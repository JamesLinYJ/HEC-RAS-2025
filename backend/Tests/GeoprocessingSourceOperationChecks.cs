using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Geospatial.Features;
using Geospatial.IO;
using Geospatial.Rasters;
using Geospatial.Vectors;
using OSGeo.GDAL;
using Ras.Backend;

internal static class GeoprocessingSourceOperationChecks
{
    private const float NoData = -9999f;

    internal static void Run() => RunAsync().GetAwaiter().GetResult();

    internal static async Task RunAsync()
    {
        using var temporary = new TemporaryDirectory();
        string root = temporary.FullName;
        VectorFixture vector = CreateVectorFixture(root);

        RasterFixture plane = CreateRasterFixture(root, "plane", (column, row) =>
            (float)((column + 0.5) + 2 * (11.5 - row)));
        RasterFixture constant = CreateRasterFixture(root, "constant", (_, _) => 7f);
        RasterFixture round = CreateRasterFixture(root, "round", (_, _) => 1.26f);
        RasterFixture missing = CreateRasterFixture(root, "missing", (column, row) =>
            column == 6 && row == 6 ? NoData : (float)((column + 0.5) + 2 * (11.5 - row)), NoData);
        RasterFixture hill = CreateRasterFixture(root, "hill", (_, row) => row is 4 or 8 ? 100f : 0f);

        GeoprocessingPolylineInput[] sourceLines = vector.Lines;
        GeoprocessingPolygonInput[] sourcePolygons = vector.Polygons;
        GeoprocessingPolylineInput selectedLine = sourceLines[0];
        GeoprocessingPolylineInput distanceLine = sourceLines[2];
        GeoprocessingPolylineInput snapLine = sourceLines[3];
        GeoprocessingPolygonInput donut = sourcePolygons[0];

        // The map caller sends only selected stable paths. Keep an unselected
        // sibling in the source fixture to prove the response stays scoped.
        GeoprocessingPolylineResponse buffered = GeoprocessingToolService.Execute(
            VectorRequest(vector, "BufferPolyline", [selectedLine]) with
            { BufferWidthText = "1", OutputHandler = "Clipboard" });
        Polygon expectedBuffer = GeoprocessingToolService.ToPolyline(selectedLine)
            .GetOffsetPolygon(2, out _, out _);
        Check(buffered.CanExecute && buffered.OutputKind == "Polygon" && buffered.PolygonOutputs is { Length: 1 }
              && buffered.CapturedPathIdentities.SequenceEqual([selectedLine.PathIdentity])
              && Near(Math.Abs(SignedArea(buffered.PolygonOutputs[0].Coordinates)), Math.Abs(expectedBuffer.Area), 1e-6),
            "BufferPolyline matches the retained offset-polygon geometry and captures only the selected source path.");

        PolylineToPolygonMatchesSource(vector, selectedLine);
        BufferPolygonPreservesHole(vector, donut);
        DensifyPolygonPreservesMultipartAndHoleSelection(vector, sourcePolygons);
        PolygonToPolylinePreservesRingsAndDimensions(vector, sourcePolygons);
        PolygonCallerBranchesUseCapturedRings(vector, donut);
        SnapToHighGroundUsesActualRaster(vector, snapLine, hill);

        GeoprocessingPolylineResponse rasterized = GeoprocessingToolService.Execute(
            VectorRequest(vector, "RasterizePolygons", polygons: [donut], outputHandler: "Tiff",
                outputName: "Rasterized hole test") with
            { CellSizeText = "1", FillValueText = "7", BackgroundValueText = "-2" });
        RasterReadback rasterizedPixels = RequireRaster(rasterized, "RasterizePolygons", vector.Root);
        Check(Near(rasterizedPixels.At(3.5, 3.5), 7, 1e-5)
              && Near(rasterizedPixels.At(5.5, 5.5), -2, 1e-5)
              && Near(rasterizedPixels.At(1.5, 1.5), -2, 1e-5),
            "RasterizePolygons writes known fill/background pixels and keeps the polygon hole empty.");

        GeoprocessingPolylineResponse distance = GeoprocessingToolService.Execute(
            VectorRequest(vector, "DistanceToLines", [distanceLine], raster: null,
                outputHandler: "Map Layer", outputName: "Distance pixels") with
            { CellSizeText = "1", MaxDistanceCellsText = "4", DistanceAlgorithm = "SpatialIndex" });
        RasterReadback distancePixels = RequireRaster(distance, "DistanceToLines", vector.Root);
        // The selected line extent is x=[2.5, 8.5], y=[6.5, 7.5]. At 1-unit
        // cells, extending that source grid by four cells gives x=[-1.5, 12.5],
        // y=[2.5, 11.5], so (6, 6) and (6, 7) are exact output-cell centers.
        // Both are exactly 0.5 map units from the horizontal segment at y=6.5.
        Check(Near(distancePixels.At(6, 6), 0.5, 1e-5)
              && Near(distancePixels.At(6, 7), 0.5, 1e-5),
            "DistanceToLines samples exact distance from each output cell center to the captured segment.");

        GeoprocessingPolylineResponse heat = GeoprocessingToolService.Execute(
            VectorRequest(vector, "ProximityHeatmap", [distanceLine], outputHandler: "Tiff",
                outputName: "Heatmap pixels") with
            { CellSizeText = "1", MaxDistanceCellsText = "4", SigmaCellsText = "2", DistanceAlgorithm = "SpatialIndex" });
        RasterReadback heatPixels = RequireRaster(heat, "ProximityHeatmap", vector.Root);
        Check(Near(heatPixels.At(6, 6), Math.Exp(-1d / 32d), 1e-5)
              && Near(heatPixels.At(6, 7), Math.Exp(-1d / 32d), 1e-5),
            "ProximityHeatmap applies the retained Gaussian decay at the exact half-unit cell-center distance with sigma two cells.");

        GeoprocessingPolylineResponse clipped = GeoprocessingToolService.Execute(
            VectorRequest(vector, "ClipRasterToPolygon", polygons: [donut], raster: plane,
                outputHandler: "Tiff", outputName: "Clipped plane") with
            { OutputCellSizeText = "1" });
        RasterReadback clippedPixels = RequireRaster(clipped, "ClipRasterToPolygon", vector.Root);
        Check(Near(clippedPixels.At(3.5, 3.5), 10.5, 1e-4)
              && IsNoData(clippedPixels, clippedPixels.At(5.5, 5.5))
              && IsNoData(clippedPixels, clippedPixels.At(1.5, 1.5)),
            "ClipRasterToPolygon preserves the source plane inside the shell and writes NoData in the hole and outside.");

        GeoprocessingPolylineResponse stats = GeoprocessingToolService.Execute(
            VectorRequest(vector, "RasterCutStats", polygons: sourcePolygons, raster: constant,
                outputHandler: "Clipboard"));
        double[] means = (stats.TextOutput ?? "").Split('\n')
            .Where(line => line.TrimStart().StartsWith("Mean:", StringComparison.Ordinal))
            .Select(line => double.Parse(line[(line.IndexOf(':') + 1)..].Trim(), CultureInfo.InvariantCulture))
            .ToArray();
        Check(stats.CanExecute && stats.OutputKind == "Text" && means.Length == 2 && means.All(value => value == 7),
            "RasterCutStats reports the two selected MultiPolygon components' actual constant-raster means.");

        GeoprocessingPolylineResponse laplacian = GeoprocessingToolService.Execute(
            VectorRequest(vector, "LaplacianTerrain", polygons: [donut], raster: constant,
                outputHandler: "Tiff", outputName: "Laplacian surface") with
            {
                UseAdvancedSizing = true, BoundarySpacingText = "2", InteriorGridSpacingText = "2",
                OutputCellSizeText = "1"
            });
        RasterReadback laplacianPixels = RequireRaster(laplacian, "LaplacianTerrain", vector.Root);
        Check(Near(laplacianPixels.At(3.5, 3.5), 7, 1e-3)
              && IsNoData(laplacianPixels, laplacianPixels.At(5.5, 5.5))
              && IsNoData(laplacianPixels, laplacianPixels.At(1.5, 1.5)),
            "LaplacianTerrain interpolates the constant surface while respecting the captured hole and outer boundary.");

        GeoprocessingPolylineResponse resampled = GeoprocessingToolService.Execute(
            RasterOnlyRequest(plane, "ResampleRaster", "Resampled plane") with { CellSizeText = "2" });
        RasterReadback resampledPixels = RequireRaster(resampled, "ResampleRaster", plane.Root);
        Check(resampledPixels.Width == 6 && resampledPixels.Height == 6
              && Near(resampledPixels.Transform[1], 2, 1e-9)
              && Near(resampledPixels.At(1, 11), 22.5, 1e-4),
            "ResampleRaster emits the retained nearest-sampled 2-unit grid and the analytic plane value at its first cell center.");

        GeoprocessingPolylineResponse rounded = GeoprocessingToolService.Execute(
            RasterOnlyRequest(round, "RoundRaster", "Rounded constant") with
            { CellSizeText = "1", RoundTo = "Tenths" });
        RasterReadback roundedPixels = RequireRaster(rounded, "RoundRaster", round.Root);
        Check(roundedPixels.Pixels.Length > 0 && roundedPixels.Pixels.All(value => Near(value, 1.3, 1e-5)),
            "RoundRaster applies source Tenths rounding to actual TIFF samples, not only the response metadata.");

        GeoprocessingPointInput noDataSeed = new("seed-feature", "seed-path:6:6", 2, 0, [6.5, 5.5]);
        GeoprocessingPolylineResponse repaired = GeoprocessingToolService.Execute(
            VectorRequest(vector, "NoDataLaplacianFill", raster: missing, points: [noDataSeed],
                outputHandler: "Tiff", outputName: "Filled plane") with
            {
                CellSizeText = "1", BoundarySpacingText = "1", InteriorGridSpacingText = "1",
                Connectivity = "FourSides", NoDataOutputMode = "Full"
            });
        RasterReadback repairedPixels = RequireRaster(repaired, "NoDataLaplacianFill", vector.Root);
        Check(Near(repairedPixels.At(6.5, 5.5), 17.5, 1.5)
              && Near(repairedPixels.At(5.5, 5.5), 16.5, 1e-4)
              && repaired.CapturedPointIdentities?.SequenceEqual([noDataSeed.PathIdentity]) == true,
            "NoDataLaplacianFill reconstructs the isolated plane cell from surrounding samples and leaves neighboring source pixels intact.");

        GeoprocessingPointInput flatSeed = new("seed-feature", "seed-path:flat", 2, 0, [5.5, 5.5]);
        GeoprocessingPolylineResponse flat = GeoprocessingToolService.Execute(
            VectorRequest(vector, "FlatAreaDetector", raster: constant, points: [flatSeed],
                outputHandler: "Clipboard") with
            { CellSizeText = "1", MaxSlopePercentText = "1", Connectivity = "FourSides" });
        Check(flat.CanExecute && flat.OutputKind == "Polygon" && flat.PolygonOutputs is { Length: 1 }
              && Math.Abs(SignedArea(flat.PolygonOutputs[0].Coordinates)) >= 120
              && flat.CapturedPointIdentities?.SequenceEqual([flatSeed.PathIdentity]) == true,
            "FlatAreaDetector floods the actual constant DEM from the selected seed and returns its full raster-sized flat region.");

        await DuplexCancellationLeavesSourcesUntouchedAsync(vector, hill);

        Check(File.ReadAllBytes(vector.Path).SequenceEqual(vector.Bytes),
            "Every source operation leaves the captured GeoJSON bytes unchanged.");
        foreach (RasterFixture raster in new[] { plane, constant, round, missing, hill })
        {
            Check(File.ReadAllBytes(raster.Path).SequenceEqual(raster.Bytes),
                "Geoprocessing leaves the captured raster bytes unchanged: " + raster.Name);
            Check(File.ReadAllBytes(raster.VisualizationPath).SequenceEqual(raster.VisualizationBytes),
                "Geoprocessing leaves the raster's owning visualization bytes unchanged: " + raster.Name);
            Check(File.ReadAllBytes(raster.ProjectPath).SequenceEqual(raster.ProjectBytes),
                "Geoprocessing leaves the raster's owning project bytes unchanged: " + raster.Name);
        }

        Console.WriteLine("All 16 retained source geoprocessing operations and two polygon caller branches returned analytic geometry, raster or cancellation results without changing captured source files.");
    }

