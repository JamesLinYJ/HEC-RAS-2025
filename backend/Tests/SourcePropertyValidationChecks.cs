using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Geospatial.PairedData;
using Geospatial;
using Geospatial.Rasters.Modifiers;
using Geospatial.Vectors;
using Ras.Backend;
using Ras.Layers;
using Ras.Layers.Terrains;
using Utility.Units;

internal static class SourcePropertyValidationChecks
{
    private const string SelectedInput = "TerrainLayersEditor/SelectedInputWithMap";
    private const string LeveePropertyTable = "LeveeModPropertiesEditor/PropertySets";

    internal static async Task Run()
    {
        using var directory = new TemporaryDirectory();
        string projectPath = Path.Combine(directory.FullName, "source validation.ras");
        Project project = Project.CreateNew(projectPath, UnitSystem.SI);
        Terrain terrain = project.AddNewTerrain("Validation");
        LeveeModTerrainInput levee = new(terrain, "Levee");
        levee.PropertiesTable.Add(new LeveeModProperties { Name = "Template", TopWidth = 5 });
        Polyline line = new(new Point[] { new(0, 0), new(10, 0) });
        levee.Add(new LeveeMod(line, new StationElevationProfile([0, 10], [1, 1]))
            { Name = "Levee feature", LeveePropertyName = "Template" });
        terrain.Add(levee);
        project.Save();
        terrain.Save();
        string assetPath = terrain.Filename;
        terrain.Dispose();
        byte[] sourceBefore = File.ReadAllBytes(assetPath);

        ModelSnapshot snapshot = await ModelEditorAdapter.LoadAsync(new(assetPath, "Terrain", projectPath));
        string inputID = snapshot.Terrain!.Inputs.Single(input => input.Type == "Levee").Id;
        snapshot = await ModelEditorAdapter.TransformTerrainAsync(new(
            Request(snapshot, assetPath, projectPath, Fields(inputID)), "selectInput", ItemId: inputID));
        TerrainEditorData selectedTerrain = snapshot.Terrain
            ?? throw new InvalidOperationException("Selecting the Levee input did not return terrain editor data.");
        if (selectedTerrain.Rows is not { } selectedRows
            || !selectedRows.TryGetValue(LeveePropertyTable, out ModelRow[]? propertyRows)
            || propertyRows is null)
        {
            throw new InvalidOperationException("Selecting the Levee input did not return its property table.");
        }
        string propertyID = propertyRows.Single().Id;
        snapshot = await ModelEditorAdapter.TransformTerrainAsync(new(
            Request(snapshot, assetPath, projectPath, Fields(inputID),
                new() { [LeveePropertyTable] = [propertyID] }),
            "selectRows", TableId: LeveePropertyTable, RowIDs: [propertyID]));

        string propertyField = snapshot.Fields.Keys.Single(key => key.EndsWith(
            "/LeveeModPropertiesDetailEditor/TopWidthString", StringComparison.Ordinal));
        ModelSaveRequest invalidModel = Request(snapshot, assetPath, projectPath,
            new Dictionary<string, string>(snapshot.Fields, StringComparer.Ordinal) { [propertyField] = "-1" },
            new() { [LeveePropertyTable] = [propertyID] }, validationOnly: true);
        SourcePropertyValidationRequest invalidRequest = ValidationRequest(invalidModel,
            propertyField, "TopWidth", "-1", [propertyID]);
        SourcePropertyValidationResponse invalidResponse = await ModelEditorAdapter.ValidateSourcePropertyAsync(invalidRequest);
        Check(invalidResponse.RequestID == invalidRequest.RequestID
            && invalidResponse.FieldID == propertyField
            && invalidResponse.SourceRevision == invalidModel.Revision
            && invalidResponse.TableSelections![LeveePropertyTable].SequenceEqual(new[] { propertyID })
            && invalidResponse.Messages.Any(message => message.Level is "error" or "typeError"),
            "Levee ErrorValidationSource uses the selected source property and returns its real negative-width validation result with the captured selection.");

        ModelSaveRequest validModel = Request(snapshot, assetPath, projectPath,
            new Dictionary<string, string>(snapshot.Fields, StringComparer.Ordinal) { [propertyField] = "7.5" },
            new() { [LeveePropertyTable] = [propertyID] }, validationOnly: true);
        SourcePropertyValidationRequest validRequest = ValidationRequest(validModel,
            propertyField, "TopWidth", "7.5", [propertyID]);
        SourcePropertyValidationResponse validResponse = await ModelEditorAdapter.ValidateSourcePropertyAsync(validRequest);
        Check(validResponse.Messages.All(message => message.Level is not ("error" or "typeError")),
            "The source validation owner accepts an in-range width without changing the saved terrain draft.");

        SourcePropertyValidationRequest staleSelection = invalidRequest with
        {
            Model = invalidModel with { TableSelections = new Dictionary<string, string[]>() }
        };
        await Reject(() => ModelEditorAdapter.ValidateSourcePropertyAsync(staleSelection));
        Check(File.ReadAllBytes(assetPath).SequenceEqual(sourceBefore),
            "Source property validation is read-only and never saves the terrain file.");
    }

    private static Dictionary<string, string> Fields(string inputID) =>
        new(StringComparer.Ordinal) { [SelectedInput] = inputID };

    private static ModelSaveRequest Request(ModelSnapshot snapshot, string assetPath, string projectPath,
        Dictionary<string, string> fields, Dictionary<string, string[]>? tableSelections = null,
        bool validationOnly = false) =>
        new(assetPath, "Terrain", projectPath, snapshot.Revision, fields,
            new Dictionary<string, ImageData[]>(StringComparer.Ordinal),
            SourceState: snapshot.SourceState,
            Rows: validationOnly ? new Dictionary<string, ModelRow[]>(StringComparer.Ordinal) : snapshot.Terrain?.Rows,
            Samples: new Dictionary<string, ModelSample[]>(StringComparer.Ordinal),
            PlanTimeWindowEdits: [],
            TableSelections: tableSelections ?? new Dictionary<string, string[]>(StringComparer.Ordinal),
            ChangedCells: new Dictionary<string, ChangedCell[]>(StringComparer.Ordinal));

    private static SourcePropertyValidationRequest ValidationRequest(ModelSaveRequest model,
        string fieldID, string propertyName, string text, string[] selectedRowIDs)
    {
        string sourceFingerprint = Fingerprint(model.SourceState ?? "");
        string parentFingerprint = Fingerprint(JsonSerializer.SerializeToUtf8Bytes(model, BackendJson.Options));
        return new(model, "source-validation:" + propertyName + ":" + text,
            Guid.NewGuid().ToString("D"), 1, 1, 1, "LeveeModPropertiesDetailEditor",
            fieldID, propertyName, text, selectedRowIDs, sourceFingerprint, parentFingerprint);
    }

    private static string Fingerprint(string value) => Fingerprint(Encoding.UTF8.GetBytes(value));
    private static string Fingerprint(byte[] bytes) =>
        Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant();

    private static async Task Reject(Func<Task<SourcePropertyValidationResponse>> action)
    {
        try { _ = await action(); }
        catch (ArgumentException) { return; }
        throw new InvalidOperationException("A source validation request with a stale selection was accepted.");
    }

    private static void Check(bool condition, string description)
    {
        if (!condition) throw new InvalidOperationException(description);
    }
}
