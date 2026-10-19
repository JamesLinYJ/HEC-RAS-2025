using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Xml.Linq;
using Ras.Backend;
using Ras.Layers;
using Utility.Units;

internal static class MapTreeChecks
{
    internal static void Run()
    {
        using var temporary = new TemporaryDirectory();
        string projectPath = Path.Combine(temporary.FullName, "MapTree.ras");
        Project project = Project.CreateNew(projectPath, UnitSystem.SI);
        project.Save();
        Dispose(project);
        byte[] projectBytes = File.ReadAllBytes(projectPath);
        string projectXml = File.ReadAllText(projectPath);
        string projectXmlSHA = Hash(Encoding.UTF8.GetBytes(projectXml));
        string visualizationPath = Path.ChangeExtension(projectPath, ".vis");

        MapDocumentMutationReceipt createdProject = MapTreeService.CreateMap(new MapDocumentRequest(
            projectPath, projectXml, projectXmlSHA, null, "Project"));
        Check(createdProject.MapIndex == 0 && createdProject.MapName == "Map" && createdProject.MapType == "Project",
            "The first persisted source project map uses the source default identity");
        MapDocumentMutationReceipt createdBuildable = MapTreeService.CreateMap(new MapDocumentRequest(
            projectPath, projectXml, projectXmlSHA, createdProject.VisualizationRevision, "Buildable"));
        Check(createdBuildable.MapIndex == 1 && createdBuildable.MapName == "Map 1" && createdBuildable.MapType == "Buildable",
            "A second persisted source map receives the next available name and serialized index");

        string elevationPath = Path.Combine(temporary.FullName, "elevation.tif");
        File.WriteAllText(elevationPath, "tree fixture only");
        XDocument visualization = XDocument.Load(visualizationPath, LoadOptions.PreserveWhitespace);
        visualization.Root!.SetAttributeValue("UnknownRootAttribute", "keep-root");
        XElement maps = visualization.Root.Element("Maps")!;
        maps.SetAttributeValue("Maps", "Map");
        XElement firstMap = maps.Elements("Map").ElementAt(0);
        firstMap.SetAttributeValue("UnknownMapAttribute", "keep-map");
        XElement treeNodes = new("Nodes",
            new XElement("Node", new XAttribute("Type", "Root"), new XAttribute("Name", "Map Layers"),
                new XElement("Node", new XAttribute("Type", "MapLayer"),
                    new XAttribute("MapType", "SingleBandRasterMapLayer"), new XAttribute("Name", "Elevation"),
                    new XAttribute("Filename", "unused.tif"), new XAttribute("FilenameRelative", "elevation.tif"),
                    new XAttribute("IsChecked", true))));
        firstMap.Add(new XElement("Tree", treeNodes));
        XElement secondMap = maps.Elements("Map").ElementAt(1);
        secondMap.SetAttributeValue("Name", "Map");
        visualization.Root.Add(new XElement("UnknownSection", new XAttribute("retained", "yes")));
        visualization.Save(visualizationPath, SaveOptions.DisableFormatting);

        string revision = Hash(File.ReadAllBytes(visualizationPath));
        MapTreeRequest projectMap = new(projectPath, projectXml, projectXmlSHA,
            "project-map-id", 0, "Map", "Project", revision);
        MapTreeSnapshot projectTree = MapTreeService.Load(projectMap);
        Check(projectTree.Roots.Select(root => root.Name).SequenceEqual(new[]
            { "Plans", "Results", "Geometries", "Terrains", "Surface Layers", "Map Layers", "Features", "Boundary Conditions" }),
            "Persisted Project map roots follow ProjectTreeModeVM order without the catalog-only Layers group");
        CatalogTreeNode mapLayers = projectTree.Roots.Single(root => root.Name == "Map Layers");
        CatalogTreeNode elevation = mapLayers.Children!.Single(node => node.Name == "Elevation");
        Check(elevation.Locator?.NodePath is { Length: 2 } && elevation.Checked == "checked" &&
              elevation.AssetID == Path.GetFullPath(elevationPath),
            "A serialized map-layer node retains its actual source path, visibility and index-based locator");

        MapTreeRequest buildableMap = projectMap with { MapIndex = 1, MapType = "Buildable" };
        MapTreeSnapshot buildableTree = MapTreeService.Load(buildableMap);
        Check(buildableTree.Roots.Select(root => root.Name).SequenceEqual(["Layers"]),
            "Persisted Buildable map uses the source BuildableTreeModeVM root");
        MapTreeMutationResult firstBuildableFolder = MapTreeService.Perform(new MapTreeActionRequest(
            buildableMap, "newFolder", Target: buildableTree.Roots.Single().Locator, Name: "First folder"));
        Check(firstBuildableFolder.Roots.Single().Children?.Single().Name == "First folder",
            "The first folder materializes and attaches a previously absent serialized root");
        var buildableReadback = MapTreeService.Load(buildableMap with
        { ExpectedVisualizationRevision = firstBuildableFolder.VisualizationRevision });
        Check(buildableReadback.Roots.Single().Children?.Single().Name == "First folder",
            "A new Buildable root and its first folder survive an independent source file read");
        projectMap = projectMap with { ExpectedVisualizationRevision = firstBuildableFolder.VisualizationRevision };

        MapTreeMutationResult folderAdded = MapTreeService.Perform(new MapTreeActionRequest(
            projectMap, "newFolder", Target: mapLayers.Locator, Name: "Terrain group"));
        revision = folderAdded.VisualizationRevision;
        CatalogTreeNode folder = folderAdded.Roots.Single(root => root.Name == "Map Layers")
            .Children!.Single(node => node.Name == "Terrain group");
        MapTreeMutationResult folderRenamed = MapTreeService.Perform(new MapTreeActionRequest(
            projectMap with { ExpectedVisualizationRevision = revision }, "rename", Node: folder.Locator, Name: "Surface group"));
        revision = folderRenamed.VisualizationRevision;
        folder = folderRenamed.Roots.Single(root => root.Name == "Map Layers")
            .Children!.Single(node => node.Name == "Surface group");
        CatalogTreeNode layerToMove = folderRenamed.Roots.Single(root => root.Name == "Map Layers")
            .Children!.Single(node => node.Name == "Elevation");
        MapTreeMutationResult moved = MapTreeService.Perform(new MapTreeActionRequest(
            projectMap with { ExpectedVisualizationRevision = revision }, "move",
            Nodes: [layerToMove.Locator], Target: folder.Locator));
        revision = moved.VisualizationRevision;
        folder = moved.Roots.Single(root => root.Name == "Map Layers")
            .Children!.Single(node => node.Name == "Surface group");
        CatalogTreeNode movedLayer = folder.Children!.Single(node => node.Name == "Elevation");
        MapTreeMutationResult hidden = MapTreeService.Perform(new MapTreeActionRequest(
            projectMap with { ExpectedVisualizationRevision = revision }, "visibility",
            Node: movedLayer.Locator, Checked: false));
        string expectedRasterID = "vis-map-0-node-" + string.Join('.', hidden.Roots.Single(root => root.Name == "Map Layers")
            .Children!.Single(node => node.Name == "Surface group").Children!.Single().Locator!.NodePath!);
        Check(hidden.HiddenLayerIDs.Contains(expectedRasterID, StringComparer.Ordinal),
            "Visibility updates return the exact persisted single-band raster source identity for the selected map");

        string latestRevision = hidden.VisualizationRevision;
        MapDocumentMutationReceipt renamed = MapTreeService.RenameMap(new MapDocumentRequest(
            projectPath, projectXml, projectXmlSHA, latestRevision, "Project", MapIndex: 0,
            MapName: "Map", MapType: "Project", NewName: "Renamed Map"));
        XDocument saved = XDocument.Load(visualizationPath);
        Check(renamed.MapName == "Renamed Map" &&
              saved.Root!.Element("Maps")!.Attribute("Maps")?.Value == "Map" &&
              saved.Root.Attribute("UnknownRootAttribute")?.Value == "keep-root" &&
              saved.Root.Element("Maps")!.Elements("Map").ElementAt(1).Attribute("Name")?.Value == "Map" &&
              saved.Root.Element("Maps")!.Elements("Map").ElementAt(0).Attribute("UnknownMapAttribute")?.Value == "keep-map" &&
              saved.Root.Element("UnknownSection")?.Attribute("retained")?.Value == "yes",
            "Index-based map rename preserves duplicate map identities, ambiguous active selection and unknown XML");

        Expect<SourceFileChangedException>(() => MapTreeService.Load(projectMap with
        {
            ExpectedVisualizationRevision = latestRevision
        }));
        Check(File.ReadAllBytes(projectPath).SequenceEqual(projectBytes),
            "Map creation, tree actions and rename never save or alter the current .ras project file");
        CheckSavedGeometryAndBuildableMaps();
        CheckPlanResultMapRoundTrip();
        Console.WriteLine("Map tree saved Plan/Result workflows, Geometry focus, Buildable membership, sparse visibility, map deletion and source preservation passed.");
    }