    private static void PolylineToPolygonMatchesSource(VectorFixture vector, GeoprocessingPolylineInput line)
    {
        GeoprocessingPolylineResponse response = GeoprocessingToolService.Execute(
            VectorRequest(vector, "PolylineToPolygon", [line]));
        Polygon expected = Polygon.CreateWithBuffer(GeoprocessingToolService.ToPolyline(line));
        Check(response.CanExecute && response.PolygonOutputs is { Length: 1 }
              && Near(Math.Abs(SignedArea(response.PolygonOutputs[0].Coordinates)), Math.Abs(expected.Area), 1e-8)
              && response.CapturedPathIdentities.SequenceEqual([line.PathIdentity]),
            "PolylineToPolygon follows Polygon.CreateWithBuffer for only the selected source path.");
    }

    private static void BufferPolygonPreservesHole(VectorFixture vector, GeoprocessingPolygonInput polygon)
    {
        GeoprocessingPolylineResponse response = GeoprocessingToolService.Execute(
            VectorRequest(vector, "BufferPolygon", polygons: [polygon], outputHandler: "Shapefile",
                outputName: "Buffered donut") with { BufferPolygonDistanceText = "0.5" });
        GeoprocessingPolygonOutput output = response.PolygonOutputs?.SingleOrDefault()
            ?? throw new InvalidOperationException("BufferPolygon did not return its selected polygon.");
        double originalOuter = Math.Abs(SignedArea(polygon.Coordinates));
        double originalHole = Math.Abs(SignedArea(polygon.Holes![0]));
        Check(response.CanExecute && output.Holes is { Length: 1 }
              && Math.Abs(SignedArea(output.Coordinates)) > originalOuter
              && Math.Abs(SignedArea(output.Holes[0])) < originalHole
              && response.CapturedPolygonPathIdentities?.SequenceEqual([polygon.PathIdentity]) == true,
            "A positive polygon buffer expands the outer ring and contracts, rather than fills, the actual hole.");
        string path = response.OutputPath ?? "";
        Check(File.Exists(path) && File.Exists(ShapefileIO.SHXFilename(path)) && File.Exists(ShapefileIO.DBFFilename(path))
              && PathEquals(Path.GetDirectoryName(path)!, Path.Combine(vector.Root, "Exports"))
              && ShapefileIO.TryRead(path, out PolygonCollectionFeatureCollection persisted).Result
              && persisted.Features.Count == 1 && persisted.Features[0].Count == 2,
            "The selected buffered polygon is written and independently read back with its hole as one complex feature.");
    }

