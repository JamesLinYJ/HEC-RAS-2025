using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Xml.Linq;
using Geospatial.GDALAssist;
using Geospatial.Rasters;
using Geospatial.Rasters.Classifications;
using Geospatial.Rendering;
using Geospatial.Rendering.Layers;
using Geospatial.Vectors;
using OSGeo.GDAL;
using Ras.Backend;
using Ras.Layers;
using Ras.Layers.Classifiers;
using Ras.Layers.Terrains;
using Utility.Units;

/// <summary>
/// Exercises viewport rendering through the exact saved Geometry-map rows and
/// source associations. All source rasters and HDF files are real temporary
/// files produced with the retained project and raster APIs.
/// </summary>
internal static class AssociatedMapLayersChecks
{
    private const int PixelWidth = 32;
    private const int PixelHeight = 24;
    private static readonly MapGeometryViewport Viewport = new(0, 0, 16, 16);

    internal static void Run()
    {
        GDALSetup.InitializeMultiplatform();
        using var directory = new TemporaryDirectory();
        Fixture fixture = CreateFixture(directory.FullName);

        byte[] projectBytes = File.ReadAllBytes(fixture.ProjectPath);
        byte[] visualizationBytes = File.ReadAllBytes(fixture.VisualizationPath);
        Dictionary<string, byte[]> sourceBytes = fixture.SourcePaths.ToDictionary(
            path => path, File.ReadAllBytes, PathComparer);

        AssociatedMapLayersRequest request = Request(fixture, fixture.AssociationLocators);
        AssociatedMapLayersSnapshot snapshot = AssociatedMapLayersService.Load(request);
        Check(snapshot.MapID == fixture.Map.MapID && snapshot.MapIndex == fixture.Map.MapIndex &&
              snapshot.MapName == fixture.Map.MapName && snapshot.MapType == "Geometry" &&
              snapshot.Viewport == Viewport && snapshot.ContextToken.Length == 64,
            "The preview response retains the exact saved map identity and requested viewport token.");
        Check(snapshot.ProjectCanonicalPath == MapSourceTestPaths.Physical(fixture.ProjectPath) &&
              snapshot.ProjectRevision == Hash(projectBytes) && snapshot.ProjectXmlSHA == fixture.ProjectXmlSHA,
            "The snapshot captures the physical project path, on-disk revision, and separate unsaved XML draft revision.");
        Check(snapshot.VisualizationRevision == Hash(visualizationBytes),
            "The response is bound to the saved Geometry map's exact .vis revision.");

        AssociatedMapLayerSnapshot terrain = Layer(snapshot, "Terrain");
        AssociatedMapLayerSnapshot nvalue = Layer(snapshot, "NValue");
        AssociatedMapLayerSnapshot classification = Layer(snapshot, "Classification");
        Check(terrain.PlotRasterTileOutlines == false && nvalue.PlotRasterTileOutlines == false &&
              classification.PlotRasterTileOutlines is null,
            "Raster renderer options are explicit for Terrain/N-value rows and absent for Classification.");
        Check(terrain.SourceExtent == new MapGeometryViewport(0, 0, 16, 16) &&
              nvalue.SourceExtent == new MapGeometryViewport(0, 0, 16, 16) &&
              classification.SourceExtent == new MapGeometryViewport(0, 0, 16, 16),
            "Each association returns its real finite source extent separately from the requested pixel viewport.");
        CheckTerrainHillshade(fixture, terrain);
        foreach (AssociatedMapLayerSnapshot layer in new[] { terrain, nvalue, classification })
        {
            Check(layer.Status == "available" && layer.IsChecked && layer.EffectiveVisible &&
                  layer.Width == PixelWidth && layer.Height == PixelHeight &&
                  layer.Rgba.Length == PixelWidth * PixelHeight * 4 &&
                  layer.Rgba.Where((_, index) => index % 4 == 3).Any(alpha => alpha != 0) &&
                  layer.Legend.Length > 0,
                $"The actual {layer.Kind} association returns visible viewport pixels and source legend values.");
            Check(layer.GeometryNodes.Select(node => node.NodeName).SequenceEqual(
                    ["R19 Shared Geometry A", "R19 Shared Geometry B"]) &&
                  layer.GeometryNodes.All(node => node.RootName == "Focused Geometries"),
                $"The {layer.Kind} row maps to both exact selected source Geometry objects in source order.");
            Check(layer.Revision == Hash(File.ReadAllBytes(layer.AssetPath)) &&
                  layer.Dependencies.Any(dependency => dependency.Role == "source-hdf" &&
                      dependency.Path == layer.AssetPath && dependency.Revision == layer.Revision) &&
                  layer.Dependencies.Where(dependency => dependency.Revision != "missing")
                      .All(dependency => dependency.Revision == Hash(File.ReadAllBytes(dependency.Path))),
                $"The {layer.Kind} response revisions equal direct SHA-256 reads of every retained dependency.");
            Check(layer.GeometryNodes.All(geometry => layer.Dependencies.Any(dependency =>
                      dependency.Role == "geometry-hdf" &&
                      MapSourceTestPaths.SameFile(dependency.Path, geometry.AssetID!) &&
                      dependency.Revision == Hash(File.ReadAllBytes(dependency.Path)))),
                $"The {layer.Kind} response exposes and hashes each selected source Geometry HDF.");
        }
        Check(terrain.Dependencies.Any(dependency => dependency.Role == "terrain-input-raster" &&
                  dependency.Revision == Hash(File.ReadAllBytes(dependency.Path))) &&
              classification.Dependencies.Any(dependency => dependency.Role == "classification-input-raster" &&
                  dependency.Revision == Hash(File.ReadAllBytes(dependency.Path))) &&
              nvalue.Dependencies.Any(dependency => dependency.Role == "classification-source-hdf" &&
                  MapSourceTestPaths.SameFile(dependency.Path, classification.AssetPath) &&
                  dependency.Revision == Hash(File.ReadAllBytes(dependency.Path))) &&
              nvalue.Dependencies.Any(dependency => dependency.Role == "classification-input-raster" &&
                  dependency.Revision == Hash(File.ReadAllBytes(dependency.Path))),
            "Terrain and classification TIFFs plus the N-value's associated Classification HDF are explicit source dependencies.");

        CatalogTreeNodeLocator terrainLocator = fixture.AssociationLocators.Single(locator =>
            locator.AssociationKind == "Terrain");
        AssociatedMapLayerRasterRuntimeOption outlines = new(terrainLocator, terrain.AssetPath,
            PlotRasterTileOutlines: true);
        AssociatedMapLayersSnapshot outlined = AssociatedMapLayersService.Load(request with
        {
            RasterRuntimeOptions = [outlines]
        });
        Check(Layer(outlined, "Terrain").PlotRasterTileOutlines == true &&
              Layer(outlined, "NValue").PlotRasterTileOutlines == false &&
              Layer(outlined, "Classification").PlotRasterTileOutlines is null &&
              outlined.ContextToken != snapshot.ContextToken,
            "The actual source RasterRenderLayer receives the selected exact Terrain option, and its render context token changes with the option.");
        Expect<SourceFileChangedException>(() => AssociatedMapLayersService.Load(request with
        {
            RasterRuntimeOptions = [outlines with { AssetPath = fixture.NValuePath }]
        }));
        Expect<ArgumentException>(() => AssociatedMapLayersService.Load(request with
        {
            RasterRuntimeOptions = [new AssociatedMapLayerRasterRuntimeOption(
                fixture.AssociationLocators.Single(locator => locator.AssociationKind == "Classification"),
                fixture.ClassificationPath, true)]
        }));

        // Source categories use explicit NLCD colors; other nonzero IDs
        // use ColorMap's retained deterministic fallback. Only NoData (0)
        // is transparent. All samples use the same map/source CRS and grid.
        AssociatedMapLayerLegend unknownLegend = classification.Legend.Single(item => item.Label == "Unmapped Class");
        int unknownID = int.Parse(unknownLegend.Value, System.Globalization.CultureInfo.InvariantCulture);
        int[] unknownArgb = [0];
        new ColorMap<int>(0).ParallelPaint(new int[] { unknownID }, unknownArgb);
        uint unknownColor = unchecked((uint)unknownArgb[0]);
        byte[] unknownRgba = [(byte)(unknownColor >> 16), (byte)(unknownColor >> 8),
            (byte)unknownColor, (byte)(unknownColor >> 24)];
        var openWater = ColorPalettes.NLCD.Colors[ColorPalettes.NLCDCategories.IndexOf(11)];
        byte[] openWaterRgba = [openWater.R, openWater.G, openWater.B, openWater.A];
        Check(classification.Status == "available" &&
              Enumerable.Range(0, PixelHeight).All(row =>
                  classification.Rgba.AsSpan(row * PixelWidth * 4, 4).SequenceEqual(openWaterRgba) &&
                  classification.Rgba.AsSpan((row * PixelWidth + PixelWidth / 2) * 4, 4).SequenceEqual(unknownRgba) &&
                  classification.Rgba[(row * PixelWidth + PixelWidth - 1) * 4 + 3] == 0) &&
              unknownLegend.Alpha == unknownRgba[3] && unknownLegend.Alpha > 0 &&
              classification.Legend.Any(item => item.Value == "0" && item.Alpha == 0),
            "Actual classification samples preserve standard NLCD colors, deterministic nonzero fallback colors, and transparent NoData. " +
            JsonSerializer.Serialize(new { classification.Status, classification.Legend }));

        AssociatedMapLayersSnapshot offscreen = AssociatedMapLayersService.Load(request with
        {
            Viewport = new MapGeometryViewport(24, 24, 40, 40),
            ContextToken = null
        });
        Check(offscreen.Layers.All(layer => layer.Status == "empty" && layer.Rgba.Length == 0) &&
              offscreen.Layers.All(layer => layer.SourceExtent == new MapGeometryViewport(0, 0, 16, 16)),
            "A source extent remains available for camera fitting when the current viewport contains no source pixels.");

        byte[] originalNValue = File.ReadAllBytes(fixture.NValuePath);
        Project unsupportedNValueProject = new(fixture.ProjectPath);
        try
        {
            NValueLayer unsupportedNValue = unsupportedNValueProject.NValues.Single(item =>
                MapSourceTestPaths.SameFile(item.Filename, fixture.NValuePath));
            unsupportedNValue.Mode = NValueSource.ImportedRaster;
            unsupportedNValue.Save();
        }
        finally
        {
            Dispose(unsupportedNValueProject);
        }
        try
        {
            AssociatedMapLayersSnapshot unsupportedNValueSnapshot = AssociatedMapLayersService.Load(
                Request(fixture, fixture.AssociationLocators));
            Check(Layer(unsupportedNValueSnapshot, "NValue") is
                    { Status: "unavailable", SourceExtent: null, Rgba.Length: 0 } &&
                  Layer(unsupportedNValueSnapshot, "Terrain").Status == "available" &&
                  Layer(unsupportedNValueSnapshot, "Classification").Status == "available",
                "An unsupported Imported Raster N-value returns explicit unavailable state without breaking other associated layers or reading a fake source extent.");
        }
        finally
        {
            File.WriteAllBytes(fixture.NValuePath, originalNValue);
        }

        // Same display name with a different source path cannot resolve to the
        // selected map row, and a captured token cannot cross a source-raster change.
        var wrongAssetLocator = terrainLocator with
        {
            AssociationAssetID = fixture.ClassificationPath
        };
        Expect<SourceFileChangedException>(() => AssociatedMapLayersService.Load(
            Request(fixture, [wrongAssetLocator, .. fixture.AssociationLocators.Where(locator => locator != terrainLocator)])));

        byte[] originalTerrainRaster = File.ReadAllBytes(fixture.TerrainRasterPath);
        using (var dataset = Gdal.Open(fixture.TerrainRasterPath, Access.GA_Update))
        using (var band = dataset.GetRasterBand(1))
            band.Fill(99, 0);
        try
        {
            Expect<SourceFileChangedException>(() => AssociatedMapLayersService.Load(
                Request(fixture, fixture.AssociationLocators, snapshot.ContextToken)));
        }
        finally
        {
            File.WriteAllBytes(fixture.TerrainRasterPath, originalTerrainRaster);
        }

        byte[] originalGeometry = File.ReadAllBytes(fixture.GeometryAPath);
        File.WriteAllBytes(fixture.GeometryAPath, [.. originalGeometry, (byte)0]);
        try
        {
            Expect<SourceFileChangedException>(() => AssociatedMapLayersService.Load(
                Request(fixture, fixture.AssociationLocators, snapshot.ContextToken)));
        }
        finally
        {
            File.WriteAllBytes(fixture.GeometryAPath, originalGeometry);
        }

        // The source checkbox is persisted by the map-tree service. Rendering
        // reports hidden without returning a transparent-looking success image.
        fixture = SetAssociationVisibility(fixture, "Terrain", false);
        AssociatedMapLayersSnapshot hiddenSnapshot = AssociatedMapLayersService.Load(
            Request(fixture, fixture.AssociationLocators));
        AssociatedMapLayerSnapshot hiddenTerrain = Layer(hiddenSnapshot, "Terrain");
        Check(hiddenTerrain.Status == "hidden" && !hiddenTerrain.EffectiveVisible &&
              hiddenTerrain.Rgba.Length == 0 && hiddenTerrain.Width == PixelWidth &&
              hiddenTerrain.Height == PixelHeight,
            "An unchecked source association reports hidden and returns no raster bytes.");
        Expect<SourceFileChangedException>(() => AssociatedMapLayersService.Load(
            Request(fixture, fixture.AssociationLocators, snapshot.ContextToken)));

        fixture = SetAssociationVisibility(fixture, "Terrain", true);
        AssociatedMapLayersSnapshot finalSnapshot = AssociatedMapLayersService.Load(
            Request(fixture, fixture.AssociationLocators));
        byte[] finalVisualizationBytes = File.ReadAllBytes(fixture.VisualizationPath);
        Check(finalSnapshot.Layers.All(layer => layer.Status == "available" &&
                  layer.Rgba.Length == PixelWidth * PixelHeight * 4),
            "The fixture's final saved map state has all three source associations enabled for native acceptance.");

        Check(File.ReadAllBytes(fixture.ProjectPath).SequenceEqual(projectBytes) &&
              File.ReadAllBytes(fixture.VisualizationPath).SequenceEqual(finalVisualizationBytes) &&
              fixture.SourcePaths.All(path => File.ReadAllBytes(path).SequenceEqual(sourceBytes[path])),
            "Viewport reads preserve the project XML, source map file, all HDF files, and all external TIFF inputs.");
        CheckResultOwnerAlias(directory.FullName);
        ExportAcceptanceFixture(directory.FullName, fixture);
        Console.WriteLine("Saved Geometry-map associated Terrain, NValue and Classification rendering preserved exact source identity, revisions, visibility and source bytes.");
    }

