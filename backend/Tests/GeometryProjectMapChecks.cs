using System.Security.Cryptography;
using System.Text;
using System.Xml.Linq;
using Geospatial;
using Geospatial.Vectors;
using Geospatial.Vectors.MeshTopology;
using Geospatial.Vectors.Topology;
using Ras.Backend;
using Ras.Hydraulics.Culverts;
using Ras.Layers;
using Utility.Files;
using Utility.Units;

/// <summary>
/// Source regression coverage for read-only Geometry data on saved Project
/// maps, sparse .vis visibility, source-bound paging, and fixture export.
/// </summary>
internal static class GeometryProjectMapChecks
{
    private const int FullPageSize = 512;

    internal static async Task Run()
    {
        using var directory = new TemporaryDirectory();
        string projectPath = Path.Combine(directory.FullName, "Geometry project map.ras");
        Project project = Project.CreateNew(projectPath, UnitSystem.SI);
        Geometry first = project.AddNewGeometry("Map geometry A");
        Geometry second = project.AddNewGeometry("Map geometry B");
        first.ConceptualMeshLayer.Topology = Topology.FromExtent(new Extent(0, 20, 0, 20));
        AddSourceCulverts(second);
        string firstAssetPath = first.Filename;
        string secondAssetPath = second.Filename;
        project.Save();
        first.Save();
        second.Save();
        Dispose(project);

        // Use retained source topology and mesh generation. A fine but real
        // TrianglePaver mesh produces enough source cells to exercise both the
        // endpoint's scan continuation and complete native paging.
        var topologyModel = new GeometryTopologyModelRequest(firstAssetPath, "Geometry", projectPath);
        GeometryTopologySnapshot topologyLoaded = await ModelEditorAdapter.LoadGeometryTopologyAsync(new(topologyModel));
        GeometryTopologySnapshot trianglePatch = await EditTopology(topologyModel, topologyLoaded,
            new("setField", "region", [0], "PatchType", "TrianglePaver"));
        GeometryTopologySnapshot primarySize = await EditTopology(topologyModel, trianglePatch,
            new("setField", "region", [0], "ConstantSize", "0.15"));
        GeometryTopologySnapshot topologyDraft = await EditTopology(topologyModel, primarySize,
            new("setField", "region", [0], "SecondaryConstantSize", "0.15"));
        var meshModel = new GeometryMeshModelRequest(firstAssetPath, "Geometry", projectPath);
        GeometryMeshSnapshot meshBase = await ModelEditorAdapter.LoadGeometryMeshAsync(new(meshModel,
            TopologyDraftState: topologyDraft.DraftState));
        GeometryMeshSnapshot meshPreview = await ModelEditorAdapter.EditGeometryMeshAsync(new(meshModel,
            meshBase.Revision, meshBase.DraftState, topologyDraft.DraftState,
            meshBase.SelectedRegionIDs, new("generate")));
        Check(meshPreview.GenerationReport is { Succeeded: true, MeshWasReplaced: true, CellCount: > 16_384 },
            "The retained TrianglePaver builds a real source mesh larger than the 16,384-cell page scan budget.");
        ModelSnapshot ordinary = await ModelEditorAdapter.LoadAsync(new ModelRequest(firstAssetPath,
            "Geometry", projectPath));
        _ = await ModelEditorAdapter.SaveAsync(new ModelSaveRequest(firstAssetPath, "Geometry", projectPath,
            ordinary.Revision, [], [], GeometryTopologyState: topologyDraft.DraftState,
            GeometryMeshState: meshPreview.DraftState));

        byte[] projectBytes = File.ReadAllBytes(projectPath);
        byte[] firstHdfBytes = File.ReadAllBytes(firstAssetPath);
        byte[] secondHdfBytes = File.ReadAllBytes(secondAssetPath);
        string projectXml = File.ReadAllText(projectPath);
        string projectXmlSha = Hash(Encoding.UTF8.GetBytes(projectXml));
        string visualizationPath = Path.ChangeExtension(projectPath, ".vis");

        MapDocumentMutationReceipt mapAReceipt = MapTreeService.CreateMap(new MapDocumentRequest(
            projectPath, projectXml, projectXmlSha, null, "Project", Name: "Map A"));
        var mapA = new MapTreeRequest(projectPath, projectXml, projectXmlSha,
            "geometry-project-map-a", mapAReceipt.MapIndex, mapAReceipt.MapName, mapAReceipt.MapType,
            mapAReceipt.VisualizationRevision);
        MapDocumentMutationReceipt mapBReceipt = MapTreeService.CreateMap(new MapDocumentRequest(
            projectPath, projectXml, projectXmlSha, mapAReceipt.VisualizationRevision, "Project", Name: "Map B"));
        mapA = mapA with { ExpectedVisualizationRevision = mapBReceipt.VisualizationRevision };
        var mapB = new MapTreeRequest(projectPath, projectXml, projectXmlSha,
            "geometry-project-map-b", mapBReceipt.MapIndex, mapBReceipt.MapName, mapBReceipt.MapType,
            mapBReceipt.VisualizationRevision);

        MapTreeSnapshot initialA = MapTreeService.Load(mapA);
        MapTreeSnapshot initialB = MapTreeService.Load(mapB);
        CatalogTreeNode firstRowA = GeometryRow(initialA.Roots, firstAssetPath, "Map geometry A");
        CatalogTreeNode firstRowB = GeometryRow(initialB.Roots, firstAssetPath, "Map geometry A");
        CatalogTreeNode secondRowB = GeometryRow(initialB.Roots, secondAssetPath, "Map geometry B");
        CatalogTreeNode firstTopologyA = Child(firstRowA, "ConceptualMesh");
        CatalogTreeNode firstTopologyB = Child(firstRowB, "ConceptualMesh");
        CatalogTreeNodeLocator firstTopologyALocator = firstTopologyA.Locator
            ?? throw new InvalidOperationException("The source topology layer has no map locator.");
        Check(firstTopologyA.Id != firstTopologyB.Id &&
              firstTopologyALocator.ParentGeometryAssetID is { } parentAsset &&
              SamePath(parentAsset, firstAssetPath) &&
              firstTopologyALocator.ParentGeometryNodeName == firstRowA.Name,
            "Default child identity is scoped to both map and exact owning Geometry asset.");

        MapGeometrySnapshot initialMap = await ModelEditorAdapter.LoadMapGeometryAsync(new(mapA,
            firstRowA.Locator!, PageSize: FullPageSize));
        Check(initialMap.GeometryCanonicalPath == MapSourceTestPaths.Physical(firstAssetPath) &&
              initialMap.GeometryRevision == Hash(firstHdfBytes),
            "The map result binds to the selected HDF's canonical identity and exact byte revision.");
        MapGeometryTopologyPage topologyPage = initialMap.Topology
            ?? throw new InvalidOperationException("The map response omitted the requested topology page.");
        Check((initialMap.TopologyState.Status is "available" or "partial") &&
              topologyPage.Features.Length > 0 && topologyPage.SourceFeatureCount >= topologyPage.Features.Length &&
              (!topologyPage.Complete || topologyPage.SourceFeatureCount ==
                  topologyPage.Features.Length + topologyPage.OmittedSourceFeatureCount),
            "Topology pages distinguish actual projected features from source rows omitted by the retained mapper.");
        MapGeometryFlowAreasPage firstCellPage = initialMap.FlowAreas
            ?? throw new InvalidOperationException("The map response omitted the requested source cell page.");
        Check(initialMap.FlowAreasState.Status == "available" && !firstCellPage.Complete &&
              firstCellPage.SourceCellCount > 16_384 && firstCellPage.ReturnedCellCount == FullPageSize &&
              firstCellPage.Cells.Length == FullPageSize && !string.IsNullOrEmpty(firstCellPage.NextCursor),
            "The first mesh page comes from real source cells and has an explicit continuation beyond the scan budget.");
        MapGeometryFlowAreaSource area = initialMap.FlowAreas.Areas.Single();
        Check(area.CellCount == firstCellPage.SourceCellCount &&
              area.FaceCount > 0 && area.NodeCount > 0 && area.Metadata.Length > 0,
            "Flow-area map metadata retains source cell, face, node, and property summary values.");
        Check(!initialMap.GeometryChecked && !initialMap.GeometryEffectiveVisible &&
              !initialMap.FlowAreasState.IsChecked && !initialMap.FlowAreasState.EffectiveVisible,
            "Source availability and effective visibility are reported independently from sparse .vis defaults.");

        // A filtered page may be empty while the bounded source scanner still
        // has to return a continuation. Drain every cursor without assuming
        // how many scan windows the real source mesh requires.
        var outsideViewport = new MapGeometryViewport(100_000, 100_000, 100_010, 100_010);
        MapGeometrySnapshot emptyContinuation = await ModelEditorAdapter.LoadMapGeometryAsync(new MapGeometryRequest(
            mapA, firstRowA.Locator!, outsideViewport, FullPageSize, initialMap.ContextToken,
            SkipTopologyPage: true, SkipCulvertsPage: true));
        MapGeometryFlowAreasPage emptyFirst = emptyContinuation.FlowAreas!;
        Check(emptyFirst.Cells.Length == 0 && !emptyFirst.Complete &&
              emptyFirst.ScannedSourceCellCount == 16_384 && !string.IsNullOrEmpty(emptyFirst.NextCursor),
            "An empty viewport page reports real scan progress and preserves its source-bound continuation.");
        MapGeometryFlowAreasPage emptyPage = emptyFirst;
        int emptyScanned = emptyFirst.ScannedSourceCellCount;
        HashSet<string> emptyCursors = new(StringComparer.Ordinal);
        while (!emptyPage.Complete)
        {
            string cursor = emptyPage.NextCursor
                ?? throw new InvalidOperationException("An incomplete empty viewport page omitted its continuation.");
            Check(emptyCursors.Add(cursor), "Empty viewport paging never repeats a source cursor.");
            MapGeometrySnapshot nextEmpty = await ModelEditorAdapter.LoadMapGeometryAsync(new MapGeometryRequest(
                mapA, firstRowA.Locator!, outsideViewport, FullPageSize, initialMap.ContextToken,
                CellCursor: cursor, SkipTopologyPage: true, SkipCulvertsPage: true));
            emptyPage = nextEmpty.FlowAreas
                ?? throw new InvalidOperationException("An empty viewport continuation page was omitted.");
            Check(emptyPage.Cells.Length == 0 && emptyPage.ScannedSourceCellCount > 0,
                "Every outside-viewport continuation scans real source cells without inventing visible polygons.");
            emptyScanned += emptyPage.ScannedSourceCellCount;
            Check(emptyScanned <= firstCellPage.SourceCellCount,
                "Empty viewport pages cannot scan past the actual saved source cell count.");
        }
        Check(emptyPage.NextCursor is null && emptyScanned == firstCellPage.SourceCellCount,
            "Empty viewport paging closes only after scanning every real source cell.");

        await Expect<SourceFileChangedException>(() => ModelEditorAdapter.LoadMapGeometryAsync(new MapGeometryRequest(
            mapA, firstRowA.Locator!, new MapGeometryViewport(0, 0, 1, 1), FullPageSize,
            initialMap.ContextToken, CellCursor: firstCellPage.NextCursor,
            SkipTopologyPage: true, SkipCulvertsPage: true)));

        // Follow every page, then compare source ordinals back to retained
        // Mesh.CellPolygon. This tests the full actual mesh, not the editor's
        // bounded preview map.
        List<GeometryMeshMapCell> allCells = firstCellPage.Cells.ToList();
        MapGeometryFlowAreasPage cellPage = firstCellPage;
        int pageCount = 1;
        while (!cellPage.Complete)
        {
            if (++pageCount > 512) throw new InvalidOperationException("Mesh paging did not converge.");
            MapGeometrySnapshot next = await ModelEditorAdapter.LoadMapGeometryAsync(new MapGeometryRequest(
                mapA, firstRowA.Locator!, PageSize: FullPageSize,
                ContextToken: initialMap.ContextToken, CellCursor: cellPage.NextCursor,
                SkipTopologyPage: true, SkipCulvertsPage: true));
            cellPage = next.FlowAreas ?? throw new InvalidOperationException("A requested source cell page was omitted.");
            allCells.AddRange(cellPage.Cells);
        }
        Check(allCells.Count == initialMap.FlowAreas.SourceCellCount &&
              allCells.Select(cell => cell.ID).Distinct(StringComparer.Ordinal).Count() == allCells.Count,
            "Following all page cursors returns every actual source mesh cell once, without a 12,000-cell preview cap.");

        var readbackProject = new Project(projectPath);
        Geometry readbackGeometry = readbackProject.Geometries.Single(item => item.Name == "Map geometry A");
        Mesh sourceMesh = readbackGeometry.FlowAreaLayer.Features.Single().Mesh
            ?? throw new InvalidOperationException("The saved source geometry omitted its generated mesh.");
        Check(sourceMesh.CellCount == allCells.Count, "All cells reported by paging match the saved retained source mesh count.");
        foreach (int index in new[] { 0, allCells.Count / 2, allCells.Count - 1 }.Distinct())
        {
            GeometryMeshMapCell cell = allCells[index];
            Point[] actual = sourceMesh.CellPolygon(cell.CellIndex).Points.ToArray();
            Check(cell.MeshIndex == 0 && cell.Coordinates.SequenceEqual(actual.Select(point =>
                    new GeometryTopologyCoordinate(point.X, point.Y))),
                "Paged cell coordinates equal the exact source Mesh.CellPolygon at their source ordinal.");
        }

        GeometryMeshMapCell viewportSeed = allCells[0];
        var viewport = new MapGeometryViewport(viewportSeed.Coordinates.Min(point => point.X),
            viewportSeed.Coordinates.Min(point => point.Y), viewportSeed.Coordinates.Max(point => point.X),
            viewportSeed.Coordinates.Max(point => point.Y));
        MapGeometrySnapshot viewportSnapshot = await ModelEditorAdapter.LoadMapGeometryAsync(new MapGeometryRequest(
            mapA, firstRowA.Locator!, viewport, FullPageSize, initialMap.ContextToken,
            SkipTopologyPage: true, SkipCulvertsPage: true));
        MapGeometryFlowAreasPage viewportPage = viewportSnapshot.FlowAreas!;
        var viewportCells = viewportPage.Cells.ToList();
        while (!viewportPage.Complete)
        {
            MapGeometrySnapshot next = await ModelEditorAdapter.LoadMapGeometryAsync(new MapGeometryRequest(
                mapA, firstRowA.Locator!, viewport, FullPageSize, initialMap.ContextToken,
                CellCursor: viewportPage.NextCursor, SkipTopologyPage: true, SkipCulvertsPage: true));
            viewportPage = next.FlowAreas ?? throw new InvalidOperationException("A requested viewport page was omitted.");
            viewportCells.AddRange(viewportPage.Cells);
        }
        Check(viewportCells.Any(cell => cell.ID == viewportSeed.ID) &&
              viewportCells.All(cell => cell.Coordinates.Max(point => point.X) >= viewport.MinX &&
                  cell.Coordinates.Min(point => point.X) <= viewport.MaxX &&
                  cell.Coordinates.Max(point => point.Y) >= viewport.MinY &&
                  cell.Coordinates.Min(point => point.Y) <= viewport.MaxY),
            "Viewport paging returns only actual source polygons intersecting the requested world-coordinate extent.");
        Dispose(readbackProject);

        // Stale project and HDF revisions invalidate the same captured map
        // context before a late cursor can publish an unrelated page.
        try
        {
            File.WriteAllBytes(projectPath, [.. projectBytes, (byte)'\n']);
            await Expect<SourceFileChangedException>(() => ModelEditorAdapter.LoadMapGeometryAsync(new MapGeometryRequest(
                mapA, firstRowA.Locator!, PageSize: FullPageSize, ContextToken: initialMap.ContextToken,
                CellCursor: firstCellPage.NextCursor, SkipTopologyPage: true, SkipCulvertsPage: true)));
        }
        finally { File.WriteAllBytes(projectPath, projectBytes); }
        try
        {
            using (var writer = new H5Assist.H5Writer(firstAssetPath))
                writer.WriteAttribute(Geometry.HDF5Group, "R18 Revision Probe", "changed source revision");
            await Expect<SourceFileChangedException>(() => ModelEditorAdapter.LoadMapGeometryAsync(new MapGeometryRequest(
                mapA, firstRowA.Locator!, PageSize: FullPageSize, ContextToken: initialMap.ContextToken,
                CellCursor: firstCellPage.NextCursor, SkipTopologyPage: true, SkipCulvertsPage: true)));
        }
        finally { File.WriteAllBytes(firstAssetPath, firstHdfBytes); }

        // Create a real sparse child at its exact source Geometry owner, then
        // reparent that owner under nested uncheckable folders. Child IDs must
        // follow the exact parent locator and all UI state must resolve to the
        // post-move rows.
        MapTreeMutationResult enabledBeforeMove = MapTreeService.Perform(new MapTreeActionRequest(
            mapA, "visibility", Node: firstTopologyALocator, Checked: true));
        mapA = mapA with { ExpectedVisualizationRevision = enabledBeforeMove.VisualizationRevision };
        CatalogTreeNode sourceSelectedChild = Child(
            GeometryRow(enabledBeforeMove.Roots, firstAssetPath, "Map geometry A"), "ConceptualMesh");
        SetSelectedAndExpanded(visualizationPath, "Map A", "Map geometry A", "ConceptualMesh");
        mapA = mapA with { ExpectedVisualizationRevision = Hash(File.ReadAllBytes(visualizationPath)) };

        XElement initialVis = XDocument.Load(visualizationPath).Root!;
        XElement mapElementA = initialVis.Element("Maps")!.Elements("Map").Single(node =>
            (string?)node.Attribute("Name") == "Map A");
        mapElementA.SetAttributeValue("VendorMapAttribute", "preserve-me");
        mapElementA.Add(new XElement("VendorExtension", new XAttribute("Marker", "preserve-me"), "opaque"));
        initialVis.Add(new XElement("VendorRoot", new XAttribute("Marker", "preserve-me")));
        initialVis.Save(visualizationPath, SaveOptions.DisableFormatting);
        mapA = mapA with { ExpectedVisualizationRevision = Hash(File.ReadAllBytes(visualizationPath)) };

        MapTreeSnapshot beforeFolders = MapTreeService.Load(mapA);
        CatalogTreeNode geometriesRoot = beforeFolders.Roots.Single(root => root.Name == "Geometries");
        MapTreeMutationResult outerAdded = MapTreeService.Perform(new MapTreeActionRequest(
            mapA, "newFolder", Target: geometriesRoot.Locator, Name: "Outer"));
        mapA = mapA with { ExpectedVisualizationRevision = outerAdded.VisualizationRevision };
        CatalogTreeNode outer = Walk(outerAdded.Roots).Single(node => node.Locator?.NodeType == "Folder" && node.Name == "Outer");
        MapTreeMutationResult innerAdded = MapTreeService.Perform(new MapTreeActionRequest(
            mapA, "newFolder", Target: outer.Locator, Name: "Inner"));
        mapA = mapA with { ExpectedVisualizationRevision = innerAdded.VisualizationRevision };
        CatalogTreeNode inner = Walk(innerAdded.Roots).Single(node => node.Locator?.NodeType == "Folder" && node.Name == "Inner");
        CatalogTreeNode geometryToMove = GeometryRow(innerAdded.Roots, firstAssetPath, "Map geometry A");
        MapTreeMutationResult moved = MapTreeService.Perform(new MapTreeActionRequest(
            mapA, "move", Nodes: [geometryToMove.Locator], Target: inner.Locator));
        mapA = mapA with { ExpectedVisualizationRevision = moved.VisualizationRevision };
        CatalogTreeNode movedGeometry = GeometryRow(moved.Roots, firstAssetPath, "Map geometry A");
        CatalogTreeNode movedTopology = Child(movedGeometry, "ConceptualMesh");
        CatalogTreeNodeLocator movedGeometryLocator = movedGeometry.Locator
            ?? throw new InvalidOperationException("The reparented Geometry row omitted its source locator.");
        CatalogTreeNodeLocator movedTopologyLocator = movedTopology.Locator
            ?? throw new InvalidOperationException("The reparented topology child omitted its source locator.");
        Check(movedGeometryLocator.NodePath is { Length: 4 } geometryPath &&
              movedTopologyLocator.ParentGeometryNodePath?.SequenceEqual(geometryPath) == true &&
              movedTopologyLocator.NodePath is { Length: 5 } && movedTopology.Id != sourceSelectedChild.Id,
            "Moving the saved Geometry through nested folders remaps each child locator and ID to its exact new path.");
        Check(moved.SelectedNodeID == movedTopology.Id && moved.ExpandedNodeIDs.Contains(movedTopology.Id, StringComparer.Ordinal) &&
              moved.ExpandedNodeIDs.All(id => Walk(moved.Roots).Any(node => node.Id == id)),
            "Expanded and selected identifiers resolve to actual returned rows after parent reparenting.");
        Check(movedGeometryLocator.RootName == "Geometries" &&
              movedTopologyLocator.ParentGeometryNodeName == movedGeometry.Name,
            "Nested source Geometry ownership retains exact root and parent identity metadata.");
        XElement movedVis = XDocument.Load(visualizationPath).Root!;
        XElement movedMapElement = movedVis.Element("Maps")!.Elements("Map").Single(node =>
            (string?)node.Attribute("Name") == "Map A");
        Check((string?)movedMapElement.Attribute("VendorMapAttribute") == "preserve-me" &&
              movedMapElement.Element("VendorExtension")?.Value == "opaque" &&
              (string?)movedVis.Element("VendorRoot")?.Attribute("Marker") == "preserve-me",
            "Unknown map and visualization XML attributes/elements survive source tree mutations.");

        CatalogTreeNode nestedRoot = moved.Roots.Single(root => root.Name == "Geometries");
        Check(nestedRoot.Children!.Any(node => node.Name == "Outer" && node.Children?.Any(child =>
                child.Name == "Inner" && child.Children?.Any(grandchild => grandchild.Name == "Map geometry A") == true) == true),
            "The selected source Geometry remains under its actual nested folder path.");

        // Enabling the child before the move correctly checked its parent.
        // Explicitly turn the moved parent off to exercise ancestor gating,
        // while retaining its independently stored child check bit.
        MapTreeMutationResult nestedParentDisabled = MapTreeService.Perform(new MapTreeActionRequest(
            mapA, "visibility", Node: movedGeometryLocator, Checked: false));
        mapA = mapA with { ExpectedVisualizationRevision = nestedParentDisabled.VisualizationRevision };
        CatalogTreeNode nestedUncheckedOwner = GeometryRow(nestedParentDisabled.Roots, firstAssetPath, "Map geometry A");
        movedGeometryLocator = nestedUncheckedOwner.Locator
            ?? throw new InvalidOperationException("The unchecked nested Geometry lost its exact locator.");
        MapGeometrySnapshot nestedHidden = await ModelEditorAdapter.LoadMapGeometryAsync(new(mapA,
            movedGeometryLocator, PageSize: 1, SkipTopologyPage: true, SkipCulvertsPage: true));
        Check(!nestedHidden.GeometryChecked && !nestedHidden.GeometryEffectiveVisible &&
              nestedHidden.TopologyState.IsChecked && !nestedHidden.TopologyState.EffectiveVisible,
            "An unchecked nested Geometry gates its checked child while uncheckable folders preserve the child state.");

        MapTreeMutationResult parentEnabled = MapTreeService.Perform(new MapTreeActionRequest(
            mapA, "visibility", Node: movedGeometryLocator, Checked: true));
        mapA = mapA with { ExpectedVisualizationRevision = parentEnabled.VisualizationRevision };
        MapTreeSnapshot enabledReadback = MapTreeService.Load(mapA);
        CatalogTreeNode enabledGeometry = GeometryRow(enabledReadback.Roots, firstAssetPath, "Map geometry A");
        CatalogTreeNode enabledTopology = Child(enabledGeometry, "ConceptualMesh");
        Check(enabledGeometry.Checked == "checked" && enabledTopology.Checked == "checked" &&
              enabledTopology.Id != firstTopologyB.Id,
            "The child check and its source parent survive reparenting, and map-scoped child IDs remain distinct.");
        MapGeometrySnapshot nestedVisible = await ModelEditorAdapter.LoadMapGeometryAsync(new(mapA,
            enabledGeometry.Locator!, PageSize: 1, SkipTopologyPage: true, SkipCulvertsPage: true));
        Check(nestedVisible.GeometryEffectiveVisible && nestedVisible.TopologyState.IsChecked &&
              nestedVisible.TopologyState.EffectiveVisible,
            "Nested source Geometry and ConceptualMesh are effectively visible only when their checkable nodes are checked.");

        MapTreeMutationResult flowAreaEnabled = MapTreeService.Perform(new MapTreeActionRequest(
            mapA, "visibility", Node: Child(enabledGeometry, "FlowAreaLayer").Locator, Checked: true));
        mapA = mapA with { ExpectedVisualizationRevision = flowAreaEnabled.VisualizationRevision };
        CatalogTreeNode bothChildrenGeometry = GeometryRow(flowAreaEnabled.Roots, firstAssetPath, "Map geometry A");
        Check(bothChildrenGeometry.Checked == "checked" &&
              Child(bothChildrenGeometry, "ConceptualMesh").Checked == "checked" &&
              Child(bothChildrenGeometry, "FlowAreaLayer").Checked == "checked",
            "Checking another direct Geometry child keeps existing child flags and auto-enables all checkable ancestors.");
        MapTreeMutationResult parentDisabled = MapTreeService.Perform(new MapTreeActionRequest(
            mapA, "visibility", Node: bothChildrenGeometry.Locator, Checked: false));
        mapA = mapA with { ExpectedVisualizationRevision = parentDisabled.VisualizationRevision };
        CatalogTreeNode disabledGeometry = GeometryRow(parentDisabled.Roots, firstAssetPath, "Map geometry A");
        Check(disabledGeometry.Checked == "unchecked" &&
              Child(disabledGeometry, "ConceptualMesh").Checked == "checked" &&
              Child(disabledGeometry, "FlowAreaLayer").Checked == "checked",
            "Turning off a Geometry parent retains both sparse child flags.");
        await Expect<SourceFileChangedException>(() => ModelEditorAdapter.LoadMapGeometryAsync(new MapGeometryRequest(
            mapA, disabledGeometry.Locator!, PageSize: FullPageSize, ContextToken: initialMap.ContextToken,
            CellCursor: firstCellPage.NextCursor, SkipTopologyPage: true, SkipCulvertsPage: true)));
        MapGeometrySnapshot nestedDisabled = await ModelEditorAdapter.LoadMapGeometryAsync(new(mapA,
            disabledGeometry.Locator!, PageSize: 1, SkipTopologyPage: true, SkipCulvertsPage: true));
        Check(!nestedDisabled.GeometryEffectiveVisible && nestedDisabled.TopologyState.IsChecked &&
              !nestedDisabled.TopologyState.EffectiveVisible && nestedDisabled.FlowAreasState.IsChecked &&
              !nestedDisabled.FlowAreasState.EffectiveVisible,
            "The endpoint preserves each child check state but reports both hidden by the unchecked parent.");
        MapTreeMutationResult parentReenabled = MapTreeService.Perform(new MapTreeActionRequest(
            mapA, "visibility", Node: disabledGeometry.Locator, Checked: true));
        mapA = mapA with { ExpectedVisualizationRevision = parentReenabled.VisualizationRevision };
        CatalogTreeNode visibleGeometryA = GeometryRow(parentReenabled.Roots, firstAssetPath, "Map geometry A");

        // Map B gets an independent sparse child under its own Geometry.
        mapB = mapB with { ExpectedVisualizationRevision = mapA.ExpectedVisualizationRevision };
        MapTreeSnapshot beforeBVisibility = MapTreeService.Load(mapB);
        CatalogTreeNode currentGeometryB = GeometryRow(beforeBVisibility.Roots, secondAssetPath, "Map geometry B");
        CatalogTreeNode culvertChildB = Child(currentGeometryB, "CulvertBarrelLayer");
        MapTreeMutationResult culvertsEnabled = MapTreeService.Perform(new MapTreeActionRequest(
            mapB, "visibility", Node: culvertChildB.Locator, Checked: true));
        mapB = mapB with { ExpectedVisualizationRevision = culvertsEnabled.VisualizationRevision };
        CatalogTreeNode visibleGeometryB = GeometryRow(culvertsEnabled.Roots, secondAssetPath, "Map geometry B");
        CatalogTreeNode visibleCulvertB = Child(visibleGeometryB, "CulvertBarrelLayer");
        CatalogTreeNodeLocator visibleGeometryBLocator = visibleGeometryB.Locator
            ?? throw new InvalidOperationException("The culvert Geometry row omitted its source locator.");
        CatalogTreeNodeLocator visibleCulvertLocator = visibleCulvertB.Locator
            ?? throw new InvalidOperationException("The culvert source child omitted its map locator.");
        Check(visibleGeometryB.Checked == "checked" && visibleCulvertB.Checked == "checked" &&
              visibleCulvertLocator.ParentGeometryNodePath?.SequenceEqual(visibleGeometryBLocator.NodePath!) == true &&
              visibleCulvertLocator.NodePath is { Length: 3 },
            "A sparse culvert child is nested under its exact second-map Geometry owner and checks that parent.");
        Check(visibleCulvertB.Id != Child(GeometryRow(enabledReadback.Roots,
                firstAssetPath, "Map geometry A"), "ConceptualMesh").Id,
            "Child IDs do not collide across different map and Geometry owners.");

        mapA = mapA with { ExpectedVisualizationRevision = mapB.ExpectedVisualizationRevision };
        MapTreeSnapshot mapAIndependentReadback = MapTreeService.Load(mapA);
        CatalogTreeNode independentGeometryA = GeometryRow(mapAIndependentReadback.Roots,
            firstAssetPath, "Map geometry A");
        Check(independentGeometryA.Checked == "checked" &&
              Child(independentGeometryA, "ConceptualMesh").Checked == "checked" &&
              Child(independentGeometryA, "FlowAreaLayer").Checked == "checked",
            "Writing Map B's sparse visibility does not alter Map A's stored source tree state.");
        await Expect<SourceFileChangedException>(() => Task.Run(() => MapTreeService.Load(mapA with { ExpectedVisualizationRevision = initialA.VisualizationRevision })));

        // The real culvert layer has two source barrels and must paginate their
        // retained property rows without fabricating an overlay.
        MapGeometrySnapshot culvertFirst = await ModelEditorAdapter.LoadMapGeometryAsync(new(mapB,
            visibleGeometryBLocator, PageSize: 1, SkipTopologyPage: true, SkipFlowAreasPage: true));
        MapGeometryCulvertsPage firstBarrelPage = culvertFirst.Culverts
            ?? throw new InvalidOperationException("The source culvert page was omitted.");
        Check(culvertFirst.CulvertsState.Status == "available" &&
              firstBarrelPage.SourceBarrelCount == 2 && firstBarrelPage.ReturnedBarrelCount == 1 &&
              !firstBarrelPage.Complete && firstBarrelPage.Features.Length == 1 &&
              !string.IsNullOrEmpty(firstBarrelPage.NextCursor),
            "The first culvert page contains a real saved source barrel and an explicit continuation.");
        MapGeometrySnapshot culvertLast = await ModelEditorAdapter.LoadMapGeometryAsync(new MapGeometryRequest(
            mapB, visibleGeometryBLocator, PageSize: 1, ContextToken: culvertFirst.ContextToken,
            CulvertCursor: firstBarrelPage.NextCursor, SkipTopologyPage: true, SkipFlowAreasPage: true));
        MapGeometryCulvertsPage lastBarrelPage = culvertLast.Culverts
            ?? throw new InvalidOperationException("The final source culvert page was omitted.");
        Check(lastBarrelPage.ReturnedBarrelCount == 1 && lastBarrelPage.Complete && lastBarrelPage.NextCursor is null &&
              lastBarrelPage.Features[0].ID != firstBarrelPage.Features[0].ID,
            "Culvert paging returns each distinct real source barrel once.");

        // The saved map row remains serialized when its HDF disappears, but
        // Project.Load no longer resolves it to a live source Geometry. The
        // endpoint must reject that stale locator instead of manufacturing a
        // missing-source snapshot with guessed identity.
        string temporarilyMissingGeometry = Path.Combine(directory.FullName, "Map geometry B temporarily missing.h5");
        File.Move(secondAssetPath, temporarilyMissingGeometry);
        try
        {
            await Expect<SourceFileChangedException>(() => ModelEditorAdapter.LoadMapGeometryAsync(new(
                mapB, visibleGeometryBLocator, PageSize: 1, ContextToken: culvertFirst.ContextToken,
                SkipTopologyPage: true, SkipFlowAreasPage: true)));
        }
        finally { File.Move(temporarilyMissingGeometry, secondAssetPath); }

        // A continuation is rejected if the caller holds an earlier project
        // revision or an earlier map visualization document.
        string staleXml = projectXml + "\n";
        await Expect<SourceFileChangedException>(() => ModelEditorAdapter.LoadMapGeometryAsync(new MapGeometryRequest(
            mapA with { ProjectXml = staleXml, ProjectXmlSHA = Hash(Encoding.UTF8.GetBytes(staleXml)) },
            visibleGeometryA.Locator!, PageSize: 1, ContextToken: initialMap.ContextToken,
            SkipTopologyPage: true, SkipCulvertsPage: true)));

        Check(File.ReadAllBytes(projectPath).SequenceEqual(projectBytes) &&
              File.ReadAllBytes(firstAssetPath).SequenceEqual(firstHdfBytes) &&
              File.ReadAllBytes(secondAssetPath).SequenceEqual(secondHdfBytes),
            "Read-only map inspection, pagination and visibility writes preserve .ras and both source Geometry HDF files byte-for-byte.");

        XDocument finalVisualization = XDocument.Load(visualizationPath);
        XElement finalMapA = finalVisualization.Root!.Element("Maps")!.Elements("Map").Single(node =>
            (string?)node.Attribute("Name") == "Map A");
        XElement finalGeometryA = finalMapA.Descendants("Node").Single(node =>
            (string?)node.Attribute("Type") == "Geometry" && (string?)node.Attribute("Name") == "Map geometry A");
        XElement finalTopologyA = finalGeometryA.Elements("Node").Single(node =>
            (string?)node.Attribute("Type") == "ConceptualMesh");
        Check(finalGeometryA.Parent?.Attribute("Name")?.Value == "Inner" &&
              finalTopologyA.Attribute("IsChecked")?.Value == "true" &&
              finalGeometryA.Attribute("IsChecked")?.Value == "true",
            "Final Map A fixture retains nested folders and explicit source parent/child visibility.");

        string fixtureDestination = ExportFixtureIfRequested(directory.FullName);
        await CheckSavedGeometryMapTypeCopiesAsync(fixtureDestination);
        int[] mapAGeometryPath = visibleGeometryA.Locator?.NodePath ?? [];
        int[] mapBGeometryPath = visibleGeometryB.Locator?.NodePath ?? [];
        int[] mapBCulvertPath = visibleCulvertLocator.NodePath ?? [];
        Console.WriteLine($"Project Geometry map checks passed; fixture={fixtureDestination}; project={Path.GetFileName(projectPath)}; " +
            $"Map A geometry={Path.GetRelativePath(directory.FullName, firstAssetPath)} locator=[{string.Join(",", mapAGeometryPath)}]; " +
            $"Map B geometry={Path.GetRelativePath(directory.FullName, secondAssetPath)} locator=[{string.Join(",", mapBGeometryPath)}] " +
            $"culvertLocator=[{string.Join(",", mapBCulvertPath)}]; " +
            $"sourceCells={allCells.Count}; culvertRows={firstBarrelPage.SourceBarrelCount}.");
    }

