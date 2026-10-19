using System.Security.Cryptography;
using System.Xml.Linq;
using Ras.Backend;
using Ras.Layers;
using Utility.Units;

/// <summary>
/// Builds an original-source Project and uncomputed Result HDFs, copies the
/// complete fixture tree, then exercises the production Plan-context and
/// linked-profile services against the copied project. No profile timestamps
/// or computed output are fabricated by this check.
/// </summary>
internal static class ResultPlanContextChecks
{
    internal static void Run()
    {
        using var sourceDirectory = new TemporaryDirectory();
        using var copiedDirectory = new TemporaryDirectory();
        string sourceProjectPath = Path.Combine(sourceDirectory.FullName, "Plan context.ras");
        Project project = Project.CreateNew(sourceProjectPath, UnitSystem.SI);
        string sourceAnchorPath = string.Empty;
        try
        {
            Terrain terrain = project.AddNewTerrain("Terrain");
            NValueLayer nvalues = project.AddNewNValueLayer("Manning n");
            Geometry geometry = project.AddNewGeometry("Geometry", terrain, nvalues);
            BoundaryCondition boundary = project.AddNewBoundaryCondition("Boundary",
                new DateTime(2026, 10, 16), TimeSpan.FromHours(2));
            Plan anchorPlan = project.AddNewPlan("Anchor plan", geometry, boundary);
            Plan candidatePlan = project.AddNewPlan("Candidate plan", geometry, boundary);
            anchorPlan.TimeWindowMode = PlanTimeWindowMode.Plan;
            anchorPlan.InternalStartTime = new DateTime(2025, 2, 3, 4, 0, 0);
            anchorPlan.InternalComputeDurationSeconds = 3600;
            anchorPlan.ComputeTimestep = TimeSpan.FromMinutes(5);
            anchorPlan.BaseOutputInterval = TimeSpan.FromMinutes(30);
            anchorPlan.SolverType = SolverType.GPU;
            foreach (CoreLayerBase layer in Layers(project)) layer.Save();
            project.Save();

            sourceAnchorPath = Path.Combine(project.ResultsDirectory, "Anchor result.h5");
            using (Result prepared = Result.PrepareResult(sourceAnchorPath, anchorPlan, geometry, boundary, null!))
                Check(File.Exists(sourceAnchorPath), "The retained Result.PrepareResult writer creates the anchor HDF.");
            using (Result prepared = Result.PrepareResult(Path.Combine(project.ResultsDirectory, "Candidate A.h5"),
                       candidatePlan, geometry, boundary, null!))
                Check(File.Exists(prepared.Filename), "The retained Result.PrepareResult writer creates candidate A.");
            using (Result prepared = Result.PrepareResult(Path.Combine(project.ResultsDirectory, "Candidate B.h5"),
                       candidatePlan, geometry, boundary, null!))
                Check(File.Exists(prepared.Filename), "The retained Result.PrepareResult writer creates candidate B.");

            // Same-named current project Plan is deliberately changed after
            // the Result captured its own embedded Plan snapshot.
            anchorPlan.InternalStartTime = new DateTime(2030, 7, 8, 9, 0, 0);
            anchorPlan.InternalComputeDurationSeconds = 7200;
            anchorPlan.SolverType = SolverType.CPU;
            anchorPlan.Save();
            project.Save();
        }
        finally { DisposeProject(project); }

        CopyTree(sourceDirectory.FullName, copiedDirectory.FullName);
        string projectPath = Path.Combine(copiedDirectory.FullName, Path.GetFileName(sourceProjectPath));
        string anchorPath = Path.Combine(copiedDirectory.FullName,
            Path.GetRelativePath(sourceDirectory.FullName, sourceAnchorPath));
        string projectXml = XElement.Load(projectPath).ToString(SaveOptions.DisableFormatting);
        Dictionary<string, string> before = HashTree(copiedDirectory.FullName);

        ResultPlanContextSnapshot snapshot = ResultPlanContextService.Inspect(projectPath,
            projectXml, anchorPath, Hash(anchorPath));
        Check(snapshot.ProjectPath == Path.GetFullPath(projectPath)
            && snapshot.AnchorName == "Anchor result"
            && snapshot.AnchorPlanName == "Anchor plan"
            && snapshot.AnchorHasPlan,
            "The copied saved Result is uniquely bound to its project and retains embedded Plan identity.");
        ResultPlanPropertyGroup timeWindow = snapshot.EmbeddedPlanGroups.Single(group => group.Title == "Time Window");
        ResultPlanPropertyGroup computation = snapshot.EmbeddedPlanGroups.Single(group => group.Title == "Computation Options");
        Check(timeWindow.Items.Single(item => item.Label == "Start").Value == "2025-02-03 04:00:00"
            && timeWindow.Items.Single(item => item.Label == "End").Value == "2025-02-03 05:00:00"
            && timeWindow.Items.Single(item => item.Label == "Profiles").Value == "3",
            "Time Window comes from the embedded Plan, not its same-named current project Plan.");
        Check(computation.Items.Single(item => item.Label == "Solver").Value.Contains("GPU", StringComparison.Ordinal),
            "Computation Options come from the embedded Plan rather than the changed current project Plan.");

        ResultPlanCandidateGroup candidateGroup = snapshot.CandidateGroups.Single(group =>
            group.HasPlan && group.PlanName == "Candidate plan");
        Check(candidateGroup.Results.Length == 2
            && candidateGroup.Results.Select(item => Path.GetFileName(item.ResultPath)).Order(StringComparer.Ordinal)
                .SequenceEqual(new[] { "Candidate A.h5", "Candidate B.h5" }.Order(StringComparer.Ordinal)),
            "The picker candidates use the actual project Results grouped by their own embedded Plan.");

        LinkedResultProfilesSnapshot linked = LinkedResultProfilesService.Read(new LinkedResultProfilesRequest(
            snapshot.ProjectPath, projectXml, snapshot.ProjectRevision, snapshot.Anchor, [candidateGroup], 0));
        Check(linked.AnchorPath == snapshot.ResultPath && linked.Steps.Length == 0
            && linked.Frames.Length == 3 && linked.Frames.All(frame => frame.ProfileIndex == null
                && frame.UnavailableReason != null),
            "The linked service accepts the complete revision-bound group and reports empty HDF profiles unavailable.");

        Expect<SourceFileChangedException>(() => LinkedResultProfilesService.Read(new LinkedResultProfilesRequest(
            snapshot.ProjectPath, projectXml, new string('0', 64), snapshot.Anchor, [candidateGroup], 0)));
        Expect<SourceFileChangedException>(() => LinkedResultProfilesService.Read(new LinkedResultProfilesRequest(
            snapshot.ProjectPath, projectXml, snapshot.ProjectRevision, snapshot.Anchor,
            [candidateGroup with { Results = candidateGroup.Results.Take(1).ToArray() }], 0)));
        Expect<SourceFileChangedException>(() => LinkedResultProfilesService.Read(new LinkedResultProfilesRequest(
            snapshot.ProjectPath, projectXml, snapshot.ProjectRevision, snapshot.Anchor,
            [candidateGroup with { Results = [candidateGroup.Results[0] with { Revision = new string('0', 64) }, candidateGroup.Results[1]] }], 0)));
        Expect<SourceFileChangedException>(() => ResultPlanContextService.Inspect(projectPath,
            projectXml, anchorPath, new string('0', 64)));

        Dictionary<string, string> after = HashTree(copiedDirectory.FullName);
        Check(before.Count == after.Count && before.All(item => after.TryGetValue(item.Key, out string? hash)
            && hash == item.Value),
            "Inspecting Plans and linking the uncomputed Results never writes copied project or HDF files.");
        ExportIfRequested(copiedDirectory.FullName);
        Console.WriteLine("Copied Result Plan contexts preserve embedded Plan values, strict linked-group identities, unavailable empty profiles, and source bytes.");
    }

