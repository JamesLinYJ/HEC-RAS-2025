using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Xml.Linq;
using Geospatial.Vectors;
using Geospatial.Vectors.Topology;
using OSGeo.GDAL;
using Ras.Backend;
using Ras.Engine;
using Ras.Layers;
using Ras.Layers.Terrains;
using Utility.Units;

internal static class GeometryMeshChecks
{
    internal static async Task Run()
    {
        using var directory = new TemporaryDirectory();
        string projectPath = Path.Combine(directory.FullName, "Mesh editor.ras");
        var project = Project.CreateNew(projectPath, UnitSystem.SI);
        var geometry = project.AddNewGeometry("Mesh geometry");
        Topology topology = Topology.FromExtent(new Extent(0, 20, 0, 20));
        geometry.ConceptualMeshLayer.Topology = topology;
        string assetPath = geometry.Filename;
        project.Save();
        geometry.Save();
        geometry.Dispose();
        using (var writer = new H5Assist.H5Writer(assetPath))
            writer.WriteAttribute(Geometry.HDF5Group, "Unknown Mesh Metadata", "Retain this attribute");

        ExportFixtureIfRequested(directory.FullName);
        byte[] original = File.ReadAllBytes(assetPath);
        var model = new GeometryMeshModelRequest(assetPath, "Geometry", projectPath);
        GeometryTopologyModelRequest topologyModel = new(assetPath, "Geometry", projectPath);
        GeometryTopologySnapshot topologyLoaded = await ModelEditorAdapter.LoadGeometryTopologyAsync(new(topologyModel));
        GeometryTopologySnapshot trianglePatch = await ModelEditorAdapter.EditGeometryTopologyAsync(new(topologyModel,
            topologyLoaded.Revision, topologyLoaded.DraftState,
            new("setField", "region", [0], "PatchType", "TrianglePaver")));
        GeometryTopologySnapshot primarySize = await ModelEditorAdapter.EditGeometryTopologyAsync(new(topologyModel,
            topologyLoaded.Revision, trianglePatch.DraftState,
            new("setField", "region", [0], "ConstantSize", "4")));
        GeometryTopologySnapshot topologyDraft = await ModelEditorAdapter.EditGeometryTopologyAsync(new(topologyModel,
            topologyLoaded.Revision, primarySize.DraftState,
            new("setField", "region", [0], "SecondaryConstantSize", "4")));

        GeometryMeshSnapshot loaded = await ModelEditorAdapter.LoadGeometryMeshAsync(new(model,
            TopologyDraftState: topologyDraft.DraftState));
        Check(loaded.CanEdit && loaded.FlowAreas.Length == 0 && loaded.Regions.Rows.Length == 1,
            "Mesh reader returns the source region identity and an empty real flow-area layer");
        GeometryMeshSnapshot preview = await ModelEditorAdapter.EditGeometryMeshAsync(new(model,
            loaded.Revision, loaded.DraftState, topologyDraft.DraftState, loaded.SelectedRegionIDs,
            new("generate", OperationID: "mesh-history-operation")));
        Check(preview.IsDirty && preview.GenerationReport is { MeshWasReplaced: true, CellCount: > 0 },
            "Generate action stores a source-built mesh preview in the in-memory child draft");
        Check(preview.DiagnosticHistoryEvent is { } history
            && history.OperationID == "mesh-history-operation" && history.Result
            && history.Topology.Features.Any(feature => feature.FeatureKind == "region"
                && feature.SelectionIDs.Contains("region:0")),
            "The transient MeshDiagnostics event carries the source OperationResult and the topology context used by its message links");
        Check(File.ReadAllBytes(assetPath).SequenceEqual(original),
            "Loading and generating a mesh preview do not write the geometry source HDF");

        GeometryMeshDraftState draft = JsonSerializer.Deserialize<GeometryMeshDraftState>(preview.DraftState, BackendJson.Options)
            ?? throw new InvalidOperationException("Mesh preview omitted its opaque draft state.");
        GeometryMeshMutation generated = draft.Mutations.Single();
        Check(generated.GeneratedMeshPayload is { Length: > 0 } && generated.GeneratedReport is not null,
            "A generated preview retains its exact serialized mesh and source build report");
        byte[] expectedMesh = Convert.FromBase64String(generated.GeneratedMeshPayload!);
        CheckMeshStreamRoundTrip(expectedMesh);
        CheckMeshStreamRoundTrip(SerializeMesh(CreateMeshWithInternalPoints()), requireInternalPoints: true);

        // A second independent service replay reads the opaque artifact. It must
        // not rerun generation and silently produce a mesh different from the
        // preview already shown to the user.
        GeometryMeshSnapshot replayed = await ModelEditorAdapter.LoadGeometryMeshAsync(new(model,
            preview.Revision, preview.DraftState, topologyDraft.DraftState, preview.SelectedRegionIDs));
        Check(replayed.FlowAreas.Length == 1 && replayed.FlowAreas[0].CellCount == preview.GenerationReport!.CellCount,
            "A fresh mesh service replay renders the exact preview artifact rather than rerunning mesh generation");
        GeometryMeshMapData previewMap = preview.Map ?? throw new InvalidOperationException("Mesh preview omitted its source map data.");
        Check(previewMap.TotalCellCount == preview.FlowAreas.Sum(row => row.CellCount)
            && previewMap.RenderedCellCount == previewMap.Cells.Length
            && previewMap.Cells.All(cell => cell.Coordinates.Length >= 3
                && cell.Coordinates.All(point => double.IsFinite(point.X) && double.IsFinite(point.Y))),
            "The source mesh map uses finite cell polygons and reports exact preview counts");
        Check(previewMap.Topology.Features.Any(feature => feature.FeatureKind == "region"
                && feature.SelectionIDs.Contains("region:0") && feature.Paths.Length > 0),
            "Mesh map topology preserves the source region FID link and source boundary coordinates");
        GeometryMeshMapCell mapCell = previewMap.Cells[0];
        Check(mapCell.FlowAreaID == "flow-area-row:0"
            && mapCell.ID == mapCell.FlowAreaID + ":cell:" + mapCell.CellIndex
            && mapCell.MeshIndex == 0,
            "Map cell identity uses the source flow-area row and source-local mesh ordinal, not a fake FID");
        using (var meshStream = new MemoryStream(expectedMesh, writable: false))
        using (var meshReader = new BinaryReader(meshStream))
        {
            Mesh sourceMesh = Mesh.Stream(meshReader);
            GeometryTopologyCoordinate[] actualCell = sourceMesh.CellPolygon(mapCell.CellIndex).Points
                .Select(point => new GeometryTopologyCoordinate(point.X, point.Y)).ToArray();
            Check(mapCell.Coordinates.SequenceEqual(actualCell),
                "Map cell coordinates are read from the exact retained source Mesh.CellPolygon");
        }

        GeometryMeshDegreeScan draftErrors = await ModelEditorAdapter.ScanGeometryMeshDegreeErrorsAsync(
            new GeometryMeshDegreeScanRequest(model, preview.Revision, preview.DraftState,
                topologyDraft.DraftState, 3, IncludeIncidentCells: true));
        Check(draftErrors.Issues.Length > 0 && draftErrors.Issues.All(issue => issue.Cells.Length > 0),
            "The degree scan replays the current generated child draft and returns its actual incident cell polygons");
        foreach (GeometryMeshDegreeIssue issue in draftErrors.Issues)
        {
            GeometryMeshMapCell[] expectedDraftCells = previewMap.Cells.Where(cell =>
                cell.MeshIndex == issue.MeshIndex && issue.Cells.Any(errorCell => errorCell.CellIndex == cell.CellIndex)).ToArray();
            Check(expectedDraftCells.Length == issue.Cells.Length
                && issue.Cells.All(errorCell => expectedDraftCells.Any(cell =>
                    cell.CellIndex == errorCell.CellIndex && cell.Coordinates.SequenceEqual(errorCell.Coordinates))),
                "Draft mesh diagnostics preserve exact Mesh.CellPolygon coordinates for each reported node's incident cells");
        }
        Check(File.ReadAllBytes(assetPath).SequenceEqual(original),
            "Scanning the current generated mesh draft does not publish or mutate the source Geometry HDF");

        ModelSnapshot ordinary = await ModelEditorAdapter.LoadAsync(new ModelRequest(assetPath, "Geometry", projectPath));
        const string descriptionField = "GeometrySummaryPage/ViewModel_SelectedGeometryVisualContext_Context_Description";
        ModelSnapshot saved = await ModelEditorAdapter.SaveAsync(new ModelSaveRequest(assetPath, "Geometry", projectPath,
            ordinary.Revision, new() { [descriptionField] = "Combined mesh and topology save" }, [],
            GeometryTopologyState: topologyDraft.DraftState, GeometryMeshState: preview.DraftState));
        Check(saved.Fields[descriptionField] == "Combined mesh and topology save",
            "One parent model save commits ordinary geometry fields with topology and generated mesh drafts");
        CheckMeshErrorMapSource(projectPath, assetPath);
        CheckNonzeroMultiResultMeshErrorLease();

        GeometryMeshSnapshot prepareBase = await ModelEditorAdapter.LoadGeometryMeshAsync(new(model, saved.Revision));
        GeometryMeshSnapshot prepareDraft = await ModelEditorAdapter.EditGeometryMeshAsync(new(model,
            prepareBase.Revision, prepareBase.DraftState, null, [], new("prepare")));
        Check(prepareDraft.PreparePending && prepareDraft.IsDirty
            && prepareDraft.PrepareSummary is null,
            "Prepare is retained as a child-ledger request and does not run during preview editing");
        byte[] sourceBeforePrepare = File.ReadAllBytes(assetPath);
        GeometryMeshPrepareException prepareFailure;
        try
        {
            await ModelEditorAdapter.SaveAsync(new ModelSaveRequest(assetPath, "Geometry", projectPath,
                saved.Revision, [], [], GeometryMeshState: prepareDraft.DraftState));
            throw new InvalidOperationException("A geometry without source associations unexpectedly prepared successfully.");
        }
        catch (GeometryMeshPrepareException exception) { prepareFailure = exception; }
        Check(File.ReadAllBytes(assetPath).SequenceEqual(sourceBeforePrepare),
            "A source-reported Prepare failure never publishes the partially prepared staging HDF");
        GeometrySummary? failureSummary = prepareFailure.SourceSummary;
        Check(failureSummary is { Success: false }
            && !string.IsNullOrWhiteSpace(failureSummary.FailureReason)
            && prepareFailure.Message.Contains(failureSummary.FailureReason, StringComparison.Ordinal)
            && (string.IsNullOrEmpty(failureSummary.PrepareLog)
                || prepareFailure.Message.Contains(failureSummary.PrepareLog, StringComparison.Ordinal)),
            "The failed staged Prepare error retains the source failure reason and any source prepare log");
        GeometryMeshDraftState prepareLedger = JsonSerializer.Deserialize<GeometryMeshDraftState>(
            prepareDraft.DraftState, BackendJson.Options) ?? throw new InvalidOperationException("Prepare draft state is invalid.");
        Check(prepareLedger.Mutations.Any(mutation => mutation.Operation == "prepare"),
            "A failed parent Prepare save leaves its request marker available for user retry or discard");

        var reopenedProject = new Project(projectPath);
        Geometry reopenedGeometry = reopenedProject.Geometries.Single(item => item.Name == "Mesh geometry");
        Mesh savedMesh = reopenedGeometry.FlowAreaLayer.Features.Single().Mesh
            ?? throw new InvalidOperationException("Parent save did not persist the generated mesh.");
        Check(SerializeMesh(savedMesh).SequenceEqual(expectedMesh),
            "The parent HDF save preserves the exact random-order mesh preview shown before Save");
        var reopened = await ModelEditorAdapter.LoadGeometryMeshAsync(new(model, saved.Revision));
        Check(reopened.FlowAreas.Length == 1 && reopened.FlowAreas[0].CellCount == preview.GenerationReport!.CellCount,
            "Reopening the geometry reports the saved flow-area mesh and actual cell count");
        var ordinaryReopened = await ModelEditorAdapter.LoadAsync(new ModelRequest(assetPath, "Geometry", projectPath));
        Check(ordinaryReopened.Fields[descriptionField] == "Combined mesh and topology save",
            "The same HDF readback retains the ordinary geometry edit");
        using (var reader = new H5Assist.H5Reader(assetPath))
            Check(reader.TryReadStringAttributeScalar(Geometry.HDF5Group, "Unknown Mesh Metadata") == "Retain this attribute",
                "Combined parent mesh/topology save preserves unknown HDF metadata");

        await Expect<SourceFileChangedException>(() => ModelEditorAdapter.SaveAsync(new ModelSaveRequest(assetPath,
            "Geometry", projectPath, ordinary.Revision, new() { [descriptionField] = "stale" }, [],
            GeometryTopologyState: topologyDraft.DraftState, GeometryMeshState: preview.DraftState)));
        await CheckSuccessfulPrepare();
        Console.WriteLine("Geometry mesh source load, bounded source map, exact preview artifact, staged Prepare success/failure, combined parent save and HDF readback checks passed.");
    }

