using System.Globalization;
using System.Xml.Linq;
using Geospatial;
using Geospatial.Vectors;
using OSGeo.GDAL;
using Ras.Backend;
using Ras.Hydraulics.Culverts;
using Ras.Layers;
using Ras.Layers.Terrains;
using Utility.Units;

internal static class GeometryCulvertChecks
{
    internal static async Task Run()
    {
        using var temporary = new TemporaryDirectory();
        string projectPath = Path.Combine(temporary.FullName, "Culvert source.ras");
        string rasterA = CreateRaster(Path.Combine(temporary.FullName, "terrain-a.tif"), 42);
        string rasterB = CreateRaster(Path.Combine(temporary.FullName, "terrain-b.tif"), 84);
        Project project = Project.CreateNew(projectPath, UnitSystem.SI);
        Terrain terrainA = project.AddNewTerrain("Culvert Terrain A");
        terrainA.Add(RasterTerrainInput.CreateAndScan(terrainA, rasterA));
        Terrain terrainB = project.AddNewTerrain("Culvert Terrain B");
        terrainB.Add(RasterTerrainInput.CreateAndScan(terrainB, rasterB));
        Geometry geometry = project.AddNewGeometry("Culvert geometry", terrainA, null!);
        geometry.BarrelPropertiesLayer.Add(new BarrelProperties
        {
            Name = "Round barrel", Rise = 1.2, Span = 1.2, Shape = BarrelShape.Circle, Mannings = .025,
            ManningsSwitchDepth = .1, DepthBlocked = 0
        });
        geometry.OpeningPropertiesLayer.Add(new OpeningProperties
        {
            Name = "Square edge", KIn = .5, KOut = .8,
            OpeningType = BarrelOpeningType.ConcretePipeCulvert_SquareEdgeWithHeadwall
        });
        Polyline sourceBarrelLine = new(new Point[] { new Point(1, 1), new Point(15, 1) });
        sourceBarrelLine.TrackZ(new double[] { 2.5, 3.5 });
        sourceBarrelLine.TrackM(new double[] { 10, 24 });
        geometry.CulvertBarrelLayer.Add(new CulvertBarrel
        {
            Name = "North barrel", Polyline = sourceBarrelLine,
            BarrelPropertyName = "Round barrel", UpstreamInvert = 40, DownstreamInvert = 39,
            UpstreamOpeningName = "Square edge", DownstreamOpeningName = ""
        });
        geometry.Save(); terrainA.Save(); terrainB.Save(); project.Save();
        string assetPath = geometry.Filename;
        geometry.Dispose(); terrainA.Dispose(); terrainB.Dispose();

        string projectXml = File.ReadAllText(projectPath);
        var model = new GeometryCulvertModelRequest(assetPath, "Geometry", projectPath, projectXml);
        byte[] sourceHdf = File.ReadAllBytes(assetPath), sourceProject = File.ReadAllBytes(projectPath);
        byte[] rasterABytes = File.ReadAllBytes(rasterA), rasterBBytes = File.ReadAllBytes(rasterB);

        GeometryCulvertSnapshot loaded = await ModelEditorAdapter.LoadGeometryCulvertsAsync(
            new(model, SelectedBarrelIDs: ["barrel:source:0"]));
        Check(loaded.CanEdit && loaded.Barrels.Rows.Length == 1
            && loaded.BarrelProperties.Rows.Single().Values["Shape"] == "Circle"
            && loaded.OpeningProperties.Rows.Single().Values["KIn"] == "0.5",
            "Culvert tables expose the real geometry barrel and both source property-set tables");
        Check(!loaded.BarrelProperties.EditableFields.Single(field => field.ID == "Shape").Choices.Contains("Custom", StringComparer.Ordinal)
            && !loaded.OpeningProperties.EditableFields.Single(field => field.ID == "OpeningType").Choices.Contains("Custom", StringComparer.Ordinal)
            && !loaded.OpeningProperties.EditableFields.Single(field => field.ID == "OpeningType").Choices.Contains("None", StringComparer.Ordinal),
            "Enum choices match the source editor's unsupported custom and none exclusions");
        Check(loaded.AssociatedTerrainName == "Culvert Terrain A" && loaded.Profiles.Single().Samples.Length > 1
            && loaded.Profiles.Single().Samples.All(sample => Math.Abs(sample.Elevation - 42) < 1e-4),
            "Selected source polyline profile samples actual values from its associated terrain raster");
        Check(loaded.AssociatedTerrainExtent is { MaxX: > 0, MaxY: > 0 },
            "The map receives the actual valid extent of the geometry's associated terrain");
        Check(loaded.Barrels.Rows.Single().Polyline is [{ Z: "2.5", M: "10" }, { Z: "3.5", M: "24" }],
            "Culvert barrel snapshots retain source Z and M dimensions without flattening them to XY");
        GeometryCulvertTerrainPreview terrainPreview = await ModelEditorAdapter.LoadGeometryCulvertTerrainPreviewAsync(
            new(model, loaded.DependencyRevision));
        Check(terrainPreview.TerrainName == "Culvert Terrain A"
            && terrainPreview.SourceExtent is { MaxX: > 0, MaxY: > 0 }
            && terrainPreview.RenderedExtent is not null
            && terrainPreview.Width is > 0 and <= 512 && terrainPreview.Height is > 0 and <= 512
            && terrainPreview.Rgba.Length == terrainPreview.Width * terrainPreview.Height * 4,
            "The culvert map preview renders bounded pixels from the actually associated source terrain and returns its exact rendered extent");
        await Expect<SourceFileChangedException>(() => ModelEditorAdapter.LoadGeometryCulvertTerrainPreviewAsync(
            new(model, "stale-terrain-dependency")));
        ExportFixtureIfRequested(temporary.FullName);

        GeometryCulvertSnapshot movedOnce = await ModelEditorAdapter.EditGeometryCulvertsAsync(new(model,
            loaded.Revision, loaded.DraftState,
            new("moveBarrels", "barrel", ["barrel:source:0"], DeltaX: 2.25, DeltaY: -1.5),
            ["barrel:source:0"]));
        GeometryCulvertCoordinate[] movedLine = movedOnce.Barrels.Rows.Single().Polyline;
        Check(movedLine[0].X == 3.25 && movedLine[0].Y == -0.5
            && movedLine[1].X == 17.25 && movedLine[1].Y == -0.5
            && movedLine.Select(point => point.Z).SequenceEqual(new string?[] { "2.5", "3.5" })
            && movedLine.Select(point => point.M).SequenceEqual(new string?[] { "10", "24" }),
            "Whole-feature movement translates every XY coordinate and preserves all source Z/M values");
        GeometryCulvertSnapshot moveUndo = await ModelEditorAdapter.EditGeometryCulvertsAsync(new(model,
            movedOnce.Revision, movedOnce.DraftState,
            new("undo", "barrel", []), ["barrel:source:0"]));
        Check(!moveUndo.IsDirty && moveUndo.Barrels.Rows.Single().Polyline[0].X == 1,
            "Whole-feature movement is an ordinary undoable geometry draft operation");

        GeometryCulvertSnapshot reversed = await ModelEditorAdapter.EditGeometryCulvertsAsync(new(model,
            loaded.Revision, loaded.DraftState,
            new("reverseBarrel", "barrel", ["barrel:source:0"]), ["barrel:source:0"]));
        GeometryCulvertFeatureRow reversedRow = reversed.Barrels.Rows.Single();
        Check(reversed.IsDirty && reversedRow.ID == loaded.Barrels.Rows.Single().ID
            && reversedRow.Values.OrderBy(pair => pair.Key).SequenceEqual(
                loaded.Barrels.Rows.Single().Values.OrderBy(pair => pair.Key))
            && reversedRow.Polyline.SequenceEqual(loaded.Barrels.Rows.Single().Polyline.Reverse())
            && reversedRow.Polyline.Select(point => point.Z).SequenceEqual(new string?[] { "3.5", "2.5" })
            && reversedRow.Polyline.Select(point => point.M).SequenceEqual(new string?[] { "24", "10" }),
            "Reverse follows the source PointCollection operation while preserving the same row, six barrel fields and aligned XY/Z/M");
        GeometryCulvertSnapshot reverseUndo = await ModelEditorAdapter.EditGeometryCulvertsAsync(new(model,
            reversed.Revision, reversed.DraftState, new("undo", "barrel", []), ["barrel:source:0"]));
        Check(!reverseUndo.IsDirty && reverseUndo.Barrels.Rows.Single().Polyline.SequenceEqual(loaded.Barrels.Rows.Single().Polyline),
            "Reverse is reversible through the culvert parent ledger without changing the HDF");

        const string geoprocessingDraftID = "4476e63a817c4c4f93b3ee0c7cb6c350";
        GeometryCulvertSnapshot xyLine = await ModelEditorAdapter.EditGeometryCulvertsAsync(new(model,
            loaded.Revision, loaded.DraftState,
            new("addBarrel", "barrel", [], DraftID: geoprocessingDraftID,
                Polyline: [new(1, 1), new(4, 2), new(7, 1), new(10, 2), new(15, 1)]),
            ["barrel:draft:" + geoprocessingDraftID]));
        GeometryCulvertSnapshot namedXYLine = await ModelEditorAdapter.EditGeometryCulvertsAsync(new(model,
            xyLine.Revision, xyLine.DraftState,
            new("setField", "barrel", ["barrel:draft:" + geoprocessingDraftID], "Name", "Filtered source line"),
            ["barrel:draft:" + geoprocessingDraftID]));
        GeometryCulvertFeatureRow xyBefore = namedXYLine.Barrels.Rows.Single(row => row.ID == "barrel:draft:" + geoprocessingDraftID);
        GeometryCulvertSnapshot filtered = await ModelEditorAdapter.EditGeometryCulvertsAsync(new(model,
            namedXYLine.Revision, namedXYLine.DraftState,
            new("filterBarrel", "barrel", [xyBefore.ID], Tolerance: 2d), [xyBefore.ID]));
        GeometryCulvertFeatureRow filteredRow = filtered.Barrels.Rows.Single(row => row.ID == xyBefore.ID);
        GeometryCulvertFeatureRow unselectedBeforeFilter = namedXYLine.Barrels.Rows.Single(row => row.ID == "barrel:source:0");
        GeometryCulvertFeatureRow unselectedAfterFilter = filtered.Barrels.Rows.Single(row => row.ID == unselectedBeforeFilter.ID);
        Check(filtered.IsDirty && filteredRow.ID == xyBefore.ID && filteredRow.FID == xyBefore.FID
            && SourceBarrelPropertiesEqual(filteredRow, xyBefore)
            && filteredRow.Polyline.SequenceEqual([xyBefore.Polyline[0], xyBefore.Polyline[^1]])
            && filteredRow.Polyline.All(point => point.Z is null && point.M is null),
            "Filter uses source Douglas-Peucker epsilon, replaces only the selected row geometry, and keeps its barrel properties and identity");
        Check(filteredRow.Values["Length"] != xyBefore.Values["Length"]
            && DerivedGeometryValuesMatch(filteredRow)
            && filteredRow.Values["VertexCount"] == "2"
            && filteredRow.Values["UpstreamSampledTerrainElevationDisplay"] == xyBefore.Values["UpstreamSampledTerrainElevationDisplay"]
            && filteredRow.Values["DownstreamSampledTerrainElevationDisplay"] == xyBefore.Values["DownstreamSampledTerrainElevationDisplay"]
            && unselectedAfterFilter.Polyline.SequenceEqual(unselectedBeforeFilter.Polyline)
            && SourceBarrelPropertiesEqual(unselectedAfterFilter, unselectedBeforeFilter),
            "Filter refreshes derived length/count from the simplified geometry while preserving endpoint samples and every unselected barrel row");
        GeometryCulvertSnapshot filterUndo = await ModelEditorAdapter.EditGeometryCulvertsAsync(new(model,
            filtered.Revision, filtered.DraftState, new("undo", "barrel", []), [xyBefore.ID]));
        Check(filterUndo.Barrels.Rows.Single(row => row.ID == xyBefore.ID).Polyline.SequenceEqual(xyBefore.Polyline),
            "Filter restores its exact source line when the parent ledger is undone");

        GeometryCulvertSnapshot smoothed = await ModelEditorAdapter.EditGeometryCulvertsAsync(new(model,
            namedXYLine.Revision, namedXYLine.DraftState,
            new("smoothBarrel", "barrel", [xyBefore.ID], WindowSize: 3, Passes: 2), [xyBefore.ID]));
        GeometryCulvertFeatureRow smoothedRow = smoothed.Barrels.Rows.Single(row => row.ID == xyBefore.ID);
        GeometryCulvertFeatureRow unselectedAfterSmooth = smoothed.Barrels.Rows.Single(row => row.ID == unselectedBeforeFilter.ID);
        Check(smoothed.IsDirty && smoothedRow.ID == xyBefore.ID && smoothedRow.FID == xyBefore.FID
            && SourceBarrelPropertiesEqual(smoothedRow, xyBefore)
            && smoothedRow.Polyline.Length == xyBefore.Polyline.Length
            && smoothedRow.Polyline[0] == xyBefore.Polyline[0]
            && smoothedRow.Polyline[^1] == xyBefore.Polyline[^1]
            && smoothedRow.Polyline[2] != xyBefore.Polyline[2]
            && smoothedRow.Polyline.All(point => point.Z is null && point.M is null)
            && DerivedGeometryValuesMatch(smoothedRow)
            && smoothedRow.Values["VertexCount"] == xyBefore.Values["VertexCount"]
            && smoothedRow.Values["UpstreamSampledTerrainElevationDisplay"] == xyBefore.Values["UpstreamSampledTerrainElevationDisplay"]
            && smoothedRow.Values["DownstreamSampledTerrainElevationDisplay"] == xyBefore.Values["DownstreamSampledTerrainElevationDisplay"]
            && unselectedAfterSmooth.Polyline.SequenceEqual(unselectedBeforeFilter.Polyline)
            && SourceBarrelPropertiesEqual(unselectedAfterSmooth, unselectedBeforeFilter),
            "Smooth uses the source moving-average window and passes while retaining endpoints and the source barrel row");
        GeometryCulvertSnapshot smoothUndo = await ModelEditorAdapter.EditGeometryCulvertsAsync(new(model,
            smoothed.Revision, smoothed.DraftState, new("undo", "barrel", []), [xyBefore.ID]));
        Check(smoothUndo.Barrels.Rows.Single(row => row.ID == xyBefore.ID).Polyline.SequenceEqual(xyBefore.Polyline),
            "Smooth restores its exact source line when the parent ledger is undone");

        await Expect<ArgumentException>(() => ModelEditorAdapter.EditGeometryCulvertsAsync(new(model,
            loaded.Revision, loaded.DraftState,
            new("filterBarrel", "barrel", ["barrel:source:0"], Tolerance: 1d), ["barrel:source:0"])));
        await Expect<ArgumentException>(() => ModelEditorAdapter.EditGeometryCulvertsAsync(new(model,
            loaded.Revision, loaded.DraftState,
            new("smoothBarrel", "barrel", ["barrel:source:0"], WindowSize: 3, Passes: 2), ["barrel:source:0"])));
        await Expect<ArgumentException>(() => ModelEditorAdapter.EditGeometryCulvertsAsync(new(model,
            loaded.Revision, loaded.DraftState,
            new("filterBarrel", "barrel", ["barrel:source:0"], Tolerance: 0d), ["barrel:source:0"])));
        await Expect<ArgumentException>(() => ModelEditorAdapter.EditGeometryCulvertsAsync(new(model,
            loaded.Revision, loaded.DraftState,
            new("smoothBarrel", "barrel", ["barrel:source:0"], WindowSize: 2, Passes: 1), ["barrel:source:0"])));

        GeometryCulvertFeatureRow sourceBarrel = loaded.Barrels.Rows.Single();
        var clipboardBarrel = new GeometryCulvertCopiedBarrel("unused", sourceBarrel.Values["Name"],
            sourceBarrel.Values["BarrelPropertyName"], sourceBarrel.Values["UpstreamInvert"],
            sourceBarrel.Values["DownstreamInvert"], sourceBarrel.Values["UpstreamOpeningName"],
            sourceBarrel.Values["DownstreamOpeningName"], sourceBarrel.Polyline);
        const string pastedDraftID = "d27f1af60cb7434d880cb9332740c9ab";
        GeometryCulvertSnapshot pasted = await ModelEditorAdapter.EditGeometryCulvertsAsync(new(model,
            loaded.Revision, loaded.DraftState,
            new("pasteBarrels", "barrel", [], CopiedBarrels: [clipboardBarrel with { DraftID = pastedDraftID }]),
            ["barrel:draft:" + pastedDraftID]));
        GeometryCulvertFeatureRow pastedRow = pasted.Barrels.Rows.Single(row => row.ID == "barrel:draft:" + pastedDraftID);
        Check(pasted.IsDirty && pastedRow.Values["Name"] == sourceBarrel.Values["Name"]
            && pastedRow.Values["BarrelPropertyName"] == sourceBarrel.Values["BarrelPropertyName"]
            && pastedRow.Values["UpstreamInvert"] == sourceBarrel.Values["UpstreamInvert"]
            && pastedRow.Values["DownstreamInvert"] == sourceBarrel.Values["DownstreamInvert"]
            && pastedRow.Values["UpstreamOpeningName"] == sourceBarrel.Values["UpstreamOpeningName"]
            && pastedRow.Values["DownstreamOpeningName"] == sourceBarrel.Values["DownstreamOpeningName"]
            && pastedRow.Polyline.SequenceEqual(sourceBarrel.Polyline),
            "Clipboard paste clones the source barrel's six properties, complete XY/Z/M line and stable draft identity");
        GeometryCulvertSnapshot pasteUndo = await ModelEditorAdapter.EditGeometryCulvertsAsync(new(model,
            pasted.Revision, pasted.DraftState, new("undo", "barrel", []), ["barrel:source:0"]));
        Check(!pasteUndo.IsDirty && pasteUndo.Barrels.Rows.Length == 1,
            "Clipboard paste is undoable without writing the source HDF");

        GeometryCulvertSnapshot reshaped = await ModelEditorAdapter.EditGeometryCulvertsAsync(new(model,
            loaded.Revision, loaded.DraftState,
            new("setPolyline", "barrel", ["barrel:source:0"], Polyline:
            [new(1, 1), new(8, 10), new(15, 1)]),
            ["barrel:source:0"]));
        Check(reshaped.IsDirty && reshaped.Barrels.Rows.Single().Polyline.Length == 3
            && reshaped.Profiles.Single().Length > loaded.Profiles.Single().Length
            && reshaped.Profiles.Single().Samples.Max(sample => sample.Y) > 9.9
            && reshaped.Profiles.Single().Samples.All(sample => Math.Abs(sample.Elevation - 42) < 1e-4),
            "Reshaping uses the observable source setter and immediately resamples the selected terrain profile along the new line");
        GeometryCulvertSnapshot shapeUndo = await ModelEditorAdapter.EditGeometryCulvertsAsync(new(model,
            reshaped.Revision, reshaped.DraftState, new("undo", "barrel", []), ["barrel:source:0"]));
        Check(shapeUndo.IsDirty == false && shapeUndo.Barrels.Rows.Single().Polyline.Length == 2
            && Math.Abs(shapeUndo.Profiles.Single().Length - loaded.Profiles.Single().Length) < 1e-6,
            "Undo replays only the mutation prefix and restores the source polyline and terrain profile");

        const string newBarrelDraftID = "542d314faab94649946af21c2de73a47";
        GeometryCulvertSnapshot drawn = await ModelEditorAdapter.EditGeometryCulvertsAsync(new(model,
            loaded.Revision, loaded.DraftState,
            new("addBarrel", "barrel", [], DraftID: newBarrelDraftID,
                Polyline: [new(2, 2), new(7, 6), new(12, 3)]),
            ["barrel:draft:" + newBarrelDraftID]));
        GeometryCulvertFeatureRow drawnBarrel = drawn.Barrels.Rows.Single(row => row.ID == "barrel:draft:" + newBarrelDraftID);
        Check(drawn.IsDirty && drawn.Barrels.Rows.Length == 2 && drawnBarrel.Values["Name"] == "Culvert Barrel"
            && drawn.Profiles.Single().BarrelID == drawnBarrel.ID
            && drawn.Profiles.Single().Samples.First().X == 2 && drawn.Profiles.Single().Samples.Last().X == 12,
            "Drawing adds a stable draft barrel and computes its profile from the same selected terrain context");
        GeometryCulvertSnapshot drawnUndo = await ModelEditorAdapter.EditGeometryCulvertsAsync(new(model,
            drawn.Revision, drawn.DraftState, new("undo", "barrel", []), [drawnBarrel.ID]));
        Check(!drawnUndo.IsDirty && drawnUndo.Barrels.Rows.Length == 1
            && drawnUndo.Barrels.Rows.All(row => row.ID != drawnBarrel.ID),
            "Undo removes only the newly drawn barrel from the staged culvert ledger");

        await Expect<ArgumentException>(() => ModelEditorAdapter.EditGeometryCulvertsAsync(new(model,
            loaded.Revision, loaded.DraftState,
            new("setPolyline", "barrel", ["barrel:source:0"], Polyline: [new(1, 1), new(1, 1)]),
            ["barrel:source:0"])));
        await Expect<ArgumentException>(() => ModelEditorAdapter.EditGeometryCulvertsAsync(new(model,
            loaded.Revision, loaded.DraftState,
            new("addBarrel", "barrel", [], DraftID: newBarrelDraftID,
                Polyline: [new(2, 2), new(double.NaN, 3)]),
            ["barrel:draft:" + newBarrelDraftID])));
        Check(File.ReadAllBytes(assetPath).SequenceEqual(sourceHdf)
            && File.ReadAllBytes(projectPath).SequenceEqual(sourceProject)
            && File.ReadAllBytes(rasterA).SequenceEqual(rasterABytes)
            && File.ReadAllBytes(rasterB).SequenceEqual(rasterBBytes),
            "Drawing, reshaping, undoing and validation failures remain in memory until the parent geometry save");

        GeometryCulvertSnapshot renamed = await ModelEditorAdapter.EditGeometryCulvertsAsync(new(model,
            loaded.Revision, loaded.DraftState,
            new("setField", "barrel", ["barrel:source:0"], "Name", "Updated barrel"),
            ["barrel:source:0"]));
        const string persistedBarrelDraftID = "1b5d367c130c4c9e9c004391e918d422";
        GeometryCulvertSnapshot parentLineDraft = await ModelEditorAdapter.EditGeometryCulvertsAsync(new(model,
            renamed.Revision, renamed.DraftState,
            new("setPolyline", "barrel", ["barrel:source:0"], Polyline:
            [new(1, 1, "2.5", "10"), new(7, 5, "3", "17"), new(15, 1, "3.5", "24")]),
            ["barrel:source:0"]));
        GeometryCulvertSnapshot parentDrawDraft = await ModelEditorAdapter.EditGeometryCulvertsAsync(new(model,
            parentLineDraft.Revision, parentLineDraft.DraftState,
            new("addBarrel", "barrel", [], DraftID: persistedBarrelDraftID,
                Polyline: [new(3, 4), new(9, 8), new(14, 3)]),
            ["barrel:source:0"]));
        GeometryCulvertSnapshot added = await ModelEditorAdapter.EditGeometryCulvertsAsync(new(model,
            parentDrawDraft.Revision, parentDrawDraft.DraftState,
            new("add", "barrelProperties", [], DraftID: "03e6edced5c24a49a131b9951e23b0e1"),
            ["barrel:source:0"]));
        GeometryCulvertFeatureRow newBarrelProperties = added.BarrelProperties.Rows.Single(row => row.ID.Contains(":draft:", StringComparison.Ordinal));
        GeometryCulvertSnapshot configured = await ModelEditorAdapter.EditGeometryCulvertsAsync(new(model,
            added.Revision, added.DraftState,
            new("setField", "barrelProperties", [newBarrelProperties.ID], "Name", "New barrel type"),
            ["barrel:source:0"]));
        Check(configured.IsDirty && configured.Barrels.Rows.Single(row => row.ID == "barrel:source:0").Values["Name"] == "Updated barrel"
            && configured.Barrels.Rows.Single(row => row.ID == "barrel:source:0").Polyline.Length == 3
            && configured.Barrels.Rows.Any(row => row.ID == "barrel:draft:" + persistedBarrelDraftID && row.Polyline.Length == 3)
            && configured.BarrelProperties.Rows.Any(row => row.Values["Name"] == "New barrel type"),
            "Identity-backed culvert names, polyline edits, drawn barrels and property-set edits compose in one in-memory draft");

        GeometryCulvertSnapshot reversedForSave = await ModelEditorAdapter.EditGeometryCulvertsAsync(new(model,
            configured.Revision, configured.DraftState,
            new("reverseBarrel", "barrel", ["barrel:source:0"]), ["barrel:source:0"]));
        GeometryCulvertSnapshot movedForSave = await ModelEditorAdapter.EditGeometryCulvertsAsync(new(model,
            reversedForSave.Revision, reversedForSave.DraftState,
            new("moveBarrels", "barrel", ["barrel:source:0"], DeltaX: 1.5, DeltaY: -0.5),
            ["barrel:source:0"]));
        const string parentPastedDraftID = "dd1300c62f4a4db7a73bd9e0c3531e85";
        GeometryCulvertFeatureRow movedSourceForCopy = movedForSave.Barrels.Rows.Single(row => row.ID == "barrel:source:0");
        var parentClipboardBarrel = new GeometryCulvertCopiedBarrel("unused", movedSourceForCopy.Values["Name"],
            movedSourceForCopy.Values["BarrelPropertyName"], movedSourceForCopy.Values["UpstreamInvert"],
            movedSourceForCopy.Values["DownstreamInvert"], movedSourceForCopy.Values["UpstreamOpeningName"],
            movedSourceForCopy.Values["DownstreamOpeningName"], movedSourceForCopy.Polyline);
        GeometryCulvertSnapshot culvertStateForSave = await ModelEditorAdapter.EditGeometryCulvertsAsync(new(model,
            movedForSave.Revision, movedForSave.DraftState,
            new("pasteBarrels", "barrel", [], CopiedBarrels: [parentClipboardBarrel with { DraftID = parentPastedDraftID }]),
            ["barrel:source:0", "barrel:draft:" + parentPastedDraftID]));
        Check(File.ReadAllBytes(assetPath).SequenceEqual(sourceHdf)
            && File.ReadAllBytes(projectPath).SequenceEqual(sourceProject)
            && File.ReadAllBytes(rasterA).SequenceEqual(rasterABytes)
            && File.ReadAllBytes(rasterB).SequenceEqual(rasterBBytes),
            "Loading and editing culverts never writes the geometry, project XML or terrain rasters");

        await Expect<ArgumentException>(() => ModelEditorAdapter.EditGeometryCulvertsAsync(new(model,
            configured.Revision, configured.DraftState,
            new("setField", "barrel", ["barrel:source:0"], "UnknownField", "1"))));
        await Expect<ArgumentException>(() => ModelEditorAdapter.EditGeometryCulvertsAsync(new(model,
            configured.Revision, configured.DraftState,
            new("setField", "barrelProperties", [newBarrelProperties.ID], "Rise", "NaN"))));
        await Expect<ArgumentException>(() => ModelEditorAdapter.EditGeometryCulvertsAsync(new(model,
            configured.Revision, configured.DraftState,
            new("setField", "barrelProperties", [newBarrelProperties.ID], "Shape", "Custom"))));
        await Expect<ArgumentException>(() => ModelEditorAdapter.EditGeometryCulvertsAsync(new(model,
            configured.Revision, configured.DraftState,
            new("setField", "openingProperties", [loaded.OpeningProperties.Rows.Single().ID], "OpeningType", "None"))));
        await Expect<ArgumentException>(() => ModelEditorAdapter.EditGeometryCulvertsAsync(new(model,
            configured.Revision, configured.DraftState,
            new("setField", "barrel", ["barrel:source:0"], "Name", "bad\nname"))));

        XElement alternateXml = XElement.Parse(projectXml);
        XElement association = alternateXml.Descendants("GeometryAssociation").Single(element =>
            element.Attribute("Geometry")?.Value == "Culvert geometry");
        association.SetAttributeValue("Terrain", "Culvert Terrain B");
        string alternateProjectXml = alternateXml.ToString(SaveOptions.DisableFormatting);
        var alternateModel = model with { ProjectXml = alternateProjectXml };
        await Expect<SourceFileChangedException>(() => ModelEditorAdapter.LoadGeometryCulvertsAsync(
            new(alternateModel, loaded.Revision, configured.DraftState, ["barrel:source:0"])));
        GeometryCulvertSnapshot alternate = await ModelEditorAdapter.LoadGeometryCulvertsAsync(
            new(alternateModel, loaded.Revision, SelectedBarrelIDs: ["barrel:source:0"]));
        Check(alternate.AssociatedTerrainName == "Culvert Terrain B"
            && alternate.Profiles.Single().Samples.Length > 1
            && alternate.Profiles.Single().Samples.All(sample => Math.Abs(sample.Elevation - 84) < 1e-4),
            "Read-only profile refresh follows the current unsaved Geometry-to-Terrain project association");

        // Source NoData is a sentinel, not a lower elevation limit.
        // Legitimate bathymetry below that sentinel must remain visible.
        try
        {
            using (var deepRaster = Gdal.Open(rasterB, Access.GA_Update))
            using (var band = deepRaster.GetRasterBand(1)) band.Fill(-11000, 0);
            GeometryCulvertSnapshot deep = await ModelEditorAdapter.LoadGeometryCulvertsAsync(
                new(alternateModel, loaded.Revision, SelectedBarrelIDs: ["barrel:source:0"]));
            Check(deep.Profiles.Single().Samples.Length > 1
                && deep.Profiles.Single().Samples.All(sample => Math.Abs(sample.Elevation + 11000) < 1e-4),
                "Finite terrain below -9999 is retained; only the actual source NoData sentinel is excluded");
        }
        finally { File.WriteAllBytes(rasterB, rasterBBytes); }

        File.AppendAllText(rasterA, "dependency changed");
        await Expect<SourceFileChangedException>(() => ModelEditorAdapter.EditGeometryCulvertsAsync(new(model,
            loaded.Revision, configured.DraftState,
            new("setField", "barrel", ["barrel:source:0"], "UpstreamInvert", "38"))));
        File.WriteAllBytes(rasterA, rasterABytes);
        Check(File.ReadAllBytes(assetPath).SequenceEqual(sourceHdf)
            && File.ReadAllBytes(projectPath).SequenceEqual(sourceProject),
            "A changed raster dependency rejects the stale culvert draft without writing source files");

        var ordinary = await ModelEditorAdapter.LoadAsync(new(assetPath, "Geometry", projectPath, projectXml));
        const string descriptionField = "GeometrySummaryPage/ViewModel_SelectedGeometryVisualContext_Context_Description";
        ModelSnapshot saved = await ModelEditorAdapter.SaveAsync(new ModelSaveRequest(assetPath, "Geometry", projectPath,
            ordinary.Revision, new() { [descriptionField] = "Combined culvert edit" }, [], ProjectXml: projectXml,
            GeometryCulvertState: culvertStateForSave.DraftState));
        ModelSnapshot ordinaryReopened = await ModelEditorAdapter.LoadAsync(new(assetPath, "Geometry", projectPath, projectXml));
        GeometryCulvertSnapshot persisted = await ModelEditorAdapter.LoadGeometryCulvertsAsync(new(model,
            saved.Revision, SelectedBarrelIDs: ["barrel:source:0"]));
        GeometryCulvertFeatureRow persistedSourceBarrel = persisted.Barrels.Rows.Single(row => row.ID == "barrel:source:0");
        GeometryCulvertFeatureRow persistedDrawnBarrel = persisted.Barrels.Rows.Single(row => row.ID == "barrel:source:1");
        GeometryCulvertFeatureRow persistedPastedBarrel = persisted.Barrels.Rows.Single(row => row.ID == "barrel:source:2");
        Check(saved.Revision != ordinary.Revision
            && saved.Fields[descriptionField] == "Combined culvert edit"
            && ordinaryReopened.Fields[descriptionField] == "Combined culvert edit"
            && persisted.Barrels.Rows.Select(row => row.ID).SequenceEqual(
                ["barrel:source:0", "barrel:source:1", "barrel:source:2"])
            && persisted.Barrels.Rows.Length == 3
            && persisted.Barrels.Rows.All(row => row.ID.StartsWith("barrel:source:", StringComparison.Ordinal))
            && persistedSourceBarrel.FID == 0 && persistedDrawnBarrel.FID == 1 && persistedPastedBarrel.FID == 2
            && persistedSourceBarrel.Values["Name"] == "Updated barrel"
            && persistedSourceBarrel.Polyline.Length == 3
            && persistedDrawnBarrel.Polyline.Length == 3
            && persistedSourceBarrel.Polyline.SequenceEqual(
                [new GeometryCulvertCoordinate(16.5, 0.5, "3.5", "24"),
                 new GeometryCulvertCoordinate(8.5, 4.5, "3", "17"),
                 new GeometryCulvertCoordinate(2.5, 0.5, "2.5", "10")])
            && persistedPastedBarrel.Values["Name"] == persistedSourceBarrel.Values["Name"]
            && persistedPastedBarrel.Values["BarrelPropertyName"] == persistedSourceBarrel.Values["BarrelPropertyName"]
            && persistedPastedBarrel.Values["UpstreamInvert"] == persistedSourceBarrel.Values["UpstreamInvert"]
            && persistedPastedBarrel.Values["DownstreamInvert"] == persistedSourceBarrel.Values["DownstreamInvert"]
            && persistedPastedBarrel.Values["UpstreamOpeningName"] == persistedSourceBarrel.Values["UpstreamOpeningName"]
            && persistedPastedBarrel.Values["DownstreamOpeningName"] == persistedSourceBarrel.Values["DownstreamOpeningName"]
            && persistedPastedBarrel.Polyline.SequenceEqual(persistedSourceBarrel.Polyline)
            && persisted.BarrelProperties.Rows.Any(row => row.Values["Name"] == "New barrel type")
            && File.ReadAllBytes(projectPath).SequenceEqual(sourceProject)
            && File.ReadAllBytes(rasterA).SequenceEqual(rasterABytes)
            && File.ReadAllBytes(rasterB).SequenceEqual(rasterBBytes),
            "The parent model save persists the moved, drawn and pasted culvert rows with cloned fields and XY/Z/M; a fresh load assigns source FIDs and leaves project/raster files untouched");

        byte[] committed = File.ReadAllBytes(assetPath);
        await Expect<SourceFileChangedException>(() => ModelEditorAdapter.EditGeometryCulvertsAsync(new(model,
            loaded.Revision, loaded.DraftState,
            new("setField", "barrel", ["barrel:source:0"], "UpstreamInvert", "38"))));
        Check(File.ReadAllBytes(assetPath).SequenceEqual(committed), "Stale geometry revisions cannot overwrite a committed culvert edit");
        Console.WriteLine("Geometry culvert source identity, terrain profile, source geoprocessing, project-draft association, dependency SHA, validation, staged save and no-write checks passed.");
    }

