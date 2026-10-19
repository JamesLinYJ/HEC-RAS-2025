using System.Security.Cryptography;
using System.Text.Json;
using H5Assist;
using H5Assist.Caching;
using Ras.Backend;
using Ras.Layers;
using Ras.Output;

/// <summary>
/// Exercises the retained LegacyOutputBlock Maximum summary through the actual
/// map dynamic-profile resampler. All HDF values are deterministic fixture
/// data written by the retained source writer, not solver output.
/// </summary>
internal static class MapDynamicProfileLegacyMaximumChecks
{
    private const string LegacyBlockPath = "/Results/Unsteady/Output/Output Blocks/Base Output";
    private const string AreaName = "Render flow area";

    internal static void Run()
    {
        using var directory = new TemporaryDirectory();
        MapResultRenderChecks.Fixture fixture = MapResultRenderChecks.CreateFixture(directory.FullName);
        WriteLegacyMaximum(fixture.ResultPath);
        VerifyReopenedLegacyOutputBlock(fixture.ResultPath);

        byte[] projectBefore = File.ReadAllBytes(fixture.ProjectPath);
        byte[] visualizationBefore = File.ReadAllBytes(fixture.VisualizationPath);
        byte[] resultBefore = File.ReadAllBytes(fixture.ResultPath);
        byte[] terrainBefore = File.ReadAllBytes(fixture.TerrainPath);

        MapResultSourcesResult sources = MapResultChartService.Sources(new(fixture.Map, []));
        MapResultActiveNode resultNode = sources.ActiveNodes.Single(node => node.NodeKind == "Result");
        GeometryTopologyCoordinate[] points = [new(0.5, 0.5), new(0.75, 0.5)];
        MapDynamicProfileLine line = new("legacy-maximum-profile-line", points);

        MapDynamicProfileSeries depth = Sample(fixture, sources.ContextToken, resultNode.Node,
            line, "Depth");
        MapDynamicProfileSeries waterSurface = Sample(fixture, sources.ContextToken, resultNode.Node,
            line, "WaterSurfaceElevation");
        MapDynamicProfileSeries velocity = Sample(fixture, sources.ContextToken, resultNode.Node,
            line, "Velocity");
        MapDynamicProfileSeries minimum = Sample(fixture, sources.ContextToken, resultNode.Node,
            line, "Depth", LegacyOutputBlock.MinProfileIndex);

        Check(depth.ProfileIndex == LegacyOutputBlock.MaxProfileIndex && depth.Time is null
            && depth.UnavailableReason is null && depth.Samples[0] == 6d,
            "Legacy Maximum Depth uses int.MaxValue, has no timeline value, and reaches the retained resampler (6 ft at the cell center).");
        Check(waterSurface.ProfileIndex == LegacyOutputBlock.MaxProfileIndex && waterSurface.Time is null
            && waterSurface.UnavailableReason is null && waterSurface.Samples[0] == 106d,
            "Legacy Maximum Water Surface Elevation uses the same retained resampler and returns bed elevation plus maximum depth.");
        Check(velocity.ProfileIndex == LegacyOutputBlock.MaxProfileIndex && velocity.Time is null
            && velocity.UnavailableReason is null && velocity.Samples[0] is double speed && speed > 0,
            "Legacy Maximum Velocity loads the real Maximum Face Velocity row through the retained resampler.");
        Check(minimum.ProfileIndex == LegacyOutputBlock.MinProfileIndex && minimum.Time is null
            && minimum.UnavailableReason?.Contains("does not read Minimum summary datasets", StringComparison.Ordinal) == true
            && minimum.Samples.All(value => value is null),
            "The retained Legacy reader's unsupported Minimum sentinel remains explicitly unavailable, without reading a normal frame.");

        Check(File.ReadAllBytes(fixture.ProjectPath).SequenceEqual(projectBefore)
            && File.ReadAllBytes(fixture.VisualizationPath).SequenceEqual(visualizationBefore)
            && File.ReadAllBytes(fixture.ResultPath).SequenceEqual(resultBefore)
            && File.ReadAllBytes(fixture.TerrainPath).SequenceEqual(terrainBefore),
            "Legacy Maximum profile sampling leaves project, .vis, Result HDF and terrain bytes unchanged.");

        ExportFixtureIfRequested(directory.FullName, fixture, resultNode, line, depth, waterSurface, velocity);
        Console.WriteLine("Legacy Maximum map dynamic-profile sampling, retained HDF loading, Depth/WSE/Velocity values, unsupported Minimum and read-only source checks passed.");
    }

