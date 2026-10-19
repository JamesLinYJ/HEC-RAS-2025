using System.Security.Cryptography;
using System.Text;
using Geospatial.GDALAssist;
using OSGeo.OGR;
using OSGeo.OSR;
using Ras.Backend;
using Ras.Layers;

internal static class GdbRasterSourceChecks
{
    private const string MapID = "8ee42f88-96b3-45ea-86d2-965e4736b829";

    internal static void Run()
    {
        using var temporary = new TemporaryDirectory();
        string root = temporary.FullName;
        string projectPath = Path.Combine(root, "gdb-raster-catalog.ras");
        Project createdProject = Project.CreateNew(projectPath, ProjectionDefinition.FromEPSG(32650));
        DisposeProject(createdProject);
        string projectXml = File.ReadAllText(projectPath, Encoding.UTF8);
        string projectXmlSHA = Hash(Encoding.UTF8.GetBytes(projectXml));
        string projectRevision = Hash(File.ReadAllBytes(projectPath));
        MapDocumentMutationReceipt createdMap = MapTreeService.CreateMap(new MapDocumentRequest(
            projectPath, projectXml, projectXmlSHA, null, "Project", Name: "GDB raster catalog map", MapID: MapID));

        string gdbPath = Path.Combine(root, "vector-only.gdb");
        CreateVectorOnlyGdb(gdbPath);
        VerifyOpenFileGdbVectorOnlyDataset(gdbPath);
        GdbMapSourceIdentity source = GdbMapSourceService.CaptureSource(gdbPath);
        GdbRasterCatalogResult rasterCatalog = GdbRasterSourceService.CatalogSubdatasets(gdbPath, source);
        Check(SameSource(source, rasterCatalog.Source) && rasterCatalog.Subdatasets.Length == 0,
            "A valid vector-only OpenFileGDB has an empty raster catalog and preserves the shared full-directory identity.");

        GdbMapCatalogResponse vectors = GdbMapSourceService.Catalog(new(gdbPath, source.Revision));
        Check(vectors.Layers.Length == 1 && vectors.Layers[0].Name == "Vector_only" &&
              vectors.Layers[0].VectorType == "Point" &&
              vectors.Layers[0].GeometryTypeCode == (int)wkbGeometryType.wkbPoint &&
              vectors.Layers[0].FeatureCount == 1,
            "The source fixture is a real OpenFileGDB vector dataset, not a synthetic raster descriptor.");
        MapDocumentMutationReceipt imported = MapTreeService.ImportGdbVector(new(
            MapDocumentRequestFor(projectPath, projectXml, createdMap), projectRevision, source)).Receipt;
        MapTreeRequest mapRequest = MapTreeRequestFor(projectPath, projectXml, imported);
        CatalogTreeNode tree = FindNode(MapTreeService.Load(mapRequest).Roots,
            node => node.Locator is { NodeType: "GdbVectorLayer", MapType: "GdbVectorLayer" });
        CatalogTreeNodeLocator vectorLocator = tree.Locator!;
        Expect<SourceFileChangedException>(() => GdbRasterSourceService.WithOpenedRasterSource(
            new GdbRasterSourceLoadRequest(mapRequest, vectorLocator, source), _ => true),
            "A vector child cannot be opened through the GDB raster source path.");

        string addedFile = Path.Combine(gdbPath, "new-stable-source-content.bin");
        File.WriteAllBytes(addedFile, [1, 2, 3, 4]);
        Expect<SourceFileChangedException>(() => GdbRasterSourceService.CatalogSubdatasets(gdbPath, source),
            "A changed GDB directory manifest invalidates the previously captured raster catalog.");
        File.Delete(addedFile);
        GdbMapSourceService.VerifySource(source);

        Console.WriteLine("GDB raster catalog rejects stale directory identities and non-raster map rows; real raster-subdataset values are checked separately by MapHoverIdentifyChecks.");
    }

    private static void CreateVectorOnlyGdb(string path)
    {
        using Driver driver = Ogr.GetDriverByName("OpenFileGDB") ??
            throw new InvalidOperationException("The packaged GDAL runtime has no OpenFileGDB driver.");
        using DataSource dataSource = driver.CreateDataSource(path, null) ??
            throw new InvalidOperationException("OpenFileGDB could not create the real vector-only fixture.");
        using var spatialReference = new SpatialReference("");
        Check(spatialReference.ImportFromEPSG(4326) == 0,
            "The GDB vector-only fixture uses a real EPSG:4326 spatial reference.");
        spatialReference.SetAxisMappingStrategy(AxisMappingStrategy.OAMS_TRADITIONAL_GIS_ORDER);
        using Layer layer = dataSource.CreateLayer("Vector_only", spatialReference,
            wkbGeometryType.wkbPoint, null) ??
            throw new InvalidOperationException("OpenFileGDB could not create the real point layer.");
        using FeatureDefn definition = layer.GetLayerDefn();
        using var feature = new Feature(definition);
        using var geometry = new OSGeo.OGR.Geometry(wkbGeometryType.wkbPoint);
        geometry.AddPoint_2D(116, 39);
        Check(feature.SetGeometry(geometry) == 0 && layer.CreateFeature(feature) == 0,
            "OpenFileGDB stores one actual point record in the vector-only fixture.");
        layer.SyncToDisk();
        dataSource.FlushCache();
    }