    private static async Task CheckSuccessfulPrepare()
    {
        using var directory = new TemporaryDirectory();
        string projectPath = Path.Combine(directory.FullName, "Prepared geometry.ras");
        Project project = Project.CreateNew(projectPath, UnitSystem.SI);
        Terrain terrain = project.AddNewTerrain("Prepare terrain");
        string rasterPath = Path.Combine(terrain.SourceDirectory, "flat.tif");
        using (var driver = Gdal.GetDriverByName("GTiff"))
        using (var raster = driver.Create(rasterPath, 32, 32, 1, DataType.GDT_Float32,
            ["TILED=YES", "BLOCKXSIZE=16", "BLOCKYSIZE=16"]))
        {
            raster.SetGeoTransform([0, 1, 0, 32, 0, -1]);
            using var band = raster.GetRasterBand(1);
            band.Fill(42, 0);
        }
        terrain.Add(RasterTerrainInput.CreateAndScan(terrain, rasterPath));
        NValueLayer nValues = project.AddNewNValueLayer("Prepare roughness");
        nValues.SetConstant(0.035f);
        Geometry geometry = project.AddNewGeometry("Prepare geometry", terrain, nValues);
        // Face-profile sampling needs raster support around each mesh edge;
        // keep the mesh inside the actual 0..32 raster footprint.
        geometry.ConceptualMeshLayer.Topology = Topology.FromExtent(new Extent(4, 24, 4, 24));
        geometry.Save();
        terrain.Save();
        nValues.Save();
        project.Save();
        string assetPath = geometry.Filename;
        geometry.Dispose();
        terrain.Dispose();
        nValues.Dispose();
        ExportPrepareFixtureIfRequested(directory.FullName);

        var topologyModel = new GeometryTopologyModelRequest(assetPath, "Geometry", projectPath);
        GeometryTopologySnapshot topology = await ModelEditorAdapter.LoadGeometryTopologyAsync(new(topologyModel));
        GeometryTopologySnapshot triangle = await ModelEditorAdapter.EditGeometryTopologyAsync(new(topologyModel,
            topology.Revision, topology.DraftState,
            new("setField", "region", [0], "PatchType", "TrianglePaver")));
        GeometryTopologySnapshot primary = await ModelEditorAdapter.EditGeometryTopologyAsync(new(topologyModel,
            topology.Revision, triangle.DraftState,
            new("setField", "region", [0], "ConstantSize", "4")));
        GeometryTopologySnapshot sized = await ModelEditorAdapter.EditGeometryTopologyAsync(new(topologyModel,
            topology.Revision, primary.DraftState,
            new("setField", "region", [0], "SecondaryConstantSize", "4")));

        var meshModel = new GeometryMeshModelRequest(assetPath, "Geometry", projectPath);
        GeometryMeshSnapshot mesh = await ModelEditorAdapter.LoadGeometryMeshAsync(new(meshModel,
            TopologyDraftState: sized.DraftState));
        GeometryMeshSnapshot generated = await ModelEditorAdapter.EditGeometryMeshAsync(new(meshModel,
            mesh.Revision, mesh.DraftState, sized.DraftState, [], new("generate")));
        Check(generated.GenerationReport is { Succeeded: true, MeshWasReplaced: true, CellCount: > 0 },
            "The successful Prepare fixture starts with a source-generated flow-area mesh");
        GeometryMeshSnapshot prepare = await ModelEditorAdapter.EditGeometryMeshAsync(new(meshModel,
            generated.Revision, generated.DraftState, sized.DraftState, [], new("prepare")));

        byte[] sourceBefore = File.ReadAllBytes(assetPath);
        ModelSnapshot saved = await ModelEditorAdapter.SaveAsync(new ModelSaveRequest(assetPath, "Geometry",
            projectPath, mesh.Revision, [], [], GeometryTopologyState: sized.DraftState,
            GeometryMeshState: prepare.DraftState));
        Check(!File.ReadAllBytes(assetPath).SequenceEqual(sourceBefore),
            "A successful parent Prepare publishes the fully prepared staged geometry");

        GeometryMeshSnapshot reopened = await ModelEditorAdapter.LoadGeometryMeshAsync(new(meshModel, saved.Revision));
        Check(reopened.PrepareSummary is { Succeeded: true }
            && reopened.FlowAreas.Single().HasPropertyTables
            && !reopened.PreparePending && !reopened.IsDirty,
            "The source Prepare summary and computed property tables survive independent HDF readback");
        var projectReadback = new Project(projectPath);
        Geometry geometryReadback = projectReadback.Geometries.Single(item => item.Name == "Prepare geometry");
        Check(geometryReadback.FlowAreaLayer.Features.Single().PropertyTables is not null,
            "Source Geometry.PrepareForCompute wrote actual property-table data in the committed HDF");
    }

