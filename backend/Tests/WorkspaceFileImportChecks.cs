using System.IO.Compression;
using System.Security.Cryptography;
using Ras.Backend;
using Ras.Layers;

internal static class WorkspaceFileImportChecks
{
    internal static void Run()
    {
        ArchiveImportPublishesOnlyOneContainedProject();
        ArchiveImportRejectsTraversalAndStaleSources();
        CoreHdfImportUsesRetainedGeometryValidityAndPreservesBytes();
        CoreHdfImportRejectsUnrecognizedFilesWithoutOutput();
        Console.WriteLine("Workspace ZIP and core HDF imports preserve sources, validate source models and publish isolated projects.");
    }

    private static void ArchiveImportPublishesOnlyOneContainedProject()
    {
        using var directory = new TemporaryDirectory();
        string sourcePath = Path.Combine(directory.FullName, "sample.zip");
        byte[] projectBytes = System.Text.Encoding.UTF8.GetBytes("<Project><!-- retained archive payload --></Project>");
        byte[] supportingBytes = [0, 1, 2, 3, 255];
        using (var archive = ZipFile.Open(sourcePath, ZipArchiveMode.Create))
        {
            WriteEntry(archive, "sample/Project.RAS", projectBytes);
            WriteEntry(archive, "sample/Geometries/Geometry.h5", supportingBytes);
        }
        byte[] originalArchive = File.ReadAllBytes(sourcePath);
        string destination = Path.Combine(directory.FullName, "imports");
        Directory.CreateDirectory(destination);

        WorkspacePreparedProject imported = WorkspaceFileImportService.PrepareArchive(new(
            sourcePath, destination, Revision(sourcePath)));
        Check(imported.ImportKind == "archive", "ZIP imports report their source-derived type.");
        Check(Path.GetFullPath(imported.ProjectPath).StartsWith(
                Path.GetFullPath(destination) + Path.DirectorySeparatorChar, StringComparison.Ordinal),
            "The prepared project stays inside the user-selected destination folder.");
        Check(File.ReadAllBytes(imported.ProjectPath).SequenceEqual(projectBytes),
            "The contained .ras file is extracted byte-for-byte.");
        Check(File.ReadAllBytes(Path.Combine(imported.DestinationDirectory, "sample/Geometries/Geometry.h5"))
                .SequenceEqual(supportingBytes),
            "Supporting project files retain their original archive bytes.");
        Check(File.ReadAllBytes(sourcePath).SequenceEqual(originalArchive),
            "Preparing an archive never changes the selected source.");

        using (var secondArchive = ZipFile.Open(sourcePath, ZipArchiveMode.Update))
            WriteEntry(secondArchive, "other/Second.ras", projectBytes);
        var ambiguousRoot = Path.Combine(directory.FullName, "ambiguous");
        Directory.CreateDirectory(ambiguousRoot);
        byte[] ambiguousSource = File.ReadAllBytes(sourcePath);
        Expect<InvalidDataException>(() => WorkspaceFileImportService.PrepareArchive(new(
            sourcePath, ambiguousRoot, Revision(sourcePath))));
        Check(!Directory.EnumerateFileSystemEntries(ambiguousRoot).Any(),
            "An archive with multiple project files leaves no partial import folder.");
        Check(File.ReadAllBytes(sourcePath).SequenceEqual(ambiguousSource),
            "The rejected archive remains byte-identical.");
    }

    private static void ArchiveImportRejectsTraversalAndStaleSources()
    {
        using var directory = new TemporaryDirectory();
        string sourcePath = Path.Combine(directory.FullName, "unsafe.zip");
        using (var archive = ZipFile.Open(sourcePath, ZipArchiveMode.Create))
        {
            WriteEntry(archive, "../outside.txt", [1, 2, 3]);
            WriteEntry(archive, "Project.ras", [4, 5, 6]);
        }
        string destination = Path.Combine(directory.FullName, "imports");
        Directory.CreateDirectory(destination);
        Expect<InvalidDataException>(() => WorkspaceFileImportService.PrepareArchive(new(
            sourcePath, destination, Revision(sourcePath))));
        Check(!File.Exists(Path.Combine(directory.FullName, "outside.txt"))
              && !Directory.EnumerateFileSystemEntries(destination).Any(),
            "A traversal entry is rejected before it writes outside or leaves partial output.");

        string validPath = Path.Combine(directory.FullName, "valid.zip");
        using (var archive = ZipFile.Open(validPath, ZipArchiveMode.Create))
            WriteEntry(archive, "Project.ras", [9, 8, 7]);
        string staleRevision = Revision(validPath);
        File.AppendAllText(validPath, "changed");
        Expect<SourceFileChangedException>(() => WorkspaceFileImportService.PrepareArchive(new(
            validPath, destination, staleRevision)));
        Check(!Directory.EnumerateFileSystemEntries(destination).Any(),
            "A changed archive is refused before extraction begins.");
    }