    private static async Task CheckSavedGeometryMapTypeCopiesAsync(string fixtureDirectory)
    {
        if (!Directory.Exists(fixtureDirectory))
            throw new DirectoryNotFoundException("The retained R18 Geometry map fixture is unavailable: " + fixtureDirectory);
        await CheckSavedGeometryMapTypeCopyAsync(fixtureDirectory, "Geometry");
        await CheckSavedGeometryMapTypeCopyAsync(fixtureDirectory, "Buildable");
    }

    private static async Task CheckSavedGeometryMapTypeCopyAsync(string fixtureDirectory, string mapType)
    {
        using var directory = new TemporaryDirectory();
        CopyFixtureDirectory(fixtureDirectory, directory.FullName);
        string projectPath = Path.Combine(directory.FullName, "Geometry project map.ras");
        string visualizationPath = Path.ChangeExtension(projectPath, ".vis");
        byte[] projectBytes = File.ReadAllBytes(projectPath);
        // Decode the file BOM as encoding metadata, not as a character in
        // the JSON/XML editor draft; its digest is distinct from disk bytes.
        string projectXml = File.ReadAllText(projectPath);
        string projectXmlSha = Hash(Encoding.UTF8.GetBytes(projectXml));
        byte[] sourceVisualizationBytes = File.ReadAllBytes(visualizationPath);

        Project project = new(projectPath);
        Geometry source = project.Geometries.Single(item => item.Name == "Map geometry A");
        string sourcePath = Path.GetFullPath(source.Filename, directory.FullName);
        Dispose(project);
        byte[] sourceHdfBytes = File.ReadAllBytes(sourcePath);
        string sourceRevision = Hash(sourceHdfBytes);

        MapDocumentMutationReceipt created = MapTreeService.CreateMap(new MapDocumentRequest(
            projectPath, projectXml, projectXmlSha, Hash(sourceVisualizationBytes), mapType,
            Name: "R19 " + mapType + " Geometry map"));
        string mapID = "r19-" + mapType.ToLowerInvariant();
        var map = new MapTreeRequest(projectPath, projectXml, projectXmlSha, mapID,
            created.MapIndex, created.MapName, created.MapType, created.VisualizationRevision);
        AddVendorMapExtension(visualizationPath, created.MapName);
        map = map with { ExpectedVisualizationRevision = Hash(File.ReadAllBytes(visualizationPath)) };

        string action = mapType == "Geometry" ? "focusGeometry" : "addGeometry";
        MapTreeMutationResult added = MapTreeService.Perform(new MapTreeActionRequest(map,
            action, SourcePath: sourcePath, SourceRevision: sourceRevision));
        map = map with { ExpectedVisualizationRevision = added.VisualizationRevision };
        CatalogTreeNode[] roots = MapTreeService.Load(map).Roots;
        string expectedRoot = mapType == "Geometry" ? "Focused Geometries" : "Layers";
        CatalogTreeNode sourceGeometry = GeometryRowInRoot(roots, expectedRoot, sourcePath, "Map geometry A");
        CatalogTreeNodeLocator locator = sourceGeometry.Locator
            ?? throw new InvalidOperationException("The saved map Geometry row omitted its exact locator.");
        Check(sourceGeometry.AssetID is { Length: > 0 } geometryAsset && SamePath(geometryAsset, sourcePath) &&
              locator.NodeType == "Geometry" && locator.RootName == expectedRoot &&
              locator.NodePath is { Length: >= 2 } && SamePath(locator.AssetID!, sourcePath),
            $"{mapType} maps resolve the real source Geometry under their exact root, path, and asset identity.");

        // The fixture already contains a Project map with the same Geometry.
        // Passing its Geometries-root locator to another map type must not
        // silently fall back to the matching asset in an unrelated root.
        XElement[] serializedMaps = XDocument.Load(visualizationPath).Root!.Element("Maps")!.Elements("Map").ToArray();
        int projectMapIndex = Array.FindIndex(serializedMaps,
            item => (string?)item.Attribute("Type") == "Project");
        if (projectMapIndex < 0) throw new InvalidOperationException("The R18 fixture has no saved Project map.");
        XElement savedProjectMap = serializedMaps[projectMapIndex];
        var existingProjectMap = new MapTreeRequest(projectPath, projectXml, projectXmlSha,
            "r19-existing-project-map", projectMapIndex, (string)savedProjectMap.Attribute("Name")!, "Project",
            map.ExpectedVisualizationRevision);
        CatalogTreeNode projectGeometry = GeometryRowInRoot(MapTreeService.Load(existingProjectMap).Roots,
            "Geometries", sourcePath, "Map geometry A");
        await Expect<SourceFileChangedException>(() => ModelEditorAdapter.LoadMapGeometryAsync(new MapGeometryRequest(
            map, projectGeometry.Locator!, PageSize: 1, SkipTopologyPage: true, SkipCulvertsPage: true)));

        MapGeometrySnapshot initial = await ModelEditorAdapter.LoadMapGeometryAsync(new MapGeometryRequest(
            map, locator, PageSize: 1));
        Check(initial.MapID == mapID && initial.MapIndex == created.MapIndex &&
              initial.MapName == created.MapName && initial.MapType == mapType &&
              initial.GeometryRevision == sourceRevision && initial.ContextToken.Length == 64 &&
              initial.Topology is { Features.Length: > 0 } &&
              initial.FlowAreas is { SourceCellCount: > 16_384, Cells.Length: 1, Complete: false, NextCursor: not null },
            $"{mapType} map rendering returns real R18 topology and paged cells under the saved map identity.");

        await Expect<SourceFileChangedException>(() => ModelEditorAdapter.LoadMapGeometryAsync(new MapGeometryRequest(
            map with { MapID = mapID + "-other-session" }, locator, PageSize: 1,
            ContextToken: initial.ContextToken, CellCursor: initial.FlowAreas!.NextCursor,
            SkipTopologyPage: true, SkipCulvertsPage: true)));

        try
        {
            File.WriteAllBytes(projectPath, [.. projectBytes, (byte)'\n']);
            await Expect<SourceFileChangedException>(() => ModelEditorAdapter.LoadMapGeometryAsync(new MapGeometryRequest(
                map, locator, PageSize: 1, ContextToken: initial.ContextToken,
                CellCursor: initial.FlowAreas!.NextCursor, SkipTopologyPage: true, SkipCulvertsPage: true)));
        }
        finally { File.WriteAllBytes(projectPath, projectBytes); }

        try
        {
            using (var writer = new H5Assist.H5Writer(sourcePath))
                writer.WriteAttribute(Geometry.HDF5Group, "R19 Geometry Map Revision Probe", mapType);
            await Expect<SourceFileChangedException>(() => ModelEditorAdapter.LoadMapGeometryAsync(new MapGeometryRequest(
                map, locator, PageSize: 1, ContextToken: initial.ContextToken,
                CellCursor: initial.FlowAreas!.NextCursor, SkipTopologyPage: true, SkipCulvertsPage: true)));
        }
        finally { File.WriteAllBytes(sourcePath, sourceHdfBytes); }

        CatalogTreeNode flowArea = Child(sourceGeometry, "FlowAreaLayer");
        MapTreeMutationResult childEnabled = MapTreeService.Perform(new MapTreeActionRequest(
            map, "visibility", Node: flowArea.Locator, Checked: true));
        map = map with { ExpectedVisualizationRevision = childEnabled.VisualizationRevision };
        await Expect<SourceFileChangedException>(() => ModelEditorAdapter.LoadMapGeometryAsync(new MapGeometryRequest(
            map, locator, PageSize: 1, ContextToken: initial.ContextToken,
            CellCursor: initial.FlowAreas!.NextCursor, SkipTopologyPage: true, SkipCulvertsPage: true)));

        CatalogTreeNode visibleGeometry = GeometryRowInRoot(childEnabled.Roots, expectedRoot, sourcePath, "Map geometry A");
        MapGeometrySnapshot visible = await ModelEditorAdapter.LoadMapGeometryAsync(new MapGeometryRequest(
            map, visibleGeometry.Locator!, PageSize: 1));
        Check(visible.GeometryChecked && visible.GeometryEffectiveVisible &&
              visible.FlowAreasState.IsChecked && visible.FlowAreasState.EffectiveVisible &&
              visible.FlowAreas?.Cells.Length == 1,
            $"{mapType} map visibility reports the exact checked parent/child while retaining actual source geometry.");

        MapTreeMutationResult parentHidden = MapTreeService.Perform(new MapTreeActionRequest(
            map, "visibility", Node: visibleGeometry.Locator, Checked: false));
        map = map with { ExpectedVisualizationRevision = parentHidden.VisualizationRevision };
        CatalogTreeNode hiddenGeometry = GeometryRowInRoot(parentHidden.Roots, expectedRoot, sourcePath, "Map geometry A");
        MapGeometrySnapshot hidden = await ModelEditorAdapter.LoadMapGeometryAsync(new MapGeometryRequest(
            map, hiddenGeometry.Locator!, PageSize: 1));
        Check(!hidden.GeometryChecked && !hidden.GeometryEffectiveVisible &&
              hidden.FlowAreasState.IsChecked && !hidden.FlowAreasState.EffectiveVisible &&
              hidden.FlowAreas?.SourceCellCount == initial.FlowAreas!.SourceCellCount &&
              hidden.FlowAreas.Cells.Length == 1,
            $"{mapType} parent visibility gates the child without substituting or dropping the real source page.");

        string removeRevision = Hash(File.ReadAllBytes(sourcePath));
        MapTreeMutationResult removed = MapTreeService.Perform(new MapTreeActionRequest(map,
            "removeSourceNode", Node: hiddenGeometry.Locator, SourcePath: sourcePath,
            SourceRevision: removeRevision));
        map = map with { ExpectedVisualizationRevision = removed.VisualizationRevision };
        Check(!Walk(MapTreeService.Load(map).Roots).Any(node => node.Locator?.NodeType == "Geometry" &&
                node.Locator.RootName == expectedRoot && node.AssetID is { } path && SamePath(path, sourcePath)),
            $"{mapType} map removal persists without deleting the source Geometry.");
        await Expect<SourceFileChangedException>(() => ModelEditorAdapter.LoadMapGeometryAsync(new MapGeometryRequest(
            map, hiddenGeometry.Locator!, PageSize: 1)));

        XDocument finalVisualization = XDocument.Load(visualizationPath);
        XElement finalRoot = finalVisualization.Root!;
        XElement finalMap = finalRoot.Element("Maps")!.Elements("Map").Single(item =>
            (string?)item.Attribute("Name") == created.MapName);
        Check((string?)finalMap.Attribute("R19VendorAttribute") == "preserve-map" &&
              (string?)finalMap.Element("R19VendorExtension")?.Attribute("Marker") == "preserve-map" &&
              (string?)finalRoot.Element("R19VendorRoot")?.Attribute("Marker") == "preserve-root",
            $"{mapType} map add, visibility and removal preserve unknown .vis XML.");
        Check(File.ReadAllBytes(projectPath).SequenceEqual(projectBytes) &&
              File.ReadAllBytes(sourcePath).SequenceEqual(sourceHdfBytes),
            $"{mapType} map reads and tree changes leave source .ras and Geometry HDF byte-identical.");
    }

