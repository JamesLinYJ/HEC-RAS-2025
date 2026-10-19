using System.Security.Cryptography;
using System.Text;
using System.Xml.Linq;
using Ras.Backend;
using Ras.Layers;
using Utility.Units;

internal static class GeometryBackupChecks
{
    internal static void Run()
    {
        using var temporary = new TemporaryDirectory();
        Fixture fixture = CreateFixture(temporary.FullName);
        GeometryBackupRestoreRequest request = RequestFor(fixture, draftDescription: "unsaved description");

        CatalogTreeSnapshot catalog = CatalogTreeService.LoadCatalog(new CatalogTreeRequest(
            fixture.ProjectPath, request.ProjectXml));
        CatalogTreeNode backupNode = FindBackup(catalog, fixture.BackupPath);
        CatalogTreeBackupSummary summary = backupNode.BackupSummary
            ?? throw new InvalidOperationException("The selected backup summary was not returned.");
        Check(summary.CanSaveAsNewGeometry && summary.Revision == fixture.BackupRevision &&
            summary.ParentGeometryPath == fixture.ParentCanonicalPath &&
            summary.ParentGeometryRevision == fixture.ParentRevision &&
            summary.ProjectRevision == fixture.ProjectRevision &&
            backupNode.AssetID == fixture.BackupCanonicalPath,
            "Catalog exposes selected backup, parent and project physical identity with stable SHA revisions");
        RejectStaleBackupAndCleanStage(fixture);
        RejectStaleProjectAndParentAndCleanStage(fixture);

        Check(fixture.ExpectedBaseName.Length > 64 &&
              !CoreLayerBase.IsLegalName(fixture.ExpectedBaseName, out _),
            "The backup-derived Geometry filename exceeds the model creation dialog's 64-character limit");
        string collisionPath = Geometry.MakeFilename(Path.GetDirectoryName(fixture.ProjectPath)!, fixture.ExpectedBaseName);
        File.Copy(fixture.BackupPath, collisionPath);
        byte[] collisionBytes = File.ReadAllBytes(collisionPath);
        byte[] projectBytesBeforeRestore = File.ReadAllBytes(fixture.ProjectPath);

        GeometryBackupRestoreReceipt receipt = GeometryBackupService.Restore(request);
        Check(receipt.NewName == fixture.ExpectedBaseName + " (1)" &&
              SourceFilePathsForTest(receipt.NewAssetPath) == SourceFilePathsForTest(
                  Geometry.MakeFilename(Path.GetDirectoryName(fixture.ProjectPath)!, receipt.NewName)),
            "Restore applies the retained Geometry naming pattern and advances safely around an existing file");
        Check(HashFile(fixture.BackupPath) == fixture.BackupRevision &&
              HashFile(fixture.ParentPath) == fixture.ParentRevision &&
              File.ReadAllBytes(fixture.ProjectPath).SequenceEqual(projectBytesBeforeRestore) &&
              File.ReadAllBytes(collisionPath).SequenceEqual(collisionBytes),
            "Restore leaves the selected backup, source Geometry, Project XML, and colliding Geometry bytes unchanged");
        Check(receipt.ProjectXmlFingerprint == HashText(request.ProjectXml) &&
              receipt.BackupRevision == fixture.BackupRevision &&
              receipt.ParentGeometryRevision == fixture.ParentRevision &&
              receipt.ProjectRevision == fixture.ProjectRevision &&
              HashFile(receipt.NewAssetPath) == fixture.BackupRevision,
            "Receipt binds the exact draft and published HDF bytes without saving the draft");

        using (var reopened = new Geometry(receipt.NewAssetPath))
            Check(!reopened.HasLoadErrors && reopened.Name == receipt.NewName,
                "The restored HDF independently reopens as the new Geometry name");
        var rereadProject = new Project(fixture.ProjectPath);
        try
        {
            Check(rereadProject.Geometries.Any(geometry =>
                    SourceFilePathsForTest(geometry.Filename) == SourceFilePathsForTest(receipt.NewAssetPath)),
                "The next source Project load discovers the restored Geometry without editing XML");
        }
        finally { Dispose(rereadProject); }
        CatalogTreeSnapshot refreshed = CatalogTreeService.LoadCatalog(new CatalogTreeRequest(
            fixture.ProjectPath, request.ProjectXml));
        Check(FindGeometry(refreshed, receipt.NewAssetPath) != null &&
              File.ReadAllBytes(fixture.ProjectPath).SequenceEqual(projectBytesBeforeRestore),
            "A refreshed catalog includes the new Geometry while the unsaved Project XML draft stays unsaved");

        Console.WriteLine("Geometry backup restore preserves the selected source, publishes a collision-free Geometry HDF, and keeps Project XML unchanged.");
    }

