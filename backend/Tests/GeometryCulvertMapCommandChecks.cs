using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Geospatial;
using Geospatial.Vectors;
using OSGeo.GDAL;
using Ras.Backend;
using Ras.Hydraulics.Culverts;
using Ras.Layers;
using Ras.Layers.Terrains;
using Utility.Units;

/// <summary>
/// Exercises culvert map commands through the same preview, child-draft,
/// parent-save and reopen routes used by the native geometry editor.
/// </summary>
internal static class GeometryCulvertMapCommandChecks
{
    private const string MergeRetainedSourceID = "barrel:source:2";

    internal static async Task Run()
    {
        using var temporary = new TemporaryDirectory();
        Fixture fixture = CreateFixture(temporary.FullName);
        GeometryCulvertModelRequest model = fixture.Model;
        GeometryCulvertSnapshot baseline = await ModelEditorAdapter.LoadGeometryCulvertsAsync(
            new(model, SelectedBarrelIDs: ["barrel:source:0", "barrel:source:1", MergeRetainedSourceID]));

        Check(baseline.CanEdit && baseline.Barrels.Rows.Select(row => row.ID).SequenceEqual(
                ["barrel:source:0", "barrel:source:1", MergeRetainedSourceID])
            && baseline.AssociatedTerrainName == "Culvert Commands Terrain"
            && baseline.DependencyRevision is { Length: > 0 },
            "The fixture loads three actual source barrel IDs and a revision-bound associated terrain.");

        byte[] sourceHdf = File.ReadAllBytes(fixture.GeometryPath);
        byte[] sourceProject = File.ReadAllBytes(fixture.ProjectPath);
        byte[] sourceTerrainHdf = File.ReadAllBytes(fixture.TerrainPath);
        byte[] sourceRaster = File.ReadAllBytes(fixture.RasterPath);
        ExportFixtureIfRequested(temporary.FullName, fixture, baseline);

        GeometryCulvertSnapshot splitUndone = await VerifySplitPreviewApplyUndo(model, baseline);
        GeometryCulvertSnapshot mergeUndone = await VerifyMergePreviewApplyUndo(model, splitUndone);
        GeometryCulvertSnapshot offsetUndone = await VerifyOffsetPreviewApplyUndo(model, mergeUndone);
        ParentSaveMerge parentSaveMerge = await CreateMergeDraftForParentSave(model, offsetUndone);
        GeometryCulvertSnapshot smartAddDraft = await VerifySmartAddTerrainPreviewAndAppend(model,
            parentSaveMerge.Snapshot);

        Check(File.ReadAllBytes(fixture.GeometryPath).SequenceEqual(sourceHdf)
            && File.ReadAllBytes(fixture.ProjectPath).SequenceEqual(sourceProject)
            && File.ReadAllBytes(fixture.TerrainPath).SequenceEqual(sourceTerrainHdf)
            && File.ReadAllBytes(fixture.RasterPath).SequenceEqual(sourceRaster),
            "Preview, apply, undo and SmartAdd append remain child-draft edits and leave every source file unchanged before parent save.");

        ModelSnapshot ordinary = await ModelEditorAdapter.LoadAsync(
            new(fixture.GeometryPath, "Geometry", fixture.ProjectPath, fixture.ProjectXml));
        ModelSnapshot saved = await ModelEditorAdapter.SaveAsync(new ModelSaveRequest(
            fixture.GeometryPath, "Geometry", fixture.ProjectPath, ordinary.Revision,
            new Dictionary<string, string>(StringComparer.Ordinal),
            new Dictionary<string, ImageData[]>(StringComparer.Ordinal),
            ProjectXml: fixture.ProjectXml,
            GeometryCulvertState: smartAddDraft.DraftState));
        GeometryCulvertSnapshot reopened = await ModelEditorAdapter.LoadGeometryCulvertsAsync(
            new(model, saved.Revision));
        GeometryCulvertFeatureRow reopenedSmartAdd = reopened.Barrels.Rows.Single(row =>
            row.Polyline.SequenceEqual(smartAddDraft.Barrels.Rows.Single(
                candidate => candidate.ID == "barrel:draft:41b5e12cfc7340d1ad4f88a6db4c12e8").Polyline));
        GeometryCulvertFeatureRow reopenedMerge = reopened.Barrels.Rows.Single(row =>
            row.Polyline.SequenceEqual(parentSaveMerge.MergedPolyline));
        GeometryCulvertFeatureRow reopenedRetained = reopened.Barrels.Rows.Single(row =>
            row.Values["Name"] == "Isolated retained barrel");
        GeometryCulvertFeatureRow baselineRetained = baseline.Barrels.Rows.Single(row =>
            row.ID == MergeRetainedSourceID);
        Check(saved.Revision != ordinary.Revision && reopened.Barrels.Rows.Length == 3
            && reopened.AssociatedTerrainName == baseline.AssociatedTerrainName
            && reopened.Barrels.Rows.Select(row => row.ID).SequenceEqual(
                ["barrel:source:0", "barrel:source:1", "barrel:source:2"])
            && reopenedSmartAdd.Polyline.SequenceEqual(smartAddDraft.Barrels.Rows.Single(
                row => row.ID == "barrel:draft:41b5e12cfc7340d1ad4f88a6db4c12e8").Polyline)
            && reopenedMerge.Polyline.SequenceEqual(parentSaveMerge.MergedPolyline)
            && HasGeneratedBarrelDefaults(reopenedSmartAdd) && HasGeneratedBarrelDefaults(reopenedMerge)
            && SameSourceBarrelData(baselineRetained, reopenedRetained)
            && !File.ReadAllBytes(fixture.GeometryPath).SequenceEqual(sourceHdf)
            && File.ReadAllBytes(fixture.ProjectPath).SequenceEqual(sourceProject)
            && File.ReadAllBytes(fixture.TerrainPath).SequenceEqual(sourceTerrainHdf)
            && File.ReadAllBytes(fixture.RasterPath).SequenceEqual(sourceRaster),
            "The parent Geometry save persists both real command outputs, keeps every generated barrel at source constructor defaults and retains the original unmerged barrel's geometry and hydraulic fields after a fresh HDF reopen.");

        Console.WriteLine("Culvert map preview, stable target identity, merge retention, generated defaults, undo, real associated-terrain SmartAdd and parent save/reopen checks passed.");
    }

