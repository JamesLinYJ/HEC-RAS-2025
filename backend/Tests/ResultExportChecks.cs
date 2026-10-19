using OgrGeometry = OSGeo.OGR.Geometry;
using GdalDriver = OSGeo.GDAL.Driver;
using System.Security.Cryptography;
using System.Text;
using System.Xml.Linq;
using Geospatial.Core.Rasters;
using Geospatial.GDALAssist;
using Geospatial.IO;
using Geospatial.Rasters;
using Geospatial.Vectors;
using Geospatial.Vectors.Meshes;
using OSGeo.GDAL;
using OSGeo.OGR;
using OSGeo.OSR;
using Ras.Backend;
using Ras.Layers;
using Ras.Mapping;
using Ras.Output;
using Ras.Rendering;
using Utility.Logging;

/// <summary>
/// Exercises the actual backend export services against a small GDAL raster
/// and the retained MapResultRenderChecks Result HDF fixture. The Result
/// values are deterministic fixture data, not solver output.
/// </summary>
internal static class ResultExportChecks
{
    internal static async Task Run()
    {
        GDALSetup.InitializeMultiplatform();
        using var temporary = new TemporaryDirectory();
        await CheckRgbRasterExport(temporary.FullName);
        await CheckDepthShapefileExport(temporary.FullName);
        Console.WriteLine("RGB RGBA TIFF and retained Result Depth Shapefile exports passed inspect/preview/execute, source immutability, no-clobber, receipt, CRS and independent GDAL/OGR reopen checks.");
    }

    private static async Task CheckRgbRasterExport(string root)
    {
        await CheckRgbRasterExportCase(root, "projected", ProjectionDefinition.FromEPSG(32650),
            expectedProjection: true).ConfigureAwait(false);
        await CheckRgbRasterExportCase(root, "local", ProjectionDefinition.LocalUSC,
            expectedProjection: false).ConfigureAwait(false);
    }

    private static async Task CheckRgbRasterExportCase(string root, string caseName,
        ProjectionDefinition projectProjection, bool expectedProjection)
    {
        string rasterDirectory = Path.Combine(root, $"rgb-{caseName}-source");
        Directory.CreateDirectory(rasterDirectory);
        string projectPath = Path.Combine(rasterDirectory, "RGB Export.ras");
        _ = Project.CreateNew(projectPath, projectProjection);
        string rasterPath = Path.Combine(rasterDirectory, "source.tif");
        CreateRgbSourceRaster(rasterPath, expectedProjection);
        string projectXml = File.ReadAllText(projectPath, Encoding.UTF8);
        string visualizationPath = Path.ChangeExtension(projectPath, ".vis");
        File.WriteAllText(visualizationPath, RgbVisualizationXml(), new UTF8Encoding(false));

        var source = new RasterMapSourceIdentity(
            "vis-map-0-node-0", projectPath, visualizationPath, HashFile(visualizationPath),
            0, "RGB Export Map", "Project", [0], "Elevation", "SingleBandRasterMapLayer",
            Path.GetFileName(rasterPath), Path.GetFileName(rasterPath), rasterPath,
            Guid.NewGuid().ToString("D"), HashFile(rasterPath));
        Dictionary<string, string> originalBytes = CaptureFiles([projectPath, visualizationPath, rasterPath]);
        var inspectRequest = new RasterRgbExportInspectRequest(source, projectXml, null);
        RasterRgbExportInspection inspection = RasterSymbologyService.InspectRgbExport(inspectRequest);
        Check(inspection.SourceID == source.Id && inspection.SourceRevision == source.SourceRevision &&
              inspection.VisualizationRevision == source.VisualizationRevision &&
              Near(inspection.FullMinX, 500_000) && Near(inspection.FullMinY, 999_992) &&
              Near(inspection.FullMaxX, 500_008) && Near(inspection.FullMaxY, 1_000_000),
            "RGB inspection resolves the exact .vis raster node, current source revisions and source georeference.");

        const double cellSize = 1;
        var previewRequest = new RasterRgbExportPreviewRequest(source, projectXml,
            "FullLayer", cellSize, null);
        RasterRgbExportPreview preview = RasterSymbologyService.PreviewRgbExport(previewRequest);
        Check(preview.SourceID == source.Id && preview.SourceRevision == inspection.SourceRevision &&
              preview.VisualizationRevision == inspection.VisualizationRevision &&
              preview.OutputWidth == 8 && preview.OutputHeight == 8 &&
              preview.Raster.Width > 0 && preview.Raster.Height > 0 &&
              preview.Raster.Rgba.Length == preview.Raster.Width * preview.Raster.Height * 4 &&
              preview.EstimatedFileSizeBytes > 0,
            "RGB preview renders source pixels and reports the selected full-layer export grid.");

        string outputDirectory = Path.Combine(root, $"rgb-{caseName}-output");
        Directory.CreateDirectory(outputDirectory);
        string outputPath = Path.Combine(outputDirectory, $"rgba-{caseName}-export.tif");
        var executeRequest = new RasterRgbExportExecuteRequest(source, projectXml,
            "FullLayer", cellSize, null, outputPath);
        RasterRgbExportExecuteResult result = await RasterSymbologyService.ExportRgbAsync(
            executeRequest, null, null).ConfigureAwait(false);
        Check(result.State == "completed" && result.OutputPath == Path.GetFullPath(outputPath) &&
              result.SourceID == source.Id && result.SourceRevision == inspection.SourceRevision &&
              result.VisualizationRevision == inspection.VisualizationRevision &&
              result.Width == preview.OutputWidth && result.Height == preview.OutputHeight &&
              Near(result.MinX, preview.MinX) && Near(result.MinY, preview.MinY) &&
              Near(result.MaxX, preview.MaxX) && Near(result.MaxY, preview.MaxY),
            "RGB execute publishes the exact inspected source and preview grid.");
        Check(result.Artifacts.Length == 1 && result.Artifacts[0].Path == Path.GetFullPath(outputPath),
            "RGB execute returns one receipt for the published TIFF.");
        CheckReceipt(result.Artifacts[0]);
        VerifyRgbaTiff(outputPath, result, projectPath, expectedProjection);
        Dictionary<string, string> publishedBytes = CaptureFiles([outputPath]);
        await ExpectIOException(async () =>
            await RasterSymbologyService.ExportRgbAsync(executeRequest, null, null).ConfigureAwait(false),
            "RGB execute rejects an existing destination.").ConfigureAwait(false);
        VerifySnapshot(originalBytes, "RGB source");
        VerifySnapshot(publishedBytes, "RGB destination after rejected overwrite");
        Check(!Directory.EnumerateFiles(outputDirectory, ".*.tmp.tif", SearchOption.TopDirectoryOnly).Any(),
            "RGB publication removes its temporary TIFF after success and no-clobber rejection.");
    }