    private static void DensifyPolygonPreservesMultipartAndHoleSelection(VectorFixture vector,
        GeoprocessingPolygonInput[] polygons)
    {
        GeoprocessingPolylineResponse response = GeoprocessingToolService.Execute(
            VectorRequest(vector, "DensifyPolygons", polygons: polygons) with { MaxSegmentLengthText = "2" });
        Check(response.CanExecute && response.PolygonOutputs is { Length: 2 }
              && response.CapturedPolygonPathIdentities?.SequenceEqual(polygons.Select(polygon => polygon.PathIdentity)) == true
              && response.PolygonOutputs[0].Holes is { Length: 1 } firstPolygonHoles
              && MaximumClosedSegmentLength(response.PolygonOutputs[0].Coordinates) <= 2.000001
              && MaximumClosedSegmentLength(firstPolygonHoles[0]) <= 2.000001
              && response.PolygonOutputs[1].Holes is { Length: 0 },
            "DensifyPolygons subdivides each selected multipart ring to the requested maximum segment length without losing the hole.");
    }

    private static void PolygonToPolylinePreservesRingsAndDimensions(VectorFixture vector,
        GeoprocessingPolygonInput[] polygons)
    {
        GeoprocessingPolylineResponse response = GeoprocessingToolService.Execute(
            VectorRequest(vector, "PolygonToPolyline", polygons: polygons));
        double[][][] expectedRings = [polygons[0].Coordinates, polygons[0].Holes![0], polygons[1].Coordinates];
        bool everyRingReturned = expectedRings.All(expected => response.Outputs.Any(output =>
            ClosedCoordinatesEqual(output.Coordinates, expected)));
        bool outerZAndM = response.Outputs.Any(output => OrdinatesMatch(output.ZValues, polygons[0].ZValues)
            && OrdinatesMatch(output.MValues, polygons[0].MValues));
        bool holeZAndM = response.Outputs.Any(output => OrdinatesMatch(output.ZValues, polygons[0].HoleZValues![0])
            && OrdinatesMatch(output.MValues, polygons[0].HoleMValues![0]));
        Check(response.CanExecute && response.Outputs.Length == 3 && everyRingReturned && outerZAndM && holeZAndM
              && response.CapturedPolygonPathIdentities?.SequenceEqual(polygons.Select(polygon => polygon.PathIdentity)) == true,
            "PolygonToPolyline emits outer and hole rings for both selected multipart components and preserves their captured Z/M ordinates.");
    }

