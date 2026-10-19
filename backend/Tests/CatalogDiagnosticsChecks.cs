using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Xml.Linq;
using H5Assist;
using Ras.Backend;
using Ras.Layers;
using Ras.Output;
using Utility.Units;

internal static class CatalogDiagnosticsChecks
{
    internal static void Run()
    {
        using var temporary = new TemporaryDirectory();
        string projectPath = Path.Combine(temporary.FullName, "catalog-diagnostics.ras");
        Project project = Project.CreateNew(projectPath, UnitSystem.SI);
        Terrain terrain = project.AddNewTerrain("Same name");
        NValueLayer nvalue = project.AddNewNValueLayer("Same name");
        Geometry geometry = project.AddNewGeometry("Catalog diagnostic geometry", terrain, nvalue);
        BoundaryCondition boundary = project.AddNewBoundaryCondition("Catalog diagnostic boundary",
            new DateTime(2026, 10, 16), TimeSpan.FromHours(1));
        Plan plan = project.AddNewPlan("Catalog diagnostic plan", geometry, boundary);
        string terrainPath = terrain.Filename;
        string nvaluePath = nvalue.Filename;
        string resultPath = project.GetUniqueResultFilename(plan.Name);
        project.Description = "Saved description";
        geometry.Save();
        boundary.Save();
        plan.Save();
        project.Save();
        using (Result prepared = Result.PrepareResult(resultPath, plan, geometry, boundary, null!)) { }
        using (var writer = new H5Writer(resultPath))
            writer.WriteDataset(OutputBlock.RootMeshOutputPath("Base Output", "Mesh") + "Water Surface",
                new float[] { 1f });
        byte[] terrainBytes = File.ReadAllBytes(terrainPath);
        byte[] nvalueBytes = File.ReadAllBytes(nvaluePath);
        byte[] resultBytes = File.ReadAllBytes(resultPath);
        byte[] projectBytes = File.ReadAllBytes(projectPath);
        Dispose(project);

        XElement draft = XElement.Load(projectPath);
        draft.Element("Description")!.Value = "Unsaved editor description";
        byte[] invalidTerrain = Encoding.UTF8.GetBytes("not an HDF5 terrain source");
        File.WriteAllBytes(terrainPath, invalidTerrain);

        CatalogTreeSnapshot invalidSnapshot = CatalogTreeService.LoadCatalog(new(projectPath,
            draft.ToString(SaveOptions.DisableFormatting)));
        CatalogTreeNode invalidTerrainNode = FindAsset(invalidSnapshot, "TerrainRootContext", terrainPath, "ObservableTerrain");
        CatalogTreeNode validNValueNode = FindAsset(invalidSnapshot, "NValueRootContext", nvaluePath, "ObservableNValueLayer");
        CatalogTreeNode resultNode = FindAsset(invalidSnapshot, "ResultRootContext", resultPath, "ObservableResult");
        Check(AllCopies(invalidSnapshot, invalidTerrainNode).Length == 2 &&
              AllCopies(invalidSnapshot, validNValueNode).Length == 2 &&
              AllCopies(invalidSnapshot, resultNode).Length == 1,
            "Direct catalog rows and Result-owned association copies retain the same exact source diagnostics.");
        Check(invalidSnapshot.Roots[0].CatalogSummary?.Description == "Unsaved editor description",
            "Catalog diagnostics read against the captured unsaved project XML draft.");
        Check(invalidTerrainNode.Name == validNValueNode.Name && invalidTerrainNode.AssetID != validNValueNode.AssetID,
            "Same-named sources retain their independent node and asset identities.");
        Check(invalidTerrainNode.DiagnosticStatus == "loaded"
            && invalidTerrainNode.DiagnosticSourceIdentity == Canonical(terrainPath)
            && invalidTerrainNode.DiagnosticSourceRevision == HashFile(terrainPath)
            && invalidTerrainNode.LayerErrors is { Length: > 0 }
            && invalidTerrainNode.LayerErrors.Any(error => error.Code == "CoreLayer_LoadError"
                && error.Severity == "Error" && error.EvaluatedMessage.Length > 0),
            "An invalid source produces the real CoreLayer load diagnostic with its exact source identity and revision.");
        Check(validNValueNode.DiagnosticStatus == "loaded"
            && validNValueNode.DiagnosticSourceIdentity == Canonical(nvaluePath)
            && validNValueNode.DiagnosticSourceRevision == HashFile(nvaluePath)
            && validNValueNode.LayerErrors is { Length: 0 },
            "A separate same-named valid source has a loaded, empty diagnostic list and its own revision.");
        Check(resultNode.DiagnosticStatus == "loaded"
            && resultNode.DiagnosticSourceIdentity == Canonical(resultPath)
            && resultNode.DiagnosticSourceRevision == HashFile(resultPath)
            && resultNode.LayerErrors is { Length: > 0 }
            && resultNode.LayerErrors.Any(error => error.Code == "Result_NeedsMigration"
                && error.Severity == "Warning"
                && error.LogData.Any(data => data.Key == "ResultName" && data.Value == resultNode.Name)),
            "A Result row exposes the exact embedded Result.LayerErrors message and named context.");
        CatalogTreeSnapshot projectSnapshot = CatalogTreeService.LoadProject(new(projectPath,
            draft.ToString(SaveOptions.DisableFormatting), Mode: "Project"));
        CatalogTreeNode projectTerrainNode = FindAsset(projectSnapshot, "TerrainsSectionContext", terrainPath, "ObservableTerrain");
        CatalogTreeNode[] mapDefaults = CatalogTreeService.LoadMapTreeDefaults(new(projectPath,
            draft.ToString(SaveOptions.DisableFormatting), Mode: "Project"), "Project");
        var mapSnapshot = new CatalogTreeSnapshot(mapDefaults);
        CatalogTreeNode mapTerrainNode = FindAsset(mapSnapshot, "TerrainsSectionContext", terrainPath,
            "ObservableTerrain");
        Check(AllCopies(projectSnapshot, projectTerrainNode).Length >= 2 &&
              AllCopies(mapSnapshot, mapTerrainNode).Length >= 2,
            "Project and default map trees attach the same diagnostics to every source association occurrence.");
        Check(projectTerrainNode.DiagnosticStatus == "loaded"
            && projectTerrainNode.LayerErrors?.Any(error => error.Code == "CoreLayer_LoadError") == true
            && mapTerrainNode.DiagnosticStatus == "loaded"
            && mapTerrainNode.LayerErrors?.Any(error => error.Code == "CoreLayer_LoadError") == true,
            "Catalog, project-tree and persistent map-tree snapshots carry the same exact source diagnostic.");
        Check(File.ReadAllBytes(terrainPath).SequenceEqual(invalidTerrain)
            && File.ReadAllBytes(nvaluePath).SequenceEqual(nvalueBytes)
            && File.ReadAllBytes(resultPath).SequenceEqual(resultBytes)
            && File.ReadAllBytes(projectPath).SequenceEqual(projectBytes),
            "Catalog diagnostics do not rewrite either source file or save the captured project draft.");

        File.WriteAllBytes(terrainPath, terrainBytes);
        CatalogTreeSnapshot repairedSnapshot = CatalogTreeService.LoadCatalog(new(projectPath,
            draft.ToString(SaveOptions.DisableFormatting)));
        CatalogTreeNode repairedTerrainNode = FindAsset(repairedSnapshot, "TerrainRootContext", terrainPath, "ObservableTerrain");
        Check(AllCopies(repairedSnapshot, repairedTerrainNode).Length == 2,
            "Repair refreshes both the direct and the Result-associated Terrain occurrence.");
        Check(repairedTerrainNode.DiagnosticStatus == "loaded"
            && repairedTerrainNode.DiagnosticSourceIdentity == Canonical(terrainPath)
            && repairedTerrainNode.DiagnosticSourceRevision == HashFile(terrainPath)
            && repairedTerrainNode.DiagnosticSourceRevision != invalidTerrainNode.DiagnosticSourceRevision
            && repairedTerrainNode.LayerErrors is { Length: 0 },
            "A repaired source is re-opened on the next snapshot and returns its actual empty diagnostic list at the new revision.");
        Check(File.ReadAllBytes(terrainPath).SequenceEqual(terrainBytes)
            && File.ReadAllBytes(nvaluePath).SequenceEqual(nvalueBytes)
            && File.ReadAllBytes(resultPath).SequenceEqual(resultBytes)
            && File.ReadAllBytes(projectPath).SequenceEqual(projectBytes),
            "The repaired reread remains read-only for source HDF files and project XML.");

        Console.WriteLine("Catalog source LayerErrors, exact identities, source revisions, draft context and read-only rereads passed.");
    }

