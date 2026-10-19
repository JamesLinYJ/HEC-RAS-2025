using System.Security.Cryptography;
using System.Text;
using System.Xml.Linq;
using Ras.Backend;

internal static class MapSourceIdentityChecks
{
    internal static void Run()
    {
        using var temporary = new TemporaryDirectory();
        FamilyCapturesReportedAndOptionalDependencies(temporary.FullName);
        PersistedMapNodeIsBoundToExactSourceAndOwner(temporary.FullName);
        UnpersistedDefaultProjectCaptureDoesNotInventAMap(temporary.FullName);
    }

    private static void FamilyCapturesReportedAndOptionalDependencies(string root)
    {
        string rasterDirectory = Path.Combine(root, "raster family");
        Directory.CreateDirectory(rasterDirectory);
        string raster = Path.Combine(rasterDirectory, "terrain.tif");
        string auxiliary = Path.Combine(rasterDirectory, "terrain.aux.xml");
        File.WriteAllBytes(raster, [1, 2, 3, 4]);
        File.WriteAllText(auxiliary, "<PAMDataset />", Encoding.UTF8);

        MapSourceFamilyCapture rasterCapture = MapSourceIdentity.CaptureFamily("raster", raster,
        [
            new(raster, "gdal-file-list"),
            new(auxiliary, "gdal-file-list")
        ]);
        Check(rasterCapture.Files.Length == 2 &&
            rasterCapture.Files.Count(file => file.Role == "source") == 1,
            "The primary source reported by GDAL is represented once in the captured family.");
        MapSourceIdentity.VerifyFamily(rasterCapture);

        string vectorDirectory = Path.Combine(root, "shapefile family");
        Directory.CreateDirectory(vectorDirectory);
        string shape = Path.Combine(vectorDirectory, "network.shp");
        string index = Path.Combine(vectorDirectory, "network.shx");
        string attributes = Path.Combine(vectorDirectory, "network.dbf");
        string projection = Path.Combine(vectorDirectory, "network.prj");
        File.WriteAllBytes(shape, [10, 11]);
        File.WriteAllBytes(index, [12, 13]);
        File.WriteAllBytes(attributes, [14, 15]);

        MapSourceFamilyCapture shapeCapture = MapSourceIdentity.CaptureFamily("shapefile", shape,
        [
            new(index, "shx"),
            new(attributes, "dbf"),
            new(projection, "prj", Required: false)
        ]);
        MapSourceIdentity.VerifyFamily(shapeCapture);
        Check(shapeCapture.Files.Length == 4 &&
            shapeCapture.Files.Single(file => file.Role == "prj") is { Required: false, Exists: false, Revision: null },
            "An absent optional projection sidecar remains an explicit part of the source family.");

        File.WriteAllText(projection, "projection definition", Encoding.UTF8);
        Expect<SourceFileChangedException>(() => MapSourceIdentity.VerifyFamily(shapeCapture),
            "An optional consumed sidecar appearing after capture invalidates the family.");

        MapSourceFamilyCapture refreshed = MapSourceIdentity.CaptureFamily("shapefile", shape,
        [
            new(index, "shx"),
            new(attributes, "dbf"),
            new(projection, "prj", Required: false)
        ]);
        File.Delete(projection);
        Expect<SourceFileChangedException>(() => MapSourceIdentity.VerifyFamily(refreshed),
            "A consumed optional projection sidecar disappearing invalidates the family.");
        File.WriteAllText(projection, "projection definition", Encoding.UTF8);
        File.WriteAllBytes(attributes, [14, 15, 16]);
        Expect<SourceFileChangedException>(() => MapSourceIdentity.VerifyFamily(refreshed),
            "Changing one required Shapefile component invalidates the entire consumed family.");
    }

