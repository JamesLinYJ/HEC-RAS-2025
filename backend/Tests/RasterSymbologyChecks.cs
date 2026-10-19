using System.Security.Cryptography;
using System.Text;
using System.Xml.Linq;
using OSGeo.GDAL;
using Ras.Backend;

internal static class RasterSymbologyChecks
{
    public static void Run()
    {
        using var temporary = new TemporaryDirectory();
        string projectPath = Path.Combine(temporary.FullName, "Map.ras");
        string visualizationPath = Path.ChangeExtension(projectPath, ".vis");
        string rasterPath = Path.Combine(temporary.FullName, "elevation.tif");
        string unrelatedRasterPath = Path.Combine(temporary.FullName, "unrelated.tif");
        CreateRaster(rasterPath, 10);
        CreateRaster(unrelatedRasterPath, 12);
        Ras.Layers.Project.CreateNew(projectPath, Utility.Units.UnitSystem.SI).Save();
        byte[] originalVisualization = Encoding.UTF8.GetBytes(VisualizationXml());
        File.WriteAllBytes(visualizationPath, originalVisualization);
        ExportFixtureIfRequested(temporary.FullName);
        string revision = Hash(originalVisualization);
        string sourceMapID = Guid.NewGuid().ToString();
        var source = Source(projectPath, visualizationPath, rasterPath, revision, sourceMapID);

        RejectArgument(() => RasterSymbologyService.Histogram(new(
            source with { SourcePath = unrelatedRasterPath }, "<Project/>", null, 2, false)),
            "An arbitrary raster path was accepted for a visualization node.");

        var inspected = RasterSymbologyService.Inspect(new(source, "<Project/>"));
        Check(inspected.Snapshot.SurfaceFillValues is { Length: 2 } values && values.SequenceEqual(new[] { 0d, 20d }),
            "Inspection reads the actual .vis color ramp");
        Check(inspected.Raster.SourceMapID == sourceMapID && inspected.Raster.Width > 0 && inspected.Raster.Height > 0 &&
              inspected.Raster.Rgba.Length == inspected.Raster.Width * inspected.Raster.Height * 4,
            "Inspection produces a source-map-scoped RGBA image from the actual GDAL raster");
        Check(inspected.Raster.Rgba.Where((_, index) => index % 4 == 3).Any(alpha => alpha > 0) &&
              inspected.Raster.Rgba.Where((_, index) => index % 4 == 0).Any(red => red is > 90 and < 180) &&
              inspected.Raster.Rgba.Where((_, index) => index % 4 == 2).Any(blue => blue is > 90 and < 180),
            "Actual GDAL pixels pass through the stored red-to-blue surface-fill ramp");

        var edited = Draft("Applied ramp", "00FF00FF", "FFFFFFFF");
        var applied = RasterSymbologyService.Apply(new(source, "<Project/>", edited));
        Check(applied.PreviousVisualizationRevision == revision && applied.VisualizationRevision != revision &&
              applied.SourceRevision == inspected.SourceRevision,
            "Apply reports the expected .vis transition and unchanged source raster revision");
        Check(applied.Raster.Rgba.Where((_, index) => index % 4 == 1).Any(green => green > 0),
            "Apply renders the requested color ramp from actual raster values");
        var savedXml = XDocument.Load(visualizationPath);
        var storedFill = savedXml.Root!.Element("Maps")!.Element("Map")!.Element("Tree")!
            .Element("Nodes")!.Element("Node")!.Element("RasterSymbology")!.Element("SurfaceFill")!;
        Check(storedFill.Attribute("Name")?.Value == "Applied ramp" &&
              storedFill.Elements("Color").Select(color => (string?)color.Attribute("Value")).SequenceEqual(["0", "20"]),
            "Apply persists the named surface fill and its manually edited values in the exact .vis node");

        var currentSource = source with { VisualizationRevision = applied.VisualizationRevision };
        var savedPalette = RasterSymbologyService.SavePalette(new(currentSource, "<Project/>", edited, "Custom ramp"));
        Check(savedPalette.Palettes.Any(palette => palette.Id == "custom:Custom ramp" && palette.IsCustom),
            "Saving a custom palette persists it in the current .vis Symbology catalog");
        var deleted = RasterSymbologyService.DeletePalette(new(
            currentSource with { VisualizationRevision = savedPalette.VisualizationRevision }, "<Project/>", "custom:Custom ramp"));
        Check(deleted.Palettes.All(palette => palette.Id != "custom:Custom ramp"),
            "Deleting a custom palette updates the same .vis catalog");

        byte[] beforeStaleApply = File.ReadAllBytes(visualizationPath);
        var staleSource = currentSource with
        {
            VisualizationRevision = deleted.VisualizationRevision,
            SourceRevision = Hash(Encoding.UTF8.GetBytes("stale source baseline"))
        };
        try
        {
            RasterSymbologyService.Apply(new(staleSource, "<Project/>", Draft("Must not write", "FF0000FF", "0000FFFF")));
            throw new InvalidOperationException("A stale source raster hash was accepted.");
        }
        catch (SourceFileChangedException) { }
        Check(File.ReadAllBytes(visualizationPath).SequenceEqual(beforeStaleApply),
            "A stale raster-source revision is rejected without changing the .vis file");
        Console.WriteLine("Current .vis raster identity, actual GDAL rendering, source revision guards, apply and custom palette persistence passed.");
    }

