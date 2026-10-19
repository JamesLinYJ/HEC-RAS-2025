using System.Globalization;
using System.Xml.Linq;
using Ras.Backend;
using Ras.Layers;
using Utility.Units;

internal static class PlanPrecomputeChecks
{
    private const string DescriptionField = "PlanSettingsPage/ViewModel_SelectedPlan_Description";
    private const string ModeField = "PlanSettingsPage/ViewModel_SelectedPlan_TimeWindowMode";
    private const string StartField = "PlanSettingsPage/ViewModel_SelectedPlan_ComputeStartTime";
    private const string EndField = "PlanSettingsPage/ViewModel_SelectedPlan_ComputeEndTime";
    private const string TimestepField = "PlanSettingsPage/ViewModel_SelectedPlan_ComputeTimestep";
    private const string ImageField = "PlanSettingsPage/ViewModel_SelectedPlan_EmbeddedImages";

    internal static async Task Run()
    {
        using var directory = new TemporaryDirectory();
        string projectPath = Path.Combine(directory.FullName, "Plan Precompute.ras");
        Project project = Project.CreateNew(projectPath, UnitSystem.SI);
        DateTime boundaryAStart = new(2026, 10, 1, 0, 0, 0);
        DateTime boundaryBStart = new(2026, 10, 3, 0, 0, 0);
        var firstBoundary = project.AddNewBoundaryCondition("Boundary A", boundaryAStart, TimeSpan.FromDays(1));
        var secondBoundary = project.AddNewBoundaryCondition("Boundary B", boundaryBStart, TimeSpan.FromDays(1));
        var plan = project.AddNewPlan("Plan A");
        string assetPath = plan.Filename;
        string firstBoundaryPath = firstBoundary.Filename;
        string secondBoundaryPath = secondBoundary.Filename;
        plan.TimeWindowMode = PlanTimeWindowMode.Plan;
        plan.InternalStartTime = boundaryBStart.AddHours(3);
        plan.InternalComputeDurationSeconds = TimeSpan.FromHours(1).TotalSeconds;
        plan.EmbeddedImages.Add("plan.png", "retained source image", Convert.FromBase64String(
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+j6LkAAAAASUVORK5CYII="));
        project.GetPlanAssociation(plan).BoundaryCondition = firstBoundary;
        firstBoundary.Save();
        secondBoundary.Save();
        plan.Save();
        project.Save();
        plan.Dispose(); firstBoundary.Dispose(); secondBoundary.Dispose();

        ModelSnapshot loaded = await ModelEditorAdapter.LoadAsync(new ModelRequest(assetPath, "Plan", projectPath));
        byte[] projectBytes = File.ReadAllBytes(projectPath);
        byte[] planBytes = File.ReadAllBytes(assetPath);
        byte[] firstBoundaryBytes = File.ReadAllBytes(firstBoundaryPath);
        byte[] secondBoundaryBytes = File.ReadAllBytes(secondBoundaryPath);

        XElement projectDraft = XElement.Load(projectPath);
        Association(projectDraft).SetAttributeValue("BoundaryCondition", "Boundary B");
        string projectXmlWithBoundaryB = projectDraft.ToString(SaveOptions.DisableFormatting);
        string planStart = LocalDate(boundaryBStart.AddHours(3));
        string planEnd = LocalDate(boundaryBStart.AddHours(4));
        var ordinaryDraft = new Dictionary<string, string>
        {
            [DescriptionField] = "Unsaved precompute description",
            [TimestepField] = "70"
        };
        PlanTimeWindowEdit[] windowDraft =
        [
            new("mode", ModeField, "Plan"),
            new("start", StartField, planStart),
            new("end", EndField, planEnd)
        ];

        PlanPrecomputeResult switched = await ModelEditorAdapter.PrecomputePlanAsync(Request(
            loaded.Revision, projectXmlWithBoundaryB, ordinaryDraft, windowDraft));
        Check(switched.Revision == loaded.Revision && !switched.Result,
            "Precompute returns the unchanged source revision and the source CanCompute failure state");
        Check(switched.Messages.Any(message => message.Code == "Plan_NoGeomAssociation"),
            "Precompute returns actual Plan.CanCompute diagnostics rather than treating validation failure as a transport error");
        Check(switched.Messages.Any(message => message.Code == "Plan_MappingIntervalMismatchingComputeInterval"),
            "Unsaved ordinary plan settings participate in the source CanCompute result");
        Check(!switched.Messages.Any(message => message.Code == "BC_DoesntCoverTimeWindow"),
            "Precompute uses the unsaved plan association to Boundary B and the ordered custom time-window setters");
        PlanPrecomputeMessage geometryMessage = switched.Messages.Single(message => message.Code == "Plan_NoGeomAssociation");
        Check(geometryMessage.DefaultSeverity == "Error" && geometryMessage.ExtraCount == 0 &&
              geometryMessage.EvaluatedMessage.Contains("Plan A", StringComparison.Ordinal) &&
              geometryMessage.LogData.Any(pair => pair.Key == "PlanName" && pair.Value == "Plan A") &&
              geometryMessage.LogData.Any(pair => pair.Key == "{OriginalFormat}"),
            "Messages preserve their source code, severity, evaluated text, structured log data and aggregation count");

        XElement projectDraftWithBoundaryA = XElement.Load(projectPath);
        var sourceAssociation = await ModelEditorAdapter.PrecomputePlanAsync(Request(
            loaded.Revision, projectDraftWithBoundaryA.ToString(SaveOptions.DisableFormatting), ordinaryDraft, windowDraft));
        Check(sourceAssociation.Messages.Any(message => message.Code == "BC_DoesntCoverTimeWindow" &&
              message.LogData.Any(pair => pair.Key == "BoundaryConditionName" && pair.Value == "Boundary A")),
            "The same unsaved Plan window produces the original boundary validation when Boundary A remains associated");

        await Expect<SourceFileChangedException>(() => ModelEditorAdapter.PrecomputePlanAsync(Request(
            loaded.Revision + "stale", projectXmlWithBoundaryB, ordinaryDraft, windowDraft)));
        await Expect<ArgumentException>(() => ModelEditorAdapter.PrecomputePlanAsync(Request(
            loaded.Revision, projectXmlWithBoundaryB,
            new Dictionary<string, string> { [TimestepField] = "NaN" }, windowDraft)));
        await Expect<NotSupportedException>(() => ModelEditorAdapter.PrecomputePlanAsync(Request(
            loaded.Revision, projectXmlWithBoundaryB, [], [],
            rows: new Dictionary<string, ModelRow[]> { ["unsupported"] = [new("row", [])] })));
        await Expect<NotSupportedException>(() => ModelEditorAdapter.PrecomputePlanAsync(Request(
            loaded.Revision, projectXmlWithBoundaryB, [], [],
            samples: new Dictionary<string, ModelSample[]> { ["unsupported"] = [new("sample", 0, null, "series")] })));

        CheckUnchanged(projectPath, projectBytes, assetPath, planBytes,
            firstBoundaryPath, firstBoundaryBytes, secondBoundaryPath, secondBoundaryBytes);
        using (var actualPlan = new Plan(assetPath))
            Check(actualPlan.EmbeddedImages.Images.Single().Description == "retained source image",
                "Precompute leaves source HDF images intact even when the request carries an image draft");

        CheckPlanPrecomputeDependencyGuards();

        Console.WriteLine("Plan precompute runs source CanCompute on unsaved plan/project drafts and leaves project and HDF bytes unchanged.");

        ModelSaveRequest Request(string revision, string projectXml, Dictionary<string, string> fields,
            PlanTimeWindowEdit[]? planTimeWindowEdits = null,
            Dictionary<string, ModelRow[]>? rows = null, Dictionary<string, ModelSample[]>? samples = null) =>
            new(assetPath, "Plan", projectPath, revision, fields,
                new Dictionary<string, ImageData[]> { [ImageField] = [] }, projectXml, loaded.SourceState,
                Rows: rows, Samples: samples, PlanTimeWindowEdits: planTimeWindowEdits);

        XElement Association(XElement root) => root.Element("PlanAssociations")?.Elements("PlanAssociation")
            .SingleOrDefault(element => (string?)element.Attribute("Plan") == "Plan A")
            ?? throw new InvalidOperationException("The fixture project must store its plan association.");
    }

    private static string LocalDate(DateTime value) => DateTime.SpecifyKind(value, DateTimeKind.Local)
        .ToString("yyyy-MM-dd'T'HH:mm:sszzz", CultureInfo.InvariantCulture);

    private static void CheckPlanPrecomputeDependencyGuards()
    {
        using var directory = new TemporaryDirectory();
        string projectPath = Path.Combine(directory.FullName, "Precompute dependency guard.ras");
        Project project = Project.CreateNew(projectPath, UnitSystem.SI);
        Terrain terrain = project.AddNewTerrain("Guard Terrain");
        NValueLayer nValues = project.AddNewNValueLayer("Guard N Values");
        Geometry geometry = project.AddNewGeometry("Guard Geometry");
        BoundaryCondition firstBoundary = project.AddNewBoundaryCondition("Guard Boundary A",
            new DateTime(2026, 10, 1), TimeSpan.FromDays(1));
        BoundaryCondition selectedBoundary = project.AddNewBoundaryCondition("Guard Boundary B",
            new DateTime(2026, 10, 3), TimeSpan.FromDays(1));
        Plan plan = project.AddNewPlan("Guard Plan");
        project.GetGeometryAssociation(geometry).Terrain = terrain;
        project.GetGeometryAssociation(geometry).NValueLayer = nValues;
        project.GetPlanAssociation(plan).Geometry = geometry;
        project.GetPlanAssociation(plan).BoundaryCondition = firstBoundary;

        string planPath = plan.Filename;
        string geometryPath = geometry.Filename;
        string terrainPath = terrain.Filename;
        string nValuesPath = nValues.Filename;
        string firstBoundaryPath = firstBoundary.Filename;
        string selectedBoundaryPath = selectedBoundary.Filename;
        firstBoundary.Save(); selectedBoundary.Save(); terrain.Save(); nValues.Save();
        geometry.Save(); plan.Save(); project.Save();
        firstBoundary.Dispose(); selectedBoundary.Dispose(); terrain.Dispose(); nValues.Dispose();
        geometry.Dispose(); plan.Dispose();

        XElement projectDraft = XElement.Load(projectPath);
        XElement association = projectDraft.Element("PlanAssociations")?.Elements("PlanAssociation")
            .Single(element => (string?)element.Attribute("Plan") == "Guard Plan")
            ?? throw new InvalidOperationException("The dependency-guard fixture must store its plan association.");
        association.SetAttributeValue("BoundaryCondition", "Guard Boundary B");
        string projectXml = projectDraft.ToString(SaveOptions.DisableFormatting);

        Dictionary<string, string> baseline = CaptureDependencies(projectPath, planPath, projectXml);
        HashSet<string> dependencyNames = baseline.Keys.Select(path => Path.GetFileName(path) ?? throw new InvalidOperationException("A dependency path has no filename.")).ToHashSet(StringComparer.Ordinal);
        Check(dependencyNames.Contains(Path.GetFileName(planPath)) &&
              dependencyNames.Contains(Path.GetFileName(geometryPath)) &&
              dependencyNames.Contains(Path.GetFileName(terrainPath)) &&
              dependencyNames.Contains(Path.GetFileName(nValuesPath)) &&
              dependencyNames.Contains(Path.GetFileName(selectedBoundaryPath)) &&
              !dependencyNames.Contains(Path.GetFileName(firstBoundaryPath)),
            "Dependency fingerprints follow the unsaved selected BC and its Geometry/Terrain/N-value chain");

        byte[] unselectedBoundaryBytes = File.ReadAllBytes(firstBoundaryPath);
        try
        {
            MutateHdf(firstBoundaryPath, BoundaryCondition.HDFGroupName);
            Check(!VerifyDependenciesRejectsChangedSource(projectPath, planPath, projectXml, baseline),
                "An unselected boundary-condition HDF is outside the precompute dependency fingerprint");
        }
        finally { File.WriteAllBytes(firstBoundaryPath, unselectedBoundaryBytes); }

        foreach ((string path, string group, string description) in new[]
                 {
                     (selectedBoundaryPath, BoundaryCondition.HDFGroupName, "selected boundary-condition"),
                     (geometryPath, Geometry.HDF5Group, "associated geometry"),
                     (terrainPath, Terrain.HDF5Group, "associated terrain"),
                     (nValuesPath, NValueLayer.HDF5Group, "associated N-value")
                 })
        {
            byte[] original = File.ReadAllBytes(path);
            try
            {
                MutateHdf(path, group);
                Check(VerifyDependenciesRejectsChangedSource(projectPath, planPath, projectXml, baseline),
                    "A changed " + description + " HDF rejects the precompute result");
            }
            finally { File.WriteAllBytes(path, original); }
        }

        XElement projectWithMissingBoundary = new XElement(projectDraft);
        projectWithMissingBoundary.Element("PlanAssociations")!.Elements("PlanAssociation")
            .Single(element => (string?)element.Attribute("Plan") == "Guard Plan")
            .SetAttributeValue("BoundaryCondition", "Guard Boundary Missing");
        string missingProjectXml = projectWithMissingBoundary.ToString(SaveOptions.DisableFormatting);
        Dictionary<string, string> missing = CaptureDependencies(projectPath, planPath, missingProjectXml);
        string missingBoundaryPath = BoundaryCondition.MakeFilename(Path.GetDirectoryName(projectPath)!, "Guard Boundary Missing");
        Check(missing.Any(pair => Path.GetFileName(pair.Key) == Path.GetFileName(missingBoundaryPath) && pair.Value == "missing"),
            "A selected but absent HDF dependency is fingerprinted with its missing state");
        File.Copy(selectedBoundaryPath, missingBoundaryPath);
        try
        {
            Check(VerifyDependenciesRejectsChangedSource(projectPath, planPath, missingProjectXml, missing),
                "A selected dependency appearing after capture invalidates the precompute result");
        }
        finally { File.Delete(missingBoundaryPath); }
    }

    private static Dictionary<string, string> CaptureDependencies(string projectPath, string assetPath, string projectXml)
    {
        return ModelEditorAdapter.CapturePlanPrecomputeDependencies(
            projectPath, assetPath, projectXml, coreLayerContext: null);
    }

    private static void VerifyDependencies(string projectPath, string assetPath, string projectXml,
        Dictionary<string, string> snapshot)
    {
        ModelEditorAdapter.VerifyPlanPrecomputeDependencies(
            projectPath, assetPath, projectXml, coreLayerContext: null, snapshot);
    }

    private static bool VerifyDependenciesRejectsChangedSource(string projectPath, string assetPath,
        string projectXml, Dictionary<string, string> snapshot)
    {
        try { VerifyDependencies(projectPath, assetPath, projectXml, snapshot); }
        catch (SourceFileChangedException) { return true; }
        return false;
    }

    private static void MutateHdf(string path, string group)
    {
        using var writer = new H5Assist.H5Writer(path);
        writer.WriteAttribute(group, "Precompute dependency guard mutation", Guid.NewGuid().ToString("N"));
    }

    private static void CheckUnchanged(string projectPath, byte[] projectBytes, string planPath, byte[] planBytes,
        string firstBoundaryPath, byte[] firstBoundaryBytes, string secondBoundaryPath, byte[] secondBoundaryBytes)
    {
        Check(File.ReadAllBytes(projectPath).SequenceEqual(projectBytes), "Plan precompute does not save project XML");
        Check(File.ReadAllBytes(planPath).SequenceEqual(planBytes), "Plan precompute does not write plan HDF");
        Check(File.ReadAllBytes(firstBoundaryPath).SequenceEqual(firstBoundaryBytes) &&
              File.ReadAllBytes(secondBoundaryPath).SequenceEqual(secondBoundaryBytes),
            "Plan precompute does not write associated boundary-condition HDF");
    }

    private static void Check(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }

    private static async Task Expect<T>(Func<Task<PlanPrecomputeResult>> action) where T : Exception
    {
        try { _ = await action(); }
        catch (T) { return; }
        throw new InvalidOperationException("Expected " + typeof(T).Name);
    }
}
