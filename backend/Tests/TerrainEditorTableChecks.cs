using Geospatial;
using Geospatial.PairedData;
using Geospatial.Rasters.Modifiers;
using Geospatial.Vectors;
using OSGeo.GDAL;
using Ras.Backend;
using Ras.Layers;
using Ras.Layers.Terrains;
using Utility.Units;

internal static class TerrainEditorTableChecks
{
    private const string Source = "TerrainLayersEditor/SelectedInputWithMap";
    private const string ChannelFeatures = "ChannelModEditor/Features";
    private const string ChannelProfile = "ChannelModEditor/Profile";
    private const string ChannelTerrainProfile = "ChannelModEditor/TerrainProfile";
    private const string LeveeFeatures = "LeveeModsTable";
    private const string LeveeProperties = "LeveeModPropertiesEditor/PropertySets";

    internal static async Task Run()
    {
        using var directory = new TemporaryDirectory();
        string projectPath = Path.Combine(directory.FullName, "terrain tables.ras");
        Project project = Project.CreateNew(projectPath, UnitSystem.SI);
        Terrain terrain = project.AddNewTerrain("Terrain tables");
        string rasterPath = Path.Combine(terrain.SourceDirectory, "terrain.tif");
        using (var driver = Gdal.GetDriverByName("GTiff"))
        using (var raster = driver.Create(rasterPath, 16, 16, 1, DataType.GDT_Float32, ["TILED=YES", "BLOCKXSIZE=16", "BLOCKYSIZE=16"]))
        {
            raster.SetGeoTransform([0, 1, 0, 16, 0, -1]);
            using var band = raster.GetRasterBand(1); band.Fill(42, 0);
        }
        terrain.Add(RasterTerrainInput.CreateAndScan(terrain, rasterPath));
        Polyline MakeLine()
        {
            Polyline line = new(new Point[] { new(1, 8), new(14, 8) });
            line.TrackZ([double.NaN, 17]);
            line.TrackM([12, double.NaN]);
            return line;
        }
        ChannelModTerrainInput channel = new(terrain, "Channel vector");
        channel.Add(new ChannelProfile(MakeLine(), new StationElevationProfile([0, 13], [double.NaN, 8])) { Name = "Original channel" });
        terrain.Add(channel);
        LeveeModTerrainInput levee = new(terrain, "Levee cut fill");
        levee.PropertiesTable.Add(new LeveeModProperties { Name = "Template" });
        levee.Add(new LeveeMod(MakeLine(), new StationElevationProfile([0, 13], [double.NaN, double.NaN]))
        { Name = "Original levee", LeveePropertyName = "Template" });
        terrain.Add(levee);
        project.Save(); terrain.Save();
        string asset = terrain.Filename;
        terrain.Dispose();
        if (Environment.GetEnvironmentVariable("HECRAS_TERRAIN_MODIFICATION_ACCEPTANCE_DIRECTORY") is string fixture)
        {
            if (Directory.Exists(fixture)) throw new IOException("Acceptance fixture destination already exists.");
            Directory.CreateDirectory(fixture);
            foreach (string source in Directory.EnumerateFiles(directory.FullName, "*", SearchOption.AllDirectories))
            {
                string target = Path.Combine(fixture, Path.GetRelativePath(directory.FullName, source));
                Directory.CreateDirectory(Path.GetDirectoryName(target)!);
                File.Copy(source, target);
            }
        }

        ModelSnapshot snapshot = await ModelEditorAdapter.LoadAsync(new(asset, "Terrain", projectPath));
        string channelID = snapshot.Terrain!.Inputs.Single(input => input.Type == "Channel").Id;
        string leveeID = snapshot.Terrain.Inputs.Single(input => input.Type == "Levee").Id;
        snapshot = await ModelEditorAdapter.TransformTerrainAsync(new(Request(snapshot, asset, projectPath, Fields("")),
            "selectInput", ItemId: channelID));
        string channelFeatureID = TerrainRows(snapshot)[ChannelFeatures].Single().Id;
        snapshot = await Select(snapshot, asset, projectPath, channelID, ChannelFeatures, [channelFeatureID]);

        string channelNameField = Scope([channelFeatureID], "ChannelModEditor/PrimarySelection_Name");
        Dictionary<string, string> fieldEdit = new(StringComparer.Ordinal)
        {
            [Source] = channelID,
            [channelNameField] = "Edited by detail"
        };
        snapshot = await ModelEditorAdapter.TransformTerrainAsync(new(Request(snapshot, asset, projectPath, fieldEdit,
            tableSelections: new() { [ChannelFeatures] = [channelFeatureID] }), "reorder", From: 0, To: 0));
        Check(TerrainRows(snapshot)[ChannelFeatures].Single().Values["Name"] == "Edited by detail",
            "An unchanged stale table payload cannot overwrite the selected-feature detail draft when no cell is marked changed.");

        ModelRow channelRow = TerrainRows(snapshot)[ChannelFeatures].Single();
        Dictionary<string, string> cellValues = new(channelRow.Values, StringComparer.Ordinal) { ["Name"] = "Edited by marked cell" };
        Dictionary<string, ModelRow[]> editedRows = CloneRows(TerrainRows(snapshot));
        editedRows[ChannelFeatures] = [channelRow with { Values = cellValues }];
        snapshot = await ModelEditorAdapter.TransformTerrainAsync(new(Request(snapshot, asset, projectPath, fieldEdit, editedRows,
            new() { [ChannelFeatures] = [channelFeatureID] },
            changedCells: new() { [ChannelFeatures] = [new(channelRow.Id, "Name")] }), "reorder", From: 0, To: 0));
        Check(TerrainRows(snapshot)[ChannelFeatures].Single().Values["Name"] == "Edited by marked cell",
            "Only the explicitly marked source cell is applied from the row payload.");

        string[] oldProfileIDs = TerrainRows(snapshot)[ChannelProfile].Select(row => row.Id).ToArray();
        snapshot = await ModelEditorAdapter.TransformTerrainAsync(new(Request(snapshot, asset, projectPath, Fields(channelID),
            tableSelections: new() { [ChannelFeatures] = [channelFeatureID] }), "addRow", TableId: ChannelProfile));
        Check(TerrainRows(snapshot)[ChannelProfile].Length == oldProfileIDs.Length + 1,
            "Adding a channel station/elevation row updates the actual selected source profile.");
        ModelRow newProfileRow = TerrainRows(snapshot)[ChannelProfile].Single(row => !oldProfileIDs.Contains(row.Id, StringComparer.Ordinal));
        Dictionary<string, ModelRow[]> profileRows = CloneRows(TerrainRows(snapshot));
        profileRows[ChannelProfile] = profileRows[ChannelProfile].Select(row => row.Id == newProfileRow.Id
            ? row with { Values = new Dictionary<string, string>(row.Values, StringComparer.Ordinal) { ["Station"] = "3.5", ["Elevation"] = "88" } }
            : row).ToArray();
        snapshot = await ModelEditorAdapter.TransformTerrainAsync(new(Request(snapshot, asset, projectPath, Fields(channelID), profileRows,
            new() { [ChannelFeatures] = [channelFeatureID] }, new() { [ChannelProfile] = [new(newProfileRow.Id, "Station"), new(newProfileRow.Id, "Elevation")] }),
            "reorder", From: 0, To: 0));
        Check(TerrainRows(snapshot)[ChannelProfile].Any(row => row.Values["Station"] == "3.5" && row.Values["Elevation"] == "88"),
            "A newly added profile row can be edited in both columns on a later RPC using its captured original identity.");
        Check(snapshot.SourceState!.Contains("NaN", StringComparison.Ordinal), "The persistent terrain draft encodes missing profile/property values without JSON numeric NaN.");

        string[] sampledRowIDs = TerrainRows(snapshot)[ChannelTerrainProfile].Select(row => row.Id).ToArray();
        snapshot = await ModelEditorAdapter.TransformTerrainAsync(new(Request(snapshot, asset, projectPath, Fields(channelID),
            tableSelections: new() { [ChannelFeatures] = [channelFeatureID] }, rowEdits: null), "copyRows",
            TableId: ChannelTerrainProfile, RowIDs: sampledRowIDs));
        Check(TerrainRows(snapshot)[ChannelProfile].Length > 2
            && TerrainRows(snapshot)[ChannelProfile].All(row => Math.Abs(double.Parse(row.Values["Elevation"], System.Globalization.CultureInfo.InvariantCulture) - 42) < 1e-5),
            "Copy Terrain to Profile samples actual raster values along the selected channel line and persists the result across RPCs.");

        snapshot = await ModelEditorAdapter.TransformTerrainAsync(new(Request(snapshot, asset, projectPath, Fields(leveeID)), "reorder", From: 0, To: 0));
        string leveePropertyID = TerrainRows(snapshot)[LeveeProperties].Single().Id;
        snapshot = await Select(snapshot, asset, projectPath, leveeID, LeveeProperties, [leveePropertyID]);
        string firstPropertyScope = Scope([leveePropertyID], "LeveeModPropertiesDetailEditor");
        Dictionary<string, string> forwardFields = new(StringComparer.Ordinal)
        {
            [Source] = leveeID,
            [firstPropertyScope + "/Name"] = "First pass",
            [firstPropertyScope + "/TopWidthString"] = "21.5",
            [firstPropertyScope + "/Mode"] = "SimpleCut"
        };
        snapshot = await ModelEditorAdapter.TransformTerrainAsync(new(Request(snapshot, asset, projectPath, forwardFields,
            tableSelections: new() { [LeveeProperties] = [leveePropertyID] }), "reorder", From: 0, To: 0));
        string updatedPropertyID = TerrainRows(snapshot)[LeveeProperties].Single().Id;
        Check(TerrainRows(snapshot)[LeveeProperties].Single().Values["Name"] == "First pass"
            && TerrainRows(snapshot)[LeveeProperties].Single().Values["Mode"] == "SimpleCut"
            && snapshot.Fields.Single(pair => pair.Key.EndsWith("/TopWidthString", StringComparison.Ordinal)).Value == "21.5",
            "A selected property detail request applies Name, width and mode together.");
        string secondPropertyScope = Scope([updatedPropertyID], "LeveeModPropertiesDetailEditor");
        Dictionary<string, string> reverseFields = new(StringComparer.Ordinal)
        {
            [Source] = leveeID,
            [secondPropertyScope + "/Mode"] = "SimpleFill",
            [secondPropertyScope + "/TopWidthString"] = "33",
            [secondPropertyScope + "/Name"] = "Second pass"
        };
        snapshot = await ModelEditorAdapter.TransformTerrainAsync(new(Request(snapshot, asset, projectPath, reverseFields,
            tableSelections: new() { [LeveeProperties] = [updatedPropertyID] }), "reorder", From: 0, To: 0));
        Check(TerrainRows(snapshot)[LeveeProperties].Single().Values["Name"] == "Second pass"
            && TerrainRows(snapshot)[LeveeProperties].Single().Values["Mode"] == "SimpleFill"
            && snapshot.Fields.Single(pair => pair.Key.EndsWith("/TopWidthString", StringComparison.Ordinal)).Value == "33",
            "A single request can update mutable-ID Levee property fields regardless of dictionary iteration order.");

        string currentLeveeFeatureID = TerrainRows(snapshot)[LeveeFeatures].Single().Id;
        snapshot = await Select(snapshot, asset, projectPath, leveeID, LeveeFeatures, [currentLeveeFeatureID]);
        string currentPropertyID = TerrainRows(snapshot)[LeveeProperties].Single().Id;
        currentLeveeFeatureID = TerrainRows(snapshot)[LeveeFeatures].Single().Id;
        ModelRow currentLeveeRow = TerrainRows(snapshot)[LeveeFeatures].Single();
        ModelRow currentLeveeProfile = TerrainRows(snapshot)[LeveeProfile()].First();
        Dictionary<string, ModelRow[]> mixedRows = CloneRows(TerrainRows(snapshot));
        mixedRows[LeveeFeatures] = [currentLeveeRow with
        {
            Values = new Dictionary<string, string>(currentLeveeRow.Values, StringComparer.Ordinal) { ["Name"] = "Feature via table" }
        }];
        mixedRows[LeveeProfile()] = [currentLeveeProfile with
        {
            Values = new Dictionary<string, string>(currentLeveeProfile.Values, StringComparer.Ordinal)
            { ["Station"] = "1.5", ["Elevation"] = "23" }
        }, .. TerrainRows(snapshot)[LeveeProfile()].Skip(1)];
        string mixedPropertyScope = Scope([currentPropertyID], "LeveeModPropertiesDetailEditor");
        Dictionary<string, string> mixedFields = new(StringComparer.Ordinal)
        {
            [Source] = leveeID,
            [mixedPropertyScope + "/Name"] = "Mixed detail",
            [mixedPropertyScope + "/TopWidthString"] = "45",
            [mixedPropertyScope + "/Mode"] = "SimpleCut"
        };
        snapshot = await ModelEditorAdapter.TransformTerrainAsync(new(Request(snapshot, asset, projectPath, mixedFields, mixedRows,
            new() { [LeveeFeatures] = [currentLeveeFeatureID], [LeveeProperties] = [currentPropertyID] },
            new()
            {
                [LeveeFeatures] = [new(currentLeveeFeatureID, "Name")],
                [LeveeProfile()] = [new(currentLeveeProfile.Id, "Station"), new(currentLeveeProfile.Id, "Elevation")]
            }), "reorder", From: 0, To: 0));
        Check(TerrainRows(snapshot)[LeveeFeatures].Single().Values["Name"] == "Feature via table"
            && TerrainRows(snapshot)[LeveeProperties].Single().Values["Name"] == "Mixed detail"
            && snapshot.Fields.Single(pair => pair.Key.EndsWith("/TopWidthString", StringComparison.Ordinal)).Value == "45"
            && TerrainRows(snapshot)[LeveeProfile()].First().Values["Station"] == "1.5"
            && TerrainRows(snapshot)[LeveeProfile()].First().Values["Elevation"] == "23",
            "A captured table-row payload applies alongside selected-property detail fields using the pre-mutation row identities.");

        currentPropertyID = TerrainRows(snapshot)[LeveeProperties].Single().Id;
        snapshot = await ModelEditorAdapter.TransformTerrainAsync(new(Request(snapshot, asset, projectPath, Fields(leveeID),
            tableSelections: new() { [LeveeProperties] = [currentPropertyID] }), "addRow", TableId: LeveeProperties));
        string addedPropertyID = TerrainRows(snapshot)[LeveeProperties].Single(row => row.Values["Name"].StartsWith("Template", StringComparison.Ordinal)).Id;
        string addedScope = Scope([addedPropertyID], "LeveeModPropertiesDetailEditor");
        snapshot = await ModelEditorAdapter.TransformTerrainAsync(new(Request(snapshot, asset, projectPath,
            new() { [Source] = leveeID, [addedScope + "/Name"] = "Second property" }), "reorder", From: 0, To: 0));
        addedPropertyID = TerrainRows(snapshot)[LeveeProperties].Single(row => row.Values["Name"] == "Second property").Id;
        string renamedScope = Scope([addedPropertyID], "LeveeModPropertiesDetailEditor");
        snapshot = await ModelEditorAdapter.TransformTerrainAsync(new(Request(snapshot, asset, projectPath,
            new() { [Source] = leveeID, [renamedScope + "/Name"] = "Renamed while removing" },
            tableSelections: new() { [LeveeProperties] = [addedPropertyID] }), "removeRows", TableId: LeveeProperties, RowIDs: [addedPropertyID]));
        Check(TerrainRows(snapshot)[LeveeProperties].Length == 1,
            "Levee property add, later-RPC rename and selected-row removal survive structural draft restoration.");

        string leveeFeatureID = TerrainRows(snapshot)[LeveeFeatures].Single().Id;
        snapshot = await Select(snapshot, asset, projectPath, leveeID, LeveeFeatures, [leveeFeatureID]);

        Dictionary<string, ModelRow[]> unknownTableRows = CloneRows(TerrainRows(snapshot));
        unknownTableRows["unknown/table"] = [];
        await Reject(() => ModelEditorAdapter.TransformTerrainAsync(new(Request(snapshot, asset, projectPath, Fields(leveeID),
            rowEdits: unknownTableRows, changedCells: new() { ["unknown/table"] = [new("row", "Name")] }), "reorder", From: 0, To: 0)));
        await Reject(() => ModelEditorAdapter.TransformTerrainAsync(new(Request(snapshot, asset, projectPath, Fields(leveeID),
            rowEdits: TerrainRows(snapshot), changedCells: new() { [LeveeFeatures] = [new("unknown-row", "Name")] }), "reorder", From: 0, To: 0)));
        Dictionary<string, ModelRow[]> currentLeveeRows = TerrainRows(snapshot);
        ModelRow leveeRow = currentLeveeRows[LeveeFeatures].Single();
        Dictionary<string, ModelRow[]> badLeveeRows = CloneRows(currentLeveeRows);
        badLeveeRows[LeveeFeatures] = [leveeRow with { Values = new Dictionary<string, string>(leveeRow.Values, StringComparer.Ordinal) { ["Bogus"] = "x" } }];
        await Reject(() => ModelEditorAdapter.TransformTerrainAsync(new(Request(snapshot, asset, projectPath, Fields(leveeID), badLeveeRows,
            new() { [LeveeFeatures] = [leveeFeatureID] }, new() { [LeveeFeatures] = [new(leveeFeatureID, "Bogus")] }), "reorder", From: 0, To: 0)));
        await Reject(() => ModelEditorAdapter.TransformTerrainAsync(new(Request(snapshot, asset, projectPath, Fields(leveeID),
            changedCells: new() { [LeveeFeatures] = [new(leveeFeatureID, "LineLength")] }), "reorder", From: 0, To: 0)));
        ModelRow station = TerrainRows(snapshot)[LeveeProfile()]
            .First();
        Dictionary<string, ModelRow[]> nonFiniteRows = CloneRows(TerrainRows(snapshot));
        nonFiniteRows[LeveeProfile()] = nonFiniteRows[LeveeProfile()].Select(row => row.Id == station.Id
            ? row with { Values = new Dictionary<string, string>(row.Values, StringComparer.Ordinal) { ["Elevation"] = "Infinity" } }
            : row).ToArray();
        await Reject(() => ModelEditorAdapter.TransformTerrainAsync(new(Request(snapshot, asset, projectPath, Fields(leveeID), nonFiniteRows,
            new() { [LeveeFeatures] = [leveeFeatureID] }, new() { [LeveeProfile()] = [new(station.Id, "Elevation")] }), "reorder", From: 0, To: 0)));

        ModelRow firstSelectedProperty = TerrainRows(snapshot)[LeveeProperties].Single();
        string firstSelectedPropertyName = firstSelectedProperty.Values["Name"];
        string firstSelectedPropertyID = firstSelectedProperty.Id;
        snapshot = await ModelEditorAdapter.TransformTerrainAsync(new(Request(snapshot, asset, projectPath, Fields(leveeID)),
            "addRow", TableId: LeveeProperties));
        string secondSelectedPropertyID = TerrainRows(snapshot)[LeveeProperties]
            .Single(row => row.Id != firstSelectedPropertyID).Id;
        string secondSelectedScope = Scope([secondSelectedPropertyID], "LeveeModPropertiesDetailEditor");
        snapshot = await ModelEditorAdapter.TransformTerrainAsync(new(Request(snapshot, asset, projectPath,
            new(StringComparer.Ordinal)
            {
                [Source] = leveeID,
                [secondSelectedScope + "/Name"] = "ForceSet peer",
                [secondSelectedScope + "/Mode"] = "SimpleCut",
                [secondSelectedScope + "/ModType"] = "TakeHigher"
            }, tableSelections: new() { [LeveeProperties] = [secondSelectedPropertyID] }),
            "reorder", From: 0, To: 0));
        // Earlier checks intentionally left the surviving property at
        // SimpleCut. Set it back to SimpleFill so this fixture proves that
        // choosing the first selected row's current value still ForceSets
        // every selected property.
        string currentFirstPropertyID = TerrainRows(snapshot)[LeveeProperties]
            .Single(row => row.Values["Name"] == firstSelectedPropertyName).Id;
        string currentFirstPropertyScope = Scope([currentFirstPropertyID], "LeveeModPropertiesDetailEditor");
        snapshot = await ModelEditorAdapter.TransformTerrainAsync(new(Request(snapshot, asset, projectPath,
            new(StringComparer.Ordinal)
            {
                [Source] = leveeID,
                [currentFirstPropertyScope + "/Mode"] = "SimpleFill"
            }, tableSelections: new() { [LeveeProperties] = [currentFirstPropertyID] }),
            "reorder", From: 0, To: 0));
        // Property row IDs are content identities and include the property
        // and mutable fields. Recompute both exact IDs after rename/Mode edit.
        string[] forceSetPropertyIDs =
        [
            TerrainRows(snapshot)[LeveeProperties].Single(row => row.Values["Name"] == firstSelectedPropertyName).Id,
            TerrainRows(snapshot)[LeveeProperties].Single(row => row.Values["Name"] == "ForceSet peer").Id
        ];
        snapshot = await Select(snapshot, asset, projectPath, leveeID, LeveeProperties, forceSetPropertyIDs);
        ModelRow[] mixedForceSetRows = TerrainRows(snapshot)[LeveeProperties];
        string currentFirstMode = mixedForceSetRows.Single(row => row.Values["Name"] == firstSelectedPropertyName).Values["Mode"];
        string currentPeerMode = mixedForceSetRows.Single(row => row.Values["Name"] == "ForceSet peer").Values["Mode"];
        string aggregateModeField = Scope(forceSetPropertyIDs, "LeveeModPropertiesDetailEditor/Mode");
        string aggregateMismatchField = Scope(forceSetPropertyIDs, "LeveeModPropertiesDetailEditor/ModeHasMismatch");
        string aggregateMode = snapshot.Fields.TryGetValue(aggregateModeField, out var modeValue) ? modeValue : "<missing>";
        string aggregateMismatch = snapshot.Fields.TryGetValue(aggregateMismatchField, out var mismatchValue) ? mismatchValue : "<missing>";
        Check(currentFirstMode == "SimpleFill"
            && currentPeerMode == "SimpleCut"
            && aggregateMode == ""
            && aggregateMismatch == "true",
            $"The mixed Mode fixture must capture two distinct values before ForceSet; actual first='{currentFirstMode}', peer='{currentPeerMode}', aggregate='{aggregateMode}', mismatch='{aggregateMismatch}'.");
        byte[] sourceBeforeLeveeForceSet = File.ReadAllBytes(asset);
        snapshot = await ModelEditorAdapter.TransformTerrainAsync(new(Request(snapshot, asset, projectPath, Fields(leveeID),
            tableSelections: new() { [LeveeProperties] = forceSetPropertyIDs }), "forceSetLeveeProperty",
            TableId: LeveeProperties,
            LeveeForceSet: new("forceSetMode", "SimpleFill", forceSetPropertyIDs)));
        forceSetPropertyIDs =
        [
            TerrainRows(snapshot)[LeveeProperties].Single(row => row.Values["Name"] == firstSelectedPropertyName).Id,
            TerrainRows(snapshot)[LeveeProperties].Single(row => row.Values["Name"] == "ForceSet peer").Id
        ];
        Check(TerrainRows(snapshot)[LeveeProperties].All(row => row.Values["Mode"] == "SimpleFill")
            && snapshot.Fields[Scope(forceSetPropertyIDs, "LeveeModPropertiesDetailEditor/ModeHasMismatch")] == "false",
            "forceSetMode applies to every exact selected property set even when the chosen value equals the first row.");
        Check(File.ReadAllBytes(asset).SequenceEqual(sourceBeforeLeveeForceSet),
            "Levee ForceSet updates only the parent source draft and does not write the source HDF.");
        snapshot = await ModelEditorAdapter.TransformTerrainAsync(new(Request(snapshot, asset, projectPath, Fields(leveeID),
            tableSelections: new() { [LeveeProperties] = forceSetPropertyIDs }), "forceSetLeveeProperty",
            TableId: LeveeProperties,
            LeveeForceSet: new("forceSetModType", "SetValue", forceSetPropertyIDs)));
        forceSetPropertyIDs =
        [
            TerrainRows(snapshot)[LeveeProperties].Single(row => row.Values["Name"] == firstSelectedPropertyName).Id,
            TerrainRows(snapshot)[LeveeProperties].Single(row => row.Values["Name"] == "ForceSet peer").Id
        ];
        Check(TerrainRows(snapshot)[LeveeProperties].All(row => row.Values["Mode"] == "SimpleFill")
            && snapshot.Fields[Scope(forceSetPropertyIDs, "LeveeModPropertiesDetailEditor/ModTypeHasMismatch")] == "false",
            "forceSetModType applies to every exact selected property set and clears its derived mixed state.");
        await Reject(() => ModelEditorAdapter.TransformTerrainAsync(new(Request(snapshot, asset, projectPath, Fields(leveeID),
            tableSelections: new() { [LeveeProperties] = forceSetPropertyIDs }), "forceSetLeveeProperty",
            TableId: LeveeProperties,
            LeveeForceSet: new("forceSetMode", "SimpleCut", [forceSetPropertyIDs[0]]))));

        snapshot = await ModelEditorAdapter.SaveAsync(Request(snapshot, asset, projectPath, Fields(leveeID)));
        using (Terrain reopened = new(asset))
        {
            ChannelModTerrainInput savedChannel = reopened.Layers.OfType<ChannelModTerrainInput>().Single();
            LeveeModTerrainInput savedLevee = reopened.Layers.OfType<LeveeModTerrainInput>().Single();
            Check(savedChannel.Features.Single().Name == "Edited by marked cell"
                && savedChannel.Features.Single().Profile.Count > 2
                && savedChannel.Features.Single().Line.HasZ && savedChannel.Features.Single().Line.HasM
                && double.IsNaN(savedChannel.Features.Single().Line.GetZBufferUnsafe().Span[0])
                && double.IsNaN(savedChannel.Features.Single().Line.GetMBufferUnsafe().Span[1]),
                "Channel feature/name/profile and line Z/M dimensions persist through structural RPCs and HDF save.");
            LeveeModProperties[] savedProperties = savedLevee.PropertiesTable.Features.ToArray();
            LeveeModProperties originalProperty = savedProperties.Single(property => property.Name == "Mixed detail");
            Check(savedProperties.Length == 2 && originalProperty.Mode == LeveeMode.SimpleFill
                && originalProperty.TopWidth == 45 && double.IsNaN(originalProperty.RightWidth)
                && double.IsNaN(originalProperty.RightGrade)
                && savedProperties.Single(property => property.Name == "ForceSet peer").Mode == LeveeMode.SimpleFill
                && savedProperties.All(property => property.ModType == Geospatial.Rasters.RasterModType.SetValue)
                && double.IsNaN(savedLevee.Features.Single().Profile.Elevations[1])
                && savedLevee.Features.Single().Name == "Feature via table"
                && savedLevee.Features.Single().Profile.Stations[0] == 1.5
                && savedLevee.Features.Single().Profile.Elevations[0] == 23
                && savedLevee.Features.Single().Line.HasZ && savedLevee.Features.Single().Line.HasM,
                "Levee profile missing values, inherited property NaNs, and feature Z/M flags survive each reopened draft and HDF save.");
        }
        Console.WriteLine("Terrain feature/property/profile selection, changed-cell validation, cross-RPC structural drafts, actual terrain sampling and HDF persistence checks were added.");
    }