    private static void PolygonCallerBranchesUseCapturedRings(VectorFixture vector, GeoprocessingPolygonInput polygon)
    {
        GeoprocessingPolylineInput[] rings =
        [
            new(polygon.FeatureIdentity, polygon.PathIdentity + ":outer", polygon.SourceFeatureIndex, 0,
                polygon.Coordinates, polygon.ZValues, polygon.MValues),
            new(polygon.FeatureIdentity, polygon.PathIdentity + ":hole:0", polygon.SourceFeatureIndex, 1,
                polygon.Holes![0], polygon.HoleZValues![0], polygon.HoleMValues![0])
        ];
        GeoprocessingPolylineResponse filtered = GeoprocessingToolService.Execute(
            VectorRequest(vector, "Filter", rings) with { ToleranceText = "0.1" });
        GeoprocessingPolylineResponse smoothed = GeoprocessingToolService.Execute(
            VectorRequest(vector, "Smooth", rings) with
            { MovingAverageWindowText = "3", MovingAveragePassesText = "1" });
        Polyline[] expectedSmooth = rings.Select(ring =>
            GeoprocessingToolService.ToPolyline(ring).CloneWithMovingAverageSmoothing(3, 1)).ToArray();
        Check(filtered.CanExecute && filtered.Outputs.Length == 2
              && filtered.CapturedPathIdentities.SequenceEqual(rings.Select(ring => ring.PathIdentity))
              && smoothed.CanExecute && smoothed.Outputs.Length == 2
              && smoothed.Outputs.Select((output, index) => OutputMatches(output, expectedSmooth[index])).All(value => value),
            "Polygon Filter and Smooth caller branches pass the selected outer/hole paths through the retained line algorithms.");
    }

