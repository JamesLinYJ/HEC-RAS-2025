using System.Security.Cryptography;
using System.Text.Json;
using Ras.Backend;
using Ras.Layers;
using Utility.Units;

internal static class DisplayUnitChoiceChecks
{
    internal static async Task Run()
    {
        using var temporary = new TemporaryDirectory();
        var si = await LoadSpatialUnits(temporary.FullName, "SI", UnitSystem.SI);
        var us = await LoadSpatialUnits(temporary.FullName, "US", UnitSystem.USCustomary);

        VerifyPressureChoices(si.Pressure);
        VerifyPressureChoices(us.Pressure);
        VerifyWindChoices(si.Wind);
        VerifyWindChoices(us.Wind);
        Check(si.Pressure.SourceId == us.Pressure.SourceId &&
              si.Pressure.SelectionId == us.Pressure.SelectionId &&
              si.Pressure.SourceUnitTypeId == us.Pressure.SourceUnitTypeId &&
              si.Pressure.Choices.SequenceEqual(us.Pressure.Choices),
            "The retained air-pressure family remains the same mbar-based choice family for SI and US projects");
        Check(si.Wind.SourceId == us.Wind.SourceId &&
              si.Wind.SelectionId == us.Wind.SelectionId &&
              si.Wind.SourceUnitTypeId == us.Wind.SourceUnitTypeId &&
              si.Wind.Choices.SequenceEqual(us.Wind.Choices),
            "The retained wind family remains the same m/s-based choice family for SI and US projects");
        Check(si.Height.SourceId == Length.Meters.Name && us.Height.SourceId == Length.Feet.Name,
            "Project units still select the actual SI or US station-height storage unit");

        var encoded = JsonSerializer.Serialize(si.Pressure, BackendJson.Options);
        using (var document = JsonDocument.Parse(encoded))
        {
            JsonElement choices = document.RootElement.GetProperty("choices");
            foreach (JsonElement choice in choices.EnumerateArray())
                Check(choice.GetProperty("name").GetString() == choice.GetProperty("id").GetString(),
                    "The wire response includes source BaseUnitType.Name without changing the existing ID symbol");
        }

        using (var document = JsonDocument.Parse(JsonSerializer.Serialize(si.Wind, BackendJson.Options)))
        {
            JsonElement root = document.RootElement;
            Check(root.GetProperty("sourceId").GetString() == WindSpeed.MetersPerSecond.Name &&
                  root.GetProperty("selectionId").GetString() == "wind" &&
                  root.GetProperty("sourceUnitTypeId").GetString() == si.Wind.SourceUnitTypeId,
                "The wire wind metadata preserves m/s storage, wind selection scope and the typed source unit ID");
            foreach (JsonElement choice in root.GetProperty("choices").EnumerateArray())
                Check(choice.GetProperty("name").GetString() == choice.GetProperty("id").GetString() &&
                      !string.IsNullOrEmpty(choice.GetProperty("unitTypeId").GetString()),
                    "Every serialized wind choice retains its source symbol and typed target unit ID");
        }

        var legacy = JsonSerializer.Deserialize<DisplayUnitChoice>(
            """{"id":"mb","scale":1,"offset":0,"unitTypeId":"Utility.Units.AirPressure::mb"}""",
            BackendJson.Options);
        Check(legacy is { Id: "mb", Name: null },
            "Older display-unit payloads that omit the optional name remain readable");
        Console.WriteLine("Display-unit choices preserve retained unit names, IDs, affine conversions and read-only source HDF bytes for SI and US boundary models.");
    }

    private static async Task<SpatialUnitsSnapshot> LoadSpatialUnits(string directory, string suffix, UnitSystem system)
    {
        // Source model collections live beside the project; isolate SI and
        // US projects so equal model names do not address the same HDF file.
        string projectDirectory = Path.Combine(directory, suffix);
        Directory.CreateDirectory(projectDirectory);
        string projectPath = Path.Combine(projectDirectory, suffix + "-units.ras");
        var project = Project.CreateNew(projectPath, system);
        var boundary = project.AddNewBoundaryCondition("Unit choices", new DateTime(2026, 10, 16, 8, 0, 0), TimeSpan.FromHours(1));
        project.Save();
        string assetPath = boundary.Filename;
        boundary.Dispose();

        byte[] originalAsset = File.ReadAllBytes(assetPath);
        byte[] originalProject = File.ReadAllBytes(projectPath);
        string originalAssetRevision = Hash(originalAsset);
        string originalProjectRevision = Hash(originalProject);
        ModelSnapshot snapshot = await ModelEditorAdapter.LoadAsync(new(assetPath, "Boundary Conditions", projectPath));
        var spatial = snapshot.Boundary?.Spatial ?? throw new InvalidOperationException("Spatial boundary unit choices were not returned.");
        var pressure = spatial["airPressure"].ValueUnits;
        var wind = spatial["wind"].ValueUnits;
        var height = spatial["airPressure"].HeightUnits;

        Check(Hash(File.ReadAllBytes(assetPath)) == originalAssetRevision && Hash(File.ReadAllBytes(projectPath)) == originalProjectRevision,
            "Loading spatial display choices does not save or rewrite the source HDF or project XML");
        return new(pressure, wind, height);
    }

