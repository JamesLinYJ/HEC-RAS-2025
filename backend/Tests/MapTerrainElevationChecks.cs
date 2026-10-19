using System.Security.Cryptography;
using System.Text;
using Geospatial.GDALAssist;
using Geospatial.Rasters;
using OSGeo.GDAL;
using Ras.Backend;
using Ras.Layers;
using Ras.Layers.Terrains;
using Utility.Units;

internal static class MapTerrainElevationChecks
{
    private static readonly MapGeometryViewport Viewport = new(0, 0, 16, 16);

    internal static void Run()
    {
        GDALSetup.InitializeMultiplatform();
        using var directory = new TemporaryDirectory();
        Fixture fixture = CreateFixture(directory.FullName);
        AssociatedMapLayersSnapshot sourceCapture = AssociatedMapLayersService.Load(
            new AssociatedMapLayersRequest(fixture.Map, [fixture.GeometryNode], [fixture.TerrainNode],
                Viewport, 16, 16));
        AssociatedMapLayerSnapshot terrainLayer = sourceCapture.Layers.Single();
        AssociatedMapLayerDependency[] expectedDependencies = terrainLayer.Dependencies
            .Where(item => item.Role is "source-hdf" or "terrain-input-raster").ToArray();
        var request = new MapTerrainElevationRequest(fixture.Map, fixture.TerrainNode,
            terrainLayer.AssetPath, terrainLayer.Revision, expectedDependencies,
            [new MapTerrainElevationCoordinate(0.5, 15.5), new MapTerrainElevationCoordinate(15.5, 0.5)]);

        byte[] terrainBytes = File.ReadAllBytes(fixture.TerrainPath);
        byte[] rasterBytes = File.ReadAllBytes(fixture.RasterPath);
        MapTerrainElevationResult result = MapTerrainElevationService.Sample(request);
        Check(result.MapID == fixture.Map.MapID && result.MapIndex == fixture.Map.MapIndex &&
              result.MapName == fixture.Map.MapName && result.MapType == fixture.Map.MapType &&
              SameLocator(result.TerrainNode, fixture.TerrainNode) &&
              SourceFilePaths.SameSourceFile(result.TerrainPath, fixture.TerrainPath) &&
              result.TerrainRevision.Length == 64 && result.ContextToken.Length == 64,
            "Terrain elevations retain the exact active saved-map and Terrain-row identity.");
        Check(result.Elevations.Length == 2 && result.Elevations[0] is 50.0 &&
              result.Elevations[1] is 125.0,
            "The service samples the two real project-world endpoints from the retained Terrain object.");
        Check(result.SourceDependencies.Length == expectedDependencies.Length &&
              result.SourceDependencies.All(actual => expectedDependencies.Any(expected =>
                  expected.Role == actual.Role &&
                  SourceFilePaths.SameSourceFile(expected.Path, actual.Path) &&
                  string.Equals(expected.Revision, actual.Revision, StringComparison.OrdinalIgnoreCase))) &&
              File.ReadAllBytes(fixture.TerrainPath).SequenceEqual(terrainBytes) &&
              File.ReadAllBytes(fixture.RasterPath).SequenceEqual(rasterBytes),
            "Sampling validates captured source SHA values and preserves every terrain input byte.");

        Expect<SourceFileChangedException>(() => MapTerrainElevationService.Sample(request with
        {
            ExpectedTerrainRevision = new string('0', 64)
        }));
        var lease = new MapResultComputeReadLease(Guid.NewGuid().ToString("D"),
            Guid.NewGuid().ToString("D"), fixture.Map.ProjectPath, [fixture.TerrainPath]);
        string missingProjectPath = Path.Combine(directory.FullName, "not-yet-written.ras");
        MapResultComputeReadLease missingProjectLease = lease with { ProjectPath = missingProjectPath };
        MapTreeRequest protectedMap = fixture.Map with
        {
            ProjectPath = missingProjectPath,
            ComputeReadLease = missingProjectLease
        };
        Expect<NotSupportedException>(() => MapTerrainElevationService.Sample(request with { Map = protectedMap }));
        Console.WriteLine("Map length slope sampled the exact retained Terrain endpoints and rejected stale or writer-owned sources.");
    }

