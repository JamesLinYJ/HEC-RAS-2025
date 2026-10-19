using System.Security.Cryptography;
using Geospatial.IO.ORM;
using H5Assist;
using Ras.Backend;
using Ras.Layers;
using Ras.Layers.Results;
using Utility.Units;

internal static class CatalogHeaderActionChecks
{
    internal static void Run()
    {
        using var temporary = new TemporaryDirectory();
        VerifyProjectionExport(temporary.FullName);
        VerifyIncompleteResultPreparation(temporary.FullName);
        Console.WriteLine("Project projection export and exact incomplete Result preflight checks passed.");
    }

    private static void VerifyProjectionExport(string directory)
    {
        string projectPath = Path.Combine(directory, "Projection Export.ras");
        Project project = Project.CreateNew(projectPath, ProjectionDefinition.FromEPSG(32650));
        try { project.Save(); }
        finally { DisposeProject(project); }

        byte[] projectBytes = File.ReadAllBytes(projectPath);
        string projectRevision = Hash(projectPath);
        string output = Path.Combine(directory, "Exports", "Projection.prj");
        var request = new ProjectProjectionExportRequest(projectPath,
            File.ReadAllText(projectPath), projectRevision, output);

        ProjectProjectionExportReceipt first = ProjectProjectionExportService.Export(request);
        Check(Path.GetFullPath(first.OutputPath) == Path.GetFullPath(output)
            && first.ProjectRevision == projectRevision
            && File.Exists(first.OutputPath) && new FileInfo(first.OutputPath).Length > 0,
            "Projection export uses the retained Projection.ExportEsri API and returns its committed output and project revision.");
        byte[] firstBytes = File.ReadAllBytes(first.OutputPath);

        ProjectProjectionExportReceipt second = ProjectProjectionExportService.Export(request);
        Check(Path.GetFullPath(second.OutputPath) == Path.GetFullPath(Path.Combine(directory, "Exports", "Projection (1).prj"))
            && File.ReadAllBytes(first.OutputPath).SequenceEqual(firstBytes)
            && File.Exists(second.OutputPath) && new FileInfo(second.OutputPath).Length > 0,
            "A repeated export selects a unique .prj destination without overwriting the prior user file.");
        Check(File.ReadAllBytes(projectPath).SequenceEqual(projectBytes),
            "Projection export does not save the captured project XML or modify the source project.");

        File.AppendAllText(projectPath, " ");
        string staleOutput = Path.Combine(directory, "Exports", "Stale.prj");
        ExpectChanged(() => ProjectProjectionExportService.Export(request with { DestinationPath = staleOutput }));
        Check(!File.Exists(staleOutput), "A stale project revision is rejected before publishing an export file.");
    }

