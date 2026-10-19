using System.Security.Cryptography;
using System.Text;
using Geospatial.Features;
using Geospatial.IO;
using Geospatial.Vectors;
using Ras.Backend;
using Ras.Layers;
using Utility.Memory;
using Utility.Units;

internal static class VectorMapPlotRenderingChecks
{
    private const string MapID = "e2028ce0-ef3a-4e46-9f72-4d940ecc2038";

    internal static void Run()
    {
        using var temporary = new TemporaryDirectory();
        string root = temporary.Path;
        string projectPath = Path.Combine(root, "vector-plot.ras");
        DisposeProject(Project.CreateNew(projectPath, ProjectionDefinition.Local(UnitSystem.SI)));
        string projectXml = File.ReadAllText(projectPath, Encoding.UTF8);
        string projectXmlSHA = Hash(Encoding.UTF8.GetBytes(projectXml));
        MapDocumentMutationReceipt created = MapTreeService.CreateMap(new MapDocumentRequest(
            projectPath, projectXml, projectXmlSHA, null, "Project", Name: "Plot fixture", MapID: MapID));

        string sourcePath = Path.Combine(root, "plot-line.shp");
        var sourceLine = new Polyline(new Point[] { new(0, 0), new(10, 6), new(20, 0) });
        sourceLine.TrackZ([1, 2, 3]);
        var attributes = new Table();
        attributes.AddColumn("Label", typeof(string));
        attributes.AddNewRow(["source row"]);
        Check(ShapefileIO.Write(sourcePath, new List<Polyline> { sourceLine }, attributes).Result,
            "The retained writer creates a real source polyline with Z and typed DBF data.");
        MapSourceFamilyCapture family = MapTreeService.CaptureShapefileFamily(sourcePath);
        string sourceRevision = family.Files.Single(file => file.Role == "source").Revision
            ?? throw new InvalidOperationException("The captured shapefile has no source revision.");

        string projectRevision = Hash(File.ReadAllBytes(projectPath));
        MapDocumentMutationReceipt imported = MapTreeService.ImportShapefileVector(new(
            MapDocumentRequestFor(projectPath, projectXml, created), sourcePath, projectRevision, family));
        MapTreeRequest map = MapTreeRequestFor(projectPath, projectXml, imported);
        CatalogTreeNode node = FindLineLayer(MapTreeService.Load(map).Roots);
        CatalogTreeNodeLocator locator = node.Locator
            ?? throw new InvalidOperationException("The persisted vector source has no exact map-tree locator.");
        string visualizationPath = Path.ChangeExtension(projectPath, ".vis");
        string visualizationRevision = Hash(File.ReadAllBytes(visualizationPath));
        Dictionary<string, string> sourceFileRevisions = family.Files.Where(file => file.Exists)
            .ToDictionary(file => file.Path, file => Hash(File.ReadAllBytes(file.Path)), StringComparer.Ordinal);

        var inspect = new MapVectorPlotOptionsRequest(map, locator, node.Id, family, sourceRevision);
        MapVectorPlotOptionsResponse options = VectorMapPlotRenderingService.InspectOptions(inspect);
        MapVectorPlotOptionDescriptor strokeVertices = options.PlotOptions.Single(option =>
            option.PropertyName == "ShowStrokeVertices");
        Check(strokeVertices.Name == "Show Stroke Vertices" && strokeVertices.Kind == "bool" &&
              strokeVertices.Value == "false" && strokeVertices.IsEnabled,
            "The source PlotOption display name remains distinct from its property-name request key.");
        Expect<ArgumentException>(() => VectorMapPlotRenderingService.InspectOptions(inspect with
        {
            PlotOptions = new Dictionary<string, string>(StringComparer.Ordinal)
            {
                [strokeVertices.Name] = "true"
            }
        }), "A display label is not accepted in place of the exact source property name.");

        RasterMapViewExtent viewport = new(-1, -5, 21, 11, 256, 160);
        MapVectorPlotStyleValues lineStyle = new("#FF202020", 2.5, "#00000000", 3,
            "#FFFFFFFF", 0, 0);
        MapVectorPlotStyleValues vertexStyle = new("#FF202020", 1.0, "#FFFFFFFF", 9,
            "#FFFFFFFF", 0, 0);
        MapVectorPlotStyle[] styles =
        [
            new("Polyline_Line_Symbology", lineStyle, []),
            new("Polyline_Vertex_Symbology", vertexStyle, [])
        ];
        MapVectorPlotRenderResponse withoutVertices = VectorMapPlotRenderingService.Render(new(
            map, locator, node.Id, family, sourceRevision, viewport,
            new Dictionary<string, string>(StringComparer.Ordinal) { ["ShowStrokeVertices"] = "false" },
            styles, RenderScale: 1));
        MapVectorPlotRenderResponse withVertices = VectorMapPlotRenderingService.Render(new(
            map, locator, node.Id, family, sourceRevision, viewport,
            new Dictionary<string, string>(StringComparer.Ordinal) { ["ShowStrokeVertices"] = "true" },
            styles, RenderScale: 1));
        Check(withoutVertices.Rgba.Length == viewport.PixelWidth * viewport.PixelHeight * 4 &&
              withVertices.Rgba.Length == withoutVertices.Rgba.Length &&
              !withVertices.Rgba.SequenceEqual(withoutVertices.Rgba),
            "The accepted source property changes the actual retained renderer's pixel frame.");

        MapVectorPlotRenderResponse scaled = VectorMapPlotRenderingService.Render(new(
            map, locator, node.Id, family, sourceRevision, viewport,
            new Dictionary<string, string>(StringComparer.Ordinal), styles, RenderScale: 3));
        Check(withoutVertices.RenderScale == 1 && scaled.RenderScale == 3 &&
              !scaled.Rgba.SequenceEqual(withoutVertices.Rgba),
            "The response identifies the exact pen/point scale and the source renderer uses it in its output.");
        Check(Hash(File.ReadAllBytes(visualizationPath)) == visualizationRevision &&
              sourceFileRevisions.All(pair => Hash(File.ReadAllBytes(pair.Key)) == pair.Value) &&
              Hash(File.ReadAllBytes(projectPath)) == projectRevision,
            "Inspection and source CPU rendering leave the project, .vis and complete Shapefile family byte-for-byte unchanged.");

        byte[] sourceBytes = File.ReadAllBytes(sourcePath);
        try
        {
            File.WriteAllBytes(sourcePath, sourceBytes.Concat(new byte[] { 0x01 }).ToArray());
            Expect<SourceFileChangedException>(() => VectorMapPlotRenderingService.InspectOptions(inspect),
                "An exact source-family capture rejects a changed shapefile before returning renderer metadata.");
        }
        finally
        {
            File.WriteAllBytes(sourcePath, sourceBytes);
        }

        Check(Hash(File.ReadAllBytes(visualizationPath)) == visualizationRevision,
            "A stale-source rejection does not alter the persisted visualization document.");
        Console.WriteLine("Vector map plot checks cover real source PlotOption property keys, actual stroke-vertex output, render scaling, stale-family rejection and unchanged project/source bytes.");
    }