    private static void VerifyRgbaTiff(string path, RasterRgbExportExecuteResult result,
        string projectPath, bool expectedProjection)
    {
        using Dataset dataset = Gdal.Open(path, Access.GA_ReadOnly) ??
            throw new InvalidDataException("GDAL could not reopen the exported RGB TIFF.");
        Check(dataset.RasterXSize == result.Width && dataset.RasterYSize == result.Height &&
              dataset.RasterCount == 4,
            "The reopened TIFF contains the requested grid and four RGBA bands.");
        double[] transform = new double[6];
        dataset.GetGeoTransform(transform);
        Check(Near(transform[0], result.MinX) && Near(transform[3], result.MaxY) &&
              Near(transform[1], result.CellSize) && Near(transform[5], -result.CellSize) &&
              Near(transform[2], 0) && Near(transform[4], 0),
            "The reopened TIFF geotransform matches the reported export extent and cell size.");
        using Band alphaBand = dataset.GetRasterBand(4);
        Check(alphaBand.GetColorInterpretation() == ColorInterp.GCI_AlphaBand,
            "The fourth TIFF band is identified as alpha by GDAL.");
        byte[] alpha = new byte[result.Width * result.Height];
        alphaBand.ReadRaster(0, 0, result.Width, result.Height, alpha,
            result.Width, result.Height, 0, 0);
        Check(alpha.Any(value => value > 0), "The reopened RGBA TIFF contains visible alpha pixels.");
        byte[] red = ReadByteBand(dataset, 1, result.Width, result.Height);
        byte[] green = ReadByteBand(dataset, 2, result.Width, result.Height);
        byte[] blue = ReadByteBand(dataset, 3, result.Width, result.Height);
        Check(red.Concat(green).Concat(blue).Any(value => value > 0),
            "The reopened TIFF contains actual RGB render values.");

        using SpatialReference? actualProjection = dataset.GetSpatialRef();
        using SpatialReference? expectedSpatialReference = ReadProjectProjection(projectPath);
        Check((actualProjection is not null) == expectedProjection &&
              (expectedSpatialReference is not null) == expectedProjection,
            expectedProjection
                ? "The projected RGB TIFF reopens with its current-project CRS."
                : "The LocalUSC RGB TIFF preserves its map grid without inventing a CRS.");
        if (actualProjection is not null && expectedSpatialReference is not null)
            Check(actualProjection.IsSame(expectedSpatialReference, null) == 1,
                "The reopened RGB TIFF projection matches the source project projection.");
        if (!expectedProjection)
            Check(!File.Exists(Path.ChangeExtension(path, ".prj")),
                "The LocalUSC RGB TIFF has no projection sidecar.");
    }

