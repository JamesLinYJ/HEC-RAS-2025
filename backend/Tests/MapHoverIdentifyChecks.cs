using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using Ras.Backend;
using Geospatial.GDALAssist;
using OSGeo.GDAL;
using Utility.Units;

/// <summary>
/// Exercises hover identify through the retained Result source resampler,
/// not through a rendered raster or sampled canvas color.
/// </summary>
internal static class MapHoverIdentifyChecks
{
    internal static async Task RunAsync()
    {
        using var directory = new TemporaryDirectory();
        MapResultRenderChecks.Fixture fixture = MapResultRenderChecks.CreateFixture(directory.FullName);
        byte[] projectBefore = File.ReadAllBytes(fixture.ProjectPath);
        byte[] visualizationBefore = File.ReadAllBytes(fixture.VisualizationPath);
        byte[] resultBefore = File.ReadAllBytes(fixture.ResultPath);
        byte[] terrainBefore = File.ReadAllBytes(fixture.TerrainPath);

        MapResultSourcesResult sources = MapResultChartService.Sources(new(fixture.Map, []));
        MapResultActiveNode resultNode = sources.ActiveNodes.Single(node => node.NodeKind == "Result");
        MapResultSelectionState selection = resultNode.Selections.Single();
        MapResultSourceChoice selected = selection.SelectedResult
            ?? throw new InvalidDataException("The exact hover fixture has no selected Result source.");
        var point = new MapHoverCoordinate(0.5, 0.5);
        var probe = new MapHoverCoordinate(0.5001, 0.5);

        async Task<(double Value, MapHoverIdentifyEntry Entry)> Identify(int profileIndex)
        {
            MapHoverIdentifyResult response = await MapHoverIdentifyService.Identify(
                new MapHoverIdentifyRequest(fixture.Map, sources.ContextToken, [],
                    $"hover-profile-{profileIndex}", point, probe, 0.0001,
                    [new MapDynamicProfileSelection(resultNode.Node, profileIndex)],
                    [new MapHoverLayerCapture(resultNode.Node, "result",
                        MapType: resultNode.SelectedMapType, ProfileIndex: profileIndex,
                        ResultSelections:
                        [
                            new MapHoverResultSelectionCapture(selection.SelectionIndex,
                                selected.ResultPath, selected.Revision)
                        ])]));
            MapHoverIdentifyEntry entry = response.Entries.Single();
            if (entry.Kind != "result" || entry.ProfileIndex != profileIndex ||
                entry.MapType != resultNode.SelectedMapType ||
                entry.SourcePath is null || entry.SourceRevision is null || entry.Value is null ||
                !MapSourceTestPaths.SameFile(entry.SourcePath, selected.ResultPath) ||
                !entry.SourceRevision.Equals(selected.Revision, StringComparison.OrdinalIgnoreCase) ||
                !double.TryParse(entry.Value, NumberStyles.Float, CultureInfo.InvariantCulture, out double value))
                throw new InvalidOperationException("Hover identify did not echo the exact Result/profile source capture.");

            MapDynamicProfileResult expected = MapDynamicProfileService.Sample(new MapDynamicProfileRequest(
                fixture.Map, sources.ContextToken, [],
                [new MapDynamicProfileLine($"expected-profile-{profileIndex}",
                    [new(point.X, point.Y), new(probe.X, probe.Y)])],
                $"expected-profile-{profileIndex}", TargetSampleCount: 1,
                PlotTerrains: false, PlotResults: true, TerrainRequiresElevationResult: false,
                MapType: "Depth", ProfileSelections: [new(resultNode.Node, profileIndex)]));
            double expectedValue = expected.Lines.Single().Series
                .Single(series => series.SourceKind == "Result")
                .Samples[0] ?? throw new InvalidDataException("The fixture Result has no value at the hover point.");
            if (Math.Abs(value - expectedValue) > 1e-9)
                throw new InvalidOperationException("Hover identify returned a value different from the source Result resampler.");
            return (value, entry);
        }

        (double first, _) = await Identify(0);
        (double last, _) = await Identify(2);
        if (!(last > first))
            throw new InvalidOperationException("The actual stored Result profiles did not produce distinct hover values.");
        if (!File.ReadAllBytes(fixture.ProjectPath).SequenceEqual(projectBefore) ||
            !File.ReadAllBytes(fixture.VisualizationPath).SequenceEqual(visualizationBefore) ||
            !File.ReadAllBytes(fixture.ResultPath).SequenceEqual(resultBefore) ||
            !File.ReadAllBytes(fixture.TerrainPath).SequenceEqual(terrainBefore))
            throw new InvalidOperationException("Hover identify modified project, map, Result, or terrain source bytes.");

        await CheckOrdinaryGeometryMesh(directory.FullName);
        await CheckSourceRaster(directory.FullName);
        Console.WriteLine("Map hover identify returns exact source-backed values for two retained Result profiles and leaves all source files byte-identical.");
    }