    private static void CheckResultOwnerAlias(string root)
    {
        string fixtureDirectory = Path.Combine(root, "result-owner-alias");
        Directory.CreateDirectory(fixtureDirectory);
        MapResultRenderChecks.Fixture fixture = MapResultRenderChecks.CreateFixture(fixtureDirectory,
            velocityVariesByProfile: true);
        string resultPath = fixture.ResultPath;
        string resultRevision = Hash(File.ReadAllBytes(resultPath));
        string projectXml = File.ReadAllText(fixture.ProjectPath);
        string projectXmlSHA = Hash(Encoding.UTF8.GetBytes(projectXml));
        string? visualizationRevision = File.Exists(fixture.VisualizationPath)
            ? Hash(File.ReadAllBytes(fixture.VisualizationPath)) : null;
        string geometryPath;
        string planName;
        using (Result result = Result.TryLoad(resultPath, out Result? loaded) && loaded is not null
                   ? loaded
                   : throw new InvalidDataException("Could not reopen the Result for the associated-owner alias check."))
        {
            planName = result.Plan?.Name
                ?? throw new InvalidDataException("The associated-owner alias Result has no Plan identity.");
        }
        Project sourceProject = new(fixture.ProjectPath);
        try
        {
            Geometry[] projectGeometries = sourceProject.Geometries.ToArray();
            Check(projectGeometries.Length == 1,
                "The Result owner alias fixture has one project-owned Geometry source.");
            string projectGeometryFilename = projectGeometries[0].Filename;
            geometryPath = Path.GetFullPath(Path.IsPathRooted(projectGeometryFilename)
                ? projectGeometryFilename
                : Path.Combine(sourceProject.ProjectDirectory, projectGeometryFilename));
        }
        finally
        {
            Dispose(sourceProject);
        }

        MapDocumentMutationReceipt created = MapTreeService.CreateMap(new MapDocumentRequest(
            fixture.ProjectPath, projectXml, projectXmlSHA, visualizationRevision, "Geometry",
            Name: "R37 Result owner alias map", InitialGeometryPath: geometryPath,
            InitialGeometryRevision: Hash(File.ReadAllBytes(geometryPath))));
        var map = new MapTreeRequest(fixture.ProjectPath, projectXml, projectXmlSHA,
            "r37-result-owner-alias", created.MapIndex, created.MapName, created.MapType,
            created.VisualizationRevision);
        MapTreeMutationResult added = MapTreeService.Perform(new MapTreeActionRequest(map,
            "addResult", SourcePath: resultPath, SourceRevision: resultRevision));
        map = map with { ExpectedVisualizationRevision = added.VisualizationRevision };

        XDocument visualization = XDocument.Load(fixture.VisualizationPath, LoadOptions.PreserveWhitespace);
        XElement serializedMap = visualization.Root!.Element("Maps")!.Elements("Map")
            .ElementAt(map.MapIndex);
        XElement layersRoot = serializedMap.Element("Tree")!.Element("Nodes")!.Elements("Node")
            .Single(node => (string?)node.Attribute("Name") == "Layers");
        XElement group = layersRoot.Elements("Node").Single(node =>
            (string?)node.Attribute("Type") == "MultiResult" &&
            string.Equals((string?)node.Attribute("Name"), planName, StringComparison.Ordinal));
        group.SetAttributeValue("SelectedMapType", "Depth");
        group.SetAttributeValue("ProfileIndex", 0);
        group.AddBeforeSelf(new XElement("Node",
            new XAttribute("Type", "Result"),
            new XAttribute("Name", Path.GetFileNameWithoutExtension(resultPath)),
            new XAttribute("IsChecked", true),
            new XAttribute("SelectedMapType", "Depth"),
            new XAttribute("ProfileIndex", 0)));
        visualization.Save(fixture.VisualizationPath, SaveOptions.DisableFormatting);
        map = map with { ExpectedVisualizationRevision = Hash(File.ReadAllBytes(fixture.VisualizationPath)) };

        MapResultSourcesResult sources = MapResultChartService.Sources(new(map, []));
        MapResultActiveNode standalone = sources.ActiveNodes.Single(node => node.NodeKind == "Result");
        MapResultActiveNode multiResult = sources.ActiveNodes.Single(node => node.NodeKind == "MultiResult");
        MapResultSourceChoice selected = multiResult.Selections.Single(selection => selection.SelectionIndex == 0)
            .SelectedResult ?? throw new InvalidDataException("The alias MultiResult has no selected Result.");
        Check(Array.IndexOf(sources.ActiveNodes, standalone) < Array.IndexOf(sources.ActiveNodes, multiResult) &&
              MapSourceTestPaths.SameFile(standalone.Selections.Single().SelectedResult!.ResultPath, resultPath) &&
              MapSourceTestPaths.SameFile(selected.ResultPath, resultPath) &&
              selected.Revision.Equals(resultRevision, StringComparison.OrdinalIgnoreCase),
            "The same exact Result is active first through a standalone row and also through MultiResult slot zero.");

        MapTreeSnapshot tree = MapTreeService.Load(map);
        CatalogTreeNode groupRow = Walk(tree.Roots).Single(node => node.Locator is
            { RootName: "Layers", NodeType: "MultiResult" } locator &&
            string.Equals(locator.NodeName, planName, StringComparison.Ordinal));
        CatalogTreeNode terrainRow = FindResultTerrain(tree.Roots, planName, resultPath, resultRevision);
        if (terrainRow.Checked != "checked")
        {
            MapTreeMutationResult shown = MapTreeService.Perform(new MapTreeActionRequest(map,
                "visibility", Node: terrainRow.Locator, Checked: true));
            map = map with { ExpectedVisualizationRevision = shown.VisualizationRevision };
            sources = MapResultChartService.Sources(new(map, []));
            multiResult = sources.ActiveNodes.Single(node => node.NodeKind == "MultiResult");
            selected = multiResult.Selections.Single(selection => selection.SelectionIndex == 0)
                .SelectedResult ?? throw new InvalidDataException("The visible alias MultiResult lost its selection.");
            tree = MapTreeService.Load(map);
            groupRow = Walk(tree.Roots).Single(node => node.Locator is
                { RootName: "Layers", NodeType: "MultiResult" } locator &&
                string.Equals(locator.NodeName, planName, StringComparison.Ordinal));
            terrainRow = FindResultTerrain(tree.Roots, planName, resultPath, resultRevision);
        }

        MapResultGeometryOwner owner = new(groupRow.Locator!, sources.ContextToken,
            null, 0, selected.ResultPath, selected.Revision);
        byte[] projectBytes = File.ReadAllBytes(fixture.ProjectPath);
        byte[] visualizationBytes = File.ReadAllBytes(fixture.VisualizationPath);
        byte[] resultBytes = File.ReadAllBytes(resultPath);
        AssociatedMapLayersSnapshot rendered = AssociatedMapLayersService.Load(new(
            map, [], [terrainRow.Locator!], new MapGeometryViewport(0, 0, 1, 1),
            PixelWidth, PixelHeight, ResultOwners: [owner]));
        AssociatedMapLayerSnapshot layer = rendered.Layers.Single();
        Check(layer.Status == "available" && layer.EffectiveVisible &&
              layer.Rgba.Length == PixelWidth * PixelHeight * 4 &&
              layer.ResultOwners is { Length: 1 } owners &&
              owners[0].SelectionIndex == 0 &&
              owners[0].ResultNode.NodeType == "MultiResult" &&
              owners[0].ResultNode.NodePath is { } ownerPath &&
              groupRow.Locator!.NodePath is { } groupPath && ownerPath.SequenceEqual(groupPath) &&
              MapSourceTestPaths.SameFile(owners[0].SelectedResultPath, resultPath) &&
              owners[0].SelectedResultRevision.Equals(resultRevision, StringComparison.OrdinalIgnoreCase) &&
              layer.Dependencies.Any(dependency => dependency.Role == "result-hdf" &&
                  MapSourceTestPaths.SameFile(dependency.Path, resultPath) &&
                  dependency.Revision.Equals(resultRevision, StringComparison.OrdinalIgnoreCase)),
            "Associated Terrain resolves slot-zero MultiResult ownership even when the deduplicated context representative is the earlier standalone Result row.");
        Expect<SourceFileChangedException>(() => AssociatedMapLayersService.Load(new(
            map, [], [terrainRow.Locator!], new MapGeometryViewport(0, 0, 1, 1),
            PixelWidth, PixelHeight, ResultOwners: [owner with
            { SelectedResultRevision = new string('0', 64) }])));
        Check(File.ReadAllBytes(fixture.ProjectPath).SequenceEqual(projectBytes) &&
              File.ReadAllBytes(fixture.VisualizationPath).SequenceEqual(visualizationBytes) &&
              File.ReadAllBytes(resultPath).SequenceEqual(resultBytes),
            "The standalone/MultiResult owner alias render preserves project, visualization and Result HDF bytes.");
    }