    private static async Task<GeometryCulvertSnapshot> VerifySplitPreviewApplyUndo(
        GeometryCulvertModelRequest model, GeometryCulvertSnapshot baseline)
    {
        const string targetID = "barrel:source:0";
        GeometryCulvertCoordinate splitPoint = new(20, 20);
        string[] outputIDs = ["10000000000040008000000000000001", "10000000000040008000000000000002"];
        var request = new GeometryCulvertMapCommandPreviewRequest(model, baseline.Revision,
            baseline.DraftState, "split-preview-correct-target", "split", [], splitPoint,
            "Anywhere", 0.01, OutputDraftIDs: outputIDs, TargetFeatureID: targetID);
        GeometryCulvertMapCommandPreviewResponse preview = await ModelEditorAdapter
            .PreviewGeometryCulvertMapCommandAsync(request);
        Check(preview.CanApply && preview.HasChange && preview.ErrorCode is null
            && preview.CapturedFeatureIDs.SequenceEqual([targetID], StringComparer.Ordinal)
            && preview.RemovedFeatureIDs.SequenceEqual([targetID], StringComparer.Ordinal)
            && preview.Outputs.Length == 2 && preview.Outputs.Select(output => output.DraftID).SequenceEqual(outputIDs),
            "Split preview captures only the actually snapped clicked barrel and returns two generated identities.");

        GeometryCulvertMapCommandPreviewResponse mismatch = await ModelEditorAdapter
            .PreviewGeometryCulvertMapCommandAsync(request with
            {
                PreviewID = "split-preview-wrong-target",
                TargetFeatureID = MergeRetainedSourceID
            });
        Check(!mismatch.CanApply && !mismatch.HasChange && mismatch.ErrorCode == "targetMismatch"
            && mismatch.Outputs.Length == 0,
            "A split click that snaps to another barrel is an explicit non-applicable preview rather than a mutation of the wrong row.");

        GeometryCulvertSnapshot edited = await ModelEditorAdapter.EditGeometryCulvertsAsync(new(model,
            baseline.Revision, baseline.DraftState,
            new GeometryCulvertMutation("split", "barrel", preview.CapturedFeatureIDs,
                PreviewID: preview.PreviewID, TargetFeatureID: targetID, SplitPoint: splitPoint,
                OutputDraftIDs: outputIDs, SplitMode: "Anywhere", MapCellSize: 0.01),
            [targetID]));
        GeometryCulvertFeatureRow[] generated = outputIDs.Select(id => edited.Barrels.Rows.Single(
            row => row.ID == "barrel:draft:" + id)).ToArray();
        Check(edited.IsDirty && !edited.Barrels.Rows.Any(row => row.ID == targetID)
            && generated.Zip(preview.Outputs).All(pair => pair.First.Polyline.SequenceEqual(pair.Second.Polyline))
            && generated.All(HasGeneratedBarrelDefaults),
            "Applying a valid split appends exactly the two preview geometries with source constructor defaults in the child ledger.");

        GeometryCulvertSnapshot undone = await ModelEditorAdapter.EditGeometryCulvertsAsync(new(model,
            edited.Revision, edited.DraftState, new("undo", "barrel", []), [targetID]));
        Check(!undone.IsDirty && SameBarrelRows(baseline.Barrels.Rows, undone.Barrels.Rows),
            "Undo restores the source barrel identity, original coordinates and all source fields after split.");
        return undone;
    }

