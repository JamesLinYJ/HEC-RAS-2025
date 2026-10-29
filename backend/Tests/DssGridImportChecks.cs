using System.Globalization;
using System.Security.Cryptography;
using System.Text.Json;
using Geospatial.Rasters;
using Geospatial.Vectors;
using Hec.Dss;
using Ras.Backend;
using Ras.Layers;
using Utility.Units;

internal static class DssGridImportChecks
{
    internal static async Task Run()
    {
        VerifyCancellationPublicationRace();
        VerifyTiledRasterSamplingDefaults();
        VerifySpatialGridTimeFormattingPreservesKind();
        using var temporary = new TemporaryDirectory();
        string root = temporary.FullName;
        string projectPath = Path.Combine(root, "DSS栅格回归.ras");
        var project = Project.CreateNew(projectPath, UnitSystem.SI);
        DateTime start = new(2025, 1, 1);
        var boundary = project.AddNewBoundaryCondition("DSS 栅格回归", start, TimeSpan.FromDays(2));
        project.Save();
        string asset = boundary.Filename;
        boundary.Dispose();

        string sourcePath = Path.Combine(root, "真实DSS栅格序列.dss");
        DateTime[] times = [new(2025, 1, 1), new(2025, 1, 2)];
        string albers = Grid.SHG_SRC_DEFINITION;
        string otherAlbers = albers.Replace("Central_Meridian\",-96.0",
            "Central_Meridian\",-100.0", StringComparison.Ordinal);
        static float[] Values(float value, bool noData = false)
        {
            float[] data = Enumerable.Repeat(value, 16).ToArray();
            if (noData) data[0] = -9999;
            return data;
        }
        string Pathname(string group, DateTime time)
            => $"/RasTests/{group}/Surface/{time.ToString("ddMMMyyyy", CultureInfo.InvariantCulture)}/1Day/RasTests/";
        Grid MakeGrid(string path, string units, DssDataType type, float[] values,
            float cellSize = 1000, string? projection = null)
        {
            float[] valid = values.Where(value => value != -9999).ToArray();
            return new Grid
            {
                PathName = path,
                GridType = GridType.ALBERS,
                Units = units,
                DataSource = "HEC-RAS actual grid regression",
                DataType = type,
                LowerLeftCellX = 10,
                LowerLeftCellY = 20,
                NumberOfCellsX = 4,
                NumberOfCellsY = 4,
                CellSize = cellSize,
                SRSName = "USA Contiguous Albers Equal Area Conic",
                SRSDefinitionType = 0,
                SRSDefinition = projection ?? albers,
                XCoordOfGridCellZero = 10000,
                YCoordOfGridCellZero = 20000,
                NullValue = -9999,
                UndefinedValue = float.MinValue,
                TimeZoneID = "UTC",
                IsTimeStamped = true,
                IsInterval = false,
                MinDataValue = valid.Min(),
                MaxDataValue = valid.Max(),
                MeanDataValue = valid.Average(),
                RangeLimitTable = [],
                NumberEqualOrExceedingRangeLimit = [],
                Data = values
            };
        }

        using (var writer = new DssWriter(sourcePath))
        {
            writer.Write(MakeGrid(Pathname("Pressure", times[0]), "Pa", DssDataType.INST_VAL,
                Values(100000, noData: true)));
            writer.Write(MakeGrid(Pathname("Pressure", times[1]), "Pa", DssDataType.INST_VAL, Values(101000)));
            writer.Write(MakeGrid(Pathname("Wind-X", times[0]), "m/s", DssDataType.INST_VAL, Values(3)));
            writer.Write(MakeGrid(Pathname("Wind-X", times[1]), "m/s", DssDataType.INST_VAL, Values(4)));
            writer.Write(MakeGrid(Pathname("Wind-Y", times[0]), "m/s", DssDataType.INST_VAL, Values(7)));
            writer.Write(MakeGrid(Pathname("Wind-Y", times[1]), "m/s", DssDataType.INST_VAL, Values(8)));
            writer.Write(MakeGrid(Pathname("Wind-Y-OtherTime", new(2025, 1, 2)), "m/s",
                DssDataType.INST_VAL, Values(70)));
            writer.Write(MakeGrid(Pathname("Wind-Y-OtherTime", new(2025, 1, 3)), "m/s",
                DssDataType.INST_VAL, Values(80)));
            writer.Write(MakeGrid(Pathname("Wind-Y-OtherSpacing", times[0]), "m/s",
                DssDataType.INST_VAL, Values(70), cellSize: 2000));
            writer.Write(MakeGrid(Pathname("Wind-Y-OtherSpacing", times[1]), "m/s",
                DssDataType.INST_VAL, Values(80), cellSize: 2000));
            writer.Write(MakeGrid(Pathname("Wind-Y-OtherProjection", times[0]), "m/s",
                DssDataType.INST_VAL, Values(70), projection: otherAlbers));
            writer.Write(MakeGrid(Pathname("Wind-Y-OtherProjection", times[1]), "m/s",
                DssDataType.INST_VAL, Values(80), projection: otherAlbers));
            writer.Write(MakeGrid(Pathname("Rain", times[0]), "mm/hr", DssDataType.PER_AVER, Values(2.5f)));
            writer.Write(MakeGrid(Pathname("Rain", times[1]), "mm/hr", DssDataType.PER_AVER, Values(3.5f)));
        }

        using (var reader = new DssReader(sourcePath))
        {
            DssPath[] records = reader.GetCatalog().UnCondensedPaths
                .Where(path => path.RecordType == RecordType.Grid).ToArray();
            Check(records.Length == 14, "Native DSS catalog returns each grid frame as a distinct exact path.");
            Grid readback = reader.GetGrid(Pathname("Pressure", times[1]), retrieveData: true);
            Check(readback.Data.Length == 16 && readback.Data.All(value => value == 101000)
                  && readback.SRSDefinition.Contains("Albers", StringComparison.OrdinalIgnoreCase)
                  && readback.NullValue == -9999,
                "Native DSS readback returns actual frame pixels, projection and NoData metadata.");
        }
        ExportFixtureIfRequested(root);

        string fileHash = Hash(sourcePath);
        var current = await ModelEditorAdapter.LoadAsync(new(asset, "Boundary Conditions", projectPath));
        ModelSaveRequest Draft() => new(asset, "Boundary Conditions", projectPath,
            current.Revision, [], [], SourceState: current.SourceState);
        var pressureInspection = await ModelEditorAdapter.InspectGridAsync(
            new(Draft(), "airPressure", [sourcePath]));
        DssGridSeriesInfo pressure = FindSeries(pressureInspection, "Pressure");
        Check(pressure.Times.Length == 2 && pressure.RecordPaths.Length == 2
              && pressure.Times[0].StartsWith("2025-01-01", StringComparison.Ordinal)
              && pressure.NoDataValue == -9999
              && pressure.Projection.Contains("Albers", StringComparison.OrdinalIgnoreCase)
              && pressureInspection.DssGridSourcePath == Path.GetFullPath(sourcePath)
              && pressureInspection.DssGridRevision == fileHash
              && Hash(sourcePath) == fileHash,
            "DSS inspection binds the original source path/SHA and exposes both actual times, projection and NoData.");

        var repeatedPressureInspection = await ModelEditorAdapter.InspectGridAsync(
            new(Draft(), "airPressure", [sourcePath]));
        DssGridSeriesInfo repeatedPressure = repeatedPressureInspection.DssGridSources!
            .Single(source => source.Id == pressure.Id);
        Check(repeatedPressure.Id == pressure.Id
              && repeatedPressure.GroupPath == pressure.GroupPath
              && !pressure.GroupPath.Contains(Path.GetTempPath(), StringComparison.Ordinal),
            "DSS series identity remains tied to the original path/SHA/records and never exposes its temporary inspection copy.");

        static DssGridImportComponent Component(string name, DssGridSeriesInfo series)
            => new(name, series.Id, series.Times, series.RecordPaths, series.GridIdentity);
        static DssGridImportSelection Selection(SpatialGridInspection inspection,
            params DssGridImportComponent[] components)
            => new(inspection.DssGridSourcePath!, inspection.DssGridRevision!,
                inspection.DssGridDraftIdentity!, Guid.NewGuid().ToString("D"), components);

        byte[] originalDssBytes = File.ReadAllBytes(sourcePath);
        string boundaryBeforeStaleImport = Hash(asset);
        File.AppendAllText(sourcePath, "source revision changed");
        await Reject<SourceFileChangedException>(() => ModelEditorAdapter.ImportGridAsync(new(Draft(),
            new("airPressure", [], "Pa", "inst-val")
            {
                DssSource = Selection(pressureInspection, Component("Value", pressure))
            })));
        File.WriteAllBytes(sourcePath, originalDssBytes);
        Check(Hash(sourcePath) == fileHash && Hash(asset) == boundaryBeforeStaleImport,
            "A DSS source changed after inspection is rejected without altering the boundary HDF.");

        current = await ModelEditorAdapter.ImportGridAsync(new(Draft(),
            new("airPressure", [], "Pa", "inst-val")
            {
                DssSource = Selection(pressureInspection, Component("Value", pressure))
            }));
        Check(current.Grids!["airPressure"].Times.Length == 2
              && current.Grids["airPressure"].Projection.Contains("Albers", StringComparison.OrdinalIgnoreCase),
            "DSS pressure import stores both frames and the source projection in the boundary model.");
        using (var actual = new BoundaryCondition(asset, project))
        {
            Check(actual.AirPressure.GetNativeGriddedRaster(out var data, out _).Result
                  && data.Times.Count == 2
                  && FrameIsEqual(data, 0, 1000, expectSingleNoData: true)
                  && FrameIsEqual(data, 1, 1010, expectSingleNoData: false),
                "Independent HDF readback preserves DSS frame values, NoData and Pa-to-millibar conversion.");
        }
        string stagedFallbackPath = Path.Combine(root, "prepared-dss-fallback.pending");
        string publishedFallbackPath = Path.Combine(root, "prepared-dss-fallback.hdf");
        File.Copy(asset, stagedFallbackPath);
        ModelSnapshot fallback = ModelEditorAdapter.PrepareDssCommittedSnapshot(current,
            stagedFallbackPath, current.SourceState);
        File.Move(stagedFallbackPath, publishedFallbackPath);
        using (JsonDocument boundaryDraft = JsonDocument.Parse(fallback.SourceState!))
            Check(fallback.Revision == Hash(publishedFallbackPath)
                  && boundaryDraft.RootElement.GetProperty("revision").GetString() == fallback.Revision
                  && fallback.Grids!["airPressure"].Times.Length == 2,
                "The prepared committed fallback carries the published HDF SHA, matching boundary draft revision and actual grid snapshot.");

        var windInspection = await ModelEditorAdapter.InspectGridAsync(new(Draft(), "wind", [sourcePath]));
        DssGridSeriesInfo windX = FindSeries(windInspection, "Wind-X");
        DssGridSeriesInfo windY = FindSeries(windInspection, "Wind-Y");
        DssGridSeriesInfo timeMismatch = FindSeries(windInspection, "Wind-Y-OtherTime");
        DssGridSeriesInfo spacingMismatch = FindSeries(windInspection, "Wind-Y-OtherSpacing");
        DssGridSeriesInfo projectionMismatch = FindSeries(windInspection, "Wind-Y-OtherProjection");
        string beforeRejectedImports = Hash(asset);
        await Reject<ArgumentException>(() => ModelEditorAdapter.ImportGridAsync(new(Draft(),
            new("wind", [], "m/s", "inst-val")
            {
                DssSource = Selection(windInspection, Component("X", windX), Component("Y", timeMismatch))
            })));
        await Reject<ArgumentException>(() => ModelEditorAdapter.ImportGridAsync(new(Draft(),
            new("wind", [], "m/s", "inst-val")
            {
                DssSource = Selection(windInspection, Component("X", windX), Component("Y", spacingMismatch))
            })));
        await Reject<ArgumentException>(() => ModelEditorAdapter.ImportGridAsync(new(Draft(),
            new("wind", [], "m/s", "inst-val")
            {
                DssSource = Selection(windInspection, Component("X", windX), Component("Y", projectionMismatch))
            })));
        Check(Hash(asset) == beforeRejectedImports,
            "Wind import rejects mismatched valid times, cell spacing and projection without replacing the model.");

        current = await ModelEditorAdapter.ImportGridAsync(new(Draft(),
            new("wind", [], "m/s", "inst-val")
            {
                DssSource = Selection(windInspection, Component("X", windX), Component("Y", windY))
            }));
        using (var actual = new BoundaryCondition(asset, project))
        {
            Check(actual.Wind.GetNativeGriddedRaster(out var data, out _).Result,
                "The native DSS X/Y frames reopen from the boundary HDF.");
            (float[] X, float[] Y) first = ReadWindFrame(data, 0);
            Check(first.X.All(value => value == 3) && first.Y.All(value => value == 7),
                "Wind frame one contains the actual DSS X and Y values.");
            (float[] X, float[] Y) second = ReadWindFrame(data, 1);
            Check(second.X.All(value => value == 4) && second.Y.All(value => value == 8),
                "Wind frame two retains the next actual DSS valid time rather than repeating frame one.");
        }

        var rainInspection = await ModelEditorAdapter.InspectGridAsync(
            new(Draft(), "precipitation", [sourcePath]));
        DssGridSeriesInfo rain = FindSeries(rainInspection, "Rain");
        current = await ModelEditorAdapter.ImportGridAsync(new(Draft(),
            new("precipitation", [], "mm/hr", "per-avg")
            {
                DssSource = Selection(rainInspection, Component("Value", rain))
            }));
        using (var actual = new BoundaryCondition(asset, project))
        {
            Check(actual.Precipitation.GetNativeGriddedRaster(out var data, out _).Result
                  && data.Times.Count == 2
                  && ReadRasterFrame(data, 0).All(value => Math.Abs(value - 2.5) < 1e-4)
                  && ReadRasterFrame(data, 1).All(value => Math.Abs(value - 3.5) < 1e-4),
                "PER_AVER DSS rainfall records retain both source times and actual frame values.");
        }
    }

