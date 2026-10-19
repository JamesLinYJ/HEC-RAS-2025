using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Xml.Linq;
using Geospatial.IO.Vectors;
using H5Assist;
using Ras.Backend;
using Ras.Hydraulics;
using Ras.Layers;
using Ras.Layers.Results;
using Ras.Output;
using Utility.Progress;

internal static class MapResultMeshTimeSeriesChecks
{
    private static void Check(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }

    internal static async Task Run()
    {
        using var temporary = new TemporaryDirectory();
        MapResultChartChecks.Fixture fixture = MapResultChartChecks.CreateFixture(temporary.FullName);
        string earlyPath = SourceFilePaths.Canonical(fixture.ResultPaths.Single(path =>
            Path.GetFileNameWithoutExtension(path) == "Chart Early"));
        string latestPath = SourceFilePaths.Canonical(fixture.ResultPaths.Single(path =>
            Path.GetFileNameWithoutExtension(path) == "Chart Latest"));
        string mismatchPath = SourceFilePaths.Canonical(fixture.ResultPaths.Single(path =>
            Path.GetFileNameWithoutExtension(path) == "Unrelated Chart"));
        int exactMeshHash;
        int cellCount;
        int faceCount;
        string flowAreaName;
        using (var early = LoadResult(earlyPath))
        {
            FlowArea flowArea = early.Geometry.FlowAreaLayer.Features.Single();
            exactMeshHash = flowArea.GetMeshDataHash(isResult: false);
            cellCount = flowArea.Mesh.CellCount;
            faceCount = flowArea.Mesh.FaceCount;
            flowAreaName = flowArea.Name;
        }
        RewriteResultSignature(earlyPath, exactMeshHash, cellCount, faceCount);
        RewriteResultSignature(latestPath, exactMeshHash, cellCount, faceCount);
        RewriteResultSignature(mismatchPath, unchecked(exactMeshHash + 1), cellCount, faceCount);

        string resultDirectory = Project.GetDefaultResultDirectory(Path.GetDirectoryName(fixture.ProjectPath)!);
        string nullSignaturePath = SourceFilePaths.Canonical(Path.Combine(resultDirectory, "Null Signature.h5"));
        File.Copy(earlyPath, nullSignaturePath);
        DeleteResultSignature(nullSignaturePath, flowAreaName);
        // The chart compares currently active Result sources. Explicitly add
        // the early Result node to the fixture's map tree so its exact source
        // path is accepted by the same snapshot used for execution; a Result
        // that is merely an option in a MultiResult plan is not an active
        // source until the user selects that option.
        AddResultNodes(fixture.VisualizationPath, "Unrelated Chart", "Null Signature", "Chart Early");

        string projectXml = File.ReadAllText(fixture.ProjectPath);
        string sessionID = Guid.NewGuid().ToString("D");
        MapTreeRequest map = fixture.Map with
        {
            ProjectXml = projectXml,
            ProjectXmlSHA = Hash(Encoding.UTF8.GetBytes(projectXml)),
            ExpectedVisualizationRevision = HashFile(fixture.VisualizationPath),
            ProjectSessionID = sessionID
        };
        MapResultSourcesResult sourceSnapshot = MapResultChartService.Sources(new(map, []));
        // Source .vis standalone Result rows serialize Name, IsChecked,
        // SelectedMapType and ProfileIndex, but no path. Match the active
        // response to the exact serialized node path, then use its returned
        // SelectedResult path/revision as the source owner; Name is only the
        // fixture's way to locate the serialized row.
        int[] earlyNodePath = SerializedResultNodePath(fixture.VisualizationPath, "Chart Early");
        MapResultActiveNode earlyResultNode = sourceSnapshot.ActiveNodes.Single(node =>
            node.NodeKind == "Result" && node.Node.NodePath.SequenceEqual(earlyNodePath));
        MapResultSourceChoice earlyChoice = earlyResultNode.Selections.Single().SelectedResult
            ?? throw new InvalidOperationException("The active Chart Early Result node has no exact selected source.");
        Check(SamePath(earlyChoice.ResultPath, earlyPath),
            $"The early Result source is taken from the selected source path at the exact serialized .vis node path. Selected={earlyChoice.ResultPath}; expected={earlyPath}.");
        int[] latestNodePath = SerializedResultNodePath(fixture.VisualizationPath, "Chart Latest");
        MapResultActiveNode latestResultNode = sourceSnapshot.ActiveNodes.Single(node =>
            node.NodeKind == "Result" && node.Node.NodePath.SequenceEqual(latestNodePath));
        MapResultSourceChoice latestChoice = latestResultNode.Selections.Single().SelectedResult
            ?? throw new InvalidOperationException("The active Chart Latest Result node has no exact selected source.");
        Check(SamePath(latestChoice.ResultPath, latestPath),
            $"The latest Result source is taken from the selected source path at its exact serialized .vis node path. Selected={latestChoice.ResultPath}; expected={latestPath}.");

        var geometryModel = new GeometryMeshModelRequest(fixture.GeometryPath, "Geometry",
            fixture.ProjectPath, projectXml);
        GeometryMeshSnapshot geometry = await ModelEditorAdapter.LoadGeometryMeshAsync(new(geometryModel));
        GeometryTopologySnapshot topology = await ModelEditorAdapter.LoadGeometryTopologyAsync(
            new(new GeometryTopologyModelRequest(fixture.GeometryPath, "Geometry", fixture.ProjectPath,
                projectXml)));
        string geometryAssetID = "map-result-mesh-time-series-geometry-origin";
        var geometryOrigin = new MapResultMeshGeometryOrigin(sessionID, geometryAssetID,
            geometryModel, geometry.Revision, geometry.DraftState, topology.DraftState,
            Hash(Encoding.UTF8.GetBytes(geometry.DraftState)),
            Hash(Encoding.UTF8.GetBytes(topology.DraftState)));
        var owner = new MapResultMeshTimeSeriesOwner(map, sessionID, sourceSnapshot.ContextToken,
            [], geometryOrigin, null);
        MapResultMeshTimeSeriesInspectResult inspected = ModelEditorAdapter.InspectMapResultMeshTimeSeries(
            new(owner));
        Check(inspected.State == "ready" && inspected.OriginKind == "Geometry"
            && inspected.OriginRevision == geometry.Revision,
            "Inspection uses the exact saved Geometry origin and retained map Result snapshot.");
        Check(inspected.MatchingResultNames.Length == 2,
            "Result candidates are filtered by the same source mesh ordinal, exact non-null mesh signature and matching mesh hash; mismatched and null signatures are skipped.");

        MapResultMeshFlowAreaChoice choice = inspected.FlowAreas.Single(item =>
            item.FlowAreaIndex == 0 && item.Name == flowAreaName && item.HasMesh);
        byte[] protectedResultBytes = new[] { earlyPath, latestPath, mismatchPath, nullSignaturePath }
            .SelectMany(path => File.ReadAllBytes(path)).ToArray();
        using (new ReadOnlyFiles([earlyPath, latestPath, mismatchPath, nullSignaturePath]))
        {
            var cellProgress = new List<BackendOperationProgress>();
            MapResultMeshTimeSeriesResult cell = await Execute(owner, choice, "Cell", 0, cellProgress.Add);
            Check(cell.State == "ready" && cell.Variable == OutputVariables.Depth.Name
                && cell.Series.Length == 2,
                "Cell charts call the retained Result post-processor for every matching active Result and exclude mismatched/null signature candidates while source HDFs are read-only.");
            CheckSeriesMatchesPostProcessor(cell.Series, [earlyPath, latestPath],
                OutputVariables.Depth, 0);

            MapResultMeshTimeSeriesResult face = await Execute(owner, choice, "Face", 1, null);
            Check(face.State == "ready" && face.Variable == OutputVariables.Velocity.Name
                && face.Series.Length == 2,
                "Face charts call the retained Result post-processor for velocity at the exact face ordinal while source HDFs are read-only.");
            CheckSeriesMatchesPostProcessor(face.Series, [earlyPath, latestPath],
                OutputVariables.Velocity, 1);
            await CheckPrivatePostProcessCacheIsolation(earlyPath,
                cell.Series.Single(series => SamePath(series.ResultPath, earlyPath)),
                face.Series.Single(series => SamePath(series.ResultPath, earlyPath)));
            Check(cellProgress.Any(item => item.TaskName is not null || item.Fraction is not null || item.Message is not null),
                "Cross-Result cell reads expose source progress over duplex.");

            var cancelRequest = new MapResultMeshTimeSeriesExecuteRequest(Guid.NewGuid().ToString("D"), owner,
                choice.FlowAreaIndex, choice.FlowAreaID, choice.Name, "Cell", 0);
            string cancelLine = JsonSerializer.Serialize(new
            {
                id = cancelRequest.OperationID,
                controlSequence = 1,
                control = new { type = "cancel" }
            }) + "\n";
            await using (var cancelControls = new BackendDuplexControlReader(cancelRequest.OperationID,
                new StringReader(cancelLine)))
            {
                await Task.Delay(50);
                MapResultMeshTimeSeriesResult cancelled = await ModelEditorAdapter
                    .LoadMapResultMeshTimeSeriesDuplexAsync(cancelRequest, null, cancelControls);
                Check(cancelled.State == "cancelled",
                    "A prequeued duplex cancellation is retained as a cancelled time-series outcome.");
            }

            var lease = new MapResultComputeReadLease(Guid.NewGuid().ToString("D"), Guid.NewGuid().ToString("D"),
                fixture.ProjectPath, [latestPath], latestPath);
            MapTreeRequest leasedMap = map with { ComputeReadLease = lease };
            byte[] latestResultBytes = File.ReadAllBytes(latestPath);
            FileAttributes latestAttributes = File.GetAttributes(latestPath);
            MapResultSourcesResult leasedSnapshot;
            try
            {
                File.SetAttributes(latestPath, latestAttributes & ~FileAttributes.ReadOnly);
                File.WriteAllBytes(latestPath, Encoding.UTF8.GetBytes("protected writer-owned Result"));
                File.SetAttributes(latestPath, latestAttributes);
                leasedSnapshot = MapResultChartService.Sources(new(leasedMap, []));
                int[] protectedNodePath = SerializedResultNodePath(fixture.VisualizationPath, "Chart Latest");
                int[] stableNodePath = SerializedResultNodePath(fixture.VisualizationPath, "Chart Early");
                Check(!leasedSnapshot.ActiveNodes.Any(node => node.NodeKind == "Result" &&
                        node.Node.NodePath.SequenceEqual(protectedNodePath)),
                    "The exact callback-owned standalone Result is omitted from active chart sources while its lease is held.");
                MapResultActiveNode stableNode = leasedSnapshot.ActiveNodes.Single(node =>
                    node.NodeKind == "Result" && node.Node.NodePath.SequenceEqual(stableNodePath));
                Check(stableNode.Selections.Single().SelectedResult is { } stableChoice &&
                    SamePath(stableChoice.ResultPath, earlyPath),
                    "The unprotected checked standalone Result remains an exact active source alongside the protected marker.");
            }
            finally
            {
                File.SetAttributes(latestPath, latestAttributes & ~FileAttributes.ReadOnly);
                File.WriteAllBytes(latestPath, latestResultBytes);
                File.SetAttributes(latestPath, latestAttributes);
            }

            byte[] originalVisualizationBytes = File.ReadAllBytes(fixture.VisualizationPath);
            bool rejectedUnprotectedBrokenNode = false;
            try
            {
                AddResultNodes(fixture.VisualizationPath, "Unprotected Broken Result");
                MapTreeRequest brokenNodeMap = map with
                {
                    ExpectedVisualizationRevision = HashFile(fixture.VisualizationPath)
                };
                try
                {
                    _ = MapResultChartService.Sources(new(brokenNodeMap, []));
                }
                catch (ArgumentException error) when (error.Message.Contains(
                           "exact source file identity", StringComparison.Ordinal))
                {
                    rejectedUnprotectedBrokenNode = true;
                }
            }
            finally
            {
                File.WriteAllBytes(fixture.VisualizationPath, originalVisualizationBytes);
            }
            Check(rejectedUnprotectedBrokenNode,
                "An ordinary checked Result node without an exact source identity still fails closed without a validated callback marker.");

            var leasedOwner = new MapResultMeshTimeSeriesOwner(leasedMap, sessionID,
                leasedSnapshot.ContextToken, [], geometryOrigin, null);
            MapResultMeshTimeSeriesInspectResult leasedInspect = ModelEditorAdapter.InspectMapResultMeshTimeSeries(
                new(leasedOwner));
            Check(leasedInspect.MatchingResultNames.Length == 1,
                "The captured map compute-read lease excludes the default-selected protected Result before source loading.");
            MapResultMeshFlowAreaChoice leasedChoice = leasedInspect.FlowAreas.Single(item => item.FlowAreaIndex == 0);
            MapResultMeshTimeSeriesResult leasedResult = await Execute(leasedOwner, leasedChoice, "Cell", 0, null);
            Check(leasedResult.State == "ready" && leasedResult.Series.Length == 1
                && SamePath(leasedResult.Series[0].ResultPath, earlyPath),
                "The execute phase honors the same lease and does not open the protected default-selected Result HDF.");
            CheckSeriesMatchesPostProcessor(leasedResult.Series, [earlyPath], OutputVariables.Depth, 0);

            XDocument changedVisualization = XDocument.Load(fixture.VisualizationPath, LoadOptions.PreserveWhitespace);
            changedVisualization.Root!.Add(new XComment("stale chart request"));
            changedVisualization.Save(fixture.VisualizationPath, SaveOptions.DisableFormatting);
            await using var staleControls = new BackendDuplexControlReader("unreachable", TextReader.Null);
            await ExpectAsync<SourceFileChangedException>(() => ModelEditorAdapter
                .LoadMapResultMeshTimeSeriesDuplexAsync(new MapResultMeshTimeSeriesExecuteRequest(
                    Guid.NewGuid().ToString("D"), owner, choice.FlowAreaIndex, choice.FlowAreaID,
                    choice.Name, "Cell", 0), null, staleControls));
        }

        Check(protectedResultBytes.SequenceEqual(new[] { earlyPath, latestPath, mismatchPath, nullSignaturePath }
                .SelectMany(File.ReadAllBytes))
            && File.Exists(Path.Combine(Path.GetDirectoryName(earlyPath)!, "Chart Early", "PostProcess.h5")),
            "Result source HDFs remain byte-for-byte unchanged; any default-dataset cache is isolated under the Result PostProcess directory.");
        Console.WriteLine("Map Result mesh time-series: exact source Geometry owner, multiple Result Depth/Velocity reads, mesh signature filtering, cancellation, lease, stale context and source HDF preservation passed.");
    }