    private static void VerifyOpenFileGdbVectorOnlyDataset(string path)
    {
        using OSGeo.GDAL.Driver rasterVectorDriver = OSGeo.GDAL.Gdal.GetDriverByName("OpenFileGDB") ??
            throw new InvalidOperationException("The packaged GDAL runtime has no OpenFileGDB raster/vector driver.");
        Check(string.Equals(rasterVectorDriver.GetMetadataItem("DCAP_VECTOR", ""), "YES",
                  StringComparison.OrdinalIgnoreCase) &&
              string.Equals(rasterVectorDriver.GetMetadataItem("DCAP_RASTER", ""), "YES",
                  StringComparison.OrdinalIgnoreCase),
            "The packaged OpenFileGDB GDAL driver advertises both vector and raster capabilities.");

        using DataSource dataset = Ogr.OpenShared(path, 0) ??
            throw new InvalidDataException("GDAL could not reopen the generated OpenFileGDB vector fixture.");
        Check(string.Equals(dataset.GetDriver()?.GetName(), "OpenFileGDB", StringComparison.Ordinal) &&
              dataset.GetLayerCount() == 1,
            "The raster-negative fixture is an actual OpenFileGDB dataset with exactly one vector layer.");
        using Layer layer = dataset.GetLayerByIndex(0) ??
            throw new InvalidDataException("The actual OpenFileGDB fixture has no vector layer.");
        using FeatureDefn definition = layer.GetLayerDefn();
        Check(string.Equals(layer.GetName(), "Vector_only", StringComparison.Ordinal) &&
              definition.GetGeomType() == wkbGeometryType.wkbPoint && layer.GetFeatureCount(1) == 1,
            "The OpenFileGDB layer contains the real named point feature and is not a synthetic raster descriptor.");
    }

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
        throw new KeyNotFoundException("The expected GDB child is missing from the saved map tree.");
    }

    private static MapDocumentRequest MapDocumentRequestFor(string projectPath, string projectXml,
        MapDocumentMutationReceipt map) => new(projectPath, projectXml, Hash(Encoding.UTF8.GetBytes(projectXml)),
        Hash(File.ReadAllBytes(Path.ChangeExtension(projectPath, ".vis"))), "Project",
        MapID: MapID, MapIndex: map.MapIndex, MapName: map.MapName, MapType: map.MapType);

    private static MapTreeRequest MapTreeRequestFor(string projectPath, string projectXml,
        MapDocumentMutationReceipt map) => new(projectPath, projectXml, Hash(Encoding.UTF8.GetBytes(projectXml)),
        MapID, map.MapIndex, map.MapName, map.MapType,
        Hash(File.ReadAllBytes(Path.ChangeExtension(projectPath, ".vis"))));

    private static bool SameSource(GdbMapSourceIdentity first, GdbMapSourceIdentity second) =>
        Path.GetFullPath(first.SourcePath) == Path.GetFullPath(second.SourcePath) &&
        string.Equals(first.Revision, second.Revision, StringComparison.OrdinalIgnoreCase) &&
        first.Files.Length == second.Files.Length && first.Files.Zip(second.Files).All(pair =>
            pair.First.RelativePath == pair.Second.RelativePath && pair.First.Length == pair.Second.Length &&
            string.Equals(pair.First.Revision, pair.Second.Revision, StringComparison.OrdinalIgnoreCase));

    private static string Hash(byte[] bytes) => Convert.ToHexString(SHA256.HashData(bytes));

    private static void DisposeProject(Project project)
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

    private static void Expect<T>(Action action, string message) where T : Exception
    {
        try { action(); }
        catch (T) { return; }
        throw new InvalidOperationException("Expected " + typeof(T).Name + ": " + message);
    }

    private sealed class TemporaryDirectory : IDisposable
    {
        private readonly DirectoryInfo directory = Directory.CreateTempSubdirectory("hecras-gdb-raster-");
        public string FullName => directory.FullName;
        public void Dispose() => directory.Delete(recursive: true);
    }
}