    private static void VerifyIncompleteResultPreparation(string directory)
    {
        string projectPath = Path.Combine(directory, "Incomplete Result.ras");
        string resultPath;
        string terrainPath;
        Project project = Project.CreateNew(projectPath, UnitSystem.SI);
        try
        {
            Terrain terrain = project.AddNewTerrain("Terrain");
            NValueLayer nValues = project.AddNewNValueLayer("NValues");
            Geometry geometry = project.AddNewGeometry("Geometry", terrain, nValues);
            BoundaryCondition boundary = project.AddNewBoundaryCondition("Boundary",
                new DateTime(2026, 10, 16), TimeSpan.FromHours(1));
            Plan plan = project.AddNewPlan("Plan", geometry, boundary);
            foreach (CoreLayerBase layer in ProjectLayers(project)) layer.Save();
            project.Save();
            terrainPath = terrain.Filename;
            resultPath = Path.Combine(project.ResultsDirectory, "Uncomputed Result.h5");
            using (Result createdResult = Result.PrepareResult(resultPath, plan, geometry, boundary, null!)) { }
        }
        finally { DisposeProject(project); }

        byte[] projectBytes = File.ReadAllBytes(projectPath);
        byte[] resultBytes = File.ReadAllBytes(resultPath);
        string projectRevision = Hash(projectPath), resultRevision = Hash(resultPath);
        var request = new IncompleteResultDeletePreparationRequest(projectPath,
            File.ReadAllText(projectPath), projectRevision, resultPath, resultRevision);

        IncompleteResultDeletePreparation prepared = ResultRemovalService.PrepareIncomplete(request);
        Check(Path.GetFullPath(prepared.ProjectPath) == Path.GetFullPath(projectPath)
            && Path.GetFullPath(prepared.ResultPath) == Path.GetFullPath(resultPath)
            && prepared.ResultRevision == resultRevision
            && prepared.ResultName == "Uncomputed Result",
            "The exact uncomputed Project.Result is eligible and its canonical source identity and SHA are returned.");
        Check(File.ReadAllBytes(projectPath).SequenceEqual(projectBytes)
            && File.ReadAllBytes(resultPath).SequenceEqual(resultBytes),
            "Result removal preparation is read-only and leaves the project and Result source byte-identical.");

        ExpectArgument(() => ResultRemovalService.PrepareIncomplete(request with {
            ResultPath = terrainPath,
            ResultRevision = Hash(terrainPath)
        }));
        Check(File.Exists(terrainPath) && File.ReadAllBytes(resultPath).SequenceEqual(resultBytes),
            "An associated Terrain is not mistaken for a Result and is never modified by preflight.");

        using (var writer = new H5Writer(resultPath))
            GeospatialH5Metadata.Write(new ComputeSummary
            {
                Success = true,
                StartTime = new DateTime(2026, 10, 16),
                TotalDuration = TimeSpan.FromMinutes(1)
            }, writer, "/Results/" + Result.ComputeSummaryGroupName);
        using (var persistedResult = new Result(resultPath))
            Check(persistedResult.ComputeSummary?.Success == true,
                "The successful-result fixture reloads its persisted Compute Summary as successful.");
        byte[] successfulBytes = File.ReadAllBytes(resultPath);
        var successfulRequest = request with { ResultRevision = Hash(resultPath) };
        ExpectInvalidOperation(() => ResultRemovalService.PrepareIncomplete(successfulRequest),
            "The selected Result completed successfully and cannot be removed as incomplete.");
        Check(File.ReadAllBytes(resultPath).SequenceEqual(successfulBytes),
            "A Result with a real persisted successful Compute Summary cannot be removed as incomplete.");

        File.AppendAllText(resultPath, "external change");
        ExpectChanged(() => ResultRemovalService.PrepareIncomplete(successfulRequest));
        File.WriteAllBytes(resultPath, successfulBytes);
        File.AppendAllText(projectPath, " ");
        ExpectChanged(() => ResultRemovalService.PrepareIncomplete(successfulRequest));
        File.WriteAllBytes(projectPath, projectBytes);
        Check(File.ReadAllBytes(projectPath).SequenceEqual(projectBytes)
            && File.ReadAllBytes(resultPath).SequenceEqual(successfulBytes),
            "Changed Result or project revisions are rejected without changing either source.");
    }

    private static IEnumerable<CoreLayerBase> ProjectLayers(Project project) =>
        project.Plans.Cast<CoreLayerBase>().Concat(project.Geometries).Concat(project.BoundaryConditions)
            .Concat(project.Terrains).Concat(project.NValues).Concat(project.ClassificationLayers);

    private static void DisposeProject(Project project)
    {
        foreach (Result result in project.Results) result.Dispose();
        foreach (CoreLayerBase layer in ProjectLayers(project)) layer.Dispose();
    }

    private static string Hash(string path)
    {
        using FileStream stream = File.OpenRead(path);
        return Convert.ToHexString(SHA256.HashData(stream));
    }

    private static void ExpectChanged(Action action)
    {
        try { action(); }
        catch (SourceFileChangedException) { return; }
        throw new InvalidOperationException("A stale source revision was accepted.");
    }

    private static void ExpectArgument(Action action)
    {
        try { action(); }
        catch (ArgumentException) { return; }
        throw new InvalidOperationException("A non-Result project asset was accepted for incomplete Result removal.");
    }

    private static void ExpectInvalidOperation(Action action, string expectedMessage)
    {
        try { action(); }
        catch (InvalidOperationException exception) when (exception.Message == expectedMessage) { return; }
        throw new InvalidOperationException("The successful Result was accepted or rejected for an unexpected reason.");
    }

    private static void Check(bool value, string message)
    {
        if (!value) throw new InvalidOperationException(message);
    }
}