    private static void CoreHdfImportUsesRetainedGeometryValidityAndPreservesBytes()
    {
        using var directory = new TemporaryDirectory();
        string sourcePath = Path.Combine(directory.FullName, "Geometry.h5");
        Geometry geometry = Geometry.CreateNew(sourcePath);
        geometry.Dispose();
        byte[] sourceBytes = File.ReadAllBytes(sourcePath);
        string destination = Path.Combine(directory.FullName, "imports");
        Directory.CreateDirectory(destination);

        WorkspacePreparedProject imported = WorkspaceFileImportService.PrepareCoreHdf(new(
            sourcePath, destination, Revision(sourcePath)));
        Check(imported.ImportKind == "geometry", "The retained HDF validator identifies a Geometry core file.");
        Check(imported.ImportedAssetPath != null && imported.ImportedAssetRevision == Revision(sourcePath)
              && File.ReadAllBytes(imported.ImportedAssetPath!).SequenceEqual(sourceBytes),
            "The Geometry HDF is copied unchanged into the new project's Geometries folder.");
        Check(Path.GetDirectoryName(imported.ImportedAssetPath!)!.EndsWith(
                "Geometries", StringComparison.Ordinal),
            "The imported Geometry uses the retained project directory structure.");
        Project reopened = new(imported.ProjectPath);
        try
        {
            Check(reopened.Name == imported.ProjectName
                  && reopened.Geometries.Count == 1
                  && Path.GetFullPath(reopened.Geometries[0].Filename) == Path.GetFullPath(imported.ImportedAssetPath!),
                "The generated project reopens and resolves its exact imported Geometry asset.");
        }
        finally
        {
            foreach (CoreLayerBase layer in reopened.Geometries.Cast<CoreLayerBase>()
                         .Concat(reopened.BoundaryConditions))
                layer.Dispose();
            foreach (Result result in reopened.Results) result.Dispose();
        }
        Check(File.ReadAllBytes(sourcePath).SequenceEqual(sourceBytes),
            "Core HDF import never modifies the original file.");
    }

    private static void CoreHdfImportRejectsUnrecognizedFilesWithoutOutput()
    {
        using var directory = new TemporaryDirectory();
        string sourcePath = Path.Combine(directory.FullName, "not-ras.h5");
        File.WriteAllBytes(sourcePath, [0, 1, 2, 3, 4, 5]);
        string destination = Path.Combine(directory.FullName, "imports");
        Directory.CreateDirectory(destination);
        Expect<Exception>(() => WorkspaceFileImportService.PrepareCoreHdf(new(
            sourcePath, destination, Revision(sourcePath))));
        Check(!Directory.EnumerateFileSystemEntries(destination).Any(),
            "An unrecognized HDF file does not create a scratch project.");
        Check(File.ReadAllBytes(sourcePath).SequenceEqual(new byte[] { 0, 1, 2, 3, 4, 5 }),
            "Rejecting an unrecognized HDF leaves the selected bytes unchanged.");

        string unsupportedExtensionPath = Path.Combine(directory.FullName, "not-ras.hdf");
        File.WriteAllBytes(unsupportedExtensionPath, [7, 8, 9]);
        Expect<ArgumentException>(() => WorkspaceFileImportService.PrepareCoreHdf(new(
            unsupportedExtensionPath, destination, Revision(unsupportedExtensionPath))));
        Check(!Directory.EnumerateFileSystemEntries(destination).Any(),
            "Only the retained .h5 quick-open extension is accepted.");
    }

    private static void WriteEntry(ZipArchive archive, string name, byte[] bytes)
    {
        ZipArchiveEntry entry = archive.CreateEntry(name);
        using Stream output = entry.Open();
        output.Write(bytes);
    }

    private static string Revision(string path)
    {
        using FileStream stream = File.OpenRead(path);
        return Convert.ToHexString(SHA256.HashData(stream));
    }

    private static void Check(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }

    private static void Expect<T>(Action action) where T : Exception
    {
        try { action(); }
        catch (T) { return; }
        throw new InvalidOperationException($"Expected {typeof(T).Name}.");
    }
}
