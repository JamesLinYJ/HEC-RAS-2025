using System.Globalization;
using Geospatial.Vectors;
using Geospatial.Vectors.Topology;
using Ras.Backend;
using Ras.Layers;
using Utility.Units;

internal static class GeometryTopologyChecks
{
    internal static async Task Run()
    {
        using var directory = new TemporaryDirectory();
        string projectPath = Path.Combine(directory.FullName, "Topology editor.ras");
        var project = Project.CreateNew(projectPath, UnitSystem.SI);
        var geometry = project.AddNewGeometry("Topology geometry");
        Topology topology = Topology.FromExtent(new Extent(0, 100, 0, 100));
        topology.AddNode(20, 20, out int lowerLeft);
        topology.AddNode(40, 20, out int lowerRight);
        topology.AddNode(40, 40, out int upperRight);
        topology.AddNode(20, 40, out int upperLeft);
        topology.AddArc(lowerLeft, lowerRight, [], out int holeSouth);
        topology.AddArc(lowerRight, upperRight, [], out int holeEast);
        topology.AddArc(upperRight, upperLeft, [], out int holeNorth);
        topology.AddArc(upperLeft, lowerLeft, [], out int holeWest);
        var innerRing = new RegionRing(4);
        innerRing.Arcs.Add(new ArcWithDirection(holeSouth, isForward: true));
        innerRing.Arcs.Add(new ArcWithDirection(holeEast, isForward: true));
        innerRing.Arcs.Add(new ArcWithDirection(holeNorth, isForward: true));
        innerRing.Arcs.Add(new ArcWithDirection(holeWest, isForward: true));
        topology.CompletedRegions.Single().AddInnerRing(innerRing);
        geometry.ConceptualMeshLayer.Topology = topology;
        string assetPath = geometry.Filename;
        project.Save();
        geometry.Save();
        geometry.Dispose();
        using (var writer = new H5Assist.H5Writer(assetPath))
            writer.WriteAttribute(Geometry.HDF5Group, "Unknown Topology Metadata", "Retain this attribute");

        var model = new GeometryTopologyModelRequest(assetPath, "Geometry", projectPath);
        byte[] original = File.ReadAllBytes(assetPath);
        var loaded = await ModelEditorAdapter.LoadGeometryTopologyAsync(new(model));
        Check(File.ReadAllBytes(assetPath).SequenceEqual(original),
            "Reading source map coordinates leaves the geometry HDF unchanged");
        Check(loaded.CanEdit && loaded.Arcs.Rows.Length == 8 && loaded.Regions.Rows.Length == 2 && loaded.Nodes.Rows.Length == 8,
            "Topology reader returns source arc, region and node identities");
        // The saved inner ring also bounds a real second region. Retained
        // completion adds its missing control point without replacing FID 0
        // or writing the original HDF; it is an unsaved source repair.
        GeometryTopologyFeatureRow repairedRegion = loaded.Regions.Rows.Single(row => row.FID == 1);
        Check(loaded.IsDirty && repairedRegion.ID == "region:1" && repairedRegion.X == 30 && repairedRegion.Y == 30
            && loaded.Completion?.IsComplete == true,
            "Retained completion creates the exact missing inner-region control point as an unsaved repair");
        GeometryTopologyMap map = loaded.Map ?? throw new InvalidOperationException("Topology reader omitted the source geometry map.");
        Check(map.Extent is { MinX: 0, MinY: 0, MaxX: 100, MaxY: 100 },
            "Topology map extent is derived from the actual geometry coordinates");
        var arcGeometry = map.Features.Single(feature => feature.ID == "arc:0");
        Check(arcGeometry.FID == loaded.Arcs.Rows.Single(row => row.FID == 0).FID
            && arcGeometry.GeometryType == "line" && arcGeometry.SelectionIDs.SequenceEqual(["arc:0"])
            && arcGeometry.Paths.Length == 1
            && arcGeometry.Paths[0].SequenceEqual([new GeometryTopologyCoordinate(0, 0), new GeometryTopologyCoordinate(0, 100)]),
            "Arc map paths keep the same source FID as the Arcs table");
        var regionGeometry = map.Features.Single(feature => feature.GeometryType == "polygon"
            && feature.SelectionIDs.SequenceEqual(["region:0"]));
        Check(regionGeometry.FID == 0 && regionGeometry.GeometryType == "polygon" && regionGeometry.Paths.Length == 2
            && regionGeometry.SelectionIDs.SequenceEqual(["region:0"]),
            "Completed-region rings preserve a real hole and link to the source control-point row identity");
        Check(regionGeometry.Paths[1].Any(point => point.X == 20 && point.Y == 20)
            && regionGeometry.Paths[1].Any(point => point.X == 40 && point.Y == 40),
            "Hole coordinates come from the saved inner-ring arcs");
        int[] tableNodeFids = loaded.Nodes.Rows.Select(row => row.FID).OrderBy(fid => fid).ToArray();
        GeometryTopologyMapFeature[] nodeFeatures = map.Features
            .Where(feature => feature.GeometryType == "point" && feature.FeatureKind == "node").ToArray();
        Check(nodeFeatures.Select(feature => feature.FID).OfType<int>().OrderBy(fid => fid).SequenceEqual(tableNodeFids)
            && nodeFeatures.All(feature => feature.SelectionIDs.SequenceEqual(["node:" + feature.FID]))
            && nodeFeatures.Length == 8,
            "Node map symbols preserve the source Node table FIDs and row-selection IDs");
        GeometryTopologyMapFeature controlPointFeature = map.Features.Single(feature => feature.ID == "region-control-point:0");
        Check(controlPointFeature.FID == loaded.Regions.Rows.Single(row => row.FID == 0).FID
            && controlPointFeature.Paths[0].Single() == new GeometryTopologyCoordinate(50, 50),
            "Region control-point map symbols preserve the source row FID and coordinates");

        var deleteArcOnly = await ModelEditorAdapter.EditGeometryTopologyAsync(new(model, loaded.Revision,
            loaded.DraftState, new("deleteSelection", "selection", []) { ArcFeatureIDs = [0] }));
        Check(deleteArcOnly.Arcs.Rows.Length < loaded.Arcs.Rows.Length
            && File.ReadAllBytes(assetPath).SequenceEqual(original),
            "Delete Selected resolves source arc FIDs to the retained edit stack without writing HDF");
        var deleteControlPointOnly = await ModelEditorAdapter.EditGeometryTopologyAsync(new(model, loaded.Revision,
            loaded.DraftState, new("deleteSelection", "selection", []) { ControlPointFeatureIDs = [1] }));
        Check(deleteControlPointOnly.Regions.Rows.Length < loaded.Regions.Rows.Length
            && File.ReadAllBytes(assetPath).SequenceEqual(original),
            "Delete Selected applies its control-point set through source region-boundary repair");
        var deleteNodeOnly = await ModelEditorAdapter.EditGeometryTopologyAsync(new(model, loaded.Revision,
            loaded.DraftState, new("deleteSelection", "selection", []) { NodeFeatureIDs = [0] }));
        Check(deleteNodeOnly.Nodes.Rows.Length < loaded.Nodes.Rows.Length
            && File.ReadAllBytes(assetPath).SequenceEqual(original),
            "Delete Selected applies its node set through the source multi-node delete operation");

        var mixedDelete = await ModelEditorAdapter.EditGeometryTopologyAsync(new(model, loaded.Revision,
            loaded.DraftState, new("deleteSelection", "selection", [])
            { ArcFeatureIDs = [0], ControlPointFeatureIDs = [1], NodeFeatureIDs = [0] }));
        Check(mixedDelete.IsDirty
            && mixedDelete.Arcs.Rows.Length < loaded.Arcs.Rows.Length
            && mixedDelete.Regions.Rows.Length < loaded.Regions.Rows.Length
            && mixedDelete.Nodes.Rows.Length < loaded.Nodes.Rows.Length
            && File.ReadAllBytes(assetPath).SequenceEqual(original),
            "Mixed Delete Selected keeps arc, control-point and node removal in one unsaved source draft");
        var mixedDeleteUndone = await ModelEditorAdapter.EditGeometryTopologyAsync(new(model, loaded.Revision,
            mixedDelete.DraftState, new("undo", "history", [])));
        Check(TopologyRowsIdentity(mixedDeleteUndone.Arcs.Rows) == TopologyRowsIdentity(loaded.Arcs.Rows)
            && TopologyRowsIdentity(mixedDeleteUndone.Regions.Rows) == TopologyRowsIdentity(loaded.Regions.Rows)
            && TopologyRowsIdentity(mixedDeleteUndone.Nodes.Rows) == TopologyRowsIdentity(loaded.Nodes.Rows),
            "Undo restores the exact source table rows after mixed selected-feature deletion");
        var mixedDeleteRedone = await ModelEditorAdapter.EditGeometryTopologyAsync(new(model, loaded.Revision,
            mixedDeleteUndone.DraftState, new("redo", "history", [])));
        Check(TopologyRowsIdentity(mixedDeleteRedone.Arcs.Rows) == TopologyRowsIdentity(mixedDelete.Arcs.Rows)
            && TopologyRowsIdentity(mixedDeleteRedone.Regions.Rows) == TopologyRowsIdentity(mixedDelete.Regions.Rows)
            && TopologyRowsIdentity(mixedDeleteRedone.Nodes.Rows) == TopologyRowsIdentity(mixedDelete.Nodes.Rows)
            && File.ReadAllBytes(assetPath).SequenceEqual(original),
            "Redo reapplies the same mixed source deletion while the geometry HDF remains untouched");
        await Expect<ArgumentException>(() => ModelEditorAdapter.EditGeometryTopologyAsync(new(model,
            loaded.Revision, loaded.DraftState, new("deleteSelection", "selection", []) { ArcFeatureIDs = [0, 0] })));
        Check(File.ReadAllBytes(assetPath).SequenceEqual(original),
            "Rejected duplicate Delete Selected FIDs leave the source geometry bytes unchanged");

        ExportFixtureIfRequested(directory.FullName);

        await CheckSelectedRegionForceCommandsAsync(directory.FullName);

        int[] resetFIDs = loaded.Regions.Rows.Select(row => row.FID).ToArray();
        Check(resetFIDs.Length == 2, "The reset regression fixture contains two source control points");
        var resetFirst = await ModelEditorAdapter.EditGeometryTopologyAsync(new(model, loaded.Revision, loaded.DraftState,
            new("setField", "region", [resetFIDs[0]], "ConstantSize", "16")));
        var resetMixed = await ModelEditorAdapter.EditGeometryTopologyAsync(new(model, loaded.Revision, resetFirst.DraftState,
            new("setField", "region", [resetFIDs[1]], "ConstantSize", "4")));
        Check(resetMixed.Regions.Rows.Select(row => row.Values["ConstantSize"]).Distinct(StringComparer.Ordinal).Count() == 2,
            "The source reset fixture starts with a true mixed ConstantSize selection");
        var resetApplied = await ModelEditorAdapter.EditGeometryTopologyAsync(new(model, loaded.Revision, resetMixed.DraftState,
            new("forceResetField", "region", resetFIDs, "ConstantSize")));
        Check(resetApplied.Regions.Rows.All(row => float.TryParse(row.Values["ConstantSize"], NumberStyles.Float,
                CultureInfo.InvariantCulture, out float value) && float.IsNaN(value)),
            "ForceResetConstantSize assigns NaN through each selected source control-point setter");
        Check(File.ReadAllBytes(assetPath).SequenceEqual(original),
            "A multi-selection ForceReset remains an unsaved topology draft and leaves the source HDF unchanged");
        var resetNoOp = await ModelEditorAdapter.EditGeometryTopologyAsync(new(model, loaded.Revision, resetApplied.DraftState,
            new("forceResetField", "region", resetFIDs, "ConstantSize")));
        Check(resetNoOp.DraftState == resetApplied.DraftState,
            "Resetting an already common NaN field does not append a duplicate mutation");
        await Expect<ArgumentException>(() => ModelEditorAdapter.EditGeometryTopologyAsync(new(model, loaded.Revision,
            resetMixed.DraftState, new("forceResetField", "region", resetFIDs, "PatchType"))));
        await Expect<ArgumentException>(() => ModelEditorAdapter.EditGeometryTopologyAsync(new(model, loaded.Revision,
            resetMixed.DraftState, new("forceResetField", "region", [resetFIDs[0], resetFIDs[0]], "ConstantSize"))));
        Check(File.ReadAllBytes(assetPath).SequenceEqual(original), "Rejected source reset commands do not mutate the HDF");

        var constantArc = await ModelEditorAdapter.EditGeometryTopologyAsync(new(model, loaded.Revision, loaded.DraftState,
            new("setField", "arc", [0], "SizeFunction", "Constant")));
        var pointsEdited = await ModelEditorAdapter.EditGeometryTopologyAsync(new(model, loaded.Revision, constantArc.DraftState,
            new("setField", "arc", [0], "PointCount", "17")));
        Check(pointsEdited.IsDirty && File.ReadAllBytes(assetPath).SequenceEqual(original),
            "Topology property edit remains a source-validated in-memory draft");
        var countArc = await ModelEditorAdapter.EditGeometryTopologyAsync(new(model, loaded.Revision, pointsEdited.DraftState,
            new("setField", "arc", [1], "SizeFunction", "CountWithBias")));
        var countConfigured = await ModelEditorAdapter.EditGeometryTopologyAsync(new(model, loaded.Revision, countArc.DraftState,
            new("setField", "arc", [1], "PointCount", "17")));
        var sizeConfigured = await ModelEditorAdapter.EditGeometryTopologyAsync(new(model, loaded.Revision, countConfigured.DraftState,
            new("setField", "arc", [0], "ConstantSize", "16")));
        var quickConstantArc = await ModelEditorAdapter.EditGeometryTopologyAsync(new(model, loaded.Revision, sizeConfigured.DraftState,
            new("halfSize", "arc", [0])));
        // Topology.FromExtent creates a Quad region. The scalar source quick-size
        // operation tested below belongs to TrianglePaver/Cartesian; Quad requires
        // an explicit NorthSouth or EastWest side axis.
        var triangleRegion = await ModelEditorAdapter.EditGeometryTopologyAsync(new(model, loaded.Revision, quickConstantArc.DraftState,
            new("setField", "region", [0], "PatchType", "TrianglePaver")));
        var regionPrimarySize = await ModelEditorAdapter.EditGeometryTopologyAsync(new(model, loaded.Revision, triangleRegion.DraftState,
            new("setField", "region", [0], "ConstantSize", "16")));
        var regionSizesConfigured = await ModelEditorAdapter.EditGeometryTopologyAsync(new(model, loaded.Revision, regionPrimarySize.DraftState,
            new("setField", "region", [0], "SecondaryConstantSize", "8")));
        var quickCountArc = await ModelEditorAdapter.EditGeometryTopologyAsync(new(model, loaded.Revision, regionSizesConfigured.DraftState,
            new("halfSize", "arc", [1])));
        var quickRegion = await ModelEditorAdapter.EditGeometryTopologyAsync(new(model, loaded.Revision, quickCountArc.DraftState,
            new("halfSize", "region", [0])));
        var unsetArc = await ModelEditorAdapter.EditGeometryTopologyAsync(new(model, loaded.Revision, quickRegion.DraftState,
            new("setField", "arc", [2], "SizeFunction", "Unset")));
        var unsetQuick = await ModelEditorAdapter.EditGeometryTopologyAsync(new(model, loaded.Revision, unsetArc.DraftState,
            new("halfSize", "arc", [2])));
        Check(unsetQuick.DraftState == unsetArc.DraftState,
            "The source quick-resize action for an Unset arc is a no-op and does not create a dirty edit");
        var tagCreated = await ModelEditorAdapter.EditGeometryTopologyAsync(new(model, loaded.Revision, unsetQuick.DraftState,
            new("createTag", "arc", [], TagName: "Edge Type", TagType: "String")));
        var tagAssigned = await ModelEditorAdapter.EditGeometryTopologyAsync(new(model, loaded.Revision, tagCreated.DraftState,
            new("setTag", "arc", [0, 1], TagName: "Edge Type", TagValue: "Boundary")));
        Check(tagAssigned.RecentArcTags.FirstOrDefault() is { Name: "Edge Type", Type: "String", Value: "Boundary" },
            "The tag editor retains the latest typed value for its recent-tag menu");
        Check(File.ReadAllBytes(assetPath).SequenceEqual(original), "Topology tag edits do not write the source before parent save");

        var ordinary = await ModelEditorAdapter.LoadAsync(new ModelRequest(assetPath, "Geometry", projectPath));
        string descriptionField = "GeometrySummaryPage/ViewModel_SelectedGeometryVisualContext_Context_Description";
        var saved = await ModelEditorAdapter.SaveAsync(new ModelSaveRequest(assetPath, "Geometry", projectPath, ordinary.Revision,
            new() { [descriptionField] = "Combined geometry and topology save" }, [], GeometryTopologyState: tagAssigned.DraftState));
        Check(saved.Revision != ordinary.Revision && saved.Fields[descriptionField] == "Combined geometry and topology save",
            "One parent model save commits ordinary geometry edits with its topology draft");

        var persisted = await ModelEditorAdapter.LoadGeometryTopologyAsync(new(model, saved.Revision));
        var ordinaryReopened = await ModelEditorAdapter.LoadAsync(new ModelRequest(assetPath, "Geometry", projectPath));
        Check(ordinaryReopened.Fields[descriptionField] == "Combined geometry and topology save",
            "Reopening the same HDF reads back the ordinary geometry description with the topology changes");
        Check(!persisted.IsDirty && persisted.Arcs.Rows.Single(row => row.FID == 0).Values["PointCount"] == "17",
            "Saved topology property is read back from HDF with a clean new revision");
        Check(persisted.Arcs.Rows.Single(row => row.FID == 0).Values["ConstantSize"] == "8",
            "Constant-size arc quick edit persists the source ConstantSize ratio");
        Check(persisted.Arcs.Rows.Single(row => row.FID == 1).Values["PointCount"] == "8",
            "Count-with-bias arc quick edit scales PointCount using the source integer ratio rule");
        var savedRegion = persisted.Regions.Rows.Single(row => row.FID == 0);
        Check(savedRegion.Values["PatchType"] == "TrianglePaver"
            && savedRegion.Values["ConstantSize"] == "8" && savedRegion.Values["SecondaryConstantSize"] == "4",
            "TrianglePaver quick edit scales both source cell-size values; Quad sizing uses a NorthSouth or EastWest side axis");
        Check(persisted.ArcTags.Any(tag => tag.ID == "Edge Type")
            && persisted.Arcs.Rows.Single(row => row.FID == 0).Values["Edge Type"] == "Boundary"
            && persisted.Arcs.Rows.Single(row => row.FID == 1).Values["Edge Type"] == "Boundary",
            "Typed metadata definition and assigned source tag values survive HDF roundtrip");
        byte[] savedBytes = File.ReadAllBytes(assetPath);
        using (var reader = new H5Assist.H5Reader(assetPath))
            Check(reader.TryReadStringAttributeScalar(Geometry.HDF5Group, "Unknown Topology Metadata") == "Retain this attribute",
                "Combined geometry and topology save retains unknown HDF attributes");

        await Expect<SourceFileChangedException>(() => ModelEditorAdapter.EditGeometryTopologyAsync(new(model,
            loaded.Revision, loaded.DraftState, new("setField", "arc", [0], "PointCount", "18"))));
        await Expect<ArgumentException>(() => ModelEditorAdapter.EditGeometryTopologyAsync(new(model,
            persisted.Revision, persisted.DraftState, new("setField", "arc", [0], "NotASourceProperty", "1"))));
        Check(File.ReadAllBytes(assetPath).SequenceEqual(savedBytes), "Rejected topology edits leave the persisted source intact");
        Console.WriteLine("Geometry topology source load, draft identity, tag/property/quick-size edits, combined save and HDF readback checks passed.");
    }