    private static async Task<GeometryCulvertSnapshot> VerifyMergePreviewApplyUndo(
        GeometryCulvertModelRequest model, GeometryCulvertSnapshot baseline)
    {
        string[] selectedIDs = ["barrel:source:0", "barrel:source:1", MergeRetainedSourceID];
        string[] outputIDs = ["20000000000040008000000000000001"];
        var request = new GeometryCulvertMapCommandPreviewRequest(model, baseline.Revision,
            baseline.DraftState, "merge-preview", "merge", selectedIDs,
            MergeTolerance: 5, OutputDraftIDs: outputIDs);
        GeometryCulvertMapCommandPreviewResponse preview = await ModelEditorAdapter
            .PreviewGeometryCulvertMapCommandAsync(request);
        Check(preview.CanApply && preview.ErrorCode is null && preview.Outputs.Length == 1
            && preview.CapturedFeatureIDs.Length == 3 && preview.RemovedFeatureIDs.Length == 2
            && preview.RetainedFeatureIDs.SequenceEqual([MergeRetainedSourceID], StringComparer.Ordinal),
            "Merge preview uses the retained PreferClosest grouping, captures all inputs and reports the disjoint original as retained.");

        GeometryCulvertSnapshot edited = await ModelEditorAdapter.EditGeometryCulvertsAsync(new(model,
            baseline.Revision, baseline.DraftState,
            new GeometryCulvertMutation("merge", "barrel", preview.CapturedFeatureIDs,
                PreviewID: preview.PreviewID, OutputDraftIDs: outputIDs, MergeTolerance: 5),
            selectedIDs));
        GeometryCulvertFeatureRow retained = edited.Barrels.Rows.Single(row => row.ID == MergeRetainedSourceID);
        GeometryCulvertFeatureRow generated = edited.Barrels.Rows.Single(row => row.ID == "barrel:draft:" + outputIDs[0]);
        GeometryCulvertFeatureRow baselineRetained = baseline.Barrels.Rows.Single(row => row.ID == MergeRetainedSourceID);
        Check(edited.IsDirty && edited.Barrels.Rows.Length == 2
            && retained.ID == baselineRetained.ID && retained.FID == 1 && retained.Values["FID"] == "1"
            && SameSourceBarrelData(baselineRetained, retained)
            && generated.Polyline.SequenceEqual(preview.Outputs.Single().Polyline)
            && HasGeneratedBarrelDefaults(generated),
            "Applying merge preserves the unmerged original's stable child-draft ID, geometry and six hydraulic properties while assigning its new source-order FID after the generated row.");

        GeometryCulvertSnapshot undone = await ModelEditorAdapter.EditGeometryCulvertsAsync(new(model,
            edited.Revision, edited.DraftState, new("undo", "barrel", []), selectedIDs));
        Check(!undone.IsDirty && SameBarrelRows(baseline.Barrels.Rows, undone.Barrels.Rows),
            "Undo restores the exact pre-merge source table and identities.");
        return undone;
    }