    private static async Task<MapResultMeshTimeSeriesResult> Execute(MapResultMeshTimeSeriesOwner owner,
        MapResultMeshFlowAreaChoice choice, string kind, int index,
        Action<BackendOperationProgress>? progress)
    {
        var request = new MapResultMeshTimeSeriesExecuteRequest(Guid.NewGuid().ToString("D"), owner,
            choice.FlowAreaIndex, choice.FlowAreaID, choice.Name, kind, index);
        await using var controls = new BackendDuplexControlReader(request.OperationID, TextReader.Null);
        return await ModelEditorAdapter.LoadMapResultMeshTimeSeriesDuplexAsync(request, progress, controls);
    }

    private static void CheckSeriesMatchesPostProcessor(MapResultMeshTimeSeriesSeries[] series,
        string[] expectedPaths, OutputVariable variable, int elementIndex)
    {
        Check(series.Length == expectedPaths.Length, "The selected Result set has the expected series count.");
        foreach (string path in expectedPaths)
        {
            MapResultMeshTimeSeriesSeries item = series.Single(candidate => SamePath(candidate.ResultPath, path));
            Result result = LoadResult(path);
            using (result)
            {
                using PostProcessor postProcessor = result.GetPostProcessor();
                postProcessor.EnsureDefaultDatasetsAsync(new ProgressReporter()).GetAwaiter().GetResult();
                float[] values = postProcessor.ReadTransposedDataset<float>(variable, elementIndex);
                DateTime[] times = postProcessor.Times.ToArray();
                Check(item.Variable == variable.Name && item.FlowAreaIndex == 0
                    && item.FlowAreaName == result.Geometry.FlowAreaLayer.Features[0].Name
                    && item.Times.SequenceEqual(times.Select(time => time.ToString("O",
                        System.Globalization.CultureInfo.InvariantCulture)))
                    && item.Values.SequenceEqual(values.Select(value => (double)value)),
                    $"{variable.Name} source series matches exact Result pp.Times and ReadTransposedDataset values for index {elementIndex}.");
            }
        }
    }