    private static Fixture CreateFixture(string root)
    {
        string projectPath = Path.Combine(root, "Backup Restore.ras");
        string parentName = new string('P', 58);
        string backupName = new string('B', 24);
        var project = Project.CreateNew(projectPath, UnitSystem.SI);
        Geometry parent = project.AddNewGeometry(parentName);
        parent.Save();
        project.Save();
        string backupDirectory = Path.Combine(Path.GetDirectoryName(parent.Filename)!,
            Path.GetFileNameWithoutExtension(parent.Filename) + " Backups");
        Directory.CreateDirectory(backupDirectory);
        string backupPath = Path.Combine(backupDirectory, backupName + ".h5");
        parent.SaveGeometryBackup(backupPath);
        string parentPath = parent.Filename;
        string expectedBaseName = parent.Name + " - " + Path.GetFileNameWithoutExtension(backupPath);
        Dispose(project);

        Check(parentName.Length <= 64 && backupName.Length <= 64 && expectedBaseName.Length > 64,
            "The fixture uses individually valid source names whose combined backup restore name exceeds 64 characters");

        return new Fixture(projectPath, parentPath, backupPath,
            HashFile(parentPath), HashFile(backupPath), HashFile(projectPath),
            SourceFilePathsForTest(parentPath), SourceFilePathsForTest(backupPath),
            expectedBaseName);
    }

    private static GeometryBackupRestoreRequest RequestFor(Fixture fixture, string draftDescription)
    {
        XElement draft = XElement.Load(fixture.ProjectPath);
        XElement? project = draft.Name.LocalName == "Project" ? draft : draft.Element("Project");
        if (project == null) throw new InvalidDataException("Project XML root is missing.");
        XElement? description = project.Element("Description");
        if (description == null) project.Add(new XElement("Description", draftDescription));
        else description.Value = draftDescription;
        return new GeometryBackupRestoreRequest(
            fixture.ProjectPath,
            draft.ToString(SaveOptions.DisableFormatting),
            fixture.BackupPath,
            fixture.BackupCanonicalPath,
            fixture.BackupRevision,
            fixture.ParentCanonicalPath,
            fixture.ParentRevision,
            fixture.ProjectRevision);
    }

    private static void RejectStaleBackupAndCleanStage(Fixture fixture)
    {
        GeometryBackupRestoreRequest request = RequestFor(fixture, "unsaved description");
        byte[] originalBackup = File.ReadAllBytes(fixture.BackupPath);
        string expectedTarget = Geometry.MakeFilename(Path.GetDirectoryName(fixture.ProjectPath)!, fixture.ExpectedBaseName);
        try
        {
            File.AppendAllText(fixture.BackupPath, "changed after catalog inspection", Encoding.UTF8);
            bool rejected = false;
            try { _ = GeometryBackupService.Restore(request); }
            catch (SourceFileChangedException) { rejected = true; }
            Check(rejected && !File.Exists(expectedTarget) && !Directory.EnumerateDirectories(
                    Path.GetDirectoryName(expectedTarget)!, ".geometry-backup-restore-*").Any(),
                "A changed selected backup is rejected before publication and leaves no staging directory");
        }
        finally { File.WriteAllBytes(fixture.BackupPath, originalBackup); }
    }