    private static void ExportFixtureIfRequested(string sourceDirectory)
    {
        ExportFixtureIfRequested(sourceDirectory, "HECRAS_MESH_ACCEPTANCE_DIRECTORY");
    }

    private static void ExportPrepareFixtureIfRequested(string sourceDirectory)
    {
        ExportFixtureIfRequested(sourceDirectory, "HECRAS_MESH_PREPARE_ACCEPTANCE_DIRECTORY");
    }

    private static void ExportFixtureIfRequested(string sourceDirectory, string environmentVariable)
    {
        string? fixture = Environment.GetEnvironmentVariable(environmentVariable);
        if (string.IsNullOrWhiteSpace(fixture)) return;
        string source = Path.GetFullPath(sourceDirectory);
        string destination = Path.GetFullPath(fixture);
        string relativeDestination = Path.GetRelativePath(source, destination);
        if (relativeDestination == "."
            || (!Path.IsPathRooted(relativeDestination)
                && relativeDestination != ".."
                && !relativeDestination.StartsWith(".." + Path.DirectorySeparatorChar, StringComparison.Ordinal)))
            throw new IOException("The mesh fixture destination must be outside its source directory: " + environmentVariable);
        if (Directory.Exists(destination) || File.Exists(destination))
            throw new IOException("The mesh fixture destination already exists: " + environmentVariable);
        Directory.CreateDirectory(destination);
        foreach (string folder in Directory.EnumerateDirectories(sourceDirectory, "*", SearchOption.AllDirectories))
            Directory.CreateDirectory(Path.Combine(destination, Path.GetRelativePath(sourceDirectory, folder)));
        foreach (string file in Directory.EnumerateFiles(sourceDirectory, "*", SearchOption.AllDirectories))
            File.Copy(file, Path.Combine(destination, Path.GetRelativePath(sourceDirectory, file)));
    }

    private static void CheckMeshStreamRoundTrip(byte[] bytes, bool requireInternalPoints = false)
    {
        using var source = new MemoryStream(bytes, writable: false);
        using var reader = new BinaryReader(new NonSeekableReadStream(source));
        Mesh mesh = Mesh.Stream(reader);
        Check(mesh.CellCount > 0 && mesh.CellCenters.Length == mesh.CellCount
            && mesh.Faces.Length > 0 && mesh.FaceInternalPoints.Length == mesh.Faces.Length,
            "Mesh.Stream(BinaryReader) restores cells, centers, faces and face-internal points on a non-seekable stream");
        if (requireInternalPoints)
        {
            Check(mesh.FaceInternalPoints[0].Span.SequenceEqual(new[] { new Point(0.25, 0.75) }),
                "Mesh.Stream(BinaryReader) restores non-empty Point arrays without primitive-array copying");
        }
        Check(SerializeMesh(mesh).SequenceEqual(bytes),
            "Mesh writer and repaired reader preserve every generated mesh stream value");

        using var negative = new MemoryStream();
        using (var writer = new BinaryWriter(negative, System.Text.Encoding.UTF8, leaveOpen: true)) writer.Write(-1);
        negative.Position = 0;
        ExpectSync<InvalidDataException>(() => Mesh.Stream(new BinaryReader(negative)));

        using var shortRead = new MemoryStream();
        using (var writer = new BinaryWriter(shortRead, System.Text.Encoding.UTF8, leaveOpen: true))
        {
            writer.Write(2); // perimeter coordinate array count
            writer.Write(12.0); // only one double of the required two
        }
        shortRead.Position = 0;
        ExpectSync<EndOfStreamException>(() => Mesh.Stream(new BinaryReader(shortRead)));

        using var oversizedTruncatedArray = new MemoryStream();
        using (var writer = new BinaryWriter(oversizedTruncatedArray, System.Text.Encoding.UTF8, leaveOpen: true))
            writer.Write(100_000_000); // count is plausible, but payload is absent
        oversizedTruncatedArray.Position = 0;
        ExpectSync<EndOfStreamException>(() => Mesh.Stream(new BinaryReader(oversizedTruncatedArray)));

        using var oversizedTruncatedRecords = new MemoryStream();
        using (var writer = new BinaryWriter(oversizedTruncatedRecords, System.Text.Encoding.UTF8, leaveOpen: true))
        {
            writer.Write(0); // perimeter
            writer.Write(0); // cells
            writer.Write(0); // cell centers
            writer.Write(int.MaxValue); // faces, no face records follow
        }
        oversizedTruncatedRecords.Position = 0;
        ExpectSync<EndOfStreamException>(() => Mesh.Stream(new BinaryReader(oversizedTruncatedRecords)));
    }