    private static void AddVendorMapExtension(string visualizationPath, string mapName)
    {
        XDocument document = XDocument.Load(visualizationPath);
        XElement root = document.Root ?? throw new InvalidDataException("The visualization document has no root.");
        XElement map = root.Element("Maps")!.Elements("Map").Single(item =>
            (string?)item.Attribute("Name") == mapName);
        map.SetAttributeValue("R19VendorAttribute", "preserve-map");
        map.Add(new XElement("R19VendorExtension", new XAttribute("Marker", "preserve-map")));
        root.Add(new XElement("R19VendorRoot", new XAttribute("Marker", "preserve-root")));
        document.Save(visualizationPath, SaveOptions.DisableFormatting);
    }

    private static CatalogTreeNode GeometryRowInRoot(IEnumerable<CatalogTreeNode> roots,
        string rootName, string assetPath, string name)
    {
        CatalogTreeNode root = roots.Single(node => node.Name == rootName);
        return Walk(root.Children ?? []).Single(node => node.Name == name &&
            node.Locator?.NodeType == "Geometry" && node.Locator.RootName == rootName &&
            node.AssetID is { Length: > 0 } path && SamePath(path, assetPath));
    }

    private static void CopyFixtureDirectory(string sourceDirectory, string destinationDirectory)
    {
        Directory.CreateDirectory(destinationDirectory);
        foreach (string sourceFolder in Directory.EnumerateDirectories(sourceDirectory, "*", SearchOption.AllDirectories))
            Directory.CreateDirectory(Path.Combine(destinationDirectory, Path.GetRelativePath(sourceDirectory, sourceFolder)));
        foreach (string sourceFile in Directory.EnumerateFiles(sourceDirectory, "*", SearchOption.AllDirectories))
            File.Copy(sourceFile, Path.Combine(destinationDirectory, Path.GetRelativePath(sourceDirectory, sourceFile)));
    }