    private static void VerifyTiledRasterSamplingDefaults()
    {
        var definition = new RasterDefinition(new Point(0, 2), cellSize: 1, rows: 2, cols: 2);
        var provider = new MemoryTileProvider<float>(definition, tileSize: 2, noDataValue: -9999f);
        provider.SetTileBuffer(0, 0, [-9999f, 20f, 30f, 40f]);
        IRaster<float> raster = provider.AsRasterizer();
        Point[] points = [new(0.5, 1.5), new(1.5, 1.5), new(2.1, 1.5)];

        float[] defaultSamples = [123f, 123f, 123f];
        raster.SamplePoints(points.AsMemory(), defaultSamples.AsMemory());
        Check(defaultSamples[0] == -9999f && defaultSamples[1] == 20f && defaultSamples[2] == -9999f,
            "Default tiled-raster sampling initializes NoData cells and out-of-extent points to NoData.");

        float[] preservedSamples = [-12345f, -12345f, -12345f];
        raster.SamplePoints(points.AsMemory(), preservedSamples.AsMemory(), SamplingParams.WithoutBufferClear);
        Check(preservedSamples[0] == -12345f && preservedSamples[1] == 20f && preservedSamples[2] == -12345f,
            "Explicit WithoutBufferClear leaves caller values at NoData and out-of-extent points unchanged.");
    }

