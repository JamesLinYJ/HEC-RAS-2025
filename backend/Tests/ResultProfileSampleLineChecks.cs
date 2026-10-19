using System.Security.Cryptography;
using Geospatial.PairedData;
using Geospatial.Rasters;
using Geospatial.Vectors;
using Geospatial.Vectors.Meshes;
using H5Assist;
using Ras.Backend;
using Ras.Engine;
using Ras.Hydraulics;
using Ras.Layers;
using Ras.Output;
using Utility.Units;
using BoundaryCondition = Ras.Layers.BoundaryCondition;

/// <summary>
/// Exercises sample-line output through the retained Result callback using
/// deterministic OutputBlock test data. The HDF fixture is not solver output.
/// </summary>
internal static class ResultProfileSampleLineChecks
{
    private static readonly DateTime Start = new(2026, 10, 16, 0, 0, 0, DateTimeKind.Utc);

    private static void CheckSymbolicProjectBase(string root, string projectPath, string xml,
        string primaryPath, string primaryRevision)
    {
        if (OperatingSystem.IsWindows()) return;
        using var alias = new TemporaryDirectory();
        foreach (string file in Directory.GetFiles(root, "*", SearchOption.AllDirectories))
        {
            if (file == projectPath) continue;
            string copy = Path.Combine(alias.FullName, Path.GetRelativePath(root, file));
            Directory.CreateDirectory(Path.GetDirectoryName(copy)!);
            File.Copy(file, copy);
        }
        string logicalProject = Path.Combine(alias.FullName, Path.GetFileName(projectPath));
        File.CreateSymbolicLink(logicalProject, projectPath);
        string logicalResult = Path.Combine(alias.FullName, Path.GetRelativePath(root, primaryPath));
        var loaded = ResultProfileSampleLineService.Sources(new(logicalProject, xml, logicalResult, primaryRevision));
        Check(loaded.ProjectPath == Path.GetFullPath(logicalProject)
            && loaded.Sources.Any(source => SameSourcePath(source.ResultPath, logicalResult)),
            "A symlinked .ras retains its selected directory as the base for relative Result dependencies.");
    }