    private static void VerifyPressureChoices(DisplayUnitData data)
    {
        BaseUnitType source = AirPressure.MilliBars;
        BaseUnitType[] family = BaseUnitType.GetAvailableTypesBase(typeof(AirPressure)).ToArray();
        var choices = data.Choices;
        Check(data.SourceId == source.Name && data.SelectionId == "airPressure" &&
              data.SourceUnitTypeId == UnitCalculatorService.Load(new(null)).FromUnits
                  .Single(unit => unit.UnitTypeName == nameof(AirPressure) && unit.Name == source.Name).Id,
            "The source pressure choice retains its canonical mbar storage identity and selection scope");
        Check(choices.Length == family.Length && choices.Select(choice => choice.Id).SequenceEqual(family.Select(unit => unit.Name)),
            "Pressure choices preserve the source BaseUnitType family order and symbols");

        foreach (var (choice, unit) in choices.Zip(family))
        {
            string expectedID = UnitCalculatorService.Load(new(choice.UnitTypeId)).ToUnits
                .Single(target => target.Name == unit.Name).Id;
            Check(choice.Name == unit.Name && choice.Id == unit.Name && choice.UnitTypeId == expectedID,
                "Each choice exposes the exact source unit name, unchanged symbol and registered source type ID");

            List<double> converted = source.TryConvertTo(unit, new double[] { 0, 1, 2 });
            double offset = converted[0];
            double scale = converted[1] - offset;
            Check(Math.Abs(choice.Offset - offset) < 1e-12 && Math.Abs(choice.Scale - scale) < 1e-12 &&
                  Math.Abs(converted[2] - (offset + 2 * scale)) < Math.Abs(scale) * 1e-12,
                "Pressure display scale and offset match the retained BaseUnitType affine conversion");
        }

        Check(Approximately(choices.Single(choice => choice.Id == "Pa").Scale, 100) &&
              Approximately(choices.Single(choice => choice.Id == "kPa").Scale, 0.1) &&
              Approximately(choices.Single(choice => choice.Id == "mmHg").Scale, 100.0 / 133.322) &&
              Approximately(choices.Single(choice => choice.Id == "mb").Scale, 1),
            "The source mbar family retains Pascal, kilopascal, mercury and mbar affine scales");
    }

    private static void VerifyWindChoices(DisplayUnitData data)
    {
        BaseUnitType source = WindSpeed.MetersPerSecond;
        BaseUnitType[] family = BaseUnitType.GetAvailableTypesBase(typeof(WindSpeed)).ToArray();
        var choices = data.Choices;
        string sourceTypeId = UnitCalculatorService.Load(new(null)).FromUnits
            .Single(unit => unit.UnitTypeName == nameof(WindSpeed) && unit.Name == source.Name).Id;
        Check(data.SourceId == source.Name && data.SelectionId == "wind" && data.SourceUnitTypeId == sourceTypeId,
            "Wind component display metadata retains the pinned m/s source unit and wind selection identity");
        Check(choices.Length == family.Length && choices.Select(choice => choice.Id).SequenceEqual(family.Select(unit => unit.Name)),
            "Wind display choices preserve the retained WindSpeed family order and unit symbols");

        foreach (var (choice, unit) in choices.Zip(family))
        {
            string expectedID = UnitCalculatorService.Load(new(choice.UnitTypeId)).ToUnits
                .Single(target => target.Name == unit.Name).Id;
            Check(choice.Name == unit.Name && choice.Id == unit.Name && choice.UnitTypeId == expectedID,
                "Each wind choice exposes the exact source unit name, unchanged symbol and registered typed-unit ID");

            List<double> converted = source.TryConvertTo(unit, new double[] { 0, 1, 2 });
            double offset = converted[0], scale = converted[1] - offset;
            Check(Math.Abs(choice.Offset - offset) < 1e-12 && Math.Abs(choice.Scale - scale) < 1e-12 &&
                  Math.Abs(converted[2] - (offset + 2 * scale)) < Math.Abs(scale) * 1e-12,
                "Wind display scale and offset match the retained BaseUnitType affine conversion");
        }

        Check(choices.Single(choice => choice.Id == source.Name).Scale == 1 &&
              choices.Single(choice => choice.Id == source.Name).Offset == 0 &&
              choices.Any(choice => choice.Id == "ft/s"),
            "Wind choices include the unchanged m/s storage value and a physical feet-per-second display choice");
    }

    private static bool Approximately(double left, double right) => Math.Abs(left - right) <= Math.Abs(right) * 1e-12;
    private static string Hash(byte[] bytes) => Convert.ToHexString(SHA256.HashData(bytes));
    private static void Check(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }

    private sealed record SpatialUnitsSnapshot(DisplayUnitData Pressure, DisplayUnitData Wind, DisplayUnitData Height);
}