    private static void CheckPlanResultMapRoundTrip()
    {
        string? fixtureDirectory = Environment.GetEnvironmentVariable("HECRAS_PLAN_MAP_ACCEPTANCE_DIRECTORY");
        if (string.IsNullOrWhiteSpace(fixtureDirectory) || !Directory.Exists(fixtureDirectory)) return;
        string sourceDirectory = Path.GetFullPath(fixtureDirectory);
        string manifestPath = Path.Combine(sourceDirectory, "acceptance.json");
        if (!File.Exists(manifestPath)) throw new FileNotFoundException("The retained Plan map acceptance manifest is missing.", manifestPath);

        using JsonDocument manifest = JsonDocument.Parse(File.ReadAllBytes(manifestPath));
        JsonElement root = manifest.RootElement;
        string projectRelativePath = root.GetProperty("projectRelativePath").GetString()!;
        string planRelativePath = root.GetProperty("planRelativePath").GetString()!;
        string planName = root.GetProperty("planName").GetString()!;
        JsonElement[] results = root.GetProperty("results").EnumerateArray().ToArray();
        if (results.Length < 2) throw new InvalidDataException("The retained Plan fixture must contain multiple Result HDFs.");
        string selectedResultRelativePath = results[0].GetProperty("path").GetString()!;
        string selectedResultRevision = results[0].GetProperty("revision").GetString()!;

        using var temporary = new TemporaryDirectory();
        string copyRoot = Path.Combine(temporary.FullName, "plan-map-fixture");
        Directory.CreateDirectory(copyRoot);
        foreach (string file in Directory.EnumerateFiles(sourceDirectory, "*", SearchOption.AllDirectories))
        {
            string destination = Path.Combine(copyRoot, Path.GetRelativePath(sourceDirectory, file));
            Directory.CreateDirectory(Path.GetDirectoryName(destination)!);
            File.Copy(file, destination, overwrite: false);
        }

        string projectPath = ResolveFixturePath(copyRoot, projectRelativePath);
        string planPath = ResolveFixturePath(copyRoot, planRelativePath);
        string selectedResultPath = ResolveFixturePath(copyRoot, selectedResultRelativePath);
        byte[] projectBefore = File.ReadAllBytes(projectPath);
        byte[] planBefore = File.ReadAllBytes(planPath);
        byte[] resultBefore = File.ReadAllBytes(selectedResultPath);
        string projectXml = File.ReadAllText(projectPath);
        string projectXmlSHA = Hash(Encoding.UTF8.GetBytes(projectXml));
        string planRevision = Hash(planBefore);
        string visualizationPath = Path.ChangeExtension(projectPath, ".vis");

        MapDocumentMutationReceipt created = MapTreeService.CreateMap(new MapDocumentRequest(
            projectPath, projectXml, projectXmlSHA, null, "Plan", Name: "Plan result view",
            InitialPlanPath: planPath, InitialPlanRevision: planRevision));
        var map = new MapTreeRequest(projectPath, projectXml, projectXmlSHA,
            "plan-result-roundtrip", created.MapIndex, created.MapName, created.MapType,
            created.VisualizationRevision);
        MapTreeSnapshot initial = MapTreeService.Load(map);
        Check(initial.Roots.Select(item => item.Name).SequenceEqual(["Focused Plans", "Matching Layers", "Layers"]),
            "A saved Plan map has the source Focused Plans, Matching Layers and Layers root order.");
        CatalogTreeNode initialPlan = FindPlan(initial.Roots, planPath);
        CatalogTreeNode initialGroup = (initialPlan.Children ?? []).Single(node => node.Locator?.NodeType == "MultiResult");
        Check(initialGroup.DiagnosticStatus == "loaded" && initialGroup.LayerErrors is not null &&
              initialGroup.DiagnosticSourceIdentity is { } latestDiagnosticPath &&
              initialGroup.DiagnosticSourceRevision == Hash(File.ReadAllBytes(latestDiagnosticPath)),
            "The Latest MultiResult diagnostics identify the exact stored Result snapshot, including a genuinely empty error list.");
        Check(PathEquals(initialGroup.Locator!.AssetID!, planPath) &&
              initialGroup.Locator.ParentPlanAssetID is { } parentPlan && PathEquals(parentPlan, planPath),
            "A Plan map stores its Result group under the exact project Plan identity.");

        MapTreeMutationResult added = MapTreeService.Perform(new MapTreeActionRequest(map, "addResult",
            SourcePath: selectedResultPath, SourceRevision: selectedResultRevision));
        var selectedMap = map with
        {
            ExpectedVisualizationRevision = added.VisualizationRevision,
            ResultSelectionOverrides = [new MapTreeResultSelectionOverride(planPath, planName,
                selectedResultPath, selectedResultRevision)]
        };
        MapTreeSnapshot selected = MapTreeService.Load(selectedMap);
        CatalogTreeNode selectedPlan = FindPlan(selected.Roots, planPath);
        CatalogTreeNode selectedGroup = (selectedPlan.Children ?? []).Single(node => node.Locator?.NodeType == "MultiResult");
        CatalogTreeNode catalogResult = CatalogTreeService.LoadCatalog(new CatalogTreeRequest(projectPath, projectXml))
            .Roots.SelectMany(Flatten).Single(node => node.SourceClass == "ObservableResult" &&
                node.AssetID is { } resultPath && PathEquals(resultPath, selectedResultPath));
        Check(selectedGroup.DiagnosticStatus == catalogResult.DiagnosticStatus &&
              selectedGroup.DiagnosticSourceIdentity is { } selectedDiagnosticPath &&
              PathEquals(selectedDiagnosticPath, selectedResultPath) &&
              string.Equals(selectedGroup.DiagnosticSourceRevision, selectedResultRevision,
                  StringComparison.OrdinalIgnoreCase) &&
              JsonSerializer.Serialize(selectedGroup.LayerErrors) == JsonSerializer.Serialize(catalogResult.LayerErrors),
            "An explicit MultiResult selection copies diagnostics from the selected Result's exact SHA, rather than its Plan or another child.");
        CatalogTreeNode[] embeddedGeometry = (selectedGroup.Children ?? []).SelectMany(Flatten)
            .Where(node => node.Locator is { NodeType: "Geometry", ParentResultNodeType: "MultiResult" })
            .ToArray();
        CatalogTreeNode[] embeddedBoundaries = (selectedGroup.Children ?? []).SelectMany(Flatten)
            .Where(node => node.Locator is { NodeType: "BoundaryCondition", ParentResultNodeType: "MultiResult" })
            .ToArray();
        Check(selectedPlan.Checked is null && selectedGroup.Checked == "checked" &&
              PathEquals(selectedGroup.Locator!.AssetID!, planPath) &&
              selectedGroup.Locator.ParentPlanAssetID is { } selectedPlanOwner && PathEquals(selectedPlanOwner, planPath) &&
              embeddedGeometry.Length == 1 && embeddedBoundaries.Length == 1 &&
              PathEquals(embeddedGeometry[0].Locator!.ParentResultAssetID!, selectedResultPath) &&
              PathEquals(embeddedBoundaries[0].Locator!.ParentResultAssetID!, selectedResultPath) &&
              string.Equals(embeddedGeometry[0].Locator!.ParentResultRevision, selectedResultRevision,
                  StringComparison.OrdinalIgnoreCase) &&
              string.Equals(embeddedBoundaries[0].Locator!.ParentResultRevision, selectedResultRevision,
                  StringComparison.OrdinalIgnoreCase),
            "Plan addResult checks the exact MultiResult row without making its non-checkable Plan parent a visibility gate, and binds embedded Geometry/BoundaryCondition to the selected Result HDF and SHA.");

        MapTreeMutationResult viewed = MapTreeService.Perform(new MapTreeActionRequest(selectedMap,
            "setResultViewState", Node: selectedGroup.Locator, Name: "Depth", ProfileIndex: 1));
        var reopenedRequest = selectedMap with { ExpectedVisualizationRevision = viewed.VisualizationRevision };
        MapTreeSnapshot reopened = MapTreeService.Load(reopenedRequest);
        CatalogTreeNode reopenedGroup = (FindPlan(reopened.Roots, planPath).Children ?? [])
            .Single(node => node.Locator?.NodeType == "MultiResult");
        Check((string?)XDocument.Load(visualizationPath).Root!.Element("Maps")!.Elements("Map")
                  .ElementAt(created.MapIndex).Descendants("Node")
                  .Single(node => (string?)node.Attribute("Type") == "MultiResult").Attribute("SelectedMapType") == "Depth" &&
              (string?)XDocument.Load(visualizationPath).Root!.Element("Maps")!.Elements("Map")
                  .ElementAt(created.MapIndex).Descendants("Node")
                  .Single(node => (string?)node.Attribute("Type") == "MultiResult").Attribute("ProfileIndex") == "1" &&
              reopenedGroup.Locator?.ParentPlanAssetID is { } reopenedPlanOwner && PathEquals(reopenedPlanOwner, planPath) &&
              PathEquals(reopenedGroup.Locator.AssetID!, planPath),
            "Plan MultiResult map type and profile index persist on the exact serialized group row and reopen with its Plan owner.");

        string planVectorPath = Path.Combine(copyRoot, "Plan overlay.geojson");
        File.WriteAllText(planVectorPath,
            "{\"type\":\"FeatureCollection\",\"features\":[{\"type\":\"Feature\",\"properties\":{\"name\":\"center\"},\"geometry\":{\"type\":\"LineString\",\"coordinates\":[[0,0],[1,1]]}}]}",
            Encoding.UTF8);
        byte[] planVectorBefore = File.ReadAllBytes(planVectorPath);
        MapTreeMutationResult planOverlay = MapTreeService.Perform(new MapTreeActionRequest(reopenedRequest,
            "addGeoJSONVector", SourcePath: planVectorPath, SourceRevision: Hash(planVectorBefore)));
        var planOverlayRequest = reopenedRequest with { ExpectedVisualizationRevision = planOverlay.VisualizationRevision };
        CatalogTreeNode planOverlayLayer = planOverlay.Roots.Single(node => node.Name == "Layers").Children!
            .Single(node => node.SourceClass == "PolylineMapLayerVisualContext");
        Check(PathEquals(planOverlayLayer.AssetID!, planVectorPath) && planOverlayLayer.Checked == "checked" &&
              planOverlayLayer.Locator is { RootName: "Layers", NodePath: { Length: 2 } },
            "The inherited Buildable map-layer action inserts a checked GeoJSON source under a saved Plan map Layers root.");

        MapTreeMutationResult removed = MapTreeService.Perform(new MapTreeActionRequest(planOverlayRequest,
            "removeSourceNode", Node: FindPlan(planOverlay.Roots, planPath).Locator,
            SourcePath: planPath, SourceRevision: planRevision));
        Check(!removed.Roots.SelectMany(Flatten).Any(node => node.Locator?.NodeType == "Plan" &&
                node.Locator.AssetID is { } asset && PathEquals(asset, planPath)),
            "Removing a focused Plan removes only that saved Plan row from the map tree.");
        Check(removed.Roots.Single(node => node.Name == "Layers").Children?.Any(node =>
                node.SourceClass == "PolylineMapLayerVisualContext" && PathEquals(node.AssetID!, planVectorPath)) == true &&
              File.ReadAllBytes(planVectorPath).SequenceEqual(planVectorBefore),
            "Removing a Plan focus leaves its independent Layers map data and source file intact.");
        Check(File.ReadAllBytes(projectPath).SequenceEqual(projectBefore) &&
              File.ReadAllBytes(planPath).SequenceEqual(planBefore) &&
              File.ReadAllBytes(selectedResultPath).SequenceEqual(resultBefore),
            "Plan map membership, Result view state and removal modify only the copied .vis document, not source Project/Plan/Result files.");

        var removedPlanMap = planOverlayRequest with
        { ExpectedVisualizationRevision = removed.VisualizationRevision };
        MapTreeMutationResult refocusedPlan = MapTreeService.Perform(new MapTreeActionRequest(removedPlanMap,
            "focusPlan", SourcePath: planPath, SourceRevision: planRevision));
        var refocusedPlanMap = removedPlanMap with
        { ExpectedVisualizationRevision = refocusedPlan.VisualizationRevision };
        MapTreeMutationResult restoredResult = MapTreeService.Perform(new MapTreeActionRequest(refocusedPlanMap,
            "addResult", SourcePath: selectedResultPath, SourceRevision: selectedResultRevision));
        var restoredResultMap = refocusedPlanMap with
        { ExpectedVisualizationRevision = restoredResult.VisualizationRevision };
        CatalogTreeNode restoredGroup = (FindPlan(restoredResult.Roots, planPath).Children ?? [])
            .Single(node => node.Locator?.NodeType == "MultiResult");
        Check(restoredGroup.Checked == "checked" &&
              restoredGroup.Locator?.AssetID is { } restoredPlanAsset && PathEquals(restoredPlanAsset, planPath),
            "Refocusing the exact Plan and adding its retained Result restores a checked source-owned MultiResult row.");
        MapTreeMutationResult restoredView = MapTreeService.Perform(new MapTreeActionRequest(restoredResultMap,
            "setResultViewState", Node: restoredGroup.Locator, Name: "Depth", ProfileIndex: 1));
        var survivingPlanRequest = restoredResultMap with
        { ExpectedVisualizationRevision = restoredView.VisualizationRevision };

        MapDocumentMutationReceipt geometryMapCreated = MapTreeService.CreateMap(new MapDocumentRequest(
            projectPath, projectXml, projectXmlSHA, restoredView.VisualizationRevision, "Geometry",
            Name: "Geometry result view"));
        var geometryMap = new MapTreeRequest(projectPath, projectXml, projectXmlSHA,
            "geometry-result-roundtrip", geometryMapCreated.MapIndex, geometryMapCreated.MapName,
            geometryMapCreated.MapType, geometryMapCreated.VisualizationRevision);
        MapTreeMutationResult geometryAdded = MapTreeService.Perform(new MapTreeActionRequest(geometryMap, "addResult",
            SourcePath: selectedResultPath, SourceRevision: selectedResultRevision));
        var selectedGeometryMap = geometryMap with
        {
            ExpectedVisualizationRevision = geometryAdded.VisualizationRevision,
            ResultSelectionOverrides = [new MapTreeResultSelectionOverride(planPath, planName,
                selectedResultPath, selectedResultRevision)]
        };
        MapTreeSnapshot geometrySelected = MapTreeService.Load(selectedGeometryMap);
        CatalogTreeNode geometryGroup = geometrySelected.Roots.Single(node => node.Name == "Layers")
            .Children!.Single(node => node.Locator?.NodeType == "MultiResult");
        CatalogTreeNode[] geometryOwnedRows = (geometryGroup.Children ?? []).SelectMany(Flatten)
            .Where(node => node.Locator is { NodeType: "Geometry", ParentResultNodeType: "MultiResult" })
            .ToArray();
        CatalogTreeNode[] boundaryOwnedRows = (geometryGroup.Children ?? []).SelectMany(Flatten)
            .Where(node => node.Locator is { NodeType: "BoundaryCondition", ParentResultNodeType: "MultiResult" })
            .ToArray();
        Check(geometryGroup.Checked == "checked" && geometryOwnedRows.Length == 1 && boundaryOwnedRows.Length == 1 &&
              PathEquals(geometryOwnedRows[0].Locator!.ParentResultAssetID!, selectedResultPath) &&
              PathEquals(boundaryOwnedRows[0].Locator!.ParentResultAssetID!, selectedResultPath) &&
              geometryOwnedRows[0].Locator!.ParentResultNodePath!.SequenceEqual(geometryGroup.Locator!.NodePath!) &&
              string.Equals(geometryOwnedRows[0].Locator!.ParentResultRevision, selectedResultRevision,
                  StringComparison.OrdinalIgnoreCase),
            "Geometry-map addResult binds embedded Geometry and BoundaryCondition children to the exact Result group path, HDF and revision.");
        MapTreeMutationResult geometryViewed = MapTreeService.Perform(new MapTreeActionRequest(selectedGeometryMap,
            "setResultViewState", Node: geometryGroup.Locator, Name: "Depth", ProfileIndex: 1));
        var geometryReopenedRequest = selectedGeometryMap with
        { ExpectedVisualizationRevision = geometryViewed.VisualizationRevision };
        CatalogTreeNode reopenedGeometryGroup = MapTreeService.Load(geometryReopenedRequest).Roots
            .Single(node => node.Name == "Layers").Children!
            .Single(node => node.Locator?.NodeType == "MultiResult");
        XElement savedGeometryGroup = XDocument.Load(visualizationPath).Root!.Element("Maps")!.Elements("Map")
            .ElementAt(geometryMapCreated.MapIndex).Descendants("Node")
            .Single(node => (string?)node.Attribute("Type") == "MultiResult");
        Check((string?)savedGeometryGroup.Attribute("SelectedMapType") == "Depth" &&
              (string?)savedGeometryGroup.Attribute("ProfileIndex") == "1" &&
              PathEquals(reopenedGeometryGroup.Locator!.AssetID!, planPath) &&
              geometryReopenedRequest.ResultSelectionOverrides!.Single().SelectedResultRevision == selectedResultRevision,
            "Geometry-map Result view type and profile index persist on the exact MultiResult and reopen with its selected Result context.");
        Check(File.ReadAllBytes(projectPath).SequenceEqual(projectBefore) &&
              File.ReadAllBytes(planPath).SequenceEqual(planBefore) &&
              File.ReadAllBytes(selectedResultPath).SequenceEqual(resultBefore),
            "Geometry-map Result membership and view-state writes leave source Project, Plan and Result files unchanged.");

        MapDocumentDeleteReceipt deletedGeometry = MapTreeService.DeleteMap(new MapDocumentRequest(
            projectPath, projectXml, projectXmlSHA, geometryViewed.VisualizationRevision, "Delete",
            MapIndex: geometryMapCreated.MapIndex, MapName: geometryMapCreated.MapName,
            MapType: geometryMapCreated.MapType));
        MapDocumentIndexChange survivingPlan = deletedGeometry.MapIndexChanges.Single();
        Check(deletedGeometry.RemovedMapIndex == geometryMapCreated.MapIndex &&
              deletedGeometry.RemovedMapName == geometryMapCreated.MapName &&
              deletedGeometry.RemovedMapType == "Geometry" &&
              survivingPlan.PreviousMapIndex == created.MapIndex && survivingPlan.MapIndex == 0 &&
              survivingPlan.MapName == created.MapName && survivingPlan.MapType == "Plan",
            "Deleting a saved map removes its exact map definition and returns the surviving map-index remap.");
        var planAfterDelete = survivingPlanRequest with
        {
            MapIndex = survivingPlan.MapIndex,
            MapName = survivingPlan.MapName,
            MapType = survivingPlan.MapType,
            ExpectedVisualizationRevision = deletedGeometry.VisualizationRevision
        };
        CatalogTreeNode planGroupAfterDelete = MapTreeService.Load(planAfterDelete).Roots
            .SelectMany(Flatten).Single(node => node.Locator?.NodeType == "MultiResult");
        XElement survivingPlanMap = XDocument.Load(visualizationPath).Root!.Element("Maps")!.Elements("Map").Single();
        XElement survivingPlanGroup = survivingPlanMap.Descendants("Node")
            .Single(node => (string?)node.Attribute("Type") == "MultiResult");
        Check(planGroupAfterDelete.Locator?.AssetID is { } planAfterDeleteAsset &&
              PathEquals(planAfterDeleteAsset, planPath) &&
              planGroupAfterDelete.Locator!.ParentPlanAssetID is { } planAfterDeleteOwner &&
              PathEquals(planAfterDeleteOwner, planPath) &&
              (string?)survivingPlanMap.Attribute("Type") == "Plan" &&
              (string?)survivingPlanGroup.Attribute("SelectedMapType") == "Depth" &&
              (string?)survivingPlanGroup.Attribute("ProfileIndex") == "1" &&
              File.ReadAllBytes(projectPath).SequenceEqual(projectBefore) &&
              File.ReadAllBytes(planPath).SequenceEqual(planBefore) &&
              File.ReadAllBytes(selectedResultPath).SequenceEqual(resultBefore),
            "Deleting a map leaves the surviving Plan and its exact Result state usable while preserving all source files.");
    }