    internal static async Task Run()
    {
        using var temporary = new TemporaryDirectory();
        string projectPath = Path.Combine(temporary.FullName, "Sample Line Project.ras");
        Project project = Project.CreateNew(projectPath, UnitSystem.USCustomary);
        try
        {
            Geometry geometry = CreateGeometry(project);
            BoundaryCondition boundary = project.AddNewBoundaryCondition("Sample Line Boundary", Start, TimeSpan.FromHours(2));
            Plan plan = project.AddNewPlan("Sample Line Plan", geometry, boundary);
            Plan unrelatedPlan = project.AddNewPlan("Unrelated Plan", geometry, boundary);
            foreach (CoreLayerBase layer in Layers(project)) layer.Save();
            project.Save();
            Directory.CreateDirectory(project.ResultsDirectory);

            string primaryPath = Path.Combine(project.ResultsDirectory, "Sample Line Primary.h5");
            string comparisonPath = Path.Combine(project.ResultsDirectory, "Sample Line Comparison.h5");
            string unrelatedPath = Path.Combine(project.ResultsDirectory, "Unrelated Result.h5");
            CreateResult(primaryPath, plan, geometry, boundary, velocityScale: 1f, stageOffset: 0f);
            CreateResult(comparisonPath, plan, geometry, boundary, velocityScale: 2f, stageOffset: 1f);
            CreateResult(unrelatedPath, unrelatedPlan, geometry, boundary, velocityScale: 3f, stageOffset: 2f);

            string projectXml = File.ReadAllText(projectPath);
            string primaryRevision = Hash(primaryPath);
            string projectRevision = Hash(projectPath);
            var sources = ResultProfileSampleLineService.Sources(new(projectPath, projectXml, primaryPath, primaryRevision));
            Check(sources.Sources.Length == 2
                && sources.Sources.All(source => source.EmbeddedPlanName == plan.Name)
                && sources.Sources.Any(source => SameSourcePath(source.ResultPath, primaryPath))
                && sources.Sources.Any(source => SameSourcePath(source.ResultPath, comparisonPath))
                && sources.Sources.All(source => source.FirstFlowAreaCellCount == 1 && source.FirstFlowAreaFaceCount == 4),
                "Overlay candidates come from the selected Result's retained ObservablePlan.NameMatchedResults and report its first embedded mesh.");
            ExportFixtureIfRequested(temporary.FullName);
            CheckSymbolicProjectBase(temporary.FullName, projectPath, projectXml, primaryPath, primaryRevision);

            var sampleLine = new GeometryTopologyCoordinate[]
            {
                new(0.5, 0.05), new(0.5, 0.95)
            };
            ResultProfileSourceIdentity[] selected = sources.Sources.Select(source =>
                new ResultProfileSourceIdentity(source.ResultPath, source.Revision)).ToArray();
            var flowRequest = new ResultProfileSampleLineRequest(projectPath, projectXml,
                primaryPath, primaryRevision, selected, sampleLine, "Flow");
            ResultProfileSampleLineResult flow = await ResultProfileSampleLineService.ComputeAsync(flowRequest);
            Check(flow.Series.Length == 2 && flow.Series.All(series => series.Available && series.Points.Length == 3)
                && flow.SampleLine.SequenceEqual(sampleLine),
                "The SampleLine request returns one source-computed series per explicitly selected related Result. "
                + string.Join("; ", flow.Series.Select(series => series.UnavailableReason ?? "available")));

            double[][] expectedFlow = [[], []];
            string[] paths = [primaryPath, comparisonPath];
            for (int index = 0; index < paths.Length; index++)
            {
                if (!Result.TryLoad(paths[index], out Result? result) || result is null)
                    throw new InvalidDataException("Could not reopen the source Result for callback comparison.");
                using (result)
                {
                    (var operation, double[] values) = await result.ComputeFlowTimeSeriesAsync(ToPolyline(sampleLine));
                    Check(operation.Result && values.Length == 3 && values.Any(value => value != 0),
                        "The retained Result.ComputeFlowTimeSeriesAsync computes nonzero flow for the crossing line.");
                    expectedFlow[index] = values;
                }
            }
            foreach (ResultProfileSampleLineSeries sample in flow.Series)
            {
                int index = Array.FindIndex(paths, path => SameSourcePath(path, sample.ResultPath));
                Check(index >= 0 && sample.Points.Select(point => point.Value).SequenceEqual(ValuesNullable(expectedFlow[index])),
                    "The backend callback returns the exact retained Result flow values for each overlay Result.");
            }
            Check(!expectedFlow[0].SequenceEqual(expectedFlow[1]),
                "Overlay rows remain distinct when the underlying stored source states differ.");

            var volumeRequest = flowRequest with { Mode = "CumulativeVolume" };
            ResultProfileSampleLineResult volume = await ResultProfileSampleLineService.ComputeAsync(volumeRequest);
            Check(volume.Series.Length == 2 && volume.Series.All(series => series.Available && series.Points.Length == 3),
                "Cumulative volume returns the source profile timestamps and one accumulated series per selected Result.");
            for (int index = 0; index < paths.Length; index++)
            {
                if (!Result.TryLoad(paths[index], out Result? result) || result is null)
                    throw new InvalidDataException("Could not reopen the source Result for accumulated-value comparison.");
                using (result)
                {
                    var postProcessor = result.GetPostProcessor();
                    double[] expectedVolume = new RateTimeSeries(postProcessor.Times, expectedFlow[index], Time.Seconds,
                        ProfileInterpolationMethod.Linear).AccumulatedValues.ToArray();
                    ResultProfileSampleLineSeries sample = volume.Series.Single(item =>
                        SameSourcePath(item.ResultPath, paths[index]));
                    Check(sample.Points.Select(point => point.Value).SequenceEqual(ValuesNullable(expectedVolume))
                        && expectedVolume.Any(value => value != 0),
                        "Cumulative values exactly follow the retained RateTimeSeries linear integration.");
                }
            }

            var unrelatedIdentity = new ResultProfileSourceIdentity(unrelatedPath, Hash(unrelatedPath));
            var outOfGroup = flowRequest with
            {
                Sources = [new ResultProfileSourceIdentity(primaryPath, primaryRevision), unrelatedIdentity]
            };
            Expect<ArgumentException>(() => ResultProfileSampleLineService.ComputeAsync(outOfGroup).GetAwaiter().GetResult());
            var stale = flowRequest with { Sources = [selected[0], selected[1] with { Revision = new string('0', 64) }] };
            Expect<SourceFileChangedException>(() => ResultProfileSampleLineService.ComputeAsync(stale).GetAwaiter().GetResult());
            var onePoint = flowRequest with { SampleLine = [sampleLine[0]] };
            Expect<ArgumentException>(() => ResultProfileSampleLineService.ComputeAsync(onePoint).GetAwaiter().GetResult());

            Check(Hash(primaryPath) == primaryRevision && Hash(comparisonPath) == sources.Sources.Single(source => SameSourcePath(source.ResultPath, comparisonPath)).Revision
                && Hash(unrelatedPath) == unrelatedIdentity.Revision && Hash(projectPath) == projectRevision,
                "Flow and cumulative sampling leave every source Result HDF and project file byte-identical.");
        }
        finally { DisposeProject(project); }

        Console.WriteLine("Retained Result sample-line flow callback, related-result overlay, cumulative integration, stale identity and read-only source checks passed.");
    }

