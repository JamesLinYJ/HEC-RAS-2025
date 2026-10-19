using Geospatial.PairedData;
using Geospatial.Rasters.Modifiers;
using Geospatial.Vectors;
using OSGeo.GDAL;
using Ras.Backend;
using Ras.Layers;
using Ras.Layers.Terrains;
using Utility.Units;

internal static class TerrainTopologyChecks
{
    private const string SourceInputField = "TerrainLayersEditor/SelectedInputWithMap";
    private const string ChannelFeatureTable = "ChannelModEditor/Features";
    private const string LeveeFeatureTable = "LeveeModsTable";
    private const string LeveeProfileTable = "LeveeModDetailEditor/Profile";

    internal static async Task Run()
    {
        using var directory = new TemporaryDirectory();
        string projectPath = Path.Combine(directory.FullName, "terrain topology.ras");
        Project project = Project.CreateNew(projectPath, UnitSystem.SI);
        Terrain terrain = project.AddNewTerrain("Topology regression");
        terrain.Add(new ConstantTerrainInput(terrain, 10, new Extent(0, 20, 0, 20), "Base"));
        string rasterPath = Path.Combine(terrain.SourceDirectory, "saved raster.tif");
        using (var driver = Gdal.GetDriverByName("GTiff"))
        using (var raster = driver.Create(rasterPath, 16, 16, 1, DataType.GDT_Float32,
                   ["TILED=YES", "BLOCKXSIZE=16", "BLOCKYSIZE=16"]))
        {
            raster.SetGeoTransform([0, 1, 0, 16, 0, -1]);
            using var band = raster.GetRasterBand(1);
            band.Fill(42, 0);
        }
        terrain.Add(RasterTerrainInput.CreateAndScan(terrain, rasterPath));

        Polyline channelLine = new(new[] { new Point(2, 10), new Point(18, 10) });
        ChannelModTerrainInput channel = new(terrain, "Channel topology");
        channel.Add(new ChannelProfile(channelLine, new StationElevationProfile([0, 16], [9, 8])) { Name = "Channel feature" });
        terrain.Add(channel);

        LeveeModTerrainInput levee = new(terrain, "Levee profile sort");
        levee.PropertiesTable.Add(new LeveeModProperties { Name = "Default" });
        levee.Add(new LeveeMod(new Polyline(new[] { new Point(2, 4), new Point(18, 4) }),
            new StationElevationProfile([12, 0, 6], [3, 1, 2]))
        { Name = "Levee feature", LeveePropertyName = "Default" });
        terrain.Add(levee);

        project.Save();
        terrain.Save();
        string assetPath = terrain.Filename;
        terrain.Dispose();

        ModelSnapshot snapshot = await ModelEditorAdapter.LoadAsync(new(assetPath, "Terrain", projectPath));
        TerrainInputData overviewInput = snapshot.Terrain!.Inputs.Single(input => input.Type == "Raster");
        Check(overviewInput.OverviewCount == 1 && overviewInput.Overviews is ["16 × 16"],
            "The saved raster metadata reports the source pyramid list including its native-resolution level.");
        string channelID = snapshot.Terrain!.Inputs.Single(input => input.Type == "Channel").Id;
        TerrainTopologyResponse empty = await Topology(snapshot, assetPath, projectPath, channelID, "load");
        Check(empty.Topology.Features.All(feature => feature.Kind != "arc"),
            "An empty source graph loads without manufacturing a line feature.");

        TerrainMapCoordinate[] points = [new(3, 6), new(8, 8), new(13, 6)];
        TerrainTopologyResponse drawn = await Topology(empty.Snapshot, assetPath, projectPath, channelID,
            "draw", points: points, mapCellSize: 0.25);
        TerrainTopologyFeature arc = drawn.Topology.Features.Single(feature => feature.Kind == "arc");
        Check(arc.Points.Length >= 2 && drawn.Topology.CanUndo && !drawn.Topology.CanRedo,
            "Draw applies an actual source graph arc and adds a parent-draft undo command.");

        TerrainTopologyResponse selected = await Topology(drawn.Snapshot, assetPath, projectPath, channelID,
            "select", featureIDs: [arc.Id]);
        Check(selected.Topology.SelectedFeatureIDs.SequenceEqual([arc.Id])
            && selected.Snapshot.SourceState == drawn.Snapshot.SourceState,
            "Graph selection is returned for the exact stable feature without entering persistent source draft state.");

        TerrainTopologyResponse reloaded = await Topology(selected.Snapshot, assetPath, projectPath, channelID, "load");
        Check(reloaded.Topology.Features.Any(feature => feature.Id == arc.Id)
            && reloaded.Topology.CanUndo,
            "A later request reconstructs the topology graph and command history from the parent draft.");

        TerrainTopologyResponse undone = await Topology(reloaded.Snapshot, assetPath, projectPath, channelID, "undo");
        TerrainTopologyResponse afterUndo = await Topology(undone.Snapshot, assetPath, projectPath, channelID, "load");
        Check(afterUndo.Topology.Features.All(feature => feature.Kind != "arc") && afterUndo.Topology.CanRedo,
            "Undo removes the prior source draw across RPC reconstruction and retains its redo command.");

        TerrainTopologyResponse redone = await Topology(afterUndo.Snapshot, assetPath, projectPath, channelID, "redo");
        TerrainTopologyResponse afterRedo = await Topology(redone.Snapshot, assetPath, projectPath, channelID, "load");
        TerrainTopologyFeature restoredArc = afterRedo.Topology.Features.Single(feature => feature.Kind == "arc");
        TerrainTopologyResponse removed = await Topology(afterRedo.Snapshot, assetPath, projectPath, channelID,
            "remove", featureIDs: [restoredArc.Id], mapCellSize: 0.25);
        TerrainTopologyResponse afterRemove = await Topology(removed.Snapshot, assetPath, projectPath, channelID, "load");
        Check(afterRemove.Topology.Features.All(feature => feature.Kind != "arc") && afterRemove.Topology.CanUndo,
            "Remove uses the retained topology selection operation and is replayable in the parent draft.");

        TerrainTopologyResponse undoRemove = await Topology(afterRemove.Snapshot, assetPath, projectPath, channelID, "undo");
        TerrainTopologyResponse beforeSave = await Topology(undoRemove.Snapshot, assetPath, projectPath, channelID, "load");
        Check(beforeSave.Topology.Features.Any(feature => feature.Kind == "arc"),
            "Undo of remove restores the graph arc from the source baseline plus retained command history.");

        await CheckTopologyCommandsAcrossRequests(beforeSave.Snapshot, assetPath, projectPath, channelID);
        CheckNestedRegionPayload();

        snapshot = await ModelEditorAdapter.SaveAsync(Request(beforeSave.Snapshot, assetPath, projectPath, channelID));
        using (Terrain reopened = new(assetPath))
            Check(reopened.Layers.OfType<ChannelModTerrainInput>().Single().Topology.ArcCount == 1,
                "The ordinary terrain parent save persists the edited Topology group to HDF.");

        channelID = snapshot.Terrain!.Inputs.Single(input => input.Type == "Channel").Id;
        Check(snapshot.Terrain!.SelectedId == channelID
            && snapshot.Terrain.Rows!.TryGetValue(ChannelFeatureTable, out ModelRow[]? savedChannelRows)
            && savedChannelRows is { Length: 1 }
            && snapshot.Terrain!.Tables!.ContainsKey(ChannelFeatureTable),
            "The ordinary parent-save snapshot restores the selected channel input with its real feature table.");
        string channelRowID = snapshot.Terrain.Rows![ChannelFeatureTable].Single().Id;
        TerrainMapData channelMap = await ModelEditorAdapter.TerrainMapAsync(new(Request(snapshot, assetPath, projectPath,
            channelID, new() { [ChannelFeatureTable] = [channelRowID] }), channelID));
        Check(channelMap.Features is { Length: 1 } && channelMap.Features[0].Id == channelRowID
            && channelMap.Features[0].Points.Length == 2,
            "The source channel line returned to the terrain map keeps the exact table-row identity and coordinates.");

        string leveeID = snapshot.Terrain.Inputs.Single(input => input.Type == "Levee").Id;
        snapshot = await SelectInput(snapshot, assetPath, projectPath, leveeID);
        Check(snapshot.Terrain!.SelectedId == leveeID
            && snapshot.Terrain.Rows!.ContainsKey(LeveeFeatureTable)
            && !snapshot.Terrain.Rows!.ContainsKey(ChannelFeatureTable)
            && snapshot.Terrain!.Tables!.ContainsKey(LeveeFeatureTable)
            && !snapshot.Terrain!.Tables!.ContainsKey(ChannelFeatureTable),
            "The real terrain input-selection action exposes only the newly selected Levee tables.");
        string leveeRowID = snapshot.Terrain.Rows![LeveeFeatureTable].Single().Id;
        TerrainTopologyResponse sorted = await Topology(snapshot, assetPath, projectPath, leveeID,
            "sortProfile", featureIDs: [leveeRowID], tableSelections: new() { [LeveeFeatureTable] = [leveeRowID] });
        double[] stations = sorted.Snapshot.Terrain!.Rows![LeveeProfileTable]
            .Select(row => double.Parse(row.Values["Station"], System.Globalization.CultureInfo.InvariantCulture)).ToArray();
        double[] elevations = sorted.Snapshot.Terrain.Rows[LeveeProfileTable]
            .Select(row => double.Parse(row.Values["Elevation"], System.Globalization.CultureInfo.InvariantCulture)).ToArray();
        Check(stations.SequenceEqual([0, 6, 12]) && elevations.SequenceEqual([1, 2, 3])
            && sorted.Topology.SelectedFeatureIDs.SequenceEqual([leveeRowID]),
            "Sort Stations delegates to the selected source Levee profile, keeps each elevation paired with its station, and returns the same feature identity.");

        snapshot = await ModelEditorAdapter.SaveAsync(Request(sorted.Snapshot, assetPath, projectPath, leveeID,
            new() { [LeveeFeatureTable] = [leveeRowID] }));
        using (Terrain reopened = new(assetPath))
        {
            StationElevationProfile savedProfile = reopened.Layers.OfType<LeveeModTerrainInput>().Single().Features.Single().Profile;
            Check(savedProfile.Stations.SequenceEqual([0, 6, 12]) && savedProfile.Elevations.SequenceEqual([1, 2, 3]),
                "The sorted source Levee station/elevation pairs persist through the ordinary parent HDF save.");
        }

        string leveeIDAfterSave = snapshot.Terrain!.Inputs.Single(input => input.Type == "Levee").Id;
        Check(snapshot.Terrain!.SelectedId == leveeIDAfterSave
            && snapshot.Terrain.Rows!.ContainsKey(LeveeFeatureTable)
            && !snapshot.Terrain.Rows!.ContainsKey(ChannelFeatureTable)
            && snapshot.Terrain!.Tables!.ContainsKey(LeveeFeatureTable)
            && !snapshot.Terrain!.Tables!.ContainsKey(ChannelFeatureTable),
            "The ordinary parent-save snapshot restores the selected Levee input with its real feature table.");
        string leveeFeatureAfterSave = snapshot.Terrain.Rows![LeveeFeatureTable].Single().Id;
        TerrainMapData leveeMap = await ModelEditorAdapter.TerrainMapAsync(new(Request(snapshot, assetPath, projectPath,
            leveeIDAfterSave, new() { [LeveeFeatureTable] = [leveeFeatureAfterSave] }), leveeIDAfterSave));
        Check(leveeMap.Features is { Length: 1 } && leveeMap.Features[0].Id == leveeFeatureAfterSave
            && leveeMap.Features[0].Points.Length == 2,
            "The source Levee line returned to the terrain map keeps the exact selected feature identity.");

        Console.WriteLine("Terrain source topology draw/select/remove/undo/redo replay, parent-HDF persistence, exact channel/levee map identities, and source Levee station sorting checks passed.");
    }

