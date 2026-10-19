using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using Ras.Backend;
using Geospatial.GDALAssist;
using Geospatial.Vectors;
using OSGeo.GDAL;
using Ras.Layers;
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
        await CheckGdbSourceRaster(directory.FullName);
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

    private static async Task CheckGdbSourceRaster(string root)
    {
        if (!GDALSetup.IsInitialized) GDALSetup.InitializeMultiplatform();
        string fixtureDirectory = Path.Combine(root, "official-gdb-raster");
        Directory.CreateDirectory(fixtureDirectory);
        string gdbPath = GdbRasterHoverFixture.Extract(fixtureDirectory);
        GdbMapCatalogResponse catalog = GdbMapSourceService.Catalog(new(gdbPath));
        GdbRasterSubdatasetDescriptor[] catalogSubdatasets = catalog.RasterSubdatasets ?? [];
        if (catalog.Layers.Length != 0 || catalogSubdatasets.Length != 44 ||
            catalogSubdatasets.Select(item => item.Name).Distinct(StringComparer.Ordinal).Count() != 44 ||
            !MapHoverIdentifyService.SamePath(catalog.Source.SourcePath, gdbPath))
            throw new InvalidDataException("The official raster-only FileGDB catalog did not return all 44 exact raster subdatasets with an empty vector list.");

        (string LeafName, string DataType, string DisplayName)[] expectedRasterIdentities =
        [
            ("float32_lz77", "float32", "Raster float32_lz77 [20x20x1], 32 bits"),
            ("float64_lz77", "float64", "Raster float64_lz77 [20x20x1], 64 bits")
        ];
        GdbRasterSubdatasetDescriptor[] expectedSubdatasets = expectedRasterIdentities.Select(expected =>
            catalogSubdatasets.Single(item => item.ConnectionString.EndsWith(
                $":{expected.LeafName}", StringComparison.Ordinal))).ToArray();
        if (expectedSubdatasets.Length != expectedRasterIdentities.Length ||
            expectedSubdatasets.Where((item, index) =>
                item.Name != expectedRasterIdentities[index].DisplayName ||
                item.DataType != expectedRasterIdentities[index].DataType ||
                !item.CanRender || item.Status != "available" || item.Width != 20 || item.Height != 20 ||
                item.BandCount != 1 || item.ProjectionWKT is null || item.Extent is null ||
                item.NoDataValue is null).Any())
            throw new InvalidDataException("The embedded GDAL FileGDB fixture did not expose its two exact renderable raster subdatasets.");

        string projectPath = Path.Combine(fixtureDirectory, "gdb-hover.ras");
        DisposeProject(Project.CreateNew(projectPath, ProjectionDefinition.FromEPSG(32611)));
        string projectXml = File.ReadAllText(projectPath, Encoding.UTF8);
        string projectXmlSHA = Hash(Encoding.UTF8.GetBytes(projectXml));
        string projectRevision = Hash(File.ReadAllBytes(projectPath));
        const string mapID = "92e92225-93a5-4ed3-9d40-99e46748625e";
        MapDocumentMutationReceipt createdMap = MapTreeService.CreateMap(new MapDocumentRequest(
            projectPath, projectXml, projectXmlSHA, null, "Project", Name: "GDB hover", MapID: mapID));
        var importOwner = new MapDocumentRequest(projectPath, projectXml, projectXmlSHA,
            createdMap.VisualizationRevision, "Project", MapID: mapID,
            MapIndex: createdMap.MapIndex, MapName: createdMap.MapName, MapType: createdMap.MapType);
        MapDocumentMutationReceipt imported = MapTreeService.ImportGdbVector(new(
            importOwner, projectRevision, catalog.Source)).Receipt;
        MapTreeRequest map = new(projectPath, projectXml, projectXmlSHA, mapID,
            imported.MapIndex, imported.MapName, imported.MapType, imported.VisualizationRevision);
        CatalogTreeNode[] tree = Flatten(MapTreeService.Load(map).Roots).ToArray();
        GdbMapSourceIdentity source = catalog.Source;
        MapResultSourcesResult resultSources = MapResultChartService.Sources(new(map, []));
        byte[] projectBefore = File.ReadAllBytes(projectPath);
        byte[] visualizationBefore = File.ReadAllBytes(Path.ChangeExtension(projectPath, ".vis"));

        Projection sourceProjection = new WKTProjection(expectedSubdatasets[0].ProjectionWKT!);
        Projection targetProjection = new EPSGProjection(32611);
        Point ProjectPoint(double x, double y) => Projector.TransformPoint(sourceProjection,
            targetProjection, new Point(x, y));

        for (int rasterIndex = 0; rasterIndex < expectedRasterIdentities.Length; rasterIndex++)
        {
            (string name, string dataType, string displayName) = expectedRasterIdentities[rasterIndex];
            GdbRasterSubdatasetDescriptor subdataset = expectedSubdatasets[rasterIndex];
            CatalogTreeNode node = tree.Single(item => item.Locator is
                { NodeType: "MapLayer", MapType: "SingleBandRasterMapLayer", Filename: var filename } &&
                string.Equals(filename, subdataset.ConnectionString, StringComparison.Ordinal));
            CatalogTreeNodeLocator locator = node.Locator
                ?? throw new InvalidDataException("A GDAL FileGDB raster child omitted its exact saved locator.");
            if (node.Name != displayName || locator.NodeName != displayName ||
                !string.Equals(subdataset.DataType, dataType, StringComparison.Ordinal) ||
                !string.Equals(locator.Filename, subdataset.ConnectionString, StringComparison.Ordinal))
                throw new InvalidDataException("The saved raster node did not retain the exact GDAL subdataset connection string.");

            var identity = new GdbRasterSymbologyIdentity(map, locator, source);
            string[] nodePath = locator.NodePath?.Select(index => index.ToString(CultureInfo.InvariantCulture)).ToArray()
                ?? throw new InvalidDataException("The saved raster node omitted its serialized tree path.");
            var rasterSource = new RasterMapSourceIdentity(
                $"vis-map-{map.MapIndex}-node-{string.Join('.', nodePath)}", map.ProjectPath,
                Path.ChangeExtension(map.ProjectPath, ".vis"), map.ExpectedVisualizationRevision!,
                map.MapIndex, map.MapName, map.MapType, locator.NodePath!, locator.NodeName,
                "SingleBandRasterMapLayer", locator.Filename, locator.FilenameRelative,
                source.SourcePath, map.MapID, source.Revision, identity);

            async Task<MapHoverIdentifyResult> Identify(string id, Point point,
                RasterMapSourceIdentity capturedSource) => await MapHoverIdentifyService.Identify(
                new MapHoverIdentifyRequest(map, resultSources.ContextToken, [], id,
                    new(point.X, point.Y), new(point.X + 0.00001, point.Y), 0.00001, [],
                    [new MapHoverLayerCapture(locator, "raster", source.SourcePath, source.Revision,
                        "SingleBandRasterMapLayer", RasterSource: capturedSource)]));

            MapHoverIdentifyEntry value = (await Identify("hover-gdb-" + dataType,
                ProjectPoint(440750, 3751290), rasterSource)).Entries.Single();
            if (value.Kind != "raster" || value.ValueType != "number" || value.Value != "107" ||
                value.MapType != "SingleBandRasterMapLayer" || value.SourcePath is null ||
                !MapHoverIdentifyService.SamePath(value.SourcePath, source.SourcePath) ||
                !value.SourceRevision!.Equals(source.Revision, StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException($"GDB {dataType} hover did not return the expected true source value and full directory revision.");

            MapHoverIdentifyEntry secondValue = (await Identify("hover-gdb-second-" + dataType,
                ProjectPoint(440810, 3751290), rasterSource)).Entries.Single();
            if (secondValue.Value != "123")
                throw new InvalidOperationException($"GDB {dataType} hover sampled a value other than the official fixture's second known point.");

            MapHoverIdentifyResult outside = await Identify("hover-gdb-outside-" + dataType,
                ProjectPoint(440650, 3751290), rasterSource);
            if (outside.Entries.Length != 0)
                throw new InvalidOperationException($"GDB {dataType} hover fabricated a value beyond the raster extent.");

            GdbRasterSymbologyIdentity staleIdentity = identity with
            {
                Source = source with { Revision = new string('0', 64) }
            };
            RasterMapSourceIdentity staleSource = rasterSource with
            {
                SourceRevision = staleIdentity.Source.Revision,
                GdbSource = staleIdentity
            };
            await ExpectAsync<SourceFileChangedException>(() => Identify("hover-gdb-stale-" + dataType,
                ProjectPoint(440750, 3751290), staleSource));
        }

        GdbMapSourceService.VerifySource(source);
        if (!File.ReadAllBytes(projectPath).SequenceEqual(projectBefore) ||
            !File.ReadAllBytes(Path.ChangeExtension(projectPath, ".vis")).SequenceEqual(visualizationBefore))
            throw new InvalidOperationException("GDB raster hover changed the project or visualization bytes.");
    }

    private static void DisposeProject(Project project)
    {
        foreach (CoreLayerBase layer in project.Plans.Cast<CoreLayerBase>().Concat(project.Geometries)
                     .Concat(project.Terrains).Concat(project.BoundaryConditions).Concat(project.NValues)
                     .Concat(project.ClassificationLayers))
            layer.Dispose();
        foreach (Result result in project.Results) result.Dispose();
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