    private static string CreateRaster(string filename, float elevation)
    {
        using var driver = Gdal.GetDriverByName("GTiff");
        using var dataset = driver.Create(filename, 32, 32, 1, DataType.GDT_Float32,
            ["TILED=YES", "BLOCKXSIZE=16", "BLOCKYSIZE=16"]);
        dataset.SetGeoTransform([0, 1, 0, 32, 0, -1]);
        using var band = dataset.GetRasterBand(1);
        band.Fill(elevation, 0);
        return filename;
    }

    private static void ExportFixtureIfRequested(string sourceDirectory)
    {
        string? fixture = Environment.GetEnvironmentVariable("HECRAS_CULVERT_ACCEPTANCE_DIRECTORY");
        if (string.IsNullOrWhiteSpace(fixture)) return;
        string destination = Path.GetFullPath(fixture);
        if (Directory.Exists(destination) || File.Exists(destination))
            throw new IOException("The culvert fixture destination already exists.");
        Directory.CreateDirectory(destination);
        foreach (string folder in Directory.EnumerateDirectories(sourceDirectory, "*", SearchOption.AllDirectories))
            Directory.CreateDirectory(Path.Combine(destination, Path.GetRelativePath(sourceDirectory, folder)));
        foreach (string file in Directory.EnumerateFiles(sourceDirectory, "*", SearchOption.AllDirectories))
            File.Copy(file, Path.Combine(destination, Path.GetRelativePath(sourceDirectory, file)));
    }

