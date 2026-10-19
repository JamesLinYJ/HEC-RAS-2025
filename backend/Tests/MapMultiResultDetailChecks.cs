using System.Security.Cryptography;
using System.Xml.Linq;
using Geospatial.IO.ORM;
using H5Assist;
using Ras.Backend;
using Ras.Layers;
using Ras.Layers.Results;
using Ras.Output;

/// <summary>
/// Checks that map MultiResult option rows carry persisted source state from
/// their exact Result HDFs. The fixture is created with retained source writers;
/// its metadata is deterministic test data, not solver output.
/// </summary>
internal static class MapMultiResultDetailChecks
{
    internal static void Run()
    {
        using var temporary = new TemporaryDirectory();
        MapResultRenderChecks.Fixture fixture = MapResultRenderChecks.CreateFixture(temporary.FullName);
        string visualizationPath = fixture.VisualizationPath;
        string planName;
        string successPath;
        string failurePath;

        Project project = new(fixture.ProjectPath);
        try
        {
            Plan plan = project.Plans.Single();
            planName = plan.Name;
            successPath = Path.Combine(project.ResultsDirectory, "R31 multiresult success.h5");
            failurePath = Path.Combine(project.ResultsDirectory, "R31 multiresult failure.h5");
            CreateResult(plan, successPath, new ComputeSummary
            {
                Success = true,
                StartTime = new DateTime(2026, 10, 18, 2, 0, 0, DateTimeKind.Utc),
                TotalDuration = TimeSpan.FromMinutes(2)
            });
            CreateResult(plan, failurePath, new ComputeSummary
            {
                Success = false,
                FailureReason = "Model Unstable",
                StartTime = new DateTime(2026, 10, 18, 4, 0, 0, DateTimeKind.Utc),
                TotalDuration = TimeSpan.FromMinutes(1)
            });
        }
        finally
        {
            DisposeProject(project);
        }

        byte[] projectBefore = File.ReadAllBytes(fixture.ProjectPath);
        XDocument visualization = XDocument.Load(visualizationPath, LoadOptions.PreserveWhitespace);
        XElement map = visualization.Root!.Element("Maps")!.Elements("Map").ElementAt(fixture.Map.MapIndex);
        XElement resultRoot = map.Element("Tree")!.Element("Nodes")!.Elements("Node")
            .Single(node => (string?)node.Attribute("Name") == "Results");
        resultRoot.Add(new XElement("Node",
            new XAttribute("Type", "MultiResult"),
            new XAttribute("Name", planName),
            new XAttribute("IsChecked", true)));
        visualization.Save(visualizationPath, SaveOptions.DisableFormatting);

        MapTreeRequest mapRequest = fixture.Map with
        {
            ExpectedVisualizationRevision = HashFile(visualizationPath)
        };
        string[] sourcePaths = Directory.EnumerateFiles(temporary.FullName, "*", SearchOption.AllDirectories)
            .OrderBy(path => path, StringComparer.Ordinal)
            .ToArray();
        Dictionary<string, byte[]> sourceBytes = sourcePaths.ToDictionary(path => path,
            File.ReadAllBytes, StringComparer.Ordinal);

        MapResultSourcesResult snapshot = MapResultChartService.Sources(new(mapRequest, []));
        MapResultActiveNode multiResult = snapshot.ActiveNodes.Single(node => node.NodeKind == "MultiResult");
        MapResultSelectionState selection = multiResult.Selections.Single();
        MapResultSourceChoice[] choices = selection.Choices;
        string unknownPath = Path.GetFullPath(fixture.ResultPath);
        string exactSuccessPath = Path.GetFullPath(successPath);
        string exactFailurePath = Path.GetFullPath(failurePath);
        MapResultSourceChoice unknown = choices.Single(choice => PathEquals(choice.ResultPath, unknownPath));
        MapResultSourceChoice success = choices.Single(choice => PathEquals(choice.ResultPath, exactSuccessPath));
        MapResultSourceChoice failure = choices.Single(choice => PathEquals(choice.ResultPath, exactFailurePath));

        Check(choices.Length == 3 && choices.Select(choice => choice.ResultPath)
                  .Distinct(PathComparer).Count() == 3 && choices.All(choice => choice.PlanName == planName),
            "MultiResult choices retain unique exact Result file identities from the owning Plan only.");
        Check(unknown.ComputeState is null && unknown.ComputeFailureReason is null && unknown.EndTime is null,
            "A Result without a persisted Compute Summary group remains unknown rather than becoming a failed default summary.");
        Check(success.ComputeState == "completed" && success.ComputeFailureReason is null
              && failure.ComputeState == "failed"
              && failure.ComputeFailureReason == "Compute failed at some point through the simulation: Model Unstable",
            "Persisted success/failure states and the source's evaluated failure reason are carried on the matching options.");
        Check(choices.Select(choice => Path.GetFileName(choice.ResultPath))
                  .SequenceEqual([Path.GetFileName(failurePath), Path.GetFileName(successPath), Path.GetFileName(unknownPath)])
              && PathEquals(selection.SelectedResult!.ResultPath, exactFailurePath),
            "Persisted EndTime orders source choices newest first and Latest selects that exact first option.");
        Check(choices.All(choice => choice.Revision.Length == 64
              && string.Equals(choice.Revision, HashFile(choice.ResultPath), StringComparison.OrdinalIgnoreCase)
              && choice.DiagnosticStatus == "loaded" && choice.LayerErrors is not null
              && choice.DiagnosticReadError is null),
            "Each option's persisted diagnostics are bound to its exact stable Result path/SHA; loaded empty errors remain distinct from unknown.");
        Check(choices.Any(choice => choice.LayerErrors!.Any(error => error.Code == "Result_NeedsMigration"
                  && error.Severity == "Warning"
                  && error.LogData.Any(data => data.Key == "ResultName" && data.Value == choice.ResultName))),
            "The option carries the source Result.LayerErrors warning and its exact Result-name context.");
        Check(File.ReadAllBytes(fixture.ProjectPath).SequenceEqual(projectBefore)
              && sourceBytes.All(pair => File.ReadAllBytes(pair.Key).SequenceEqual(pair.Value)),
            "Map MultiResult option and diagnostic reads preserve the project, .vis, and all Result HDF bytes.");

        Console.WriteLine("Map MultiResult source choices preserve exact Result identity, persisted compute state, loaded diagnostics, source latest ordering and read-only HDF snapshots.");
    }

