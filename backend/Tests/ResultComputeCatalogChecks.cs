using System.Security.Cryptography;
using System.Text;
using Geospatial.IO.ORM;
using H5Assist;
using Ras.Backend;
using Ras.Layers;
using Ras.Layers.Results;
using Utility.Units;

internal static class ResultComputeCatalogChecks
{
    internal static void Run()
    {
        using var temporary = new TemporaryDirectory();
        string projectPath = Path.Combine(temporary.FullName, "Result State.ras");
        string planPath;
        string planName;
        string resultsDirectory;
        string[] layerPaths;
        Project project = Project.CreateNew(projectPath, UnitSystem.SI);
        try
        {
            Terrain terrain = project.AddNewTerrain("Result State Terrain");
            NValueLayer nValues = project.AddNewNValueLayer("Result State Roughness");
            Geometry geometry = project.AddNewGeometry("Result State Geometry", terrain, nValues);
            BoundaryCondition boundary = project.AddNewBoundaryCondition("Result State Boundary",
                new DateTime(2026, 10, 17), TimeSpan.FromHours(1));
            Plan plan = project.AddNewPlan("Result State Plan", geometry, boundary);
            foreach (CoreLayerBase layer in Layers(project)) layer.Save();
            project.Save();
            planPath = plan.Filename;
            planName = plan.Name;
            resultsDirectory = project.ResultsDirectory;
            layerPaths = Layers(project).Select(layer => layer.Filename).Append(projectPath).ToArray();

            Directory.CreateDirectory(project.ResultsDirectory);
            CreateResult(project, "Unknown state", plan, geometry, boundary, null);
            CreateResult(project, "Successful state", plan, geometry, boundary, new ComputeSummary
            {
                Success = true,
                StartTime = new DateTime(2026, 10, 17, 0, 0, 0, DateTimeKind.Local),
                TotalDuration = TimeSpan.FromMinutes(2)
            });
            CreateResult(project, "Failed state", plan, geometry, boundary, new ComputeSummary
            {
                Success = false,
                FailureReason = "Model Unstable",
                StartTime = new DateTime(2026, 10, 17, 0, 0, 0, DateTimeKind.Local),
                TotalDuration = TimeSpan.FromMinutes(1)
            });
        }
        finally { Dispose(project); }

        string[] resultPaths = Directory.EnumerateFiles(resultsDirectory, "*.h5", SearchOption.TopDirectoryOnly).ToArray();
        var expected = new Dictionary<string, (string? State, string? FailureReason)>(StringComparer.Ordinal)
        {
            ["Unknown state"] = (null, null),
            ["Successful state"] = ("completed", null),
            ["Failed state"] = ("failed", "Compute failed at some point through the simulation: Model Unstable")
        };
        if (resultPaths.Length != expected.Count)
            throw new InvalidDataException("The source Result fixture did not create the expected three HDF files.");

        var sourceFiles = layerPaths.Concat(resultPaths).Distinct(StringComparer.Ordinal)
            .ToDictionary(path => path, Hash, StringComparer.Ordinal);
        CatalogTreeNode[] catalogNodes = CatalogTreeService.LoadCatalog(new CatalogTreeRequest(projectPath))
            .Roots.SelectMany(Flatten).Where(node => node.SourceClass == "ObservableResult").ToArray();
        CheckCatalogResults(catalogNodes, resultPaths, expected);

        string projectXml = File.ReadAllText(projectPath);
        string projectXmlSHA = Hash(Encoding.UTF8.GetBytes(projectXml));
        string planRevision = Hash(planPath);
        MapDocumentMutationReceipt created = MapTreeService.CreateMap(new MapDocumentRequest(
            projectPath, projectXml, projectXmlSHA, null, "Plan", Name: "Result state map",
            InitialPlanPath: planPath, InitialPlanRevision: planRevision));
        foreach (string resultPath in resultPaths)
        {
            string resultRevision = Hash(resultPath);
            var mapRequest = new MapTreeRequest(projectPath, projectXml, projectXmlSHA,
                "result-state-map", created.MapIndex, created.MapName, created.MapType,
                created.VisualizationRevision,
                [new MapTreeResultSelectionOverride(planPath, planName, resultPath, resultRevision)]);
            CatalogTreeNode selected = MapTreeService.Load(mapRequest).Roots.SelectMany(Flatten)
                .Single(node => node.Locator?.NodeType == "MultiResult");
            CatalogTreeNode catalogResult = catalogNodes.Single(node => node.AssetID is { } path && PathEquals(path, resultPath));
            Check(selected.ResultComputeState == catalogResult.ResultComputeState &&
                  selected.ResultComputeFailureReason == catalogResult.ResultComputeFailureReason &&
                  selected.ResultComputeSourcePath is { } selectedPath && PathEquals(selectedPath, resultPath) &&
                  string.Equals(selected.ResultComputeSourceRevision, resultRevision, StringComparison.OrdinalIgnoreCase),
                "A MultiResult state is copied only from the exact selected Result path and SHA.");
        }

        Check(sourceFiles.All(pair => Hash(pair.Key) == pair.Value),
            "Catalog and MapTree state reads leave the source Project, Plan and Result HDF bytes unchanged.");
        Console.WriteLine("Persisted Result compute unknown/success/failure states and exact selected Map MultiResult identities passed.");
    }

