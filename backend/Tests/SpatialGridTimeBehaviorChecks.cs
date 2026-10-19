using System.Security.Cryptography;
using System.Text.Json;
using Ras.Backend;
using Ras.Layers;
using Utility.Units;

internal static class SpatialGridTimeBehaviorChecks
{
    internal static async Task Run()
    {
        var forwards = new SpatialGridSelection("airPressure", [], "mb", "inst-val")
        {
            TimeBehavior = SpatialGridTimeBehavior.ProjectForwards
        };
        string encoded = JsonSerializer.Serialize(forwards, BackendJson.Options);
        var roundTrip = JsonSerializer.Deserialize<SpatialGridSelection>(encoded, BackendJson.Options)
            ?? throw new InvalidOperationException("Spatial grid selection did not round-trip.");
        using var document = JsonDocument.Parse(encoded);
        Check(roundTrip.TimeBehavior == SpatialGridTimeBehavior.ProjectForwards
            && document.RootElement.GetProperty("timeBehavior").GetString() == "ProjectForwards",
            "The gridImport contract preserves the selected source enum value");

        const string legacyJson = "{\"layerId\":\"airPressure\",\"bands\":[],\"units\":\"mb\",\"dataType\":\"inst-val\"}";
        var legacy = JsonSerializer.Deserialize<SpatialGridSelection>(legacyJson, BackendJson.Options)
            ?? throw new InvalidOperationException("Legacy spatial grid selection did not deserialize.");
        Check(legacy.TimeBehavior == SpatialGridTimeBehavior.ProjectBackwards,
            "Requests that omit the new option retain the source enum zero-value default");

        using var temporary = new TemporaryDirectory();
        string projectPath = Path.Combine(temporary.FullName, "time-behavior.ras");
        var project = Project.CreateNew(projectPath, UnitSystem.SI);
        var boundary = project.AddNewBoundaryCondition("Time Behavior", new DateTime(2026, 10, 16, 8, 0, 0), TimeSpan.FromHours(1));
        project.Save();
        string assetPath = boundary.Filename;
        boundary.Dispose();
        var snapshot = await ModelEditorAdapter.LoadAsync(new(assetPath, "Boundary Conditions", projectPath));
        var request = new ModelSaveRequest(assetPath, "Boundary Conditions", projectPath, snapshot.Revision,
            new Dictionary<string, string>(), new Dictionary<string, ImageData[]>(), SourceState: snapshot.SourceState);
        string before = Convert.ToHexString(SHA256.HashData(await File.ReadAllBytesAsync(assetPath)));
        await Reject<ArgumentException>(() => ModelEditorAdapter.ImportGridAsync(new(request,
            forwards with { TimeBehavior = (SpatialGridTimeBehavior)99 })));
        string after = Convert.ToHexString(SHA256.HashData(await File.ReadAllBytesAsync(assetPath)));
        Check(after == before, "Unknown time behavior values reject before the staged import is published");
    }

    private static void Check(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }

    private static async Task Reject<T>(Func<Task> operation) where T : Exception
    {
        try { await operation(); }
        catch (T) { return; }
        throw new InvalidOperationException("Expected " + typeof(T).Name);
    }
}
