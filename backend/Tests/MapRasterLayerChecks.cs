using System.Security.Cryptography;
using System.Text;
using System.Xml.Linq;
using Geospatial.GDALAssist;
using OSGeo.GDAL;
using Ras.Backend;
using Utility.Files;

internal static class MapRasterLayerChecks
{
    internal static void Run()
    {
        using var temporary = new TemporaryDirectory();
        string root = temporary.FullName;
        string projectPath = Path.Combine(root, "GDAL Raster.ras");
        Ras.Layers.Project.CreateNew(projectPath, Utility.Units.UnitSystem.SI).Save();
        string projectXml = File.ReadAllText(projectPath);
        string projectRevision = Hash(File.ReadAllBytes(projectPath));
        string projectXmlSHA = Hash(Encoding.UTF8.GetBytes(projectXml));
        MapDocumentMutationReceipt map = MapTreeService.CreateMap(new(projectPath, projectXml,
            projectXmlSHA, null, "Project", Name: "Project map"));
        string visualizationPath = Path.ChangeExtension(projectPath, ".vis");
        string visualizationRevision = map.VisualizationRevision;

        (string File, DataType Type, int Bands, string MapType)[] cases =
        [
            ("continuous.tif", DataType.GDT_Float32, 1, "SingleBandRasterMapLayer"),
            ("rgb.tif", DataType.GDT_Byte, 3, "ImageRasterMapLayer"),
            ("classes-int32.tif", DataType.GDT_Int32, 1, "DiscreteRasterMapLayer"),
            ("classes-uint32.tif", DataType.GDT_UInt32, 1, "DiscreteRasterMapLayer"),
            ("classes-byte.tif", DataType.GDT_Byte, 1, "DiscreteRasterMapLayer")
        ];
        foreach (var item in cases)
        {
            string sourcePath = Path.Combine(root, item.File);
            CreateRaster(sourcePath, item.Type, item.Bands);
            MapRasterLayerInspectResult inspection = MapRasterLayerService.Inspect(new(sourcePath));
            Check(inspection.MapLayerType == item.MapType && inspection.SupportedMapLayerTypes.SequenceEqual([item.MapType]),
                $"GDAL type classification retains {item.MapType}.");
            Check(inspection.SourceRevision.Length == 64 && inspection.CanRenderPreview,
                "The source inspection returns a deterministic exact-manifest revision and preview eligibility.");
            MapRasterLayerPreviewResult preview = MapRasterLayerService.Preview(new(sourcePath,
                inspection.SourceRevision, item.MapType, projectPath, projectXml, projectXmlSHA));
            Check(preview.Raster.SourceMapID is null && preview.Raster.Width > 0 && preview.Raster.Height > 0 &&
                preview.Raster.Rgba.Length == preview.Raster.Width * preview.Raster.Height * 4,
                "Preview is rendered from the current source context as RGBA pixels.");

            MapDocumentRequest owner = new(projectPath, projectXml, projectXmlSHA, visualizationRevision,
                "Project", MapIndex: map.MapIndex, MapName: map.MapName, MapType: map.MapType);
            MapDocumentMutationReceipt imported = MapTreeService.ImportRasterLayer(new(owner, sourcePath,
                inspection.SourceRevision, item.MapType, projectRevision, inspection.SourceCanonicalPath));
            visualizationRevision = imported.VisualizationRevision;
            XDocument document = XDocument.Load(visualizationPath, LoadOptions.PreserveWhitespace);
            XElement node = document.Descendants("Node").Single(candidate =>
                (string?)candidate.Attribute("MapType") == item.MapType &&
                (string?)candidate.Attribute("Filename") == sourcePath);
            Check((string?)node.Attribute("IsChecked") == "true" &&
                (string?)node.Attribute("FilenameRelative") == item.File,
                "The `.vis` node persists the exact original source path and selected renderer MapType.");

            // Use the stored tree position rather than assuming a flat tree when
            // constructing the exact map source identity for readback.
            XElement[] children = document.Root!.Element("Maps")!.Elements("Map").Single()
                .Element("Tree")!.Element("Nodes")!.Elements("Node").ToArray();
            var indexed = FindNodePath(children, node, []);
            string sourceID = $"vis-map-{map.MapIndex}-node-{string.Join('.', indexed)}";
            var source = new RasterMapSourceIdentity(sourceID, projectPath, visualizationPath,
                visualizationRevision, map.MapIndex, map.MapName, map.MapType, indexed,
                item.File[..^4], item.MapType, sourcePath, item.File, sourcePath,
                Guid.NewGuid().ToString(), inspection.SourceRevision);
            MapRasterLayerReadResult loaded = MapRasterLayerService.Load(new(source, projectXml));
            Check(loaded.SourceRevision == inspection.SourceRevision && loaded.Raster.SourceMapID == source.SourceMapID &&
                loaded.Raster.Width > 0 && loaded.Raster.Height > 0 &&
                loaded.Raster.Rgba.Length == loaded.Raster.Width * loaded.Raster.Height * 4,
                "Reopening the serialized source retains its map identity and renders through the selected GDAL context.");
        }

        string vrtPath = Path.Combine(root, "continuous.vrt");
        GDALRaster.BuildVRT([Path.Combine(root, cases[0].File)], vrtPath);
        MapRasterLayerInspectResult vrt = MapRasterLayerService.Inspect(new(vrtPath));
        string before = vrt.SourceRevision;
        string dependency = Path.Combine(root, cases[0].File);
        MapDocumentRequest vrtOwner = new(projectPath, projectXml, projectXmlSHA, visualizationRevision,
            "Project", MapIndex: map.MapIndex, MapName: map.MapName, MapType: map.MapType);
        using (var update = Gdal.Open(dependency, Access.GA_Update))
        using (var band = update.GetRasterBand(1)) band.Fill(73, 0);
        MapRasterLayerInspectResult updatedVrt = MapRasterLayerService.Inspect(new(vrtPath));
        Check(updatedVrt.SourceRevision != before,
            "Changing a VRT dependency changes its manifest identity even when the VRT XML is unchanged.");
        ExpectThrows<SourceFileChangedException>(() => MapRasterLayerService.Preview(new(vrtPath,
            before, vrt.MapLayerType, projectPath, projectXml, projectXmlSHA)));
        ExpectThrows<SourceFileChangedException>(() => MapTreeService.ImportRasterLayer(new(vrtOwner,
            vrtPath, before, vrt.MapLayerType, projectRevision, vrt.SourceCanonicalPath)));
        MapDocumentMutationReceipt vrtImport = MapTreeService.ImportRasterLayer(new(vrtOwner,
            vrtPath, updatedVrt.SourceRevision, updatedVrt.MapLayerType, projectRevision,
            updatedVrt.SourceCanonicalPath));
        visualizationRevision = vrtImport.VisualizationRevision;
        XDocument vrtDocument = XDocument.Load(visualizationPath, LoadOptions.PreserveWhitespace);
        XElement vrtNode = vrtDocument.Descendants("Node").Single(candidate =>
            (string?)candidate.Attribute("Filename") == vrtPath);
        Check((string?)vrtNode.Attribute("Filename") == vrtPath &&
            (string?)vrtNode.Attribute("FilenameRelative") == Path.GetFileName(vrtPath),
            "The VRT node retains the absolute source path and project-relative path separately.");
        int[] vrtNodePath = FindNodePath(vrtDocument.Root!.Element("Maps")!.Elements("Map").Single()
            .Element("Tree")!.Element("Nodes")!.Elements("Node"), vrtNode, []);
        var vrtSource = new RasterMapSourceIdentity($"vis-map-{map.MapIndex}-node-{string.Join('.', vrtNodePath)}",
            projectPath, visualizationPath, visualizationRevision, map.MapIndex, map.MapName, map.MapType,
            vrtNodePath, (string?)vrtNode.Attribute("Name") ?? throw new InvalidDataException("The VRT node name is missing."),
            updatedVrt.MapLayerType, (string?)vrtNode.Attribute("Filename"),
            (string?)vrtNode.Attribute("FilenameRelative"), vrtPath,
            Guid.NewGuid().ToString(), updatedVrt.SourceRevision);
        MapRasterLayerReadResult vrtLoaded = MapRasterLayerService.Load(new(vrtSource, projectXml));
        Check(vrtLoaded.SourceRevision == updatedVrt.SourceRevision && vrtLoaded.Raster.SourceMapID == vrtSource.SourceMapID,
            "An imported VRT reopens from its exact `.vis` source identity and dependency manifest.");
        using (var update = Gdal.Open(dependency, Access.GA_Update))
        using (var band = update.GetRasterBand(1)) band.Fill(91, 0);
        ExpectThrows<SourceFileChangedException>(() => MapRasterLayerService.Load(new(vrtSource, projectXml)));
        Console.WriteLine("GDAL continuous, RGB, integer/byte discrete and VRT source-backed import/readback checks passed.");
    }