    private static void VerifySpatialGridTimeFormattingPreservesKind()
    {
        DateTime ticks = new(2025, 1, 1, 12, 34, 56, DateTimeKind.Unspecified);
        DateTime wallTime = DateTime.SpecifyKind(ticks, DateTimeKind.Unspecified);
        DateTime utcTime = DateTime.SpecifyKind(ticks, DateTimeKind.Utc);
        DateTime localTime = DateTime.SpecifyKind(ticks, DateTimeKind.Local);

        string wallText = SpatialGridService.Date(wallTime);
        string utcText = SpatialGridService.Date(utcTime);
        string localText = SpatialGridService.Date(localTime);
        DateTime ParseRoundTrip(string value) => DateTime.Parse(value, CultureInfo.InvariantCulture,
            DateTimeStyles.RoundtripKind);

        DateTime parsedWall = ParseRoundTrip(wallText);
        DateTime parsedUtc = ParseRoundTrip(utcText);
        DateTime parsedLocal = ParseRoundTrip(localText);
        DateTime importedWall = SpatialGridService.ParseDate(wallText);
        DateTime importedUtc = SpatialGridService.ParseDate(utcText);
        DateTime importedLocal = SpatialGridService.ParseDate(localText);
        const string wallClockText = "2025-01-01T12:34:56.0000000";
        Check(parsedWall.Kind == DateTimeKind.Unspecified && parsedWall.Ticks == wallTime.Ticks
              && wallText == wallClockText,
            "Unspecified grid timestamps remain timezone-free wall-clock values.");
        Check(parsedUtc.Kind == DateTimeKind.Utc && parsedUtc.Ticks == utcTime.Ticks
              && utcText == wallClockText + "Z",
            "Explicit UTC grid timestamps retain UTC kind and the UTC designator.");
        Check(parsedLocal.Kind == DateTimeKind.Local && parsedLocal.Ticks == localTime.Ticks
              && localText == wallClockText + localTime.ToString("zzz", CultureInfo.InvariantCulture),
            "Explicit local grid timestamps retain the machine-local offset and unchanged wall-clock ticks.");
        Check(importedWall.Kind == DateTimeKind.Unspecified && importedWall.Ticks == wallTime.Ticks,
            "A formatted GDAL wall-clock band timestamp survives the import parser without an implicit UTC-to-local shift.");
        DateTime expectedLocalUtc = utcTime.ToLocalTime();
        Check(importedUtc.Kind == DateTimeKind.Local && importedUtc.Ticks == expectedLocalUtc.Ticks,
            "A formatted UTC band timestamp keeps the existing conversion to local time on import.");
        Check(importedLocal.Kind == DateTimeKind.Local && importedLocal.Ticks == localTime.Ticks,
            "A formatted local band timestamp survives import with its local wall-clock ticks.");
    }