    private static MapDynamicProfileSeries Sample(MapResultRenderChecks.Fixture fixture,
        string contextToken, CatalogTreeNodeLocator node, MapDynamicProfileLine line,
        string mapType, int profileIndex = int.MaxValue)
    {
        MapDynamicProfileResult response = MapDynamicProfileService.Sample(new(fixture.Map,
            contextToken, [], [line], "legacy-maximum-lines", TargetSampleCount: 16,
            PlotTerrains: false, PlotResults: true, TerrainRequiresElevationResult: false,
            MapType: mapType, ProfileSelections: [new(node, profileIndex)]));
        MapDynamicProfileSeries series = response.Lines.Single().Series.Single(item => item.SourceKind == "Result");
        Check(response.LinesToken == "legacy-maximum-lines"
            && response.DistanceUnits == "ft"
            && MapSourceTestPaths.SameFile(series.SourcePath, fixture.ResultPath)
            && string.Equals(series.SourceRevision, Hash(fixture.ResultPath), StringComparison.OrdinalIgnoreCase),
            "The result sample retains the exact source identity/revision, request token and project distance units.");
        return series;
    }

    private static void WriteLegacyMaximum(string resultPath)
    {
        using var writer = new H5Writer(resultPath);
        // Result.InitInternal prefers the modern root; remove it so reopening
        // must take the retained LegacyOutputBlock loader path.
        writer.Delete("/Results/Output Blocks");
        writer.CreateGroup(LegacyBlockPath);
        writer.WriteAttribute(LegacyBlockPath, "Output Block Name", "Base Output");
        writer.WriteDataset(LegacyBlockPath + "/Unsteady Time Series/Time", new double[] { 0d });
        writer.WriteDataset(LegacyBlockPath + "/Unsteady Time Series/Time Date Stamp",
            new[] { "2026-10-16T00:00:00Z" });

        string summaryPath = LegacyBlockPath + "/Summary Output/2D Flow Areas/" + AreaName + "/";
        using (var depthRows = new H5AppendCache<float>(writer, summaryPath + "Maximum Cell Depth",
                   nRowsPerChunk: 10, nColumns: 1))
            depthRows.AddRow(new float[] { 6f }.AsMemory());
        using (var velocityRows = new H5AppendCache<float>(writer, summaryPath + "Maximum Face Velocity",
                   nRowsPerChunk: 10, nColumns: 4))
            velocityRows.AddRow(new float[] { 0.25f, 0.5f, 0.75f, 1f }.AsMemory());
    }

    private static void VerifyReopenedLegacyOutputBlock(string resultPath)
    {
        if (!Result.TryLoad(resultPath, out Result? reopened) || reopened is null)
            throw new InvalidDataException("The source-written Legacy Maximum Result could not be reopened.");
        using (reopened)
        {
            if (reopened.BaseOutputBlock is not LegacyOutputBlock legacy)
                throw new InvalidDataException("Reopening did not select LegacyOutputBlock after the modern Output Blocks root was removed.");
            Check(legacy.ProfileCount == 1
                && legacy.ProfileIndex("Max") == LegacyOutputBlock.MaxProfileIndex
                && legacy.ProfileName(LegacyOutputBlock.MaxProfileIndex) == "Max",
                "The reopened Result exposes one timeline profile and the retained Max sentinel identity.");
        }
    }

