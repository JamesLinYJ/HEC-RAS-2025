using System.Buffers.Binary;
using System.Security.Cryptography;
using System.Text;
using Geospatial;
using Geospatial.Rasters;
using Geospatial.Vectors;
using Ras.Backend;
using Ras.Layers;
using Ras.Layers.BoundaryConditions;
using Utility.Units;

internal static class MapTreeWindChildChecks
{
    internal static async Task Run()
    {
        using var temporary = new TemporaryDirectory();
        string projectPath = Path.Combine(temporary.FullName, "Wind map context.ras");
        Project project = Project.CreateNew(projectPath, UnitSystem.SI);
        BoundaryCondition createdBoundary = project.AddNewBoundaryCondition("Wind source", 
            new DateTime(2026, 10, 18, 0, 0, 0, DateTimeKind.Utc), TimeSpan.FromHours(2));
        string boundaryPath = Path.GetFullPath(createdBoundary.Filename);
        project.Save();
        createdBoundary.Save();
        DisposeProject(project);

        ModelSnapshot loaded = await ModelEditorAdapter.LoadAsync(new ModelRequest(
            boundaryPath, "Boundary Conditions", projectPath));
        Dictionary<string, string> windValues = new()
        {
            ["WindConstantControl/Constant1"] = "3.5",
            ["WindConstantControl/Constant2"] = "-2.5",
            ["WindForcesControl/WindLayer_Ratio"] = "1",
            ["WindForcesControl/WindLayer_IsEnabled"] = "true",
            ["WindForcesControl/WindLayer_SpatialDataType"] = "Constant"
        };
        ModelSnapshot saved = await ModelEditorAdapter.SaveAsync(new ModelSaveRequest(
            boundaryPath, "Boundary Conditions", projectPath, loaded.Revision, windValues,
            new Dictionary<string, ImageData[]>()));
        Check(windValues.All(pair => saved.Fields[pair.Key] == pair.Value),
            "The Wind fixture is stored through the ordinary retained BoundaryCondition editor path.");

        byte[] projectBefore = File.ReadAllBytes(projectPath);
        byte[] boundaryBefore = File.ReadAllBytes(boundaryPath);
        string projectXml = File.ReadAllText(projectPath);
        string projectXmlSHA = Hash(Encoding.UTF8.GetBytes(projectXml));
        MapDocumentMutationReceipt createdMap = MapTreeService.CreateMap(new MapDocumentRequest(
            projectPath, projectXml, projectXmlSHA, null, "Project", Name: "Wind map"));
        MapTreeRequest map = new(projectPath, projectXml, projectXmlSHA,
            Guid.NewGuid().ToString("D"), createdMap.MapIndex, createdMap.MapName,
            createdMap.MapType, createdMap.VisualizationRevision);

        MapTreeSnapshot initial = MapTreeService.Load(map);
        CatalogTreeNode initialBoundary = FindBoundary(initial.Roots, boundaryPath);
        CatalogTreeNode initialWind = FindWind(initialBoundary);
        CatalogTreeNodeLocator initialBoundaryLocator = initialBoundary.Locator!;
        CatalogTreeNodeLocator initialWindLocator = initialWind.Locator!;
        bool initialParentPathMatches = initialWindLocator.ParentBoundaryConditionNodePath is { } initialParentPath
            ? initialParentPath.SequenceEqual(initialBoundaryLocator.NodePath ?? [])
            : initialBoundaryLocator.NodePath is null;
        bool initialWindPathMatches = initialWindLocator.NodePath is { } initialWindPath
            ? initialBoundaryLocator.NodePath is { } initialBoundaryPath &&
              initialWindPath.Length == initialBoundaryPath.Length + 1 &&
              initialWindPath.Take(initialBoundaryPath.Length).SequenceEqual(initialBoundaryPath)
            : initialBoundaryLocator.NodePath is null;
        Check(initialBoundary.Checked == "unchecked" && initialWind.Checked == "unchecked" &&
              initialBoundaryLocator.RootName == "Boundary Conditions" &&
              initialWind.SourceClass == "WindLayerVisualContext" && initialWind.LocalizeName &&
              initialWind.Name == "Wind Forces" && initialWindLocator.NodeType == "WindLayer" &&
              PathEquals(initialWindLocator.AssetID!, boundaryPath) &&
              initialWindLocator.ParentBoundaryConditionAssetID is { } initialParentAsset &&
                  PathEquals(initialParentAsset, boundaryPath) &&
              initialWindLocator.ParentBoundaryConditionNodeName == initialBoundary.Name &&
              initialParentPathMatches && initialWindPathMatches,
            "The source map exposes a distinct unchecked Wind child with exact parent Boundary identity and an independent tree path.");

        MapTreeMutationResult parentEnabled = MapTreeService.Perform(new MapTreeActionRequest(
            map, "visibility", Node: initialBoundaryLocator, Checked: true));
        map = map with { ExpectedVisualizationRevision = parentEnabled.VisualizationRevision };
        CatalogTreeNode enabledBoundary = FindBoundary(parentEnabled.Roots, boundaryPath);
        CatalogTreeNode enabledWind = FindWind(enabledBoundary);
        Check(enabledBoundary.Checked == "checked" && enabledWind.Checked == "unchecked" &&
              !MapTreeService.IsEffectivelyVisible(parentEnabled.Roots, enabledWind),
            "Checking a BoundaryCondition does not silently activate the separate Wind source child.");
        Expect<InvalidOperationException>(() => MapWindVelocityFieldService.Sample(
            Request(map, enabledBoundary.Locator!, enabledWind.Locator!, boundaryPath,
                Hash(boundaryBefore), "inactive")));

        MapTreeMutationResult windEnabled = MapTreeService.Perform(new MapTreeActionRequest(
            map, "visibility", Node: enabledWind.Locator, Checked: true));
        map = map with { ExpectedVisualizationRevision = windEnabled.VisualizationRevision };
        MapTreeSnapshot visibleTree = MapTreeService.Load(map);
        CatalogTreeNode selectedBoundary = FindBoundary(visibleTree.Roots, boundaryPath);
        CatalogTreeNode selectedWind = FindWind(selectedBoundary);
        Check(selectedBoundary.Checked == "checked" && selectedWind.Checked == "checked" &&
              MapTreeService.IsEffectivelyVisible(visibleTree.Roots, selectedWind) &&
              selectedWind.Locator?.ParentBoundaryConditionAssetID is { } selectedParent &&
                  PathEquals(selectedParent, boundaryPath) &&
              selectedWind.Locator.ParentBoundaryConditionNodePath is { } selectedParentPath &&
                  selectedParentPath.SequenceEqual(selectedBoundary.Locator!.NodePath ?? []),
            "The Wind child persists independently beneath its exact visible BoundaryCondition owner.");

        const int width = 12;
        const int height = 8;
        var viewport = new RasterMapViewExtent(0, 0, 1, 1, width, height);
        byte[] visualizationBeforeSample = File.ReadAllBytes(Path.ChangeExtension(projectPath, ".vis"));
        MapWindVelocityFieldResult field = MapWindVelocityFieldService.Sample(Request(map,
            selectedBoundary.Locator!, selectedWind.Locator!, boundaryPath, Hash(boundaryBefore),
            "wind-constant-sample") with { Viewport = viewport });
        Check(field.ContextToken == "wind-context" && field.RequestID == "wind-constant-sample" &&
              field.SpatialDataType == "Constant" && field.ProfileIndex == 0 && field.Profiles.Length == 2 &&
              field.Profiles[0].Index == 0 && field.Time == field.Profiles[0].Time &&
              MapResultRenderService.SameLocator(field.BoundaryNode, selectedBoundary.Locator!) &&
              MapResultRenderService.SameLocator(field.WindNode, selectedWind.Locator!) &&
              field.SourceID == MapResultRenderService.NodeIdentity(selectedWind.Locator!) &&
              field.InterleavedVelocity.Length == width * height * 3 * sizeof(float),
            "The Wind sampler response retains the selected Wind child, active map context and actual source profile timeline.");

        Project sampleProject = new(projectPath);
        try
        {
            BoundaryCondition sourceBoundary = sampleProject.BoundaryConditions.Single(condition =>
                PathEquals(condition.Filename, boundaryPath));
            WindLayer sourceWind = sourceBoundary.Wind
                ?? throw new InvalidDataException("The persisted BoundaryCondition has no Wind layer.");
            var definition = new RasterDefinition(new Extent(0, 1, 0, 1), height, width);
            float[] expectedX = new float[definition.CellCount];
            float[] expectedY = new float[definition.CellCount];
            float[] expectedMagnitude = new float[definition.CellCount];
            sourceWind.ResampleVxVy(new ResampleArgs(definition), 0,
                expectedX.AsMemory(), expectedY.AsMemory(), expectedMagnitude.AsMemory());
            bool matchesRetainedResampler = true;
            for (int index = 0; index < definition.CellCount; index++)
            {
                int offset = checked(index * 3 * sizeof(float));
                matchesRetainedResampler &= ReadFloat(field.InterleavedVelocity, offset) == expectedX[index]
                    && ReadFloat(field.InterleavedVelocity, offset + sizeof(float)) == expectedY[index]
                    && ReadFloat(field.InterleavedVelocity, offset + 2 * sizeof(float)) == expectedMagnitude[index];
            }
            Check(matchesRetainedResampler && expectedX.All(value => value == 3.5f) &&
                  expectedY.All(value => value == -2.5f),
                "The service's interleaved velocity cells equal the actual retained Wind constant resampler output.");
        }
        finally
        {
            DisposeProject(sampleProject);
        }

        Expect<ArgumentException>(() => MapWindVelocityFieldService.Sample(Request(map,
            selectedBoundary.Locator!, selectedWind.Locator! with
            { ParentBoundaryConditionNodeName = "Different Boundary" }, boundaryPath,
            Hash(boundaryBefore), "wrong-parent") with { Viewport = viewport }));
        Expect<SourceFileChangedException>(() => MapWindVelocityFieldService.Sample(Request(map,
            selectedBoundary.Locator!, selectedWind.Locator!, boundaryPath,
            new string('0', 64), "stale-boundary") with { Viewport = viewport }));
        Check(File.ReadAllBytes(projectPath).SequenceEqual(projectBefore) &&
              File.ReadAllBytes(boundaryPath).SequenceEqual(boundaryBefore) &&
              File.ReadAllBytes(Path.ChangeExtension(projectPath, ".vis")).SequenceEqual(visualizationBeforeSample),
            "Wind sampling leaves the project, BoundaryCondition HDF and selected map .vis bytes unchanged.");
        Console.WriteLine("Independent map Wind child identity, visibility, retained constant resampling, stale-source rejection and source preservation passed.");
    }