    private static Mesh CreateMeshWithInternalPoints()
    {
        var cell = new Cell { Faces = new[] { 0 } };
        var face = new Face(0, -1) { fpA = 0, fpB = 1 };
        FacePoint[] facePoints =
        [
            new FacePoint(0, 0) { Faces = new[] { 0 } },
            new FacePoint(1, 0) { Faces = new[] { 0 } }
        ];
        var perimeter = new Polygon(new[]
        {
            new Point(0, 0), new Point(1, 0), new Point(1, 1), new Point(0, 1)
        });
        return new Mesh(perimeter, [cell], [face], facePoints, [new Point(0.5, 0.5)],
            [new[] { new Point(0.25, 0.75) }]);
    }

    private static void CheckMeshErrorMapSource(string projectPath, string assetPath)
    {
        byte[] sourceBefore = File.ReadAllBytes(assetPath);
        string projectXml = File.ReadAllText(projectPath);
        string projectXmlSHA = Hash(Encoding.UTF8.GetBytes(projectXml));
        MapDocumentMutationReceipt created = MapTreeService.CreateMap(new MapDocumentRequest(
            projectPath, projectXml, projectXmlSHA, null, "Project"));
        var map = new MapTreeRequest(projectPath, projectXml, projectXmlSHA,
            Guid.NewGuid().ToString(), created.MapIndex, created.MapName, created.MapType,
            created.VisualizationRevision);
        MapTreeSnapshot tree = MapTreeService.Load(map);
        CatalogTreeNode flowArea = Flatten(tree.Roots).Single(node =>
            node.Locator is { NodeType: "FlowAreaLayer", ParentGeometryAssetID: { } parent }
                && PathEquals(parent, assetPath));
        CatalogTreeNodeLocator locator = flowArea.Locator
            ?? throw new InvalidOperationException("MapTree omitted the actual FlowArea locator.");
        string sourceRevision = Hash(File.ReadAllBytes(assetPath));
        var request = new MapTreeMeshErrorRequest(map, locator, Guid.NewGuid().ToString(),
            "geometry-mesh-error-source-test", "mesh-error-context", assetPath, sourceRevision,
            ResultOwner: null, Action: "load");

        MapTreeMeshErrorSnapshot initial = MapTreeService.MeshErrors(request);
        Check(initial.Status == "disabled" && !initial.CheckMeshErrors && initial.MaxFacesPerNode == 8
            && initial.IsChecked == (flowArea.Checked == "checked"),
            "The mesh-error map property reads the exact FlowArea .vis defaults and actual check state.");

        MapTreeMeshErrorSnapshot enabled = MapTreeService.MeshErrors(request with
        { Action = "set", CheckMeshErrors = true, MaxFacesPerNodeEntry = 4.5 });
        Check(enabled.Status == "available" && enabled.CheckMeshErrors && enabled.MaxFacesPerNode == 5
            && enabled.Issues.Length > 0 && enabled.TotalIssueCount == enabled.Issues.Length,
            "A real saved source mesh yields high-degree-node rows after retained .vis threshold rounding.");
        CatalogTreeNodeLocator materializedLocator = enabled.FlowAreaNode;
        CatalogTreeNodeLocator normalizedLocator = materializedLocator with
        {
            NodePath = locator.NodePath,
            ParentGeometryNodePath = locator.ParentGeometryNodePath
        };
        Check(normalizedLocator == locator &&
              IsUnchangedOrMaterializedPath(locator.NodePath, materializedLocator.NodePath) &&
              IsUnchangedOrMaterializedPath(locator.ParentGeometryNodePath,
                  materializedLocator.ParentGeometryNodePath) &&
              locator.NodePath is null && materializedLocator.NodePath is { Length: > 0 },
            "The setting receipt rebases the implicit FlowArea locator only to the path materialized by its exact .vis mutation.");
        request = request with { FlowAreaNode = materializedLocator };

        var sourceProject = new Project(projectPath);
        Geometry sourceGeometry = sourceProject.Geometries.Single(item =>
            PathEquals(item.Filename, assetPath) && item.Name == "Mesh geometry");
        IMeshCollection meshes = sourceGeometry.FlowAreaLayer.AsMeshCollection();
        var expected = new List<MeshNodeDegreeError>();
        meshes.Lock.AcquireReaderLock(-1);
        try
        {
            for (int meshIndex = 0; meshIndex < meshes.Count; meshIndex++)
                MeshNodeDegreeScan.FindHighDegreeNodes(meshes[meshIndex], meshIndex, 5, expected);
            expected.Sort((left, right) => right.FaceCount.CompareTo(left.FaceCount));
            Check(expected.Count == enabled.TotalIssueCount,
                "Map mesh-error rows have the same source scan count as MeshNodeDegreeScan over the generated HDF.");
            foreach (MeshNodeDegreeError sourceIssue in expected)
            {
                MapTreeMeshErrorIssue mapped = enabled.Issues.Single(issue =>
                    issue.MeshIndex == sourceIssue.MeshIndex && issue.NodeIndex == sourceIssue.NodeIndex);
                Check(mapped.FaceCount == sourceIssue.FaceCount
                    && mapped.Node.X == sourceIssue.NodePoint.X && mapped.Node.Y == sourceIssue.NodePoint.Y,
                    "Each map diagnostic retains the exact source mesh/node identity, valence and coordinates.");
                Mesh sourceMesh = meshes[sourceIssue.MeshIndex];
                MapTreeMeshErrorCell[] expectedCells = sourceIssue.Cells
                    .Where(cellIndex => cellIndex >= 0 && cellIndex < sourceMesh.CellCount)
                    .Select(cellIndex => new MapTreeMeshErrorCell(cellIndex,
                        sourceMesh.CellPolygon(cellIndex).Points
                            .Select(point => new MapTreeMeshErrorCoordinate(point.X, point.Y)).ToArray()))
                    .ToArray();
                Check(mapped.Cells.Select(cell => cell.CellIndex).SequenceEqual(
                        expectedCells.Select(cell => cell.CellIndex))
                    && mapped.Cells.Zip(expectedCells).All(pair => pair.First.Coordinates.SequenceEqual(pair.Second.Coordinates)),
                    "The map overlay polygons are the exact incident source Mesh.CellPolygon coordinates.");
            }
        }
        finally
        {
            meshes.Lock.ReleaseReaderLock();
            sourceGeometry.Dispose();
        }

        MapTreeMeshErrorSnapshot draftSettings = MapTreeService.MeshErrors(request with
        {
            Map = map with { ExpectedVisualizationRevision = enabled.VisualizationRevision },
            Action = "draftSettings",
            ReadSettingsOnly = true
        });
        Check(draftSettings.Status == "draftSettings" && draftSettings.CheckMeshErrors
            && draftSettings.MaxFacesPerNode == 5 && draftSettings.Issues.Length == 0
            && draftSettings.IsChecked is null && draftSettings.IsEffectivelyVisible is null,
            "Generated-draft settings resolve the exact .vis controls without projecting persisted-HDF mesh rows.");

        MapTreeMeshErrorSnapshot draftSettingsAfterSet = MapTreeService.MeshErrors(request with
        {
            Map = map with { ExpectedVisualizationRevision = draftSettings.VisualizationRevision },
            Action = "set",
            ReadSettingsOnly = true,
            CheckMeshErrors = true,
            MaxFacesPerNodeEntry = 5
        });
        Check(draftSettingsAfterSet.Status == "draftSettings" && draftSettingsAfterSet.CheckMeshErrors
            && draftSettingsAfterSet.MaxFacesPerNode == 5 && draftSettingsAfterSet.Issues.Length == 0,
            "A generated-draft setting mutation returns settings only; the native caller scans its current opaque draft next.");

        MapTreeMeshErrorSnapshot persisted = MapTreeService.MeshErrors(request with
        { Map = map with { ExpectedVisualizationRevision = draftSettingsAfterSet.VisualizationRevision } });
        Check(persisted.Status == "available" && persisted.CheckMeshErrors
            && persisted.MaxFacesPerNode == 5 && persisted.Issues.Length == enabled.Issues.Length,
            "A fresh map-service request reads the committed mesh-error settings and diagnostics from .vis/HDF.");

        MapTreeMeshErrorSnapshot disabled = MapTreeService.MeshErrors(request with
        {
            Map = map with { ExpectedVisualizationRevision = persisted.VisualizationRevision },
            Action = "set", CheckMeshErrors = false, MaxFacesPerNodeEntry = null
        });
        Check(disabled.Status == "disabled" && !disabled.CheckMeshErrors && disabled.Issues.Length == 0,
            "Turning off MeshErrorProperties removes its map diagnostics without changing the source mesh.");

        MapTreeMeshErrorSnapshot reopenedDisabled = MapTreeService.MeshErrors(request with
        { Map = map with { ExpectedVisualizationRevision = disabled.VisualizationRevision } });
        Check(reopenedDisabled.Status == "disabled" && !reopenedDisabled.CheckMeshErrors
            && reopenedDisabled.Issues.Length == 0,
            "A fresh map request confirms the disabled state was persisted in the exact saved .vis row.");

        ExpectSync<SourceFileChangedException>(() => MapTreeService.MeshErrors(request with
        {
            Map = map with { ExpectedVisualizationRevision = disabled.VisualizationRevision },
            SourceRevision = new string('0', 64)
        }));
        Check(sourceBefore.SequenceEqual(File.ReadAllBytes(assetPath)),
            "Reading, scanning and editing map-local mesh diagnostics leave the geometry HDF byte-for-byte unchanged.");
    }

