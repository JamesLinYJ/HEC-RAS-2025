using System.Security.Cryptography;
using Ras.Backend;
using Ras.Layers;
using Utility.Units;

internal static class GeometryNamedBackupChecks
{
    internal static void Run()
    {
        using var temporary = new TemporaryDirectory();
        Fixture fixture = CreateFixture(temporary.FullName);
        byte[] projectBefore = File.ReadAllBytes(fixture.ProjectPath);
        byte[] geometryBefore = File.ReadAllBytes(fixture.GeometryPath);

        GeometryNamedBackupReceipt first = GeometryBackupService.CreateNamed(Request(fixture, "Manual backup"));
        string expectedDirectory = Path.Combine(Path.GetDirectoryName(fixture.GeometryPath)!,
            Path.GetFileNameWithoutExtension(fixture.GeometryPath) + " Backups");
        Check(Path.GetDirectoryName(first.BackupPath) == expectedDirectory &&
              Path.GetFileName(first.BackupPath) == "Manual backup.h5",
            "The named backup is written into the source Geometry Backups folder with the entered name");
        Check(first.ProjectRevision == fixture.ProjectRevision &&
              first.GeometryRevision == fixture.GeometryRevision &&
              first.ProjectXmlFingerprint == fixture.ProjectXmlFingerprint &&
              first.BackupRevision == HashFile(first.BackupPath),
            "The receipt binds the saved project, draft XML, exact Geometry and new backup bytes");
        Check(File.ReadAllBytes(fixture.ProjectPath).SequenceEqual(projectBefore) &&
              File.ReadAllBytes(fixture.GeometryPath).SequenceEqual(geometryBefore),
            "Creating a named backup leaves the project and source Geometry bytes unchanged");
        using (var reopened = new Geometry(first.BackupPath))
            Check(!reopened.HasLoadErrors, "The named backup reopens as a retained Geometry HDF");

        GeometryNamedBackupReceipt duplicate = GeometryBackupService.CreateNamed(Request(fixture, "Manual backup"));
        Check(Path.GetFileName(duplicate.BackupPath) == "Manual backup (1).h5" &&
              File.ReadAllBytes(fixture.ProjectPath).SequenceEqual(projectBefore) &&
              File.ReadAllBytes(fixture.GeometryPath).SequenceEqual(geometryBefore),
            "A duplicate name follows FileHelpers.UniqueFilename without replacing either source or backup");

        string[] beforeRejectedName = Directory.GetFiles(expectedDirectory).Select(Path.GetFullPath).Order().ToArray();
        bool rejectedPathName = false;
        try { _ = GeometryBackupService.CreateNamed(Request(fixture, "../escape")); }
        catch (ArgumentException) { rejectedPathName = true; }
        Check(rejectedPathName &&
              Directory.GetFiles(expectedDirectory).Select(Path.GetFullPath).Order().SequenceEqual(beforeRejectedName) &&
              File.ReadAllBytes(fixture.ProjectPath).SequenceEqual(projectBefore) &&
              File.ReadAllBytes(fixture.GeometryPath).SequenceEqual(geometryBefore),
            "Path separators are rejected before they can escape the retained backup directory");

        RejectStaleGeometry(fixture, expectedDirectory);
        RejectStaleProject(fixture, expectedDirectory);

        CatalogTreeSnapshot refreshed = CatalogTreeService.LoadCatalog(new CatalogTreeRequest(
            fixture.ProjectPath, fixture.ProjectXml));
        Check(FindBackup(refreshed, first.BackupPath) != null && FindBackup(refreshed, duplicate.BackupPath) != null,
            "A normal catalog reload discovers both retained named backups");
        Console.WriteLine("Named Geometry backup uses ObservableGeometry.CheckCreateBackup semantics, preserves source bytes, and rejects stale inputs.");
    }