    private static Fixture CreateFixture(string root)
    {
        string projectPath = Path.Combine(root, "Map terrain elevation.ras");
        Project project = Project.CreateNew(projectPath, UnitSystem.SI);
        string terrainPath;
        string rasterPath;
        string geometryPath;
        try
        {
            Terrain terrain = project.AddNewTerrain("Elevation source");
            rasterPath = Path.Combine(terrain.SourceDirectory, "elevation.tif");
            WriteRaster(rasterPath);
            terrain.Add(RasterTerrainInput.CreateAndScan(terrain, rasterPath));
            Geometry geometry = project.AddNewGeometry("Elevation geometry", terrain, null!);
            terrainPath = terrain.Filename;
            geometryPath = geometry.Filename;
            terrain.Save();
            geometry.Save();
            project.Save();
        }
        finally
        {
            foreach (CoreLayerBase layer in project.Geometries.Cast<CoreLayerBase>()
                         .Concat(project.Terrains).Concat(project.NValues).Concat(project.ClassificationLayers)
                         .Concat(project.Plans).Concat(project.BoundaryConditions))
                layer.Dispose();
            foreach (Result result in project.Results) result.Dispose();
        }

        string projectXml = File.ReadAllText(projectPath);
        string projectXmlSHA = Hash(Encoding.UTF8.GetBytes(projectXml));
        byte[] visualization = File.Exists(Path.ChangeExtension(projectPath, ".vis"))
            ? File.ReadAllBytes(Path.ChangeExtension(projectPath, ".vis")) : [];
        MapDocumentMutationReceipt created = MapTreeService.CreateMap(new MapDocumentRequest(
            projectPath, projectXml, projectXmlSHA,
            visualization.Length == 0 ? null : Hash(visualization), "Geometry",
            Name: "Terrain elevation check", InitialGeometryPath: geometryPath,
            InitialGeometryRevision: Hash(File.ReadAllBytes(geometryPath))));
        var map = new MapTreeRequest(projectPath, projectXml, projectXmlSHA,
            "map-terrain-elevation-check", created.MapIndex, created.MapName,
            created.MapType, created.VisualizationRevision);
        CatalogTreeNode[] roots = MapTreeService.Load(map).Roots;
        CatalogTreeNode geometryNode = Descendants(roots).Single(node =>
            node.Locator?.NodeType == "Geometry" &&
            SourceFilePaths.SameSourceFile(node.Locator.AssetID!, geometryPath));
        map = SetVisibility(map, geometryNode.Locator!, true);
        roots = MapTreeService.Load(map).Roots;
        CatalogTreeNode terrainNode = Descendants(roots).Single(node =>
            node.Locator?.NodeType == "Terrain" && node.Locator.AssociationKind == "Terrain" &&
            SourceFilePaths.SameSourceFile(node.Locator.AssetID!, terrainPath));
        map = SetVisibility(map, terrainNode.Locator!, true);
        roots = MapTreeService.Load(map).Roots;
        geometryNode = Descendants(roots).Single(node => node.Locator?.NodeType == "Geometry" &&
            SourceFilePaths.SameSourceFile(node.Locator.AssetID!, geometryPath));
        terrainNode = Descendants(roots).Single(node => node.Locator?.NodeType == "Terrain" &&
            node.Locator.AssociationKind == "Terrain" &&
            SourceFilePaths.SameSourceFile(node.Locator.AssetID!, terrainPath));
        return new Fixture(projectPath, terrainPath, rasterPath, map,
            geometryNode.Locator!, terrainNode.Locator!);
    }

    private static MapTreeRequest SetVisibility(MapTreeRequest map,
        CatalogTreeNodeLocator locator, bool visible)
    {
        MapTreeMutationResult update = MapTreeService.Perform(new MapTreeActionRequest(
            map, "visibility", Node: locator, Checked: visible));
        return map with { ExpectedVisualizationRevision = update.VisualizationRevision };
    }

