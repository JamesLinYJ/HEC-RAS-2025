using System.Security.Cryptography;
using System.Text;
using System.Globalization;
using System.Xml.Linq;
using Geospatial.GDALAssist;
using OSGeo.GDAL;
using Ras.Backend;
using Utility.Files;

internal static class MapRasterImportChecks
{
    internal static void Run()
    {
        using var temporary = new TemporaryDirectory();
        string projectPath = Path.Combine(temporary.FullName, "Raster Import.ras");
        Ras.Layers.Project.CreateNew(projectPath, Utility.Units.UnitSystem.SI).Save();
        byte[] originalProject = File.ReadAllBytes(projectPath);
        string projectXml = File.ReadAllText(projectPath);
        string projectRevision = Hash(originalProject);
        string rasterPath = Path.Combine(temporary.FullName, "地理处理结果.tif");
        CreateRaster(rasterPath, 42);
        byte[] originalRaster = File.ReadAllBytes(rasterPath);
        string rasterRevision = Hash(originalRaster);
        string visPath = Path.ChangeExtension(projectPath, ".vis");
        string? initialVisRevision = File.Exists(visPath) ? Hash(File.ReadAllBytes(visPath)) : null;
        var initialMap = new MapDocumentRequest(projectPath, projectXml, Hash(Encoding.UTF8.GetBytes(projectXml)),
            initialVisRevision, "Project");
        var request = new MapRasterImportRequest(initialMap, rasterPath, rasterRevision,
            projectRevision, SourceFilePaths.Canonical(rasterPath));

        MapDocumentMutationReceipt imported = MapTreeService.ImportRaster(request);
        Check(imported.MapIndex == 0 && imported.MapType == "Project" &&
            imported.PreviousVisualizationRevision == initialVisRevision,
            "Import creates the first real Project map and reports its exact visualization transition.");
        XDocument saved = XDocument.Load(visPath);
        XElement map = saved.Root!.Element("Maps")!.Elements("Map").ElementAt(imported.MapIndex);
        XElement root = map.Element("Tree")!.Element("Nodes")!.Elements("Node")
            .Single(node => (string?)node.Attribute("Name") == "Map Layers");
        XElement rasterFolder = root.Elements("Node").Single(node => (string?)node.Attribute("Name") == "Rasters");
        XElement layer = rasterFolder.Elements("Node").Single();
        Check((string?)layer.Attribute("MapType") == "SingleBandRasterMapLayer" &&
            (string?)layer.Attribute("IsChecked") == "true" &&
            (string?)layer.Attribute("FilenameRelative") == Path.GetFileName(rasterPath),
            "The saved checked raster node uses the source map format and relative source identity.");
        int[] rasterNodePath = [0, 0, 0];
        string rasterSourceID = $"vis-map-{imported.MapIndex}-node-{string.Join(".", rasterNodePath)}";
        var source = new RasterMapSourceIdentity(rasterSourceID, projectPath, visPath,
            imported.VisualizationRevision, imported.MapIndex, imported.MapName, imported.MapType, rasterNodePath,
            Path.GetFileNameWithoutExtension(rasterPath), "SingleBandRasterMapLayer", rasterPath,
            Path.GetFileName(rasterPath), rasterPath, Guid.NewGuid().ToString(), rasterRevision);
        RasterSymbologyInspectResult actualPixels = RasterSymbologyService.Load(new(source, projectXml));
        Check(actualPixels.SourceRevision == rasterRevision && actualPixels.Raster.Width > 0 &&
            actualPixels.Raster.Height > 0 &&
            actualPixels.Raster.Rgba.Length == actualPixels.Raster.Width * actualPixels.Raster.Height * 4 &&
            actualPixels.Raster.Rgba.Where((_, index) => index % 4 == 3).Any(alpha => alpha != 0),
            "The reopened imported layer renders actual GDAL TIFF pixels through the production raster service.");
        Check(actualPixels.RasterInfoStats is { } rasterProperties &&
            SourceFilePaths.Canonical(rasterProperties.Path) == SourceFilePaths.Canonical(rasterPath) &&
            rasterProperties.Revision == rasterRevision && rasterProperties.Info?.BandCount == 1 &&
            rasterProperties.Stats is { } stats &&
            double.Parse(stats.Min, CultureInfo.CurrentCulture) == 42 &&
            double.Parse(stats.Max, CultureInfo.CurrentCulture) == 42 &&
            double.Parse(stats.Mean, CultureInfo.CurrentCulture) == 42,
            "rasterMap.load returns source RasterInfo and RasterStats bound to the exact source path and SHA.");
        Check(File.ReadAllBytes(projectPath).SequenceEqual(originalProject) &&
            File.ReadAllBytes(rasterPath).SequenceEqual(originalRaster),
            "Map insertion changes neither the source raster nor the saved project XML.");

        MapDocumentRequest currentOwner = initialMap with
        {
            ExpectedVisualizationRevision = imported.VisualizationRevision,
            MapIndex = imported.MapIndex, MapName = imported.MapName, MapType = imported.MapType
        };
        byte[] beforeReject = File.ReadAllBytes(visPath);
        Reject<ArgumentException>(() => MapTreeService.ImportRaster(request with { Map = currentOwner }));
        Reject<SourceFileChangedException>(() => MapTreeService.ImportRaster(request with
        {
            Map = currentOwner, ExpectedProjectRevision = new string('0', 64)
        }));
        Reject<SourceFileChangedException>(() => MapTreeService.ImportRaster(request with
        {
            Map = currentOwner, SourceRevision = new string('0', 64)
        }));
        Reject<SourceFileChangedException>(() => MapTreeService.ImportRaster(request with
        {
            Map = currentOwner, ExpectedSourceCanonicalPath = rasterPath + ".other"
        }));
        Check(File.ReadAllBytes(visPath).SequenceEqual(beforeReject),
            "Duplicate, stale project, stale raster and mismatched physical-path imports leave .vis byte-identical.");

        var buildable = MapTreeService.CreateMap(new MapDocumentRequest(projectPath, projectXml,
            Hash(Encoding.UTF8.GetBytes(projectXml)), imported.VisualizationRevision, "Buildable"));
        var buildableOwner = initialMap with
        {
            Kind = "Buildable", MapIndex = buildable.MapIndex, MapName = buildable.MapName,
            MapType = buildable.MapType, ExpectedVisualizationRevision = buildable.VisualizationRevision
        };
        MapDocumentMutationReceipt second = MapTreeService.ImportRaster(request with { Map = buildableOwner });
        var reopened = XDocument.Load(visPath).Root!.Element("Maps")!.Elements("Map").ElementAt(second.MapIndex);
        Check(reopened.Descendants("Node").Any(node =>
                (string?)node.Attribute("MapType") == "SingleBandRasterMapLayer") &&
            XDocument.Load(visPath).Root!.Element("Maps")!.Elements("Map").ElementAt(0)
                .Descendants("Node").Count(node => (string?)node.Attribute("MapType") == "SingleBandRasterMapLayer") == 1,
            "The same source can be connected to another exact saved map without duplicating or changing its first map owner.");
        var treeRequest = new MapTreeRequest(projectPath, projectXml, Hash(Encoding.UTF8.GetBytes(projectXml)),
            Guid.NewGuid().ToString(), second.MapIndex, second.MapName, second.MapType, second.VisualizationRevision);
        CatalogTreeNode rasterNode = Flatten(MapTreeService.Load(treeRequest).Roots)
            .Single(node => node.SourceClass == "RasterMapLayerVisualContext");
        MapTreeMutationResult removed = MapTreeService.Perform(new MapTreeActionRequest(treeRequest,
            "removeSourceNode", Node: rasterNode.Locator, SourcePath: rasterPath, SourceRevision: rasterRevision));
        Check(!Flatten(removed.Roots).Any(node => node.SourceClass == "RasterMapLayerVisualContext") &&
            File.ReadAllBytes(rasterPath).SequenceEqual(originalRaster) &&
            File.ReadAllBytes(projectPath).SequenceEqual(originalProject),
            "Removing the exact raster map reference preserves its TIFF and project connection source files.");
        Console.WriteLine("Real TIFF map import, first-map creation, pixel readback, saved map ownership and stale-source guards passed.");
    }

    private static IEnumerable<CatalogTreeNode> Flatten(IEnumerable<CatalogTreeNode> roots)
    {
        foreach (CatalogTreeNode node in roots)
        {
            yield return node;
            foreach (CatalogTreeNode child in Flatten(node.Children ?? [])) yield return child;
        }
    }

    private static void CreateRaster(string path, float value)
    {
        using (var driver = Gdal.GetDriverByName("GTiff"))
        using (var dataset = driver.Create(path, 8, 8, 1, DataType.GDT_Float32, []))
        {
            dataset.SetGeoTransform([0, 1, 0, 8, 0, -1]);
            using var band = dataset.GetRasterBand(1);
            band.Fill(value, 0);
        }

        // The production RasterInfo route reads cached GDAL statistics without
        // forcing a scan. These values exactly describe the constant pixels above.
        GDALRaster.SetStats(path, value, value, value, 0);
    }

    private static string Hash(byte[] bytes) => Convert.ToHexString(SHA256.HashData(bytes));
    private static void Reject<T>(Action action) where T : Exception
    {
        try { action(); }
        catch (T) { return; }
        throw new InvalidOperationException($"The raster import unexpectedly accepted a request requiring {typeof(T).Name}.");
    }
    private static void Check(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }
}