    private static float[] ReadRasterFrame(ITimeSeriesRaster<float> raster, int frame)
    {
        RasterDefinition definition = raster.RasterDefinition;
        Point[] points = CellCenters(definition);
        float[] values = new float[points.Length];
        raster.SamplePoints(points.AsMemory(), frame, values.AsMemory());
        return values;
    }

    private static bool FrameIsEqual(ITimeSeriesRaster<float> raster, int frame,
        float expectedValue, bool expectSingleNoData)
    {
        RasterDefinition definition = raster.RasterDefinition;
        float[] raw = new float[definition.CellCount];
        raster.GetRange(definition.FullRange(), frame, raw.AsMemory());
        float[] sampled = ReadRasterFrame(raster, frame);
        float noData = raster.NoDataValue ?? float.NaN;
        bool rawMatches = expectSingleNoData
            ? raw.Count(value => value == noData) == 1
                && raw.Where(value => value != noData).All(value => Math.Abs(value - expectedValue) < 1e-4)
            : raw.All(value => Math.Abs(value - expectedValue) < 1e-4);
        bool sampledMatches = expectSingleNoData
            ? sampled.Count(value => value == noData) == 1
                && sampled.Where(value => value != noData).All(value => Math.Abs(value - expectedValue) < 1e-4)
            : sampled.All(value => Math.Abs(value - expectedValue) < 1e-4);
        if (rawMatches && sampledMatches) return true;

        string Values(float[] values) => "[" + string.Join(", ", values.Select(value =>
            value.ToString("R", CultureInfo.InvariantCulture))) + "]";
        string DescribeNumber(double value) => value.ToString("R", CultureInfo.InvariantCulture);
        throw new InvalidOperationException(
            $"DSS HDF frame {frame} mismatch. Expected {expectedValue:R} mb "
            + $"with singleNoData={expectSingleNoData}; rasterNoData="
            + (raster.NoDataValue?.ToString("R", CultureInfo.InvariantCulture) ?? "null")
            + $"; definition={definition.Rows}x{definition.Cols}"
            + $" left={DescribeNumber(definition.Left)} bottom={DescribeNumber(definition.Bottom)}"
            + $" right={DescribeNumber(definition.Right)} top={DescribeNumber(definition.Top)}"
            + $" cellSize={DescribeNumber(definition.CellSize)}"
            + $"; rawGetRange={Values(raw)}; samplePoints={Values(sampled)}.");
    }