    private static CatalogTreeNode FindResultTerrain(IEnumerable<CatalogTreeNode> roots,
        string planName, string resultPath, string resultRevision) => Walk(roots).Single(node =>
        node.Locator is { NodeType: "Terrain", ParentResultNodeType: "MultiResult" } locator &&
        string.Equals(locator.ParentResultNodeName, planName, StringComparison.Ordinal) &&
        locator.ParentResultAssetID is { } parentPath && MapSourceTestPaths.SameFile(parentPath, resultPath) &&
        locator.ParentResultRevision is { } parentRevision &&
        parentRevision.Equals(resultRevision, StringComparison.OrdinalIgnoreCase));

    private static Fixture CreateFixture(string root)
    {
        string projectPath = Path.Combine(root, "Associated Map Layers.ras");
        Project project = Project.CreateNew(projectPath, UnitSystem.SI);
        string terrainRasterPath;
        string classificationRasterPath;
        string terrainPath;
        string nvaluePath;
        string classificationPath;
        string geometryAPath;
        string geometryBPath;
        try
        {
            Terrain terrain = project.AddNewTerrain("R19 Shared Terrain");
            terrainRasterPath = Path.Combine(terrain.SourceDirectory, "elevation.tif");
            CreateFloatRaster(terrainRasterPath, 51.5f);
            terrain.Add(RasterTerrainInput.CreateAndScan(terrain, terrainRasterPath));

            ClassificationLayer classification = project.AddNewClassification("R19 Shared Classification");
            classificationRasterPath = Path.Combine(classification.SourceDirectory, "land-cover.tif");
            CreateClassificationRaster(classificationRasterPath);
            var classes = new Classification();
            classes.Set(11, "Open Water");
            classes.Set(99, "Unmapped Class");
            classification.AddNewRasterLayer(classificationRasterPath, classes);

            NValueLayer nvalue = project.AddNewNValueLayer("R19 Shared NValue");
            nvalue.SetTrackClassificationLayer(classification);
            nvalue.InterpretationTable.Set("Open Water", 0.035f);

            Geometry first = project.AddNewGeometry("R19 Shared Geometry A", terrain, nvalue);
            Geometry second = project.AddNewGeometry("R19 Shared Geometry B", terrain, nvalue);
            terrainPath = terrain.Filename;
            nvaluePath = nvalue.Filename;
            classificationPath = classification.Filename;
            geometryAPath = first.Filename;
            geometryBPath = second.Filename;

            terrain.Save();
            classification.Save();
            nvalue.Save();
            first.Save();
            second.Save();
            project.Save();
        }
        finally
        {
            Dispose(project);
        }

        string projectXml = DraftProjectXml(projectPath);
        string projectXmlSHA = Hash(Encoding.UTF8.GetBytes(projectXml));
        byte[] sourceVisualization = File.Exists(Path.ChangeExtension(projectPath, ".vis"))
            ? File.ReadAllBytes(Path.ChangeExtension(projectPath, ".vis")) : [];
        MapDocumentMutationReceipt mapReceipt = MapTreeService.CreateMap(new MapDocumentRequest(
            projectPath, projectXml, projectXmlSHA, sourceVisualization.Length == 0 ? null : Hash(sourceVisualization),
            "Geometry", Name: "R19 Associated Geometry Map", InitialGeometryPath: geometryAPath,
            InitialGeometryRevision: Hash(File.ReadAllBytes(geometryAPath))));
        var map = new MapTreeRequest(projectPath, projectXml, projectXmlSHA,
            "r19-associated-geometry-map", mapReceipt.MapIndex, mapReceipt.MapName,
            mapReceipt.MapType, mapReceipt.VisualizationRevision);
        MapTreeMutationResult focusedSecond = MapTreeService.Perform(new MapTreeActionRequest(
            map, "focusGeometry", SourcePath: geometryBPath,
            SourceRevision: Hash(File.ReadAllBytes(geometryBPath))));
        map = map with { ExpectedVisualizationRevision = focusedSecond.VisualizationRevision };

        CatalogTreeNode[] roots = MapTreeService.Load(map).Roots;
        CatalogTreeNode[] geometries = [
            FindGeometry(roots, geometryAPath, "R19 Shared Geometry A"),
            FindGeometry(roots, geometryBPath, "R19 Shared Geometry B")
        ];
        foreach (CatalogTreeNode geometry in geometries)
            map = SetVisibility(map, geometry.Locator!, true);

        roots = MapTreeService.Load(map).Roots;
        CatalogTreeNodeLocator[] associationLocators = [
            FindMatchingAssociation(roots, "Terrain", terrainPath).Locator!,
            FindMatchingAssociation(roots, "NValue", nvaluePath).Locator!,
            FindMatchingAssociation(roots, "Classification", classificationPath).Locator!
        ];
        foreach (CatalogTreeNodeLocator locator in associationLocators)
            map = SetVisibility(map, locator, true);

        roots = MapTreeService.Load(map).Roots;
        CatalogTreeNode[] finalGeometries = [
            FindGeometry(roots, geometryAPath, "R19 Shared Geometry A"),
            FindGeometry(roots, geometryBPath, "R19 Shared Geometry B")
        ];
        CatalogTreeNodeLocator[] finalAssociations = [
            FindMatchingAssociation(roots, "Terrain", terrainPath).Locator!,
            FindMatchingAssociation(roots, "NValue", nvaluePath).Locator!,
            FindMatchingAssociation(roots, "Classification", classificationPath).Locator!
        ];
        Check(finalGeometries.Select(node => node.Name).SequenceEqual(
                ["R19 Shared Geometry A", "R19 Shared Geometry B"]) &&
              finalAssociations.All(locator => locator.RootName == "Matching Layers") &&
              finalAssociations.Select(locator => locator.AssociationKind).SequenceEqual(
                ["Terrain", "NValue", "Classification"]),
            "Two retained Geometry objects share three exact source associations under Matching Layers.");

        return new Fixture(projectPath, Path.ChangeExtension(projectPath, ".vis"), map,
            projectXmlSHA, terrainPath, nvaluePath, classificationPath, geometryAPath, geometryBPath,
            terrainRasterPath, classificationRasterPath, finalGeometries.Select(node => node.Locator!).ToArray(),
            finalAssociations);
    }

