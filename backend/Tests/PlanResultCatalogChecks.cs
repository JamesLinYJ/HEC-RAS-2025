using System.Security.Cryptography;
using System.Xml.Linq;
using Ras.Backend;
using Ras.Layers;
using Utility.Units;

internal static class PlanResultCatalogChecks
{
    internal static void Run()
    {
        using var temporary = new TemporaryDirectory();
        string projectPath = Path.Combine(temporary.FullName, "相关结果.ras");
        Project project = Project.CreateNew(projectPath, UnitSystem.SI);
        string planPath;
        try
        {
            Terrain terrain = project.AddNewTerrain("地形");
            NValueLayer nvalues = project.AddNewNValueLayer("糙率");
            Geometry geometry = project.AddNewGeometry("几何", terrain, nvalues);
            BoundaryCondition boundary = project.AddNewBoundaryCondition("边界", new DateTime(2026, 10, 16), TimeSpan.FromHours(1));
            Plan plan = project.AddNewPlan("计划一", geometry, boundary);
            Plan other = project.AddNewPlan("计划二", geometry, boundary);
            foreach (CoreLayerBase layer in Layers(project)) layer.Save();
            project.Save();
            planPath = plan.Filename;
            Directory.CreateDirectory(project.ResultsDirectory);
            using Result first = Result.PrepareResult(Path.Combine(project.ResultsDirectory, "历史甲.h5"), plan, geometry, boundary, null!);
            using Result second = Result.PrepareResult(Path.Combine(project.ResultsDirectory, "历史乙.h5"), plan, geometry, boundary, null!);
            // Its filename resembles the selected Plan, but its embedded Plan
            // belongs to the other source model. NameMatchedResults excludes it.
            using Result unrelated = Result.PrepareResult(Path.Combine(project.ResultsDirectory, "计划一.h5"), other, geometry, boundary, null!);
        }
        finally { Dispose(project); }

        var baseline = Directory.EnumerateFiles(temporary.FullName, "*", SearchOption.AllDirectories)
            .ToDictionary(path => path, Hash, StringComparer.Ordinal);
        XElement draft = XElement.Load(projectPath);
        draft.SetAttributeValue("Description", "未保存的项目说明");
        string xml = draft.ToString(SaveOptions.DisableFormatting);
        var request = new PlanResultCatalogRequest(projectPath, xml, planPath, Hash(planPath));
        PlanResultCatalog catalog = PlanResultCatalogService.Load(request);
        Check(catalog.PlanName == "计划一" && catalog.Results.Length == 2
            && catalog.Results.Select(item => item.Name).Order().SequenceEqual(new[] { "历史乙", "历史甲" }.Order())
            && catalog.Results.All(item => item.EmbeddedPlanName == "计划一" && !item.HasComputed && item.ProfileCount == 0),
            "Plan result choices follow the embedded Plan name, independently of the Result filename or computed status.");
        Check(catalog.Results.All(item => item.Revision == Hash(item.ResultPath))
            && catalog.Revision == Hash(planPath)
            && baseline.All(pair => Hash(pair.Key) == pair.Value),
            "Choices retain exact saved source revisions without saving project XML or HDF sources.");
        ExpectChanged(() => PlanResultCatalogService.Load(request with { Revision = new string('0', 64) }));
        ExpectArgument(() => PlanResultCatalogService.Load(request with { PlanPath = catalog.Results[0].ResultPath,
            Revision = catalog.Results[0].Revision }));
        string? destination = Environment.GetEnvironmentVariable("HECRAS_PLAN_RESULT_ACCEPTANCE_DIRECTORY");
        if (!string.IsNullOrEmpty(destination))
        {
            string target = Path.GetFullPath(destination);
            if (Directory.Exists(target) || File.Exists(target)
                || target.StartsWith(Path.GetFullPath(temporary.FullName) + Path.DirectorySeparatorChar, StringComparison.Ordinal))
                throw new IOException("The plan-result acceptance destination already exists or is inside the fixture source.");
            Directory.CreateDirectory(target);
            foreach (string file in baseline.Keys)
            {
                string copy = Path.Combine(target, Path.GetRelativePath(temporary.FullName, file));
                Directory.CreateDirectory(Path.GetDirectoryName(copy)!);
                File.Copy(file, copy);
            }
        }
        Console.WriteLine("Plan result choices match original ObservablePlan.NameMatchedResults, exact source identity and unchanged project/HDF bytes.");
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
    private static void Check(bool value, string message)
    {
        if (!value) throw new InvalidOperationException(message);
    }
    private static void ExpectChanged(Action action)
    {
        try { action(); } catch (SourceFileChangedException) { return; }
        throw new InvalidOperationException("A stale Plan revision must be rejected.");
    }
    private static void ExpectArgument(Action action)
    {
        try { action(); } catch (ArgumentException) { return; }
        throw new InvalidOperationException("A file outside the current Project Plans must be rejected.");
    }
}