    private static Geometry CreateGeometry(Project project)
    {
        Geometry geometry = project.AddNewGeometry("Sample Line Geometry");
        Mesh mesh = CreateMesh();
        var elevation = new ConstantValueResampler<float>(100f, Extent.Infinite, -9999f);
        var roughness = new ConstantValueResampler<float>(0.03f, Extent.Infinite, -9999f);
        var computed = MeshPropertyTables.ComputeFrom(mesh, elevation, roughness,
            PropertyTableOptions.Default(UnitSystem.USCustomary), out MeshPropertyTables tables);
        Check(computed.Result, "Source hydraulic tables are prepared for the deterministic HDF test fixture.");
        geometry.FlowAreaLayer.Add(new FlowArea(mesh, "采样线 流区") { PropertyTables = tables });
        geometry.Save();
        return geometry;
    }

    private static void CreateResult(string resultPath, Plan plan, Geometry geometry,
        BoundaryCondition boundary, float velocityScale, float stageOffset)
    {
        using (Result prepared = Result.PrepareResult(resultPath, plan, geometry, boundary, null!))
            Check(File.Exists(resultPath), "The retained Result.PrepareResult writer creates the HDF test fixture.");
        if (!Result.TryLoad(resultPath, out Result? loaded) || loaded is null)
            throw new InvalidDataException("Could not reopen the result fixture for OutputBlock writing.");
        using (loaded)
        using (var output = OutputBlock.CreateNew(loaded, "Base Output"))
        {
            string areaName = loaded.Geometry.FlowAreaLayer[0].Name;
            Check(output.GetTimeSeriesDatasetName(OutputVariables.Depth)
                    == output.GetTimeSeriesDatasetName(OutputVariables.Depth, areaName)
                && output.GetTimeSeriesDebugGroupName()
                    == OutputBlock.RootMeshOutputPath("Base Output", areaName) + "DEBUG",
                "Single-mesh post-processing resolves the embedded Chinese/spaced flow-area name for normal and debug datasets.");
            output.EnableWriting();
            double[][] faceVelocities =
            [
                [1f, 2f, 3f, 4f],
                [2f, 4f, 6f, 8f],
                [3f, 6f, 9f, 12f]
            ];
            for (int profile = 0; profile < faceVelocities.Length; profile++)
            {
                FlowArea area = loaded.Geometry.FlowAreaLayer[0];
                var state = new MeshWaterState(area.Mesh, area.PropertyTables)
                {
                    tMicros = profile * 1_800_000_000L,
                    CellElevation = [101.5f + stageOffset + profile * 0.5f],
                    FaceVelocity = faceVelocities[profile].Select(value => value * velocityScale).ToArray()
                };
                output.AddTimestep(new MeshTimestep(state, profile));
            }
            output.FinishWriting();
        }
    }

