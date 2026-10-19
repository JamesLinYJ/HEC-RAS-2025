using Ras.Backend;
using Ras.Layers;
using Utility.Units;

internal static class PlanEditorChecks
{
    internal static async Task Run()
    {
        using var directory = new TemporaryDirectory();
        string projectPath = Path.Combine(directory.FullName, "测试工程.ras");
        var project = Project.CreateNew(projectPath, UnitSystem.SI);
        string path;
        using (var plan = project.AddNewPlan("计划一"))
        {
            path = plan.Filename;
            var image = plan.EmbeddedImages.Add("原图.png", "保留说明", Convert.FromBase64String("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+j6LkAAAAASUVORK5CYII="));
            image.X = 12.5; image.Y = 6.25;
            plan.Save();
            plan.UseWriter(writer => writer.WriteAttribute("/Plan Data", "Unknown Editor Metadata", "保留"));
            project.Save();
        }
        var request = new ModelRequest(path, "Plan", projectPath);
        var loaded = await ModelEditorAdapter.LoadAsync(request);
        Check(loaded.CanEdit && loaded.Fields["PlanCatalogSummary/Context_Name"] == "计划一", "Adapter loads the actual named source plan");
        const string imageKey = "PlanSettingsPage/ViewModel_SelectedPlan_EmbeddedImages";
        var imageData = loaded.Images[imageKey];
        Check(imageData.Length == 1 && imageData[0].Name == "原图.png", "Adapter loads original HDF image identity and bytes");
        Dictionary<string, string> edits = new()
        {
            ["PlanSettingsPage/ViewModel_SelectedPlan_Description"] = "本机保存的中文计划",
            ["PlanSettingsPage/ViewModel_SelectedPlan_TimeWindowMode"] = "Plan",
            ["PlanSettingsPage/ViewModel_SelectedPlan_ComputeStartTime"] = "2026-10-15T08:00:00+08:00",
            ["PlanSettingsPage/ViewModel_SelectedPlan_ComputeEndTime"] = "2026-10-15T10:00:00+08:00",
            ["PlanSettingsPage/ViewModel_SelectedPlan_ComputeTimestep"] = "12.5",
            ["PlanComputeSettingsPage/ViewModel_SelectedPlan_CoreCount"] = "4"
        };
        var saved = await ModelEditorAdapter.SaveAsync(new(path, "Plan", projectPath, loaded.Revision, edits, new() { [imageKey] = imageData }));
        Check(saved.Revision != loaded.Revision && saved.Fields["PlanSettingsPage/ViewModel_SelectedPlan_ComputeTimestep"] == "12.5", "Source setters persist real HDF parameters and return a new revision");
        using (var actual = new Plan(path))
        {
            Check(actual.Description == "本机保存的中文计划" && actual.ComputeTimestep.TotalSeconds == 12.5 && actual.CoreCount == 4, "Independent original source readback sees edited values");
            actual.UseReader(reader => Check(reader.TryReadStringAttributeScalar("/Plan Data", "Unknown Editor Metadata") == "保留", "Transactional edit retains unknown HDF metadata"));
            Check(actual.EmbeddedImages.Images.Single().Description == "保留说明" && actual.EmbeddedImages.Images[0].X == 12.5, "Retained image metadata survives saving");
        }
        await Expect<SourceFileChangedException>(() => ModelEditorAdapter.SaveAsync(new(path, "Plan", projectPath, loaded.Revision, edits, [])));
        await Expect<ArgumentException>(() => ModelEditorAdapter.SaveAsync(new(path, "Plan", projectPath, saved.Revision,
            new() { ["PlanSettingsPage/ViewModel_SelectedPlan_ComputeTimestep"] = "NaN" }, [])));
        var unchanged = await ModelEditorAdapter.LoadAsync(request);
        Check(unchanged.Revision == saved.Revision, "Rejected input does not alter the source file");
        if (Environment.GetEnvironmentVariable("HECRAS_EDITOR_ACCEPTANCE_DIRECTORY") is string fixture)
        {
            if (Directory.Exists(fixture)) throw new IOException("Acceptance fixture destination already exists.");
            Directory.CreateDirectory(fixture);
            foreach (string folder in Directory.EnumerateDirectories(directory.FullName, "*", SearchOption.AllDirectories))
                Directory.CreateDirectory(Path.Combine(fixture, Path.GetRelativePath(directory.FullName, folder)));
            foreach (string file in Directory.EnumerateFiles(directory.FullName, "*", SearchOption.AllDirectories))
                File.Copy(file, Path.Combine(fixture, Path.GetRelativePath(directory.FullName, file)));
        }
        var cleared = await ModelEditorAdapter.SaveAsync(new(path, "Plan", projectPath, saved.Revision, [], new() { [imageKey] = [] }));
        Check(cleared.Images[imageKey].Length == 0, "Image deletion removes the actual HDF dataset");
        Check(!Directory.EnumerateFiles(Path.GetDirectoryName(path)!, ".model-edit-*.pending").Any(), "Successful and failed writes leave no staging files");
        Console.WriteLine("Source plan editor HDF read/edit/save, image metadata/removal, revision conflict and failed-write preservation checks passed.");
    }
    private static void Check(bool condition, string message)
    { if (!condition) throw new InvalidOperationException(message); }
    private static async Task Expect<T>(Func<Task<ModelSnapshot>> action) where T : Exception
    {
        try { await action(); }
        catch (T) { return; }
        throw new InvalidOperationException("Expected " + typeof(T).Name);
    }
}
