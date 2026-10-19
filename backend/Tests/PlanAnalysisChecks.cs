using System.Security.Cryptography;
using System.Text;
using System.Xml.Linq;
using Ras.Backend;
using Ras.Layers;
using Utility.Units;

internal static class PlanAnalysisChecks
{
    internal static void Run()
    {
        using var temporary = new TemporaryDirectory();
        string projectPath = Path.Combine(temporary.FullName, "Plan analysis.ras");
        Project project = Project.CreateNew(projectPath, UnitSystem.SI);
        string firstPlanPath;
        string secondPlanPath;
        try
        {
            Terrain terrain = project.AddNewTerrain("Terrain");
            NValueLayer nvalues = project.AddNewNValueLayer("Roughness");
            Geometry geometry = project.AddNewGeometry("Geometry", terrain, nvalues);
            BoundaryCondition boundary = project.AddNewBoundaryCondition("Boundary",
                new DateTime(2026, 1, 1), TimeSpan.FromHours(2));
            Plan first = project.AddNewPlan("Plan A", geometry, boundary);
            Plan second = project.AddNewPlan("Plan B", geometry, boundary);
            first.CoreCount = 2;
            second.CoreCount = 4;
            foreach (CoreLayerBase layer in Layers(project)) layer.Save();
            project.Save();
            firstPlanPath = first.Filename;
            secondPlanPath = second.Filename;
            Directory.CreateDirectory(project.ResultsDirectory);
            using Result history = Result.PrepareResult(
                Path.Combine(project.ResultsDirectory, "Plan A history.h5"), first,
                geometry, boundary, null!);
        }
        finally { Dispose(project); }

        XElement projectDraft = XElement.Load(projectPath);
        projectDraft.SetAttributeValue("Description", "unsaved Plan analysis description");
        string projectXml = projectDraft.ToString(SaveOptions.DisableFormatting);
        var capture = new PlanAnalysisProjectCapture(projectPath, Hash(projectPath), projectXml,
            HashText(projectXml));
        Dictionary<string, string> before = Directory.EnumerateFiles(temporary.FullName, "*",
                SearchOption.AllDirectories)
            .ToDictionary(path => path, Hash, StringComparer.Ordinal);

        PlanAnalysisDiffOptionsResponse diffOptions =
            ModelEditorAdapter.LoadPlanAnalysisDiffOptions(new(capture));
        PlanAnalysisDiffOption firstPlan = diffOptions.Options.Single(item =>
            !item.IsResult && Same(item.PlanPath, firstPlanPath));
        PlanAnalysisDiffOption secondPlan = diffOptions.Options.Single(item =>
            !item.IsResult && Same(item.PlanPath, secondPlanPath));
        PlanAnalysisDiffOption historyOption = diffOptions.Options.Single(item =>
            item.IsResult && Same(item.PlanPath, firstPlanPath));
        Check(historyOption.ResultPath is not null && Same(historyOption.PlanPath, firstPlanPath),
            "A Result choice remains tied to its exact owning Plan; the comparison reads that Plan, not HDF data.");

        const string coreCountField = "PlanComputeSettingsPage/ViewModel_SelectedPlan_CoreCount";
        var draft = new PlanAnalysisPlanDraft(firstPlanPath, Hash(firstPlanPath),
            new Dictionary<string, string> { [coreCountField] = "10" },
            PlanTimeWindowEdits: []);
        PlanAnalysisDiffResponse diff = ModelEditorAdapter.ComparePlanAnalysis(
            new(capture, historyOption.Id, secondPlan.Id, [draft]));
        PlanAnalysisDiffRow coreCount = diff.Rows.Single(row => row.Key == nameof(Plan.CoreCount));
        Check(coreCount.LeftValue == "10" && coreCount.RightValue == "4" && coreCount.Differs,
            "Diff compares the Plan behind a selected Result and applies the exact unsaved Plan draft in memory.");

        PlanMatrixOptionsResponse matrixOptions = ModelEditorAdapter.LoadPlanMatrixOptions(
            new(capture, firstPlanPath, draft));
        Check(matrixOptions.SelectedPlanPath is not null && Same(matrixOptions.SelectedPlanPath, firstPlanPath) &&
              matrixOptions.Properties.Single(property => property.PropertyName == nameof(Plan.CoreCount))
                  .InitialValues.Single().Value == "10",
            "Matrix properties use the selected source Plan draft while retaining exact path identity.");
        PlanMatrixPreviewResponse preview = ModelEditorAdapter.PreviewPlanMatrix(new(capture,
            firstPlanPath, Hash(firstPlanPath), draft,
            [new PlanMatrixAxisSelection(nameof(Plan.CoreCount), ["1", "2"])],
            matrixOptions.Rules.Where(rule => rule.Enabled).Select(rule => rule.Name).ToArray(),
            CollapseIrrelevant: true,
            OutputDirectory: Path.Combine(temporary.FullName, "generated-matrix")));
        Check(preview.Combinations.Length == 2 && preview.WriteCount == 2 &&
              preview.Combinations.Select(row => row.Filename).Distinct(StringComparer.OrdinalIgnoreCase).Count() == 2,
            "Matrix preview uses the source sweep algorithm and gives each run a distinct filename.");

        ExpectChanged(() => ModelEditorAdapter.PreviewPlanMatrix(new(capture,
            firstPlanPath, new string('0', 64), draft,
            [new PlanMatrixAxisSelection(nameof(Plan.CoreCount), ["1"])], [], true)));
        ExpectChanged(() => ModelEditorAdapter.LoadPlanAnalysisDiffOptions(new(capture with
        { ProjectRevision = new string('0', 64) })));
        Check(before.All(pair => Hash(pair.Key) == pair.Value),
            "Plan analysis uses current Project XML and Plan drafts without writing the Project, Plan or Result sources.");
    }

    private static IEnumerable<CoreLayerBase> Layers(Project project) => project.Plans.Cast<CoreLayerBase>()
        .Concat(project.Geometries).Concat(project.BoundaryConditions).Concat(project.Terrains)
        .Concat(project.NValues).Concat(project.ClassificationLayers);

    private static void Dispose(Project project)
    {
        foreach (Result result in project.Results) result.Dispose();
        foreach (CoreLayerBase layer in Layers(project)) layer.Dispose();
    }

    private static string Hash(string path)
    {
        using Stream stream = File.OpenRead(path);
        return Convert.ToHexString(SHA256.HashData(stream));
    }

    private static string HashText(string value) =>
        Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(value))).ToLowerInvariant();

    private static bool Same(string left, string right) =>
        SourceFilePaths.SameSourceFile(left, right);

    private static void Check(bool value, string message)
    {
        if (!value) throw new InvalidOperationException(message);
    }

    private static void ExpectChanged(Action action)
    {
        try { action(); } catch (SourceFileChangedException) { return; }
        throw new InvalidOperationException("Stale Plan analysis sources must be rejected.");
    }
}