    private static void ExportFixtureIfRequested(string sourceRoot,
        MapResultRenderChecks.Fixture fixture, MapResultActiveNode resultNode,
        MapDynamicProfileLine line, MapDynamicProfileSeries depth,
        MapDynamicProfileSeries waterSurface, MapDynamicProfileSeries velocity)
    {
        string? destination = Environment.GetEnvironmentVariable("HECRAS_LEGACY_MAXIMUM_ACCEPTANCE_DIRECTORY");
        if (string.IsNullOrWhiteSpace(destination)) return;

        string source = Path.GetFullPath(sourceRoot);
        string target = Path.GetFullPath(destination);
        StringComparison comparison = OperatingSystem.IsWindows()
            ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal;
        string sourcePrefix = source.TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
        if (Directory.Exists(target) || File.Exists(target)
            || target.Equals(source, comparison) || target.StartsWith(sourcePrefix, comparison))
            throw new IOException("The Legacy Maximum acceptance directory must be new and outside the source fixture.");

        Directory.CreateDirectory(target);
        foreach (string path in Directory.EnumerateFiles(source, "*", SearchOption.AllDirectories))
        {
            string copy = Path.Combine(target, Path.GetRelativePath(source, path));
            Directory.CreateDirectory(Path.GetDirectoryName(copy)!);
            File.Copy(path, copy);
        }

        string Relative(string path) => Path.GetRelativePath(source, path).Replace('\\', '/');
        var manifest = new
        {
            provenance = "Fresh Project.CreateNew/Result.PrepareResult/OutputBlock.CreateNew fixture. The modern Output Blocks root was removed with retained H5Writer; a Legacy Output Blocks tree and row-chunked summary datasets were written with retained H5Writer and H5AppendCache. Values are deterministic fixture data, not solver output.",
            project = Relative(fixture.ProjectPath),
            visualization = Relative(fixture.VisualizationPath),
            result = Relative(fixture.ResultPath),
            terrain = Relative(fixture.TerrainPath),
            sha256 = new
            {
                project = Hash(fixture.ProjectPath),
                visualization = Hash(fixture.VisualizationPath),
                result = Hash(fixture.ResultPath),
                terrain = Hash(fixture.TerrainPath)
            },
            map = new
            {
                id = fixture.Map.MapID,
                index = fixture.Map.MapIndex,
                name = fixture.Map.MapName,
                type = fixture.Map.MapType
            },
            line = new
            {
                id = line.Id,
                points = line.Points.Select(point => new { x = point.X, y = point.Y }).ToArray(),
                feature = (object?)null
            },
            selectedResult = new
            {
                nodeKind = resultNode.NodeKind,
                nodeName = resultNode.Name,
                locator = resultNode.Node,
                source = Relative(fixture.ResultPath),
                profileIndex = LegacyOutputBlock.MaxProfileIndex,
                time = (string?)null,
                resolveLocator = "Recompute project XML SHA and .vis revision, call map.resultSources, then resolve this locator against its returned active Result nodes. Create a fresh context token for each dynamic-profile request."
            },
            hdf = new
            {
                legacyBlock = LegacyBlockPath,
                maximumCellDepth = LegacyBlockPath + "/Summary Output/2D Flow Areas/" + AreaName + "/Maximum Cell Depth",
                maximumFaceVelocity = LegacyBlockPath + "/Summary Output/2D Flow Areas/" + AreaName + "/Maximum Face Velocity",
                profileIndex = LegacyOutputBlock.MaxProfileIndex,
                minimumProfileIndex = LegacyOutputBlock.MinProfileIndex
            },
            expected = new
            {
                distanceUnits = "ft",
                profileTime = (string?)null,
                depthAtFirstPoint = depth.Samples[0],
                waterSurfaceElevationAtFirstPoint = waterSurface.Samples[0],
                velocityAtFirstPoint = velocity.Samples[0],
                minimumUnavailableContains = "does not read Minimum summary datasets"
            }
        };
        File.WriteAllText(Path.Combine(target, "LEGACY_MAXIMUM_PROFILE_FIXTURE.json"),
            JsonSerializer.Serialize(manifest, new JsonSerializerOptions
            {
                WriteIndented = true,
                PropertyNamingPolicy = JsonNamingPolicy.CamelCase
            }));
        File.WriteAllText(Path.Combine(target, "ACCEPTANCE.txt"),
            "Fresh retained-source writer fixture for Legacy Maximum dynamic-profile integration. "
            + "Recompute project XML SHA and .vis revision when loading. The summary values are test data, not a solver run or solver validation.");
    }

    private static string Hash(string path)
    {
        using FileStream stream = File.OpenRead(path);
        return Convert.ToHexString(SHA256.HashData(stream));
    }

    private static void Check(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }
}