    private static async Task CheckDepthShapefileExport(string root)
    {
        string acceptanceDirectory = RequireMapResultRenderFixture();
        Dictionary<string, string> acceptanceBytes = CaptureDirectory(acceptanceDirectory);
        ContourBounds localBounds = await CheckDepthShapefileExportCase(root, acceptanceDirectory,
            acceptanceBytes, "local", assignProjectedCrs: false).ConfigureAwait(false);
        ContourBounds projectedBounds = await CheckDepthShapefileExportCase(root, acceptanceDirectory,
            acceptanceBytes, "projected", assignProjectedCrs: true).ConfigureAwait(false);
        Check(Near(localBounds.MinX, projectedBounds.MinX) &&
              Near(localBounds.MinY, projectedBounds.MinY) &&
              Near(localBounds.MaxX, projectedBounds.MaxX) &&
              Near(localBounds.MaxY, projectedBounds.MaxY),
            "Assigning the private fixture's CRS metadata does not transform any exported contour coordinates.");
    }

    private static async Task<ContourBounds> CheckDepthShapefileExportCase(string root,
        string acceptanceDirectory, Dictionary<string, string> acceptanceBytes,
        string caseName, bool assignProjectedCrs)
    {
        string privateDirectory = Path.Combine(root, $"map-result-{caseName}-private-copy");
        CopyDirectory(acceptanceDirectory, privateDirectory);
        string[] projects = Directory.EnumerateFiles(privateDirectory, "*.ras", SearchOption.TopDirectoryOnly).ToArray();
        Check(projects.Length == 1,
            "The top-level MapResultRenderChecks acceptance fixture contains exactly one copied project.");
        string projectPath = Path.GetFullPath(projects[0]);
        string visualizationPath = Path.ChangeExtension(projectPath, ".vis");
        Check(File.Exists(visualizationPath),
            "The copied MapResultRenderChecks fixture has its matching visualization file.");
        if (assignProjectedCrs) AssignProjectionToPrivateFixtureCopy(projectPath);
        string projectXml = File.ReadAllText(projectPath, Encoding.UTF8);
        XDocument visualization = XDocument.Load(visualizationPath, LoadOptions.PreserveWhitespace);
        XElement[] maps = visualization.Root?.Element("Maps")?.Elements("Map").ToArray() ?? [];
        Check(maps.Length == 1,
            "The retained Result export fixture has one exact persisted map owner.");
        XElement mapElement = maps[0];
        string mapName = (string?)mapElement.Attribute("Name") ??
            throw new InvalidDataException("The Result fixture map has no persisted name.");
        string mapType = (string?)mapElement.Attribute("Type") ??
            throw new InvalidDataException("The Result fixture map has no persisted type.");
        var map = new MapTreeRequest(projectPath, projectXml,
            Hash(Encoding.UTF8.GetBytes(projectXml)), Guid.NewGuid().ToString("D"),
            0, mapName, mapType, HashFile(visualizationPath));
        Check(map.ComputeReadLease is null,
            "The retained render fixture has no active compute-read lease; the export does not invent one.");

        Dictionary<string, string> privateSourceBytes = CaptureDirectory(privateDirectory);
        MapResultSourcesResult sources = MapResultChartService.Sources(new(map, []));
        Check(sources.MapID == map.MapID && sources.MapIndex == map.MapIndex &&
              sources.MapName == map.MapName && sources.MapType == map.MapType &&
              sources.ContextToken.Length == 64,
            "Result source discovery establishes the exact copied map context token.");
        MapResultActiveNode active = sources.ActiveNodes.Single(node => node.NodeKind == "Result");
        MapResultSelectionState slotZero = active.Selections.Single(slot => slot.SelectionIndex == 0);
        MapResultSourceChoice selected = slotZero.SelectedResult ??
            throw new InvalidDataException("The retained Result fixture has no selected slot-zero source.");
        Check(!selected.IsComputing && IsWithin(privateDirectory, selected.ResultPath) &&
              HashFile(selected.ResultPath).Equals(selected.Revision, StringComparison.OrdinalIgnoreCase),
            "The chosen Result is readable from the private fixture copy and matches its current source revision.");

        var inspectRequest = new DepthShapefileExportInspectRequest(map, [], sources.ContextToken);
        DepthShapefileExportInspection inspection = DepthShapefileExportService.Inspect(inspectRequest);
        DepthShapefileExportOwner owner = inspection.Owners.Single(candidate =>
            SameNode(candidate.Node, active.Node) && candidate.NodeKind == active.NodeKind &&
            candidate.SelectionIndex == 0);
        int profileIndex = active.ProfileIndex ??
            throw new InvalidDataException("The active Result fixture has no serialized profile selection.");
        DepthShapefileExportProfile profile = owner.Profiles.Single(item => item.Index == profileIndex);
        Check(inspection.ContextToken == sources.ContextToken && inspection.MapID == sources.MapID &&
              owner.ResultPath == selected.ResultPath && owner.ResultRevision == selected.Revision &&
              owner.CurrentProfileIndex == profileIndex && profile.Name.Length > 0,
            "Depth inspection retains the exact active Result owner, context token, slot zero, source revision and profile snapshot.");

        var viewport = new RasterMapViewExtent(0, 0, 1, 1, 32, 32);
        const double testCellSize = 0.1;
        var previewRequest = new DepthShapefileExportPreviewRequest(map, [], sources.ContextToken,
            active.Node, 0, selected.ResultPath, selected.Revision, profileIndex,
            viewport, testCellSize, inspection.DefaultSimplifyDistance);
        DepthShapefileExportPreview preview = DepthShapefileExportService.Preview(previewRequest);
        Check(preview.ContextToken == sources.ContextToken && preview.ResultNode == active.Node &&
              preview.SelectionIndex == 0 && preview.ResultPath == selected.ResultPath &&
              preview.ResultRevision == selected.Revision && preview.ProfileIndex == profileIndex &&
              preview.ProfileName == profile.Name && preview.CellSize == testCellSize &&
              preview.Polygons.Length > 0 &&
              preview.ResultRaster is { } resultRaster &&
              resultRaster.SourceMapID == map.MapID && resultRaster.ResultPath == selected.ResultPath &&
              resultRaster.Revision == selected.Revision && resultRaster.ProfileIndex == profileIndex &&
              resultRaster.Rgba.Length == resultRaster.Width * resultRaster.Height * 4,
            "Depth preview runs against the existing Result owner and profile and returns retained result pixels plus generated contour polygons.");

        string outputDirectory = Path.Combine(root, $"depth-{caseName}-output");
        Directory.CreateDirectory(outputDirectory);
        string outputPath = Path.Combine(outputDirectory, $"depth-{caseName}-contours.shp");
        var executeRequest = new DepthShapefileExportExecuteRequest(map, [], sources.ContextToken,
            active.Node, 0, selected.ResultPath, selected.Revision, profileIndex,
            testCellSize, inspection.DefaultSimplifyDistance, outputPath);
        DepthShapefileExportExecuteResult result = await DepthShapefileExportService.ExportAsync(
            executeRequest, null, null).ConfigureAwait(false);
        Check(result.State == "completed" && result.OutputPath == Path.GetFullPath(outputPath) &&
              result.MapID == map.MapID && result.ContextToken == sources.ContextToken &&
              result.ResultNode == active.Node && result.SelectionIndex == 0 &&
              result.ResultPath == selected.ResultPath && result.ResultRevision == selected.Revision &&
              result.ProfileIndex == profileIndex && result.ProfileName == profile.Name &&
              result.CellSize == testCellSize &&
              result.PolygonCount > 0,
            "Depth execute publishes contours from the same map, context token, selected Result slot and profile.");
        string[] requiredExtensions = assignProjectedCrs
            ? [".shp", ".shx", ".dbf", ".prj"]
            : [".shp", ".shx", ".dbf"];
        Check(requiredExtensions.All(extension => result.Artifacts.Any(artifact =>
                  string.Equals(Path.GetExtension(artifact.Path), extension,
                      StringComparison.OrdinalIgnoreCase))) &&
              (assignProjectedCrs || result.Artifacts.All(artifact =>
                  !string.Equals(Path.GetExtension(artifact.Path), ".prj", StringComparison.OrdinalIgnoreCase))),
            assignProjectedCrs
                ? "Depth execute receipts include the Shapefile, index, DBF and current-project CRS sidecar."
                : "Local-coordinate depth exports include the Shapefile, index and DBF but do not invent a projection sidecar.");
        foreach (ExportArtifactReceipt receipt in result.Artifacts) CheckReceipt(receipt);
        ContourBounds bounds = VerifyDepthShapefile(outputPath, result, projectPath,
            expectedProjection: assignProjectedCrs);
        ContourBounds originalResultMapBounds = ExportOriginalResultMapDepthBounds(map,
            sources.ContextToken, selected.ResultPath, profileIndex, testCellSize,
            inspection.DefaultSimplifyDistance, root, caseName);
        // The retained WinUI DepthShapeExporter also fed its cell-centered raster
        // directly to GetContourShapes; its polygon envelope is not the raster clip extent.
        if (!assignProjectedCrs)
            Check(Near(originalResultMapBounds.MinX, -0.05) &&
                  Near(originalResultMapBounds.MinY, 0.05) &&
                  Near(originalResultMapBounds.MaxX, 0.95) &&
                  Near(originalResultMapBounds.MaxY, 1.05),
                "The retained ResultMap contour path places the 0.1-cell 0..1 raster at its measured border-cell OGR envelope.");
        Check(Near(bounds.MinX, originalResultMapBounds.MinX) &&
              Near(bounds.MinY, originalResultMapBounds.MinY) &&
              Near(bounds.MaxX, originalResultMapBounds.MaxX) &&
              Near(bounds.MaxY, originalResultMapBounds.MaxY),
            "The exported depth geometry matches an independently regenerated original ResultMap depth raster and OGR contour envelope.");

        Dictionary<string, string> publishedFamily = CaptureFiles(result.Artifacts.Select(item => item.Path));
        await ExpectIOException(async () =>
            await DepthShapefileExportService.ExportAsync(executeRequest, null, null).ConfigureAwait(false),
            "Depth execute rejects an existing Shapefile family.").ConfigureAwait(false);
        VerifySnapshot(privateSourceBytes, "Private Result source copy");
        VerifySnapshot(acceptanceBytes, "Original MapResultRenderChecks fixture");
        VerifySnapshot(publishedFamily, "Depth Shapefile family after rejected overwrite");
        Check(!Directory.EnumerateFiles(outputDirectory, ".*.tmp", SearchOption.AllDirectories).Any() &&
              !Directory.EnumerateDirectories(outputDirectory, ".*.tmp", SearchOption.AllDirectories).Any(),
            "Depth publication removes its temporary Shapefile staging directory after success and no-clobber rejection.");
        return bounds;
    }