    private static void CheckNonzeroMultiResultMeshErrorLease()
    {
        using var directory = new TemporaryDirectory();
        MapResultRenderChecks.Fixture fixture = MapResultRenderChecks.CreateFixture(directory.FullName,
            velocityVariesByProfile: true);
        string historicalPath = Path.Combine(Path.GetDirectoryName(fixture.ResultPath)!,
            "Mesh error historical copy.h5");
        File.Copy(fixture.ResultPath, historicalPath);

        XDocument visualization = XDocument.Load(fixture.VisualizationPath, LoadOptions.PreserveWhitespace);
        XElement serializedMap = visualization.Root!.Element("Maps")!.Elements("Map")
            .ElementAt(fixture.Map.MapIndex);
        XElement resultsRoot = serializedMap.Element("Tree")!.Element("Nodes")!.Elements("Node")
            .Single(node => (string?)node.Attribute("Name") == "Results");
        XElement standaloneResult = resultsRoot.Elements("Node")
            .Single(node => (string?)node.Attribute("Type") == "Result");
        standaloneResult.Remove();
        standaloneResult.SetAttributeValue("Name", Path.GetFileNameWithoutExtension(historicalPath));
        string planName;
        using (Result result = Result.TryLoad(fixture.ResultPath, out Result? loaded) && loaded is not null
                   ? loaded
                   : throw new InvalidDataException("Could not reopen the Result used by the mesh-error slot fixture."))
            planName = result.Plan?.Name
                ?? throw new InvalidDataException("The mesh-error slot fixture Result has no Plan identity.");
        // Make the standalone alias the first source node. The map resolver
        // coalesces equal Result/map-type contexts and keeps that row as the
        // representative, while retaining exact MultiResult slot membership.
        resultsRoot.Add(standaloneResult);
        resultsRoot.Add(new XElement("Node", new XAttribute("Type", "MultiResult"),
            new XAttribute("Name", planName), new XAttribute("IsChecked", true),
            new XAttribute("SelectedMapType", "Depth"), new XAttribute("ProfileIndex", 0)));
        visualization.Save(fixture.VisualizationPath, SaveOptions.DisableFormatting);

        MapTreeRequest map = fixture.Map with
        { ExpectedVisualizationRevision = Hash(File.ReadAllBytes(fixture.VisualizationPath)) };
        MapResultSourcesResult unleasedSources = MapResultChartService.Sources(new(map, []));
        MapResultActiveNode unleasedGroup = unleasedSources.ActiveNodes.Single(node => node.NodeKind == "MultiResult");
        string planAssetPath = unleasedGroup.Node.AssetID
            ?? throw new InvalidDataException("The MultiResult fixture has no exact Plan asset identity.");
        MapResultSourceChoice writerChoice = unleasedGroup.Selections.Single().Choices.Single(choice =>
            PathEquals(choice.ResultPath, fixture.ResultPath));
        MapResultSourceChoice historicalChoice = unleasedGroup.Selections.Single().Choices.Single(choice =>
            PathEquals(choice.ResultPath, historicalPath));

        MapTreeResultSelectionOverride treeSelection = new(planAssetPath, planName,
            historicalChoice.ResultPath, historicalChoice.Revision);
        MapResultSelectionOverride[] historyInSlotOne =
        [
            new(unleasedGroup.Node, 0, "Explicit", writerChoice.ResultPath, writerChoice.Revision),
            new(unleasedGroup.Node, 1, "Explicit", historicalChoice.ResultPath, historicalChoice.Revision)
        ];

        // Enable the exact historical Result FlowArea before opening the
        // writer lease. Both slots and the earlier standalone row resolve to
        // this same stored Result, exercising the coalesced source identity.
        MapTreeRequest setupMap = map with { ResultSelectionOverrides = [treeSelection] };
        MapResultSelectionOverride[] duplicateHistoricalSlots =
        [
            new(unleasedGroup.Node, 0, "Explicit", historicalChoice.ResultPath, historicalChoice.Revision),
            new(unleasedGroup.Node, 1, "Explicit", historicalChoice.ResultPath, historicalChoice.Revision)
        ];
        MapResultSourcesResult setupSources = MapResultChartService.Sources(
            new MapResultSourcesRequest(setupMap, duplicateHistoricalSlots));
        MapResultActiveNode setupGroup = setupSources.ActiveNodes.Single(node =>
            node.NodeKind == "MultiResult" && PathEquals(node.Node.AssetID!, planAssetPath));
        Check(setupGroup.Selections.Length == 2 &&
              setupGroup.Selections[0].SelectedResult is { } setupHistorical &&
              PathEquals(setupHistorical.ResultPath, historicalChoice.ResultPath) &&
              setupGroup.Selections[1].SelectedResult is { } setupSecondHistorical &&
              PathEquals(setupSecondHistorical.ResultPath, historicalChoice.ResultPath),
            "Two MultiResult slots and an earlier standalone row can select the same exact historical Result.");
        MapTreeSnapshot setupTree = MapTreeService.Load(setupMap);
        CatalogTreeNodeLocator setupFlowArea = Flatten(setupTree.Roots).Single(node =>
            node.Locator is { NodeType: "FlowAreaLayer", ParentResultNodeType: "MultiResult",
                ParentResultAssetID: { } parentResult } && PathEquals(parentResult, historicalPath)).Locator
            ?? throw new InvalidDataException("The nonzero historical Result omitted its setup FlowArea locator.");
        var setupOwner = new MapResultGeometryOwner(setupGroup.Node, setupSources.ContextToken,
            duplicateHistoricalSlots, 0, historicalChoice.ResultPath, historicalChoice.Revision);
        var setupRequest = new MapTreeMeshErrorRequest(setupMap, setupFlowArea,
            Guid.NewGuid().ToString(), "mesh-error-nonzero-result-setup", setupSources.ContextToken,
            historicalChoice.ResultPath, historicalChoice.Revision, setupOwner, "set",
            CheckMeshErrors: true, MaxFacesPerNodeEntry: 4);
        MapTreeMeshErrorSnapshot enabledHistorical = MapTreeService.MeshErrors(setupRequest);
        Check(enabledHistorical.Status == "available" && enabledHistorical.CheckMeshErrors &&
              enabledHistorical.MaxFacesPerNode == 4,
            $"The historical Result setup performs an enabled exact-source scan. {MeshErrorSnapshotDetails(enabledHistorical)}");
        map = map with { ExpectedVisualizationRevision = enabledHistorical.VisualizationRevision };

        // A second slot still owns the same deduplicated Result context even
        // though the standalone alias was the context representative. Loading
        // via slot one must scan the real embedded FlowArea and retain exact
        // owner/path/revision checks.
        MapTreeRequest duplicateMap = map with { ResultSelectionOverrides = [treeSelection] };
        MapResultSourcesResult duplicateSources = MapResultChartService.Sources(
            new MapResultSourcesRequest(duplicateMap, duplicateHistoricalSlots));
        MapResultActiveNode duplicateGroup = duplicateSources.ActiveNodes.Single(node =>
            node.NodeKind == "MultiResult" && PathEquals(node.Node.AssetID!, planAssetPath));
        MapTreeSnapshot duplicateTree = MapTreeService.Load(duplicateMap);
        CatalogTreeNodeLocator duplicateFlowArea = Flatten(duplicateTree.Roots).Single(node =>
            node.Locator is { NodeType: "FlowAreaLayer", ParentResultNodeType: "MultiResult",
                ParentResultAssetID: { } parentResult } && PathEquals(parentResult, historicalPath)).Locator
            ?? throw new InvalidDataException("The duplicate-slot historical Result omitted its exact FlowArea locator.");
        var duplicateOwner = new MapResultGeometryOwner(duplicateGroup.Node, duplicateSources.ContextToken,
            duplicateHistoricalSlots, 1, historicalChoice.ResultPath, historicalChoice.Revision);
        MapTreeMeshErrorSnapshot duplicateSlotScan = MapTreeService.MeshErrors(new MapTreeMeshErrorRequest(
            duplicateMap, duplicateFlowArea, Guid.NewGuid().ToString(), "mesh-error-duplicate-result-slot",
            duplicateSources.ContextToken, historicalChoice.ResultPath, historicalChoice.Revision,
            duplicateOwner, "load"));
        Check(duplicateSlotScan.Status == "available" && duplicateSlotScan.CheckMeshErrors &&
              duplicateSlotScan.MaxFacesPerNode == 4 &&
              PathEquals(duplicateSlotScan.SourcePath, historicalChoice.ResultPath) &&
              duplicateSlotScan.SourceRevision.Equals(historicalChoice.Revision,
                  StringComparison.OrdinalIgnoreCase) &&
              duplicateSlotScan.ContextToken == duplicateSources.ContextToken,
            $"A duplicate historical Result selected in slot one resolves through the deduplicated standalone representative and scans its exact mesh. {MeshErrorSnapshotDetails(duplicateSlotScan)}");

        // The remainder exercises the writer lease without a checked
        // standalone alias, so only the two explicitly selected MultiResult
        // slots participate in the protected/readable split.
        XDocument withoutStandalone = XDocument.Load(fixture.VisualizationPath, LoadOptions.PreserveWhitespace);
        XElement standaloneRow = withoutStandalone.Root!.Element("Maps")!.Elements("Map")
            .ElementAt(fixture.Map.MapIndex).Element("Tree")!.Element("Nodes")!.Elements("Node")
            .Single(node => (string?)node.Attribute("Name") == "Results")
            .Elements("Node").Single(node => (string?)node.Attribute("Type") == "Result");
        standaloneRow.SetAttributeValue("IsChecked", false);
        withoutStandalone.Save(fixture.VisualizationPath, SaveOptions.DisableFormatting);
        map = map with { ExpectedVisualizationRevision = Hash(File.ReadAllBytes(fixture.VisualizationPath)) };

        // The setting mutation changed the .vis context token; rebuild the
        // source node identity before constructing writer/history requests.
        unleasedSources = MapResultChartService.Sources(new(map, []));
        unleasedGroup = unleasedSources.ActiveNodes.Single(node => node.NodeKind == "MultiResult");
        historyInSlotOne =
        [
            new(unleasedGroup.Node, 0, "Explicit", writerChoice.ResultPath, writerChoice.Revision),
            new(unleasedGroup.Node, 1, "Explicit", historicalChoice.ResultPath, historicalChoice.Revision)
        ];

        var lease = new MapResultComputeReadLease(Guid.NewGuid().ToString("D"), Guid.NewGuid().ToString("D"),
            fixture.ProjectPath, [fixture.ResultPath], fixture.ResultPath);
        MapTreeRequest leasedMap = map with
        {
            ResultSelectionOverrides = [treeSelection],
            ComputeReadLease = lease
        };
        MapTreeSnapshot selectedTree = MapTreeService.Load(leasedMap);
        CatalogTreeNode historicalFlowArea = Flatten(selectedTree.Roots).Single(node =>
            node.Locator is { NodeType: "FlowAreaLayer", ParentResultNodeType: "MultiResult",
                ParentResultAssetID: { } parentResult } locator &&
            PathEquals(parentResult, historicalChoice.ResultPath));
        CatalogTreeNodeLocator historicalFlowAreaLocator = historicalFlowArea.Locator
            ?? throw new InvalidDataException("The selected historical Result omitted its exact FlowArea locator.");
        Check(historicalFlowAreaLocator.ParentResultRevision is { } selectedRevision &&
              selectedRevision.Equals(historicalChoice.Revision, StringComparison.OrdinalIgnoreCase),
            "The selected nonzero-slot FlowArea locator carries the exact historical Result revision.");

        MapResultSourcesResult historySources = MapResultChartService.Sources(new(leasedMap, historyInSlotOne));
        MapResultActiveNode historyGroup = historySources.ActiveNodes.Single(node => node.NodeKind == "MultiResult");
        Check(historyGroup.Selections.Length == 2 && historyGroup.Selections[0].SelectionIndex == 0 &&
              historyGroup.Selections[0].SelectedResult is null &&
              historyGroup.Selections[1].SelectionIndex == 1 &&
              historyGroup.Selections[1].SelectedResult is { } selectedHistorical &&
              PathEquals(selectedHistorical.ResultPath, historicalChoice.ResultPath) &&
              selectedHistorical.Revision.Equals(historicalChoice.Revision, StringComparison.OrdinalIgnoreCase),
            "A writer-protected slot zero remains pending while the exact historical source remains selected in slot one.");

        var historyOwner = new MapResultGeometryOwner(historyGroup.Node, historySources.ContextToken,
            historyInSlotOne, 1, historicalChoice.ResultPath, historicalChoice.Revision);
        var historyRequest = new MapTreeMeshErrorRequest(leasedMap, historicalFlowAreaLocator,
            lease.ProjectSessionID, "mesh-error-nonzero-result-slot", historySources.ContextToken,
            historicalChoice.ResultPath, historicalChoice.Revision, historyOwner, "load");

        MapResultSelectionOverride[] writerInSlotOne =
        [
            new(unleasedGroup.Node, 0, "Explicit", historicalChoice.ResultPath, historicalChoice.Revision),
            new(unleasedGroup.Node, 1, "Explicit", writerChoice.ResultPath, writerChoice.Revision)
        ];
        MapResultSourcesResult writerSources = MapResultChartService.Sources(new(leasedMap, writerInSlotOne));
        MapResultActiveNode writerGroup = writerSources.ActiveNodes.Single(node => node.NodeKind == "MultiResult");
        Check(writerGroup.Selections.Length == 2 &&
              PathEquals(writerGroup.Selections[0].SelectedResult!.ResultPath, historicalChoice.ResultPath) &&
              writerGroup.Selections[1].SelectionIndex == 1 && writerGroup.Selections[1].SelectedResult is null,
            "A selected historical slot zero stays available while a writer-owned slot one remains pending.");

        CatalogTreeNodeLocator writerFlowAreaLocator = historicalFlowAreaLocator with
        {
            ParentResultAssetID = writerChoice.ResultPath,
            ParentResultRevision = writerChoice.Revision
        };
        var writerOwner = new MapResultGeometryOwner(writerGroup.Node, writerSources.ContextToken,
            writerInSlotOne, 1, writerChoice.ResultPath, writerChoice.Revision);
        var writerRequest = new MapTreeMeshErrorRequest(leasedMap, writerFlowAreaLocator,
            lease.ProjectSessionID, "mesh-error-nonzero-result-slot", writerSources.ContextToken,
            writerChoice.ResultPath, writerChoice.Revision, writerOwner, "load");

        byte[] projectBytes = File.ReadAllBytes(fixture.ProjectPath);
        byte[] visualizationBytes = File.ReadAllBytes(fixture.VisualizationPath);
        byte[] writerBytes = File.ReadAllBytes(fixture.ResultPath);
        byte[] historicalBytes = File.ReadAllBytes(historicalPath);
        byte[] terrainBytes = File.ReadAllBytes(fixture.TerrainPath);

        MapTreeMeshErrorSnapshot historySnapshot = MapTreeService.MeshErrors(historyRequest);
        Check(historySnapshot.Status == "available" && historySnapshot.CheckMeshErrors &&
              historySnapshot.MaxFacesPerNode == 4 &&
              historySnapshot.TotalIssueCount >= historySnapshot.Issues.Length &&
              PathEquals(historySnapshot.SourcePath, historicalChoice.ResultPath) &&
              historySnapshot.SourceRevision.Equals(historicalChoice.Revision, StringComparison.OrdinalIgnoreCase) &&
              historySnapshot.ContextToken == historySources.ContextToken,
            $"The enabled mesh-error source loader scans the exact historical FlowArea owned by nonzero slot one while the other slot is writer-protected. {MeshErrorSnapshotDetails(historySnapshot)}");

        MapTreeMeshErrorSnapshot writerSnapshot = MapTreeService.MeshErrors(writerRequest);
        Check(writerSnapshot.Status == "writerProtected" && writerSnapshot.Issues.Length == 0 &&
              PathEquals(writerSnapshot.SourcePath, writerChoice.ResultPath) &&
              writerSnapshot.SourceRevision.Equals(writerChoice.Revision, StringComparison.OrdinalIgnoreCase),
            $"The exact writer-owned Result in nonzero slot one is rejected before its HDF is opened or hashed. {MeshErrorSnapshotDetails(writerSnapshot)}");
        Check(File.ReadAllBytes(fixture.ProjectPath).SequenceEqual(projectBytes) &&
              File.ReadAllBytes(fixture.VisualizationPath).SequenceEqual(visualizationBytes) &&
              File.ReadAllBytes(fixture.ResultPath).SequenceEqual(writerBytes) &&
              File.ReadAllBytes(historicalPath).SequenceEqual(historicalBytes) &&
              File.ReadAllBytes(fixture.TerrainPath).SequenceEqual(terrainBytes),
            "Nonzero Result slot mesh diagnostics preserve project, visualization, writer Result, historical Result and terrain bytes.");

        // A Result-owned FlowArea setting mutation must return the exact locator
        // from its committed .vis tree and a context token recalculated for that
        // visualization revision. The follow-up request then proves both are
        // usable by the real Result/HDF reader.
        MapTreeRequest writableMap = map with { ResultSelectionOverrides = [treeSelection] };
        MapResultSelectionOverride[] writableOverrides =
        [
            new(unleasedGroup.Node, 0, "Explicit", historicalChoice.ResultPath, historicalChoice.Revision),
            new(unleasedGroup.Node, 1, "Explicit", writerChoice.ResultPath, writerChoice.Revision)
        ];
        MapResultSourcesResult writableSources = MapResultChartService.Sources(
            new MapResultSourcesRequest(writableMap, writableOverrides));
        MapResultActiveNode writableGroup = writableSources.ActiveNodes.Single(node =>
            node.NodeKind == "MultiResult" && PathEquals(node.Node.AssetID!, planAssetPath));
        MapTreeSnapshot writableTree = MapTreeService.Load(writableMap);
        CatalogTreeNodeLocator writableFlowArea = Flatten(writableTree.Roots).Single(node =>
            node.Locator is { NodeType: "FlowAreaLayer", ParentResultNodeType: "MultiResult",
                ParentResultAssetID: { } parentResult } && PathEquals(parentResult, historicalPath)).Locator
            ?? throw new InvalidDataException("The writable selected historical Result omitted its FlowArea locator.");
        var writableOwner = new MapResultGeometryOwner(writableGroup.Node, writableSources.ContextToken,
            writableOverrides, 0, historicalChoice.ResultPath, historicalChoice.Revision);
        var writableRequest = new MapTreeMeshErrorRequest(writableMap, writableFlowArea,
            lease.ProjectSessionID, "mesh-error-result-mutation", writableSources.ContextToken,
            historicalChoice.ResultPath, historicalChoice.Revision, writableOwner, "set",
            CheckMeshErrors: true, MaxFacesPerNodeEntry: 5);
        MapTreeMeshErrorSnapshot savedResultSettings = MapTreeService.MeshErrors(writableRequest);
        Check(savedResultSettings.Status == "available" && savedResultSettings.CheckMeshErrors &&
              savedResultSettings.MaxFacesPerNode == 5 &&
              savedResultSettings.VisualizationRevision != writableMap.ExpectedVisualizationRevision,
            $"The tree-selected historical Result in slot zero changes its FlowArea threshold from the setup value, commits, and scans the exact embedded source. {MeshErrorSnapshotDetails(savedResultSettings)} ExpectedPreviousVisualizationRevision={writableMap.ExpectedVisualizationRevision}.");

        MapTreeRequest refreshedWritableMap = writableMap with
        { ExpectedVisualizationRevision = savedResultSettings.VisualizationRevision };
        MapResultSourcesResult refreshedWritableSources = MapResultChartService.Sources(
            new MapResultSourcesRequest(refreshedWritableMap, writableOverrides));
        Check(savedResultSettings.ContextToken == refreshedWritableSources.ContextToken,
            $"The Result receipt carries the context token recalculated from the committed visualization revision. ReceiptContextToken={savedResultSettings.ContextToken}; RefreshedContextToken={refreshedWritableSources.ContextToken}.");
        MapTreeSnapshot refreshedWritableTree = MapTreeService.Load(refreshedWritableMap);
        CatalogTreeNodeLocator exactReloadedFlowArea = Flatten(refreshedWritableTree.Roots).Single(node =>
            node.Locator is { NodeType: "FlowAreaLayer", ParentResultNodeType: "MultiResult",
                ParentResultAssetID: { } parentResult } && PathEquals(parentResult, historicalPath)).Locator
            ?? throw new InvalidDataException("The committed Result FlowArea could not be reloaded by its exact locator.");
        MapResultGeometryOwner refreshedWritableOwner = writableOwner with
        { ContextToken = refreshedWritableSources.ContextToken };
        MapTreeMeshErrorSnapshot reloadedResultSettings = MapTreeService.MeshErrors(writableRequest with
        {
            Map = refreshedWritableMap,
            FlowAreaNode = savedResultSettings.FlowAreaNode,
            ContextToken = refreshedWritableSources.ContextToken,
            ResultOwner = refreshedWritableOwner,
            Action = "load",
            CheckMeshErrors = null,
            MaxFacesPerNodeEntry = null
        });
        Check(MeshErrorLocatorIdentityEquals(exactReloadedFlowArea, savedResultSettings.FlowAreaNode) &&
              reloadedResultSettings.Status == "available" && reloadedResultSettings.CheckMeshErrors &&
              reloadedResultSettings.MaxFacesPerNode == 5 &&
              reloadedResultSettings.ContextToken == refreshedWritableSources.ContextToken,
            $"The Result-owned mutation receipt's new locator and context token load the persisted .vis settings and real mesh data. ReceiptContextToken={savedResultSettings.ContextToken}; RefreshedContextToken={refreshedWritableSources.ContextToken}; {MeshErrorSnapshotDetails(reloadedResultSettings)}");
    }

