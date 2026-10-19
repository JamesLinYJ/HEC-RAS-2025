using System.Buffers.Binary;
using System.Security.Cryptography;
using System.Text.Json;
using System.Xml.Linq;
using Geospatial.Vectors;
using Ras.Backend;
using Ras.Output;
using Utility.Units;

/// <summary>
/// Exercises the DynamicProfilePlot map route against the same reopenable
/// Result HDF fixture used by the retained map renderer. Stored values are
/// deterministic test data and are not solver output.
/// </summary>
internal static class MapDynamicProfileChecks
{
    internal static void Run()
    {
        using var directory = new TemporaryDirectory();
        MapResultRenderChecks.Fixture fixture = AddActiveTerrainNode(
            MapResultRenderChecks.CreateFixture(directory.FullName));
        fixture = AddActiveVectorLayer(fixture, out string vectorPath);

        byte[] projectBefore = File.ReadAllBytes(fixture.ProjectPath);
        byte[] visualizationBefore = File.ReadAllBytes(fixture.VisualizationPath);
        byte[] resultBefore = File.ReadAllBytes(fixture.ResultPath);
        byte[] terrainBefore = File.ReadAllBytes(fixture.TerrainPath);
        byte[] vectorBefore = File.ReadAllBytes(vectorPath);
        MapResultSourcesResult sources = MapResultChartService.Sources(new(fixture.Map, []));
        MapResultActiveNode resultNode = sources.ActiveNodes.Single(node => node.NodeKind == "Result");
        GeometryTopologyCoordinate[] originalPoints =
        [
            new(0.5, 0.5),
            new(2, 0.5)
        ];
        MapDynamicProfileLine line = new("dynamic-profile-fixture", originalPoints);

        MapDynamicProfileResult depthFirst = MapDynamicProfileService.Sample(new(fixture.Map,
            sources.ContextToken, [], [line], "line-snapshot-1", TargetSampleCount: 16,
            PlotTerrains: true, PlotResults: true, TerrainRequiresElevationResult: true,
            MapType: "Depth", ProfileSelections: [new(resultNode.Node, 0)]));
        MapDynamicProfileResult depthLast = MapDynamicProfileService.Sample(new(fixture.Map,
            sources.ContextToken, [], [line], "line-snapshot-1", TargetSampleCount: 16,
            PlotTerrains: true, PlotResults: true, TerrainRequiresElevationResult: false,
            MapType: "Depth", ProfileSelections: [new(resultNode.Node, 2)]));
        MapDynamicProfileResult waterSurface = MapDynamicProfileService.Sample(new(fixture.Map,
            sources.ContextToken, [], [line], "line-snapshot-1", TargetSampleCount: 16,
            PlotTerrains: true, PlotResults: true, TerrainRequiresElevationResult: true,
            MapType: "WaterSurfaceElevation", ProfileSelections: [new(resultNode.Node, 2)]));
        string projectXml = File.ReadAllText(fixture.ProjectPath);
        ResultPlanContextSnapshot planContext = ResultPlanContextService.Inspect(fixture.ProjectPath,
            projectXml, fixture.ResultPath, Hash(fixture.ResultPath));
        LinkedResultProfilesRequest linkedRequest = new(fixture.ProjectPath, projectXml,
            planContext.ProjectRevision, planContext.Anchor, [], ProfileIndex: 2);
        MapDynamicProfileResult linked = MapDynamicProfileService.Sample(new(fixture.Map,
            sources.ContextToken, [], [line], "line-snapshot-linked", TargetSampleCount: 16,
            PlotTerrains: true, PlotResults: true, TerrainRequiresElevationResult: false,
            MapType: "Depth", LinkedResults: linkedRequest));
        MapDynamicProfileResult linkedMaximum = MapDynamicProfileService.Sample(new(fixture.Map,
            sources.ContextToken, [], [line], "line-snapshot-linked-max", TargetSampleCount: 16,
            PlotTerrains: false, PlotResults: true, TerrainRequiresElevationResult: false,
            MapType: "Depth", LinkedResults: linkedRequest, LinkedFrameMode: "Maximum"));
        MapDynamicProfileResult linkedMinimum = MapDynamicProfileService.Sample(new(fixture.Map,
            sources.ContextToken, [], [line], "line-snapshot-linked-min", TargetSampleCount: 16,
            PlotTerrains: false, PlotResults: true, TerrainRequiresElevationResult: false,
            MapType: "Depth", LinkedResults: linkedRequest, LinkedFrameMode: "Minimum"));

        MapDynamicProfileLineResult firstLine = depthFirst.Lines.Single();
        MapDynamicProfileLineResult lastLine = depthLast.Lines.Single();
        Check(depthFirst.LinesToken == "line-snapshot-1" && depthLast.ContextToken == sources.ContextToken,
            "The response echoes the exact line snapshot and resolved source-context tokens.");
        Check(depthFirst.DistanceUnits == "ft" &&
              MapDynamicProfileService.DistanceUnits(UnitSystem.USCustomary) == "ft" &&
              MapDynamicProfileService.DistanceUnits(UnitSystem.SI) == "m",
            "Station-distance labels follow the resolved project unit system, independently of sampled ordinate units.");
        Check(firstLine.Points.SequenceEqual(originalPoints) && firstLine.Id == line.Id,
            "The response preserves the source polyline coordinates and stable line identity.");
        var expectedPolyline = new Polyline(originalPoints.Select(point => new Point(point.X, point.Y)).ToList());
        expectedPolyline.Densify(expectedPolyline.Length / 16d);
        GeometryTopologyCoordinate[] expectedSamples = expectedPolyline.Points
            .Select(point => new GeometryTopologyCoordinate(point.X, point.Y)).ToArray();
        Check(firstLine.SamplePoints.SequenceEqual(expectedSamples)
            && firstLine.Distances.Length == firstLine.SamplePoints.Length
            && firstLine.Distances[0] == 0
            && firstLine.Distances.Zip(firstLine.Distances.Skip(1), (left, right) => right >= left).All(value => value),
            "Polyline.Densify uses the retained target-spacing contract and returns monotonic cumulative stations.");

        MapDynamicProfileSeries firstDepth = firstLine.Series.Single(series => series.SourceKind == "Result");
        MapDynamicProfileSeries lastDepth = lastLine.Series.Single(series => series.SourceKind == "Result");
        Check(firstDepth.ProfileIndex == 0 && lastDepth.ProfileIndex == 2
            && firstDepth.Samples.Length == firstLine.SamplePoints.Length
            && lastDepth.Samples.Length == lastLine.SamplePoints.Length
            && firstDepth.Samples[0] is double firstValue && firstValue > 0
            && lastDepth.Samples[0] is double lastValue && lastValue > firstValue,
            "The active Result series samples distinct stored Depth profiles through the actual map resampler.");
        Check(lastDepth.Samples.Any(value => value == 0),
            "Chart-friendly Depth no-data is represented by the source's zero substitute.");
        MapDynamicProfileSeries linkedDepth = linked.Lines.Single().Series.Single(series => series.SourceKind == "Result");
        Check(linkedDepth.ProfileIndex == 2 && linkedDepth.Samples.SequenceEqual(lastDepth.Samples)
            && MapSourceTestPaths.SameFile(linkedDepth.SourcePath, fixture.ResultPath),
            "Linked Result frames sample the exact returned keyed profile and retain its source identity instead of the base .vis Result selection.");
        MapDynamicProfileSeries linkedMaximumUnavailable = linkedMaximum.Lines.Single().Series.Single(series => series.SourceKind == "Result");
        MapDynamicProfileSeries linkedMinimumUnavailable = linkedMinimum.Lines.Single().Series.Single(series => series.SourceKind == "Result");
        Check(linkedMaximumUnavailable.ProfileIndex == LegacyOutputBlock.MaxProfileIndex
            && linkedMaximumUnavailable.UnavailableReason?.Contains("Legacy Maximum", StringComparison.Ordinal) == true
            && linkedMaximumUnavailable.Samples.All(value => value is null)
            && linkedMinimumUnavailable.ProfileIndex == LegacyOutputBlock.MinProfileIndex
            && linkedMinimumUnavailable.Time is null
            && linkedMinimumUnavailable.UnavailableReason?.Contains("does not read Minimum", StringComparison.Ordinal) == true
            && linkedMinimumUnavailable.Samples.All(value => value is null),
            "Linked Maximum/Minimum use summary sentinels and return explicit unavailable on a modern OutputBlock fixture.");
        Check(!firstLine.Series.Any(series => series.SourceKind == "Terrain")
            && lastLine.Series.Any(series => series.SourceKind == "Terrain")
            && waterSurface.Lines.Single().Series.Any(series => series.SourceKind == "Terrain"),
            "Active terrain series obey TerrainRequiresElevationResult for Depth and Water Surface Elevation.");

        MapDynamicProfileResult implicitMapType = MapDynamicProfileService.Sample(new(fixture.Map,
            sources.ContextToken, [], [line], "line-snapshot-implicit-map-type", TargetSampleCount: 16,
            PlotTerrains: true, PlotResults: true, TerrainRequiresElevationResult: false,
            MapType: null, ProfileSelections: [new(resultNode.Node, 0)]));
        MapDynamicProfileResult implicitMapTypeTerrainGated = MapDynamicProfileService.Sample(new(fixture.Map,
            sources.ContextToken, [], [line], "line-snapshot-implicit-map-type-gated", TargetSampleCount: 16,
            PlotTerrains: true, PlotResults: true, TerrainRequiresElevationResult: true,
            MapType: null, ProfileSelections: [new(resultNode.Node, 0)]));
        Check(implicitMapType.Lines.Single().Series.Any(series => series.SourceKind == "Terrain")
            && !implicitMapTypeTerrainGated.Lines.Single().Series.Any(series => series.SourceKind == "Terrain")
            && implicitMapType.Lines.Single().Series.Single(series => series.SourceKind == "Result").MapType == "Depth",
            "A nil MapType preserves each active Result's stored type and the terrain gate uses only the actual request map type.");

        var feature = new MapResultFeatureIdentity(vectorPath, Hash(vectorPath), line.Id, CoordinateSHA(originalPoints));
        MapDynamicProfileLine vectorLine = line with { Feature = feature };
        MapDynamicProfileResult vectorLineResult = MapDynamicProfileService.Sample(new(fixture.Map,
            sources.ContextToken, [], [vectorLine], "map-vector-source-token", TargetSampleCount: 16,
            PlotTerrains: false, PlotResults: true, TerrainRequiresElevationResult: false,
            MapType: "Depth", ProfileSelections: [new(resultNode.Node, 0)]));
        Check(vectorLineResult.Lines.Single().Id == line.Id &&
              vectorLineResult.Lines.Single().Points.SequenceEqual(originalPoints),
            "A saved-map vector line is accepted only with its exact selected-map path, source revision, feature ID and coordinate hash.");
        Expect<ArgumentException>(() => MapDynamicProfileService.Sample(new(fixture.Map,
            sources.ContextToken, [], [vectorLine with { Feature = feature with { CoordinateSHA = new string('0', 64) } }],
            "map-vector-coordinate-mismatch", TargetSampleCount: 16, PlotTerrains: false, PlotResults: true,
            TerrainRequiresElevationResult: false, MapType: "Depth", ProfileSelections: [new(resultNode.Node, 0)])));
        Expect<SourceFileChangedException>(() => MapDynamicProfileService.Sample(new(fixture.Map,
            sources.ContextToken, [], [vectorLine with { Feature = feature with { VectorRevision = new string('0', 64) } }],
            "map-vector-stale-revision", TargetSampleCount: 16, PlotTerrains: false, PlotResults: true,
            TerrainRequiresElevationResult: false, MapType: "Depth", ProfileSelections: [new(resultNode.Node, 0)])));
        string unattachedVectorPath = Path.Combine(Path.GetDirectoryName(fixture.ProjectPath)!, "Unattached profile.geojson");
        File.WriteAllBytes(unattachedVectorPath, vectorBefore);
        Expect<ArgumentException>(() => MapDynamicProfileService.Sample(new(fixture.Map,
            sources.ContextToken, [], [vectorLine with { Feature = feature with
                { VectorPath = unattachedVectorPath, VectorRevision = Hash(unattachedVectorPath) } }],
            "map-vector-not-in-map", TargetSampleCount: 16, PlotTerrains: false, PlotResults: true,
            TerrainRequiresElevationResult: false, MapType: "Depth", ProfileSelections: [new(resultNode.Node, 0)])));

        MapDynamicProfileSeries activeTerrain = lastLine.Series.Single(series => series.SourceKind == "Terrain");
        Check(activeTerrain.Samples[0] == 100
            && activeTerrain.Samples.Length == lastLine.SamplePoints.Length
            && !string.IsNullOrWhiteSpace(activeTerrain.SourceRevision),
            "The checked active-map terrain is sampled through its retained Terrain source and carries a dependency revision.");
        Expect<SourceFileChangedException>(() => MapDynamicProfileService.Sample(new(fixture.Map,
            new string('0', 64), [], [line], "line-snapshot-stale", TargetSampleCount: 16,
            PlotTerrains: false, PlotResults: true, TerrainRequiresElevationResult: false,
            MapType: "Depth", ProfileSelections: [new(resultNode.Node, 0)])));
        Expect<SourceFileChangedException>(() => MapDynamicProfileService.Sample(new(fixture.Map,
            sources.ContextToken, [], [line], "line-snapshot-linked-stale", TargetSampleCount: 16,
            PlotTerrains: false, PlotResults: true, TerrainRequiresElevationResult: false,
            MapType: "Depth", LinkedResults: linkedRequest with { ProjectXml = projectXml + " " })));

        MapDynamicProfileSeries maximumUnavailable = MapDynamicProfileService.Sample(new(fixture.Map,
            sources.ContextToken, [], [line], "line-snapshot-summary-max", TargetSampleCount: 16,
            PlotTerrains: false, PlotResults: true, TerrainRequiresElevationResult: false,
            MapType: "Depth", ProfileSelections: [new(resultNode.Node, LegacyOutputBlock.MaxProfileIndex)]))
            .Lines.Single().Series.Single(series => series.SourceKind == "Result");
        MapDynamicProfileSeries minimumUnavailable = MapDynamicProfileService.Sample(new(fixture.Map,
            sources.ContextToken, [], [line], "line-snapshot-summary-min", TargetSampleCount: 16,
            PlotTerrains: false, PlotResults: true, TerrainRequiresElevationResult: false,
            MapType: "Depth", ProfileSelections: [new(resultNode.Node, LegacyOutputBlock.MinProfileIndex)]))
            .Lines.Single().Series.Single(series => series.SourceKind == "Result");
        Check(maximumUnavailable.UnavailableReason?.Contains("non-Legacy", StringComparison.Ordinal) == true
            && maximumUnavailable.Samples.All(value => value is null)
            && minimumUnavailable.ProfileIndex == LegacyOutputBlock.MinProfileIndex
            && minimumUnavailable.UnavailableReason?.Contains("does not read Minimum", StringComparison.Ordinal) == true
            && minimumUnavailable.Samples.All(value => value is null),
            "Legacy Max/Min sentinels are never coerced to ordinary frames; this OutputBlock fixture reports unsupported summaries unavailable.");

        Check(File.ReadAllBytes(fixture.ProjectPath).SequenceEqual(projectBefore)
            && File.ReadAllBytes(fixture.VisualizationPath).SequenceEqual(visualizationBefore)
            && File.ReadAllBytes(fixture.ResultPath).SequenceEqual(resultBefore)
            && File.ReadAllBytes(fixture.TerrainPath).SequenceEqual(terrainBefore)
            && File.ReadAllBytes(vectorPath).SequenceEqual(vectorBefore),
            "Dynamic profile sampling leaves the project, .vis, Result HDF, terrain and vector source bytes unchanged.");
        ExportAcceptanceFixtureIfRequested(fixture, originalPoints, line, resultNode, vectorPath);
        Console.WriteLine("Dynamic profile source-line densification, active terrain/result sampling, profile-index changes, Depth no-data, terrain gate, stale-context rejection and read-only source checks passed.");
    }

