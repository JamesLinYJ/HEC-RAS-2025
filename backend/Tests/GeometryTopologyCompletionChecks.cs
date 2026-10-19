using System.Security.Cryptography;
using System.Text;
using System.Reflection;
using Geospatial.Vectors;
using Geospatial.Vectors.Topology;
using Geospatial.Rendering.Systems.Vector;
using Ras.Backend;
using Ras.Layers;
using Utility.Units;

internal static class GeometryTopologyCompletionChecks
{
    private const string QuadPatchError = "ConceptualMeshTopology_QuadPatchLessThanFourArcs";

    internal static async Task Run()
    {
        CheckHeadlessProxyRejectsRenderingCalls();
        await CheckAutomaticRepairDraftReplay();
        using var directory = new TemporaryDirectory();
        string projectPath = Path.Combine(directory.FullName, "Topology completion.ras");
        Project project = Project.CreateNew(projectPath, UnitSystem.SI);
        Geometry geometry = project.AddNewGeometry("Triangle with a quad patch");
        Topology topology = CreateTriangleWithQuadPatch();
        geometry.ConceptualMeshLayer.Topology = topology;
        string assetPath = geometry.Filename;
        project.Save();
        geometry.Save();
        geometry.Dispose();

        var model = new GeometryTopologyModelRequest(assetPath, "Geometry", projectPath);
        byte[] originalSource = File.ReadAllBytes(assetPath);
        GeometryTopologySnapshot loaded = await ModelEditorAdapter.LoadGeometryTopologyAsync(new(model));
        GeometryTopologyCompletionResult sourceFailure = RequireCompletion(loaded);
        Check(!sourceFailure.IsComplete && sourceFailure.SourceRevision == loaded.Revision,
            "The initial completion result reports the source topology failure against its saved revision");
        Check(sourceFailure.DraftIdentity == DraftIdentity(loaded.DraftState),
            "Completion identity hashes the exact opaque draft string returned in the same snapshot");

        GeometryTopologyCompletionMessage quadError = sourceFailure.Messages.Single(message => message.Code == QuadPatchError);
        GeometryTopologyLogValue regionIndex = quadError.LogData.Single(value => value.Key == "RegionIndex");
        Check(regionIndex.IntegerValue is >= 0,
            "The retained source message exposes its completed-region ordinal as an integer log value");
        GeometryTopologyFeatureRow controlPoint = loaded.Regions.Rows.Single();
        GeometryTopologyDiagnosticTarget target = quadError.Targets.Single(item =>
            item.FeatureKind == "controlPoint" && item.FID == controlPoint.FID);
        Check(target.TableRowID == controlPoint.ID
            && target.TableRowID == "region:" + controlPoint.FID,
            "A retained RegionIndex resolves to the contained source control-point row, not to a fabricated FID");
        GeometryTopologyMapFeature polygon = loaded.Map!.Features.Single(feature => feature.GeometryType == "polygon"
            && feature.SelectionIDs.Contains(target.TableRowID));
        Check(target.MapFeatureIDs.Contains(polygon.ID, StringComparer.Ordinal)
            && target.MapFeatureIDs.Contains("region-control-point:" + controlPoint.FID, StringComparer.Ordinal),
            "The source completion message links to the exact completed polygon and source control-point marker");
        Check(File.ReadAllBytes(assetPath).SequenceEqual(originalSource),
            "Loading a real failed topology completes it in memory without writing the source HDF");

        GeometryTopologySnapshot fixedDraft = await Edit(model, loaded, "PatchType", "TrianglePaver");
        Check(RequireCompletion(fixedDraft).IsComplete
            && !RequireCompletion(fixedDraft).Messages.Any(message => message.Code == QuadPatchError)
            && fixedDraft.CanUndo && !fixedDraft.CanRedo,
            "A source-backed patch edit recomputes completion and starts the undo history");

        GeometryTopologySnapshot undone = await History(model, fixedDraft, "undo");
        GeometryTopologyCompletionResult undoneCompletion = RequireCompletion(undone);
        Check(!undoneCompletion.IsComplete && undoneCompletion.Messages.Any(message => message.Code == QuadPatchError)
            && !undone.CanUndo && undone.CanRedo,
            "Undo replays the saved baseline and restores its exact retained completion failure");
        Check(undone.DraftState.Contains("redoMutations", StringComparison.Ordinal)
            && undoneCompletion.DraftIdentity == DraftIdentity(undone.DraftState),
            "Undo returns redo history inside the opaque draft covered by the completion identity");

        GeometryTopologySnapshot redone = await History(model, undone, "redo");
        Check(RequireCompletion(redone).IsComplete && redone.CanUndo && !redone.CanRedo,
            "Redo reapplies the accepted source edit and refreshes completion and history state");

        GeometryTopologySnapshot branchBase = await History(model, redone, "undo");
        GeometryTopologySnapshot branched = await Edit(model, branchBase, "PatchType", "TrianglePaver");
        Check(RequireCompletion(branched).IsComplete && branched.CanUndo && !branched.CanRedo,
            "A new source edit after undo clears the stale redo branch");

        GeometryTopologySnapshot discarded = await ModelEditorAdapter.LoadGeometryTopologyAsync(new(model, loaded.Revision));
        Check(!discarded.CanUndo && !discarded.CanRedo && !discarded.IsDirty
            && !RequireCompletion(discarded).IsComplete
            && RequireCompletion(discarded).Messages.Any(message => message.Code == QuadPatchError),
            "Discarding an unsaved draft returns to the unchanged source completion result");
        Check(File.ReadAllBytes(assetPath).SequenceEqual(originalSource),
            "Load, edit, undo, redo and discard leave the source HDF byte-for-byte unchanged");
    }