    private static void AddSourceCulverts(Geometry geometry)
    {
        geometry.BarrelPropertiesLayer.Add(new BarrelProperties
        {
            Name = "Round barrel", Rise = 1.2, Span = 1.2, Shape = BarrelShape.Circle,
            Mannings = .025, ManningsSwitchDepth = .1, DepthBlocked = 0
        });
        geometry.OpeningPropertiesLayer.Add(new OpeningProperties
        {
            Name = "Square edge", KIn = .5, KOut = .8,
            OpeningType = BarrelOpeningType.ConcretePipeCulvert_SquareEdgeWithHeadwall
        });
        AddBarrel(geometry, "North barrel", 1, 1);
        AddBarrel(geometry, "South barrel", 4, 5);
    }

    private static void AddBarrel(Geometry geometry, string name, double x, double y)
    {
        geometry.CulvertBarrelLayer.Add(new CulvertBarrel
        {
            Name = name,
            Polyline = new Polyline(new Point[] { new(x, y), new(x + 8, y + 1) }),
            BarrelPropertyName = "Round barrel",
            UpstreamInvert = 40,
            DownstreamInvert = 39,
            UpstreamOpeningName = "Square edge",
            DownstreamOpeningName = ""
        });
    }

    private static async Task<GeometryTopologySnapshot> EditTopology(
        GeometryTopologyModelRequest model, GeometryTopologySnapshot snapshot,
        GeometryTopologyMutation mutation) => await ModelEditorAdapter.EditGeometryTopologyAsync(new(model,
            snapshot.Revision, snapshot.DraftState, mutation));