    private static async Task CheckTopologyCommandsAcrossRequests(ModelSnapshot snapshot, string asset,
        string projectPath, string inputID)
    {
        TerrainTopologyResponse baseline = await Topology(snapshot, asset, projectPath, inputID, "load");
        TerrainTopologyFeature arc = baseline.Topology.Features.Single(feature => feature.Kind == "arc");
        Check(arc.Points.Length >= 3, "The fixture arc retains an internal source vertex.");
        int arcCount = baseline.Topology.Features.Count(feature => feature.Kind == "arc");

        TerrainMapCoordinate first = arc.Points[0];
        TerrainMapCoordinate second = arc.Points[1];
        var midpoint = new TerrainMapCoordinate((first.X + second.X) / 2, (first.Y + second.Y) / 2);
        TerrainTopologyResponse inserted = await Topology(baseline.Snapshot, asset, projectPath, inputID,
            "insertVertex", featureIDs: [arc.Id], points: [midpoint], mapCellSize: 0.25);
        string insertedVertexID = inserted.Topology.SelectedFeatureIDs.Single();
        TerrainTopologyFeature vertex = inserted.Topology.Features.Single(feature => feature.Id == insertedVertexID);
        Check(inserted.Topology.SelectedFeatureIDs.SequenceEqual([vertex.Id]),
            "Insert Vertex returns the source internal-vertex identity for synchronized selection.");

        await Reject(() => ModelEditorAdapter.TerrainTopologyAsync(new(
            Request(inserted.Snapshot, asset, projectPath, inputID), inputID, "select", [arc.Id], [], null,
            baseline.Topology.DraftIdentity)));

        TerrainTopologyResponse afterInsert = await Topology(inserted.Snapshot, asset, projectPath, inputID, "load");
        TerrainTopologyFeature insertedArc = afterInsert.Topology.Features.Single(feature => feature.Id == arc.Id);
        Check(insertedArc.Points.Length == arc.Points.Length + 1,
            "The next request replays the inserted source vertex from the parent terrain draft.");
        TerrainMapCoordinate movedPoint = vertex.Points[0] with { Y = vertex.Points[0].Y + 0.5 };
        TerrainTopologyResponse moved = await Topology(afterInsert.Snapshot, asset, projectPath, inputID,
            "moveVertex", featureIDs: [arc.Id], points: [vertex.Points[0], movedPoint],
            mapCellSize: 0.25, vertexIndex: vertex.VertexIndex);
        TerrainTopologyResponse afterMove = await Topology(moved.Snapshot, asset, projectPath, inputID, "load");
        Check(afterMove.Topology.Features.Single(feature => feature.Id == arc.Id).Points
                .Any(point => point.X == movedPoint.X && point.Y == movedPoint.Y),
            "Move Vertex changes the actual source polyline across request reconstruction.");
        TerrainTopologyResponse undoMove = await Topology(afterMove.Snapshot, asset, projectPath, inputID, "undo");
        TerrainTopologyResponse afterUndoMove = await Topology(undoMove.Snapshot, asset, projectPath, inputID, "load");
        Check(afterUndoMove.Topology.Features.Single(feature => feature.Id == arc.Id).Points.SequenceEqual(insertedArc.Points),
            "Undo restores the exact internal source vertex after a move.");

        TerrainTopologyResponse deleted = await Topology(afterUndoMove.Snapshot, asset, projectPath, inputID,
            "deleteVertex", featureIDs: [arc.Id], vertexIndex: vertex.VertexIndex);
        TerrainTopologyResponse afterDelete = await Topology(deleted.Snapshot, asset, projectPath, inputID, "load");
        Check(afterDelete.Topology.Features.Single(feature => feature.Id == arc.Id).Points.Length == arc.Points.Length,
            "Delete Vertex removes the requested internal point from the source graph.");
        TerrainTopologyResponse undoDelete = await Topology(afterDelete.Snapshot, asset, projectPath, inputID, "undo");
        TerrainTopologyResponse graph = await Topology(undoDelete.Snapshot, asset, projectPath, inputID, "load");
        Check(graph.Topology.Features.Single(feature => feature.Id == arc.Id).Points.SequenceEqual(insertedArc.Points),
            "Undo restores the deleted internal source vertex and its coordinate.");

        foreach (string mode in new[] { "AtVertex", "Anywhere" })
        {
            TerrainTopologyFeature currentArc = graph.Topology.Features.Single(feature => feature.Id == arc.Id);
            TerrainMapCoordinate splitPoint = mode == "AtVertex"
                ? currentArc.Points[1]
                : new((currentArc.Points[0].X + currentArc.Points[1].X) / 2,
                      (currentArc.Points[0].Y + currentArc.Points[1].Y) / 2);
            TerrainTopologyResponse split = await Topology(graph.Snapshot, asset, projectPath, inputID,
                "split", featureIDs: [arc.Id], points: [splitPoint], mapCellSize: 0.01, splitMode: mode);
            TerrainTopologyResponse afterSplit = await Topology(split.Snapshot, asset, projectPath, inputID, "load");
            Check(afterSplit.Topology.Features.Count(feature => feature.Kind == "arc") > arcCount,
                $"The source {mode} split produces graph fragments across RPC requests.");
            TerrainTopologyResponse undoSplit = await Topology(afterSplit.Snapshot, asset, projectPath, inputID, "undo");
            graph = await Topology(undoSplit.Snapshot, asset, projectPath, inputID, "load");
            Check(graph.Topology.Features.Count(feature => feature.Kind == "arc") == arcCount,
                $"Undo restores the source arc after a {mode} split.");
        }

        TerrainTopologyFeature node = graph.Topology.Features.First(feature => feature.Kind == "node");
        TerrainMapCoordinate origin = node.Points[0];
        var destination = origin with { X = origin.X + 1, Y = origin.Y + 1 };
        TerrainTopologyResponse movedNode = await Topology(graph.Snapshot, asset, projectPath, inputID,
            "moveNodes", featureIDs: [node.Id], points: [origin, destination], mapCellSize: 0.25);
        TerrainTopologyResponse afterNodeMove = await Topology(movedNode.Snapshot, asset, projectPath, inputID, "load");
        Check(afterNodeMove.Topology.Features.Any(feature => feature.Kind == "node"
                && feature.Points[0].X == destination.X && feature.Points[0].Y == destination.Y),
            "Move Node writes the source graph node into the cross-request terrain draft.");
        TerrainTopologyResponse undoNodeMove = await Topology(afterNodeMove.Snapshot, asset, projectPath, inputID, "undo");
        graph = await Topology(undoNodeMove.Snapshot, asset, projectPath, inputID, "load");
        Check(graph.Topology.Features.Any(feature => feature.Id == node.Id
                && feature.Points[0].X == origin.X && feature.Points[0].Y == origin.Y),
            "Undo restores the original node coordinate.");

        TerrainTopologyResponse secondArc = await Topology(graph.Snapshot, asset, projectPath, inputID,
            "draw", points: [new(2, 2), new(5, 3)], mapCellSize: 0.25);
        TerrainTopologyResponse beforeMerge = await Topology(secondArc.Snapshot, asset, projectPath, inputID, "load");
        TerrainTopologyFeature movingNode = beforeMerge.Topology.Features.Single(feature => feature.Kind == "node"
            && feature.Points[0].X == 2 && feature.Points[0].Y == 2);
        TerrainTopologyFeature targetNode = beforeMerge.Topology.Features.Single(feature => feature.Kind == "node"
            && feature.Points[0].X == origin.X && feature.Points[0].Y == origin.Y);
        int nodeCount = beforeMerge.Topology.Features.Count(feature => feature.Kind == "node");
        TerrainTopologyResponse merged = await Topology(beforeMerge.Snapshot, asset, projectPath, inputID,
            "moveNodes", featureIDs: [movingNode.Id], points: [movingNode.Points[0], targetNode.Points[0]], mapCellSize: 0.25);
        TerrainTopologyResponse afterMerge = await Topology(merged.Snapshot, asset, projectPath, inputID, "load");
        Check(afterMerge.Topology.Features.Count(feature => feature.Kind == "node") == nodeCount - 1,
            "Moving a source node onto another invokes the retained node-merge operation.");
        TerrainTopologyResponse undoMerge = await Topology(afterMerge.Snapshot, asset, projectPath, inputID, "undo");
        TerrainTopologyResponse afterUndoMerge = await Topology(undoMerge.Snapshot, asset, projectPath, inputID, "load");
        Check(afterUndoMerge.Topology.Features.Count(feature => feature.Kind == "node") == nodeCount,
            "Undo restores the deleted source node and graph connections after merge.");
        TerrainTopologyResponse undoSecondArc = await Topology(afterUndoMerge.Snapshot, asset, projectPath, inputID, "undo");
        graph = await Topology(undoSecondArc.Snapshot, asset, projectPath, inputID, "load");
        Check(graph.Topology.Features.Count(feature => feature.Kind == "arc") == arcCount,
            "Undo of the added arc returns the topology to its saved baseline.");
    }

