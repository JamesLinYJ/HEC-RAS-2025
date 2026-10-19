using System.Security.Cryptography;
using System.Text;
using Geospatial.PairedData;
using Geospatial.Rasters.Modifiers;
using Geospatial.Rasters;
using Geospatial.Vectors;
using Ras.Backend;
using Ras.Layers;
using Ras.Layers.Terrains;
using Utility.Units;

internal static class TerrainInputMapContextChecks
{
    internal static void Run()
    {
        using var directory = new TemporaryDirectory();
        string projectPath = Path.Combine(directory.FullName, "terrain-input-map.ras");
        Project project = Project.CreateNew(projectPath, ProjectionDefinition.FromEPSG(32650));
        Terrain terrain = project.AddNewTerrain("Map context");

        ChannelModTerrainInput channel = new(terrain, "Channel source");
        channel.Add(new ChannelProfile(new Polyline(new Point[] { new(10, 20), new(30, 40) }),
            new StationElevationProfile([0, 1], [2, 1])) { Name = "Channel line" });
        terrain.Add(channel);

        PolygonRasterModTerrainInput polygon = new(terrain, "Polygon source");
        polygon.Add(new PolygonRasterMod(new Polygon(new Point[] {
            new Point(50, 60), new Point(70, 60), new Point(70, 80), new Point(50, 80)
        }), RasterModType.AddValue, 1));
        terrain.Add(polygon);

        LeveeModTerrainInput levee = new(terrain, "Levee source");
        levee.PropertiesTable.Add(new LeveeModProperties { Name = "Default" });
        levee.Add(new LeveeMod(new Polyline(new Point[] { new(90, 20), new(110, 40) }),
            new StationElevationProfile([0, 20], [4, 3]))
        { Name = "Levee line", LeveePropertyName = "Default" });
        terrain.Add(levee);

        project.Save();
        terrain.Save();
        string terrainPath = terrain.Filename;
        terrain.Dispose();

        string projectXml = File.ReadAllText(projectPath);
        string projectXmlSHA = Hash(Encoding.UTF8.GetBytes(projectXml));
        MapDocumentMutationReceipt created = MapTreeService.CreateMap(new MapDocumentRequest(
            projectPath, projectXml, projectXmlSHA, null, "Project"));
        MapTreeRequest map = new(projectPath, projectXml, projectXmlSHA, "terrain-map-session",
            created.MapIndex, created.MapName, created.MapType, created.VisualizationRevision);
        MapTreeSnapshot tree = MapTreeService.Load(map);
        CatalogTreeNode[] inputs = Flatten(tree.Roots).Where(node => node.Locator?.NodeType == "TerrainInput").ToArray();
        string visualizationPath = Path.ChangeExtension(projectPath, ".vis");
        byte[] visualizationBefore = File.ReadAllBytes(visualizationPath);

        Check(inputs.Length == 3 && inputs.All(node => node.Checked == "unchecked" && !node.CanPin)
            && inputs.Select(node => node.Id).Distinct(StringComparer.Ordinal).Count() == 3,
            "Renderable Channel, Polygon and Levee terrain inputs have distinct unchecked transient rows and no source pin capability");

        foreach (var expected in new[]
        {
            (SourceClass: "ChannelModTerrainInputParentVC", Kind: "line", Count: 1, Index: 0),
            (SourceClass: "PolygonRasterModTerrainInputVisualContext", Kind: "polygon", Count: 1, Index: 1),
            (SourceClass: "LeveeModTerrainInputVC", Kind: "line", Count: 1, Index: 2)
        })
        {
            CatalogTreeNode node = inputs.Single(candidate => candidate.SourceClass == expected.SourceClass);
            TerrainInputMapContextData rendered = TerrainInputMapContextService.Render(
                new TerrainInputMapContextRequest(map, node.Id, node.SourceClass, terrainPath));
            Check(rendered.InputNodeID == node.Id
                && rendered.InputIndex == expected.Index
                && rendered.SourceClass == expected.SourceClass
                && rendered.TerrainPath == Path.GetFullPath(terrainPath)
                && rendered.TerrainRevision.Length == 64
                && rendered.Features.Length == expected.Count
                && rendered.Features.All(feature => feature.Kind == expected.Kind
                    && feature.Points.Length >= (expected.Kind == "line" ? 2 : 3)
                    && feature.Points.All(point => double.IsFinite(point.X) && double.IsFinite(point.Y))),
                $"{expected.SourceClass} returns its actual finite source geometry in project map coordinates");
        }

        CatalogTreeNode selected = inputs.Single(node => node.SourceClass == "ChannelModTerrainInputParentVC");
        Expect<SourceFileChangedException>(() =>
        {
            _ = TerrainInputMapContextService.Render(new TerrainInputMapContextRequest(
                map, selected.Id, "LeveeModTerrainInputVC", terrainPath));
        });
        Expect<SourceFileChangedException>(() =>
        {
            _ = TerrainInputMapContextService.Render(new TerrainInputMapContextRequest(map, selected.Id,
                selected.SourceClass, Path.Combine(directory.FullName, "other-terrain.hdf")));
        });

        Check(File.ReadAllBytes(visualizationPath).SequenceEqual(visualizationBefore),
            "Transient TerrainInput map checks do not write their state into the saved .vis document");
    }

    private static IEnumerable<CatalogTreeNode> Flatten(IEnumerable<CatalogTreeNode> nodes)
    {
        foreach (CatalogTreeNode node in nodes)
        {
            yield return node;
            if (node.Children is { } children)
                foreach (CatalogTreeNode child in Flatten(children)) yield return child;
        }
    }

    private static string Hash(byte[] bytes) => Convert.ToHexString(SHA256.HashData(bytes));

    private static void Check(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }

    private static void Expect<TException>(Action action) where TException : Exception
    {
        try { action(); }
        catch (TException) { return; }
        throw new InvalidOperationException("Expected " + typeof(TException).Name);
    }
}