    private static int[] FindNodePath(IEnumerable<XElement> nodes, XElement wanted, int[] prefix)
    {
        int index = 0;
        foreach (XElement node in nodes)
        {
            int[] path = [.. prefix, index];
            if (ReferenceEquals(node, wanted)) return path;
            int[]? descendant = TryFind(node.Elements("Node"), wanted, path);
            if (descendant is not null) return descendant;
            index++;
        }
        throw new InvalidOperationException("The serialized raster node could not be addressed in `.vis`.");
    }

    private static int[]? TryFind(IEnumerable<XElement> nodes, XElement wanted, int[] prefix)
    {
        try { return FindNodePath(nodes, wanted, prefix); }
        catch (InvalidOperationException) { return null; }
    }

    private static void CreateRaster(string path, DataType type, int bands)
    {
        using var driver = Gdal.GetDriverByName("GTiff");
        using var raster = driver.Create(path, 8, 8, bands, type, []);
        raster.SetGeoTransform([0, 1, 0, 8, 0, -1]);
        for (int index = 1; index <= bands; index++)
        {
            using var band = raster.GetRasterBand(index);
            band.Fill(type == DataType.GDT_Byte ? 128 : 7, 0);
        }
    }

    private static string Hash(byte[] bytes) => Convert.ToHexString(SHA256.HashData(bytes));
    private static void Check(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }

    private static void ExpectThrows<TException>(Action action) where TException : Exception
    {
        try { action(); }
        catch (TException) { return; }
        throw new InvalidOperationException($"Expected {typeof(TException).Name}.");
    }
}