    private static MapResultRenderChecks.Fixture AddActiveTerrainNode(MapResultRenderChecks.Fixture fixture)
    {
        XDocument visualization = XDocument.Load(fixture.VisualizationPath, LoadOptions.PreserveWhitespace);
        XElement map = visualization.Root!.Element("Maps")!.Elements("Map")
            .ElementAt(fixture.Map.MapIndex);
        XElement tree = map.Element("Tree") ?? throw new InvalidDataException("The map fixture has no tree.");
        XElement nodes = tree.Element("Nodes") ?? throw new InvalidDataException("The map fixture has no tree nodes.");
        nodes.Add(new XElement("Node", new XAttribute("Type", "Root"), new XAttribute("Name", "Terrains"),
            new XElement("Node", new XAttribute("Type", "Terrain"),
                new XAttribute("Name", "Render terrain"), new XAttribute("IsChecked", true))));
        visualization.Save(fixture.VisualizationPath, SaveOptions.DisableFormatting);

        string updatedRevision = Hash(fixture.VisualizationPath);
        return fixture with { Map = fixture.Map with { ExpectedVisualizationRevision = updatedRevision } };
    }

    private static MapResultRenderChecks.Fixture AddActiveVectorLayer(
        MapResultRenderChecks.Fixture fixture, out string vectorPath)
    {
        string directory = Path.GetDirectoryName(fixture.ProjectPath)!;
        vectorPath = Path.Combine(directory, "Profile source.geojson");
        File.WriteAllText(vectorPath, JsonSerializer.Serialize(new
        {
            type = "FeatureCollection",
            features = new[]
            {
                new
                {
                    type = "Feature",
                    id = "dynamic-profile-fixture",
                    properties = new { },
                    geometry = new
                    {
                        type = "LineString",
                        coordinates = new[] { new[] { 0.5, 0.5 }, new[] { 2.0, 0.5 } }
                    }
                }
            }
        }));

        XDocument visualization = XDocument.Load(fixture.VisualizationPath, LoadOptions.PreserveWhitespace);
        XElement map = visualization.Root!.Element("Maps")!.Elements("Map")
            .ElementAt(fixture.Map.MapIndex);
        XElement treeNodes = map.Element("Tree")?.Element("Nodes")
            ?? throw new InvalidDataException("The map fixture has no tree nodes.");
        XElement? mapLayers = treeNodes.Elements("Node")
            .FirstOrDefault(node => (string?)node.Attribute("Name") == "Map Layers");
        if (mapLayers is null)
        {
            mapLayers = new XElement("Node", new XAttribute("Type", "Root"), new XAttribute("Name", "Map Layers"));
            treeNodes.Add(mapLayers);
        }
        mapLayers.Add(new XElement("Node", new XAttribute("Type", "MapLayer"),
            new XAttribute("MapType", "PolylinesVector"), new XAttribute("Name", "Profile source"),
            new XAttribute("Filename", vectorPath), new XAttribute("FilenameRelative", Path.GetFileName(vectorPath)),
            new XAttribute("IsChecked", true)));
        visualization.Save(fixture.VisualizationPath, SaveOptions.DisableFormatting);
        string updatedRevision = Hash(fixture.VisualizationPath);
        return fixture with { Map = fixture.Map with { ExpectedVisualizationRevision = updatedRevision } };
    }