    private static void PersistedMapNodeIsBoundToExactSourceAndOwner(string root)
    {
        string directory = Path.Combine(root, "persisted map");
        Directory.CreateDirectory(directory);
        string projectPath = Path.Combine(directory, "project.ras");
        string projectXml = "<Project />";
        File.WriteAllText(projectPath, projectXml, new UTF8Encoding(encoderShouldEmitUTF8Identifier: false));
        byte[] originalProjectBytes = File.ReadAllBytes(projectPath);
        string projectXmlSHA = Hash(Encoding.UTF8.GetBytes(projectXml));
        string sourcePath = Path.Combine(directory, "reference.dat");
        File.WriteAllBytes(sourcePath, [21, 22, 23]);

        MapDocumentMutationReceipt created = MapTreeService.CreateMap(new MapDocumentRequest(
            projectPath, projectXml, projectXmlSHA, null, "Project", Name: "Project map"));
        string visualizationPath = Path.ChangeExtension(projectPath, ".vis");
        XDocument visualization = XDocument.Load(visualizationPath, LoadOptions.PreserveWhitespace);
        XElement mapElement = visualization.Root!.Element("Maps")!.Elements("Map").Single();
        string relativePath = Path.GetRelativePath(directory, sourcePath);
        mapElement.Add(new XElement("Tree",
            new XElement("Nodes",
                new XElement("Node",
                    new XAttribute("Type", "Root"),
                    new XAttribute("Name", "Layers"),
                    new XElement("Node",
                        new XAttribute("Type", "MapLayer"),
                        new XAttribute("Name", "reference"),
                        new XAttribute("MapType", "SingleBandRasterMapLayer"),
                        new XAttribute("Filename", sourcePath),
                        new XAttribute("FilenameRelative", relativePath),
                        new XAttribute("IsChecked", true))))));
        visualization.Save(visualizationPath, SaveOptions.DisableFormatting);
        byte[] capturedVisualizationBytes = File.ReadAllBytes(visualizationPath);

        var mapRequest = new MapTreeRequest(projectPath, projectXml, projectXmlSHA,
            "map-owner-1", created.MapIndex, created.MapName, created.MapType, Hash(capturedVisualizationBytes));
        var locator = new CatalogTreeNodeLocator("Layers", "MapLayer", "reference", [0, 0],
            MapType: "SingleBandRasterMapLayer",
            Filename: sourcePath,
            FilenameRelative: relativePath);
        MapSourceNodeLocation location = MapSourceIdentity.ResolvePersistedNode(mapRequest, locator);
        MapSourceFamilyCapture family = MapSourceIdentity.CaptureFamily("raster", location.SourcePath, []);
        MapSourceNodeCapture capture = MapSourceIdentity.ResolvePersistedNode(mapRequest, locator, family);
        MapSourceIdentity.VerifyPersistedNode(mapRequest, capture);
        MapSourceIdentity.VerifyMap(mapRequest, capture.Map);
        Check(capture.Map.IsPersisted && capture.Map.MapIndex == created.MapIndex &&
            capture.Map.MapName == created.MapName && capture.Map.MapType == "Project" &&
            PathEquals(capture.Family.SourcePath, sourcePath),
            "The source family is bound to the exact saved map row and canonical file path.");

        Expect<SourceFileChangedException>(() => MapSourceIdentity.VerifyMap(
            mapRequest with { MapID = "different-map-owner" }, capture.Map),
            "A map capture cannot be reused for another map selection identity.");
        Expect<SourceFileChangedException>(() => MapSourceIdentity.ResolvePersistedNode(
            mapRequest, locator with { NodeName = "same-file-different-node" }),
            "A matching filename elsewhere does not substitute for the exact persisted tree row.");

        Expect<SourceFileChangedException>(() => MapSourceIdentity.VerifyMap(mapRequest with
        {
            ProjectXml = "<Project Changed=\"true\" />",
            ProjectXmlSHA = Hash(Encoding.UTF8.GetBytes("<Project Changed=\"true\" />"))
        }, capture.Map), "A different current project XML draft cannot reuse the capture.");

        File.WriteAllText(projectPath, "<Project Updated=\"true\" />",
            new UTF8Encoding(encoderShouldEmitUTF8Identifier: false));
        Expect<SourceFileChangedException>(() => MapSourceIdentity.VerifyMap(mapRequest, capture.Map),
            "An external project-file change invalidates the exact map capture.");
        File.WriteAllBytes(projectPath, originalProjectBytes);

        XDocument changedVisualization = XDocument.Load(visualizationPath, LoadOptions.PreserveWhitespace);
        changedVisualization.Descendants("Node").Single(node =>
            (string?)node.Attribute("Type") == "MapLayer").SetAttributeValue("Name", "renamed-source");
        changedVisualization.Save(visualizationPath, SaveOptions.DisableFormatting);
        Expect<SourceFileChangedException>(() => MapSourceIdentity.VerifyMap(mapRequest, capture.Map),
            "A changed visualization revision invalidates the exact map capture.");
        File.WriteAllBytes(visualizationPath, capturedVisualizationBytes);

        File.WriteAllBytes(sourcePath, [21, 22, 24]);
        Expect<SourceFileChangedException>(() => MapSourceIdentity.VerifyPersistedNode(mapRequest, capture),
            "The exact tree row is rejected after its source family changes.");
    }

    private static void UnpersistedDefaultProjectCaptureDoesNotInventAMap(string root)
    {
        string directory = Path.Combine(root, "unpersisted map");
        Directory.CreateDirectory(directory);
        string projectPath = Path.Combine(directory, "default.ras");
        string projectXml = "<Project />";
        File.WriteAllText(projectPath, projectXml, new UTF8Encoding(encoderShouldEmitUTF8Identifier: false));
        var request = new MapDocumentRequest(projectPath, projectXml,
            Hash(Encoding.UTF8.GetBytes(projectXml)), null, "Project", MapID: "default-project-context");

        MapSourceMapCapture capture = MapSourceIdentity.CaptureMap(request);
        Check(!capture.IsPersisted && capture.MapIndex is null && capture.MapName is null &&
            capture.MapID == "default-project-context" && capture.VisualizationRevision is null,
            "The default Project map is represented as an unpersisted owner without a fabricated saved identity.");
        MapSourceIdentity.VerifyMap(request, capture);

        MapTreeService.CreateMap(request with { Name = "First saved map" });
        Expect<SourceFileChangedException>(() => MapSourceIdentity.VerifyMap(request, capture),
            "Creating the first saved map invalidates the unpersisted default-map capture.");

        var invalidUnpersisted = request with { Kind = "Buildable" };
        Expect<ArgumentException>(() => MapSourceIdentity.CaptureMap(invalidUnpersisted),
            "An unpersisted Buildable map cannot borrow the default Project-map identity.");
    }

    private static string Hash(byte[] bytes) => Convert.ToHexString(SHA256.HashData(bytes));

    private static bool PathEquals(string left, string right) =>
        MapSourceTestPaths.SameFile(left, right);

    private static void Check(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }

    private static void Expect<TException>(Action action, string message) where TException : Exception
    {
        try
        {
            action();
        }
        catch (TException)
        {
            return;
        }
        throw new InvalidOperationException(message);
    }

    private sealed class TemporaryDirectory : IDisposable
    {
        public TemporaryDirectory()
        {
            FullName = Path.Combine(Path.GetTempPath(), "ras-map-source-identity-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(FullName);
        }

        public string FullName { get; }

        public void Dispose()
        {
            if (Directory.Exists(FullName)) Directory.Delete(FullName, recursive: true);
        }
    }
}
