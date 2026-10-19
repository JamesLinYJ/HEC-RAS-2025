using System.Security.Cryptography;
using System.Xml.Linq;
using H5Assist;
using Ras.Backend;
using Ras.Layers;
using Ras.Output;
using Utility.Units;

internal static class ResultInspectorChecks
{
    internal static void Run()
    {
        using var temporary = new TemporaryDirectory();
        string projectPath = Path.Combine(temporary.FullName, "结果检查.ras");
        var project = Project.CreateNew(projectPath, UnitSystem.SI);
        var terrain = project.AddNewTerrain("项目地形");
        string terrainName = terrain.Name;
        string terrainPath = terrain.Filename;
        var values = project.AddNewNValueLayer("项目糙率");
        var geometry = project.AddNewGeometry("嵌入几何", terrain, values);
        var boundary = project.AddNewBoundaryCondition("嵌入边界", new DateTime(2026, 10, 16), TimeSpan.FromHours(1));
        var plan = project.AddNewPlan("嵌入方案", geometry, boundary);
        plan.Description = "Result Plan snapshot description";
        geometry.Description = "Result Geometry snapshot description";
        boundary.Description = "Result Boundary snapshot description";
        plan.Save();
        geometry.Save();
        boundary.Save();
        project.Save();

        string resultPath = project.GetUniqueResultFilename(plan.Name);
        using (Result created = Result.PrepareResult(resultPath, plan, geometry, boundary, null!))
        {
            Check(File.Exists(resultPath), "The original Result.PrepareResult API writes a source HDF5 result.");
        }
        // Seed the exact legacy output dataset checked by source
        // Result.NeedsConvertToNewFormat so Result.LayerErrors returns its
        // actual migration warning after reopening the HDF.
        using (var writer = new H5Writer(resultPath))
            writer.WriteDataset(OutputBlock.RootMeshOutputPath("Base Output", "Mesh") + "Water Surface",
                new float[] { 1f });

        // Keep the current project's files at the same paths and names, but
        // change their persisted metadata after the Result has captured its own
        // embedded Plan/Geometry/Boundary snapshots.
        plan.Description = "Current project Plan metadata";
        geometry.Description = "Current project Geometry metadata";
        boundary.Description = "Current project Boundary metadata";
        plan.Save();
        geometry.Save();
        boundary.Save();
        DisposeProject(project);

        Project changedProject = new(projectPath);
        Check(changedProject.Plans.Single().Description == "Current project Plan metadata"
            && changedProject.Geometries.Single().Description == "Current project Geometry metadata"
            && changedProject.BoundaryConditions.Single().Description == "Current project Boundary metadata",
            "Same-named current project HDF sources now carry changed metadata at the same source paths.");
        DisposeProject(changedProject);

        byte[] projectBytes = File.ReadAllBytes(projectPath);
        byte[] resultBytes = File.ReadAllBytes(resultPath);
        string revision = HashFile(resultPath);
        XElement draft = XElement.Load(projectPath);
        XElement associations = draft.Element("ResultAssociations") ?? new XElement("ResultAssociations");
        associations.Add(new XElement("ResultAssociation",
            new XAttribute("Result", Path.GetFileNameWithoutExtension(resultPath)),
            new XAttribute("OverrideTerrain", terrainName)));
        if (associations.Parent == null) draft.Add(associations);

        var snapshot = ResultInspectorService.Inspect(new(projectPath, draft.ToString(SaveOptions.DisableFormatting), resultPath, revision));
        Check(Path.IsPathFullyQualified(snapshot.ResultPath) && snapshot.Revision == revision
            && File.ReadAllBytes(snapshot.ResultPath).SequenceEqual(resultBytes),
            "Inspection resolves the source HDF through the returned absolute path with its exact SHA-256 revision.");
        Check(snapshot.Name == "嵌入方案"
            && snapshot.Plan is { Name: "嵌入方案", Description: "Result Plan snapshot description", EmbeddedInResult: true }
            && snapshot.Geometry is { Name: "嵌入几何", Description: "Result Geometry snapshot description", EmbeddedInResult: true }
            && snapshot.BoundaryCondition is { Name: "嵌入边界", Description: "Result Boundary snapshot description", EmbeddedInResult: true },
            "Plan, geometry and boundary identities and metadata come from the Result's embedded model snapshots even when same-named project sources have changed.");
        Check(!snapshot.HasComputed && snapshot.ProfileCount == 0 && snapshot.ComputeSummary == null,
            "The prepared, uncomputed source result has no invented compute summary or profile data.");
        Check(snapshot.OutputBlocks.Length > 0 && snapshot.OutputBlocks.All(block => block.ProfileCount == block.ProfileNames.Length),
            "Output block/profile metadata comes from the actual reopened Result HDF.");
        Check(snapshot.TerrainChoices.SequenceEqual(new[] { terrainName })
            && snapshot.OverrideTerrainName == terrainName && snapshot.AssociatedTerrainName == terrainName
            && snapshot.ShowAutoDetectedTerrain == false,
            "A current project XML draft resolves the source terrain override without saving it.");
        Project errorProject = new(projectPath);
        try
        {
            Result sourceResult = errorProject.Results.Single(candidate =>
                Path.GetFullPath(candidate.Filename) == Path.GetFullPath(resultPath));
            var sourceErrors = sourceResult.LayerErrors ?? [];
            Check(sourceErrors.Count > 0
                && snapshot.LayerErrors.Length == sourceErrors.Count
                && snapshot.LayerErrors.Select((item, index) =>
                    item.Code == sourceErrors[index].MessageType?.Code
                    && item.Severity == sourceErrors[index].MessageType?.DefaultSeverity.ToString()
                    && item.EvaluatedMessage == sourceErrors[index].EvaluatedMessage
                    && item.LogData.SequenceEqual(sourceErrors[index].LogData.Select(pair =>
                        new ResultInspectorLogDatum(pair.Key, FormatLogValue(pair.Value)))))
                    .All(matches => matches),
                "Inspection returns actual Result.LayerErrors in source order with severity, evaluated text, and formatted named values.");
            Check(snapshot.LayerErrors.Any(message =>
                    message.Code == "Result_NeedsMigration"
                    && message.Severity == "Warning"
                    && message.LogData.Any(value => value.Key == "ResultName" && value.Value == snapshot.Name)),
                "A legacy-format Result produces its actual migration warning and ResultName named value.");
        }
        finally
        {
            DisposeProject(errorProject);
        }
        Check(File.ReadAllBytes(projectPath).SequenceEqual(projectBytes), "Inspection never saves the project's unsaved result association draft.");
        Check(File.ReadAllBytes(resultPath).SequenceEqual(resultBytes), "Inspection leaves the source result HDF byte-identical.");

        var deletePreparation = ResultInspectorService.PrepareDelete(new(projectPath,
            draft.ToString(SaveOptions.DisableFormatting), resultPath, revision));
        Check(Path.IsPathFullyQualified(deletePreparation.ProjectPath)
            && Path.IsPathFullyQualified(deletePreparation.ResultPath)
            && Path.GetFileName(deletePreparation.ProjectPath) == Path.GetFileName(projectPath)
            && Path.GetFileName(deletePreparation.ResultPath) == Path.GetFileName(resultPath)
            && deletePreparation.Name == "嵌入方案" && deletePreparation.Revision == revision,
            "Delete preparation returns the exact current-project Result identity and SHA without performing deletion.");
        ExpectArgument(() => ResultInspectorService.PrepareDelete(new(projectPath,
            draft.ToString(SaveOptions.DisableFormatting), terrainPath, HashFile(terrainPath))));
        Check(File.Exists(terrainPath) && File.ReadAllBytes(projectPath).SequenceEqual(projectBytes)
            && File.ReadAllBytes(resultPath).SequenceEqual(resultBytes),
            "Delete preparation rejects a referenced terrain file and never mutates the Result, project draft source, or terrain.");

        File.AppendAllText(resultPath, "external change");
        ExpectChanged(() => ResultInspectorService.Inspect(new(projectPath, draft.ToString(SaveOptions.DisableFormatting), resultPath, revision)));
        ExpectChanged(() => ResultInspectorService.PrepareDelete(new(projectPath,
            draft.ToString(SaveOptions.DisableFormatting), resultPath, revision)));
        File.WriteAllBytes(resultPath, resultBytes);
        Check(File.ReadAllBytes(projectPath).SequenceEqual(projectBytes)
            && File.ReadAllBytes(resultPath).SequenceEqual(resultBytes),
            "A stale result revision is rejected and both original files remain unchanged after restoration.");

        Console.WriteLine("Source Result inspection, embedded snapshots, project-draft terrain association, output metadata and stale HDF revision checks passed.");
    }

    private static string HashFile(string path)
    {
        using FileStream stream = File.OpenRead(path);
        return Convert.ToHexString(SHA256.HashData(stream));
    }

    private static string? FormatLogValue(object? value) => value switch
    {
        null => null,
        IFormattable formatted => formatted.ToString(null, System.Globalization.CultureInfo.InvariantCulture),
        _ => value.ToString()
    };

    private static void DisposeProject(Project project)
    {
        foreach (Result result in project.Results) result.Dispose();
        foreach (CoreLayerBase layer in project.Plans.Cast<CoreLayerBase>()
                     .Concat(project.Geometries).Concat(project.Terrains)
                     .Concat(project.BoundaryConditions).Concat(project.NValues)
                     .Concat(project.ClassificationLayers))
            layer.Dispose();
    }

    private static void ExpectChanged(Action action)
    {
        try { action(); }
        catch (SourceFileChangedException) { return; }
        throw new InvalidOperationException("A result inspection with a stale source revision was accepted.");
    }

    private static void ExpectArgument(Action action)
    {
        try { action(); }
        catch (ArgumentException) { return; }
        throw new InvalidOperationException("A non-result project asset was accepted for result deletion.");
    }

    private static void Check(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }
}