    private static ContourBounds ExportOriginalResultMapDepthBounds(MapTreeRequest map,
        string contextToken, string resultPath, int profileIndex, double cellSize,
        double simplifyDistance, string root, string caseName)
    {
        using ResolvedMapResultContext context = MapResultChartService.ResolveContext(
            map, [], contextToken);
        ResolvedMapResultNode selected = context.ResultContexts.Single(candidate =>
            PathComparer().Equals(Path.GetFullPath(candidate.ResultPath), Path.GetFullPath(resultPath)) &&
            candidate.SelectionIndices.Contains(0));
        IHorizontalOutputBlock outputBlock = selected.Result.BaseOutputBlock as IHorizontalOutputBlock
            ?? throw new InvalidDataException("The original ResultMap fixture has no horizontal output block.");
        Ras.Layers.Terrain terrain = selected.Result.AssociatedTerrain
            ?? throw new InvalidDataException("The original ResultMap fixture has no associated terrain.");
        MeshPropertyTables[] tables = selected.Result.Geometry?.FlowAreaLayer?.AllPropertyTables()
            ?? throw new InvalidDataException("The original ResultMap fixture has no embedded mesh properties.");
        var originalRenderLayer = new ResultMapRenderLayer(outputBlock, MapTypes.Depth,
            terrain, tables);
        Mapper mapper = Mapper.CreateMapper(MapTypes.Depth, outputBlock, tables);
        mapper.RenderOptions.AllowNegativeDepths = true;
        var originalGenerationResampler = new ResultMapResampler(mapper,
            originalRenderLayer.TerrainResampler);
        IRaster<float> depthRaster = originalGenerationResampler.AsSingleProfile(profileIndex)
            .AsRaster(cellSize);
        RasterDefinition definition = depthRaster.RasterDefinition;
        Check(Near(definition.Extent.MinX, 0) && Near(definition.Extent.MinY, 0) &&
              Near(definition.Extent.MaxX, 1) && Near(definition.Extent.MaxY, 1) &&
              definition.Rows == 10 && definition.Cols == 10,
            "The original ResultMap depth raster is a 10-by-10, 0..1 cell grid at the requested 0.1 cell size.");

        ContourShapeOperations.GetContourShapes(depthRaster, 256, 0f,
            out ComplexPolygonCollection polygons, out _, simplifyDistance);
        string baselinePath = Path.Combine(root, $"depth-{caseName}-original-result-map.shp");
        OperationResult write = ShapefileIO.Write(baselinePath, polygons.ToArray());
        Check(write.Result,
            "The original ResultMap raster and contour path independently writes an OGR-readable reference family.");
        ContourBounds bounds = ReadAllShapefileBounds(baselinePath);
        context.EnsureUnchanged();
        return bounds;
    }