    private static void Check(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }

    private static bool SourceBarrelPropertiesEqual(GeometryCulvertFeatureRow left, GeometryCulvertFeatureRow right)
    {
        string[] keys = ["Name", "BarrelPropertyName", "UpstreamInvert", "DownstreamInvert",
            "UpstreamOpeningName", "DownstreamOpeningName"];
        return keys.All(key => left.Values.TryGetValue(key, out string? leftValue)
            && right.Values.TryGetValue(key, out string? rightValue) && leftValue == rightValue);
    }

    private static bool DerivedGeometryValuesMatch(GeometryCulvertFeatureRow row)
    {
        double length = 0d;
        for (int index = 1; index < row.Polyline.Length; index++)
        {
            double dx = row.Polyline[index].X - row.Polyline[index - 1].X;
            double dy = row.Polyline[index].Y - row.Polyline[index - 1].Y;
            length += Math.Sqrt(dx * dx + dy * dy);
        }
        return double.TryParse(row.Values.GetValueOrDefault("Length"), NumberStyles.Float,
                   CultureInfo.InvariantCulture, out double reportedLength)
            && Math.Abs(reportedLength - length) <= Math.Max(1e-9, Math.Abs(length) * 1e-12)
            && row.Values.GetValueOrDefault("VertexCount") == row.Polyline.Length.ToString(CultureInfo.InvariantCulture);
    }

    private static async Task Expect<T>(Func<Task> action) where T : Exception
    {
        try { await action(); }
        catch (T) { return; }
        throw new InvalidOperationException("Expected " + typeof(T).Name);
    }
}