    private static RasterMapSourceIdentity Source(string projectPath, string visualizationPath, string rasterPath,
        string visualizationRevision, string sourceMapID) => new(
            "vis-map-0-node-0", projectPath, visualizationPath, visualizationRevision,
            0, "Map", "Project", [0], "Elevation", "SingleBandRasterMapLayer",
            "unused.tif", "elevation.tif", rasterPath, sourceMapID);

    private static RasterSymbologyDraftContract Draft(string name, string first, string second) => new(
        null, name,
        [new(Guid.NewGuid(), first, 0), new(Guid.NewGuid(), second, 20)],
        "Manual", false, true, false, true);

    private static void CreateRaster(string path, float value)
    {
        using var driver = Gdal.GetDriverByName("GTiff");
        using var dataset = driver.Create(path, 8, 8, 1, DataType.GDT_Float32,
            ["TILED=YES", "BLOCKXSIZE=16", "BLOCKYSIZE=16"]);
        dataset.SetGeoTransform([0, 1, 0, 8, 0, -1]);
        using var band = dataset.GetRasterBand(1);
        band.Fill(value, 0);
    }

    private static string VisualizationXml() => """
        <Ras><Maps><Map Name="Map" Type="Project"><Tree><Nodes>
        <Node Type="MapLayer" MapType="SingleBandRasterMapLayer" Name="Elevation" Filename="unused.tif" FilenameRelative="elevation.tif">
          <RasterSymbology ValueSource="Manual" IsSurfaceFillEnabled="true" Alpha="255">
            <SurfaceFill Name="Source ramp"><Color R="255" G="0" B="0" Value="0"/><Color R="0" G="0" B="255" Value="20"/></SurfaceFill>
          </RasterSymbology>
        </Node></Nodes></Tree></Map></Maps><Symbology/></Ras>
        """;

    private static string Hash(byte[] bytes) => Convert.ToHexString(SHA256.HashData(bytes));

    private static void ExportFixtureIfRequested(string sourceDirectory)
    {
        string? fixture = Environment.GetEnvironmentVariable("HECRAS_RASTER_SYMBOLOGY_ACCEPTANCE_DIRECTORY");
        if (string.IsNullOrWhiteSpace(fixture)) return;
        string destination = Path.GetFullPath(fixture);
        if (Directory.Exists(destination) || File.Exists(destination))
            throw new IOException("The raster symbology fixture destination already exists.");
        Directory.CreateDirectory(destination);
        foreach (string folder in Directory.EnumerateDirectories(sourceDirectory, "*", SearchOption.AllDirectories))
            Directory.CreateDirectory(Path.Combine(destination, Path.GetRelativePath(sourceDirectory, folder)));
        foreach (string file in Directory.EnumerateFiles(sourceDirectory, "*", SearchOption.AllDirectories))
            File.Copy(file, Path.Combine(destination, Path.GetRelativePath(sourceDirectory, file)));
    }

    private static void RejectArgument(Action action, string failure)
    {
        try { action(); }
        catch (ArgumentException) { return; }
        throw new InvalidOperationException(failure);
    }

    private static void Check(bool value, string message)
    {
        if (!value) throw new InvalidOperationException(message);
    }
}