    private static string ResolveFixturePath(string root, string relativePath) =>
        Path.GetFullPath(Path.Combine(root, relativePath.Replace('/', Path.DirectorySeparatorChar)));

    private static CatalogTreeNode FindPlan(IEnumerable<CatalogTreeNode> roots, string sourcePath) =>
        roots.SelectMany(Flatten).Single(node => node.Locator?.NodeType == "Plan" &&
            node.Locator.AssetID is { } path && PathEquals(path, sourcePath));

    private static XElement EnsureUniqueBuildableLayersRoot(XElement map)
    {
        XElement[] trees = map.Elements("Tree").ToArray();
        if (trees.Length > 1)
            throw new InvalidDataException("The Buildable map fixture has ambiguous Tree elements.");
        XElement tree = trees.SingleOrDefault() ?? new XElement("Tree");
        if (tree.Parent is null) map.Add(tree);

        XElement[] nodeContainers = tree.Elements("Nodes").ToArray();
        if (nodeContainers.Length > 1)
            throw new InvalidDataException("The Buildable map fixture has ambiguous Tree/Nodes elements.");
        XElement nodes = nodeContainers.SingleOrDefault() ?? new XElement("Nodes");
        if (nodes.Parent is null) tree.Add(nodes);

        XElement[] roots = nodes.Elements("Node").Where(node =>
            (string?)node.Attribute("Type") == "Root" && (string?)node.Attribute("Name") == "Layers").ToArray();
        if (roots.Length > 1)
            throw new InvalidDataException("The Buildable map fixture has ambiguous Layers roots.");
        XElement root = roots.SingleOrDefault() ?? new XElement("Node",
            new XAttribute("Type", "Root"), new XAttribute("Name", "Layers"));
        if (root.Parent is null) nodes.Add(root);
        return root;
    }