    private static ContourBounds ReadAllShapefileBounds(string path)
    {
        using DataSource dataSource = Ogr.OpenShared(path, 0) ??
            throw new InvalidDataException("OGR could not reopen the independently generated ResultMap reference.");
        using Layer layer = dataSource.GetLayerByIndex(0) ??
            throw new InvalidDataException("OGR could not open the independently generated ResultMap reference layer.");
        double minX = double.PositiveInfinity;
        double minY = double.PositiveInfinity;
        double maxX = double.NegativeInfinity;
        double maxY = double.NegativeInfinity;
        while (layer.GetNextFeature() is { } feature)
        {
            using (feature)
            using (OgrGeometry geometry = feature.GetGeometryRef() ??
                   throw new InvalidDataException("The independent ResultMap reference has an empty geometry."))
            {
                var envelope = new Envelope();
                geometry.GetEnvelope(envelope);
                minX = Math.Min(minX, envelope.MinX);
                minY = Math.Min(minY, envelope.MinY);
                maxX = Math.Max(maxX, envelope.MaxX);
                maxY = Math.Max(maxY, envelope.MaxY);
            }
        }
        if (!double.IsFinite(minX) || !double.IsFinite(minY) ||
            !double.IsFinite(maxX) || !double.IsFinite(maxY))
            throw new InvalidDataException("OGR found no independent ResultMap depth geometry.");
        return new(minX, minY, maxX, maxY);
    }

