using Utility.Memory;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Geospatial.Features;
using Geospatial.IO;
using Geospatial.Vectors;
using Geospatial.Vectors.Topology;
using Ras.Backend;
using Ras.Layers;
using Utility.Units;

internal static class GeometryVectorImportChecks
{
    internal static async Task Run()
    {
        using var directory = new TemporaryDirectory();
        string projectPath = Path.Combine(directory.FullName, "Vector import.ras");
        var project = Project.CreateNew(projectPath, UnitSystem.SI);
        var geometry = project.AddNewGeometry("Vector import geometry");
        Topology topology = Topology.FromExtent(new Extent(0, 100, 0, 100));
        topology.AddNode(20, 20, out int lowerLeft);
        topology.AddNode(40, 20, out int lowerRight);
        topology.AddNode(40, 40, out int upperRight);
        topology.AddNode(20, 40, out int upperLeft);
        topology.AddArc(lowerLeft, lowerRight, [], out int south);
        topology.AddArc(lowerRight, upperRight, [], out int east);
        topology.AddArc(upperRight, upperLeft, [], out int north);
        topology.AddArc(upperLeft, lowerLeft, [], out int west);
        var ring = new RegionRing(4);
        ring.Arcs.Add(new ArcWithDirection(south, true));
        ring.Arcs.Add(new ArcWithDirection(east, true));
        ring.Arcs.Add(new ArcWithDirection(north, true));
        ring.Arcs.Add(new ArcWithDirection(west, true));
        topology.CompletedRegions.Single().AddInnerRing(ring);
        geometry.ConceptualMeshLayer.Topology = topology;
        string assetPath = geometry.Filename;
        project.Save();
        geometry.Save();
        geometry.Dispose();

        string noMergePath = CreateLine(directory.FullName, "no-merge.shp", "No merge",
            [new Point(10, 70), new Point(45, 70), new Point(90, 70)]);
        string mergePath = CreateLine(directory.FullName, "merge.shp", "Merge",
            [new Point(10, 55), new Point(45, 55), new Point(90, 55)]);
        Point[] polygonPoints =
            [new Point(55, 70), new Point(80, 70), new Point(80, 90), new Point(55, 90), new Point(55, 70)];
        string polygonPath = CreatePolygon(directory.FullName, "polygon.shp", "Imported polygon", polygonPoints);
        MapSourceFamilyCapture noMergeFamily = MapTreeService.CaptureShapefileFamily(noMergePath);
        MapSourceFamilyCapture mergeFamily = MapTreeService.CaptureShapefileFamily(mergePath);
        MapSourceFamilyCapture polygonFamily = MapTreeService.CaptureShapefileFamily(polygonPath);
        var model = new GeometryTopologyModelRequest(assetPath, "Geometry", projectPath);
        byte[] originalGeometry = File.ReadAllBytes(assetPath);

        GeometryTopologySnapshot loaded = await ModelEditorAdapter.LoadGeometryTopologyAsync(new(model));
        string draftIdentity = loaded.Completion?.DraftIdentity
            ?? throw new InvalidOperationException("The topology reader omitted its exact draft identity.");
        var inspectRequest = new GeometryVectorImportInspectRequest(model, loaded.Revision,
            loaded.DraftState, draftIdentity, [noMergePath, mergePath, polygonPath]);
        await Expect<SourceFileChangedException>(() => ModelEditorAdapter.InspectGeometryVectorImportAsync(
            inspectRequest with { DraftState = loaded.DraftState + " " }));
        GeometryVectorImportInspection inspected = await ModelEditorAdapter.InspectGeometryVectorImportAsync(inspectRequest);
        Check(inspected.Revision == loaded.Revision && inspected.DraftIdentity == draftIdentity
            && inspected.Sources.Length == 3 && inspected.Issues.Length == 0
            && inspected.Sources.Where(source => source.Path != polygonFamily.SourcePath)
                .All(source => source.ShapeType == "Polyline" && source.FeatureCount == 1)
            && inspected.Sources.Single(source => source.Path == polygonFamily.SourcePath).FeatureCount == 1,
            "The inspection returns actual line and polygon records and captures the exact parent draft.");
        Check(inspected.Sources.Single(source => source.Path == noMergeFamily.SourcePath).Features.Single().Points.SequenceEqual(
                [new GeometryTopologyCoordinate(10, 70), new GeometryTopologyCoordinate(45, 70), new GeometryTopologyCoordinate(90, 70)])
            && inspected.Sources.Single(source => source.Path == mergeFamily.SourcePath).Features.Single().Points.SequenceEqual(
                [new GeometryTopologyCoordinate(10, 55), new GeometryTopologyCoordinate(45, 55), new GeometryTopologyCoordinate(90, 55)]),
            "Separate selected source files retain their real, distinct coordinate sequences.");
        GeometryVectorImportSource polygonSource = inspected.Sources.Single(source => source.Path == polygonFamily.SourcePath);
        GeometryTopologyCoordinate[] expectedPolygonCoordinates = polygonPoints
            .Select(point => new GeometryTopologyCoordinate(point.X, point.Y)).ToArray();
        Check(polygonSource.ShapeType == "Polygon" && polygonSource.Features.Single().GeometryType == "polygon"
            && polygonSource.Features.Single().Points.SequenceEqual(expectedPolygonCoordinates),
            "Polygon records retain their geometry kind and source coordinates instead of becoming preview-only shapes.");

        byte[] dbfBeforeStaleAttempt = File.ReadAllBytes(ShapefileIO.DBFFilename(noMergePath));
        File.AppendAllText(ShapefileIO.DBFFilename(noMergePath), "changed after inspection");
        var inspectedNoMerge = inspected.Sources.Single(source => source.Path == noMergeFamily.SourcePath);
        await Expect<SourceFileChangedException>(() => ModelEditorAdapter.ApplyGeometryVectorImportAsync(
            new GeometryVectorImportApplyRequest(model, loaded.Revision, loaded.DraftState, draftIdentity,
                [new(inspectedNoMerge.Path, inspectedNoMerge.Family)], "NoMerge", false, false)));
        File.WriteAllBytes(ShapefileIO.DBFFilename(noMergePath), dbfBeforeStaleAttempt);
        Check(File.ReadAllBytes(assetPath).SequenceEqual(originalGeometry),
            "A changed Shapefile member is rejected without touching the geometry source.");

        GeometryVectorImportSource noMergeSource = inspected.Sources.Single(source => source.Path == noMergeFamily.SourcePath);
        GeometryTopologySnapshot pasted = await ModelEditorAdapter.ApplyGeometryVectorImportAsync(
            new GeometryVectorImportApplyRequest(model, loaded.Revision, loaded.DraftState, draftIdentity,
                [new(noMergeSource.Path, noMergeSource.Family), new(polygonSource.Path, polygonSource.Family)], "NoMerge", false, false));
        Check(pasted.IsDirty && pasted.Arcs.Rows.Length > loaded.Arcs.Rows.Length
            && pasted.DraftState.Contains("importPayload", StringComparison.Ordinal)
            && pasted.DraftState.Contains("polygon", StringComparison.Ordinal)
            && File.ReadAllBytes(assetPath).SequenceEqual(originalGeometry),
            "Import Without Merge adds real line and polygon arcs as one unsaved replayable parent-draft mutation.");
        string expectedDraftIdentity = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(pasted.DraftState)))
            .ToLowerInvariant();
        GeometryTopologyCompletionResult completion = pasted.Completion
            ?? throw new InvalidOperationException("The topology import omitted its new draft generation identity.");
        Check(completion.DraftIdentity == expectedDraftIdentity && completion.DraftIdentity != draftIdentity,
            "The import response identifies the exact new opaque parent draft generation.");
        using (JsonDocument draft = JsonDocument.Parse(pasted.DraftState))
        {
            JsonElement importPayload = draft.RootElement.GetProperty("mutations").EnumerateArray().Single()
                .GetProperty("importPayload");
            Dictionary<string, string> retainedFamilies = importPayload.GetProperty("sources").EnumerateArray()
                .ToDictionary(source => source.GetProperty("path").GetString()!,
                    source => source.GetProperty("family").GetProperty("revision").GetString()!);
            Check(retainedFamilies.TryGetValue(noMergeFamily.SourcePath, out string? retainedLineRevision)
                    && retainedLineRevision == noMergeFamily.Revision
                && retainedFamilies.TryGetValue(polygonFamily.SourcePath, out string? retainedPolygonRevision)
                    && retainedPolygonRevision == polygonFamily.Revision,
                "The saved draft mutation retains each selected source path and its exact captured family SHA.");
        }

        GeometryTopologySnapshot undone = await ModelEditorAdapter.EditGeometryTopologyAsync(new(model,
            pasted.Revision, pasted.DraftState, new("undo", "history", [])));
        Check(TopologyRowsIdentity(undone.Arcs.Rows) == TopologyRowsIdentity(loaded.Arcs.Rows),
            "Undo removes the whole imported line operation from the parent draft.");
        GeometryTopologySnapshot redone = await ModelEditorAdapter.EditGeometryTopologyAsync(new(model,
            undone.Revision, undone.DraftState, new("redo", "history", [])));
        Check(TopologyRowsIdentity(redone.Arcs.Rows) == TopologyRowsIdentity(pasted.Arcs.Rows),
            "Redo replays the same imported source features in their original order.");

        GeometryVectorImportSource mergeSource = inspected.Sources.Single(source => source.Path == mergeFamily.SourcePath);
        GeometryTopologySnapshot merged = await ModelEditorAdapter.ApplyGeometryVectorImportAsync(
            new GeometryVectorImportApplyRequest(model, redone.Revision, redone.DraftState,
                redone.Completion!.DraftIdentity,
                [new(mergeSource.Path, mergeSource.Family)], "Merge", MergeContiguousArcs: true,
                RemoveExternalArcs: false));
        Check(merged.IsDirty && merged.DraftState != redone.DraftState
            && File.ReadAllBytes(assetPath).SequenceEqual(originalGeometry),
            "Import and Merge runs the retained TIN merge and contiguous-arc option inside the unsaved parent draft.");

        foreach (string path in noMergeFamily.Files.Concat(mergeFamily.Files).Concat(polygonFamily.Files).Where(file => file.Exists)
                     .Select(file => file.Path).Distinct(StringComparer.Ordinal))
            File.Delete(path);
        ModelSnapshot saved = await ModelEditorAdapter.SaveAsync(new ModelSaveRequest(assetPath, "Geometry",
            projectPath, merged.Revision, [], [], GeometryTopologyState: merged.DraftState));
        GeometryTopologySnapshot reopened = await ModelEditorAdapter.LoadGeometryTopologyAsync(new(model, saved.Revision));
        Check(!reopened.IsDirty && reopened.Arcs.Rows.Length > loaded.Arcs.Rows.Length
            && !File.ReadAllBytes(assetPath).SequenceEqual(originalGeometry),
            "The parent model save persists the imported topology and draft replay no longer depends on source files.");
    }

    private static string CreateLine(string directory, string filename, string name, Point[] points)
    {
        string path = Path.Combine(directory, filename);
        var table = new Table();
        table.AddColumn("Name", typeof(string));
        table.AddNewRow([name]);
        Check(ShapefileIO.Write(path, new List<Polyline> { new(points) }, table).Result,
            "The retained writer creates a real Shapefile fixture.");
        return path;
    }

    private static string CreatePolygon(string directory, string filename, string name, Point[] points)
    {
        string path = Path.Combine(directory, filename);
        var table = new Table();
        table.AddColumn("Name", typeof(string));
        table.AddNewRow([name]);
        var sourcePolygon = new Polygon(points);
        // The generic Polyline overload writes a line shapefile even when the
        // runtime instance is Polygon. Keep the collection's static type exact.
        Check(ShapefileIO.Write(path, new List<Polygon> { sourcePolygon }, table).Result,
            "The retained writer creates a real polygon Shapefile fixture.");
        Check(ShapefileIO.IsPolygonShapefile(path),
            "The polygon fixture has a polygon ShapeType header rather than a line header.");

        Check(ShapefileIO.TryRead(path, out PolygonCollectionFeatureCollection reopened).Result,
            "An independent Shapefile reopen reads the polygon record.");
        Polygon reopenedSource = reopened.Features.Single().Single();
        Point[] pointsBeforeGetter = reopenedSource.Points.ToArray();
        Polygon flattenedSource = reopened.ToExplodedPolygonCollection().Single();
        Check(pointsBeforeGetter.SequenceEqual(points) && pointsBeforeGetter.Length >= 4
            && pointsBeforeGetter[0].Equals(pointsBeforeGetter[^1]),
            "The reopened polygon retains its original coordinate order and explicit closing point.");
        Check(ReferenceEquals(reopenedSource, flattenedSource)
            && reopenedSource.Points.SequenceEqual(pointsBeforeGetter),
            "The polygon collection source getter returns the same record without changing its coordinates.");
        return path;
    }

    private static string TopologyRowsIdentity(GeometryTopologyFeatureRow[] rows) =>
        string.Join("|", rows.Select(row => $"{row.ID}:{row.FID}"));

    private static void Check(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }

    private static async Task Expect<T>(Func<Task> operation) where T : Exception
    {
        try { await operation(); }
        catch (T) { return; }
        throw new InvalidOperationException("Expected " + typeof(T).Name + ".");
    }

    private sealed class TemporaryDirectory : IDisposable
    {
        private readonly DirectoryInfo directory = Directory.CreateTempSubdirectory("hecras-vector-import-");
        public string FullName => directory.FullName;
        public void Dispose() => directory.Delete(recursive: true);
    }
}