    private static void SnapToHighGroundUsesActualRaster(VectorFixture vector,
        GeoprocessingPolylineInput line, RasterFixture hill)
    {
        GeoprocessingPolylineResponse response = GeoprocessingToolService.Execute(
            VectorRequest(vector, "SnapToHighGround", [line], raster: hill) with
            { SearchRadiusText = "2", SampleSpacingText = "1", SearchMode = "Perpendicular", ElevationMode = "Highest" });
        Check(response.CanExecute && response.Outputs is { Length: 1 }
              && response.Outputs[0].Coordinates.All(point => Near(point[1], 3.5, 1e-6) || Near(point[1], 7.5, 1e-6))
              && response.Outputs[0].ZValues?.SequenceEqual(line.ZValues ?? []) == true
              && response.Outputs[0].MValues?.SequenceEqual(line.MValues ?? []) == true,
            "SnapToHighGround moves each selected vertex onto a measured DEM ridge and retains its original Z/M sequence.");
    }

    private static async Task DuplexCancellationLeavesSourcesUntouchedAsync(VectorFixture vector, RasterFixture hill)
    {
        double[][] coordinates = Enumerable.Range(0, 50_000)
            .Select(index => new[] { 2.5 + index % 7, 5.5 }).ToArray();
        var longLine = new GeoprocessingPolylineInput("line-source", "path:cancel:0", 0, 0, coordinates);
        GeoprocessingPolylineRequest request = VectorRequest(vector, "SnapToHighGround", [longLine], raster: hill) with
        { SearchRadiusText = "2", SampleSpacingText = "1", OutputHandler = "Clipboard" };
        string requestID = Guid.NewGuid().ToString("D");
        var input = new CancellationControlInput(requestID);
        var progress = new List<BackendOperationProgress>();
        bool sent = false;
        await using var controls = new BackendDuplexControlReader(requestID, input);
        try
        {
            _ = await GeoprocessingToolService.ExecuteDuplexAsync(request, update =>
            {
                progress.Add(update);
                if (!sent && update.TaskName == "Checking captured map features")
                {
                    sent = true;
                    input.SendCancel();
                    Thread.Sleep(150);
                }
            }, controls);
            throw new InvalidOperationException("The geoprocessing duplex operation ignored its cancellation frame.");
        }
        catch (OperationCanceledException) { }

        Check(sent && progress.Any(update => update.TaskName == "Checking captured map features")
              && File.ReadAllBytes(vector.Path).SequenceEqual(vector.Bytes)
              && File.ReadAllBytes(hill.Path).SequenceEqual(hill.Bytes),
            "A live duplex cancel received before high-ground sampling preserves the captured vector and DEM bytes.");
    }