    private static MapDocumentRequest MapDocumentRequestFor(string projectPath, string projectXml,
        MapDocumentMutationReceipt map)
    {
        string visualizationPath = Path.ChangeExtension(projectPath, ".vis");
        return new(projectPath, projectXml, Hash(Encoding.UTF8.GetBytes(projectXml)),
            Hash(File.ReadAllBytes(visualizationPath)), "Project", MapID: MapID,
            MapIndex: map.MapIndex, MapName: map.MapName, MapType: map.MapType);
    }

    private static MapTreeRequest MapTreeRequestFor(string projectPath, string projectXml,
        MapDocumentMutationReceipt map) => new(projectPath, projectXml,
        Hash(Encoding.UTF8.GetBytes(projectXml)), MapID, map.MapIndex, map.MapName,
        map.MapType, Hash(File.ReadAllBytes(Path.ChangeExtension(projectPath, ".vis"))));

    private static CatalogTreeNode FindLineLayer(IEnumerable<CatalogTreeNode> nodes)
    {
        CatalogTreeNode[] matches = nodes.SelectMany(Flatten).Where(node =>
            node.Locator is { NodeType: "MapLayer", MapType: "PolylinesVector" }).ToArray();
        return matches.Length == 1 ? matches[0]
            : throw new InvalidOperationException($"Expected exactly one persisted polyline layer, found {matches.Length}.");
    }

    private static IEnumerable<CatalogTreeNode> Flatten(CatalogTreeNode node)
    {
        yield return node;
        if (node.Children is null) yield break;
        foreach (CatalogTreeNode child in node.Children)
            foreach (CatalogTreeNode descendant in Flatten(child)) yield return descendant;
    }

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

    private static void Expect<TException>(Action action, string message) where TException : Exception
    {
        try { action(); }
        catch (TException) { return; }
        throw new InvalidOperationException("Expected " + typeof(TException).Name + ": " + message);
    }

    private sealed class TemporaryDirectory : IDisposable
    {
        public string Path { get; } = System.IO.Path.Combine(System.IO.Path.GetTempPath(),
            "HECRAS-VectorPlot-" + Guid.NewGuid().ToString("N"));
        public TemporaryDirectory() => Directory.CreateDirectory(Path);
        public void Dispose()
        {
            if (Directory.Exists(Path)) Directory.Delete(Path, recursive: true);
        }
    }
}
