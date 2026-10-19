using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Geospatial;
using Geospatial.Features;
using Geospatial.GDALAssist;
using Geospatial.IO;
using Geospatial.Vectors;
using Geospatial.Vectors.Topology;
using Ras.Backend;
using Ras.Layers;
using Utility.Units;

internal static class GeometryMeshElementToolsChecks
{
    internal static async Task Run()
    {
        using var directory = new TemporaryDirectory();
        string projectPath = Path.Combine(directory.FullName, "Mesh element tools.ras");
        Project project = Project.CreateNew(projectPath, ProjectionDefinition.FromEPSG(32650));
        Geometry geometry = project.AddNewGeometry("Element tools geometry");
        geometry.ConceptualMeshLayer.Topology = Topology.FromExtent(
            new Extent(500_000, 500_020, 4_500_000, 4_500_020));
        geometry.Save();
        project.Save();
        string assetPath = geometry.Filename;
        geometry.Dispose();
        MapResultChartService.DisposeProject(project);

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

        var model = new GeometryMeshModelRequest(assetPath, "Geometry", projectPath);
        GeometryMeshSnapshot loaded = await ModelEditorAdapter.LoadGeometryMeshAsync(new(model,
            TopologyDraftState: sized.DraftState));
        GeometryMeshSnapshot generated = await ModelEditorAdapter.EditGeometryMeshAsync(new(model,
            loaded.Revision, loaded.DraftState, sized.DraftState, [], new("generate")));
        Check(generated.GenerationReport is { Succeeded: true, MeshWasReplaced: true, CellCount: > 0 }
            && generated.FlowAreas is [{ ID: "flow-area-row:0", HasMesh: true }],
            "Mesh tools operate on a real generated mesh in the current unsaved Geometry draft.");

        byte[] geometryBefore = File.ReadAllBytes(assetPath);
        byte[] projectBefore = File.ReadAllBytes(projectPath);
        GeometryMeshDraftState draft = JsonSerializer.Deserialize<GeometryMeshDraftState>(
            generated.DraftState, BackendJson.Options)
            ?? throw new InvalidOperationException("The generated mesh draft is missing.");
        string meshPayload = draft.Mutations.Single().GeneratedMeshPayload
            ?? throw new InvalidOperationException("The generated mesh draft omitted its serialized source mesh.");
        Mesh sourceMesh;
        using (var stream = new MemoryStream(Convert.FromBase64String(meshPayload), writable: false))
        using (var reader = new BinaryReader(stream))
            sourceMesh = Mesh.Stream(reader);

        string meshSHA = Digest(generated.DraftState);
        string topologySHA = Digest(sized.DraftState);
        string flowAreaID = generated.FlowAreas.Single().ID;
        string flowAreaName = generated.FlowAreas.Single().Name;
        GeometryMeshElementFindResult cell = await ModelEditorAdapter.FindGeometryMeshElementAsync(
            FindRequest(model, generated, sized.DraftState, meshSHA, topologySHA,
                flowAreaID, flowAreaName, "Cell", 0));
        GeometryMeshElementFindResult face = await ModelEditorAdapter.FindGeometryMeshElementAsync(
            FindRequest(model, generated, sized.DraftState, meshSHA, topologySHA,
                flowAreaID, flowAreaName, "Face", 0));
        GeometryMeshElementFindResult node = await ModelEditorAdapter.FindGeometryMeshElementAsync(
            FindRequest(model, generated, sized.DraftState, meshSHA, topologySHA,
                flowAreaID, flowAreaName, "Node", 0));
        Point cellCenter = sourceMesh.CellCenters[0];
        Point faceCenter = sourceMesh.FaceCentroidPoint(0);
        Point nodePoint = sourceMesh.FacePoints[0].Point;
        Check(cell.FlowAreaID == flowAreaID && cell.FlowAreaName == flowAreaName
            && cell.ElementKind == "Cell" && cell.Index == 0
            && Near(cell.X, cellCenter.X) && Near(cell.Y, cellCenter.Y)
            && cell.Coordinates.SequenceEqual(sourceMesh.CellPolygon(0).Points
                .Select(point => new GeometryTopologyCoordinate(point.X, point.Y)))
            && cell.Coordinates.Length >= 3
            && SameExtent(cell.Viewport, sourceMesh.CellCenters[0],
                Math.Sqrt(sourceMesh.CellPolygonArea(0)) * 2.0),
            "Find Cell returns the exact draft cell polygon, source center, request identity and legacy viewport.");
        Check(face.ElementKind == "Face" && face.Index == 0
            && Near(face.X, faceCenter.X) && Near(face.Y, faceCenter.Y)
            && face.Coordinates.SequenceEqual(PolylineCoordinates(sourceMesh.FacePolyline(0)))
            && face.Coordinates.Length >= 2
            && SameExtent(face.Viewport, faceCenter, sourceMesh.FacePolylineLength(0) * 2.0),
            "Find Face returns the exact draft face polyline, centroid, request identity and legacy viewport.");
        Check(node.ElementKind == "Node" && node.Index == 0
            && Near(node.X, nodePoint.X) && Near(node.Y, nodePoint.Y)
            && node.Coordinates.SequenceEqual([new GeometryTopologyCoordinate(nodePoint.X, nodePoint.Y)])
            && SameExtent(node.Viewport, nodePoint, sourceMesh.FaceSimpleLength(0) * 2.0),
            "Find Node returns the exact draft node coordinate and legacy viewport.");
        await ExpectAsync<ArgumentOutOfRangeException>(() => ModelEditorAdapter.FindGeometryMeshElementAsync(
            FindRequest(model, generated, sized.DraftState, meshSHA, topologySHA,
                flowAreaID, flowAreaName, "Cell", -1)));
        await ExpectAsync<ArgumentOutOfRangeException>(() => ModelEditorAdapter.FindGeometryMeshElementAsync(
            FindRequest(model, generated, sized.DraftState, meshSHA, topologySHA,
                flowAreaID, flowAreaName, "Cell", sourceMesh.CellCount)));
        await ExpectAsync<SourceFileChangedException>(() => ModelEditorAdapter.FindGeometryMeshElementAsync(
            FindRequest(model, generated, sized.DraftState, meshSHA, topologySHA,
                flowAreaID, "stale flow-area name", "Cell", 0)));

        string centersPath = Path.Combine(directory.FullName, "Current mesh cell centers.shp");
        GeometryMeshShapefileExportRequest centersRequest = ExportRequest(model, generated,
            sized.DraftState, meshSHA, topologySHA, flowAreaID, flowAreaName,
            "CellCenters", centersPath, Guid.NewGuid().ToString("D"));
        GeometryMeshShapefileExportResult centersResult = await ModelEditorAdapter.ExportGeometryMeshShapefileAsync(
            centersRequest, null, null);
        Check(centersResult.State == "completed" && centersResult.OutputPath == centersPath
            && centersResult.FeatureCount == sourceMesh.CellCount
            && centersResult.CanonicalAssetPath == Path.GetFullPath(assetPath)
            && centersResult.SourceRevision == generated.Revision
            && centersResult.FlowAreaID == flowAreaID && centersResult.FlowAreaName == flowAreaName
            && centersResult.MeshDraftSHA256 == meshSHA && centersResult.TopologyDraftSHA256 == topologySHA,
            "Cell-center export returns the exact revision, current draft identities and a completed receipt.");
        Check(ShapefileIO.TryRead(centersPath, out PointFeatureCollection centers).Result
            && centers.Count == sourceMesh.CellCount,
            "The cell-center export is a real readable Point Shapefile with one feature per source cell.");
        Point[] actualCenters = centers.AsPointCollection().ToArray();
        Point[] expectedCenters = sourceMesh.CellCenters.ToArray();
        Check(actualCenters.Length == expectedCenters.Length
            && actualCenters.Zip(expectedCenters).All(pair => Near(pair.First.X, pair.Second.X)
                && Near(pair.First.Y, pair.Second.Y)),
            "Every exported point coordinate preserves the exact source CellCenters order and coordinates.");
        CheckProjectionAndReceipts(centersResult, centersPath);
        GeometryMeshShapefileExportResult repeated = await ModelEditorAdapter.ExportGeometryMeshShapefileAsync(
            centersRequest, null, null);
        Check(repeated.Artifacts.SequenceEqual(centersResult.Artifacts),
            "Retrying a completed operation ID returns its original receipt without rewriting files.");
        await ExpectAsync<ArgumentException>(() => ModelEditorAdapter.ExportGeometryMeshShapefileAsync(
            centersRequest with { OutputPath = Path.Combine(directory.FullName, "Different.shp") }, null, null));

        string perimeterPath = Path.Combine(directory.FullName, "Current mesh perimeter faces.shp");
        GeometryMeshShapefileExportResult perimeterResult = await ModelEditorAdapter.ExportGeometryMeshShapefileAsync(
            ExportRequest(model, generated, sized.DraftState, meshSHA, topologySHA,
                flowAreaID, flowAreaName, "PerimeterFaces", perimeterPath, Guid.NewGuid().ToString("D")),
            null, null);
        var expectedPerimeter = Enumerable.Range(0, sourceMesh.Faces.Length)
            .Where(index => sourceMesh.Faces[index].cellA < 0 || sourceMesh.Faces[index].cellB < 0)
            .Select(index => (Index: index, Face: sourceMesh.Faces[index],
                Line: sourceMesh.FacePolyline(index), Length: sourceMesh.FacePolylineLength(index)))
            .ToArray();
        Check(expectedPerimeter.Length > 0 && perimeterResult.State == "completed"
            && perimeterResult.FeatureCount == expectedPerimeter.Length,
            "The perimeter export uses the retained faceA/faceB exterior-face definition.");
        Check(ShapefileIO.TryRead(perimeterPath, out PolylineCollectionFeatureCollection perimeter).Result
            && perimeter.Count == expectedPerimeter.Length,
            "The perimeter export is a real readable Polyline Shapefile with the exact source face count.");
        Polyline[] actualLines = perimeter.ToExplodedPolylineCollection().ToArray();
        Check(actualLines.Length == expectedPerimeter.Length
            && actualLines.Zip(expectedPerimeter).All(pair => PolylineEquals(pair.First, pair.Second.Line)),
            "Perimeter polyline records preserve source mesh face order and every source vertex.");
        Check(perimeter.AttributeTable.Columns.Select(column => column.Name)
                .SequenceEqual(["Face", "CellA", "CellB", "Length"], StringComparer.Ordinal)
            && perimeter.AttributeTable.Columns.Select(column => column.Type)
                .SequenceEqual([typeof(int), typeof(int), typeof(int), typeof(double)])
            && perimeter.AttributeTable.Rows.Count == expectedPerimeter.Length
            && expectedPerimeter.Select((expected, index) =>
                Convert.ToInt32(perimeter.AttributeTable.Rows[index][0], CultureInfo.InvariantCulture) == expected.Index
                && Convert.ToInt32(perimeter.AttributeTable.Rows[index][1], CultureInfo.InvariantCulture) == expected.Face.cellA
                && Convert.ToInt32(perimeter.AttributeTable.Rows[index][2], CultureInfo.InvariantCulture) == expected.Face.cellB
                && Near(Convert.ToDouble(perimeter.AttributeTable.Rows[index][3], CultureInfo.InvariantCulture), expected.Length, 1e-5))
                .All(valid => valid),
            "Perimeter DBF retains the exact Face, CellA, CellB, Length schema, values and source ordering.");
        CheckProjectionAndReceipts(perimeterResult, perimeterPath);
        Check(File.ReadAllBytes(assetPath).SequenceEqual(geometryBefore)
            && File.ReadAllBytes(projectPath).SequenceEqual(projectBefore),
            "Find and both exports only replay the current child draft; source Geometry HDF and project remain unchanged.");

        string occupiedPath = Path.Combine(directory.FullName, "Occupied mesh export.shp");
        byte[] existingDbf = [0x21, 0x43, 0x65];
        File.WriteAllBytes(ShapefileIO.DBFFilename(occupiedPath), existingDbf);
        await ExpectAsync<IOException>(() => ModelEditorAdapter.ExportGeometryMeshShapefileAsync(
            ExportRequest(model, generated, sized.DraftState, meshSHA, topologySHA,
                flowAreaID, flowAreaName, "CellCenters", occupiedPath, Guid.NewGuid().ToString("D")), null, null));
        Check(File.ReadAllBytes(ShapefileIO.DBFFilename(occupiedPath)).SequenceEqual(existingDbf)
            && !File.Exists(occupiedPath) && !File.Exists(ShapefileIO.SHXFilename(occupiedPath)),
            "An occupied sidecar blocks publication before any other family component is created or replaced.");

        using (var append = new FileStream(assetPath, FileMode.Append, FileAccess.Write, FileShare.Read))
            append.WriteByte(0x5a);
        string staleOutput = Path.Combine(directory.FullName, "Stale source export.shp");
        await ExpectAsync<SourceFileChangedException>(() => ModelEditorAdapter.ExportGeometryMeshShapefileAsync(
            ExportRequest(model, generated, sized.DraftState, meshSHA, topologySHA,
                flowAreaID, flowAreaName, "CellCenters", staleOutput, Guid.NewGuid().ToString("D")), null, null));
        Check(!File.Exists(staleOutput) && !File.Exists(ShapefileIO.DBFFilename(staleOutput)),
            "An HDF revision change rejects export before writing any public Shapefile family member.");

        Console.WriteLine("Mesh element lookup and Cell Centers / Perimeter Faces exports match the retained source Mesh and Shapefile formats.");
    }