    private static void CreateFloatRaster(string path, float value)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        using var driver = Gdal.GetDriverByName("GTiff");
        using var dataset = driver.Create(path, 16, 16, 1, DataType.GDT_Float32, ["TILED=YES"]);
        dataset.SetGeoTransform([0, 1, 0, 16, 0, -1]);
        using var band = dataset.GetRasterBand(1);
        float[] values = new float[16 * 16];
        for (int row = 0; row < 16; row++)
        for (int column = 0; column < 16; column++)
            values[row * 16 + column] = value + row * 3f + column * 2f;
        band.WriteRaster(0, 0, 16, 16, values, 16, 16, 0, 0);
    }

    private static void CheckTerrainHillshade(Fixture fixture, AssociatedMapLayerSnapshot rendered)
    {
        Project project = new(fixture.ProjectPath);
        try
        {
            Terrain terrain = project.Terrains.Single(item => MapSourceTestPaths.SameFile(item.Filename, fixture.TerrainPath));
            Extent extent = terrain.ValidExtent;
            double histogramCellSize = Math.Sqrt(Math.Sqrt(extent.Area));
            int histogramSampleCount = new RasterDefinition(extent, histogramCellSize).CellCount;
            Histogram histogram = terrain.ComputeHistogram(histogramSampleCount, 1024);
            InterpolatedSurfaceFill fill = new(ColorPalettes.Terrain, histogram,
                isStretched: true, regenForScreen: false, name: ColorPalettes.Terrain.Name);

            const int width = PixelWidth;
            const int height = PixelHeight;
            double pixelWidth = (Viewport.MaxX - Viewport.MinX) / width;
            double pixelHeight = (Viewport.MaxY - Viewport.MinY) / height;
            double cellSize = Math.Max(pixelWidth, pixelHeight);
            int columns = checked((int)Math.Ceiling((Viewport.MaxX - Viewport.MinX) / cellSize) + 2);
            int rows = checked((int)Math.Ceiling((Viewport.MaxY - Viewport.MinY) / cellSize) + 2);
            var query = new RasterDefinition(new Point(Viewport.MinX - cellSize, Viewport.MaxY + cellSize),
                cellSize, rows, columns);
            var symbology = new RasterSymbology(fill);
            symbology.HillshadeProperties.IsEnabled = false;
            var layer = new RasterRenderLayer(terrain, symbology)
            {
                RegisterDataOnPlotRequest = false
            };
            using var plot = new PlotRequest(query);
            Check(layer.Render(plot), "The retained raster engine can render the sloped Terrain fixture without hillshade.");

            ReadOnlySpan<int> unshaded = plot.ColorBufferARGB.Span;
            bool foundShadedPixel = false;
            for (int row = 3; row < height - 2 && !foundShadedPixel; row++)
            for (int column = 3; column < width - 2 && !foundShadedPixel; column++)
            {
                double x = Viewport.MinX + (column + 0.5) * pixelWidth;
                double y = Viewport.MaxY - (row + 0.5) * pixelHeight;
                int sourceIndex = query.Row(y) * query.Cols + query.Col(x);
                uint expected = unchecked((uint)unshaded[sourceIndex]);
                int outputIndex = (row * width + column) * 4;
                int expectedLuminance = (int)((expected >> 16 & 0xff) * 299 +
                    (expected >> 8 & 0xff) * 587 + (expected & 0xff) * 114);
                int actualLuminance = rendered.Rgba[outputIndex] * 299 +
                    rendered.Rgba[outputIndex + 1] * 587 + rendered.Rgba[outputIndex + 2] * 114;
                foundShadedPixel = actualLuminance < expectedLuminance;
            }
            Check(foundShadedPixel,
                "Associated Terrain pixels include the retained source hillshade over a real sloped TIFF, beyond the same palette without hillshade.");
        }
        finally
        {
            Dispose(project);
        }
    }

    private static void CreateClassificationRaster(string path)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        using var driver = Gdal.GetDriverByName("GTiff");
        using var dataset = driver.Create(path, 16, 16, 1, DataType.GDT_Int32, ["TILED=YES"]);
        dataset.SetGeoTransform([0, 1, 0, 16, 0, -1]);
        using var band = dataset.GetRasterBand(1);
        int[] values = new int[16 * 16];
        for (int row = 0; row < 16; row++)
        for (int column = 0; column < 16; column++)
            values[row * 16 + column] = column < 5 ? 11 : column < 11 ? 99 : 0;
        band.WriteRaster(0, 0, 16, 16, values, 16, 16, 0, 0);
    }

    private static string DraftProjectXml(string projectPath)
    {
        XElement project = XElement.Load(projectPath, LoadOptions.PreserveWhitespace);
        XElement metadata = project.Name.LocalName == "Project"
            ? project
            : project.DescendantsAndSelf().First(element => element.Name.LocalName == "Project");
        metadata.SetElementValue("Description", "R19 unsaved Geometry map preview draft");
        return project.ToString(SaveOptions.DisableFormatting);
    }

    private static CatalogTreeNode FindGeometry(CatalogTreeNode[] roots, string path, string name) =>
        Walk(roots).Single(node => node.Locator is { NodeType: "Geometry", RootName: "Focused Geometries" } locator &&
            locator.NodeName == name && locator.AssetID is { } asset && MapSourceTestPaths.SameFile(asset, path));

    private static CatalogTreeNode FindMatchingAssociation(CatalogTreeNode[] roots, string kind, string path) =>
        Walk(roots).Single(node => node.Locator is { } locator && locator.RootName == "Matching Layers" &&
            locator.NodeType == kind && locator.AssociationKind == kind &&
            locator.AssociationAssetID is { } associated && MapSourceTestPaths.SameFile(associated, path));

    private static IEnumerable<CatalogTreeNode> Walk(IEnumerable<CatalogTreeNode> roots)
    {
        foreach (CatalogTreeNode node in roots)
        {
            yield return node;
            if (node.Children is { } children)
                foreach (CatalogTreeNode child in Walk(children)) yield return child;
        }
    }

    private static Fixture SetAssociationVisibility(Fixture fixture, string kind, bool visible)
    {
        CatalogTreeNode[] roots = MapTreeService.Load(fixture.Map).Roots;
        CatalogTreeNodeLocator locator = FindMatchingAssociation(roots, kind,
            fixture.SourcePathFor(kind)).Locator!;
        MapTreeRequest updatedMap = SetVisibility(fixture.Map, locator, visible);
        CatalogTreeNode[] updatedRoots = MapTreeService.Load(updatedMap).Roots;
        CatalogTreeNodeLocator[] currentAssociations = [
            FindMatchingAssociation(updatedRoots, "Terrain", fixture.TerrainPath).Locator!,
            FindMatchingAssociation(updatedRoots, "NValue", fixture.NValuePath).Locator!,
            FindMatchingAssociation(updatedRoots, "Classification", fixture.ClassificationPath).Locator!
        ];
        CatalogTreeNodeLocator[] currentGeometries = [
            FindGeometry(updatedRoots, fixture.GeometryAPath, "R19 Shared Geometry A").Locator!,
            FindGeometry(updatedRoots, fixture.GeometryBPath, "R19 Shared Geometry B").Locator!
        ];
        return fixture with { Map = updatedMap, GeometryLocators = currentGeometries,
            AssociationLocators = currentAssociations };
    }

    private static MapTreeRequest SetVisibility(MapTreeRequest map, CatalogTreeNodeLocator locator, bool visible)
    {
        MapTreeMutationResult result = MapTreeService.Perform(new MapTreeActionRequest(
            map, "visibility", Node: locator, Checked: visible));
        return map with { ExpectedVisualizationRevision = result.VisualizationRevision };
    }

    private static AssociatedMapLayersRequest Request(Fixture fixture,
        CatalogTreeNodeLocator[] associationLocators, string? contextToken = null) => new(
        fixture.Map, fixture.GeometryLocators, associationLocators, Viewport,
        PixelWidth, PixelHeight, contextToken);

    private static AssociatedMapLayerSnapshot Layer(AssociatedMapLayersSnapshot snapshot, string kind) =>
        snapshot.Layers.Single(layer => layer.Kind == kind);

    private static void ExportAcceptanceFixture(string sourceRoot, Fixture fixture)
    {
        string? configuredPath = Environment.GetEnvironmentVariable("HECRAS_ASSOCIATED_MAP_ACCEPTANCE_DIRECTORY");
        if (string.IsNullOrWhiteSpace(configuredPath)) return;
        string target = Path.GetFullPath(configuredPath);
        string source = Path.GetFullPath(sourceRoot);
        if (Directory.Exists(target) || File.Exists(target) ||
            target.StartsWith(source + Path.DirectorySeparatorChar, StringComparison.Ordinal))
            throw new IOException("The associated map acceptance directory already exists or is inside the source fixture.");
        Directory.CreateDirectory(target);
        foreach (string path in Directory.EnumerateFiles(source, "*", SearchOption.AllDirectories))
        {
            string destination = Path.Combine(target, Path.GetRelativePath(source, path));
            Directory.CreateDirectory(Path.GetDirectoryName(destination)!);
            File.Copy(path, destination);
        }

        var manifest = new
        {
            project = Path.GetFileName(fixture.ProjectPath),
            map = new { fixture.Map.MapIndex, fixture.Map.MapName, fixture.Map.MapType },
            geometries = fixture.GeometryLocators.Select(locator => new
            {
                locator.NodeName,
                path = Path.GetRelativePath(source, locator.AssetID!)
            }).ToArray(),
            associations = fixture.AssociationLocators.Select(locator => new
            {
                kind = locator.AssociationKind,
                name = locator.NodeName,
                path = Path.GetRelativePath(source, locator.AssociationAssetID!)
            }).ToArray(),
            request = new { viewport = Viewport, width = PixelWidth, height = PixelHeight }
        };
        File.WriteAllText(Path.Combine(target, "manifest.json"),
            JsonSerializer.Serialize(manifest, new JsonSerializerOptions { WriteIndented = true }));
        File.WriteAllText(Path.Combine(target, "ACCEPTANCE.txt"),
            "Retained source project with one saved Geometry map, two focused Geometry HDFs, and shared Terrain, NValue and Classification source objects. " +
            "Backing TIFFs are real GDAL-written test data; this fixture is for read-only native map integration acceptance.");
    }

    private static void Dispose(Project project)
    {
        foreach (CoreLayerBase layer in project.Plans.Cast<CoreLayerBase>()
            .Concat(project.Geometries).Concat(project.Terrains).Concat(project.BoundaryConditions)
            .Concat(project.NValues).Concat(project.ClassificationLayers))
            layer.Dispose();
        foreach (Result result in project.Results) result.Dispose();
    }

    private static string Hash(string path) => Hash(File.ReadAllBytes(path));
    private static string Hash(byte[] bytes) => Convert.ToHexString(SHA256.HashData(bytes));
    private static StringComparer PathComparer => OperatingSystem.IsWindows()
        ? StringComparer.OrdinalIgnoreCase : StringComparer.Ordinal;

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

    private sealed record Fixture(string ProjectPath, string VisualizationPath, MapTreeRequest Map,
        string ProjectXmlSHA, string TerrainPath, string NValuePath, string ClassificationPath,
        string GeometryAPath, string GeometryBPath, string TerrainRasterPath, string ClassificationRasterPath,
        CatalogTreeNodeLocator[] GeometryLocators, CatalogTreeNodeLocator[] AssociationLocators)
    {
        internal string[] SourcePaths => [TerrainPath, NValuePath, ClassificationPath,
            GeometryAPath, GeometryBPath, TerrainRasterPath, ClassificationRasterPath];

        internal string SourcePathFor(string kind) => kind switch
        {
            "Terrain" => TerrainPath,
            "NValue" => NValuePath,
            "Classification" => ClassificationPath,
            _ => throw new ArgumentOutOfRangeException(nameof(kind))
        };
    }
}