    private static GeoprocessingPolylineRequest VectorRequest(VectorFixture vector, string operation,
        GeoprocessingPolylineInput[]? lines = null, GeoprocessingPolygonInput[]? polygons = null,
        GeoprocessingPointInput[]? points = null, RasterFixture? raster = null,
        string outputHandler = "Clipboard", string? outputName = null) => new(
        SourcePath: vector.Path,
        SourceRevision: vector.Revision,
        ProjectDirectory: vector.Root,
        ProjectProjectionType: "Local",
        ProjectProjectionValue: "English",
        Operation: operation,
        InputMode: "Selected",
        InputLines: lines ?? [],
        CultureName: "en-US",
        OutputHandler: outputHandler,
        OutputName: outputName,
        InputPolygons: polygons,
        RasterSource: raster?.Identity,
        ProjectXml: raster?.ProjectXml,
        InputPoints: points);

    private static GeoprocessingPolylineRequest RasterOnlyRequest(RasterFixture raster, string operation,
        string outputName) => new(
        SourcePath: raster.Path,
        SourceRevision: raster.Revision,
        ProjectDirectory: raster.Root,
        ProjectProjectionType: "Local",
        ProjectProjectionValue: "English",
        Operation: operation,
        InputMode: "All",
        InputLines: [],
        CultureName: "en-US",
        OutputHandler: "Tiff",
        OutputName: outputName,
        RasterSource: raster.Identity,
        ProjectXml: raster.ProjectXml);

    private static RasterReadback RequireRaster(GeoprocessingPolylineResponse response, string operation,
        string expectedProjectDirectory)
    {
        string path = response.OutputPath ?? "";
        string expectedExportDirectory = Path.GetFullPath(Path.Combine(expectedProjectDirectory, "Exports"));
        Check(response.CanExecute && response.Operation == operation && response.OutputKind == "Raster"
              && Path.IsPathFullyQualified(path) && File.Exists(path)
              && PathEquals(Path.GetDirectoryName(Path.GetFullPath(path))!, expectedExportDirectory),
            operation + " writes its raster into the exact captured project's Exports directory.");
        RasterReadback result = ReadRaster(path);
        Check(result.Width > 0 && result.Height > 0 && result.Pixels.Length == result.Width * result.Height,
            operation + " output opens as a real GDAL raster with pixels.");
        double expectedMinY = result.Transform[3] + result.Height * result.Transform[5];
        double expectedMaxX = result.Transform[0] + result.Width * result.Transform[1];
        Check(response.OutputRasterWidth == result.Width && response.OutputRasterHeight == result.Height
              && response.OutputRasterExtent is { Length: 4 } extent
              && Near(extent[0], result.Transform[0], 1e-8)
              && Near(extent[1], expectedMinY, 1e-8)
              && Near(extent[2], expectedMaxX, 1e-8)
              && Near(extent[3], result.Transform[3], 1e-8),
            operation + " returns raster dimensions and extent that match the independently opened TIFF.");
        return result;
    }

    private static VectorFixture CreateVectorFixture(string root)
    {
        double[][] line0 = [[2.5, 5.5], [5.5, 6.5], [8.5, 5.5]];
        double[][] line1 = [[2.5, 3.5], [8.5, 3.5]];
        double[][] line2 = [[2.5, 6.5], [3.5, 6.5], [8.5, 6.5], [8.5, 7.5]];
        double[][] line3 = [[2.5, 5.5], [5.5, 5.5], [8.5, 5.5]];
        double[][] outer = [[2, 2], [8, 2], [8, 8], [2, 8], [2, 2]];
        double[][] hole = [[4, 4], [4, 6], [6, 6], [6, 4], [4, 4]];
        double[][] secondOuter = [[9, 2], [11, 2], [11, 4], [9, 4], [9, 2]];
        var content = new
        {
            type = "FeatureCollection",
            features = new object[]
            {
                new { type = "Feature", id = "line-source", properties = new { }, geometry = new { type = "MultiLineString", coordinates = new[] { line0, line1, line2, line3 } } },
                new { type = "Feature", id = "polygon-source", properties = new { }, geometry = new { type = "MultiPolygon", coordinates = new[] { new[] { outer, hole }, new[] { secondOuter } } } }
            }
        };
        byte[] bytes = JsonSerializer.SerializeToUtf8Bytes(content);
        string path = Path.Combine(root, "source.geojson");
        File.WriteAllBytes(path, bytes);

        GeoprocessingPolylineInput[] lines =
        [
            new("line-source", "path:line-source:0", 0, 0, line0, ["10", "20", "30"], ["1", "2", "3"]),
            new("line-source", "path:line-source:1", 0, 1, line1),
            new("line-source", "path:line-source:2", 0, 2, line2),
            new("line-source", "path:line-source:3", 0, 3, line3, ["10", "20", "30"], ["1", "2", "3"])
        ];
        GeoprocessingPolygonInput[] polygons =
        [
            new("polygon-source", "path:polygon-source:0", 1, 0, outer,
                ["1", "2", "3", "4", "1"], ["11", "12", "13", "14", "11"],
                [hole], [["5", "6", "7", "8", "5"]], [["15", "16", "17", "18", "15"]]),
            new("polygon-source", "path:polygon-source:1", 1, 1, secondOuter)
        ];
        return new(root, path, bytes, Convert.ToHexString(SHA256.HashData(bytes)), lines, polygons);
    }