    private static GeometryMeshElementFindRequest FindRequest(GeometryMeshModelRequest model,
        GeometryMeshSnapshot mesh, string topologyDraft, string meshSHA, string topologySHA,
        string flowAreaID, string flowAreaName, string elementKind, int index) => new(
        model, mesh.Revision, mesh.DraftState, topologyDraft, meshSHA, topologySHA,
        flowAreaID, flowAreaName, elementKind, index);

    private static GeometryMeshShapefileExportRequest ExportRequest(GeometryMeshModelRequest model,
        GeometryMeshSnapshot mesh, string topologyDraft, string meshSHA, string topologySHA,
        string flowAreaID, string flowAreaName, string exportKind, string outputPath, string operationID) => new(
        operationID, model, mesh.Revision, mesh.DraftState, topologyDraft, meshSHA, topologySHA,
        flowAreaID, flowAreaName, exportKind, outputPath);

    private static void CheckProjectionAndReceipts(GeometryMeshShapefileExportResult result, string shpPath)
    {
        Check(result.ProjectionWKT is { Length: > 0 }
            && File.Exists(ShapefileIO.PRJFilename(shpPath))
            && new ESRIProjection(ShapefileIO.PRJFilename(shpPath)).IsEqual(new EPSGProjection(32650)),
            "A projected source mesh writes a matching EPSG:32650 .prj sidecar.");
        string[] required = [".shp", ".shx", ".dbf", ".prj"];
        Check(required.All(extension => result.Artifacts.Any(artifact =>
                string.Equals(Path.GetExtension(artifact.Path), extension, StringComparison.OrdinalIgnoreCase)))
            && result.Artifacts.All(artifact => File.Exists(artifact.Path)
                && artifact.SizeBytes == new FileInfo(artifact.Path).Length
                && artifact.SHA256.Equals(Hash(File.ReadAllBytes(artifact.Path)), StringComparison.OrdinalIgnoreCase)),
            "The export receipt covers every published Shapefile component with its actual size and SHA-256.");
    }