    private static string LeveeProfile() => "LeveeModDetailEditor/Profile";
    private static Dictionary<string, string> Fields(string selectedID) => new(StringComparer.Ordinal) { [Source] = selectedID };
    private static Dictionary<string, ModelRow[]> TerrainRows(ModelSnapshot snapshot) => snapshot.Terrain?.Rows
        ?? throw new InvalidDataException("The source terrain editor did not return its table rows.");

    private static string Scope(IEnumerable<string> ids, string route) => "TerrainSelection/" + string.Join("+", ids.Order(StringComparer.Ordinal)) + "/" + route;
    private static Dictionary<string, ModelRow[]> CloneRows(Dictionary<string, ModelRow[]> rows) => rows.ToDictionary(
        pair => pair.Key, pair => pair.Value.Select(row => row with { Values = new Dictionary<string, string>(row.Values, StringComparer.Ordinal) }).ToArray(), StringComparer.Ordinal);

    private static ModelSaveRequest Request(ModelSnapshot snapshot, string asset, string projectPath,
        Dictionary<string, string> fields, Dictionary<string, ModelRow[]>? rowEdits = null,
        Dictionary<string, string[]>? tableSelections = null, Dictionary<string, ChangedCell[]>? changedCells = null) =>
        new(asset, "Terrain", projectPath, snapshot.Revision, fields, new Dictionary<string, ImageData[]>(),
            SourceState: snapshot.SourceState, Rows: rowEdits ?? snapshot.Terrain?.Rows,
            TableSelections: tableSelections, ChangedCells: changedCells);

    private static async Task<ModelSnapshot> Select(ModelSnapshot snapshot, string asset, string projectPath,
        string inputID, string tableID, string[] rowIDs) => await ModelEditorAdapter.TransformTerrainAsync(new(
            Request(snapshot, asset, projectPath, Fields(inputID), tableSelections: new() { [tableID] = rowIDs }),
            "selectRows", TableId: tableID, RowIDs: rowIDs));

    private static async Task Reject(Func<Task<ModelSnapshot>> action)
    {
        try { _ = await action(); }
        catch (ArgumentException) { return; }
        throw new InvalidOperationException("Invalid terrain table edit was accepted.");
    }

    private static void Check(bool value, string reason)
    {
        if (!value) throw new InvalidOperationException(reason);
    }
}