    private static void SetSelectedAndExpanded(string visualizationPath, string mapName,
        string geometryName, string childType)
    {
        XDocument document = XDocument.Load(visualizationPath);
        XElement map = document.Root!.Element("Maps")!.Elements("Map").Single(node =>
            (string?)node.Attribute("Name") == mapName);
        XElement geometry = map.Descendants("Node").Single(node =>
            (string?)node.Attribute("Type") == "Geometry" && (string?)node.Attribute("Name") == geometryName);
        XElement child = geometry.Elements("Node").Single(node => (string?)node.Attribute("Type") == childType);
        child.SetAttributeValue("IsExpanded", true);
        child.SetAttributeValue("IsIsSelected", true);
        geometry.SetAttributeValue("IsExpanded", true);
        document.Save(visualizationPath, SaveOptions.DisableFormatting);
    }

    private static CatalogTreeNode GeometryRow(IEnumerable<CatalogTreeNode> roots,
        string assetPath, string name) => Walk(roots).Single(node => node.Name == name &&
            node.Locator?.NodeType == "Geometry" && node.AssetID is { Length: > 0 } path && SamePath(path, assetPath));

    private static CatalogTreeNode Child(CatalogTreeNode geometry, string nodeType) =>
        (geometry.Children ?? []).Single(node => node.Locator?.NodeType == nodeType);

