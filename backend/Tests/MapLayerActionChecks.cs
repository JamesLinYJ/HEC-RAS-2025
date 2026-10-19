using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Xml.Linq;
using Geospatial.GDALAssist;
using Ras.Backend;
using Ras.Layers;
using OSGeo.GDAL;
using Utility.Files;
using Utility.Units;

internal static class MapLayerActionChecks
{
    internal static void Run()
    {
        using var temporary = new TemporaryDirectory();
        (string projectPath, string resultPath) = CreateProjectWithResult(temporary.FullName);
        byte[] originalProject = File.ReadAllBytes(projectPath);
        byte[] originalResult = File.ReadAllBytes(resultPath);
        string projectXml = DraftProjectXml(projectPath);
        string projectXmlSHA = Hash(Encoding.UTF8.GetBytes(projectXml));
        string visualizationPath = Path.ChangeExtension(projectPath, ".vis");

        MapDocumentMutationReceipt projectMapCreated = MapTreeService.CreateMap(new MapDocumentRequest(
            projectPath, projectXml, projectXmlSHA, null, "Project"));
        MapDocumentMutationReceipt buildableMapCreated = MapTreeService.CreateMap(new MapDocumentRequest(
            projectPath, projectXml, projectXmlSHA, projectMapCreated.VisualizationRevision, "Buildable"));
        AddUnknownVisualizationData(visualizationPath);
        string revision = Hash(File.ReadAllBytes(visualizationPath));
        var projectMap = new MapTreeRequest(projectPath, projectXml, projectXmlSHA,
            "project-map", projectMapCreated.MapIndex, projectMapCreated.MapName, projectMapCreated.MapType, revision);
        var buildableMap = new MapTreeRequest(projectPath, projectXml, projectXmlSHA,
            "buildable-map", buildableMapCreated.MapIndex, buildableMapCreated.MapName, buildableMapCreated.MapType, revision);

        string resultRevision = Hash(File.ReadAllBytes(resultPath));
        MapTreeMutationResult resultAdded = MapTreeService.Perform(new MapTreeActionRequest(
            buildableMap, "addResult", SourcePath: resultPath, SourceRevision: resultRevision));
        CatalogTreeNode resultGroup = resultAdded.Roots.Single(root => root.Name == "Layers")!
            .Children!.Single(node => node.SourceClass == "MultiResultNodeVM");
        Check(resultGroup.Name == "Plan A" && resultGroup.Checked == "checked"
            && resultGroup.Locator is { NodeType: "MultiResult", NodePath: { Length: 2 } },
            "A Plan-linked Result is persisted as the retained source MultiResult plan group and activates that node.");
        projectMap = projectMap with { ExpectedVisualizationRevision = resultAdded.VisualizationRevision };
        buildableMap = buildableMap with { ExpectedVisualizationRevision = resultAdded.VisualizationRevision };
        MapResultSourcesResult initialResultSources = MapResultChartService.Sources(
            new MapResultSourcesRequest(buildableMap));
        MapTreeMutationResult selectedWaterSurface = MapTreeService.Perform(new MapTreeActionRequest(
            buildableMap, "setResultMapType", Name: "WaterSurfaceElevation"));
        buildableMap = buildableMap with { ExpectedVisualizationRevision = selectedWaterSurface.VisualizationRevision };
        projectMap = projectMap with { ExpectedVisualizationRevision = selectedWaterSurface.VisualizationRevision };
        CatalogTreeNode waterSurfaceGroup = selectedWaterSurface.Roots.Single(root => root.Name == "Layers")
            .Children!.Single(node => node.SourceClass == "MultiResultNodeVM");
        Check(waterSurfaceGroup.Properties!.Any(property => property.Id == "Source/SelectedMapType" &&
                property.Value == "Water Surface"),
            "Map-wide result type selection stores the exact source serializer name on active MultiResult nodes.");
        CatalogTreeNode reopenedWaterSurfaceGroup = MapTreeService.Load(buildableMap).Roots
            .Single(root => root.Name == "Layers").Children!
            .Single(node => node.SourceClass == "MultiResultNodeVM");
        CatalogTreeProperty[] reopenedProperties = reopenedWaterSurfaceGroup.Properties
            ?? throw new InvalidOperationException("The reopened MultiResult has no saved source properties.");
        Check(reopenedProperties.Single(property =>
                property.Id == "Source/SelectedMapType").Value == "Water Surface" &&
            reopenedProperties.Select(property => property.Id).Distinct().Count() ==
                reopenedProperties.Length,
            "Reopening a matched source node projects its saved renderer properties once, without duplicate source attributes.");
        MapResultSourcesResult waterSurfaceSources = MapResultChartService.Sources(
            new MapResultSourcesRequest(buildableMap));
        Check(waterSurfaceSources.ActiveNodes.Single(node => node.NodeKind == "MultiResult").SelectedMapType == "Water Surface"
            && waterSurfaceSources.ContextToken != initialResultSources.ContextToken,
            "Refreshing result sources observes the newly persisted map type and issues a new context token.");
        MapTreeMutationResult selectedDepthVelocity = MapTreeService.Perform(new MapTreeActionRequest(
            buildableMap, "setResultMapType", Name: "DepthTimesVelocity"));
        buildableMap = buildableMap with { ExpectedVisualizationRevision = selectedDepthVelocity.VisualizationRevision };
        projectMap = projectMap with { ExpectedVisualizationRevision = selectedDepthVelocity.VisualizationRevision };
        MapResultSourcesResult depthVelocitySources = MapResultChartService.Sources(
            new MapResultSourcesRequest(buildableMap));
        Check(depthVelocitySources.ActiveNodes.Single(node => node.NodeKind == "MultiResult").SelectedMapType == "D*V",
            "The map-wide action maps the retained DepthTimesVelocity key to its serialized D*V renderer type.");
        foreach ((string key, string sourceName) in new[] { ("Depth", "Depth"), ("Velocity", "Velocity") })
        {
            MapTreeMutationResult selectedMapType = MapTreeService.Perform(new MapTreeActionRequest(
                buildableMap, "setResultMapType", Name: key));
            buildableMap = buildableMap with { ExpectedVisualizationRevision = selectedMapType.VisualizationRevision };
            projectMap = projectMap with { ExpectedVisualizationRevision = selectedMapType.VisualizationRevision };
            MapResultSourcesResult refreshedSources = MapResultChartService.Sources(
                new MapResultSourcesRequest(buildableMap));
            Check(refreshedSources.ActiveNodes.Single(node => node.NodeKind == "MultiResult").SelectedMapType == sourceName,
                $"The map-wide {key} choice is persisted using the retained source map type name.");
        }
        var resultReadback = MapTreeService.Load(buildableMap);
        Check(resultReadback.Roots.Single(root => root.Name == "Layers").Children!.Count(node =>
                node.SourceClass == "MultiResultNodeVM" && node.Name == "Plan A") == 1,
            "The result group is reconstructed from a fresh .vis read at its source tree identity.");
        var automaticProjectResults = MapTreeService.Load(projectMap);
        Check(Flatten(automaticProjectResults.Roots).Any(node => node.SourceClass == "MultiResultNodeVM" && node.Name == "Plan A"),
            "Project map Result groups come from the source Project tree and are not duplicated by a manual add action.");
        byte[] beforeProjectResultAdd = File.ReadAllBytes(visualizationPath);
        Expect<NotSupportedException>(() => MapTreeService.Perform(new MapTreeActionRequest(
            projectMap, "addResult", SourcePath: resultPath, SourceRevision: resultRevision)));
        Check(File.ReadAllBytes(visualizationPath).SequenceEqual(beforeProjectResultAdd),
            "Project Result groups are source-generated and reject manual add without writing the .vis file.");

        string unlinkedDirectory = Path.Combine(temporary.FullName, "Unlinked");
        Directory.CreateDirectory(unlinkedDirectory);
        string externalVectorPath = Path.Combine(unlinkedDirectory, "outside.geojson");
        File.WriteAllText(externalVectorPath, LineGeoJson, Encoding.UTF8);
        string externalRevision = Hash(File.ReadAllBytes(externalVectorPath));
        string beforeRejectedAdd = Hash(File.ReadAllBytes(visualizationPath));
        Expect<ArgumentException>(() => MapTreeService.Perform(new MapTreeActionRequest(
            buildableMap, "addGeoJSONVector", SourcePath: externalVectorPath, SourceRevision: externalRevision)));
        Check(Hash(File.ReadAllBytes(visualizationPath)) == beforeRejectedAdd,
            "An unlinked external GeoJSON file cannot mutate the project's .vis file.");

        string connectedFilesDirectory = Path.Combine(temporary.FullName, "External Inputs");
        Directory.CreateDirectory(connectedFilesDirectory);
        string connectedFilePath = Path.Combine(connectedFilesDirectory, "connected.geojson");
        File.WriteAllText(connectedFilePath, LineGeoJson, Encoding.UTF8);
        string connectedFileRevision = Hash(File.ReadAllBytes(connectedFilePath));
        string linkedDirectory = Path.Combine(temporary.FullName, "External Inputs", "GeoJSON inputs");
        Directory.CreateDirectory(linkedDirectory);
        string directoryVectorPath = Path.Combine(linkedDirectory, "directory.geojson");
        File.WriteAllText(directoryVectorPath, LineGeoJson, Encoding.UTF8);
        string directoryVectorRevision = Hash(File.ReadAllBytes(directoryVectorPath));
        string connectedProjectXml = AddFileConnection(projectXml, projectPath, connectedFilePath);
        connectedProjectXml = AddDirectoryConnection(connectedProjectXml, projectPath, linkedDirectory);
        string connectedProjectXmlSHA = Hash(Encoding.UTF8.GetBytes(connectedProjectXml));
        buildableMap = buildableMap with { ProjectXml = connectedProjectXml, ProjectXmlSHA = connectedProjectXmlSHA };
        projectMap = projectMap with { ProjectXml = connectedProjectXml, ProjectXmlSHA = connectedProjectXmlSHA };

        MapTreeMutationResult externalFileAdded = MapTreeService.Perform(new MapTreeActionRequest(
            buildableMap, "addGeoJSONVector", SourcePath: connectedFilePath, SourceRevision: connectedFileRevision));
        buildableMap = buildableMap with { ExpectedVisualizationRevision = externalFileAdded.VisualizationRevision };
        projectMap = projectMap with { ExpectedVisualizationRevision = externalFileAdded.VisualizationRevision };
        CatalogTreeNode externalFileNode = externalFileAdded.Roots.Single(root => root.Name == "Layers")
            .Children!.Single(node => node.SourceClass == "PolylineMapLayerVisualContext");
        Check(PathEquals(externalFileNode.AssetID!, connectedFilePath),
            "A GeoJSON file explicitly connected in the unsaved Project XML draft is eligible for map insertion.");
        MapTreeMutationResult externalFileRemoved = MapTreeService.Perform(new MapTreeActionRequest(
            buildableMap, "removeSourceNode", Node: externalFileNode.Locator,
            SourcePath: connectedFilePath, SourceRevision: connectedFileRevision));
        buildableMap = buildableMap with { ExpectedVisualizationRevision = externalFileRemoved.VisualizationRevision };
        projectMap = projectMap with { ExpectedVisualizationRevision = externalFileRemoved.VisualizationRevision };

        MapTreeMutationResult externalDirectoryAdded = MapTreeService.Perform(new MapTreeActionRequest(
            projectMap, "addGeoJSONVector", SourcePath: directoryVectorPath,
            SourceRevision: directoryVectorRevision));
        projectMap = projectMap with { ExpectedVisualizationRevision = externalDirectoryAdded.VisualizationRevision };
        buildableMap = buildableMap with { ExpectedVisualizationRevision = externalDirectoryAdded.VisualizationRevision };
        CatalogTreeNode directoryVectorNode = externalDirectoryAdded.Roots.Single(root => root.Name == "Map Layers")
            .Children!.Single(node => node.Name == "Vectors").Children!
            .Single(node => node.SourceClass == "PolylineMapLayerVisualContext");
        Check(PathEquals(directoryVectorNode.AssetID!, directoryVectorPath),
            "A GeoJSON file enumerated by a current Project directory connection can be inserted into a map.");
        MapTreeMutationResult externalDirectoryRemoved = MapTreeService.Perform(new MapTreeActionRequest(
            projectMap, "removeSourceNode", Node: directoryVectorNode.Locator,
            SourcePath: directoryVectorPath, SourceRevision: directoryVectorRevision));
        projectMap = projectMap with { ExpectedVisualizationRevision = externalDirectoryRemoved.VisualizationRevision };
        buildableMap = buildableMap with { ExpectedVisualizationRevision = externalDirectoryRemoved.VisualizationRevision };

        string vectorDirectory = Path.Combine(Path.GetDirectoryName(projectPath)!, "Map Data");
        Directory.CreateDirectory(vectorDirectory);
        string vectorPath = Path.Combine(vectorDirectory, "Centerline.geojson");
        File.WriteAllText(vectorPath, LineGeoJson, Encoding.UTF8);
        string vectorRevision = Hash(File.ReadAllBytes(vectorPath));
        MapTreeMutationResult projectVectorAdded = MapTreeService.Perform(new MapTreeActionRequest(
            projectMap, "addGeoJSONVector", SourcePath: vectorPath, SourceRevision: vectorRevision));
        projectMap = projectMap with { ExpectedVisualizationRevision = projectVectorAdded.VisualizationRevision };
        CatalogTreeNode projectVector = projectVectorAdded.Roots.Single(root => root.Name == "Map Layers")
            .Children!.Single(node => node.Name == "Vectors").Children!
            .Single(node => node.Name == "Centerline");
        Check(projectVector.SourceClass == "PolylineMapLayerVisualContext" && projectVector.Name == "Centerline"
            && projectVector.Checked == "checked" && PathEquals(projectVector.AssetID!, vectorPath),
            "Project map GeoJSON import creates the real Polyline vector node beneath its source Vectors folder.");

        buildableMap = buildableMap with { ExpectedVisualizationRevision = projectVectorAdded.VisualizationRevision };
        MapTreeMutationResult buildableVectorAdded = MapTreeService.Perform(new MapTreeActionRequest(
            buildableMap, "addGeoJSONVector", SourcePath: vectorPath, SourceRevision: vectorRevision));
        buildableMap = buildableMap with { ExpectedVisualizationRevision = buildableVectorAdded.VisualizationRevision };
        CatalogTreeNode buildableVector = buildableVectorAdded.Roots.Single(root => root.Name == "Layers")
            .Children!.Single(node => node.SourceClass == "PolylineMapLayerVisualContext");
        MapTreeMutationResult hidden = MapTreeService.Perform(new MapTreeActionRequest(
            buildableMap, "visibility", Node: buildableVector.Locator, Checked: false));
        Check(hidden.HiddenLayerIDs.Any(hiddenPath => PathEquals(hiddenPath, vectorPath)),
            "Buildable map vector visibility is returned under the exact source-owned path.");
        buildableMap = buildableMap with { ExpectedVisualizationRevision = hidden.VisualizationRevision };

        byte[] beforeStaleRemoval = File.ReadAllBytes(visualizationPath);
        Expect<SourceFileChangedException>(() => MapTreeService.Perform(new MapTreeActionRequest(
            buildableMap, "removeSourceNode", Node: buildableVector.Locator,
            SourcePath: vectorPath, SourceRevision: new string('0', 64))));
        Check(File.ReadAllBytes(visualizationPath).SequenceEqual(beforeStaleRemoval),
            "Stale vector SHA rejects removal before changing any .vis data.");

        MapTreeMutationResult removed = MapTreeService.Perform(new MapTreeActionRequest(
            buildableMap, "removeSourceNode", Node: buildableVector.Locator,
            SourcePath: vectorPath, SourceRevision: vectorRevision));
        buildableMap = buildableMap with { ExpectedVisualizationRevision = removed.VisualizationRevision };
        projectMap = projectMap with { ExpectedVisualizationRevision = removed.VisualizationRevision };
        Check(!Flatten(removed.Roots).Any(node => node.SourceClass == "PolylineMapLayerVisualContext")
            && Flatten(MapTreeService.Load(projectMap).Roots).Any(node =>
                node.SourceClass == "PolylineMapLayerVisualContext" && PathEquals(node.AssetID!, vectorPath)),
            "Removing a Buildable vector removes only that map's precise .vis node while the Project map keeps its node.");

        string rasterDirectory = Path.Combine(Path.GetDirectoryName(projectPath)!, "Raster Data");
        Directory.CreateDirectory(rasterDirectory);
        string projectRevision = Hash(File.ReadAllBytes(projectPath));
        void VerifyRasterMapLayer(string filename, DataType dataType, int bands, string mapType)
        {
            string rasterPath = Path.Combine(rasterDirectory, filename);
            CreateRaster(rasterPath, dataType, bands);
            byte[] originalRaster = File.ReadAllBytes(rasterPath);
            MapRasterLayerInspectResult inspected = MapRasterLayerService.Inspect(new(rasterPath));
            Check(inspected.MapLayerType == mapType,
                $"The {mapType} removal path starts with a GDAL-confirmed source map type.");
            var owner = new MapDocumentRequest(buildableMap.ProjectPath, buildableMap.ProjectXml,
                buildableMap.ProjectXmlSHA, buildableMap.ExpectedVisualizationRevision, buildableMap.MapType,
                MapIndex: buildableMap.MapIndex, MapName: buildableMap.MapName, MapType: buildableMap.MapType);
            MapDocumentMutationReceipt imported = MapTreeService.ImportRasterLayer(new(owner, rasterPath,
                inspected.SourceRevision, mapType, projectRevision, inspected.SourceCanonicalPath));
            buildableMap = buildableMap with { ExpectedVisualizationRevision = imported.VisualizationRevision };
            projectMap = projectMap with { ExpectedVisualizationRevision = imported.VisualizationRevision };

            CatalogTreeNode rasterNode = Flatten(MapTreeService.Load(buildableMap).Roots).Single(node =>
                node.Locator is { NodeType: "MapLayer", MapType: var currentType } && currentType == mapType &&
                node.AssetID is { } assetID && PathEquals(assetID, rasterPath));
            MapTreeMutationResult hiddenRaster = MapTreeService.Perform(new MapTreeActionRequest(
                buildableMap, "visibility", Node: rasterNode.Locator, Checked: false));
            int[] nodePath = rasterNode.Locator?.NodePath
                ?? throw new InvalidOperationException("The raster source node has no persisted tree path.");
            string expectedHiddenID = $"vis-map-{buildableMap.MapIndex}-node-{string.Join('.', nodePath)}";
            Check(hiddenRaster.HiddenLayerIDs.Contains(expectedHiddenID, StringComparer.Ordinal),
                $"Hidden {mapType} visibility is returned using its exact .vis map-node identity.");
            buildableMap = buildableMap with { ExpectedVisualizationRevision = hiddenRaster.VisualizationRevision };
            projectMap = projectMap with { ExpectedVisualizationRevision = hiddenRaster.VisualizationRevision };

            rasterNode = Flatten(MapTreeService.Load(buildableMap).Roots).Single(node =>
                node.Locator is { NodeType: "MapLayer", MapType: var currentType } && currentType == mapType &&
                node.AssetID is { } assetID && PathEquals(assetID, rasterPath));
            byte[] beforeStaleRasterRemoval = File.ReadAllBytes(visualizationPath);
            Expect<SourceFileChangedException>(() => MapTreeService.Perform(new MapTreeActionRequest(
                buildableMap, "removeSourceNode", Node: rasterNode.Locator,
                SourcePath: rasterPath, SourceRevision: new string('0', 64))));
            Check(File.ReadAllBytes(visualizationPath).SequenceEqual(beforeStaleRasterRemoval),
                $"A stale {mapType} source revision rejects removal without changing the .vis file.");

            MapTreeMutationResult rasterRemoved = MapTreeService.Perform(new MapTreeActionRequest(
                buildableMap, "removeSourceNode", Node: rasterNode.Locator,
                SourcePath: rasterPath, SourceRevision: inspected.SourceRevision));
            buildableMap = buildableMap with { ExpectedVisualizationRevision = rasterRemoved.VisualizationRevision };
            projectMap = projectMap with { ExpectedVisualizationRevision = rasterRemoved.VisualizationRevision };
            Check(!Flatten(MapTreeService.Load(buildableMap).Roots).Any(node =>
                    node.Locator is { NodeType: "MapLayer", MapType: var currentType } && currentType == mapType &&
                    node.AssetID is { } assetID && PathEquals(assetID, rasterPath)) &&
                File.ReadAllBytes(rasterPath).SequenceEqual(originalRaster),
                $"Removing {mapType} persists to .vis while retaining the original raster source file.");
        }

        VerifyRasterMapLayer("continuous.tif", DataType.GDT_Float32, 1, "SingleBandRasterMapLayer");
        VerifyRasterMapLayer("rgb.tif", DataType.GDT_Byte, 3, "ImageRasterMapLayer");
        VerifyRasterMapLayer("classes.tif", DataType.GDT_Int32, 1, "DiscreteRasterMapLayer");

        string vrtDependency = Path.Combine(rasterDirectory, "vrt-dependency.tif");
        CreateRaster(vrtDependency, DataType.GDT_Float32, 1);
        string vrtPath = Path.Combine(rasterDirectory, "dependent.vrt");
        GDALRaster.BuildVRT([vrtDependency], vrtPath);
        MapRasterLayerInspectResult vrtInspection = MapRasterLayerService.Inspect(new(vrtPath));
        var vrtOwner = new MapDocumentRequest(buildableMap.ProjectPath, buildableMap.ProjectXml,
            buildableMap.ProjectXmlSHA, buildableMap.ExpectedVisualizationRevision, buildableMap.MapType,
            MapIndex: buildableMap.MapIndex, MapName: buildableMap.MapName, MapType: buildableMap.MapType);
        MapDocumentMutationReceipt vrtImported = MapTreeService.ImportRasterLayer(new(vrtOwner, vrtPath,
            vrtInspection.SourceRevision, vrtInspection.MapLayerType, projectRevision,
            vrtInspection.SourceCanonicalPath));
        buildableMap = buildableMap with { ExpectedVisualizationRevision = vrtImported.VisualizationRevision };
        projectMap = projectMap with { ExpectedVisualizationRevision = vrtImported.VisualizationRevision };
        CatalogTreeNode vrtNode = Flatten(MapTreeService.Load(buildableMap).Roots).Single(node =>
            node.Locator is { NodeType: "MapLayer", MapType: var currentType } &&
            currentType == vrtInspection.MapLayerType && node.AssetID is { } assetID && PathEquals(assetID, vrtPath));
        using (var update = Gdal.Open(vrtDependency, Access.GA_Update))
        using (var band = update.GetRasterBand(1)) band.Fill(91, 0);
        byte[] beforeStaleVrtRemoval = File.ReadAllBytes(visualizationPath);
        Expect<SourceFileChangedException>(() => MapTreeService.Perform(new MapTreeActionRequest(
            buildableMap, "removeSourceNode", Node: vrtNode.Locator,
            SourcePath: vrtPath, SourceRevision: vrtInspection.SourceRevision)));
        Check(File.ReadAllBytes(visualizationPath).SequenceEqual(beforeStaleVrtRemoval),
            "A changed VRT dependency rejects removal using the original manifest without changing .vis.");
        MapRasterLayerInspectResult currentVrt = MapRasterLayerService.Inspect(new(vrtPath));
        byte[] currentVrtBytes = File.ReadAllBytes(vrtPath);
        byte[] currentDependencyBytes = File.ReadAllBytes(vrtDependency);
        MapTreeMutationResult vrtRemoved = MapTreeService.Perform(new MapTreeActionRequest(
            buildableMap, "removeSourceNode", Node: vrtNode.Locator,
            SourcePath: vrtPath, SourceRevision: currentVrt.SourceRevision));
        buildableMap = buildableMap with { ExpectedVisualizationRevision = vrtRemoved.VisualizationRevision };
        projectMap = projectMap with { ExpectedVisualizationRevision = vrtRemoved.VisualizationRevision };
        Check(!Flatten(MapTreeService.Load(buildableMap).Roots).Any(node =>
                node.Locator is { NodeType: "MapLayer", MapType: var currentType } &&
                currentType == currentVrt.MapLayerType && node.AssetID is { } assetID && PathEquals(assetID, vrtPath)) &&
            File.ReadAllBytes(vrtPath).SequenceEqual(currentVrtBytes) &&
            File.ReadAllBytes(vrtDependency).SequenceEqual(currentDependencyBytes),
            "Removing a VRT with its current dependency manifest persists to .vis and preserves the VRT and dependency files.");

        string savedVisualization = File.ReadAllText(visualizationPath);
        Check(savedVisualization.Contains("PreserveRoot", StringComparison.Ordinal)
            && savedVisualization.Contains("PreserveMap", StringComparison.Ordinal),
            "Source map actions preserve unrelated visualization root and map attributes.");
        Check(File.ReadAllBytes(projectPath).SequenceEqual(originalProject)
            && File.ReadAllBytes(resultPath).SequenceEqual(originalResult)
            && projectXml.Contains("unsaved map action draft", StringComparison.Ordinal),
            "Map layer actions never save an unsaved project XML draft or modify the Result HDF.");

        ExportAcceptanceFixture(temporary.FullName, projectPath, resultPath, vectorPath, visualizationPath);
        Console.WriteLine("Source map result and GeoJSON add/remove routes preserve exact project, map, file and revision identities.");
    }