    private static bool MeshErrorLocatorIdentityEquals(CatalogTreeNodeLocator left,
        CatalogTreeNodeLocator right) =>
        string.Equals(left.RootName, right.RootName, StringComparison.Ordinal) &&
        string.Equals(left.NodeType, right.NodeType, StringComparison.Ordinal) &&
        string.Equals(left.NodeName, right.NodeName, StringComparison.Ordinal) &&
        OptionalIndicesEqual(left.NodePath, right.NodePath) &&
        OptionalLocatorPathEquals(left.AssetID, right.AssetID) &&
        string.Equals(left.MapType, right.MapType, StringComparison.Ordinal) &&
        OptionalLocatorPathEquals(left.Filename, right.Filename) &&
        string.Equals(left.FilenameRelative, right.FilenameRelative, StringComparison.Ordinal) &&
        OptionalLocatorPathEquals(left.ParentGeometryAssetID, right.ParentGeometryAssetID) &&
        OptionalIndicesEqual(left.ParentGeometryNodePath, right.ParentGeometryNodePath) &&
        string.Equals(left.ParentGeometryNodeName, right.ParentGeometryNodeName, StringComparison.Ordinal) &&
        OptionalLocatorPathEquals(left.AssociationAssetID, right.AssociationAssetID) &&
        string.Equals(left.AssociationKind, right.AssociationKind, StringComparison.Ordinal) &&
        OptionalLocatorPathEquals(left.ParentPlanAssetID, right.ParentPlanAssetID) &&
        OptionalIndicesEqual(left.ParentPlanNodePath, right.ParentPlanNodePath) &&
        string.Equals(left.ParentPlanNodeName, right.ParentPlanNodeName, StringComparison.Ordinal) &&
        string.Equals(left.ParentResultNodeType, right.ParentResultNodeType, StringComparison.Ordinal) &&
        OptionalLocatorPathEquals(left.ParentResultAssetID, right.ParentResultAssetID) &&
        OptionalIndicesEqual(left.ParentResultNodePath, right.ParentResultNodePath) &&
        string.Equals(left.ParentResultNodeName, right.ParentResultNodeName, StringComparison.Ordinal) &&
        string.Equals(left.ParentResultRevision, right.ParentResultRevision, StringComparison.OrdinalIgnoreCase) &&
        OptionalLocatorPathEquals(left.ParentBoundaryConditionAssetID, right.ParentBoundaryConditionAssetID) &&
        OptionalIndicesEqual(left.ParentBoundaryConditionNodePath, right.ParentBoundaryConditionNodePath) &&
        string.Equals(left.ParentBoundaryConditionNodeName, right.ParentBoundaryConditionNodeName,
            StringComparison.Ordinal);