    private static async Task CheckOrdinaryGeometryMesh(string root)
    {
        string directoryPath = Path.Combine(root, "ordinary-geometry-mesh");
        Directory.CreateDirectory(directoryPath);
        MapResultRenderChecks.Fixture fixture = MapResultRenderChecks.CreateFixture(directoryPath);
        MapTreeSnapshot initialTree = MapTreeService.Load(fixture.Map);
        CatalogTreeNode[] initialNodes = Flatten(initialTree.Roots).ToArray();
        CatalogTreeNode initialGeometry = initialNodes.Single(node =>
            node.Locator is { RootName: "Geometries", NodeType: "Geometry", AssetID: { Length: > 0 } } &&
            node.Name == "Render geometry");
        CatalogTreeNodeLocator initialGeometryLocator = initialGeometry.Locator
            ?? throw new InvalidDataException("The ordinary Geometry fixture omitted its exact source locator.");
        string geometryPath = initialGeometryLocator.AssetID
            ?? throw new InvalidDataException("The ordinary Geometry fixture omitted its source path.");
        CatalogTreeNode initialFlowArea = initialNodes.Single(node =>
            node.Locator is { RootName: "Geometries", NodeType: "FlowAreaLayer",
                ParentGeometryAssetID: { } parentPath } &&
            MapSourceTestPaths.SameFile(parentPath, geometryPath));
        CatalogTreeNodeLocator initialFlowAreaLocator = initialFlowArea.Locator
            ?? throw new InvalidDataException("The ordinary FlowArea fixture omitted its exact map locator.");
        MapTreeMutationResult shown = MapTreeService.Perform(new MapTreeActionRequest(fixture.Map,
            "visibility", Node: initialFlowAreaLocator, Checked: true));
        MapTreeRequest map = fixture.Map with { ExpectedVisualizationRevision = shown.VisualizationRevision };
        CatalogTreeNode[] visibleNodes = Flatten(MapTreeService.Load(map).Roots).ToArray();
        CatalogTreeNode geometry = visibleNodes.Single(node =>
            node.Locator is { RootName: "Geometries", NodeType: "Geometry", AssetID: { } path } &&
            MapSourceTestPaths.SameFile(path, geometryPath));
        CatalogTreeNode flowArea = visibleNodes.Single(node =>
            node.Locator is { RootName: "Geometries", NodeType: "FlowAreaLayer",
                ParentGeometryAssetID: { } parentPath } &&
            MapSourceTestPaths.SameFile(parentPath, geometryPath));
        CatalogTreeNodeLocator geometryLocator = geometry.Locator
            ?? throw new InvalidDataException("The ordinary Geometry fixture omitted its exact map locator.");
        CatalogTreeNodeLocator flowAreaLocator = flowArea.Locator
            ?? throw new InvalidDataException("The ordinary FlowArea fixture omitted its exact map locator.");
        MapGeometrySnapshot geometrySource = await ModelEditorAdapter.LoadMapGeometryAsync(
            new MapGeometryRequest(map, geometryLocator, PageSize: 1,
                SkipTopologyPage: true, SkipCulvertsPage: true));
        MapGeometryFlowAreaSource sourceArea = geometrySource.FlowAreas?.Areas.Single()
            ?? throw new InvalidDataException("The ordinary Geometry fixture omitted its source FlowArea row.");
        MapResultSourcesResult resultSources = MapResultChartService.Sources(new(map, []));
        string emptySHA = Hash(Encoding.UTF8.GetBytes(string.Empty));
        var mesh = new MapHoverMeshCapture(flowAreaLocator, geometryLocator,
            sourceArea.ID, geometrySource.ContextToken, geometrySource.GeometryCanonicalPath,
            geometrySource.GeometryRevision, geometrySource.PlanNodes, null,
            new GeometryMeshModelRequest(geometrySource.GeometryCanonicalPath, "Geometry",
                map.ProjectPath, map.ProjectXml), "savedSource", string.Empty, emptySHA,
            null, emptySHA);
        var request = new MapHoverIdentifyRequest(map, resultSources.ContextToken, [],
            "hover-ordinary-geometry-mesh", new(0.5, 0.5), new(0.5001, 0.5), 0.0001,
            [], [new MapHoverLayerCapture(flowAreaLocator, "mesh", Mesh: mesh)]);
        byte[] projectBefore = File.ReadAllBytes(fixture.ProjectPath);
        byte[] visualizationBefore = File.ReadAllBytes(fixture.VisualizationPath);
        byte[] geometryBefore = File.ReadAllBytes(geometrySource.GeometryCanonicalPath);

        MapHoverIdentifyResult response = await MapHoverIdentifyService.Identify(request);
        MapHoverIdentifyEntry entry = response.Entries.Single();
        if (entry.Kind != "mesh" || entry.ValueType != "Cell" || entry.MeshIndex != 0 ||
            entry.ElementIndex != 0 || entry.Label != "Cell[0]" ||
            entry.SourcePath is null || !MapSourceTestPaths.SameFile(entry.SourcePath, geometrySource.GeometryCanonicalPath) ||
            entry.SourceRevision != geometrySource.GeometryRevision)
            throw new InvalidOperationException("Ordinary Geometry hover did not return the exact source Mesh cell hit and indices.");

        MapHoverMeshCapture staleMesh = mesh with { SourceRevision = new string('0', 64) };
        await ExpectAsync<SourceFileChangedException>(() => MapHoverIdentifyService.Identify(request with
        {
            RequestID = "hover-ordinary-geometry-mesh-stale",
            Layers = [new MapHoverLayerCapture(flowAreaLocator, "mesh", Mesh: staleMesh)]
        }));
        if (!File.ReadAllBytes(fixture.ProjectPath).SequenceEqual(projectBefore) ||
            !File.ReadAllBytes(fixture.VisualizationPath).SequenceEqual(visualizationBefore) ||
            !File.ReadAllBytes(geometrySource.GeometryCanonicalPath).SequenceEqual(geometryBefore))
            throw new InvalidOperationException("Ordinary Geometry hover or stale-capture rejection modified source files.");
    }