    private static (string ProjectPath, string ResultPath) CreateProjectWithResult(string root)
    {
        string projectDirectory = Path.Combine(root, "Project");
        Directory.CreateDirectory(projectDirectory);
        string projectPath = Path.Combine(projectDirectory, "Map Actions.ras");
        Project project = Project.CreateNew(projectPath, UnitSystem.SI);
        string resultPath;
        try
        {
            Terrain terrain = project.AddNewTerrain("Terrain A");
            NValueLayer nvalues = project.AddNewNValueLayer("N Values A");
            Geometry geometry = project.AddNewGeometry("Geometry A", terrain, nvalues);
            BoundaryCondition boundary = project.AddNewBoundaryCondition("Boundary A",
                new DateTime(2026, 10, 16), TimeSpan.FromHours(1));
            Plan plan = project.AddNewPlan("Plan A", geometry, boundary);
            foreach (CoreLayerBase layer in Layers(project)) layer.Save();
            project.Save();
            resultPath = Path.Combine(project.ResultsDirectory, "History A.h5");
            using (Result prepared = Result.PrepareResult(resultPath, plan, geometry, boundary, null!))
                Check(File.Exists(resultPath), "The retained Result.PrepareResult writer creates the source Result fixture.");
        }
        finally { Dispose(project); }
        return (projectPath, resultPath);
    }