    private static IEnumerable<CoreLayerBase> Layers(Project project) => project.Plans.Cast<CoreLayerBase>()
        .Concat(project.Geometries).Concat(project.BoundaryConditions).Concat(project.Terrains)
        .Concat(project.NValues).Concat(project.ClassificationLayers);

    private static void DisposeProject(Project project)
    {
        foreach (Result result in project.Results) result.Dispose();
        foreach (CoreLayerBase layer in Layers(project)) layer.Dispose();
    }

    private static void CopyTree(string source, string destination)
    {
        foreach (string file in Directory.EnumerateFiles(source, "*", SearchOption.AllDirectories))
        {
            string target = Path.Combine(destination, Path.GetRelativePath(source, file));
            Directory.CreateDirectory(Path.GetDirectoryName(target)!);
            File.Copy(file, target);
        }
    }

    private static Dictionary<string, string> HashTree(string root) =>
        Directory.EnumerateFiles(root, "*", SearchOption.AllDirectories)
            .ToDictionary(path => Path.GetRelativePath(root, path), Hash, StringComparer.Ordinal);

    private static string Hash(string path)
    {
        using FileStream stream = File.OpenRead(path);
        return Convert.ToHexString(SHA256.HashData(stream));
    }

    private static void ExportIfRequested(string fixtureRoot)
    {
        string? destination = Environment.GetEnvironmentVariable("HECRAS_LINKED_RESULT_ACCEPTANCE_DIRECTORY");
        if (string.IsNullOrWhiteSpace(destination)) return;
        destination = Path.GetFullPath(destination);
        string source = Path.GetFullPath(fixtureRoot) + Path.DirectorySeparatorChar;
        if (Directory.Exists(destination) || File.Exists(destination)
            || destination.StartsWith(source, StringComparison.Ordinal))
            throw new IOException("The linked Result acceptance destination already exists or is inside the temporary fixture.");
        Directory.CreateDirectory(destination);
        CopyTree(fixtureRoot, destination);
    }

    private static void Check(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }

    private static void Expect<T>(Action action) where T : Exception
    {
        try { action(); }
        catch (T) { return; }
        throw new InvalidOperationException("Expected " + typeof(T).Name + ".");
    }
}