    private static (float[] X, float[] Y) ReadWindFrame(ITimeSeriesVelocityRasterizer<float> raster, int frame)
    {
        RasterDefinition definition = raster.RasterDefinition;
        Point[] points = CellCenters(definition);
        float[] x = new float[points.Length];
        float[] y = new float[points.Length];
        float[] magnitude = new float[points.Length];
        raster.SamplePointsVxVy(points.AsMemory(), frame, x.AsMemory(), y.AsMemory(), magnitude.AsMemory());
        return (x, y);
    }

    private static Point[] CellCenters(RasterDefinition definition)
        => Enumerable.Range(0, definition.Rows).SelectMany(row => Enumerable.Range(0, definition.Cols)
            .Select(column => new Point(
                definition.Left + (column + 0.5) * definition.CellSize,
                definition.Top - (row + 0.5) * definition.CellSize))).ToArray();

    private static void ExportFixtureIfRequested(string sourceDirectory)
    {
        string? fixture = Environment.GetEnvironmentVariable("HECRAS_DSS_GRID_ACCEPTANCE_DIRECTORY");
        if (string.IsNullOrWhiteSpace(fixture)) return;
        string destination = Path.GetFullPath(fixture);
        if (Directory.Exists(destination) || File.Exists(destination))
            throw new IOException("The DSS grid fixture destination already exists.");
        Directory.CreateDirectory(destination);
        foreach (string folder in Directory.EnumerateDirectories(sourceDirectory, "*", SearchOption.AllDirectories))
            Directory.CreateDirectory(Path.Combine(destination, Path.GetRelativePath(sourceDirectory, folder)));
        foreach (string file in Directory.EnumerateFiles(sourceDirectory, "*", SearchOption.AllDirectories))
            File.Copy(file, Path.Combine(destination, Path.GetRelativePath(sourceDirectory, file)));
    }