    private static async Task CheckAutomaticRepairDraftReplay()
    {
        using var directory = new TemporaryDirectory();
        string projectPath = Path.Combine(directory.FullName, "Topology automatic repair.ras");
        Project project = Project.CreateNew(projectPath, UnitSystem.SI);
        Geometry geometry = project.AddNewGeometry("Triangle missing a control point");
        geometry.ConceptualMeshLayer.Topology = CreateTriangleWithoutControlPoint();
        string assetPath = geometry.Filename;
        project.Save();
        geometry.Save();
        geometry.Dispose();

        var model = new GeometryTopologyModelRequest(assetPath, "Geometry", projectPath);
        byte[] originalSource = File.ReadAllBytes(assetPath);
        GeometryTopologySnapshot repaired = await ModelEditorAdapter.LoadGeometryTopologyAsync(new(model));
        GeometryTopologyFeatureRow controlPoint = repaired.Regions.Rows.Single();
        GeometryTopologyMap repairMap = repaired.Map
            ?? throw new InvalidOperationException("The retained control-point repair omitted the source topology map.");
        GeometryTopologyMapFeature marker = repairMap.Features.Single(feature =>
            feature.ID == "region-control-point:" + controlPoint.FID.ToString(System.Globalization.CultureInfo.InvariantCulture));
        GeometryTopologyMapFeature polygon = repairMap.Features.Single(feature => feature.GeometryType == "polygon"
            && feature.SelectionIDs.Contains(controlPoint.ID, StringComparer.Ordinal));
        Check(repaired.IsDirty && controlPoint.X is not null && controlPoint.Y is not null
            && marker.FID == controlPoint.FID && marker.Paths.Single().Single() == new GeometryTopologyCoordinate(controlPoint.X.Value, controlPoint.Y.Value)
            && polygon.SelectionIDs.Contains(controlPoint.ID, StringComparer.Ordinal),
            "Retained completion silently adds the best real control point to the observable region table and its source polygon/marker map");
        Check(File.ReadAllBytes(assetPath).SequenceEqual(originalSource),
            "The retained automatic repair remains an in-memory dirty draft and does not write its HDF before save");

        GeometryTopologySnapshot edited = await Edit(model, repaired, "PatchType", "Quad");
        GeometryTopologySnapshot replayed = await History(model, edited, "undo");
        GeometryTopologyFeatureRow replayedControlPoint = replayed.Regions.Rows.Single();
        GeometryTopologyMap replayedMap = replayed.Map
            ?? throw new InvalidOperationException("Replaying the repaired topology omitted its source map.");
        GeometryTopologyMapFeature replayedMarker = replayedMap.Features.Single(feature => feature.ID == marker.ID);
        GeometryTopologyMapFeature replayedPolygon = replayedMap.Features.Single(feature => feature.ID == polygon.ID);
        Check(replayed.IsDirty && replayedControlPoint.ID == controlPoint.ID && replayedControlPoint.FID == controlPoint.FID
            && replayedControlPoint.X == controlPoint.X && replayedControlPoint.Y == controlPoint.Y
            && replayedControlPoint.Values.OrderBy(pair => pair.Key, StringComparer.Ordinal)
                .SequenceEqual(controlPoint.Values.OrderBy(pair => pair.Key, StringComparer.Ordinal))
            && replayedMarker.Paths.Single().Single() == marker.Paths.Single().Single()
            && replayedPolygon.SelectionIDs.SequenceEqual(polygon.SelectionIDs, StringComparer.Ordinal),
            "Replaying an edited then undone source draft repeats the silent repair with the same observable table row and map geometry");
        Check(File.ReadAllBytes(assetPath).SequenceEqual(originalSource),
            "Editing and undoing around the automatic repair still leave the source HDF unchanged before explicit save");

        GeometryTopologySnapshot saved = await ModelEditorAdapter.SaveGeometryTopologyAsync(
            new GeometryTopologySaveRequest(model, replayed.Revision, replayed.DraftState));
        Check(!saved.IsDirty && saved.Regions.Rows.Single().ID == controlPoint.ID
            && saved.Map?.Features.Any(feature => feature.ID == marker.ID) == true
            && !File.ReadAllBytes(assetPath).SequenceEqual(originalSource),
            "Explicit save persists the real automatic control-point repair and reloads it as a clean table/map snapshot");
    }