    private static bool OptionalIndicesEqual(int[]? left, int[]? right) =>
        left is null || right is null ? left is null && right is null : left.SequenceEqual(right);

    private static bool OptionalLocatorPathEquals(string? left, string? right) =>
        left is null || right is null ? left is null && right is null : PathEquals(left, right);

    private static string MeshErrorSnapshotDetails(MapTreeMeshErrorSnapshot snapshot) =>
        $"Status={snapshot.Status}; Diagnostic={snapshot.Diagnostic ?? "<none>"}; " +
        $"CheckMeshErrors={snapshot.CheckMeshErrors}; MaxFacesPerNode={snapshot.MaxFacesPerNode}; " +
        $"PreviousVisualizationRevision={snapshot.PreviousVisualizationRevision ?? "<none>"}; " +
        $"VisualizationRevision={snapshot.VisualizationRevision}; " +
        $"ContextToken={snapshot.ContextToken}; SourcePath={snapshot.SourcePath}; " +
        $"SourceRevision={snapshot.SourceRevision}.";

    private static IEnumerable<CatalogTreeNode> Flatten(IEnumerable<CatalogTreeNode> nodes)
    {
        foreach (CatalogTreeNode node in nodes)
        {
            yield return node;
            if (node.Children is not null)
                foreach (CatalogTreeNode child in Flatten(node.Children)) yield return child;
        }
    }