    private static string Hash(string path)
        => Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(path)));

    private static DssGridSeriesInfo FindSeries(SpatialGridInspection inspection, string bPart)
        => inspection.DssGridSources!.Single(source => source.RecordPaths.Length == 2
            && source.RecordPaths.All(path => IsExpectedGroupPath(path, bPart)));

    private static bool IsExpectedGroupPath(string path, string bPart)
    {
        string[] parts = path.Split('/', StringSplitOptions.RemoveEmptyEntries);
        return parts.Length == 6 && parts[0] == "RasTests" && parts[1] == bPart
            && parts[2] == "Surface" && parts[4] == "1Day" && parts[5] == "RasTests";
    }

    private static void VerifyCancellationPublicationRace()
    {
        using (var cancelled = DssGridImportService.BeginImport(Guid.NewGuid().ToString("D")))
        {
            bool published = false;
            Check(cancelled.RequestCancel(), "Precommit cancellation is accepted.");
            try { cancelled.Publish(() => published = true); }
            catch (OperationCanceledException) { }
            Check(!published && !cancelled.IsCommitted,
                "Precommit cancellation prevents publication and does not produce a committed receipt.");
        }
        using (var committed = DssGridImportService.BeginImport(Guid.NewGuid().ToString("D")))
        {
            bool published = false;
            committed.Publish(() => published = true);
            Check(published && committed.IsCommitted && !committed.RequestCancel(),
                "A completed publication wins a later cancellation request and keeps its committed receipt available.");
        }
        for (int index = 0; index < 64; index++)
        {
            using var operation = DssGridImportService.BeginImport(Guid.NewGuid().ToString("D"));
            bool cancelAccepted = false;
            bool published = false;
            Task cancel = Task.Run(() => cancelAccepted = operation.RequestCancel());
            Task commit = Task.Run(() =>
            {
                try { operation.Publish(() => published = true); }
                catch (OperationCanceledException) { }
            });
            Task.WaitAll(cancel, commit);
            Check(operation.IsCommitted == published,
                "The import publication state matches the atomic model-file commit.");
            Check(operation.IsCommitted ? !cancelAccepted : cancelAccepted,
                "Cancellation and atomic publication have one serialized winner.");
        }
    }

    private static void Check(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }

    private static async Task Reject<T>(Func<Task> operation) where T : Exception
    {
        try { await operation(); }
        catch (T) { return; }
        throw new InvalidOperationException("Expected " + typeof(T).Name);
    }
}