    private static async Task CheckSelectedRegionForceCommandsAsync(string fixtureRoot)
    {
        string projectDirectory = Path.Combine(fixtureRoot, "Selected region force commands");
        Directory.CreateDirectory(projectDirectory);
        string projectPath = Path.Combine(projectDirectory, "Selected region force commands.ras");
        var project = Project.CreateNew(projectPath, UnitSystem.SI);
        var geometry = project.AddNewGeometry("Selected region geometry");
        Topology topology = Topology.FromExtent(new Extent(0, 120, 0, 120));
        AddSquareInnerRing(topology, 20, 40);
        AddSquareInnerRing(topology, 70, 90);
        geometry.ConceptualMeshLayer.Topology = topology;
        string assetPath = geometry.Filename;
        project.Save();
        geometry.Save();
        geometry.Dispose();

        var model = new GeometryTopologyModelRequest(assetPath, "Geometry", projectPath);
        byte[] original = File.ReadAllBytes(assetPath);
        GeometryTopologySnapshot loaded = await ModelEditorAdapter.LoadGeometryTopologyAsync(new(model));
        GeometryTopologyFeatureRow[] orderedRegions = loaded.Regions.Rows.OrderBy(row => row.FID).ToArray();
        Check(orderedRegions.Length == 3,
            "The force-command fixture contains the outer region and both source regions bounded by inner rings");

        // Keep the outer region outside the selected set. The two inner regions
        // establish a real mixed PatchType selection before Force Set.
        GeometryTopologyFeatureRow[] selected = orderedRegions.Skip(1).Take(2).ToArray();
        GeometryTopologyFeatureRow outside = orderedRegions[0];
        int[] selectedFIDs = selected.Select(row => row.FID).ToArray();
        string outsidePatchType = outside.Values["PatchType"];
        string outsideConstantSize = outside.Values["ConstantSize"];
        GeometryTopologySnapshot mixed = loaded;
        mixed = await ModelEditorAdapter.EditGeometryTopologyAsync(new(model, loaded.Revision, mixed.DraftState,
            new("setField", "region", [selected[0].FID], "PatchType", "TrianglePaver")));
        mixed = await ModelEditorAdapter.EditGeometryTopologyAsync(new(model, loaded.Revision, mixed.DraftState,
            new("setField", "region", [selected[1].FID], "PatchType", "Quad")));
        Check(mixed.Regions.Rows.Single(row => row.FID == selected[0].FID).Values["PatchType"] == "TrianglePaver"
            && mixed.Regions.Rows.Single(row => row.FID == selected[1].FID).Values["PatchType"] == "Quad",
            "The selected inner source control points have distinct PatchType values before Force Set");

        GeometryTopologySnapshot forced = await ModelEditorAdapter.EditGeometryTopologyAsync(new(model,
            loaded.Revision, mixed.DraftState,
            new GeometryTopologyMutation("forceSetPatchType", "region", [], Value: "Cartesian")
            { ControlPointFeatureIDs = selectedFIDs }));
        Check(forced.IsDirty && forced.CanUndo
            && selectedFIDs.All(fid => forced.Regions.Rows.Single(row => row.FID == fid).Values["PatchType"] == "Cartesian"),
            "ForceSetPatchType assigns one source enum to the complete multi-row selection in the parent draft");
        Check(forced.Regions.Rows.Single(row => row.FID == outside.FID).Values["PatchType"] == outsidePatchType
            && forced.Regions.Rows.Single(row => row.FID == outside.FID).Values["ConstantSize"] == outsideConstantSize
            && File.ReadAllBytes(assetPath).SequenceEqual(original),
            "ForceSetPatchType leaves the unselected source control point and original HDF unchanged");

        GeometryTopologySnapshot forceUndone = await ModelEditorAdapter.EditGeometryTopologyAsync(new(model,
            loaded.Revision, forced.DraftState, new("undo", "history", [])));
        Check(forceUndone.Regions.Rows.Single(row => row.FID == selected[0].FID).Values["PatchType"] == "TrianglePaver"
            && forceUndone.Regions.Rows.Single(row => row.FID == selected[1].FID).Values["PatchType"] == "Quad"
            && forceUndone.Regions.Rows.Single(row => row.FID == outside.FID).Values["PatchType"] == outsidePatchType,
            "Undo restores both original selected PatchTypes without changing the outside region");
        GeometryTopologySnapshot forceRedone = await ModelEditorAdapter.EditGeometryTopologyAsync(new(model,
            loaded.Revision, forceUndone.DraftState, new("redo", "history", [])));
        Check(selectedFIDs.All(fid => forceRedone.Regions.Rows.Single(row => row.FID == fid).Values["PatchType"] == "Cartesian")
            && forceRedone.Regions.Rows.Single(row => row.FID == outside.FID).Values["PatchType"] == outsidePatchType,
            "Redo reapplies the same selected PatchType assignment and retains the outside source value");

        GeometryTopologySnapshot sized = await ModelEditorAdapter.EditGeometryTopologyAsync(new(model,
            loaded.Revision, forceRedone.DraftState,
            new("setField", "region", [selected[0].FID], "ConstantSize", "16")));
        sized = await ModelEditorAdapter.EditGeometryTopologyAsync(new(model, loaded.Revision, sized.DraftState,
            new("setField", "region", [selected[1].FID], "ConstantSize", "4")));
        Check(selectedFIDs.Select(fid => sized.Regions.Rows.Single(row => row.FID == fid).Values["ConstantSize"])
                .Distinct(StringComparer.Ordinal).Count() == 2,
            "The source region reset command receives deliberately mixed selected sizing values");

        GeometryTopologySnapshot reset = await ModelEditorAdapter.EditGeometryTopologyAsync(new(model,
            loaded.Revision, sized.DraftState, new("forceResetField", "region", selectedFIDs, "ConstantSize")));
        Check(selectedFIDs.All(fid => float.TryParse(reset.Regions.Rows.Single(row => row.FID == fid).Values["ConstantSize"],
                NumberStyles.Float, CultureInfo.InvariantCulture, out float value) && float.IsNaN(value)),
            "ForceResetRegionField stores the source NaN default on every selected control point");
        Check(reset.Regions.Rows.Single(row => row.FID == outside.FID).Values["PatchType"] == outsidePatchType
            && reset.Regions.Rows.Single(row => row.FID == outside.FID).Values["ConstantSize"] == outsideConstantSize
            && selectedFIDs.All(fid => reset.Regions.Rows.Single(row => row.FID == fid).Values["PatchType"] == "Cartesian")
            && File.ReadAllBytes(assetPath).SequenceEqual(original),
            "ForceResetRegionField changes only selected sizing values and leaves both source bytes and outside defaults untouched");

        GeometryTopologySnapshot resetUndone = await ModelEditorAdapter.EditGeometryTopologyAsync(new(model,
            loaded.Revision, reset.DraftState, new("undo", "history", [])));
        Check(resetUndone.Regions.Rows.Single(row => row.FID == selected[0].FID).Values["ConstantSize"] == "16"
            && resetUndone.Regions.Rows.Single(row => row.FID == selected[1].FID).Values["ConstantSize"] == "4"
            && resetUndone.Regions.Rows.Single(row => row.FID == outside.FID).Values["ConstantSize"] == outsideConstantSize,
            "Undo restores each selected region's independent pre-reset value while preserving the unselected region");
        GeometryTopologySnapshot resetRedone = await ModelEditorAdapter.EditGeometryTopologyAsync(new(model,
            loaded.Revision, resetUndone.DraftState, new("redo", "history", [])));

        ModelSnapshot parent = await ModelEditorAdapter.LoadAsync(new ModelRequest(assetPath, "Geometry", projectPath));
        Check(parent.Revision == loaded.Revision,
            "The ordinary parent editor and topology draft share the same captured source HDF revision");
        ModelSnapshot saved = await ModelEditorAdapter.SaveAsync(new ModelSaveRequest(assetPath, "Geometry", projectPath,
            parent.Revision, new(), new(), GeometryTopologyState: resetRedone.DraftState));
        Check(saved.Revision != loaded.Revision && !File.ReadAllBytes(assetPath).SequenceEqual(original),
            "The parent model save commits the topology command draft and advances the source HDF revision");
        GeometryTopologySnapshot reopened = await ModelEditorAdapter.LoadGeometryTopologyAsync(new(model, saved.Revision));
        Check(!reopened.IsDirty && reopened.Revision == saved.Revision
            && selectedFIDs.All(fid => reopened.Regions.Rows.Single(row => row.FID == fid).Values["PatchType"] == "Cartesian")
            && reopened.Regions.Rows.Single(row => row.FID == outside.FID).Values["PatchType"] == outsidePatchType,
            "Parent save and source reopen preserve the ForceSetPatchType selection and outside default");
        Check(selectedFIDs.All(fid => float.TryParse(reopened.Regions.Rows.Single(row => row.FID == fid).Values["ConstantSize"],
                NumberStyles.Float, CultureInfo.InvariantCulture, out float value) && float.IsNaN(value))
            && reopened.Regions.Rows.Single(row => row.FID == outside.FID).Values["ConstantSize"] == outsideConstantSize,
            "Parent save and source reopen preserve the selected NaN reset and unselected source sizing value");
    }

