using System.Security.Cryptography;
using System.Text;
using Geospatial.GDALAssist;
using OSGeo.GDAL;
using OSGeo.OGR;
using OSGeo.OSR;
using Ras.Backend;
using Ras.Layers;

internal static class RasterSymbologyGdbChecks
{
    private const string MapID = "abfc7039-9429-4542-a13b-9ef0539e2744";

    internal static void Run()
    {
        using var temporary = new TemporaryDirectory();
        string root = temporary.FullName;
        CheckStagedVisualizationReceipt(root);
        string projectPath = Path.Combine(root, "raster-symbology-gdb.ras");
        Project project = Project.CreateNew(projectPath, ProjectionDefinition.FromEPSG(32650));
        DisposeProject(project);
        string projectXml = File.ReadAllText(projectPath, Encoding.UTF8);
        string projectXmlRevision = Hash(Encoding.UTF8.GetBytes(projectXml));
        string projectRevision = Hash(File.ReadAllBytes(projectPath));
        MapDocumentMutationReceipt created = MapTreeService.CreateMap(new MapDocumentRequest(
            projectPath, projectXml, projectXmlRevision, null, "Project", Name: "GDB Raster Symbology", MapID: MapID));

        string gdbPath = Path.Combine(root, "vector-only.gdb");
        CreateVectorOnlyGdb(gdbPath);
        GdbMapSourceIdentity source = GdbMapSourceService.CaptureSource(gdbPath);
        GdbMapImportResponse imported = MapTreeService.ImportGdbVector(new(
            MapDocumentRequestFor(projectPath, projectXml, created), projectRevision, source));
        MapDocumentMutationReceipt importedReceipt = imported.Receipt;
        MapTreeRequest map = MapTreeRequestFor(projectPath, projectXml, importedReceipt);
        CatalogTreeNode vectorNode = FindNode(MapTreeService.Load(map).Roots,
            node => node.Locator is { NodeType: "GdbVectorLayer", MapType: "GdbVectorLayer" });
        CatalogTreeNodeLocator vectorLocator = vectorNode.Locator!;
        string visualizationPath = Path.ChangeExtension(projectPath, ".vis");
        byte[] before = File.ReadAllBytes(visualizationPath);

        var wrongRasterIdentity = new GdbRasterSymbologyIdentity(map, vectorLocator, source);
        var wrongRaster = new RasterMapSourceIdentity(
            $"vis-map-{map.MapIndex}-node-{string.Join(".", vectorLocator.NodePath!)}",
            map.ProjectPath, visualizationPath, map.ExpectedVisualizationRevision!, map.MapIndex,
            map.MapName, map.MapType, vectorLocator.NodePath!, vectorLocator.NodeName,
            "SingleBandRasterMapLayer", vectorLocator.Filename, vectorLocator.FilenameRelative,
            gdbPath, map.MapID, source.Revision, wrongRasterIdentity);
        Expect<SourceFileChangedException>(() => RasterSymbologyService.Inspect(new(wrongRaster, projectXml)),
            "A GDB vector row must never be read or accepted through raster symbology.");
        Check(File.ReadAllBytes(visualizationPath).SequenceEqual(before),
            "A rejected GDB vector row leaves the owning .vis bytes unchanged.");

        CatalogTreeNodeLocator rasterShapedLocator = vectorLocator with
        {
            NodeType = "MapLayer",
            MapType = "SingleBandRasterMapLayer",
            AssetID = gdbPath,
            Filename = vectorLocator.Filename ?? "GDB raster connection"
        };
        var staleSource = source with { Revision = new string('F', 64) };
        var staleIdentity = new GdbRasterSymbologyIdentity(map, rasterShapedLocator, staleSource);
        var staleRaster = wrongRaster with
        {
            NodeName = rasterShapedLocator.NodeName,
            Filename = rasterShapedLocator.Filename,
            FilenameRelative = rasterShapedLocator.FilenameRelative,
            SourceRevision = staleSource.Revision,
            GdbSource = staleIdentity
        };
        Expect<SourceFileChangedException>(() => RasterSymbologyService.Inspect(new(staleRaster, projectXml)),
            "A stale full-directory GDB revision must be rejected before raster pixels are read.");
        Check(File.ReadAllBytes(visualizationPath).SequenceEqual(before),
            "A stale GDB manifest cannot mutate the visualization file.");

        CheckOrdinaryTiffStillLoads(root);
        Console.WriteLine("GDB raster symbology rejects mismatched node types and stale full-directory identities; staged visualization commits return the exact staged SHA; ordinary TIFF inspection still uses its existing source-backed path.");
    }