    private static Topology CreateTriangleWithQuadPatch()
    {
        Topology topology = new();
        topology.AddNode(0, 0, out _);
        topology.AddNode(20, 0, out _);
        topology.AddNode(10, 20, out _);
        topology.AddArc(0, 1);
        topology.AddArc(1, 2);
        topology.AddArc(2, 0);
        topology.AddRegionControlPoint(new Point(10, 5));
        var topologyResult = topology.Complete();
        if (!topologyResult)
            throw new InvalidOperationException("The temporary triangular topology did not complete: " + topologyResult.GetConcatenatedMessages());
        topology.EnsureMeshMetadataColumns();
        topology.SetControlPointData(0, PatchType.Quad, SizeFunction.Constant, 5f);
        return topology;
    }

    private static Topology CreateTriangleWithoutControlPoint()
    {
        Topology topology = new();
        topology.AddNode(0, 0, out _);
        topology.AddNode(20, 0, out _);
        topology.AddNode(10, 20, out _);
        topology.AddArc(0, 1);
        topology.AddArc(1, 2);
        topology.AddArc(2, 0);
        var topologyResult = topology.Complete();
        if (!topologyResult)
            throw new InvalidOperationException("The temporary triangular topology did not complete: " + topologyResult.GetConcatenatedMessages());
        topology.EnsureMeshMetadataColumns();
        return topology;
    }

    private static async Task<GeometryTopologySnapshot> Edit(GeometryTopologyModelRequest model,
        GeometryTopologySnapshot snapshot, string field, string value) =>
        await ModelEditorAdapter.EditGeometryTopologyAsync(new(model, snapshot.Revision, snapshot.DraftState,
            new("setField", "region", [0], field, value)));

    private static async Task<GeometryTopologySnapshot> History(GeometryTopologyModelRequest model,
        GeometryTopologySnapshot snapshot, string operation) =>
        await ModelEditorAdapter.EditGeometryTopologyAsync(new(model, snapshot.Revision, snapshot.DraftState,
            new(operation, "history", [])));

    private static GeometryTopologyCompletionResult RequireCompletion(GeometryTopologySnapshot snapshot) =>
        snapshot.Completion ?? throw new InvalidOperationException("The topology snapshot omitted retained completion data.");

    private static string DraftIdentity(string draftState) =>
        Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(draftState))).ToLowerInvariant();

    private static void CheckHeadlessProxyRejectsRenderingCalls()
    {
        IVectorManager manager = DispatchProxy.Create<IVectorManager, GeometryTopologyHeadlessVectorManagerProxy>();
        bool rejected = false;
        try { manager.TryDeleteVector(default); }
        catch (NotSupportedException) { rejected = true; }
        Check(rejected, "A headless completion context does not silently accept a rendering operation");
    }

    private static void Check(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }
}