    private static async Task<GeometryCulvertSnapshot> VerifyOffsetPreviewApplyUndo(
        GeometryCulvertModelRequest model, GeometryCulvertSnapshot baseline)
    {
        const string targetID = "barrel:source:0";
        string[] outputIDs =
        [
            "30000000000040008000000000000001", "30000000000040008000000000000002",
            "30000000000040008000000000000003", "30000000000040008000000000000004"
        ];
        var request = new GeometryCulvertMapCommandPreviewRequest(model, baseline.Revision,
            baseline.DraftState, "offset-preview", "offset", [targetID],
            OffsetDistance: 2, OffsetSides: "Both", IncludeEndpoints: true,
            KeepOriginal: true, OutputDraftIDs: outputIDs);
        GeometryCulvertMapCommandPreviewResponse preview = await ModelEditorAdapter
            .PreviewGeometryCulvertMapCommandAsync(request);
        Check(preview.CanApply && preview.ErrorCode is null && preview.Outputs.Length == 4
            && preview.RetainedFeatureIDs.SequenceEqual([targetID], StringComparer.Ordinal)
            && preview.RemovedFeatureIDs.Length == 0,
            "Offset preview exposes both real source banks and endpoint connectors while keeping the original selected feature.");

        GeometryCulvertSnapshot edited = await ModelEditorAdapter.EditGeometryCulvertsAsync(new(model,
            baseline.Revision, baseline.DraftState,
            new GeometryCulvertMutation("offset", "barrel", preview.CapturedFeatureIDs,
                PreviewID: preview.PreviewID, OutputDraftIDs: outputIDs,
                OffsetDistance: 2, OffsetSides: "Both", IncludeEndpoints: true, KeepOriginal: true),
            [targetID]));
        Check(edited.IsDirty && edited.Barrels.Rows.Length == baseline.Barrels.Rows.Length + outputIDs.Length
            && edited.Barrels.Rows.Single(row => row.ID == targetID).Polyline.SequenceEqual(
                baseline.Barrels.Rows.Single(row => row.ID == targetID).Polyline)
            && outputIDs.Select(id => edited.Barrels.Rows.Single(row => row.ID == "barrel:draft:" + id))
                .All(HasGeneratedBarrelDefaults),
            "Applying offset uses its preview geometries and preserves the original row when requested.");

        GeometryCulvertSnapshot undone = await ModelEditorAdapter.EditGeometryCulvertsAsync(new(model,
            edited.Revision, edited.DraftState, new("undo", "barrel", []), [targetID]));
        Check(!undone.IsDirty && SameBarrelRows(baseline.Barrels.Rows, undone.Barrels.Rows),
            "Undo removes all offset outputs and restores the original source table.");
        return undone;
    }

    private static async Task<GeometryCulvertSnapshot> VerifySmartAddTerrainPreviewAndAppend(
        GeometryCulvertModelRequest model, GeometryCulvertSnapshot baseline)
    {
        const string draftID = "41b5e12cfc7340d1ad4f88a6db4c12e8";
        GeometryCulvertCoordinate start = new(20, 70);
        GeometryCulvertCoordinate end = new(90, 70);
        var request = new GeometryCulvertSmartAddPreviewRequest(model, baseline.Revision,
            baseline.DraftState, "smart-add-real-terrain", start, end,
            new(new GeometryCulvertExtent(0, 0, 128, 128), 128, 128),
            new GeometryCulvertSmartAddOptions(Algorithm: "HighGround",
                MaxSegmentPixels: 120, HighGroundSnapRadiusCells: 0));
        GeometryCulvertSmartAddPreviewResponse preview = await ModelEditorAdapter
            .PreviewGeometryCulvertSmartAddAsync(request);
        Check(preview.CanAppend && preview.ErrorCode is null
            && preview.TerrainName == baseline.AssociatedTerrainName && preview.Path.Length >= 2
            && preview.Path[0] == start
            && preview.Path.All(point => double.IsFinite(point.X) && double.IsFinite(point.Y)),
            "SmartAdd resamples the geometry's real associated terrain and returns a finite path beginning at the captured map start.");

        GeometryCulvertSnapshot appended = await ModelEditorAdapter.EditGeometryCulvertsAsync(new(model,
            baseline.Revision, baseline.DraftState,
            new GeometryCulvertMutation("addBarrel", "barrel", [], DraftID: draftID,
                Polyline: preview.Path),
            ["barrel:draft:" + draftID]));
        GeometryCulvertFeatureRow generated = appended.Barrels.Rows.Single(row => row.ID == "barrel:draft:" + draftID);
        Check(appended.IsDirty && generated.Polyline.SequenceEqual(preview.Path)
            && HasGeneratedBarrelDefaults(generated),
            "Accepting a SmartAdd terrain preview appends its exact accepted path through the ordinary undoable culvert child mutation.");
        return appended;
    }

