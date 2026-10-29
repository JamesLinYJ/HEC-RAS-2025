using Ras.Backend;
using Geospatial;
using Geospatial.Vectors;
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
        geometry.BarrelPropertiesLayer.Add(new BarrelProperties
        {
            Name = "Barrel A", Rise = 1, Span = 1, Shape = BarrelShape.Circle, Mannings = .025,
            ManningsSwitchDepth = .1, DepthBlocked = 0
        });
        geometry.BarrelPropertiesLayer.Add(new BarrelProperties
        {
            Name = "Barrel B", Rise = 1.2, Span = 1.2, Shape = BarrelShape.Circle, Mannings = .025,
            ManningsSwitchDepth = .1, DepthBlocked = 0
        });
        geometry.BarrelPropertiesLayer.Add(new BarrelProperties
        {
            Name = "Barrel C", Rise = 1.4, Span = 1.4, Shape = BarrelShape.Circle, Mannings = .025,
            ManningsSwitchDepth = .1, DepthBlocked = 0
        });
        geometry.OpeningPropertiesLayer.Add(new OpeningProperties { Name = "First", KIn = .25, KOut = .35 });
        geometry.OpeningPropertiesLayer.Add(new OpeningProperties { Name = "Second", KIn = .5, KOut = .65,
            OpeningType = BarrelOpeningType.CorrugatedMetalPipeCulvert_Headwall });
        geometry.OpeningPropertiesLayer.Add(new OpeningProperties { Name = "Unselected", KIn = .75, KOut = .85 });
        geometry.CulvertBarrelLayer.Add(new CulvertBarrel
        {
            Name = "First barrel", Polyline = BarrelLine(1), BarrelPropertyName = "Barrel A",
            UpstreamInvert = 10, DownstreamInvert = 9, UpstreamOpeningName = "First", DownstreamOpeningName = "First"
        });
        geometry.CulvertBarrelLayer.Add(new CulvertBarrel
        {
            Name = "Second barrel", Polyline = BarrelLine(2), BarrelPropertyName = "Barrel B",
            UpstreamInvert = 20, DownstreamInvert = 19, UpstreamOpeningName = "Second", DownstreamOpeningName = "Second"
        });
        geometry.CulvertBarrelLayer.Add(new CulvertBarrel
        {
            Name = "Unselected barrel", Polyline = BarrelLine(3), BarrelPropertyName = "Barrel C",
            UpstreamInvert = 30, DownstreamInvert = 29, UpstreamOpeningName = "Unselected", DownstreamOpeningName = "Unselected"
        });
        project.Save();
        geometry.Save();
        string assetPath = geometry.Filename;
        geometry.Dispose();
        byte[] projectXmlBytes = File.ReadAllBytes(projectPath);
        byte[] sourceGeometryBytes = File.ReadAllBytes(assetPath);

        var model = new GeometryCulvertModelRequest(assetPath, "Geometry", projectPath, File.ReadAllText(projectPath));
        GeometryCulvertSnapshot loaded = await ModelEditorAdapter.LoadGeometryCulvertsAsync(new(model));
        GeometryCulvertFeatureRow[] rows = loaded.OpeningProperties.Rows;
        string[] selectedIDs = rows.Take(2).Select(row => row.ID).ToArray();
        GeometryCulvertFeatureRow[] barrelRows = loaded.Barrels.Rows;
        string[] selectedBarrelIDs = barrelRows.Take(2).Select(row => row.ID).ToArray();
        Check(barrelRows.Length == 3 && selectedBarrelIDs.Length == 2,
            "The fixture has two mixed selected barrels and one unselected barrel");
        var barrelAssociationChoices = new[]
        {
            (FieldID: "BarrelPropertyName", Value: "Barrel A", First: "Barrel A", Second: "Barrel B", Unselected: "Barrel C"),
            (FieldID: "UpstreamOpeningName", Value: "First", First: "First", Second: "Second", Unselected: "Unselected"),
            (FieldID: "DownstreamOpeningName", Value: "First", First: "First", Second: "Second", Unselected: "Unselected")
        };
        GeometryCulvertSnapshot associationUndoBaseline = loaded;
        foreach (var choice in barrelAssociationChoices)
        {
            GeometryCulvertSnapshot applied = await ModelEditorAdapter.EditGeometryCulvertsAsync(new(model,
                associationUndoBaseline.Revision, associationUndoBaseline.DraftState,
                new("setField", "barrel", selectedBarrelIDs, choice.FieldID, choice.Value)));
            Check(selectedBarrelIDs.All(id => applied.Barrels.Rows.Single(row => row.ID == id).Values[choice.FieldID] == choice.Value)
                && applied.Barrels.Rows.Single(row => row.ID == barrelRows[2].ID).Values[choice.FieldID] == choice.Unselected,
                "A mixed association choice explicitly applies the first row's value to every selected barrel and leaves other rows unchanged: " + choice.FieldID);
            Check(File.ReadAllBytes(assetPath).SequenceEqual(sourceGeometryBytes)
                && File.ReadAllBytes(projectPath).SequenceEqual(projectXmlBytes),
                "Staging a selected barrel association does not change the source geometry file");

            GeometryCulvertSnapshot undo = await ModelEditorAdapter.EditGeometryCulvertsAsync(new(model,
                applied.Revision, applied.DraftState, new("undo", "barrel", [])));
            Check(!undo.IsDirty
                && undo.Barrels.Rows.Single(row => row.ID == selectedBarrelIDs[0]).Values[choice.FieldID] == choice.First
                && undo.Barrels.Rows.Single(row => row.ID == selectedBarrelIDs[1]).Values[choice.FieldID] == choice.Second
                && undo.Barrels.Rows.Single(row => row.ID == barrelRows[2].ID).Values[choice.FieldID] == choice.Unselected,
                "Undo restores the original mixed association values without changing the unselected row: " + choice.FieldID);
            Check(File.ReadAllBytes(assetPath).SequenceEqual(sourceGeometryBytes)
                && File.ReadAllBytes(projectPath).SequenceEqual(projectXmlBytes),
                "Undoing a selected barrel association leaves the source geometry file unchanged");
            associationUndoBaseline = undo;
        }
        GeometryCulvertSnapshot noneAssociation = await ModelEditorAdapter.EditGeometryCulvertsAsync(new(model,
            associationUndoBaseline.Revision, associationUndoBaseline.DraftState,
            new("setField", "barrel", selectedBarrelIDs, "UpstreamOpeningName", "")));
        Check(selectedBarrelIDs.All(id => noneAssociation.Barrels.Rows.Single(row => row.ID == id)
                .Values["UpstreamOpeningName"] == "")
            && noneAssociation.Barrels.Rows.Single(row => row.ID == barrelRows[2].ID)
                .Values["UpstreamOpeningName"] == "Unselected",
            "Choosing None explicitly clears the selected upstream associations while leaving the unselected row intact");
        GeometryCulvertSnapshot noneUndo = await ModelEditorAdapter.EditGeometryCulvertsAsync(new(model,
            noneAssociation.Revision, noneAssociation.DraftState, new("undo", "barrel", [])));
        Check(noneUndo.Barrels.Rows.Single(row => row.ID == selectedBarrelIDs[0]).Values["UpstreamOpeningName"] == "First"
            && noneUndo.Barrels.Rows.Single(row => row.ID == selectedBarrelIDs[1]).Values["UpstreamOpeningName"] == "Second"
            && File.ReadAllBytes(assetPath).SequenceEqual(sourceGeometryBytes),
            "Undo restores both associations after explicitly choosing None, without writing the source HDF");
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
        GeometryCulvertSnapshot associationFinal = resetOut;
        foreach (var choice in barrelAssociationChoices)
        {
            associationFinal = await ModelEditorAdapter.EditGeometryCulvertsAsync(new(model,
                associationFinal.Revision, associationFinal.DraftState,
                new("setField", "barrel", selectedBarrelIDs, choice.FieldID, choice.Value)));
        }
        Check(File.ReadAllBytes(assetPath).SequenceEqual(sourceGeometryBytes)
            && File.ReadAllBytes(projectPath).SequenceEqual(projectXmlBytes),
            "All selected-association edits remain staged until the parent geometry save");

        ModelSnapshot saved = await ModelEditorAdapter.SaveAsync(new ModelSaveRequest(assetPath, "Geometry",
            projectPath, parentBaseline.Revision, new(), new(), ProjectXml: File.ReadAllText(projectPath),
            GeometryCulvertState: associationFinal.DraftState));
        GeometryCulvertSnapshot persisted = await ModelEditorAdapter.LoadGeometryCulvertsAsync(new(model, saved.Revision));
        Check(selectedIDs.All(id => persisted.OpeningProperties.Rows.Single(row => row.ID == id).Values["KOut"] == string.Empty)
            && persisted.OpeningProperties.Rows.Single(row => row.ID == selectedIDs[0]).Values["KIn"] == "0.25"
            && persisted.OpeningProperties.Rows.Single(row => row.ID == selectedIDs[1]).Values["KIn"] == "0.5"
            && persisted.OpeningProperties.Rows.Single(row => row.Values["Name"] == "Unselected").Values["KOut"] == "0.85"
            && selectedBarrelIDs.All(id => persisted.Barrels.Rows.Single(row => row.ID == id).Values["BarrelPropertyName"] == "Barrel A")
            && selectedBarrelIDs.All(id => persisted.Barrels.Rows.Single(row => row.ID == id).Values["UpstreamOpeningName"] == "First")
            && selectedBarrelIDs.All(id => persisted.Barrels.Rows.Single(row => row.ID == id).Values["DownstreamOpeningName"] == "First")
            && persisted.Barrels.Rows.Single(row => row.ID == barrelRows[2].ID).Values["BarrelPropertyName"] == "Barrel C"
            && persisted.Barrels.Rows.Single(row => row.ID == barrelRows[2].ID).Values["UpstreamOpeningName"] == "Unselected"
            && persisted.Barrels.Rows.Single(row => row.ID == barrelRows[2].ID).Values["DownstreamOpeningName"] == "Unselected"
            && !File.ReadAllBytes(assetPath).SequenceEqual(sourceGeometryBytes)
            && File.ReadAllBytes(projectPath).SequenceEqual(projectXmlBytes),
            "The parent model save persists selected KOut resets and all three selected barrel choices, preserves unselected rows, and leaves project XML bytes unchanged");
    }

    private static void Check(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }

    private static Polyline BarrelLine(double y) =>
        new(new Point[] { new Point(0, y), new Point(10, y) });

    private static async Task Expect<TException>(Func<Task> operation) where TException : Exception
    {
        try { await operation(); }
        catch (TException) { return; }
        throw new InvalidOperationException("Expected " + typeof(TException).Name + ".");
    }
}