    private static void CheckStagedVisualizationReceipt(string root)
    {
        string visualizationPath = Path.Combine(root, "staged-receipt.vis");
        string temporaryPath = visualizationPath + ".staged";
        byte[] original = Encoding.UTF8.GetBytes("<Ras><Maps /></Ras>");
        byte[] staged = Encoding.UTF8.GetBytes("<Ras><Maps /><Symbology /></Ras>");
        File.WriteAllBytes(visualizationPath, original);
        File.WriteAllBytes(temporaryPath, staged);

        string receipt = RasterSymbologyService.ReplaceStagedVisualizationFile(
            temporaryPath, visualizationPath, Hash(original), Hash(staged));
        Check(receipt == Hash(staged) && File.ReadAllBytes(visualizationPath).SequenceEqual(staged) &&
              !File.Exists(temporaryPath),
            "A successful visualization replacement returns the staged-byte SHA and commits those exact bytes.");

        byte[] competing = Encoding.UTF8.GetBytes("<Ras><Maps><Map Name=\"other\" /></Maps></Ras>");
        File.WriteAllBytes(visualizationPath, competing);
        File.WriteAllBytes(temporaryPath, staged);
        Expect<SourceFileChangedException>(() =>
        {
            _ = RasterSymbologyService.ReplaceStagedVisualizationFile(
                temporaryPath, visualizationPath, Hash(original), Hash(staged));
        }, "A stale pre-commit visualization revision must be rejected before replacement.");
        Check(File.ReadAllBytes(visualizationPath).SequenceEqual(competing),
            "A stale visualization baseline is never overwritten by the staged payload.");
        File.Delete(temporaryPath);
    }

    private static void CheckOrdinaryTiffStillLoads(string root)
    {
        string projectPath = Path.Combine(root, "ordinary-tiff.ras");
        string visualizationPath = Path.ChangeExtension(projectPath, ".vis");
        string rasterPath = Path.Combine(root, "ordinary.tif");
        Project project = Project.CreateNew(projectPath, Utility.Units.UnitSystem.SI);
        DisposeProject(project);
        CreateRaster(rasterPath);
        byte[] visualization = Encoding.UTF8.GetBytes("""
            <Ras><Maps><Map Name="TIFF map" Type="Project"><Tree><Nodes>
            <Node Type="MapLayer" MapType="SingleBandRasterMapLayer" Name="Ordinary TIFF" Filename="ordinary.tif" FilenameRelative="ordinary.tif" />
            </Nodes></Tree></Map></Maps><Symbology /></Ras>
            """);
        File.WriteAllBytes(visualizationPath, visualization);
        var source = new RasterMapSourceIdentity("vis-map-0-node-0", projectPath, visualizationPath,
            Hash(visualization), 0, "TIFF map", "Project", [0], "Ordinary TIFF",
            "SingleBandRasterMapLayer", "ordinary.tif", "ordinary.tif", rasterPath,
            Guid.NewGuid().ToString("D"), Hash(File.ReadAllBytes(rasterPath)));
        RasterSymbologyInspectResult result = RasterSymbologyService.Inspect(new(source, "<Project />"));
        Check(result.SourceRevision == source.SourceRevision && result.Raster.Width > 0 &&
              result.Raster.Height > 0 && result.Raster.Rgba.Length == result.Raster.Width * result.Raster.Height * 4,
            "The regular single-file TIFF path still renders the actual raster and reports its file hash.");
    }