    private static ContourBounds VerifyDepthShapefile(string path,
        DepthShapefileExportExecuteResult result, string projectPath, bool expectedProjection)
    {
        using DataSource dataSource = Ogr.OpenShared(path, 0) ??
            throw new InvalidDataException("OGR could not independently reopen the exported depth Shapefile.");
        Check(dataSource.GetLayerCount() == 1,
            "The reopened depth Shapefile has one polygon layer.");
        using Layer layer = dataSource.GetLayerByIndex(0) ??
            throw new InvalidDataException("OGR could not reopen the depth polygon layer.");
        wkbGeometryType layerType = layer.GetGeomType();
        Check((layerType is wkbGeometryType.wkbPolygon or wkbGeometryType.wkbMultiPolygon) &&
              layer.GetFeatureCount(1) == result.PolygonCount,
            "OGR reads the retained polygon geometry declaration and every published contour feature.");
        double minX = double.PositiveInfinity;
        double minY = double.PositiveInfinity;
        double maxX = double.NegativeInfinity;
        double maxY = double.NegativeInfinity;
        while (layer.GetNextFeature() is { } feature)
        {
            using (feature)
            using (OgrGeometry geometry = feature.GetGeometryRef() ??
                   throw new InvalidDataException("The persisted depth feature has no polygon geometry."))
            {
                Check((geometry.GetGeometryType() is wkbGeometryType.wkbPolygon or wkbGeometryType.wkbMultiPolygon) &&
                      double.IsFinite(geometry.Area()) && geometry.Area() > 0,
                    "Every reopened OGR feature contains a non-empty polygon geometry.");
                var featureEnvelope = new Envelope();
                geometry.GetEnvelope(featureEnvelope);
                minX = Math.Min(minX, featureEnvelope.MinX);
                minY = Math.Min(minY, featureEnvelope.MinY);
                maxX = Math.Max(maxX, featureEnvelope.MaxX);
                maxY = Math.Max(maxY, featureEnvelope.MaxY);
            }
        }
        if (!double.IsFinite(minX) || !double.IsFinite(minY) ||
            !double.IsFinite(maxX) || !double.IsFinite(maxY))
            throw new InvalidDataException("OGR found no persisted depth contour feature.");
        using SpatialReference? actualProjection = layer.GetSpatialRef();
        using SpatialReference? expectedSpatialReference = ReadProjectProjection(projectPath);
        Check((actualProjection is not null) == expectedProjection &&
              (expectedSpatialReference is not null) == expectedProjection,
            expectedProjection
                ? "The projected depth Shapefile reopens with a projection sidecar."
                : "The LocalUSC depth Shapefile reopens without claiming an undefined projected CRS.");
        if (actualProjection is not null && expectedSpatialReference is not null)
            Check(actualProjection.IsSame(expectedSpatialReference, null) == 1,
                "The reopened depth Shapefile projection matches the current project projection.");
        if (!expectedProjection)
            Check(!File.Exists(Path.ChangeExtension(path, ".prj")),
                "The LocalUSC export does not create a projection sidecar for coordinates without a CRS.");
        return new(minX, minY, maxX, maxY);
    }