    private static void CheckSavedGeometryAndBuildableMaps()
    {
        using var temporary = new TemporaryDirectory();
        string projectPath = Path.Combine(temporary.FullName, "Geometry map actions.ras");
        Project project = Project.CreateNew(projectPath, UnitSystem.SI);
        Geometry first = project.AddNewGeometry("Map geometry A");
        Geometry second = project.AddNewGeometry("Map geometry B");
        BoundaryCondition boundary = project.AddNewBoundaryCondition("Map boundary",
            new DateTime(2026, 10, 16, 8, 0, 0), TimeSpan.FromHours(1));
        string firstPath = SourcePath(projectPath, first.Filename);
        string secondPath = SourcePath(projectPath, second.Filename);
        string boundaryPath = SourcePath(projectPath, boundary.Filename);
        project.Save();
        first.Save();
        second.Save();
        boundary.Save();
        Dispose(project);

        byte[] projectBefore = File.ReadAllBytes(projectPath);
        byte[] firstBefore = File.ReadAllBytes(firstPath);
        byte[] secondBefore = File.ReadAllBytes(secondPath);
        byte[] boundaryBefore = File.ReadAllBytes(boundaryPath);
        string projectXml = File.ReadAllText(projectPath);
        string projectXmlSHA = Hash(Encoding.UTF8.GetBytes(projectXml));
        string visualizationPath = Path.ChangeExtension(projectPath, ".vis");

        MapDocumentMutationReceipt geometryMapReceipt = MapTreeService.CreateMap(new MapDocumentRequest(
            projectPath, projectXml, projectXmlSHA, null, "Geometry", Name: "Geometry view",
            InitialGeometryPath: firstPath, InitialGeometryRevision: Hash(firstBefore)));
        var geometryMap = new MapTreeRequest(projectPath, projectXml, projectXmlSHA,
            "geometry-map-actions", geometryMapReceipt.MapIndex, geometryMapReceipt.MapName,
            geometryMapReceipt.MapType, geometryMapReceipt.VisualizationRevision);
        MapTreeSnapshot initialGeometryTree = MapTreeService.Load(geometryMap);
        Check(initialGeometryTree.Roots.Select(root => root.Name).SequenceEqual(
                ["Focused Geometries", "Matching Layers", "Layers"]) &&
              FindGeometry(initialGeometryTree.Roots, firstPath).Checked == "unchecked",
            "A saved Geometry map uses the source root order and keeps the initial focus in the source unchecked state.");

        // Unknown per-map state is not owned by this adapter and must survive
        // the source-root synchronization caused by a later focus action.
        XDocument visualization = XDocument.Load(visualizationPath, LoadOptions.PreserveWhitespace);
        XElement geometryMapElement = visualization.Root!.Element("Maps")!.Elements("Map")
            .ElementAt(geometryMapReceipt.MapIndex);
        geometryMapElement.SetAttributeValue("VendorMapState", "preserve");
        XElement geometryTreeNodes = geometryMapElement.Element("Tree")!.Element("Nodes")!;
        XElement geometryLayersRoot = geometryTreeNodes.Elements("Node").Single(node =>
            (string?)node.Attribute("Type") == "Root" && (string?)node.Attribute("Name") == "Layers");
        geometryLayersRoot.Add(new XElement("Node", new XAttribute("Type", "BoundaryCondition"),
            new XAttribute("Name", "Map boundary"), new XAttribute("IsChecked", true)));
        geometryTreeNodes.Add(
            new XElement("Node", new XAttribute("Type", "Root"), new XAttribute("Name", "Vendor state"),
                new XElement("Node", new XAttribute("Type", "VendorLayer"), new XAttribute("Name", "Vendor child"))));
        visualization.Save(visualizationPath, SaveOptions.DisableFormatting);
        geometryMap = geometryMap with { ExpectedVisualizationRevision = Hash(File.ReadAllBytes(visualizationPath)) };
        CatalogTreeNode geometryBoundary = MapTreeService.Load(geometryMap).Roots
            .Single(node => node.Name == "Layers").Children!
            .Single(node => node.Locator?.NodeType == "BoundaryCondition");
        Check(geometryBoundary.Checked == "checked" &&
              PathEquals(geometryBoundary.AssetID!, boundaryPath) &&
              geometryBoundary.Locator is { RootName: "Layers", NodePath: { Length: 2 } },
            "A saved Geometry map resolves its direct Layers BoundaryCondition row to the exact project HDF and keeps its visibility state.");

        Expect<SourceFileChangedException>(() => MapTreeService.Perform(new MapTreeActionRequest(
            geometryMap, "focusGeometry", SourcePath: secondPath, SourceRevision: new string('0', 64))));
        MapTreeMutationResult focused = MapTreeService.Perform(new MapTreeActionRequest(
            geometryMap, "focusGeometry", SourcePath: secondPath, SourceRevision: Hash(secondBefore)));
        geometryMap = geometryMap with { ExpectedVisualizationRevision = focused.VisualizationRevision };
        CatalogTreeNode[] focusedRows = focused.Roots.SelectMany(Flatten)
            .Where(node => node.Locator?.NodeType == "Geometry").ToArray();
        Check(focusedRows.Length == 2 &&
              PathEquals(focusedRows[0].Locator!.AssetID!, firstPath) &&
              PathEquals(focusedRows[1].Locator!.AssetID!, secondPath),
            "focusGeometry appends the exact source Geometry in focus order without name-based rebinding.");
        XDocument focusedVisualization = XDocument.Load(visualizationPath);
        XElement focusedMapElement = focusedVisualization.Root!.Element("Maps")!.Elements("Map")
            .ElementAt(geometryMapReceipt.MapIndex);
        Check(focusedMapElement.Attribute("VendorMapState")?.Value == "preserve" &&
              focusedMapElement.Descendants("Node").Any(node =>
                  (string?)node.Attribute("Type") == "VendorLayer" &&
                  (string?)node.Attribute("Name") == "Vendor child"),
            "Focusing a source Geometry preserves unknown .vis attributes and nodes.");
        Expect<SourceFileChangedException>(() => MapTreeService.Load(geometryMap with
        {
            ExpectedVisualizationRevision = geometryMapReceipt.VisualizationRevision
        }));

        MapDocumentMutationReceipt buildableReceipt = MapTreeService.CreateMap(new MapDocumentRequest(
            projectPath, projectXml, projectXmlSHA, focused.VisualizationRevision, "Buildable", Name: "Buildable view"));
        var buildableMap = new MapTreeRequest(projectPath, projectXml, projectXmlSHA,
            "buildable-map-actions", buildableReceipt.MapIndex, buildableReceipt.MapName,
            buildableReceipt.MapType, buildableReceipt.VisualizationRevision);
        geometryMap = geometryMap with { ExpectedVisualizationRevision = buildableReceipt.VisualizationRevision };
        XDocument withBuildableBoundary = XDocument.Load(visualizationPath, LoadOptions.PreserveWhitespace);
        XElement buildableMapElement = withBuildableBoundary.Root!.Element("Maps")!.Elements("Map")
            .ElementAt(buildableReceipt.MapIndex);
        XElement buildableLayersRoot = EnsureUniqueBuildableLayersRoot(buildableMapElement);
        buildableLayersRoot.Add(new XElement("Node", new XAttribute("Type", "BoundaryCondition"),
            new XAttribute("Name", "Map boundary"), new XAttribute("IsChecked", true)));
        withBuildableBoundary.Save(visualizationPath, SaveOptions.DisableFormatting);
        string withBuildableBoundaryRevision = Hash(File.ReadAllBytes(visualizationPath));
        buildableMap = buildableMap with { ExpectedVisualizationRevision = withBuildableBoundaryRevision };
        geometryMap = geometryMap with { ExpectedVisualizationRevision = withBuildableBoundaryRevision };
        CatalogTreeNode buildableBoundary = MapTreeService.Load(buildableMap).Roots.Single().Children!
            .Single(node => node.Locator?.NodeType == "BoundaryCondition");
        Check(buildableBoundary.Checked == "checked" &&
              PathEquals(buildableBoundary.AssetID!, boundaryPath) &&
              buildableBoundary.Locator is { RootName: "Layers", NodePath: { Length: 2 } },
            "A saved Buildable map resolves its direct Layers BoundaryCondition row to the exact project HDF and preserves the checked state.");
        Check(MapTreeService.Load(buildableMap).Roots.Single().Name == "Layers",
            "A saved Buildable map starts with its source Layers root.");
        MapTreeMutationResult added = MapTreeService.Perform(new MapTreeActionRequest(
            buildableMap, "addGeometry", SourcePath: secondPath, SourceRevision: Hash(secondBefore)));
        buildableMap = buildableMap with { ExpectedVisualizationRevision = added.VisualizationRevision };
        geometryMap = geometryMap with { ExpectedVisualizationRevision = added.VisualizationRevision };
        CatalogTreeNode buildableGeometry = FindGeometry(added.Roots, secondPath);
        Check(buildableGeometry.Checked == "checked" &&
              buildableGeometry.Locator is { RootName: "Layers", NodePath: { Length: >= 2 } },
            "Buildable addGeometry creates and checks the exact Geometry row below Layers.");

        CatalogTreeNode buildableChild = FindGeometryChild(buildableGeometry);
        MapTreeMutationResult childEnabled = MapTreeService.Perform(new MapTreeActionRequest(
            buildableMap, "visibility", Node: buildableChild.Locator, Checked: true));
        buildableMap = buildableMap with { ExpectedVisualizationRevision = childEnabled.VisualizationRevision };
        geometryMap = geometryMap with { ExpectedVisualizationRevision = childEnabled.VisualizationRevision };
        CatalogTreeNode visibleBuildableGeometry = FindGeometry(childEnabled.Roots, secondPath);
        CatalogTreeNode visibleBuildableChild = FindGeometryChild(visibleBuildableGeometry);
        Check(visibleBuildableGeometry.Checked == "checked" && visibleBuildableChild.Checked == "checked" &&
              IsRenderedChildVisible(buildableMap, visibleBuildableGeometry, visibleBuildableChild),
            "Checking a Geometry child enables its checkable ancestors and makes the child effectively visible.");

        CatalogTreeNode focusedSecond = FindGeometry(MapTreeService.Load(geometryMap).Roots, secondPath);
        Check(focusedSecond.Checked == "unchecked",
            "Buildable membership and visibility are isolated from the same Geometry in a saved Geometry map.");
        CatalogTreeNode geometryChild = FindGeometryChild(focusedSecond);
        MapTreeMutationResult geometryChildEnabled = MapTreeService.Perform(new MapTreeActionRequest(
            geometryMap, "visibility", Node: geometryChild.Locator, Checked: true));
        geometryMap = geometryMap with { ExpectedVisualizationRevision = geometryChildEnabled.VisualizationRevision };
        buildableMap = buildableMap with { ExpectedVisualizationRevision = geometryChildEnabled.VisualizationRevision };
        CatalogTreeNode enabledGeometry = FindGeometry(geometryChildEnabled.Roots, secondPath);
        CatalogTreeNode enabledGeometryChild = FindGeometryChild(enabledGeometry);
        MapTreeMutationResult geometryParentDisabled = MapTreeService.Perform(new MapTreeActionRequest(
            geometryMap, "visibility", Node: enabledGeometry.Locator, Checked: false));
        geometryMap = geometryMap with { ExpectedVisualizationRevision = geometryParentDisabled.VisualizationRevision };
        buildableMap = buildableMap with { ExpectedVisualizationRevision = geometryParentDisabled.VisualizationRevision };
        CatalogTreeNode disabledGeometry = FindGeometry(geometryParentDisabled.Roots, secondPath);
        CatalogTreeNode retainedGeometryChild = FindGeometryChild(disabledGeometry);
        Check(disabledGeometry.Checked == "unchecked" && retainedGeometryChild.Checked == "checked" &&
              !IsRenderedChildVisible(geometryMap, disabledGeometry, retainedGeometryChild) &&
              FindGeometry(MapTreeService.Load(buildableMap).Roots, secondPath).Checked == "checked",
            "Unchecking a Geometry parent retains the child flag, gates effective visibility, and does not alter another map.");

        MapTreeMutationResult buildableParentDisabled = MapTreeService.Perform(new MapTreeActionRequest(
            buildableMap, "visibility", Node: visibleBuildableGeometry.Locator, Checked: false));
        buildableMap = buildableMap with { ExpectedVisualizationRevision = buildableParentDisabled.VisualizationRevision };
        geometryMap = geometryMap with { ExpectedVisualizationRevision = buildableParentDisabled.VisualizationRevision };
        CatalogTreeNode disabledBuildable = FindGeometry(buildableParentDisabled.Roots, secondPath);
        CatalogTreeNode retainedBuildableChild = FindGeometryChild(disabledBuildable);
        Check(disabledBuildable.Checked == "unchecked" && retainedBuildableChild.Checked == "checked" &&
              !IsRenderedChildVisible(buildableMap, disabledBuildable, retainedBuildableChild),
            "Buildable Geometry parent visibility also preserves the independently stored child flag.");

        MapTreeMutationResult removedBuildable = MapTreeService.Perform(new MapTreeActionRequest(
            buildableMap, "removeSourceNode", Node: disabledBuildable.Locator,
            SourcePath: secondPath, SourceRevision: Hash(secondBefore)));
        buildableMap = buildableMap with { ExpectedVisualizationRevision = removedBuildable.VisualizationRevision };
        geometryMap = geometryMap with { ExpectedVisualizationRevision = removedBuildable.VisualizationRevision };
        Check(!removedBuildable.Roots.SelectMany(Flatten).Any(node => node.Locator?.NodeType == "Geometry" &&
                node.Locator.AssetID is { } asset && PathEquals(asset, secondPath)),
            "removeSourceNode removes only the exact source Geometry from the Buildable map.");
        MapTreeMutationResult removedFocus = MapTreeService.Perform(new MapTreeActionRequest(
            geometryMap, "removeSourceNode", Node: disabledGeometry.Locator,
            SourcePath: secondPath, SourceRevision: Hash(secondBefore)));
        geometryMap = geometryMap with { ExpectedVisualizationRevision = removedFocus.VisualizationRevision };
        Check(removedFocus.Roots.SelectMany(Flatten).Where(node => node.Locator?.NodeType == "Geometry")
                .Select(node => node.Locator!.AssetID).SequenceEqual([FindGeometry(removedFocus.Roots, firstPath).Locator!.AssetID]),
            "removeSourceNode removes only the requested focus row and leaves the other Geometry focus in order.");
        Check(File.ReadAllBytes(projectPath).SequenceEqual(projectBefore) &&
              File.ReadAllBytes(firstPath).SequenceEqual(firstBefore) &&
              File.ReadAllBytes(secondPath).SequenceEqual(secondBefore) &&
              File.ReadAllBytes(boundaryPath).SequenceEqual(boundaryBefore),
            "Saved Geometry and Buildable map tree actions modify only the .vis file, not project, Geometry or BoundaryCondition HDF sources.");
    }