    private static Mesh CreateMesh()
    {
        Point[] points = [new(0, 0), new(1, 0), new(1, 1), new(0, 1)];
        Face[] faces = Enumerable.Range(0, 4)
            .Select(index => new Face { fpA = index, fpB = (index + 1) % 4, cellA = 0, cellB = -1 }).ToArray();
        FacePoint[] nodes = points.Select((point, index) => new FacePoint(point)
            { Faces = [(index + 3) % 4, index] }).ToArray();
        return new Mesh(new Polygon(points), [new Cell { Faces = new int[] { 0, 1, 2, 3 } }],
            faces, nodes, [new Point(0.5, 0.5)], null!);
    }

    private static Polyline ToPolyline(IEnumerable<GeometryTopologyCoordinate> points)
    {
        var line = new Polyline();
        foreach (GeometryTopologyCoordinate point in points) line.Add(new Point(point.X, point.Y));
        return line;
    }

    private static IEnumerable<CoreLayerBase> Layers(Project project) => project.Plans.Cast<CoreLayerBase>()
        .Concat(project.Geometries).Concat(project.BoundaryConditions).Concat(project.Terrains)
        .Concat(project.NValues).Concat(project.ClassificationLayers);

    private static void DisposeProject(Project project)
    {
        foreach (Result result in project.Results) result.Dispose();
        foreach (CoreLayerBase layer in Layers(project)) layer.Dispose();
    }

    private static string Hash(string path)
    {
        using Stream stream = File.OpenRead(path);
        return Convert.ToHexString(SHA256.HashData(stream));
    }

    private static bool SameSourcePath(string left, string right) =>
        PathComparer.Equals(CanonicalPath(left, depth: 0), CanonicalPath(right, depth: 0));

    private static StringComparer PathComparer => OperatingSystem.IsWindows()
        ? StringComparer.OrdinalIgnoreCase
        : StringComparer.Ordinal;

    private static string CanonicalPath(string path, int depth)
    {
        if (depth > 64) throw new IOException("The fixture path contains too many symbolic links.");

        string fullPath = Path.GetFullPath(path);
        string root = Path.GetPathRoot(fullPath)
            ?? throw new ArgumentException("The fixture path must be absolute.", nameof(path));
        string current = root;
        string remainder = fullPath[root.Length..];
        foreach (string segment in remainder.Split(
                     [Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar],
                     StringSplitOptions.RemoveEmptyEntries))
        {
            current = Path.Combine(current, segment);
            FileSystemInfo info = Directory.Exists(current)
                ? new DirectoryInfo(current)
                : new FileInfo(current);
            if (info.LinkTarget is null) continue;
            FileSystemInfo? target = info.ResolveLinkTarget(returnFinalTarget: true);
            if (target is null) continue;

            string targetPath = Path.GetFullPath(target.FullName);
            if (!PathComparer.Equals(targetPath, current)) current = CanonicalPath(targetPath, depth + 1);
        }
        return current;
    }

    private static double?[] ValuesNullable(IEnumerable<double> values) => values.Select(value => (double?)value).ToArray();

    private static void ExportFixtureIfRequested(string sourceRoot)
    {
        string? destination = Environment.GetEnvironmentVariable("HECRAS_RESULT_SAMPLE_LINE_ACCEPTANCE_DIRECTORY");
        if (string.IsNullOrWhiteSpace(destination)) return;
        string target = Path.GetFullPath(destination);
        if (Directory.Exists(target) || File.Exists(target)
            || target.StartsWith(Path.GetFullPath(sourceRoot) + Path.DirectorySeparatorChar, StringComparison.Ordinal))
            throw new IOException("The sample-line acceptance directory already exists or is inside the source fixture.");
        Directory.CreateDirectory(target);
        foreach (string path in Directory.EnumerateFiles(sourceRoot, "*", SearchOption.AllDirectories))
        {
            string copy = Path.Combine(target, Path.GetRelativePath(sourceRoot, path));
            Directory.CreateDirectory(Path.GetDirectoryName(copy)!);
            File.Copy(path, copy);
        }
    }

    private static void Check(bool condition, string name)
    {
        if (!condition) throw new InvalidOperationException(name);
    }

    private static void Expect<T>(Action action) where T : Exception
    {
        try { action(); }
        catch (T) { return; }
        throw new InvalidOperationException("Expected " + typeof(T).Name + ".");
    }
}
