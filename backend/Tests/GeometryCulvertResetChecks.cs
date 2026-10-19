using Ras.Backend;
using System.Globalization;
using Ras.Hydraulics.Culverts;
using Ras.Layers;
using Utility.Units;

internal static class GeometryCulvertResetChecks
{
    internal static async Task Run()
    {
        using var directory = new TemporaryDirectory();
        string projectPath = Path.Combine(directory.FullName, "Opening coefficient reset.ras");
        Project project = Project.CreateNew(projectPath, UnitSystem.SI);
        Geometry geometry = project.AddNewGeometry("Reset geometry");
        geometry.OpeningPropertiesLayer.Add(new OpeningProperties { Name = "First", KIn = .25, KOut = .35 });
        geometry.OpeningPropertiesLayer.Add(new OpeningProperties { Name = "Second", KIn = .5, KOut = .65,
            OpeningType = BarrelOpeningType.CorrugatedMetalPipeCulvert_Headwall });
        geometry.OpeningPropertiesLayer.Add(new OpeningProperties { Name = "Unselected", KIn = .75, KOut = .85 });
        project.Save();
        geometry.Save();
        string assetPath = geometry.Filename;
        geometry.Dispose();
        byte[] projectXmlBytes = File.ReadAllBytes(projectPath);

        var model = new GeometryCulvertModelRequest(assetPath, "Geometry", projectPath, File.ReadAllText(projectPath));
        GeometryCulvertSnapshot loaded = await ModelEditorAdapter.LoadGeometryCulvertsAsync(new(model));
        GeometryCulvertFeatureRow[] rows = loaded.OpeningProperties.Rows;
        string[] selectedIDs = rows.Take(2).Select(row => row.ID).ToArray();
        Check(new[] { rows[0].Values["KIn"], rows[1].Values["KIn"] }.Distinct(StringComparer.Ordinal).Count() == 2,
            "The selected opening-property rows begin with a real KIn mismatch");
        GeometryCulvertField[] openingFields = loaded.OpeningProperties.EditableFields;
        Check(openingFields.Single(field => field.ID == "OpeningType").ForceSetCommand == "forceSetOpeningType"
            && openingFields.Single(field => field.ID == "OpeningType").ErrorValidationSource is null
            && openingFields.Single(field => field.ID == "KIn") is { ShowClearButton: true,
                ClearCommand: "resetOpeningCoefficient", ErrorValidationSource: "OpeningPropertiesDetailEditor",
                ErrorValidationPropertyName: "KInString" }
            && openingFields.Single(field => field.ID == "KOut").ErrorValidationPropertyName == "KOutString"
            && openingFields.Single(field => field.ID == "Name").ErrorValidationPropertyName == "Name",
            "Opening property contracts retain the source ForceSet, mismatch clear, and exact text-field validation routes");

        GeometryCulvertSnapshot forcedType = await ModelEditorAdapter.EditGeometryCulvertsAsync(new(model,
            loaded.Revision, loaded.DraftState,
            new("forceSetOpeningType", "openingProperties", selectedIDs, "OpeningType",
                "ConcretePipeCulvert_GrooveEndWithHeadwall")));
        Check(forcedType.IsDirty && selectedIDs.All(id => forcedType.OpeningProperties.Rows
                .Single(row => row.ID == id).Values["OpeningType"] == "ConcretePipeCulvert_GrooveEndWithHeadwall")
            && forcedType.OpeningProperties.Rows.Single(row => row.Values["Name"] == "Unselected")
                .Values["OpeningType"] == "ConcretePipeCulvert_SquareEdgeWithHeadwall",
            "ForceSetOpeningType writes the chosen source enum only to the selected opening-property identities");
        GeometryCulvertSnapshot forceUndo = await ModelEditorAdapter.EditGeometryCulvertsAsync(new(model,
            forcedType.Revision, forcedType.DraftState, new("undo", "openingProperties", [])));
        Check(!forceUndo.IsDirty && forceUndo.OpeningProperties.Rows.Single(row => row.Values["Name"] == "Second")
                .Values["OpeningType"] == "CorrugatedMetalPipeCulvert_Headwall",
            "Undo removes a ForceSet command from the parent's replayable geometry draft");

        GeometryCulvertSnapshot invalidKIn = await ModelEditorAdapter.EditGeometryCulvertsAsync(new(model,
            loaded.Revision, loaded.DraftState,
            new("setField", "openingProperties", [rows[0].ID], "KIn", "1.5")));
        Check(invalidKIn.OpeningProperties.Rows.Single(row => row.ID == rows[0].ID).Errors is { } fieldErrors
            && fieldErrors["KInString"].Any(message => message.Contains("absolute bounds of 0 and 1", StringComparison.OrdinalIgnoreCase)),
            "Field error snapshots map the source editor's KInString validation route to the wrapped ObservableOpeningProperties error");

        CultureInfo priorCulture = CultureInfo.CurrentCulture;
        try
        {
            foreach (string culture in new[] { "fr-FR", "en-US" })
            {
                CultureInfo.CurrentCulture = CultureInfo.GetCultureInfo(culture);
                GeometryCulvertSnapshot validCoefficient = await ModelEditorAdapter.EditGeometryCulvertsAsync(new(model,
                    loaded.Revision, loaded.DraftState, new("setField", "openingProperties", [rows[0].ID], "KIn", "0.5")));
                Check(validCoefficient.OpeningProperties.Rows.Single(row => row.ID == rows[0].ID)
                        .Errors!["KInString"].Length == 0,
                    "Invariant wire values use the source textbox culture during validation: " + culture);
                GeometryCulvertSnapshot invalidCoefficient = await ModelEditorAdapter.EditGeometryCulvertsAsync(new(model,
                    loaded.Revision, loaded.DraftState, new("setField", "openingProperties", [rows[0].ID], "KIn", "1.5")));
                Check(invalidCoefficient.OpeningProperties.Rows.Single(row => row.ID == rows[0].ID)
                        .Errors!["KInString"].Length != 0,
                    "Original absolute bounds remain enforced for comma and decimal-point cultures: " + culture);
            }
        }
        finally { CultureInfo.CurrentCulture = priorCulture; }

        GeometryCulvertSnapshot resetIn = await ModelEditorAdapter.EditGeometryCulvertsAsync(new(model,
            loaded.Revision, loaded.DraftState,
            new("resetOpeningCoefficient", "openingProperties", selectedIDs, FieldID: "KIn")));
        Check(resetIn.IsDirty
            && selectedIDs.All(id => resetIn.OpeningProperties.Rows.Single(row => row.ID == id).Values["KIn"] == string.Empty)
            && selectedIDs.All(id => resetIn.OpeningProperties.Rows.Single(row => row.ID == id).Values["KOut"] != string.Empty)
            && resetIn.OpeningProperties.Rows.Single(row => row.Values["Name"] == "Unselected").Values["KIn"] == "0.75",
            "The typed KIn reset writes NaN through source observables only for the selected opening-property identities and keeps source display blank");

        GeometryCulvertSnapshot undone = await ModelEditorAdapter.EditGeometryCulvertsAsync(new(model,
            resetIn.Revision, resetIn.DraftState, new("undo", "openingProperties", [])));
        Check(!undone.IsDirty
            && undone.OpeningProperties.Rows.Single(row => row.Values["Name"] == "First").Values["KIn"] == "0.25"
            && undone.OpeningProperties.Rows.Single(row => row.Values["Name"] == "Second").Values["KIn"] == "0.5",
            "Undo removes the typed NaN reset from the parent's replayable geometry draft");

        GeometryCulvertSnapshot resetOut = await ModelEditorAdapter.EditGeometryCulvertsAsync(new(model,
            undone.Revision, undone.DraftState,
            new("resetOpeningCoefficient", "openingProperties", selectedIDs, FieldID: "KOut")));
        Check(selectedIDs.All(id => resetOut.OpeningProperties.Rows.Single(row => row.ID == id).Values["KOut"] == string.Empty)
            && selectedIDs.All(id => resetOut.OpeningProperties.Rows.Single(row => row.ID == id).Values["KIn"] != string.Empty)
            && resetOut.OpeningProperties.Rows.Single(row => row.Values["Name"] == "Unselected").Values["KOut"] == "0.85",
            "The typed KOut reset is independently scoped to selected opening-property rows");

        await Expect<ArgumentException>(() => ModelEditorAdapter.EditGeometryCulvertsAsync(new(model,
            loaded.Revision, loaded.DraftState,
            new("resetOpeningCoefficient", "barrelProperties", selectedIDs, FieldID: "KIn"))));
        await Expect<ArgumentException>(() => ModelEditorAdapter.EditGeometryCulvertsAsync(new(model,
            loaded.Revision, loaded.DraftState,
            new("resetOpeningCoefficient", "openingProperties", selectedIDs, FieldID: "Name"))));
        await Expect<ArgumentException>(() => ModelEditorAdapter.EditGeometryCulvertsAsync(new(model,
            loaded.Revision, loaded.DraftState,
            new("setField", "openingProperties", [rows[0].ID], "KIn", "NaN"))));

        ModelSnapshot parentBaseline = await ModelEditorAdapter.LoadAsync(new ModelRequest(
            assetPath, "Geometry", projectPath, File.ReadAllText(projectPath)));
        ModelSnapshot saved = await ModelEditorAdapter.SaveAsync(new ModelSaveRequest(assetPath, "Geometry",
            projectPath, parentBaseline.Revision, new(), new(), ProjectXml: File.ReadAllText(projectPath),
            GeometryCulvertState: resetOut.DraftState));
        GeometryCulvertSnapshot persisted = await ModelEditorAdapter.LoadGeometryCulvertsAsync(new(model, saved.Revision));
        Check(selectedIDs.All(id => persisted.OpeningProperties.Rows.Single(row => row.ID == id).Values["KOut"] == string.Empty)
            && persisted.OpeningProperties.Rows.Single(row => row.ID == selectedIDs[0]).Values["KIn"] == "0.25"
            && persisted.OpeningProperties.Rows.Single(row => row.ID == selectedIDs[1]).Values["KIn"] == "0.5"
            && persisted.OpeningProperties.Rows.Single(row => row.Values["Name"] == "Unselected").Values["KOut"] == "0.85"
            && File.ReadAllBytes(projectPath).SequenceEqual(projectXmlBytes),
            "The parent model save persists selected KOut resets as NaN, preserves KIn and unselected rows, and leaves project XML bytes unchanged");
    }

    private static void Check(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }

    private static async Task Expect<TException>(Func<Task> operation) where TException : Exception
    {
        try { await operation(); }
        catch (TException) { return; }
        throw new InvalidOperationException("Expected " + typeof(TException).Name + ".");
    }
}