    private static async Task<ParentSaveMerge> CreateMergeDraftForParentSave(
        GeometryCulvertModelRequest model, GeometryCulvertSnapshot baseline)
    {
        string[] selectedIDs = ["barrel:source:0", "barrel:source:1", MergeRetainedSourceID];
        string[] outputIDs = ["50000000000040008000000000000001"];
        GeometryCulvertMapCommandPreviewResponse preview = await ModelEditorAdapter
            .PreviewGeometryCulvertMapCommandAsync(new GeometryCulvertMapCommandPreviewRequest(model,
                baseline.Revision, baseline.DraftState, "merge-preview-parent-save", "merge", selectedIDs,
                MergeTolerance: 5, OutputDraftIDs: outputIDs));
        Check(preview.CanApply && preview.ErrorCode is null && preview.Outputs.Length == 1
            && preview.RetainedFeatureIDs.SequenceEqual([MergeRetainedSourceID], StringComparer.Ordinal),
            "The parent-save merge preview retains the unmerged source row before acceptance.");
        GeometryCulvertSnapshot applied = await ModelEditorAdapter.EditGeometryCulvertsAsync(new(model,
            baseline.Revision, baseline.DraftState,
            new GeometryCulvertMutation("merge", "barrel", preview.CapturedFeatureIDs,
                PreviewID: preview.PreviewID, OutputDraftIDs: outputIDs, MergeTolerance: 5),
            selectedIDs));
        GeometryCulvertFeatureRow retained = applied.Barrels.Rows.Single(row => row.ID == MergeRetainedSourceID);
        GeometryCulvertFeatureRow generated = applied.Barrels.Rows.Single(row => row.ID == "barrel:draft:" + outputIDs[0]);
        Check(applied.IsDirty && applied.Barrels.Rows.Length == 2
            && HasGeneratedBarrelDefaults(generated)
            && retained.ID == MergeRetainedSourceID && retained.FID == 1 && retained.Values["FID"] == "1"
            && SameSourceBarrelData(baseline.Barrels.Rows.Single(row => row.ID == MergeRetainedSourceID), retained),
            "The accepted parent-save merge keeps the retained source object's stable child-draft identity, geometry and hydraulic fields while its source-order FID moves behind the generated row.");
        return new ParentSaveMerge(applied, preview.Outputs.Single().Polyline);
    }

    private static Fixture CreateFixture(string root)
    {
        string projectPath = Path.Combine(root, "Culvert map commands.ras");
        Project project = Project.CreateNew(projectPath, UnitSystem.SI);
        Terrain terrain = project.AddNewTerrain("Culvert Commands Terrain");
        Directory.CreateDirectory(terrain.SourceDirectory);
        string rasterPath = Path.Combine(terrain.SourceDirectory, "culvert-command-terrain.tif");
        CreateGradientRaster(rasterPath);
        terrain.Add(RasterTerrainInput.CreateAndScan(terrain, rasterPath));

        Geometry geometry = project.AddNewGeometry("Culvert map commands", terrain, null!);
        geometry.BarrelPropertiesLayer.Add(new BarrelProperties
        {
            Name = "Round barrel", Rise = 1.5, Span = 1.5, Shape = BarrelShape.Circle,
            Mannings = 0.025, ManningsSwitchDepth = 0.1, DepthBlocked = 0
        });
        geometry.OpeningPropertiesLayer.Add(new OpeningProperties
        {
            Name = "Square edge", KIn = 0.5, KOut = 0.8,
            OpeningType = BarrelOpeningType.ConcretePipeCulvert_SquareEdgeWithHeadwall
        });
        AddSourceBarrel(geometry, "West connected barrel", new(10, 20), new(30, 20), 41, 40);
        AddSourceBarrel(geometry, "East connected barrel", new(34, 20), new(44, 20), 39, 38);
        AddSourceBarrel(geometry, "Isolated retained barrel", new(110, 100), new(120, 100), 37, 36);
        geometry.Save();
        terrain.Save();
        project.Save();

        string geometryPath = geometry.Filename;
        string terrainPath = terrain.Filename;
        geometry.Dispose();
        terrain.Dispose();
        string projectXml = File.ReadAllText(projectPath);
        return new Fixture(projectPath, geometryPath, terrainPath, rasterPath, projectXml,
            new GeometryCulvertModelRequest(geometryPath, "Geometry", projectPath, projectXml));
    }