    private static void WriteRaster(string path)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        using var driver = Gdal.GetDriverByName("GTiff");
        using var dataset = driver.Create(path, 16, 16, 1, DataType.GDT_Float32, ["TILED=YES"]);
        dataset.SetGeoTransform([0, 1, 0, 16, 0, -1]);
        using var band = dataset.GetRasterBand(1);
        float[] values = new float[16 * 16];
        for (int row = 0; row < 16; row++)
        for (int column = 0; column < 16; column++)
            values[row * 16 + column] = 50 + row * 3 + column * 2;
        band.WriteRaster(0, 0, 16, 16, values, 16, 16, 0, 0);
    }

    private static IEnumerable<CatalogTreeNode> Descendants(IEnumerable<CatalogTreeNode> roots)
    {
        foreach (CatalogTreeNode node in roots)
        {
            yield return node;
            foreach (CatalogTreeNode child in Descendants(node.Children ?? [])) yield return child;
        }
    }

    private static string Hash(byte[] bytes) => Convert.ToHexString(SHA256.HashData(bytes));

    private static bool SameLocator(CatalogTreeNodeLocator left, CatalogTreeNodeLocator right) =>
        string.Equals(left.RootName, right.RootName, StringComparison.Ordinal) &&
        string.Equals(left.NodeType, right.NodeType, StringComparison.Ordinal) &&
        string.Equals(left.NodeName, right.NodeName, StringComparison.Ordinal) &&
        (left.NodePath ?? []).SequenceEqual(right.NodePath ?? []) &&
        SameOptionalPath(left.AssetID, right.AssetID) &&
        string.Equals(left.MapType, right.MapType, StringComparison.Ordinal) &&
        SameOptionalPath(left.Filename, right.Filename) &&
        SameOptionalPath(left.FilenameRelative, right.FilenameRelative) &&
        SameOptionalPath(left.ParentGeometryAssetID, right.ParentGeometryAssetID) &&
        (left.ParentGeometryNodePath ?? []).SequenceEqual(right.ParentGeometryNodePath ?? []) &&
        string.Equals(left.ParentGeometryNodeName, right.ParentGeometryNodeName, StringComparison.Ordinal) &&
        SameOptionalPath(left.AssociationAssetID, right.AssociationAssetID) &&
        string.Equals(left.AssociationKind, right.AssociationKind, StringComparison.Ordinal) &&
        SameOptionalPath(left.ParentPlanAssetID, right.ParentPlanAssetID) &&
        (left.ParentPlanNodePath ?? []).SequenceEqual(right.ParentPlanNodePath ?? []) &&
        string.Equals(left.ParentPlanNodeName, right.ParentPlanNodeName, StringComparison.Ordinal) &&
        string.Equals(left.ParentResultNodeType, right.ParentResultNodeType, StringComparison.Ordinal) &&
        SameOptionalPath(left.ParentResultAssetID, right.ParentResultAssetID) &&
        (left.ParentResultNodePath ?? []).SequenceEqual(right.ParentResultNodePath ?? []) &&
        string.Equals(left.ParentResultNodeName, right.ParentResultNodeName, StringComparison.Ordinal) &&
        string.Equals(left.ParentResultRevision, right.ParentResultRevision, StringComparison.Ordinal) &&
        SameOptionalPath(left.ParentBoundaryConditionAssetID, right.ParentBoundaryConditionAssetID) &&
        (left.ParentBoundaryConditionNodePath ?? []).SequenceEqual(right.ParentBoundaryConditionNodePath ?? []) &&
        string.Equals(left.ParentBoundaryConditionNodeName, right.ParentBoundaryConditionNodeName, StringComparison.Ordinal);

    private static bool SameOptionalPath(string? left, string? right) =>
        left is null || right is null
            ? left is null && right is null
            : left.Length == 0 || right.Length == 0
                ? string.Equals(left, right, StringComparison.Ordinal)
                : Path.IsPathRooted(left) && Path.IsPathRooted(right)
                    ? SourceFilePaths.SameSourceFile(left, right)
                    : string.Equals(left, right, StringComparison.Ordinal);

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

    private sealed record Fixture(string ProjectPath, string TerrainPath, string RasterPath,
        MapTreeRequest Map, CatalogTreeNodeLocator GeometryNode, CatalogTreeNodeLocator TerrainNode);
}