    private static void CreateResult(Plan plan, string path, ComputeSummary summary)
    {
        using (Result prepared = Result.PrepareResult(path, plan, plan.Geometry, plan.BoundaryCondition, null!))
        {
            if (!File.Exists(path))
                throw new InvalidDataException("The retained source Result writer did not create the R31 option HDF.");
        }
        using var writer = new H5Writer(path);
        GeospatialH5Metadata.Write(summary, writer, "/Results/" + Result.ComputeSummaryGroupName);
        // This retained old-format dataset is the actual source condition for
        // Result_NeedsMigration. An empty prepared Result has no such warning.
        writer.WriteDataset(OutputBlock.RootMeshOutputPath("Base Output", "Mesh") + "Water Surface",
            new float[] { 1f });
    }

    private static void DisposeProject(Project project)
    {
        foreach (Result result in project.Results) result.Dispose();
        foreach (CoreLayerBase layer in project.Plans.Cast<CoreLayerBase>()
                     .Concat(project.Geometries).Concat(project.Terrains)
                     .Concat(project.BoundaryConditions).Concat(project.NValues)
                     .Concat(project.ClassificationLayers))
            layer.Dispose();
    }

    private static string HashFile(string path)
    {
        using FileStream stream = File.OpenRead(path);
        return Convert.ToHexString(SHA256.HashData(stream));
    }

    private static bool PathEquals(string first, string second) => string.Equals(Path.GetFullPath(first),
        Path.GetFullPath(second), OperatingSystem.IsWindows()
            ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal);

    private static StringComparer PathComparer => OperatingSystem.IsWindows()
        ? StringComparer.OrdinalIgnoreCase : StringComparer.Ordinal;

    private static void Check(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }
}