    private static RasterFixture CreateRasterFixture(string root, string name,
        Func<int, int, float> valueAt, float? noData = null)
    {
        string directory = Path.Combine(root, "raster-" + name);
        Directory.CreateDirectory(directory);
        string projectPath = Path.Combine(directory, "Raster.ras");
        string projectXml = "<Project/>";
        byte[] projectBytes = Encoding.UTF8.GetBytes(projectXml);
        File.WriteAllBytes(projectPath, projectBytes);
        string rasterPath = Path.Combine(directory, name + ".tif");
        const int width = 12, height = 12;
        float[] pixels = Enumerable.Range(0, width * height)
            .Select(index => valueAt(index % width, index / width)).ToArray();
        using (var driver = Gdal.GetDriverByName("GTiff"))
        using (var dataset = driver.Create(rasterPath, width, height, 1, DataType.GDT_Float32,
                   ["TILED=YES", "BLOCKXSIZE=16", "BLOCKYSIZE=16"]))
        {
            dataset.SetGeoTransform([0, 1, 0, 12, 0, -1]);
            using var band = dataset.GetRasterBand(1);
            if (noData.HasValue) band.SetNoDataValue(noData.Value);
            band.WriteRaster(0, 0, width, height, pixels, width, height, 0, 0);
            dataset.FlushCache();
        }
        byte[] rasterBytes = File.ReadAllBytes(rasterPath);
        string revision = Convert.ToHexString(SHA256.HashData(rasterBytes));
        string visualizationPath = Path.ChangeExtension(projectPath, ".vis");
        string fileName = Path.GetFileName(rasterPath);
        string visualization = $"""
            <Ras><Maps><Map Name="Map" Type="Project"><Tree><Nodes>
            <Node Type="MapLayer" MapType="SingleBandRasterMapLayer" Name="Elevation" Filename="{fileName}" FilenameRelative="{fileName}">
              <RasterSymbology ValueSource="Manual" IsSurfaceFillEnabled="true" Alpha="255">
                <SurfaceFill Name="Source ramp"><Color R="255" G="0" B="0" Value="0"/><Color R="0" G="0" B="255" Value="100"/></SurfaceFill>
              </RasterSymbology>
            </Node></Nodes></Tree></Map></Maps><Symbology/></Ras>
            """;
        File.WriteAllText(visualizationPath, visualization, new UTF8Encoding(false));
        byte[] visualizationBytes = File.ReadAllBytes(visualizationPath);
        string visualizationRevision = Convert.ToHexString(SHA256.HashData(visualizationBytes));
        var identity = new RasterMapSourceIdentity("vis-map-0-node-0", projectPath, visualizationPath,
            visualizationRevision, 0, "Map", "Project", [0], "Elevation", "SingleBandRasterMapLayer",
            fileName, fileName, rasterPath, Guid.NewGuid().ToString("D"), revision);
        return new(name, directory, projectPath, projectBytes, projectXml, visualizationPath,
            visualizationBytes, rasterPath, rasterBytes, revision, identity);
    }

    private static RasterReadback ReadRaster(string path)
    {
        using var dataset = Gdal.Open(path, Access.GA_ReadOnly);
        double[] transform = new double[6];
        dataset.GetGeoTransform(transform);
        float[] pixels = new float[checked(dataset.RasterXSize * dataset.RasterYSize)];
        using var band = dataset.GetRasterBand(1);
        band.ReadRaster(0, 0, dataset.RasterXSize, dataset.RasterYSize, pixels,
            dataset.RasterXSize, dataset.RasterYSize, 0, 0);
        band.GetNoDataValue(out double noData, out int hasNoData);
        return new(dataset.RasterXSize, dataset.RasterYSize, transform, pixels,
            hasNoData == 0 ? null : noData);
    }

    private static bool IsNoData(RasterReadback raster, float value) =>
        raster.NoData is { } noData ? value == noData : !float.IsFinite(value);