    private static void CheckNestedRegionPayload()
    {
        using var directory = new TemporaryDirectory();
        Project project = Project.CreateNew(Path.Combine(directory.FullName, "nested topology.ras"), UnitSystem.SI);
        Terrain terrain = project.AddNewTerrain("Nested topology");
        Geospatial.Vectors.Topology.Topology topology = Geospatial.Vectors.Topology.Topology.FromExtent(new Extent(0, 20, 0, 20));
        topology.AddNode(7, 7, out int a); topology.AddNode(13, 7, out int b);
        topology.AddNode(13, 13, out int c); topology.AddNode(7, 13, out int d);
        topology.AddArc(a, b); topology.AddArc(b, c); topology.AddArc(c, d); topology.AddArc(d, a);
        topology.UpdateControlPointPoint(0, new Point(2, 2));
        if (!topology.Complete(forceRecomplete: true))
            throw new InvalidOperationException("The nested topology source fixture could not be completed.");
        ChannelMod.EnsureTopologyColumns(topology);
        var channel = new ChannelModTerrainInput(terrain, "Nested region source");
        channel.TopologyLayer.Topology = topology;
        var session = new TerrainTopologyEditSession("nested-region-input", channel);
        session.Initialize();

        TerrainTopologyFeature donut = session.Features().Single(feature => feature.Kind == "region"
            && feature.Rings is { Length: >= 2 });
        int regionFID = int.Parse(donut.Id.Split(':')[^1], System.Globalization.CultureInfo.InvariantCulture);
        Check(donut.Rings!.Length == channel.Topology.GetRegionComplexPolygon(regionFID).Rings.Count,
            "The topology response retains each source outer/inner ring for even-odd fill and hit testing.");
        var holePoint = new Point(10, 10);
        Check(!channel.Topology.RegionContainsPoint(regionFID, holePoint),
            "The source region containment excludes points inside its inner ring.");
        bool holeHit = channel.Topology.HitTestRegion(holePoint, out _, out int hitRegion);
        Check(!holeHit || hitRegion != regionFID,
            "The source region hit test never selects the donut region through its hole.");
        Check(donut.ControlPointIndex != null, "The nested-region fixture has an editable source mask control point.");
        bool previousMask = ChannelMod.GetRegionIsMask(channel.Topology, regionFID);
        var maskMutation = new TerrainTopologyMutation("maskRegion", [donut.Id]);
        Check(session.Apply(maskMutation, out string? selectedRegion) && selectedRegion == donut.Id
            && ChannelMod.GetRegionIsMask(channel.Topology, regionFID) != previousMask,
            "Mask Region toggles the exact selected source region and returns its stable identity.");
        Check(session.Apply(maskMutation, out _)
            && ChannelMod.GetRegionIsMask(channel.Topology, regionFID) == previousMask,
            "Applying the inverse source mask toggle restores the original region state.");
    }