    private static string RequireMapResultRenderFixture()
    {
        string? configured = Environment.GetEnvironmentVariable(
            "HECRAS_MAP_RESULT_RENDER_ACCEPTANCE_DIRECTORY");
        Check(!string.IsNullOrWhiteSpace(configured),
            "Depth export validation requires HECRAS_MAP_RESULT_RENDER_ACCEPTANCE_DIRECTORY. Configure it before the existing MapResultRenderChecks.Run producer; this is a required fixture gate, never a skip.");
        string directory = Path.GetFullPath(configured!);
        string marker = Path.Combine(directory, "ACCEPTANCE.txt");
        Check(Directory.Exists(directory) && File.Exists(marker) &&
              File.ReadAllText(marker, Encoding.UTF8).Contains(
                  "Map Result raster render fixture built with Result.PrepareResult",
                  StringComparison.Ordinal),
            "The required HECRAS_MAP_RESULT_RENDER_ACCEPTANCE_DIRECTORY fixture was not produced by MapResultRenderChecks.Run.");
        return directory;
    }

    private static void AssignProjectionToPrivateFixtureCopy(string projectPath)
    {
        XDocument project = XDocument.Load(projectPath, LoadOptions.PreserveWhitespace);
        XElement projection = project.Root?.Element("Projection") ??
            throw new InvalidDataException("The copied MapResultRenderChecks project has no Projection element.");
        ProjectionDefinition.FromEPSG(32650).Serialize(projection);
        project.Save(projectPath, SaveOptions.DisableFormatting);
    }

    private static void CreateRgbSourceRaster(string path, bool withProjection)
    {
        using GdalDriver driver = Gdal.GetDriverByName("GTiff") ??
            throw new InvalidOperationException("GDAL has no GTiff driver for the RGB export source fixture.");
        using Dataset dataset = driver.Create(path, 8, 8, 1, DataType.GDT_Float32,
            ["TILED=YES", "BLOCKXSIZE=16", "BLOCKYSIZE=16"]) ??
            throw new InvalidOperationException("GDAL could not create the RGB export source TIFF.");
        dataset.SetGeoTransform([500_000, 1, 0, 1_000_000, 0, -1]);
        if (withProjection)
        {
            using var spatialReference = new SpatialReference("");
            Check(spatialReference.ImportFromEPSG(32650) == 0,
                "The projected RGB source TIFF uses a real EPSG:32650 spatial reference.");
            Check(spatialReference.ExportToWkt(out string wkt, []) == 0,
                "OSR exports the RGB source projection.");
            Check(dataset.SetProjection(wkt) == 0,
                "GDAL assigns the RGB source TIFF projection.");
        }
        using Band band = dataset.GetRasterBand(1);
        band.Fill(10, 0);
    }

    private static string RgbVisualizationXml() => """
        <Ras><Maps><Map Name="RGB Export Map" Type="Project"><Tree><Nodes>
        <Node Type="MapLayer" MapType="SingleBandRasterMapLayer" Name="Elevation" Filename="source.tif" FilenameRelative="source.tif">
          <RasterSymbology ValueSource="Manual" IsSurfaceFillEnabled="true" Alpha="255">
            <SurfaceFill Name="Source ramp"><Color R="255" G="0" B="0" Value="0"/><Color R="0" G="0" B="255" Value="20"/></SurfaceFill>
          </RasterSymbology>
        </Node></Nodes></Tree></Map></Maps><Symbology/></Ras>
        """;

    private static byte[] ReadByteBand(Dataset dataset, int index, int width, int height)
    {
        using Band band = dataset.GetRasterBand(index);
        byte[] values = new byte[width * height];
        band.ReadRaster(0, 0, width, height, values, width, height, 0, 0);
        return values;
    }

    private static SpatialReference? ReadProjectProjection(string projectPath)
    {
        XElement projectionElement = XDocument.Load(projectPath).Root?.Element("Projection") ??
            throw new InvalidDataException("The source project has no serialized projection definition.");
        ProjectionDefinition definition = ProjectionDefinition.Deserialize(projectionElement);
        OperationResult evaluated = definition.Evaluate(out Geospatial.GDALAssist.Projection? projection, out _);
        Check(evaluated.Result && (projection is not null || definition.Type == ProjectionType.Local),
            "The source project projection definition evaluates through the retained projection service; local coordinate projects intentionally have no projected CRS.");
        if (projection is null) return null;
        return new SpatialReference(projection!.GetWKT());
    }

    private static Dictionary<string, string> CaptureDirectory(string root) => CaptureFiles(
        Directory.EnumerateFiles(root, "*", SearchOption.AllDirectories));