    private static void CheckCatalogResults(CatalogTreeNode[] nodes, string[] resultPaths,
        IReadOnlyDictionary<string, (string? State, string? FailureReason)> expected)
    {
        foreach (string path in resultPaths)
        {
            string name = Path.GetFileNameWithoutExtension(path)!;
            CatalogTreeNode node = nodes.Single(candidate => candidate.Name == name &&
                candidate.AssetID is { } asset && PathEquals(asset, path));
            (string? state, string? failureReason) = expected[name];
            Check(node.ResultComputeState == state && node.ResultComputeFailureReason == failureReason,
                $"Persisted Result '{name}' reports the source ComputeSummary state without treating an absent summary as failure.");
            Check(node.ResultComputeSourcePath is { } sourcePath && PathEquals(sourcePath, path) &&
                  string.Equals(node.ResultComputeSourceRevision, Hash(path), StringComparison.OrdinalIgnoreCase),
                $"Persisted Result '{name}' carries its exact canonical path and stable HDF revision.");
        }
    }

    private static void CreateResult(Project project, string name, Plan plan, Geometry geometry,
        BoundaryCondition boundary, ComputeSummary? summary)
    {
        string path = Path.Combine(project.ResultsDirectory, name + ".h5");
        using (Result prepared = Result.PrepareResult(path, plan, geometry, boundary, null!))
        {
            if (!File.Exists(path)) throw new InvalidDataException("The retained source Result writer did not create its HDF.");
        }
        if (summary is null) return;
        using var writer = new H5Writer(path);
        GeospatialH5Metadata.Write(summary, writer, "/Results/Compute Summary");
    }

    private static IEnumerable<CoreLayerBase> Layers(Project project) => project.Plans.Cast<CoreLayerBase>()
        .Concat(project.Geometries).Concat(project.BoundaryConditions).Concat(project.Terrains)
        .Concat(project.NValues).Concat(project.ClassificationLayers);

    private static IEnumerable<CatalogTreeNode> Flatten(CatalogTreeNode node)
    {
        yield return node;
        if (node.Children is null) yield break;
        foreach (CatalogTreeNode child in node.Children)
            foreach (CatalogTreeNode descendant in Flatten(child)) yield return descendant;
    }

    private static bool PathEquals(string first, string second) => string.Equals(Path.GetFullPath(first),
        Path.GetFullPath(second), OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal);

    private static string Hash(string path)
    {
        using Stream stream = File.OpenRead(path);
        return Convert.ToHexString(SHA256.HashData(stream));
    }

    private static string Hash(byte[] bytes) => Convert.ToHexString(SHA256.HashData(bytes));

    private static void Dispose(Project project)
    {
        foreach (Result result in project.Results) result.Dispose();
        foreach (CoreLayerBase layer in Layers(project)) layer.Dispose();
    }

    private static void Check(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }
}
