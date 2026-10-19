using System.ComponentModel.DataAnnotations;
using System.Globalization;
using System.Xml.Linq;
using Ras.Backend;
using Ras.Layers;
using Utility.Units;

internal static class PlanContextRefreshChecks
{
    private const string DescriptionField = "PlanSettingsPage/ViewModel_SelectedPlan_Description";
    private const string ModeField = "PlanSettingsPage/ViewModel_SelectedPlan_TimeWindowMode";
    private const string StartField = "PlanSettingsPage/ViewModel_SelectedPlan_ComputeStartTime";
    private const string EndField = "PlanSettingsPage/ViewModel_SelectedPlan_ComputeEndTime";
    private const string ImageField = "PlanSettingsPage/ViewModel_SelectedPlan_EmbeddedImages";

    internal static async Task Run()
    {
        using var directory = new TemporaryDirectory();
        string projectPath = Path.Combine(directory.FullName, "Plan Context Refresh.ras");
        Project project = Project.CreateNew(projectPath, UnitSystem.SI);
        var firstBoundary = project.AddNewBoundaryCondition("Boundary A",
            new DateTime(2026, 10, 1, 0, 0, 0), new DateTime(2026, 10, 2, 0, 0, 0));
        var secondBoundary = project.AddNewBoundaryCondition("Boundary B",
            new DateTime(2026, 10, 3, 6, 0, 0), new DateTime(2026, 10, 4, 12, 0, 0));
        var plan = project.AddNewPlan("Plan A");
        string assetPath = plan.Filename;
        plan.Description = "Original description";
        plan.TimeWindowMode = PlanTimeWindowMode.BoundaryCondition;
        plan.InternalStartTime = new DateTime(2026, 10, 5, 8, 0, 0);
        plan.InternalComputeDurationSeconds = 6 * 60 * 60;
        plan.EmbeddedImages.Add("plan.png", "retained image", Convert.FromBase64String(
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+j6LkAAAAASUVORK5CYII="));
        project.GetPlanAssociation(plan).BoundaryCondition = firstBoundary;
        firstBoundary.Save();
        secondBoundary.Save();
        plan.Save();
        project.Save();
        string firstBoundaryPath = firstBoundary.Filename;
        string secondBoundaryPath = secondBoundary.Filename;
        plan.Dispose(); firstBoundary.Dispose(); secondBoundary.Dispose();

        ExportFixtureIfRequested(directory.FullName);

        var loaded = await ModelEditorAdapter.LoadAsync(new ModelRequest(assetPath, "Plan", projectPath));
        byte[] projectBytes = File.ReadAllBytes(projectPath);
        byte[] planBytes = File.ReadAllBytes(assetPath);
        byte[] firstBoundaryBytes = File.ReadAllBytes(firstBoundaryPath);
        byte[] secondBoundaryBytes = File.ReadAllBytes(secondBoundaryPath);

        XElement switchedProject = XElement.Load(projectPath);
        XElement association = Association(switchedProject);
        association.SetAttributeValue("BoundaryCondition", "Boundary B");
        string switchedProjectXml = switchedProject.ToString(SaveOptions.DisableFormatting);
        var draftFields = new Dictionary<string, string>
        {
            [DescriptionField] = "Unsaved plan description",
            [ModeField] = "Plan",
            [StartField] = "2026-10-06T07:00:00+00:00",
            [EndField] = "2026-10-07T19:30:00+00:00"
        };
        ModelSaveRequest switchedRequest = Request(loaded.Revision, switchedProjectXml, draftFields,
            new Dictionary<string, ImageData[]> { [ImageField] = [] });
        ModelContextRefreshResult refreshed = await ModelEditorAdapter.RefreshPlanContextAsync(switchedRequest);
        Check(refreshed.Baseline.Fields[DescriptionField] == "Original description" &&
              refreshed.Draft.Fields[DescriptionField] == "Unsaved plan description",
            "Baseline preserves saved plan values while draft applies unsaved field edits");
        Check(refreshed.Baseline.Fields[ModeField] == "BoundaryCondition" &&
              WallTime(refreshed.Baseline, StartField) == new DateTime(2026, 10, 3, 6, 0, 0) &&
              WallTime(refreshed.Baseline, EndField) == new DateTime(2026, 10, 4, 12, 0, 0),
            "Baseline dates inherit from the unsaved project association");
        Check(refreshed.Draft.Fields[ModeField] == "Plan" &&
              DateTimeOffset.Parse(refreshed.Draft.Fields[StartField], CultureInfo.InvariantCulture) ==
              DateTimeOffset.Parse(draftFields[StartField], CultureInfo.InvariantCulture) &&
              DateTimeOffset.Parse(refreshed.Draft.Fields[EndField], CultureInfo.InvariantCulture) ==
              DateTimeOffset.Parse(draftFields[EndField], CultureInfo.InvariantCulture),
            "Draft applies the source mode-before-window setter order");
        Check(refreshed.Baseline.Images[ImageField].Length == 1 && refreshed.Draft.Images[ImageField].Length == 1,
            "Image edits stay with the frontend and are not applied by a context refresh");
        Check(refreshed.Baseline.Revision == loaded.Revision && refreshed.Draft.Revision == loaded.Revision,
            "Both snapshots retain the unchanged source revision");
        CheckUnchanged(projectPath, projectBytes, assetPath, planBytes,
            firstBoundaryPath, firstBoundaryBytes, secondBoundaryPath, secondBoundaryBytes);

        XElement noBoundaryProject = XElement.Load(projectPath);
        Association(noBoundaryProject).Remove();
        ModelContextRefreshResult noBoundary = await ModelEditorAdapter.RefreshPlanContextAsync(
            Request(loaded.Revision, noBoundaryProject.ToString(SaveOptions.DisableFormatting), []));
        Check(noBoundary.Baseline.Fields[ModeField] == "BoundaryCondition" &&
              WallTime(noBoundary.Baseline, StartField) == new DateTime(2026, 10, 5, 8, 0, 0) &&
              WallTime(noBoundary.Baseline, EndField) == new DateTime(2026, 10, 5, 14, 0, 0),
            "Missing boundary association falls back to the source plan's internal time window");
        CheckUnchanged(projectPath, projectBytes, assetPath, planBytes,
            firstBoundaryPath, firstBoundaryBytes, secondBoundaryPath, secondBoundaryBytes);

        await Expect<ValidationException>(() => ModelEditorAdapter.RefreshPlanContextAsync(
            Request(loaded.Revision, switchedProjectXml, new Dictionary<string, string> { [StartField] = "2026-10-08T00:00:00+00:00" })));
        var invalidWindow = new Dictionary<string, string>
        {
            [ModeField] = "Plan",
            [StartField] = "2026-10-08T00:00:00+00:00",
            [EndField] = "2026-10-08T00:00:00+00:00"
        };
        await Expect<ValidationException>(() => ModelEditorAdapter.RefreshPlanContextAsync(
            Request(loaded.Revision, switchedProjectXml, invalidWindow)));
        var invalidOrderedWindow = new[]
        {
            WindowEdit("invalid-mode", ModeField, "Plan"),
            WindowEdit("invalid-start", StartField, "2026-10-08T00:00:00+00:00"),
            WindowEdit("invalid-end", EndField, "2026-10-08T00:00:00+00:00")
        };
        await Expect<ValidationException>(() => ModelEditorAdapter.RefreshPlanContextAsync(
            Request(loaded.Revision, switchedProjectXml, [], sourceState: loaded.SourceState,
                planTimeWindowEdits: invalidOrderedWindow)));
        await Expect<ArgumentException>(() => ModelEditorAdapter.RefreshPlanContextAsync(
            Request(loaded.Revision, switchedProjectXml, [], sourceState: "{invalid-json",
                planTimeWindowEdits: [])));
        await Expect<ArgumentException>(() => ModelEditorAdapter.SaveAsync(new ModelSaveRequest(assetPath, "Plan", projectPath,
            loaded.Revision, [], [], switchedProjectXml, "{invalid-json", PlanTimeWindowEdits: [])));
        await Expect<NotSupportedException>(() => ModelEditorAdapter.RefreshPlanContextAsync(
            Request(loaded.Revision, switchedProjectXml, [], rows: new Dictionary<string, ModelRow[]> { ["unused"] = [new("row", [])] })));
        await Expect<NotSupportedException>(() => ModelEditorAdapter.RefreshPlanContextAsync(
            Request(loaded.Revision, switchedProjectXml, [], samples: new Dictionary<string, ModelSample[]> { ["unused"] = [new("sample", 0, null, "series")] })));
        CheckUnchanged(projectPath, projectBytes, assetPath, planBytes,
            firstBoundaryPath, firstBoundaryBytes, secondBoundaryPath, secondBoundaryBytes);

        string unrelatedDirectory = Path.Combine(directory.FullName, "unrelated-project");
        Directory.CreateDirectory(unrelatedDirectory);
        var unrelatedProject = Project.CreateNew(Path.Combine(unrelatedDirectory, "Unrelated.ras"), UnitSystem.SI);
        unrelatedProject.Save();
        await Expect<ArgumentException>(() => ModelEditorAdapter.RefreshPlanContextAsync(
            Request(loaded.Revision, XElement.Load(unrelatedProject.Filename).ToString(SaveOptions.DisableFormatting), [], owningProjectPath: unrelatedProject.Filename)));

        // Keep this alias outside the exported fixture tree: it points back to
        // the fixture root, and recursive fixture copying must never traverse it.
        string aliasDirectory = Path.Combine(Path.GetDirectoryName(directory.FullName)!,
            "plan-context-refresh-alias-" + Guid.NewGuid().ToString("N"));
        Directory.CreateSymbolicLink(aliasDirectory, directory.FullName);
        try
        {
            await VerifyAliasedPaths(projectPath, Path.Combine(aliasDirectory, "Plans", "Plan A.h5"),
                "A symlinked asset parent resolves to the owning project's source plan");
            await VerifyAliasedPaths(Path.Combine(aliasDirectory, "Plan Context Refresh.ras"), assetPath,
                "A symlinked project parent resolves to the owning project's source plan");
        }
        finally
        {
            Directory.Delete(aliasDirectory);
        }

        // Apply a quick mode/date/mode sequence exactly as captured by SwiftUI.
        // The visible values end in BC mode, but the internal custom window must
        // survive the intervening inherited getters and appear when Plan returns.
        var orderedWindow = new[]
        {
            WindowEdit("custom-mode", ModeField, "Plan"),
            WindowEdit("custom-start", StartField, "2026-10-06T07:00:00+00:00"),
            WindowEdit("custom-end", EndField, "2026-10-07T19:30:00+00:00"),
            WindowEdit("inherited-mode", ModeField, "BoundaryCondition")
        };
        ModelContextRefreshResult quickToggle = await ModelEditorAdapter.RefreshPlanContextAsync(
            Request(loaded.Revision, switchedProjectXml,
                new Dictionary<string, string> { [DescriptionField] = "Ordered window draft" },
                sourceState: loaded.SourceState, planTimeWindowEdits: orderedWindow));
        Check(quickToggle.Baseline.Fields[ModeField] == "BoundaryCondition" &&
              WallTime(quickToggle.Baseline, StartField) == new DateTime(2026, 10, 3, 6, 0, 0),
            "The baseline is computed from the current project association and persisted HDF state");
        Check(quickToggle.Draft.Fields[ModeField] == "BoundaryCondition" &&
              WallTime(quickToggle.Draft, StartField) == new DateTime(2026, 10, 3, 6, 0, 0) &&
              WallTime(quickToggle.Draft, EndField) == new DateTime(2026, 10, 4, 12, 0, 0),
            "Ordered Plan-to-custom-date-to-BC events finish with inherited boundary dates");
        string inheritedState = quickToggle.Draft.SourceState
            ?? throw new InvalidOperationException("The refreshed plan must return canonical internal window state.");
        ModelContextRefreshResult switchedBack = await ModelEditorAdapter.RefreshPlanContextAsync(
            Request(loaded.Revision, switchedProjectXml, [], sourceState: inheritedState,
                planTimeWindowEdits: [WindowEdit("return-to-plan", ModeField, "Plan")]));
        Check(switchedBack.Draft.Fields[ModeField] == "Plan" &&
              DateTimeOffset.Parse(switchedBack.Draft.Fields[StartField], CultureInfo.InvariantCulture) ==
              DateTimeOffset.Parse("2026-10-06T07:00:00+00:00", CultureInfo.InvariantCulture) &&
              DateTimeOffset.Parse(switchedBack.Draft.Fields[EndField], CultureInfo.InvariantCulture) ==
              DateTimeOffset.Parse("2026-10-07T19:30:00+00:00", CultureInfo.InvariantCulture),
            "Switching back to Plan restores custom dates hidden by BC-mode getters");

        string customState = switchedBack.Draft.SourceState
            ?? throw new InvalidOperationException("The Plan draft must return canonical internal window state.");
        ModelSnapshot saved = await ModelEditorAdapter.SaveAsync(new ModelSaveRequest(assetPath, "Plan", projectPath,
            loaded.Revision, [], [], switchedProjectXml, customState, PlanTimeWindowEdits: []));
        ModelSnapshot reopened = await ModelEditorAdapter.LoadAsync(new ModelRequest(assetPath, "Plan", projectPath));
        Check(reopened.Fields[ModeField] == "Plan" &&
              DateTimeOffset.Parse(reopened.Fields[StartField], CultureInfo.InvariantCulture) ==
              DateTimeOffset.Parse("2026-10-06T07:00:00+00:00", CultureInfo.InvariantCulture) &&
              DateTimeOffset.Parse(reopened.Fields[EndField], CultureInfo.InvariantCulture) ==
              DateTimeOffset.Parse("2026-10-07T19:30:00+00:00", CultureInfo.InvariantCulture),
            "Saving and reopening persists the ordered custom window through source observables");
        Check(saved.Revision != loaded.Revision && saved.Revision == reopened.Revision &&
              saved.SourceState is not null && saved.PlanTimeWindowFieldIDs is not null &&
              File.ReadAllBytes(projectPath).SequenceEqual(projectBytes) &&
              File.ReadAllBytes(firstBoundaryPath).SequenceEqual(firstBoundaryBytes) &&
              File.ReadAllBytes(secondBoundaryPath).SequenceEqual(secondBoundaryBytes),
            "Saving the plan window does not write project XML or associated boundary models");

        using (var externallyEditedPlan = new Plan(assetPath))
        {
            externallyEditedPlan.Description = "External source change";
            externallyEditedPlan.Save();
        }
        byte[] externallyEditedBytes = File.ReadAllBytes(assetPath);
        await Expect<SourceFileChangedException>(() => ModelEditorAdapter.RefreshPlanContextAsync(
            Request(reopened.Revision, switchedProjectXml, [], sourceState: reopened.SourceState,
                planTimeWindowEdits: [])));
        Check(File.ReadAllBytes(assetPath).SequenceEqual(externallyEditedBytes) &&
              File.ReadAllBytes(projectPath).SequenceEqual(projectBytes),
            "A stale revision is rejected without further source or project writes");

        Console.WriteLine("Plan context refresh uses unsaved project associations and validates drafts without writing source files.");

        ModelSaveRequest Request(string revision, string projectXml, Dictionary<string, string> fields,
            Dictionary<string, ImageData[]>? images = null, Dictionary<string, ModelRow[]>? rows = null,
            Dictionary<string, ModelSample[]>? samples = null, string? owningProjectPath = null,
            string? sourceState = null, PlanTimeWindowEdit[]? planTimeWindowEdits = null) =>
            new(assetPath, "Plan", owningProjectPath ?? projectPath, revision, fields, images ?? [], projectXml,
                SourceState: sourceState, Rows: rows, Samples: samples, PlanTimeWindowEdits: planTimeWindowEdits);

        PlanTimeWindowEdit WindowEdit(string id, string field, string value) => new(id, field, value);

        async Task VerifyAliasedPaths(string requestProjectPath, string requestAssetPath, string message)
        {
            ModelSnapshot aliasLoaded = await ModelEditorAdapter.LoadAsync(
                new ModelRequest(requestAssetPath, "Plan", requestProjectPath));
            Check(aliasLoaded.Fields[ModeField] == "BoundaryCondition" &&
                  WallTime(aliasLoaded, StartField) == new DateTime(2026, 10, 1, 0, 0, 0),
                message + " on initial load");
            ModelContextRefreshResult aliasRefresh = await ModelEditorAdapter.RefreshPlanContextAsync(
                new ModelSaveRequest(requestAssetPath, "Plan", requestProjectPath, aliasLoaded.Revision,
                    [], [], switchedProjectXml));
            Check(aliasRefresh.Baseline.Fields[ModeField] == "BoundaryCondition" &&
                  WallTime(aliasRefresh.Baseline, StartField) == new DateTime(2026, 10, 3, 6, 0, 0) &&
                  WallTime(aliasRefresh.Baseline, EndField) == new DateTime(2026, 10, 4, 12, 0, 0),
                message + " after an unsaved association refresh");
            CheckUnchanged(projectPath, projectBytes, assetPath, planBytes,
                firstBoundaryPath, firstBoundaryBytes, secondBoundaryPath, secondBoundaryBytes);
        }

        XElement Association(XElement root) => root.Element("PlanAssociations")?.Elements("PlanAssociation")
            .SingleOrDefault(element => (string?)element.Attribute("Plan") == "Plan A")
            ?? throw new InvalidOperationException("The fixture project must store its plan association.");
    }

    private static DateTime WallTime(ModelSnapshot snapshot, string field) =>
        DateTimeOffset.Parse(snapshot.Fields[field], CultureInfo.InvariantCulture).DateTime;

    private static void CheckUnchanged(string projectPath, byte[] projectBytes, string planPath, byte[] planBytes,
        string firstBoundaryPath, byte[] firstBoundaryBytes, string secondBoundaryPath, byte[] secondBoundaryBytes)
    {
        Check(File.ReadAllBytes(projectPath).SequenceEqual(projectBytes), "Plan context refresh does not save the project XML");
        Check(File.ReadAllBytes(planPath).SequenceEqual(planBytes), "Plan context refresh does not write plan HDF");
        Check(File.ReadAllBytes(firstBoundaryPath).SequenceEqual(firstBoundaryBytes) &&
              File.ReadAllBytes(secondBoundaryPath).SequenceEqual(secondBoundaryBytes),
            "Plan context refresh does not write associated boundary HDF");
    }

    private static void ExportFixtureIfRequested(string sourceDirectory)
    {
        if (Environment.GetEnvironmentVariable("HECRAS_PLAN_CONTEXT_ACCEPTANCE_DIRECTORY") is not string fixture) return;
        string destination = Path.GetFullPath(fixture);
        if (Directory.Exists(destination)) throw new IOException("Plan context acceptance destination already exists.");
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

    private static async Task Expect<T>(Func<Task> action) where T : Exception
    {
        try { await action(); }
        catch (T) { return; }
        throw new InvalidOperationException("Expected " + typeof(T).Name);
    }
}