    private static void CreateVectorOnlyGdb(string path)
    {
        using OSGeo.OGR.Driver driver = Ogr.GetDriverByName("OpenFileGDB") ??
            throw new InvalidOperationException("The packaged GDAL runtime has no OpenFileGDB driver.");
        using DataSource dataSource = driver.CreateDataSource(path, null) ??
            throw new InvalidOperationException("OpenFileGDB could not create the real vector-only fixture.");
        using var spatialReference = new SpatialReference("");
        Check(spatialReference.ImportFromEPSG(4326) == 0,
            "The GDB identity fixture uses a valid spatial reference.");
        spatialReference.SetAxisMappingStrategy(AxisMappingStrategy.OAMS_TRADITIONAL_GIS_ORDER);
        using Layer layer = dataSource.CreateLayer("Identity probe", spatialReference,
            wkbGeometryType.wkbPoint, null) ??
            throw new InvalidOperationException("OpenFileGDB could not create the identity probe layer.");
        using FeatureDefn definition = layer.GetLayerDefn();
        using var feature = new Feature(definition);
        using var geometry = new OSGeo.OGR.Geometry(wkbGeometryType.wkbPoint);
        geometry.AddPoint_2D(116, 39);
        Check(feature.SetGeometry(geometry) == 0 && layer.CreateFeature(feature) == 0,
            "OpenFileGDB writes a real source row for the wrong-node check.");
        layer.SyncToDisk();
        dataSource.FlushCache();
    }

    private static void CreateRaster(string path)
    {
        using var driver = Gdal.GetDriverByName("GTiff") ??
            throw new InvalidOperationException("The packaged GDAL runtime has no GTiff driver.");
        using var dataset = driver.Create(path, 8, 8, 1, DataType.GDT_Float32, []);
        dataset.SetGeoTransform([0, 1, 0, 8, 0, -1]);
        using var band = dataset.GetRasterBand(1);
        band.Fill(42, 0);
    }

    private static MapDocumentRequest MapDocumentRequestFor(string projectPath, string projectXml,
        MapDocumentMutationReceipt map) => new(projectPath, projectXml,
        Hash(Encoding.UTF8.GetBytes(projectXml)), Hash(File.ReadAllBytes(Path.ChangeExtension(projectPath, ".vis"))),
        "Project", MapID: MapID, MapIndex: map.MapIndex, MapName: map.MapName, MapType: map.MapType);

    private static MapTreeRequest MapTreeRequestFor(string projectPath, string projectXml,
        MapDocumentMutationReceipt map) => new(projectPath, projectXml,
        Hash(Encoding.UTF8.GetBytes(projectXml)), MapID, map.MapIndex, map.MapName, map.MapType,
        Hash(File.ReadAllBytes(Path.ChangeExtension(projectPath, ".vis"))));

    private static CatalogTreeNode FindNode(IEnumerable<CatalogTreeNode> nodes,
        Func<CatalogTreeNode, bool> predicate)
    {
        foreach (CatalogTreeNode node in nodes)
        {
            if (predicate(node)) return node;
            if (node.Children is { Length: > 0 })
            {
                try { return FindNode(node.Children, predicate); }
                catch (KeyNotFoundException) { }
            }
        }
        throw new KeyNotFoundException("The expected GDB identity probe map row is missing.");
    }

    private static void DisposeProject(Project project)
    {
        foreach (CoreLayerBase layer in project.Plans.Cast<CoreLayerBase>().Concat(project.Geometries)
                     .Concat(project.Terrains).Concat(project.BoundaryConditions).Concat(project.NValues)
                     .Concat(project.ClassificationLayers))
            layer.Dispose();
        foreach (Result result in project.Results) result.Dispose();
    }

    private static string Hash(byte[] bytes) => Convert.ToHexString(SHA256.HashData(bytes));

    private static void Check(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }

    private static void Expect<T>(Action action, string message) where T : Exception
    {
        try { action(); }
        catch (T) { return; }
        throw new InvalidOperationException("Expected " + typeof(T).Name + ": " + message);
    }

    private sealed class TemporaryDirectory : IDisposable
    {
        private readonly DirectoryInfo directory = Directory.CreateTempSubdirectory("hecras-raster-gdb-symbology-");
        public string FullName => directory.FullName;
        public void Dispose() => directory.Delete(recursive: true);
    }
}