    private static void AddSquareInnerRing(Topology topology, double lower, double upper)
    {
        topology.AddNode(lower, lower, out int lowerLeft);
        topology.AddNode(upper, lower, out int lowerRight);
        topology.AddNode(upper, upper, out int upperRight);
        topology.AddNode(lower, upper, out int upperLeft);
        topology.AddArc(lowerLeft, lowerRight, [], out int south);
        topology.AddArc(lowerRight, upperRight, [], out int east);
        topology.AddArc(upperRight, upperLeft, [], out int north);
        topology.AddArc(upperLeft, lowerLeft, [], out int west);
        var ring = new RegionRing(4);
        ring.Arcs.Add(new ArcWithDirection(south, isForward: true));
        ring.Arcs.Add(new ArcWithDirection(east, isForward: true));
        ring.Arcs.Add(new ArcWithDirection(north, isForward: true));
        ring.Arcs.Add(new ArcWithDirection(west, isForward: true));
        topology.CompletedRegions.Single().AddInnerRing(ring);
    }

    private static void ExportFixtureIfRequested(string sourceDirectory)
    {
        string? fixture = Environment.GetEnvironmentVariable("HECRAS_TOPOLOGY_ACCEPTANCE_DIRECTORY");
        if (string.IsNullOrWhiteSpace(fixture)) return;
        string destination = Path.GetFullPath(fixture);
        if (Directory.Exists(destination) || File.Exists(destination))
            throw new IOException("The topology fixture destination already exists.");
        Directory.CreateDirectory(destination);
        foreach (string folder in Directory.EnumerateDirectories(sourceDirectory, "*", SearchOption.AllDirectories))
            Directory.CreateDirectory(Path.Combine(destination, Path.GetRelativePath(sourceDirectory, folder)));
        foreach (string file in Directory.EnumerateFiles(sourceDirectory, "*", SearchOption.AllDirectories))
            File.Copy(file, Path.Combine(destination, Path.GetRelativePath(sourceDirectory, file)));
    }

    private static string TopologyRowsIdentity(GeometryTopologyFeatureRow[] rows) => string.Join("\n", rows.Select(row =>
        string.Join("\u001f", row.ID, row.FID.ToString(CultureInfo.InvariantCulture),
            string.Join("\u001e", row.Values.OrderBy(pair => pair.Key, StringComparer.Ordinal)
                .Select(pair => pair.Key + "\u001d" + pair.Value)),
            row.X?.ToString("R", CultureInfo.InvariantCulture) ?? "",
            row.Y?.ToString("R", CultureInfo.InvariantCulture) ?? "",
            row.StartNodeID?.ToString(CultureInfo.InvariantCulture) ?? "",
            row.EndNodeID?.ToString(CultureInfo.InvariantCulture) ?? "")));

    private static void Check(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }

    private static async Task Expect<T>(Func<Task<GeometryTopologySnapshot>> action) where T : Exception
    {
        try { await action(); }
        catch (T) { return; }
        throw new InvalidOperationException("Expected " + typeof(T).Name);
    }
}