    private static string Hash(byte[] bytes) => Convert.ToHexString(SHA256.HashData(bytes));

    private static bool PathEquals(string first, string second) =>
        string.Equals(Path.GetFullPath(first), Path.GetFullPath(second), OperatingSystem.IsWindows()
            ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal);

    private static bool IsUnchangedOrMaterializedPath(int[]? previous, int[]? current) =>
        previous is null || current is null
            ? previous is null && current is null || previous is null && current is { Length: > 0 }
            : previous.SequenceEqual(current);

    private static byte[] SerializeMesh(Mesh mesh)
    {
        using var stream = new MemoryStream();
        using (var writer = new BinaryWriter(stream, System.Text.Encoding.UTF8, leaveOpen: true)) mesh.Stream(writer);
        return stream.ToArray();
    }

    private static void Check(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }

    private static void ExpectSync<T>(Action action) where T : Exception
    {
        try { action(); }
        catch (T) { return; }
        throw new InvalidOperationException("Expected " + typeof(T).Name);
    }

    private static async Task Expect<T>(Func<Task> action) where T : Exception
    {
        try { await action(); }
        catch (T) { return; }
        throw new InvalidOperationException("Expected " + typeof(T).Name);
    }

    private sealed class NonSeekableReadStream(Stream inner) : Stream
    {
        public override bool CanRead => inner.CanRead;
        public override bool CanSeek => false;
        public override bool CanWrite => false;
        public override long Length => throw new NotSupportedException();
        public override long Position { get => throw new NotSupportedException(); set => throw new NotSupportedException(); }
        public override void Flush() => throw new NotSupportedException();
        public override int Read(byte[] buffer, int offset, int count) => inner.Read(buffer, offset, count);
        public override int Read(Span<byte> buffer) => inner.Read(buffer);
        public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
        public override void SetLength(long value) => throw new NotSupportedException();
        public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();
    }
}
