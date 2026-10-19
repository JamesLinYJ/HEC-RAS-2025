using System.Security.Cryptography;
using System.Xml.Linq;
using Ras.Backend;
using Ras.Layers;
using Ras.Layers.Results;
using Utility.Units;

/// <summary>
/// Exercises the exact embedded Result.Plan associations used by the native
/// read-only viewer. The project draft deliberately points the same source Plan
/// at different models, so a same-name/current-project fallback is observable.
/// </summary>
internal static class PlanResultAssociationChecks
{
    internal static void Run()
    {
        using var directory = new TemporaryDirectory();
        string projectPath = Path.Combine(directory.FullName, "Result Plan associations.ras");
        Project project = Project.CreateNew(projectPath, UnitSystem.SI);
        string resultPath;
        string embeddedGeometryName;
        string embeddedBoundaryName;
        try
        {
            Terrain terrain = project.AddNewTerrain("Terrain");
            NValueLayer nValues = project.AddNewNValueLayer("Manning n");
            Geometry embeddedGeometry = project.AddNewGeometry("Embedded Geometry", terrain, nValues);
            Geometry currentGeometry = project.AddNewGeometry("Current Geometry", terrain, nValues);
            BoundaryCondition embeddedBoundary = project.AddNewBoundaryCondition("Embedded Boundary",
                new DateTime(2026, 10, 18), TimeSpan.FromHours(1));
            BoundaryCondition currentBoundary = project.AddNewBoundaryCondition("Current Boundary",
                new DateTime(2026, 10, 18), TimeSpan.FromHours(1));
            Plan plan = project.AddNewPlan("Source Plan", embeddedGeometry, embeddedBoundary);
            foreach (CoreLayerBase layer in Layers(project)) layer.Save();
            project.Save();

            embeddedGeometryName = embeddedGeometry.Name;
            embeddedBoundaryName = embeddedBoundary.Name;
            resultPath = project.GetUniqueResultFilename(plan.Name);
            using (Result prepared = Result.PrepareResult(resultPath, plan, embeddedGeometry,
                       embeddedBoundary, null!))
                Check(File.Exists(prepared.Filename), "The retained Result writer creates a real Result HDF.");

            // Change only the unsaved project XML context. The embedded result
            // still carries the original Plan and its original associations.
            XElement projectDraft = XElement.Load(projectPath);
            XElement association = projectDraft.Element("PlanAssociations")?.Elements("PlanAssociation")
                .Single(item => (string?)item.Attribute("Plan") == plan.Name)
                ?? throw new InvalidOperationException("The source Plan association row was not saved.");
            association.SetAttributeValue("Geometry", currentGeometry.Name);
            association.SetAttributeValue("BoundaryCondition", currentBoundary.Name);

            byte[] projectBefore = File.ReadAllBytes(projectPath);
            byte[] resultBefore = File.ReadAllBytes(resultPath);
            string revision = Hash(resultPath);
            PlanResultAssociationSnapshot snapshot = PlanResultAssociationService.Inspect(
                new(projectPath, projectDraft.ToString(SaveOptions.DisableFormatting), resultPath, revision));

            Check(snapshot.HasPlan && snapshot.PlanName == plan.Name,
                "The viewer snapshot identifies the Plan embedded in the selected Result.");
            Check(snapshot.GeometryName == embeddedGeometryName
                && snapshot.BoundaryConditionName == embeddedBoundaryName,
                "Geometry and Boundary Condition come from Result.Plan, not the current unsaved Plan association row.");
            Check(snapshot.ProjectPath == Path.GetFullPath(projectPath)
                && snapshot.ResultPath == Path.GetFullPath(resultPath)
                && snapshot.Revision == revision && snapshot.ProjectRevision == Hash(projectPath),
                "The result and project identities are returned with the inspected HDF SHA and current project-file SHA.");
            Check(File.ReadAllBytes(projectPath).SequenceEqual(projectBefore)
                && File.ReadAllBytes(resultPath).SequenceEqual(resultBefore),
                "Reading embedded associations leaves the saved project and Result HDF byte-identical.");

            Expect<SourceFileChangedException>(() => PlanResultAssociationService.Inspect(
                new(projectPath, projectDraft.ToString(SaveOptions.DisableFormatting), resultPath,
                    new string('0', revision.Length))));
            Expect<ArgumentException>(() => PlanResultAssociationService.Inspect(
                new(projectPath, projectDraft.ToString(SaveOptions.DisableFormatting), terrain.Filename,
                    Hash(terrain.Filename))));
            Check(File.ReadAllBytes(projectPath).SequenceEqual(projectBefore)
                && File.ReadAllBytes(resultPath).SequenceEqual(resultBefore),
                "A stale or non-Result request is rejected without changing either source file.");
        }
        finally
        {
            DisposeProject(project);
        }

        Console.WriteLine("Exact embedded Result.Plan association and read-only revision checks passed.");
    }

    private static IEnumerable<CoreLayerBase> Layers(Project project) => project.Plans.Cast<CoreLayerBase>()
        .Concat(project.Geometries).Concat(project.Terrains).Concat(project.BoundaryConditions)
        .Concat(project.NValues).Concat(project.ClassificationLayers);

    private static string Hash(string path)
    {
        using FileStream stream = File.OpenRead(path);
        return Convert.ToHexString(SHA256.HashData(stream));
    }

    private static void DisposeProject(Project project)
    {
        foreach (Result result in project.Results) result.Dispose();
        foreach (CoreLayerBase layer in Layers(project)) layer.Dispose();
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