    private static void AddSourceBarrel(Geometry geometry, string name,
        Point start, Point end, double upstreamInvert, double downstreamInvert)
    {
        geometry.CulvertBarrelLayer.Add(new CulvertBarrel
        {
            Name = name,
            Polyline = new Polyline(new Point[] { start, end }),
            BarrelPropertyName = "Round barrel",
            UpstreamInvert = upstreamInvert,
            DownstreamInvert = downstreamInvert,
            UpstreamOpeningName = "Square edge",
            DownstreamOpeningName = ""
        });
    }

    private static void CreateGradientRaster(string path)
    {
        const int size = 128;
        using var driver = Gdal.GetDriverByName("GTiff");
        using var dataset = driver.Create(path, size, size, 1, DataType.GDT_Float32,
            ["TILED=YES", "BLOCKXSIZE=32", "BLOCKYSIZE=32"]);
        dataset.SetGeoTransform([0, 1, 0, size, 0, -1]);
        var values = new float[size * size];
        for (int row = 0; row < size; row++)
        for (int column = 0; column < size; column++)
            values[row * size + column] = 0.1f * column + 0.03f * row + 0.0002f * column * row;
        using var band = dataset.GetRasterBand(1);
        band.WriteRaster(0, 0, size, size, values, size, size, 0, 0);
    }