    private static async Task Reject(Func<Task> action)
    {
        try { await action(); }
        catch (ArgumentException) { return; }
        throw new InvalidOperationException("A stale topology draft identity was accepted.");
    }

    private static async Task<TerrainTopologyResponse> Topology(ModelSnapshot snapshot, string asset, string projectPath,
        string inputID, string operation, string[]? featureIDs = null, TerrainMapCoordinate[]? points = null,
        double? mapCellSize = null, Dictionary<string, string[]>? tableSelections = null,
        string? splitMode = null, int? vertexIndex = null, string? metadataKind = null,
        string? metadataColumn = null, string? metadataValue = null)
    {
        string? expectedDraftIdentity = null;
        if (operation is not ("load" or "sortProfile"))
        {
            TerrainTopologyResponse loaded = await ModelEditorAdapter.TerrainTopologyAsync(new(
                Request(snapshot, asset, projectPath, inputID, tableSelections), inputID, "load"));
            snapshot = loaded.Snapshot;
            expectedDraftIdentity = loaded.Topology.DraftIdentity;
        }
        return await ModelEditorAdapter.TerrainTopologyAsync(new(
            Request(snapshot, asset, projectPath, inputID, tableSelections), inputID, operation,
            featureIDs ?? [], points ?? [], mapCellSize, expectedDraftIdentity, splitMode,
            vertexIndex, metadataKind, metadataColumn, metadataValue));
    }

    private static Task<ModelSnapshot> SelectInput(ModelSnapshot snapshot, string asset, string projectPath,
        string inputID)
    {
        string currentInputID = snapshot.Terrain?.SelectedId
            ?? throw new InvalidOperationException("Selecting a terrain input requires the current selected input identity.");
        return ModelEditorAdapter.TransformTerrainAsync(new(
            Request(snapshot, asset, projectPath, currentInputID), "selectInput", ItemId: inputID));
    }

    private static ModelSaveRequest Request(ModelSnapshot snapshot, string asset, string projectPath, string inputID,
        Dictionary<string, string[]>? tableSelections = null) => new(asset, "Terrain", projectPath, snapshot.Revision,
        new(StringComparer.Ordinal) { [SourceInputField] = inputID }, new Dictionary<string, ImageData[]>(),
        SourceState: snapshot.SourceState, Rows: snapshot.Terrain?.Rows, TableSelections: tableSelections);

    private static void Check(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }
}