    private static string SourcePath(string projectPath, string filename) => Path.GetFullPath(
        Path.IsPathRooted(filename) ? filename : Path.Combine(Path.GetDirectoryName(projectPath)!, filename));

    // Assert visibility through the public renderer contract, so this test
    // covers the user-facing source result rather than a private tree helper.
    private static bool IsRenderedChildVisible(MapTreeRequest map,
        CatalogTreeNode geometry, CatalogTreeNode child)
    {
        MapGeometrySnapshot snapshot = ModelEditorAdapter.LoadMapGeometryAsync(
            new MapGeometryRequest(map, geometry.Locator!, PageSize: 1,
                SkipTopologyPage: true, SkipFlowAreasPage: true, SkipCulvertsPage: true))
            .GetAwaiter().GetResult();
        return child.Locator?.NodeType switch
        {
            "ConceptualMesh" => snapshot.TopologyState.EffectiveVisible,
            "FlowAreaLayer" => snapshot.FlowAreasState.EffectiveVisible,
            "CulvertBarrelLayer" => snapshot.CulvertsState.EffectiveVisible,
            _ => throw new InvalidOperationException("The selected source child is not a rendered Geometry layer.")
        };
    }

    private static CatalogTreeNode FindGeometry(IEnumerable<CatalogTreeNode> roots, string sourcePath) =>
        roots.SelectMany(Flatten).Single(node => node.Locator?.NodeType == "Geometry" &&
            node.Locator.AssetID is { } path && PathEquals(path, sourcePath));

    private static CatalogTreeNode FindGeometryChild(CatalogTreeNode geometry) =>
        (geometry.Children ?? []).First(node => node.Locator?.NodeType is "ConceptualMesh" or "FlowAreaLayer" or "CulvertBarrelLayer");

    private static IEnumerable<CatalogTreeNode> Flatten(CatalogTreeNode node)
    {
        yield return node;
        if (node.Children is { Length: > 0 } children)
            foreach (CatalogTreeNode child in children.SelectMany(Flatten)) yield return child;
    }

    private static bool PathEquals(string first, string second)
    {
        StringComparison comparison = OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal;
        return string.Equals(Path.GetFullPath(first), Path.GetFullPath(second), comparison);
    }

    private static void Dispose(Project project)
    {
        foreach (CoreLayerBase layer in project.Plans.Cast<CoreLayerBase>().Concat(project.Geometries)
            .Concat(project.Terrains).Concat(project.BoundaryConditions).Concat(project.NValues)
            .Concat(project.ClassificationLayers)) layer.Dispose();
        foreach (Result result in project.Results) result.Dispose();
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
}