    private static void ExportFixtureIfRequested(string sourceRoot, Fixture fixture,
        GeometryCulvertSnapshot baseline)
    {
        string? configured = Environment.GetEnvironmentVariable("HECRAS_CULVERT_COMMAND_ACCEPTANCE_DIRECTORY");
        if (string.IsNullOrWhiteSpace(configured)) return;
        string destination = Path.GetFullPath(configured);
        if (Directory.Exists(destination) || File.Exists(destination))
            throw new IOException("The culvert command acceptance destination already exists; refusing to overwrite it.");

        Directory.CreateDirectory(destination);
        foreach (string sourceDirectory in Directory.EnumerateDirectories(sourceRoot, "*", SearchOption.AllDirectories))
            Directory.CreateDirectory(Path.Combine(destination, Path.GetRelativePath(sourceRoot, sourceDirectory)));
        foreach (string sourceFile in Directory.EnumerateFiles(sourceRoot, "*", SearchOption.AllDirectories))
        {
            string relative = Path.GetRelativePath(sourceRoot, sourceFile);
            string target = Path.Combine(destination, relative);
            Directory.CreateDirectory(Path.GetDirectoryName(target)!);
            File.Copy(sourceFile, target);
        }

        string projectRelativePath = PortableRelativePath(sourceRoot, fixture.ProjectPath);
        string geometryRelativePath = PortableRelativePath(sourceRoot, fixture.GeometryPath);
        string terrainRelativePath = PortableRelativePath(sourceRoot, fixture.TerrainPath);
        string rasterRelativePath = PortableRelativePath(sourceRoot, fixture.RasterPath);
        var hashes = Directory.EnumerateFiles(destination, "*", SearchOption.AllDirectories)
            .ToDictionary(path => PortableRelativePath(destination, path),
                path => Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(path))), StringComparer.Ordinal);
        var manifest = new
        {
            schemaVersion = 1,
            kind = "culvert-map-command-acceptance",
            createdBy = nameof(GeometryCulvertMapCommandChecks),
            fixtureFresh = true,
            projectRelativePath,
            geometryRelativePath,
            terrainRelativePath,
            rasterRelativePaths = new[] { rasterRelativePath },
            sourceRevision = baseline.Revision,
            associatedDependencyRevision = baseline.DependencyRevision,
            sourceBarrels = baseline.Barrels.Rows.OrderBy(row => row.FID).Select(row => new
            {
                id = row.ID,
                fid = row.FID,
                values = row.Values,
                polyline = row.Polyline
            }).ToArray(),
            files = hashes
        };
        string manifestPath = Path.Combine(destination, "manifest.json");
        File.WriteAllText(manifestPath, JsonSerializer.Serialize(manifest, BackendJson.Options),
            new UTF8Encoding(encoderShouldEmitUTF8Identifier: false));
        Check(File.Exists(Path.Combine(destination, projectRelativePath))
            && File.Exists(Path.Combine(destination, geometryRelativePath))
            && File.Exists(Path.Combine(destination, terrainRelativePath))
            && File.Exists(Path.Combine(destination, rasterRelativePath))
            && !Path.IsPathFullyQualified(projectRelativePath)
            && !Path.IsPathFullyQualified(geometryRelativePath)
            && !Path.IsPathFullyQualified(terrainRelativePath)
            && hashes.ContainsKey(projectRelativePath) && hashes.ContainsKey(geometryRelativePath)
            && hashes.ContainsKey(terrainRelativePath) && hashes.ContainsKey(rasterRelativePath),
            "The fresh acceptance export contains the complete project, geometry HDF, associated terrain HDF and raster under relocatable relative paths with SHA-256 entries.");
    }

    private static bool HasGeneratedBarrelDefaults(GeometryCulvertFeatureRow row) =>
        row.Values.GetValueOrDefault("Name") == "Culvert Barrel"
        && row.Values.GetValueOrDefault("BarrelPropertyName") == string.Empty
        && row.Values.GetValueOrDefault("UpstreamInvert") == "0"
        && row.Values.GetValueOrDefault("DownstreamInvert") == "0"
        && row.Values.GetValueOrDefault("UpstreamOpeningName") == string.Empty
        && row.Values.GetValueOrDefault("DownstreamOpeningName") == string.Empty;

    private static bool SameBarrelRows(GeometryCulvertFeatureRow[] expected, GeometryCulvertFeatureRow[] actual) =>
        expected.Length == actual.Length && expected.All(row => actual.FirstOrDefault(candidate => candidate.ID == row.ID) is { } candidate
            && SameBarrelRow(row, candidate));

    private static bool SameBarrelRow(GeometryCulvertFeatureRow expected, GeometryCulvertFeatureRow actual) =>
        expected.ID == actual.ID && expected.FID == actual.FID
        && expected.Values.Count == actual.Values.Count
        && expected.Values.All(pair => actual.Values.TryGetValue(pair.Key, out string? value) && value == pair.Value)
        && expected.Polyline.SequenceEqual(actual.Polyline);

    private static bool SameSourceBarrelData(GeometryCulvertFeatureRow expected, GeometryCulvertFeatureRow actual) =>
        expected.Values.GetValueOrDefault("Name") == actual.Values.GetValueOrDefault("Name")
        && expected.Values.GetValueOrDefault("BarrelPropertyName") == actual.Values.GetValueOrDefault("BarrelPropertyName")
        && expected.Values.GetValueOrDefault("UpstreamInvert") == actual.Values.GetValueOrDefault("UpstreamInvert")
        && expected.Values.GetValueOrDefault("DownstreamInvert") == actual.Values.GetValueOrDefault("DownstreamInvert")
        && expected.Values.GetValueOrDefault("UpstreamOpeningName") == actual.Values.GetValueOrDefault("UpstreamOpeningName")
        && expected.Values.GetValueOrDefault("DownstreamOpeningName") == actual.Values.GetValueOrDefault("DownstreamOpeningName")
        && expected.Polyline.SequenceEqual(actual.Polyline);

    private static string PortableRelativePath(string root, string path) =>
        Path.GetRelativePath(root, path).Replace(Path.DirectorySeparatorChar, '/');

    private static void Check(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }

    private sealed record Fixture(string ProjectPath, string GeometryPath, string TerrainPath,
        string RasterPath, string ProjectXml, GeometryCulvertModelRequest Model);
    private sealed record ParentSaveMerge(GeometryCulvertSnapshot Snapshot,
        GeometryCulvertCoordinate[] MergedPolyline);
}