    private static MapWindVelocityFieldRequest Request(MapTreeRequest map,
        CatalogTreeNodeLocator boundary, CatalogTreeNodeLocator wind, string path,
        string revision, string requestID) => new(map, boundary, wind, path, revision,
            "wind-context", requestID, 0, null, new RasterMapViewExtent(0, 0, 1, 1, 12, 8));

    private static CatalogTreeNode FindBoundary(IEnumerable<CatalogTreeNode> roots, string path) =>
        roots.SelectMany(Flatten).Single(node => node.Locator?.NodeType == "BoundaryCondition" &&
            node.Locator.AssetID is { } asset && PathEquals(asset, path));

    private static CatalogTreeNode FindWind(CatalogTreeNode boundary) =>
        (boundary.Children ?? []).Single(node => node.Locator?.NodeType == "WindLayer");

    private static IEnumerable<CatalogTreeNode> Flatten(CatalogTreeNode node)
    {
        yield return node;
        if (node.Children is { Length: > 0 } children)
            foreach (CatalogTreeNode child in children.SelectMany(Flatten)) yield return child;
    }

    private static bool PathEquals(string first, string second) =>
        string.Equals(Path.GetFullPath(first), Path.GetFullPath(second), OperatingSystem.IsWindows()
            ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal);

    private static void DisposeProject(Project project)
    {
        foreach (CoreLayerBase layer in project.Plans.Cast<CoreLayerBase>().Concat(project.Geometries)
            .Concat(project.Terrains).Concat(project.BoundaryConditions).Concat(project.NValues)
            .Concat(project.ClassificationLayers)) layer.Dispose();
        foreach (Result result in project.Results) result.Dispose();
    }

    private static float ReadFloat(byte[] bytes, int offset) =>
        BitConverter.Int32BitsToSingle(BinaryPrimitives.ReadInt32LittleEndian(bytes.AsSpan(offset, sizeof(float))));

    private static string Hash(byte[] bytes) => Convert.ToHexString(SHA256.HashData(bytes));

    private static void Check(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }

    private static void Expect<T>(Action action) where T : Exception
    {
        try { action(); }
        catch (T) { return; }
        throw new InvalidOperationException("Expected " + typeof(T).Name + ".");
    }

    private sealed class TemporaryDirectory : IDisposable
    {
        public string FullName { get; } = Path.Combine(Path.GetTempPath(), "hecras-wind-map-" + Guid.NewGuid().ToString("N"));
        public TemporaryDirectory() => Directory.CreateDirectory(FullName);
        public void Dispose()
        {
            try { Directory.Delete(FullName, recursive: true); }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }
    }
}