    private static bool SamePath(string first, string second) =>
        string.Equals(MapSourceTestPaths.Physical(first), MapSourceTestPaths.Physical(second),
            OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal);

    private static IEnumerable<CatalogTreeNode> Walk(IEnumerable<CatalogTreeNode> nodes)
    {
        foreach (CatalogTreeNode node in nodes)
        {
            yield return node;
            if (node.Children is { Length: > 0 } children)
                foreach (CatalogTreeNode nested in Walk(children)) yield return nested;
        }
    }

    private static void Dispose(Project project)
    {
        foreach (CoreLayerBase layer in project.Plans.Cast<CoreLayerBase>().Concat(project.Geometries)
            .Concat(project.Terrains).Concat(project.BoundaryConditions).Concat(project.NValues)
            .Concat(project.ClassificationLayers)) layer.Dispose();
        foreach (Result result in project.Results) result.Dispose();
    }

    private static string ExportFixtureIfRequested(string sourceDirectory)
    {
        string? fixture = Environment.GetEnvironmentVariable("HECRAS_GEOMETRY_MAP_ACCEPTANCE_DIRECTORY");
        if (string.IsNullOrWhiteSpace(fixture))
        {
            string? root = FindRepositoryRoot();
            if (root is null) return "(not requested)";
            fixture = Path.Combine(root, "backend", "build", "geometry-map-fixture-round18-20261017");
        }
        string destination = Path.GetFullPath(fixture);
        if (Directory.Exists(destination) || File.Exists(destination)) return destination;
        string parent = Path.GetDirectoryName(destination)
            ?? throw new IOException("The geometry map fixture destination has no parent directory.");
        Directory.CreateDirectory(parent);
        Directory.CreateDirectory(destination);
        foreach (string folder in Directory.EnumerateDirectories(sourceDirectory, "*", SearchOption.AllDirectories))
            Directory.CreateDirectory(Path.Combine(destination, Path.GetRelativePath(sourceDirectory, folder)));
        foreach (string file in Directory.EnumerateFiles(sourceDirectory, "*", SearchOption.AllDirectories))
            File.Copy(file, Path.Combine(destination, Path.GetRelativePath(sourceDirectory, file)));
        return destination;
    }

    private static string? FindRepositoryRoot()
    {
        for (DirectoryInfo? current = new DirectoryInfo(Directory.GetCurrentDirectory()); current is not null;
             current = current.Parent)
        {
            if (Directory.Exists(Path.Combine(current.FullName, "backend", "Host")) &&
                Directory.Exists(Path.Combine(current.FullName, "backend", "Tests")))
                return current.FullName;
        }
        return null;
    }

    private static string Hash(byte[] bytes) => Convert.ToHexString(SHA256.HashData(bytes));

    private static void Check(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }

    private static async Task Expect<T>(Func<Task> action) where T : Exception
    {
        try { await action(); }
        catch (T) { return; }
        throw new InvalidOperationException("Expected " + typeof(T).Name);
    }
}