    private static string DraftProjectXml(string projectPath)
    {
        XElement draft = XElement.Load(projectPath);
        draft.SetAttributeValue("Description", "unsaved map action draft");
        return draft.ToString(SaveOptions.DisableFormatting);
    }

    private static string AddFileConnection(string projectXml, string projectPath, string path)
    {
        XElement project = XElement.Parse(projectXml);
        string projectDirectory = Path.GetDirectoryName(Path.GetFullPath(projectPath))!;
        var connection = FileExternalConnection.CreateAbsoluteFileConnection(
            Path.GetFileName(path), path, projectDirectory);
        AppendConnection(project, connection.SaveXML());
        return project.ToString(SaveOptions.DisableFormatting);
    }

    private static string AddDirectoryConnection(string projectXml, string projectPath, string directoryPath)
    {
        XElement project = XElement.Parse(projectXml);
        string projectDirectory = Path.GetDirectoryName(Path.GetFullPath(projectPath))!;
        var connection = new DirectoryExternalConnection(projectDirectory)
        {
            Name = "GeoJSON directory",
            SearchPattern = "*.geojson",
            Recurse = false
        };
        connection.SetConnectedPathname(directoryPath);
        AppendConnection(project, connection.SaveXML());
        return project.ToString(SaveOptions.DisableFormatting);
    }

