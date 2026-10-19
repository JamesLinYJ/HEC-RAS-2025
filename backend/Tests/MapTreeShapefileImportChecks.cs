using System.Security.Cryptography;
using System.Text;
using System.Xml.Linq;
using Geospatial.Features;
using Geospatial.IO;
using Geospatial.Vectors;
using Ras.Backend;
using Utility.Memory;

internal static class MapTreeShapefileImportChecks
{
    internal static void Run()
    {
        using var temporary = new TemporaryDirectory();
        string root = temporary.FullName;
        string projectPath = Path.Combine(root, "project.ras");
        const string projectXml = "<Project />";
        byte[] projectBytes = Encoding.UTF8.GetBytes(projectXml);
        File.WriteAllBytes(projectPath, projectBytes);
        string projectRevision = Hash(projectBytes);
        MapDocumentMutationReceipt created = MapTreeService.CreateMap(new MapDocumentRequest(
            projectPath, projectXml, projectRevision, null, "Project", Name: "Project map"));

        string pointPath = Path.Combine(root, "points.shp");
        var pointTable = OneColumn("Name", "中文点");
        pointTable.AddNewRow(["第二个点"]);
        Check(ShapefileIO.Write(pointPath, new List<Point> { new(1, 2), new(3, 4) }, pointTable).Result,
            "Actual retained point Shapefile writer creates a source fixture.");

        string linePath = Path.Combine(root, "lines.shp");
        var lineTable = OneColumn("Name", "带XYZM的线");
        var line = new Polyline(new Point[] { new(0, 0), new(1, 2), new(3, 5) });
        line.TrackZ(new double[] { 10, 20, 30 });
        line.TrackM(new double[] { 100, 200, 300 });
        Check(ShapefileIO.Write(linePath, new List<Polyline> { line }, lineTable).Result,
            "Actual retained polyline Shapefile writer creates a dimensional source fixture.");
        string lineProjectionPath = ShapefileIO.PRJFilename(linePath);
        byte[] projectionBytes = Encoding.UTF8.GetBytes("source projection sidecar");
        File.WriteAllBytes(lineProjectionPath, projectionBytes);

        string polygonPath = Path.Combine(root, "polygons.shp");
        var polygonTable = OneColumn("Class", "湿地");
        Check(ShapefileIO.Write(polygonPath, new List<Polygon>
        {
            new(new Point[] { new(0, 0), new(2, 0), new(2, 2), new(0, 2) })
        }, polygonTable).Result, "Actual retained polygon Shapefile writer creates a source fixture.");

        MapSourceFamilyCapture pointFamily = MapTreeService.CaptureShapefileFamily(pointPath);
        MapSourceFamilyCapture lineFamily = MapTreeService.CaptureShapefileFamily(linePath);
        MapSourceFamilyCapture polygonFamily = MapTreeService.CaptureShapefileFamily(polygonPath);
        CheckFamily(pointFamily, pointPath, projectionExists: false);
        CheckFamily(lineFamily, linePath, projectionExists: true);
        CheckFamily(polygonFamily, polygonPath, projectionExists: false);

        string visualizationPath = Path.ChangeExtension(projectPath, ".vis");
        byte[] visualizationBeforeStaleImport = File.ReadAllBytes(visualizationPath);
        File.WriteAllText(lineProjectionPath, "changed projection sidecar", new UTF8Encoding(false));
        Expect<SourceFileChangedException>(() => MapTreeService.ImportShapefileVector(new(
            MapRequest(projectPath, projectXml, created), linePath, projectRevision, lineFamily)),
            "Changing the optional projection file after capture invalidates the complete family.");
        Check(File.ReadAllBytes(visualizationPath).SequenceEqual(visualizationBeforeStaleImport),
            "A changed sidecar is rejected before the visualization is published.");
        File.WriteAllBytes(lineProjectionPath, projectionBytes);
        lineFamily = MapTreeService.CaptureShapefileFamily(linePath);

        var beforeFiles = new[] { pointPath, ShapefileIO.SHXFilename(pointPath), ShapefileIO.DBFFilename(pointPath),
            linePath, ShapefileIO.SHXFilename(linePath), ShapefileIO.DBFFilename(linePath), lineProjectionPath,
            polygonPath, ShapefileIO.SHXFilename(polygonPath), ShapefileIO.DBFFilename(polygonPath) }
            .ToDictionary(path => path, File.ReadAllBytes, StringComparer.Ordinal);

        MapTreeService.ImportShapefileVector(new(MapRequest(projectPath, projectXml, created), pointPath,
            projectRevision, pointFamily));
        MapDocumentMutationReceipt lineImport = MapTreeService.ImportShapefileVector(new(
            MapRequest(projectPath, projectXml, created), linePath, projectRevision, lineFamily));
        MapDocumentMutationReceipt polygonImport = MapTreeService.ImportShapefileVector(new(
            MapRequest(projectPath, projectXml, lineImport), polygonPath, projectRevision, polygonFamily));

        XDocument visualization = XDocument.Load(visualizationPath, LoadOptions.PreserveWhitespace);
        XElement map = visualization.Root!.Element("Maps")!.Elements("Map").Single();
        XElement vectors = map.Descendants("Node").Single(node =>
            (string?)node.Attribute("Type") == "Folder" && (string?)node.Attribute("Name") == "Vectors");
        XElement[] layers = vectors.Elements("Node").Where(node => (string?)node.Attribute("Type") == "MapLayer").ToArray();
        Check(layers.Length == 3 &&
            layers.Single(node => (string?)node.Attribute("MapType") == "PointsVector").Attribute("Filename")?.Value == pointPath &&
            layers.Single(node => (string?)node.Attribute("MapType") == "PolylinesVector").Attribute("Filename")?.Value == linePath &&
            layers.Single(node => (string?)node.Attribute("MapType") == "PolygonsVector").Attribute("Filename")?.Value == polygonPath &&
            layers.All(node => (string?)node.Attribute("IsChecked") == "true"),
            "Each source file is persisted once under the existing map Vectors folder with its actual detected reader type.");

        Check(ShapefileIO.TryRead(pointPath, out PointFeatureCollection points).Result && points.Count == 2 &&
            (string?)points.AttributeTable.Rows[0][0] == "中文点",
            "The persisted point source still opens through its actual source reader with DBF attributes intact.");
        Check(ShapefileIO.TryRead(linePath, out PolylineCollectionFeatureCollection lines).Result && lines.Count == 1 &&
            (string?)lines.AttributeTable.Rows[0][0] == "带XYZM的线",
            "The persisted line source retains its actual record count and DBF attributes.");
        Polyline readLine = lines.ToExplodedPolylineCollection().Single();
        Check(readLine.HasZ && readLine.HasM && readLine.Z.SequenceEqual(new double[] { 10, 20, 30 }) &&
            readLine.M.SequenceEqual(new double[] { 100, 200, 300 }),
            "The true retained Shapefile reader preserves exact source Z and M ordinates.");
        Check(ShapefileIO.TryRead(polygonPath, out PolygonCollectionFeatureCollection polygons).Result &&
            polygons.Count == 1 && (string?)polygons.AttributeTable.Rows[0][0] == "湿地",
            "The persisted polygon source retains its source reader count and DBF attributes.");

        foreach ((string path, byte[] bytes) in beforeFiles)
            Check(File.ReadAllBytes(path).SequenceEqual(bytes), "Import never rewrites a source Shapefile component.");
        MapSourceIdentity.VerifyFamily(pointFamily);
        MapSourceIdentity.VerifyFamily(lineFamily);
        MapSourceIdentity.VerifyFamily(polygonFamily);
        Check(File.ReadAllBytes(projectPath).SequenceEqual(projectBytes),
            "Adding map-tree references leaves the project XML source untouched.");

        byte[] beforeDuplicate = File.ReadAllBytes(visualizationPath);
        Expect<ArgumentException>(() => MapTreeService.ImportShapefileVector(new(
            MapRequest(projectPath, projectXml, polygonImport), pointPath, projectRevision, pointFamily)),
            "The same physical Shapefile cannot be added twice to one map.");
        Check(File.ReadAllBytes(visualizationPath).SequenceEqual(beforeDuplicate),
            "A duplicate source request does not rewrite the map visualization.");

        string unreadablePath = Path.Combine(root, "unreadable.shp");
        Check(ShapefileIO.Write(unreadablePath, new List<Point> { new(7, 8) }).Result,
            "Actual retained writer creates a typed-reader failure fixture.");
        File.WriteAllBytes(ShapefileIO.DBFFilename(unreadablePath), []);
        MapSourceFamilyCapture unreadableFamily = MapTreeService.CaptureShapefileFamily(unreadablePath);
        byte[] beforeReaderFailure = File.ReadAllBytes(visualizationPath);
        Expect<InvalidDataException>(() => MapTreeService.ImportShapefileVector(new(
            MapRequest(projectPath, projectXml, polygonImport), unreadablePath, projectRevision, unreadableFamily)),
            "A real typed-reader failure must stop import before adding a map layer.");
        Check(File.ReadAllBytes(visualizationPath).SequenceEqual(beforeReaderFailure),
            "A typed reader failure never publishes a partial Shapefile node.");

        string multipointPath = Path.Combine(root, "multipoint.shp");
        var multipoint = new PointCollection(new Point[] { new(0, 0), new(1, 1) });
        Check(ShapefileIO.Write(multipointPath, (IReadOnlyList<PointCollection>)new List<PointCollection> { multipoint }).Result,
            "Actual retained writer creates a multipoint rejection fixture.");
        Expect<NotSupportedException>(() => MapTreeService.CaptureShapefileFamily(multipointPath),
            "Multipoint files are explicit unsupported inputs rather than coerced point layers.");

        Console.WriteLine("Retained Shapefile capture/import, family guards, typed point/polyline/polygon readers, source Z/M and attribute preservation passed.");
    }