    private static string CoordinateSHA(IEnumerable<GeometryTopologyCoordinate> coordinates)
    {
        using IncrementalHash hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        hash.AppendData(System.Text.Encoding.UTF8.GetBytes("HECRAS-MAP-LINE-v1\0"));
        Span<byte> bytes = stackalloc byte[sizeof(ulong)];
        foreach (GeometryTopologyCoordinate coordinate in coordinates)
        {
            BinaryPrimitives.WriteUInt64BigEndian(bytes,
                unchecked((ulong)BitConverter.DoubleToInt64Bits(coordinate.X)));
            hash.AppendData(bytes);
            BinaryPrimitives.WriteUInt64BigEndian(bytes,
                unchecked((ulong)BitConverter.DoubleToInt64Bits(coordinate.Y)));
            hash.AppendData(bytes);
        }
        return Convert.ToHexString(hash.GetHashAndReset());
    }

    private static string Hash(string path)
    {
        using FileStream stream = File.OpenRead(path);
        return Convert.ToHexString(SHA256.HashData(stream));
    }

    private static void ExportAcceptanceFixtureIfRequested(MapResultRenderChecks.Fixture fixture,
        GeometryTopologyCoordinate[] points, MapDynamicProfileLine line, MapResultActiveNode resultNode,
        string vectorPath)
    {
        string? destination = Environment.GetEnvironmentVariable("HECRAS_DYNAMIC_PROFILE_ACCEPTANCE_DIRECTORY");
        if (string.IsNullOrWhiteSpace(destination)) return;
        string target = Path.GetFullPath(destination);
        string source = Path.GetFullPath(Path.GetDirectoryName(fixture.ProjectPath)!);
        StringComparison pathComparison = OperatingSystem.IsWindows()
            ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal;
        if (Directory.Exists(target) || File.Exists(target) || IsInside(target, source, pathComparison))
            throw new IOException("The dynamic-profile acceptance directory must not exist or be inside the source fixture.");

        Directory.CreateDirectory(target);
        foreach (string path in Directory.EnumerateFiles(source, "*", SearchOption.AllDirectories))
        {
            string relative = Path.GetRelativePath(source, path);
            string copy = Path.Combine(target, relative);
            Directory.CreateDirectory(Path.GetDirectoryName(copy)!);
            File.Copy(path, copy);
        }

        string Relative(string path) => Path.GetRelativePath(source, path).Replace('\\', '/');
        var manifest = new
        {
            provenance = "Retained Project.CreateNew, Result.PrepareResult, OutputBlock.CreateNew, MapTreeService.CreateMap, source terrain writers, and a deterministic saved GeoJSON line source. Stored values are fixture data, not solver output.",
            project = Relative(fixture.ProjectPath),
            visualization = Relative(fixture.VisualizationPath),
            results = new[] { Relative(fixture.ResultPath) },
            terrains = new[] { Relative(fixture.TerrainPath) },
            vectorSources = new[]
            {
                new
                {
                    path = Relative(vectorPath),
                    mapType = "PolylinesVector",
                    sourceRevision = Hash(vectorPath),
                    featureID = line.Id,
                    coordinateSHA = CoordinateSHA(points)
                }
            },
            distanceUnits = "ft",
            map = new
            {
                index = fixture.Map.MapIndex,
                name = fixture.Map.MapName,
                type = fixture.Map.MapType
            },
            lines = new[]
            {
                new
                {
                    id = line.Id,
                    points = points.Select(point => new { x = point.X, y = point.Y }).ToArray(),
                    feature = new
                    {
                        vectorPath = Relative(vectorPath),
                        vectorRevision = Hash(vectorPath),
                        featureID = line.Id,
                        coordinateSHA = CoordinateSHA(points)
                    }
                }
            },
            selectedResult = new
            {
                nodeKind = resultNode.NodeKind,
                nodeName = resultNode.Name,
                locator = new
                {
                    rootName = resultNode.Node.RootName,
                    nodeType = resultNode.Node.NodeType,
                    nodeName = resultNode.Node.NodeName,
                    nodePath = resultNode.Node.NodePath,
                    mapType = resultNode.Node.MapType
                },
                source = Relative(fixture.ResultPath),
                profileIndices = new[] { 0, 2 },
                resolveLocator = "Call map.resultSources using a newly computed project XML SHA and .vis revision, then resolve this node locator against the returned active nodes."
            }
        };
        File.WriteAllText(Path.Combine(target, "DYNAMIC_PROFILE_FIXTURE.json"),
            JsonSerializer.Serialize(manifest, new JsonSerializerOptions { WriteIndented = true }));
        File.WriteAllText(Path.Combine(target, "ACCEPTANCE.txt"),
            "This is a deterministic source-writer fixture for dynamic profile integration. Recompute current project XML and .vis revisions when loading it. It does not represent a solver run or solver validation.");

        static bool IsInside(string path, string parent, StringComparison comparison)
        {
            string normalizedParent = parent.TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
            return path.Equals(parent, comparison) || path.StartsWith(normalizedParent, comparison);
        }
    }

    private static void Check(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }

    private static void Expect<T>(Action action) where T : Exception
    {
        try { action(); }
        catch (T) { return; }
        throw new InvalidOperationException("Expected " + typeof(T).Name + ".");
    }
}