    private static void AppendConnection(XElement project, XElement connection)
    {
        XElement connections = project.Element("Connections") ?? new XElement("Connections");
        if (connections.Parent is null) project.Add(connections);
        connections.Add(connection);
    }

    private static void AddUnknownVisualizationData(string path)
    {
        XDocument visualization = XDocument.Load(path, LoadOptions.PreserveWhitespace);
        visualization.Root!.SetAttributeValue("PreserveRoot", "yes");
        visualization.Root.Element("Maps")!.Elements("Map").First()
            .SetAttributeValue("PreserveMap", "yes");
        visualization.Root.Add(new XElement("UnknownSection", new XAttribute("Keep", "yes")));
        visualization.Save(path, SaveOptions.DisableFormatting);
    }

    private static void CreateRaster(string path, DataType dataType, int bands)
    {
        using var driver = Gdal.GetDriverByName("GTiff");
        using var raster = driver.Create(path, 8, 8, bands, dataType, []);
        raster.SetGeoTransform([0, 1, 0, 8, 0, -1]);
        for (int index = 1; index <= bands; index++)
        {
            using var band = raster.GetRasterBand(index);
            band.Fill(dataType == DataType.GDT_Byte ? 128 : 7, 0);
        }
    }

    private static void ExportAcceptanceFixture(string sourceRoot, string projectPath, string resultPath,
        string vectorPath, string visualizationPath)
    {
        string? configuredPath = Environment.GetEnvironmentVariable("HECRAS_MAP_LAYER_ACTION_ACCEPTANCE_DIRECTORY");
        if (string.IsNullOrWhiteSpace(configuredPath)) return;
        string destination = Path.GetFullPath(configuredPath);
        string source = Path.GetFullPath(sourceRoot);
        if (Directory.Exists(destination) || File.Exists(destination) ||
            destination.StartsWith(source + Path.DirectorySeparatorChar, StringComparison.Ordinal))
            throw new IOException("The map layer action acceptance destination already exists or is inside the fixture source.");
        Directory.CreateDirectory(destination);
        foreach (string sourceFile in Directory.EnumerateFiles(source, "*", SearchOption.AllDirectories))
        {
            string output = Path.Combine(destination, Path.GetRelativePath(source, sourceFile));
            Directory.CreateDirectory(Path.GetDirectoryName(output)!);
            File.Copy(sourceFile, output);
        }
        var manifest = new
        {
            project = Path.GetRelativePath(source, projectPath),
            visualization = Path.GetRelativePath(source, visualizationPath),
            result = Path.GetRelativePath(source, resultPath),
            vector = Path.GetRelativePath(source, vectorPath),
            mapTypes = new[] { "Project", "Buildable" },
            sourceTreeTypes = new[] { "MultiResult", "MapLayer" }
        };
        File.WriteAllText(Path.Combine(destination, "manifest.json"),
            JsonSerializer.Serialize(manifest, new JsonSerializerOptions { WriteIndented = true }));
    }