    private static async Task CheckPrivatePostProcessCacheIsolation(string resultPath,
        MapResultMeshTimeSeriesSeries expectedDepth, MapResultMeshTimeSeriesSeries expectedVelocity)
    {
        byte[] sourceBytes = File.ReadAllBytes(resultPath);
        using Result firstResult = LoadResult(resultPath);
        using Result secondResult = LoadResult(resultPath);
        string sharedCachePath = Result.DefaultExpectedPostProcessFilename(firstResult);
        Directory.CreateDirectory(Path.GetDirectoryName(sharedCachePath)!);
        byte[] sentinel = Encoding.UTF8.GetBytes("shared PostProcess cache must remain untouched");
        File.WriteAllBytes(sharedCachePath, sentinel);

        string cacheRoot = Path.Combine(Path.GetTempPath(), "HEC", "RAS", "PostProcessReads");
        HashSet<string> directoriesBefore = Directory.Exists(cacheRoot)
            ? Directory.EnumerateDirectories(cacheRoot).Select(Path.GetFullPath).ToHashSet(StringComparer.Ordinal)
            : [];
        string[] createdDirectories = [];
        using (var firstScope = new ResultPostProcessReadScope(firstResult))
        using (var secondScope = new ResultPostProcessReadScope(secondResult))
        {
            createdDirectories = Directory.EnumerateDirectories(cacheRoot).Select(Path.GetFullPath)
                .Where(path => !directoriesBefore.Contains(path)).ToArray();
            Check(createdDirectories.Length == 2 && !SamePath(createdDirectories[0], createdDirectories[1]),
                "Two independent Result read scopes receive separate private cache directories.");
            string[] privateCachePaths = createdDirectories
                .Select(path => Path.Combine(path, "PostProcess.h5")).ToArray();
            Check(privateCachePaths.All(File.Exists),
                "Each private scope creates its own derived PostProcess cache.");

            PostProcessor first = firstScope.Processor;
            PostProcessor second = secondScope.Processor;
            await Task.WhenAll(
                first.EnsureDefaultDatasetsAsync(new ProgressReporter()),
                second.EnsureDefaultDatasetsAsync(new ProgressReporter()));
            Task<float[]> firstDepthTask = Task.Run(() => first.ReadTransposedDataset<float>(OutputVariables.Depth, 0));
            Task<float[]> secondDepthTask = Task.Run(() => second.ReadTransposedDataset<float>(OutputVariables.Depth, 0));
            Task<float[]> firstVelocityTask = Task.Run(() => first.ReadTransposedDataset<float>(OutputVariables.Velocity, 1));
            Task<float[]> secondVelocityTask = Task.Run(() => second.ReadTransposedDataset<float>(OutputVariables.Velocity, 1));
            await Task.WhenAll(firstDepthTask, secondDepthTask, firstVelocityTask, secondVelocityTask);

            DateTime[] firstTimes = first.Times.ToArray();
            DateTime[] secondTimes = second.Times.ToArray();
            string[] expectedTimes = firstTimes.Select(time => time.ToString("O",
                System.Globalization.CultureInfo.InvariantCulture)).ToArray();
            Check(firstTimes.SequenceEqual(secondTimes)
                && expectedTimes.SequenceEqual(expectedDepth.Times)
                && expectedTimes.SequenceEqual(expectedVelocity.Times)
                && firstDepthTask.Result.SequenceEqual(secondDepthTask.Result)
                && firstDepthTask.Result.Select(value => (double)value).SequenceEqual(expectedDepth.Values)
                && firstVelocityTask.Result.SequenceEqual(secondVelocityTask.Result)
                && firstVelocityTask.Result.Select(value => (double)value).SequenceEqual(expectedVelocity.Values),
                "Concurrent private caches return identical real Depth and Velocity series and match the Host route timestamps and values.");
            Check(File.ReadAllBytes(sharedCachePath).SequenceEqual(sentinel),
                "Private Result post-processing leaves the shared default PostProcess.h5 sentinel untouched.");
            Check(File.ReadAllBytes(resultPath).SequenceEqual(sourceBytes),
                "Concurrent post-processing only reads the original Result HDF.");
        }

        string[] leakedDirectories = Directory.Exists(cacheRoot)
            ? Directory.EnumerateDirectories(cacheRoot).Select(Path.GetFullPath)
                .Where(path => !directoriesBefore.Contains(path)).ToArray()
            : [];
        Check(leakedDirectories.Length == 0,
            "Disposing independent Result post-process scopes removes their private cache directories.");
        Check(File.ReadAllBytes(sharedCachePath).SequenceEqual(sentinel)
            && File.ReadAllBytes(resultPath).SequenceEqual(sourceBytes),
            "Scope cleanup preserves both the shared-cache sentinel and original Result HDF.");
    }