    private static GeometryTopologyCoordinate[] PolylineCoordinates(Polyline line) => line.Points
        .Select(point => new GeometryTopologyCoordinate(point.X, point.Y)).ToArray();

    private static bool PolylineEquals(Polyline actual, Polyline expected)
    {
        GeometryTopologyCoordinate[] left = PolylineCoordinates(actual);
        GeometryTopologyCoordinate[] right = PolylineCoordinates(expected);
        return left.Length == right.Length && left.Zip(right).All(pair =>
            Near(pair.First.X, pair.Second.X) && Near(pair.First.Y, pair.Second.Y));
    }

    private static bool SameExtent(GeometryMeshExtent actual, Point center, double size)
    {
        Extent expected = Extent.CenteredOn(center, size).EnforceMinDimensions(1.0, 1.0);
        return Near(actual.MinX, expected.MinX) && Near(actual.MinY, expected.MinY)
            && Near(actual.MaxX, expected.MaxX) && Near(actual.MaxY, expected.MaxY);
    }

    private static bool Near(double left, double right, double tolerance = 1e-8) =>
        Math.Abs(left - right) <= tolerance;

    private static string Digest(string value) => Hash(Encoding.UTF8.GetBytes(value));

    private static string Hash(byte[] bytes) =>
        Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant();

    private static async Task ExpectAsync<TException>(Func<Task> action) where TException : Exception
    {
        try { await action(); }
        catch (TException) { return; }
        throw new InvalidOperationException("Expected " + typeof(TException).Name + ".");
    }

    private static void Check(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }
}