    private static async Task CheckSourceRaster(string root)
    {
        if (!GDALSetup.IsInitialized) GDALSetup.InitializeMultiplatform();
        string directoryPath = Path.Combine(root, "source-raster");
        Directory.CreateDirectory(directoryPath);
        MapResultRenderChecks.Fixture fixture = MapResultRenderChecks.CreateFixture(directoryPath);
        string rasterPath = Path.Combine(directoryPath, "Hover source.tif");
        const int width = 2, height = 2;
        const float noData = -9999f;
        float[] values = [11f, 22f, noData, 44f];
        using (var driver = Gdal.GetDriverByName("GTiff"))
        using (var dataset = driver.Create(rasterPath, width, height, 1, DataType.GDT_Float32, []))
        {
            dataset.SetGeoTransform([0, 1, 0, 2, 0, -1]);
            using var band = dataset.GetRasterBand(1);
            band.SetNoDataValue(noData);
            band.WriteRaster(0, 0, width, height, values, width, height, 0, 0);
            dataset.FlushCache();
        }
        MapRasterLayerInspectResult inspected = MapRasterLayerService.Inspect(new(rasterPath));
        if (inspected.MapLayerType != "SingleBandRasterMapLayer")
            throw new InvalidDataException("The source hover raster fixture did not inspect as a single-band raster.");
        var owner = new MapDocumentRequest(fixture.Map.ProjectPath, fixture.Map.ProjectXml,
            fixture.Map.ProjectXmlSHA, fixture.Map.ExpectedVisualizationRevision, fixture.Map.MapType,
            MapIndex: fixture.Map.MapIndex, MapName: fixture.Map.MapName, MapType: fixture.Map.MapType);
        MapDocumentMutationReceipt imported = MapTreeService.ImportRasterLayer(new(owner, rasterPath,
            inspected.SourceRevision, inspected.MapLayerType,
            Hash(File.ReadAllBytes(fixture.ProjectPath)), inspected.SourceCanonicalPath));
        MapTreeRequest map = fixture.Map with { ExpectedVisualizationRevision = imported.VisualizationRevision };
        CatalogTreeNode rasterNode = Flatten(MapTreeService.Load(map).Roots).Single(node =>
            node.Locator is { NodeType: "MapLayer", MapType: "SingleBandRasterMapLayer" } &&
            node.AssetID is { } path && MapSourceTestPaths.SameFile(path, rasterPath));
        CatalogTreeNodeLocator locator = rasterNode.Locator
            ?? throw new InvalidDataException("The source raster fixture omitted its exact map-node locator.");
        int[] nodePath = locator.NodePath
            ?? throw new InvalidDataException("The imported raster fixture omitted its serialized node path.");
        string visualizationPath = Path.ChangeExtension(fixture.ProjectPath, ".vis");
        var descriptor = new RasterMapSourceIdentity(
            $"vis-map-{map.MapIndex}-node-{string.Join('.', nodePath)}",
            map.ProjectPath, visualizationPath, map.ExpectedVisualizationRevision!, map.MapIndex,
            map.MapName, map.MapType, nodePath, locator.NodeName, locator.MapType!, locator.Filename,
            locator.FilenameRelative, inspected.SourceCanonicalPath, map.MapID, inspected.SourceRevision);
        MapResultSourcesResult resultSources = MapResultChartService.Sources(new(map, []));
        byte[] projectBefore = File.ReadAllBytes(fixture.ProjectPath);
        byte[] visualizationBefore = File.ReadAllBytes(visualizationPath);
        byte[] rasterBefore = File.ReadAllBytes(rasterPath);

        async Task<MapHoverIdentifyResult> Identify(string id, MapHoverCoordinate point,
            RasterMapSourceIdentity source) => await MapHoverIdentifyService.Identify(
                new MapHoverIdentifyRequest(map, resultSources.ContextToken, [], id, point,
                    new(point.X + 0.0001, point.Y), 0.0001, [],
                    [new MapHoverLayerCapture(locator, "raster", source.SourcePath,
                        source.SourceRevision, source.MapLayerType, RasterSource: source)]));

        MapHoverIdentifyEntry value = (await Identify("hover-raster-value", new(0.5, 1.5), descriptor))
            .Entries.Single();
        if (value.Kind != "raster" || value.ValueType != "number" || value.Value != "11" ||
            value.SourcePath is null || !MapSourceTestPaths.SameFile(value.SourcePath, rasterPath) ||
            value.SourceRevision != inspected.SourceRevision)
            throw new InvalidOperationException("Raster hover did not return the exact source sample value and revision.");

        MapHoverIdentifyResult missing = await Identify("hover-raster-nodata", new(0.5, 0.5), descriptor);
        if (missing.Entries.Length != 0)
            throw new InvalidOperationException("Raster hover exposed a synthetic value for a source NoData cell.");
        RasterMapSourceIdentity stale = descriptor with { SourceRevision = new string('0', 64) };
        await ExpectAsync<SourceFileChangedException>(() => Identify("hover-raster-stale", new(0.5, 1.5), stale));
        if (!File.ReadAllBytes(fixture.ProjectPath).SequenceEqual(projectBefore) ||
            !File.ReadAllBytes(visualizationPath).SequenceEqual(visualizationBefore) ||
            !File.ReadAllBytes(rasterPath).SequenceEqual(rasterBefore))
            throw new InvalidOperationException("Source raster hover or stale-capture rejection modified source files.");
    }

    private static IEnumerable<CatalogTreeNode> Flatten(IEnumerable<CatalogTreeNode> roots)
    {
        foreach (CatalogTreeNode node in roots)
        {
            yield return node;
            foreach (CatalogTreeNode child in Flatten(node.Children ?? [])) yield return child;
        }
    }

    private static string Hash(byte[] bytes) => Convert.ToHexString(SHA256.HashData(bytes));

    private static async Task ExpectAsync<TException>(Func<Task> action) where TException : Exception
    {
        try { await action(); }
        catch (TException) { return; }
        throw new InvalidOperationException($"Expected {typeof(TException).Name}.");
    }
}