    private static Dictionary<string, string> CaptureFiles(IEnumerable<string> paths) => paths
        .Select(Path.GetFullPath)
        .Distinct(PathComparer())
        .ToDictionary(path => path, HashFile, PathComparer());

    private static void VerifySnapshot(IReadOnlyDictionary<string, string> expected, string description)
    {
        foreach ((string path, string hash) in expected)
            Check(File.Exists(path) && HashFile(path).Equals(hash, StringComparison.OrdinalIgnoreCase),
                $"{description} source bytes changed: {path}");
    }

    private static void CheckReceipt(ExportArtifactReceipt receipt)
    {
        Check(File.Exists(receipt.Path) && new FileInfo(receipt.Path).Length == receipt.SizeBytes &&
              HashFile(receipt.Path).Equals(receipt.SHA256, StringComparison.OrdinalIgnoreCase),
            "The export receipt matches the published artifact bytes and SHA-256: " + receipt.Path);
    }

    private static void CopyDirectory(string source, string destination)
    {
        Check(!Directory.Exists(destination) && !File.Exists(destination),
            "The private Result fixture copy destination already exists.");
        Directory.CreateDirectory(destination);
        foreach (string directory in Directory.EnumerateDirectories(source, "*", SearchOption.AllDirectories))
            Directory.CreateDirectory(Path.Combine(destination, Path.GetRelativePath(source, directory)));
        foreach (string path in Directory.EnumerateFiles(source, "*", SearchOption.AllDirectories))
        {
            string copy = Path.Combine(destination, Path.GetRelativePath(source, path));
            Directory.CreateDirectory(Path.GetDirectoryName(copy)!);
            File.Copy(path, copy, overwrite: false);
        }
    }

    private static bool IsWithin(string root, string path)
    {
        string canonicalRoot = Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar) +
            Path.DirectorySeparatorChar;
        string candidate = Path.GetFullPath(path);
        return candidate.StartsWith(canonicalRoot,
            OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal);
    }

    private static StringComparer PathComparer() => OperatingSystem.IsWindows()
        ? StringComparer.OrdinalIgnoreCase : StringComparer.Ordinal;

    private static bool SameNode(CatalogTreeNodeLocator first, CatalogTreeNodeLocator second) =>
        first.RootName == second.RootName && first.NodeType == second.NodeType &&
        first.NodeName == second.NodeName && SamePath(first.NodePath, second.NodePath) &&
        first.AssetID == second.AssetID && first.MapType == second.MapType &&
        first.Filename == second.Filename && first.FilenameRelative == second.FilenameRelative &&
        first.ParentGeometryAssetID == second.ParentGeometryAssetID &&
        SamePath(first.ParentGeometryNodePath, second.ParentGeometryNodePath) &&
        first.ParentGeometryNodeName == second.ParentGeometryNodeName &&
        first.AssociationAssetID == second.AssociationAssetID && first.AssociationKind == second.AssociationKind &&
        first.ParentPlanAssetID == second.ParentPlanAssetID &&
        SamePath(first.ParentPlanNodePath, second.ParentPlanNodePath) &&
        first.ParentPlanNodeName == second.ParentPlanNodeName &&
        first.ParentResultNodeType == second.ParentResultNodeType &&
        first.ParentResultAssetID == second.ParentResultAssetID &&
        SamePath(first.ParentResultNodePath, second.ParentResultNodePath) &&
        first.ParentResultNodeName == second.ParentResultNodeName &&
        first.ParentResultRevision == second.ParentResultRevision &&
        first.ParentBoundaryConditionAssetID == second.ParentBoundaryConditionAssetID &&
        SamePath(first.ParentBoundaryConditionNodePath, second.ParentBoundaryConditionNodePath) &&
        first.ParentBoundaryConditionNodeName == second.ParentBoundaryConditionNodeName;

    private static bool SamePath(int[]? first, int[]? second) =>
        first is null ? second is null : second is not null && first.SequenceEqual(second);

    private static string HashFile(string path)
    {
        using FileStream input = File.OpenRead(path);
        return Convert.ToHexString(SHA256.HashData(input));
    }

    private static string Hash(byte[] bytes) => Convert.ToHexString(SHA256.HashData(bytes));

    private static bool Near(double first, double second) => Math.Abs(first - second) < 1e-8;

    private sealed record ContourBounds(double MinX, double MinY, double MaxX, double MaxY);

    private static async Task ExpectIOException(Func<Task> action, string message)
    {
        try
        {
            await action().ConfigureAwait(false);
        }
        catch (IOException)
        {
            return;
        }
        throw new InvalidOperationException(message);
    }

    private static void Check(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }
}
