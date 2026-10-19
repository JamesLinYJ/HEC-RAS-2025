using Ras.Backend;
using Ras.Layers;

internal static class ProjectMigrationChecks
{
    internal static void Run()
    {
        using var temporary = new TemporaryDirectory();
        string invalidPath = Path.Combine(temporary.FullName, "Short.prj");
        File.WriteAllText(invalidPath, "Proj Title\n");
        var invalid = ProjectMigrationService.Inspect(new(invalidPath, temporary.FullName));
        Check(!invalid.CanExecute && invalid.ValidationMessage != null && invalid.DestinationPath == null,
            "Short v6 project is rejected before the source parser indexes its unit-system line");

        string sourceDirectory = Path.Combine(temporary.FullName, "LegacySource");
        Directory.CreateDirectory(sourceDirectory);
        string sourcePath = Path.Combine(sourceDirectory, "Legacy.prj");
        File.WriteAllLines(sourcePath, ["Proj Title=Legacy", "Current Plan=", "", "SI Units"]);
        byte[] sourceBytes = File.ReadAllBytes(sourcePath);
        var inspection = ProjectMigrationService.Inspect(new(sourcePath, temporary.FullName));
        Check(inspection.CanExecute && inspection.ProjectName == "Legacy" && inspection.Revision != null,
            "V6 source validation and revision use the retained migration format");
        Check(inspection.DestinationPath != null && !Directory.Exists(inspection.DestinationPath),
            "Inspection proposes a new destination without creating it");

        string sourceAlias = Path.Combine(temporary.FullName, "LegacySourceAlias");
        Directory.CreateSymbolicLink(sourceAlias, sourceDirectory);
        try
        {
            ProjectMigrationService.Execute(new(sourcePath, sourceAlias, inspection.Revision!));
            throw new InvalidOperationException("Source symlink alias accepted as migration output");
        }
        catch (ArgumentException error)
        {
            Check(error.Message.Contains("separate from the source", StringComparison.Ordinal),
                "Symlink aliases resolve to the same source project folder");
        }

        string caseSourceDirectory = Path.Combine(temporary.FullName, "CaseSource");
        string caseAliasDirectory = Path.Combine(temporary.FullName, "casesource");
        Directory.CreateDirectory(caseSourceDirectory);
        string caseSourcePath = Path.Combine(caseSourceDirectory, "Case.prj");
        File.WriteAllLines(caseSourcePath, ["Proj Title=Case", "Current Plan=", "", "SI Units"]);
        bool caseAliasIsSameDirectory = Directory.Exists(caseAliasDirectory);
        if (!caseAliasIsSameDirectory) Directory.CreateDirectory(caseAliasDirectory);
        caseAliasIsSameDirectory = caseAliasIsSameDirectory && File.Exists(Path.Combine(caseAliasDirectory, "Case.prj"));
        try
        {
            var caseInspection = ProjectMigrationService.Inspect(new(caseSourcePath, temporary.FullName));
            ProjectMigrationService.Execute(new(caseSourcePath, caseAliasDirectory, caseInspection.Revision!));
            throw new InvalidOperationException("Existing case-only migration output accepted");
        }
        catch (ArgumentException error)
        {
            string expected = caseAliasIsSameDirectory ? "separate from the source" : "already exists";
            Check(error.Message.Contains(expected, StringComparison.Ordinal),
                "Directory identity follows the active filesystem's case sensitivity");
        }

        File.AppendAllText(sourcePath, "\nchanged");
        try
        {
            ProjectMigrationService.Execute(new(sourcePath, inspection.DestinationPath!, inspection.Revision!));
            throw new InvalidOperationException("Changed migration source accepted");
        }
        catch (SourceFileChangedException) { }
        Check(!Directory.Exists(inspection.DestinationPath!), "Stale source leaves no migration output");

        File.WriteAllBytes(sourcePath, sourceBytes);
        var fresh = ProjectMigrationService.Inspect(new(sourcePath, temporary.FullName));
        var updates = new List<BackendOperationProgress>();
        var migrated = ProjectMigrationService.Execute(new(sourcePath, fresh.DestinationPath!, fresh.Revision!), updates.Add);
        Check(File.Exists(migrated.ProjectPath) && migrated.ProjectPath.EndsWith(".ras", StringComparison.OrdinalIgnoreCase),
            "The retained ModelConverter creates an openable RAS project in a separate output folder");
        Check(migrated.Messages?.Any(message => message.StartsWith("Saved ", StringComparison.Ordinal)) == true,
            "The retained converter's actual saved-project message is returned with the result");
        Check(updates.Any(update => update.Message?.StartsWith("Saved ", StringComparison.Ordinal) == true),
            "The retained converter's actual message is streamed while migration is running");
        string[] outputProjects = Directory.GetFiles(migrated.DestinationPath, "*.ras", SearchOption.TopDirectoryOnly);
        Check(outputProjects.Length == 1 && Path.GetFullPath(outputProjects[0]) == migrated.ProjectPath,
            "Migration success requires exactly one top-level RAS project");
        Check(File.ReadAllBytes(sourcePath).SequenceEqual(sourceBytes), "The original v6 project file remains byte-identical");

        var reopened = new Project(migrated.ProjectPath);
        try { Check(reopened.Name == migrated.ProjectName, "Migrated project can be reopened through the retained project reader"); }
        finally { Dispose(reopened); }

        var postConversion = ProjectMigrationService.Inspect(new(sourcePath, temporary.FullName));
        bool changedDuringConversion = false;
        try
        {
            ProjectMigrationService.Execute(new(sourcePath, postConversion.DestinationPath!, postConversion.Revision!), update =>
            {
                if (!changedDuringConversion && update.Message?.StartsWith("Saved ", StringComparison.Ordinal) == true)
                {
                    File.AppendAllText(sourcePath, "\nchanged during conversion");
                    changedDuringConversion = true;
                }
            });
            throw new InvalidOperationException("Source changed during conversion was accepted");
        }
        catch (SourceFileChangedException) { }
        Check(changedDuringConversion, "The retained converter emitted its saved message before the post-conversion source recheck");
        Check(Directory.Exists(postConversion.DestinationPath!) && Directory.EnumerateFiles(postConversion.DestinationPath!).Any(),
            "Post-conversion source changes fail honestly and keep partial output for diagnosis");
        File.WriteAllBytes(sourcePath, sourceBytes);
        Console.WriteLine("V6 project migration validation, source revision checks, real reporter streaming, actual conversion, output verification and source preservation passed.");
    }

    private static void Dispose(Project project)
    {
        foreach (CoreLayerBase layer in project.Plans.Cast<CoreLayerBase>()
            .Concat(project.Geometries).Concat(project.Terrains).Concat(project.BoundaryConditions)
            .Concat(project.NValues).Concat(project.ClassificationLayers)) layer.Dispose();
    }

    private static void Check(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }
}