    private static void RejectStaleProjectAndParentAndCleanStage(Fixture fixture)
    {
        GeometryBackupRestoreRequest request = RequestFor(fixture, "unsaved description");
        string expectedTarget = Geometry.MakeFilename(Path.GetDirectoryName(fixture.ProjectPath)!, fixture.ExpectedBaseName);
        byte[] originalProject = File.ReadAllBytes(fixture.ProjectPath);
        try
        {
            XElement changed = XElement.Load(fixture.ProjectPath);
            XElement project = changed.Name.LocalName == "Project" ? changed :
                changed.Element("Project") ?? throw new InvalidDataException("Project XML root is missing.");
            XElement? description = project.Element("Description");
            if (description == null) project.Add(new XElement("Description", "external project edit"));
            else description.Value = "external project edit";
            File.WriteAllText(fixture.ProjectPath, changed.ToString(SaveOptions.DisableFormatting), Encoding.UTF8);
            bool rejected = false;
            try { _ = GeometryBackupService.Restore(request); }
            catch (SourceFileChangedException) { rejected = true; }
            Check(rejected && !File.Exists(expectedTarget),
                "An external Project XML change after catalog inspection blocks restore before publication");
        }
        finally { File.WriteAllBytes(fixture.ProjectPath, originalProject); }

        byte[] originalParent = File.ReadAllBytes(fixture.ParentPath);
        try
        {
            File.AppendAllText(fixture.ParentPath, "changed after catalog inspection", Encoding.UTF8);
            bool rejected = false;
            try { _ = GeometryBackupService.Restore(request); }
            catch (SourceFileChangedException) { rejected = true; }
            Check(rejected && !File.Exists(expectedTarget),
                "A changed parent Geometry revision blocks restore before publication");
        }
        finally { File.WriteAllBytes(fixture.ParentPath, originalParent); }

        Check(!Directory.EnumerateDirectories(Path.GetDirectoryName(expectedTarget)!,
                ".geometry-backup-restore-*").Any(),
            "Stale Project and parent checks leave no owned staging directories");
    }

    private static CatalogTreeNode FindBackup(CatalogTreeSnapshot snapshot, string backupPath)
    {
        foreach (CatalogTreeNode root in snapshot.Roots)
        {
            CatalogTreeNode? match = Find(root);
            if (match != null) return match;
        }
        throw new InvalidOperationException("The selected Geometry backup is missing from the catalog tree.");

        CatalogTreeNode? Find(CatalogTreeNode node)
        {
            if (node.SourceClass == "BackupNodeVM" && node.BackupSummary is { } summary &&
                SourceFilePathsForTest(summary.Filename) == SourceFilePathsForTest(backupPath)) return node;
            foreach (CatalogTreeNode child in node.Children ?? [])
                if (Find(child) is { } found) return found;
            return null;
        }
    }

    private static CatalogTreeNode? FindGeometry(CatalogTreeSnapshot snapshot, string assetPath)
    {
        foreach (CatalogTreeNode root in snapshot.Roots)
            if (Find(root) is { } match) return match;
        return null;

        CatalogTreeNode? Find(CatalogTreeNode node)
        {
            if (node.SourceClass == "ObservableGeometry" &&
                node.AssetID is { } id && SourceFilePathsForTest(id) == SourceFilePathsForTest(assetPath)) return node;
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

    private static string HashText(string value) => Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(value)));

    private static string SourceFilePathsForTest(string path) => MapSourceTestPaths.Physical(path);

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

    private sealed record Fixture(string ProjectPath, string ParentPath, string BackupPath,
        string ParentRevision, string BackupRevision, string ProjectRevision, string ParentCanonicalPath,
        string BackupCanonicalPath, string ExpectedBaseName);
}