    private static double SignedArea(double[][] ring)
    {
        double area = 0;
        for (int index = 0; index < ring.Length; index++)
        {
            double[] current = ring[index];
            double[] next = ring[(index + 1) % ring.Length];
            area += current[0] * next[1] - next[0] * current[1];
        }
        return area / 2;
    }

    private static double MaximumClosedSegmentLength(double[][] ring)
    {
        double maximum = 0;
        for (int index = 0; index < ring.Length; index++)
        {
            double[] current = ring[index], next = ring[(index + 1) % ring.Length];
            maximum = Math.Max(maximum, Math.Sqrt(Math.Pow(next[0] - current[0], 2) + Math.Pow(next[1] - current[1], 2)));
        }
        return maximum;
    }

    private static bool ClosedCoordinatesEqual(double[][] actual, double[][] expected)
    {
        if (actual.Length != expected.Length) return false;
        for (int start = 0; start < expected.Length; start++)
        {
            if (!Near(actual[0][0], expected[start][0], 1e-9) || !Near(actual[0][1], expected[start][1], 1e-9)) continue;
            bool forward = true, backward = true;
            for (int index = 0; index < actual.Length; index++)
            {
                forward &= Near(actual[index][0], expected[(start + index) % expected.Length][0], 1e-9)
                    && Near(actual[index][1], expected[(start + index) % expected.Length][1], 1e-9);
                int reverseIndex = (start - index + expected.Length) % expected.Length;
                backward &= Near(actual[index][0], expected[reverseIndex][0], 1e-9)
                    && Near(actual[index][1], expected[reverseIndex][1], 1e-9);
            }
            if (forward || backward) return true;
        }
        return false;
    }

    private static bool OrdinatesMatch(string[]? actual, string[]? expected) => actual is not null && expected is not null
        && (actual.SequenceEqual(expected, StringComparer.Ordinal)
            || actual.SequenceEqual(expected.Reverse(), StringComparer.Ordinal));

    private static bool OutputMatches(GeoprocessingPolylineOutput output, Polyline expected) =>
        output.Coordinates.Length == expected.Count && Enumerable.Range(0, expected.Count).All(index =>
            Near(output.Coordinates[index][0], expected[index].X, 1e-9)
            && Near(output.Coordinates[index][1], expected[index].Y, 1e-9));

    private static bool Near(double actual, double expected, double tolerance) =>
        double.IsFinite(actual) && Math.Abs(actual - expected) <= tolerance;

    private static bool PathEquals(string first, string second) =>
        Path.GetFullPath(first).Equals(Path.GetFullPath(second), OperatingSystem.IsWindows()
            ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal);

    private static void Check(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }

    private sealed record VectorFixture(string Root, string Path, byte[] Bytes, string Revision,
        GeoprocessingPolylineInput[] Lines, GeoprocessingPolygonInput[] Polygons);

    private sealed record RasterFixture(string Name, string Root, string ProjectPath, byte[] ProjectBytes,
        string ProjectXml, string VisualizationPath, byte[] VisualizationBytes, string Path,
        byte[] Bytes, string Revision, RasterMapSourceIdentity Identity);

    private sealed record RasterReadback(int Width, int Height, double[] Transform, float[] Pixels, double? NoData)
    {
        public float At(double x, double y)
        {
            int column = (int)Math.Floor((x - Transform[0]) / Transform[1]);
            int row = (int)Math.Floor((y - Transform[3]) / Transform[5]);
            if ((uint)column >= (uint)Width || (uint)row >= (uint)Height)
                throw new InvalidOperationException("The analytic pixel lies outside the returned raster extent.");
            return Pixels[row * Width + column];
        }
    }

    private sealed class CancellationControlInput(string requestID) : TextReader
    {
        private readonly TaskCompletionSource<string?> line = new(TaskCreationOptions.RunContinuationsAsynchronously);
        private int cancelSent;
        private int lineRead;

        public void SendCancel()
        {
            if (Interlocked.Exchange(ref cancelSent, 1) != 0) return;
            line.TrySetResult(JsonSerializer.Serialize(new
            {
                id = requestID,
                controlSequence = 1,
                control = new { type = "cancel" }
            }));
        }

        public override ValueTask<string?> ReadLineAsync(CancellationToken cancellationToken)
        {
            if (Interlocked.Exchange(ref lineRead, 1) != 0)
                return ValueTask.FromResult<string?>(null);
            return new(line.Task.WaitAsync(cancellationToken));
        }
    }
}