    private static IEnumerable<CoreLayerBase> Layers(Project project) => project.Plans.Cast<CoreLayerBase>()
        .Concat(project.Geometries).Concat(project.Terrains).Concat(project.BoundaryConditions)
        .Concat(project.NValues).Concat(project.ClassificationLayers);

    private static void Dispose(Project project)
    {
        foreach (Result result in project.Results) result.Dispose();
        foreach (CoreLayerBase layer in Layers(project)) layer.Dispose();
    }

    private static IEnumerable<CatalogTreeNode> Flatten(IEnumerable<CatalogTreeNode> nodes)
    {
        foreach (CatalogTreeNode node in nodes)
        {
            yield return node;
            if (node.Children is { Length: > 0 } children)
                foreach (CatalogTreeNode descendant in Flatten(children)) yield return descendant;
        }
    }

    private static bool PathEquals(string first, string second) =>
        string.Equals(CanonicalPath(first), CanonicalPath(second),
            OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal);

    private static string CanonicalPath(string path)
    {
        string fullPath = Path.GetFullPath(path);
        string root = Path.GetPathRoot(fullPath) ?? "";
        string current = root;
        foreach (string segment in fullPath[root.Length..].Split(Path.DirectorySeparatorChar,
                     StringSplitOptions.RemoveEmptyEntries))
        {
            string candidate = Path.Combine(current, segment);
            FileSystemInfo info = Directory.Exists(candidate) ? new DirectoryInfo(candidate) : new FileInfo(candidate);
            FileSystemInfo? target = null;
            try { target = info.ResolveLinkTarget(returnFinalTarget: true); }
            catch (IOException) { }
            current = Path.GetFullPath(target?.FullName ?? candidate);
        }
        return current;
    }

    private static string Hash(byte[] bytes) => Convert.ToHexString(SHA256.HashData(bytes));

    private static void Expect<T>(Action action) where T : Exception
    {
        try { action(); }
        catch (T) { return; }
        throw new InvalidOperationException("Expected " + typeof(T).Name);
    }

    private static void Check(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }

    private const string LineGeoJson = """
        {"type":"FeatureCollection","features":[{"type":"Feature","properties":{"name":"center"},"geometry":{"type":"LineString","coordinates":[[0,0],[1,1]]}}]}
        """;
}