    private static Table OneColumn(string name, string value)
    {
        var table = new Table();
        table.AddColumn(name, typeof(string));
        table.AddNewRow([value]);
        return table;
    }

    private static MapDocumentRequest MapRequest(string projectPath, string projectXml,
        MapDocumentMutationReceipt map)
    {
        string visualizationPath = Path.ChangeExtension(projectPath, ".vis");
        return new(projectPath, projectXml, Hash(Encoding.UTF8.GetBytes(projectXml)), Hash(File.ReadAllBytes(visualizationPath)),
            "Project", MapID: "shapefile-import-test-map", MapIndex: map.MapIndex,
            MapName: map.MapName, MapType: map.MapType);
    }

    private static void CheckFamily(MapSourceFamilyCapture family, string sourcePath, bool projectionExists)
    {
        Check(family.Family == "shapefile" && family.SourcePath == Path.GetFullPath(sourcePath) &&
            family.Files.Length == 4 && family.Files.Single(file => file.Role == "source").Required &&
            family.Files.Single(file => file.Role == "shx").Required &&
            family.Files.Single(file => file.Role == "dbf").Required &&
            family.Files.Single(file => file.Role == "prj") is { Required: false, Exists: var exists } && exists == projectionExists,
            "Capture retains the canonical .shp/.shx/.dbf members plus explicit optional .prj presence.");
        MapSourceIdentity.VerifyFamily(family);
    }

    private static string Hash(byte[] bytes) => Convert.ToHexString(SHA256.HashData(bytes));
    private static void Check(bool value, string message)
    {
        if (!value) throw new InvalidOperationException(message);
    }

    private static void Expect<T>(Action action, string message) where T : Exception
    {
        try { action(); }
        catch (T) { return; }
        throw new InvalidOperationException("Expected " + typeof(T).Name + ": " + message);
    }
}