    private static CatalogTreeNode FindAsset(CatalogTreeSnapshot snapshot, string groupSourceClass,
        string path, string sourceClass)
    {
        string canonical = Canonical(path);
        CatalogTreeNode group = Walk(snapshot.Roots).Single(node => node.SourceClass == groupSourceClass);
        return Walk(group.Children ?? []).Single(node => node.SourceClass == sourceClass
            && node.AssetID is { } asset && Canonical(asset) == canonical);
    }

    private static CatalogTreeNode[] AllCopies(CatalogTreeSnapshot snapshot, CatalogTreeNode reference)
    {
        CatalogTreeNode[] occurrences = Walk(snapshot.Roots).Where(node => node.SourceClass == reference.SourceClass
            && node.AssetID is { } asset && Canonical(asset) == Canonical(reference.AssetID!)).ToArray();
        Check(occurrences.All(node => node.DiagnosticStatus == reference.DiagnosticStatus
            && node.DiagnosticSourceIdentity == reference.DiagnosticSourceIdentity
            && node.DiagnosticSourceRevision == reference.DiagnosticSourceRevision
            && node.DiagnosticReadError == reference.DiagnosticReadError
            && JsonSerializer.Serialize(node.LayerErrors) == JsonSerializer.Serialize(reference.LayerErrors)),
            "Every presentation of the same source has the same diagnostic identity, revision and messages.");
        return occurrences;
    }

    private static IEnumerable<CatalogTreeNode> Walk(IEnumerable<CatalogTreeNode> nodes)
    {
        foreach (CatalogTreeNode node in nodes)
        {
            yield return node;
            if (node.Children is { } children)
                foreach (CatalogTreeNode child in Walk(children)) yield return child;
        }
    }

    private static string Canonical(string path) => Path.GetFullPath(path);

    private static string HashFile(string path)
    {
        using FileStream stream = File.OpenRead(path);
        return Convert.ToHexString(SHA256.HashData(stream));
    }

    private static void Dispose(Project project)
    {
        foreach (CoreLayerBase layer in project.Plans.Cast<CoreLayerBase>().Concat(project.Geometries)
                     .Concat(project.Terrains).Concat(project.BoundaryConditions).Concat(project.NValues)
                     .Concat(project.ClassificationLayers))
            layer.Dispose();
        foreach (Result result in project.Results) result.Dispose();
    }

    private static void Check(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }
}