    private static Fixture CreateFixture(string root)
    {
        string projectPath = Path.Combine(root, "Named Backup.ras");
        Project project = Project.CreateNew(projectPath, UnitSystem.SI);
        try
        {
            Geometry geometry = project.AddNewGeometry("Named geometry");
            geometry.Save();
            project.Save();
            string projectXml = File.ReadAllText(projectPath);
            return new Fixture(projectPath, geometry.Filename, projectXml,
                HashFile(projectPath), HashFile(geometry.Filename), HashText(projectXml));
        }
        finally { Dispose(project); }
    }

    private static GeometryNamedBackupRequest Request(Fixture fixture, string name) => new(
        fixture.ProjectPath,
        fixture.ProjectXml,
        fixture.ProjectRevision,
        fixture.GeometryPath,
        SourceFilePaths.Canonical(fixture.GeometryPath),
        fixture.GeometryRevision,
        name);

    private static void RejectStaleGeometry(Fixture fixture, string backupDirectory)
    {
        byte[] original = File.ReadAllBytes(fixture.GeometryPath);
        try
        {
            File.AppendAllText(fixture.GeometryPath, "changed after catalog inspection");
            string[] before = Directory.Exists(backupDirectory)
                ? Directory.GetFiles(backupDirectory).Select(Path.GetFullPath).Order().ToArray()
                : [];
            bool rejected = false;
            try { _ = GeometryBackupService.CreateNamed(Request(fixture, "Stale geometry")); }
            catch (SourceFileChangedException) { rejected = true; }
            string[] after = Directory.Exists(backupDirectory)
                ? Directory.GetFiles(backupDirectory).Select(Path.GetFullPath).Order().ToArray()
                : [];
            Check(rejected && before.SequenceEqual(after),
                "A stale Geometry revision is rejected without creating a backup");
        }
        finally { File.WriteAllBytes(fixture.GeometryPath, original); }
    }

    private static void RejectStaleProject(Fixture fixture, string backupDirectory)
    {
        byte[] original = File.ReadAllBytes(fixture.ProjectPath);
        try
        {
            File.AppendAllText(fixture.ProjectPath, "changed after catalog inspection");
            string[] before = Directory.Exists(backupDirectory)
                ? Directory.GetFiles(backupDirectory).Select(Path.GetFullPath).Order().ToArray()
                : [];
            bool rejected = false;
            try { _ = GeometryBackupService.CreateNamed(Request(fixture, "Stale project")); }
            catch (SourceFileChangedException) { rejected = true; }
            string[] after = Directory.Exists(backupDirectory)
                ? Directory.GetFiles(backupDirectory).Select(Path.GetFullPath).Order().ToArray()
                : [];
            Check(rejected && before.SequenceEqual(after),
                "A stale saved-project revision is rejected without creating a backup");
        }
        finally { File.WriteAllBytes(fixture.ProjectPath, original); }
    }

    private static CatalogTreeNode? FindBackup(CatalogTreeSnapshot snapshot, string path)
    {
        foreach (CatalogTreeNode root in snapshot.Roots)
            if (Find(root) is { } found) return found;
        return null;

        CatalogTreeNode? Find(CatalogTreeNode node)
        {
            if (node.SourceClass == "BackupNodeVM" && node.BackupSummary is { } summary &&
                SourceFilePaths.Canonical(summary.Filename) == SourceFilePaths.Canonical(path)) return node;
            foreach (CatalogTreeNode child in node.Children ?? [])
                if (Find(child) is { } found) return found;
            return null;
        }
    }

    private static string HashFile(string path)
    {
        using var stream = File.OpenRead(path);
        return Convert.ToHexString(SHA256.HashData(stream));
    }

    private static string HashText(string value) => Convert.ToHexString(SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(value)));

    private static void Dispose(Project project)
    {
        foreach (CoreLayerBase layer in project.Plans.Cast<CoreLayerBase>().Concat(project.Geometries)
            .Concat(project.Terrains).Concat(project.BoundaryConditions).Concat(project.NValues)
            .Concat(project.ClassificationLayers)) layer.Dispose();
        foreach (Result result in project.Results) result.Dispose();
    }

    private static void Check(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }

    private sealed record Fixture(string ProjectPath, string GeometryPath, string ProjectXml,
        string ProjectRevision, string GeometryRevision, string ProjectXmlFingerprint);
}