    private static Result LoadResult(string path)
    {
        if (!Result.TryLoad(path, out Result? result) || result is null)
            throw new InvalidDataException("Could not reopen Result fixture: " + path);
        return result;
    }

    private static void RewriteResultSignature(string path, int hash, int cellCount, int faceCount)
    {
        string flowAreaName;
        using (Result result = LoadResult(path))
            flowAreaName = result.Geometry.FlowAreaLayer.Features.Single().Name;
        string group = MeshReader.TableSignatureGroupName("/Geometry/2D Flow Areas/" + flowAreaName);
        using var writer = new H5Writer(path);
        if (writer.ExistsAsGroup(group)) writer.Delete(group);
        new MeshPropertyTableSignature
        {
            MeshCellCount = cellCount,
            MeshFaceCount = faceCount,
            MeshHash = hash
        }.Save(writer, group);
    }

    private static void DeleteResultSignature(string path, string flowAreaName)
    {
        string group = MeshReader.TableSignatureGroupName("/Geometry/2D Flow Areas/" + flowAreaName);
        using var writer = new H5Writer(path);
        if (writer.ExistsAsGroup(group)) writer.Delete(group);
    }

    private static int[] SerializedResultNodePath(string visualizationPath, string resultName)
    {
        XDocument document = XDocument.Load(visualizationPath, LoadOptions.PreserveWhitespace);
        XElement[] maps = document.Root!.Element("Maps")!.Elements("Map").ToArray();
        XElement map = maps.Single();
        XElement[] roots = map.Element("Tree")!.Element("Nodes")!.Elements("Node").ToArray();
        int rootIndex = Array.FindIndex(roots, node => (string?)node.Attribute("Type") == "Root" &&
            (string?)node.Attribute("Name") == "Results");
        if (rootIndex < 0) throw new InvalidDataException("The .vis fixture has no Results root.");
        XElement[] resultNodes = roots[rootIndex].Elements("Node")
            .Where(node => (string?)node.Attribute("Type") == "Result" &&
                (string?)node.Attribute("Name") == resultName).ToArray();
        if (resultNodes.Length != 1)
            throw new InvalidDataException("The .vis fixture must contain one standalone Result row for " + resultName + ".");
        int childIndex = Array.IndexOf(roots[rootIndex].Elements("Node").ToArray(), resultNodes[0]);
        return [rootIndex, childIndex];
    }

