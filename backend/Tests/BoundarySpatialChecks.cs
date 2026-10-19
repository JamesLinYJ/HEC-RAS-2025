using System.ComponentModel.DataAnnotations;
using Ras.Backend;
using Ras.Layers;
using Utility.Units;

internal static class BoundarySpatialChecks
{
    internal static async Task Run()
    {
        using var temporary = new TemporaryDirectory();
        string projectPath = Path.Combine(temporary.FullName, "空间边界.ras");
        var project = Project.CreateNew(projectPath, UnitSystem.SI);
        var boundary = project.AddNewBoundaryCondition("真实气象", new DateTime(2026, 10, 15), TimeSpan.FromDays(1));
        Check(!boundary.AirPressure.IsEnabled && !boundary.AirDensity.IsEnabled && boundary.AirPressure.ConstantValue == 1013.2f && boundary.AirDensity.ConstantValue == 1.225f,
            "New source defaults do not enable meteorology while constructing a model or its observer");
        boundary.AirPressure.ConstantValue = 902.25f; boundary.AirPressure.SpatialDataType = SpatialDataType.Point; boundary.AirPressure.IsEnabled = false;
        boundary.AirDensity.ConstantValue = 1.13f; boundary.AirDensity.SpatialDataType = SpatialDataType.Gridded; boundary.AirDensity.IsEnabled = false;
        project.Save(); string filename = boundary.Filename; boundary.Dispose();
        var request = new ModelRequest(filename, "Boundary Conditions", projectPath);
        var loaded = await ModelEditorAdapter.LoadAsync(request);
        Check(loaded.Fields["AirPressureControl/AirPressureLayer_ConstantValue"] == "902.25"
            && loaded.Fields["AirPressureControl/AirPressureLayer_SpatialDataType"] == "Point"
            && loaded.Fields["AirPressureControl/AirPressureLayer_IsEnabled"] == "false"
            && loaded.Fields["AirDensityControl/AirDensityLayer_ConstantValue"] == "1.13"
            && loaded.Fields["AirDensityControl/AirDensityLayer_SpatialDataType"] == "Gridded"
            && loaded.Fields["AirDensityControl/AirDensityLayer_IsEnabled"] == "false", "Constructing observable wrappers must retain persisted constants, modes and enablement");
        var saved = await ModelEditorAdapter.SaveAsync(new(filename, request.Kind, projectPath, loaded.Revision,
            new() { ["BoundaryConditionsSummary/BoundaryCondition_Description"] = "只编辑说明" }, []));
        Check(saved.Fields["AirDensityControl/AirDensityLayer_ConstantValue"] == "1.13" && saved.Fields["AirPressureControl/AirPressureLayer_SpatialDataType"] == "Point",
            "Unrelated metadata saves preserve meteorology");
        var changes = new Dictionary<string, string> {
            ["PrecipitationControl/PrecipitationLayer_ConstantValue"] = "0.0025", ["PrecipitationControl/PrecipitationLayer_Ratio"] = "1.25",
            ["PrecipitationControl/PrecipitationLayer_IsEnabled"] = "true", ["PrecipitationControl/PrecipitationLayer_SpatialDataType"] = "Constant",
            ["EvapotranspirationControl/EvapotranspirationLayer_ConstantValue"] = "0.0004", ["EvapotranspirationControl/EvapotranspirationLayer_Ratio"] = "0.75",
            ["EvapotranspirationControl/EvapotranspirationLayer_IsEnabled"] = "true", ["EvapotranspirationControl/EvapotranspirationLayer_SpatialDataType"] = "Constant",
            ["WindConstantControl/Constant1"] = "3.5", ["WindConstantControl/Constant2"] = "-2.5", ["WindForcesControl/WindLayer_Ratio"] = "0.9",
            ["WindForcesControl/WindLayer_IsEnabled"] = "true", ["WindForcesControl/WindLayer_SpatialDataType"] = "Constant",
            ["AirPressureControl/AirPressureLayer_ConstantValue"] = "1000.125", ["AirPressureControl/AirPressureLayer_IsEnabled"] = "false", ["AirPressureControl/AirPressureLayer_SpatialDataType"] = "Constant",
            ["AirDensityControl/AirDensityLayer_ConstantValue"] = "1.2", ["AirDensityControl/AirDensityLayer_Ratio"] = "1.1",
            ["AirDensityControl/AirDensityLayer_IsEnabled"] = "true", ["AirDensityControl/AirDensityLayer_SpatialDataType"] = "Constant"
        };
        saved = await ModelEditorAdapter.SaveAsync(new(filename, request.Kind, projectPath, saved.Revision, changes, []));
        Check(changes.All(pair => saved.Fields[pair.Key] == pair.Value), "Five spatial control groups roundtrip through retained source setters and actual HDF");
        Check(!saved.FieldGroups.Values.Any(group => group.Any(key => key.StartsWith("PrecipitationControl/", StringComparison.Ordinal)) && group.Any(key => key.StartsWith("WindForcesControl/", StringComparison.Ordinal))),
            "Equal property names on different spatial layers must not be linked");
        using (var reread = new BoundaryCondition(filename, project))
        {
            Check(reread.Precipitation.ConstantValue == .0025f && reread.Evapotranspiration.ConstantValue == .0004f
                && reread.Wind.ConstantVx == 3.5f && reread.Wind.ConstantVy == -2.5f && !reread.AirPressure.IsEnabled && reread.AirPressure.ConstantValue == 1000.125f
                && reread.AirDensity.IsEnabled && reread.AirDensity.ConstantValue == 1.2f, "Independent source reader verifies numeric values and explicit disabled state after constant edits");
        }
        byte[] before = File.ReadAllBytes(filename);
        await Reject<ArgumentException>(new() { ["PrecipitationControl/PrecipitationLayer_ConstantValue"] = "1e50" });
        await Reject<ArgumentException>(new() { ["WindConstantControl/Constant1"] = "NaN" });
        await Reject<ValidationException>(new() { ["EvapotranspirationControl/EvapotranspirationLayer_SpatialDataType"] = "Gridded" });
        Check(File.ReadAllBytes(filename).SequenceEqual(before), "Rejected spatial values leave source HDF bytes intact");
        Check(!Directory.EnumerateFiles(temporary.FullName, ".model-edit-*.pending", SearchOption.AllDirectories).Any(), "Rejected edits clean their staging files");
        Console.WriteLine("Five spatial boundary groups, constant wind components, HDF reread, cross-layer identity, safe defaults and rejected values passed.");
        async Task Reject<T>(Dictionary<string, string> fields) where T : Exception
        {
            try { await ModelEditorAdapter.SaveAsync(new(filename, request.Kind, projectPath, saved.Revision, fields, [])); }
            catch (T) { return; }
            throw new InvalidOperationException("Expected " + typeof(T).Name);
        }
    }
    private static void Check(bool condition, string message) { if (!condition) throw new InvalidOperationException(message); }
}
