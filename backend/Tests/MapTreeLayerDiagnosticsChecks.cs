using System.Security.Cryptography;
using System.Text;
using System.Xml.Linq;
using Ras.Backend;
using Ras.Layers;
using Utility.Units;

internal static class MapTreeLayerDiagnosticsChecks
{
    internal static void Run()
    {
        using var temporary = new TemporaryDirectory();
        string projectPath = Path.Combine(temporary.FullName, "MapLayerDiagnostics.ras");
        Project project = Project.CreateNew(projectPath, UnitSystem.SI);
        project.Save();
        Dispose(project);

        string projectXml = File.ReadAllText(projectPath);
        string projectXmlSHA = Hash(Encoding.UTF8.GetBytes(projectXml));
        MapDocumentMutationReceipt created = MapTreeService.CreateMap(new MapDocumentRequest(
            projectPath, projectXml, projectXmlSHA, null, "Project"));
        string visualizationPath = Path.ChangeExtension(projectPath, ".vis");
        string mixedPath = Path.Combine(temporary.FullName, "mixed.geojson");
        string brokenPath = Path.Combine(temporary.FullName, "broken.geojson");
        string missingPath = Path.Combine(temporary.FullName, "missing.geojson");
        string mixedJSON = """
            {"type":"FeatureCollection","features":[
              {"type":"Feature","properties":{"source":"point"},"geometry":{"type":"Point","coordinates":[1,2]}},
              {"type":"Feature","properties":{"source":"line"},"geometry":{"type":"LineString","coordinates":[[0,0],[2,2]]}},
              {"type":"Feature","properties":{"source":"polygon"},"geometry":{"type":"Polygon","coordinates":[[[0,0],[2,0],[2,2],[0,2],[0,0]]]}}
            ]}
            """;
        File.WriteAllText(mixedPath, mixedJSON);
        File.WriteAllText(brokenPath, "{not a GeoJSON feature collection");
        byte[] mixedBefore = File.ReadAllBytes(mixedPath);
        byte[] brokenBefore = File.ReadAllBytes(brokenPath);

        XDocument visualization = XDocument.Load(visualizationPath, LoadOptions.PreserveWhitespace);
        XElement map = visualization.Root!.Element("Maps")!.Elements("Map").ElementAt(created.MapIndex);
        map.Add(new XElement("Tree", new XElement("Nodes",
            new XElement("Node", new XAttribute("Type", "Root"), new XAttribute("Name", "Map Layers"),
                Layer("Mixed Points", "PointsVector", "mixed.geojson"),
                Layer("Mixed Lines", "PolylinesVector", "mixed.geojson"),
                Layer("Mixed Polygons", "PolygonsVector", "mixed.geojson"),
                Layer("Broken Polygon", "PolygonsVector", "broken.geojson"),
                Layer("Missing Points", "PointsVector", "missing.geojson"),
                Layer("Unsupported", "UnknownVectorKind", "mixed.geojson")))));
        visualization.Save(visualizationPath, SaveOptions.DisableFormatting);

        string visualizationRevision = Hash(File.ReadAllBytes(visualizationPath));
        var request = new MapTreeRequest(projectPath, projectXml, projectXmlSHA,
            "map-layer-diagnostics", created.MapIndex, created.MapName, created.MapType,
            visualizationRevision);
        CatalogTreeNode root = MapTreeService.Load(request).Roots.Single(node => node.Name == "Map Layers");
        CatalogTreeNode[] layerNodes = root.Children ?? throw new InvalidOperationException("Map Layers has no children.");
        CatalogTreeNode point = layerNodes.Single(node => node.Name == "Mixed Points");
        CatalogTreeNode line = layerNodes.Single(node => node.Name == "Mixed Lines");
        CatalogTreeNode polygon = layerNodes.Single(node => node.Name == "Mixed Polygons");
        Check(point.SourceClass == "PointMapLayerVisualContext" && line.SourceClass == "PolylineMapLayerVisualContext" &&
              polygon.SourceClass == "PolygonMapLayerVisualContext",
            "The retained map type selects the corresponding typed vector reader for a mixed GeoJSON source.");
        foreach (CatalogTreeNode loaded in new[] { point, line, polygon })
        {
            Check(loaded.DiagnosticStatus == "loaded" && loaded.LayerErrors is not null &&
                  loaded.DiagnosticSourceIdentity is { } sourceIdentity &&
                  PathEquals(sourceIdentity, mixedPath) &&
                  loaded.AssetID is { } assetID && PathEquals(assetID, mixedPath) &&
                  loaded.Checked == "checked" && loaded.Locator is { RootName: "Map Layers", NodeType: "MapLayer", NodePath: { Length: 2 } } &&
                  string.Equals(loaded.DiagnosticSourceRevision, Hash(mixedBefore), StringComparison.OrdinalIgnoreCase),
                "A successfully read vector map layer carries diagnostics without changing its source path, check state or locator.");
        }

        CatalogTreeNode broken = layerNodes.Single(node => node.Name == "Broken Polygon");
        Check(broken.DiagnosticStatus == "readFailed" && broken.LayerErrors is { Length: > 0 } errors &&
              errors.Any(error => error.Code == "GeoJsonReader_FailedToRead") &&
              broken.DiagnosticReadError is { Length: > 0 } readError &&
              readError.Contains("Failed to read GeoJSON", StringComparison.Ordinal),
            "Malformed existing GeoJSON exposes the retained reader's actual failure messages.");

        CatalogTreeNode missing = layerNodes.Single(node => node.Name == "Missing Points");
        CatalogTreeNode unsupported = layerNodes.Single(node => node.Name == "Unsupported");
        Check(missing.AssetID is null && missing.Checked is null && missing.DiagnosticStatus is null &&
              missing.LayerErrors is null && unsupported.AssetID is { } unsupportedAsset &&
              PathEquals(unsupportedAsset, mixedPath) && unsupported.Checked is null &&
              unsupported.DiagnosticStatus is null && unsupported.LayerErrors is null,
            "Missing and unsupported source rows retain the existing unavailable semantics without invented diagnostics.");

        Check(mixedBefore.SequenceEqual(File.ReadAllBytes(mixedPath)) &&
              brokenBefore.SequenceEqual(File.ReadAllBytes(brokenPath)),
            "Map-layer diagnostic reads leave source files byte-for-byte unchanged.");
    }

    private static XElement Layer(string name, string mapType, string filename) =>
        new("Node", new XAttribute("Type", "MapLayer"), new XAttribute("MapType", mapType),
            new XAttribute("Name", name), new XAttribute("FilenameRelative", filename),
            new XAttribute("IsChecked", true));

    private static void Dispose(Project project)
    {
        foreach (CoreLayerBase layer in project.Plans.Cast<CoreLayerBase>().Concat(project.Geometries)
            .Concat(project.Terrains).Concat(project.BoundaryConditions).Concat(project.NValues)
            .Concat(project.ClassificationLayers)) layer.Dispose();
        foreach (Result result in project.Results) result.Dispose();
    }

    private static string Hash(byte[] bytes) => Convert.ToHexString(SHA256.HashData(bytes));

    private static bool PathEquals(string first, string second) =>
        string.Equals(Path.GetFullPath(first), Path.GetFullPath(second), OperatingSystem.IsWindows()
            ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal);

    private static void Check(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }
}