    private static void AddResultNodes(string visualizationPath, params string[] resultNames)
    {
        XDocument document = XDocument.Load(visualizationPath, LoadOptions.PreserveWhitespace);
        XElement results = document.Root!.Element("Maps")!.Elements("Map").Single()
            .Element("Tree")!.Element("Nodes")!.Elements("Node")
            .Single(node => (string?)node.Attribute("Name") == "Results");
        foreach (string resultName in resultNames)
            results.Add(new XElement("Node", new XAttribute("Type", "Result"),
                new XAttribute("Name", resultName), new XAttribute("IsChecked", true),
                new XAttribute("SelectedMapType", "Depth"), new XAttribute("ProfileIndex", 0)));
        document.Save(visualizationPath, SaveOptions.DisableFormatting);
    }

    private static string Hash(byte[] bytes) => Convert.ToHexString(SHA256.HashData(bytes));
    private static string HashFile(string path) => Hash(File.ReadAllBytes(path));
    private static bool SamePath(string left, string right) =>
        Path.GetFullPath(left).Equals(Path.GetFullPath(right), StringComparison.Ordinal);

    private static async Task ExpectAsync<T>(Func<Task> action) where T : Exception
    {
        try { await action(); }
        catch (T) { return; }
        throw new InvalidOperationException("Expected " + typeof(T).Name + ".");
    }

    private sealed class TemporaryDirectory : IDisposable
    {
        private readonly DirectoryInfo directory = Directory.CreateTempSubdirectory("hecras-mesh-timeseries-");
        public string FullName => Path.GetFullPath(directory.FullName);
        public void Dispose() => directory.Delete(recursive: true);
    }

    private sealed class ReadOnlyFiles : IDisposable
    {
        private readonly Dictionary<string, FileAttributes> originalAttributes = [];

        internal ReadOnlyFiles(IEnumerable<string> paths)
        {
            try
            {
                foreach (string path in paths.Distinct(StringComparer.Ordinal))
                {
                    FileAttributes attributes = File.GetAttributes(path);
                    originalAttributes.Add(path, attributes);
                    File.SetAttributes(path, attributes | FileAttributes.ReadOnly);
                }
            }
            catch
            {
                Dispose();
                throw;
            }
        }

        public void Dispose()
        {
            foreach ((string path, FileAttributes attributes) in originalAttributes)
                File.SetAttributes(path, attributes);
            originalAttributes.Clear();
        }
    }
}
