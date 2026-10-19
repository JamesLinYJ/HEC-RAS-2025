using Ras.Backend;
using Ras.Layers;
using Ras.Updates;

internal static class ProjectLibraryChecks
{
    internal static void Run()
    {
        CheckSyntheticCatalogUsesSourceEntries();
        CheckSyntheticOpenWritesOneReadableProjectToSelectedFolder();
        CheckManifestPathsStayInsideProjectFolder();
    }

    private static void CheckSyntheticCatalogUsesSourceEntries()
    {
        ProjectLibraryProjectRow[] rows = ProjectLibraryService.SyntheticCatalogForChecks();
        Check(rows.Length > 0 && rows.All(row => row.Kind == "synthetic" && !string.IsNullOrWhiteSpace(row.Id)) &&
              rows.Select(row => row.Id).Distinct(StringComparer.Ordinal).Count() == rows.Length,
            "The debug synthetic catalog is projected from distinct retained source factories.");
        Check(rows.Any(row => row.Id == "TestGPUSmallThackerAction"),
            "The retained GPU Thacker small fixture remains available by its source identity.");
    }

    private static void CheckSyntheticOpenWritesOneReadableProjectToSelectedFolder()
    {
        using var directory = new TemporaryDirectory();
        string savedPath = ProjectLibraryService.SaveSyntheticForChecks("TestGPUSmallThackerAction",
            directory.Path, terrainCellCount: 64, analyticalCellCount: 16);
        string[] rasFiles = Directory.GetFiles(directory.Path, "*.ras", SearchOption.TopDirectoryOnly);
        Check(rasFiles.Length == 1 && File.Exists(savedPath) &&
              Path.GetFullPath(rasFiles[0]) == Path.GetFullPath(savedPath),
            "A real retained synthetic factory writes exactly one top-level project in its destination.");
        var reopened = new Project(rasFiles[0]);
        try
        {
            Check(Path.GetFullPath(reopened.Filename) == Path.GetFullPath(rasFiles[0]),
                "The synthetic project result can be reopened by the retained Project model.");
        }
        finally { Dispose(reopened); }
    }

    private static void CheckManifestPathsStayInsideProjectFolder()
    {
        MappedFile Safe(string filename) => new() { Filename = filename, SHA256 = new string('a', 64), Length = 1 };
        Check(ProjectLibraryService.ValidateRelativeManifestPaths([Safe("Geometry/mesh.hdf")])
                .SequenceEqual(["Geometry/mesh.hdf"]),
            "Relative source manifest paths are preserved for the retained importer.");
        Expect<InvalidDataException>(() => ProjectLibraryService.ValidateRelativeManifestPaths([Safe("../outside.ras")]));
        Expect<InvalidDataException>(() => ProjectLibraryService.ValidateRelativeManifestPaths([Safe("/outside.ras")]));
        Expect<InvalidDataException>(() => ProjectLibraryService.ValidateRelativeManifestPaths(
            [Safe("terrain.tif"), Safe("terrain.tif")]));
        Expect<InvalidDataException>(() => ProjectLibraryService.ValidateRelativeManifestPaths(
            [new MappedFile { Filename = "terrain.tif", SHA256 = "not-a-hash", Length = 1 }]));
    }

    private static void Expect<T>(Action action) where T : Exception
    {
        try { action(); }
        catch (T) { return; }
        throw new InvalidOperationException("Expected " + typeof(T).Name + ".");
    }

    private static void Check(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }

    private static void Dispose(Project project)
    {
        foreach (CoreLayerBase layer in project.Plans.Cast<CoreLayerBase>().Concat(project.Geometries)
            .Concat(project.Terrains).Concat(project.BoundaryConditions).Concat(project.NValues)
            .Concat(project.ClassificationLayers))
            layer.Dispose();
        foreach (Result result in project.Results) result.Dispose();
    }

    private sealed class TemporaryDirectory : IDisposable
    {
        public string Path { get; } = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "ras-project-library-" + Guid.NewGuid().ToString("N"));
        public TemporaryDirectory() => Directory.CreateDirectory(Path);
        public void Dispose()
        {
            try { Directory.Delete(Path, recursive: true); }
            catch { /* The fixture directory is private to this check. */ }
        }
    }
}
