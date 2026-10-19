using System.Globalization;
using Hec.Dss;
using Ras.Backend;

/// <summary>
/// Exercises the retained DSS writer and the read-only catalog/record service
/// against an actual native DSS 7 file. The published fixture is intentionally
/// retained so the Swift integration checks can consume the same source data.
/// </summary>
internal static class DssRecordChecks
{
    private const double Missing = -901.0;
    private const string FixtureFolderName = "dss-fixture-round28-20261018-v1";
    private const string RegularReachAPath = "/Round28/Reach-A/Flow/31Dec2024/1Hour/Round28/";
    private const string RegularReachBPath = "/Round28/Reach-B/Flow/02Jan2025/1Hour/Round28/";
    private const string IrregularPath = "/Round28/Reach-A/Stage/31Dec2024/IR-Day/Round28/";
    private const string PairedPath = "/Round28/Reach-A/Rating///Round28/";

    internal static void Run()
    {
        DateTime qualityStart = new(2025, 1, 1);
        var trimQuality = new TimeSeries(new DssPath(RegularReachBPath), [Missing, 2, 3, Missing],
            qualityStart, "CFS", "INST-VAL")
        {
            Times = Enumerable.Range(0, 4).Select(index => qualityStart.AddHours(index)).ToArray(),
            Qualities = [10, 11, 20, 21, 30, 31, 40, 41]
        };
        trimQuality.Trim();
        Check(trimQuality.Values.SequenceEqual(new double[] { 2, 3 })
            && trimQuality.Qualities.SequenceEqual(new int[] { 20, 21, 30, 31 }),
            "Trimming missing edge values retains every native quality word for the corresponding source rows");
        DssRuntimeInformation runtime = DssRuntimeService.Inspect();
        Check(runtime.Available,
            "The real DSS acceptance check requires the packaged native DSS runtime at "
            + runtime.LibraryPath + ". " + runtime.Error);

        string fixtureDirectory = NewFixtureDirectory();
        string sourcePath = Path.Combine(fixtureDirectory, "records.dss");
        WriteRealDssFile(sourcePath);
        byte[] originalBytes = File.ReadAllBytes(sourcePath);
        Check(originalBytes.Length > 0, "DssWriter produced a nonempty source DSS file");

        DssCatalogResponse catalog = DssRecordService.Catalog(new DssCatalogRequest(sourcePath));
        Check(catalog.Path == Path.GetFullPath(sourcePath) && catalog.Revision.Length == 64,
            "The DSS catalog returns the canonical source path and its SHA-256 revision");
        Check(catalog.Records.Select(record => record.Path).Distinct(StringComparer.Ordinal).Count()
            == catalog.Records.Length, "DSS catalog paths are unique");

        DssRecordDescriptor regularA = Record(catalog, RegularReachAPath, "RegularTimeSeries");
        DssRecordDescriptor regularB = Record(catalog, RegularReachBPath, "RegularTimeSeries");
        Check(regularA.Parts[2] == regularB.Parts[2]
            && regularA.Path != regularB.Path,
            "Records with the same C-part name remain distinct when their complete DSS paths differ");
        Check(regularA.ComprisingPaths.Length >= 2,
            "A series spanning DSS date blocks retains its condensed identity and all comprising paths");
        Check(regularA.Parts[3] == "01Dec2024-01Jan2025"
            && regularA.ComprisingPaths.Select(path => new DssPath(path).Dpart)
                .SequenceEqual(new[] { "01Dec2024", "01Jan2025" })
            && regularB.Parts[3] == "01Jan2025",
            "Hourly catalog dates describe canonical monthly storage blocks rather than the first sample dates");
        Check(catalog.Records.Length == 5
            && catalog.Records.Count(record => record.RecordType == "LocationInfo") == 1,
            "The catalog includes the separate location metadata record created by the retained writer");

        // The retained reader's condensed-path record-type lookup must use a
        // real stored pathname, not the synthesized date-range pathname.
        using (var reader = new DssReader(sourcePath))
        {
            DssPath condensed = reader.GetCatalog().Single(path => path.FullPath == regularA.Path);
            Check(condensed is DssPathCondensed,
                "The cross-date series is represented by a condensed DSS path");
            Check(reader.GetRecordType(condensed) == RecordType.RegularTimeSeries,
                "GetRecordType resolves a condensed identity through its first real pathname");
        }
        Check(File.ReadAllBytes(sourcePath).SequenceEqual(originalBytes),
            "Cataloging and condensed type lookup leave the source DSS bytes unchanged");

        DssRecordDescriptor irregular = Record(catalog, IrregularPath, "IrregularTimeSeries");
        DssRecordDescriptor paired = Record(catalog, PairedPath, "PairedData");
        string unicodePath = Path.Combine(fixtureDirectory, "水文 观测数据.dss");
        File.Copy(sourcePath, unicodePath);
        DssCatalogResponse unicodeCatalog = DssRecordService.Catalog(new DssCatalogRequest(unicodePath));
        Check(unicodeCatalog.Path == unicodePath && unicodeCatalog.Revision == catalog.Revision,
            "Chinese source filenames preserve exact identity while native reads use the isolated copy");
        DssReadResponse unicodeRead = DssRecordService.Read(new DssReadRequest(unicodePath,
            unicodeCatalog.Revision, [regularA.Path]));
        Check(unicodeRead.Records.Single().Kind == "timeSeries"
            && File.ReadAllBytes(unicodePath).SequenceEqual(originalBytes),
            "A real DSS source under a Chinese filename can be read without modifying its bytes");
        DssReadResponse read = DssRecordService.Read(new DssReadRequest(sourcePath, catalog.Revision,
            catalog.Records.Select(record => record.Path).ToArray()));
        Check(read.Revision == catalog.Revision && read.Records.Length == catalog.Records.Length,
            "The selected source catalog records are read against the matching revision");

        DssRecordResult regularResult = Result(read, regularA.Path, "timeSeries");
        DssTimeSeriesData regularSeries = regularResult.TimeSeries
            ?? throw new InvalidOperationException("DSS regular time series payload was missing.");
        DateTime regularStart = new(2024, 12, 31, 22, 0, 0, DateTimeKind.Unspecified);
        DateTime[] regularTimes = Enumerable.Range(0, 28).Select(index => regularStart.AddHours(index)).ToArray();
        double?[] regularValues = Enumerable.Range(0, 28)
            .Select(index => index == 7 ? (double?)null : index + 0.25).ToArray();
        int[] regularQualities = Enumerable.Range(0, 28).Select(index => index + 10).ToArray();
        CheckSeries(regularSeries, regularTimes, regularValues, regularQualities, "CFS", "INST-VAL",
            "Regular series preserves all values, missing data, quality flags, units and times across date blocks");

        DssRecordResult secondRegularResult = Result(read, regularB.Path, "timeSeries");
        Check(secondRegularResult.TimeSeries is { } secondRegular
            && secondRegular.Values.SequenceEqual(new double?[] { 91.5, 92.5, 93.5 })
            && secondRegular.Units == "CFS",
            "A same-name record at a different full pathname returns its own data");

        DssRecordResult irregularResult = Result(read, irregular.Path, "timeSeries");
        DssTimeSeriesData irregularSeries = irregularResult.TimeSeries
            ?? throw new InvalidOperationException("DSS irregular time series payload was missing.");
        DateTime irregularStart = new(2024, 12, 31, 23, 59, 40, DateTimeKind.Unspecified);
        DateTime[] irregularTimes = [irregularStart, irregularStart.AddSeconds(7), irregularStart.AddSeconds(55),
            irregularStart.AddSeconds(61), irregularStart.AddSeconds(90)];
        CheckSeries(irregularSeries, irregularTimes, [2.5, 4.5, null, 8.5, 10.5], [31, 32, 33, 34, 35],
            "FT", "INST-VAL", "Irregular series preserves second-granularity dates, missing data and quality flags");

        DssRecordResult pairedResult = Result(read, paired.Path, "pairedData");
        DssPairedData pairedData = pairedResult.PairedData
            ?? throw new InvalidOperationException("DSS paired-data payload was missing.");
        Check(pairedData.Ordinates.SequenceEqual(new double?[] { 0, 5, 10 })
            && pairedData.Curves.Length == 2
            && pairedData.Curves[0].Label == "Low Flow"
            && pairedData.Curves[0].Values.SequenceEqual(new double?[] { 10, 20, 30 })
            && pairedData.Curves[1].Label == "High Flow"
            && pairedData.Curves[1].Values.SequenceEqual(new double?[] { 15, 25, 35 })
            && pairedData.IndependentUnits == "FT"
            && pairedData.DependentUnits == "CFS"
            && pairedData.IndependentType == "STAGE"
            && pairedData.DependentType == "FLOW",
            "Paired-data reads preserve real curve labels, ordinate arrays, units and types");
        Check(pairedResult.Location is { } location
            && location.X == 500123.25 && location.Y == 3765432.75 && location.Z == 18.5
            && location.CoordinateSystem == CoordinateSystem.UTM.ToString()
            && location.CoordinateID == 26910
            && location.HorizontalUnits == 3 && location.HorizontalDatum == 4
            && location.VerticalUnits == 5 && location.VerticalDatum == 6
            && location.TimeZoneName == "America/Los_Angeles"
            && location.Supplemental == "round28-position-fields",
            "Paired-data reads return the actual stored location and coordinate metadata");
        Check(File.ReadAllBytes(sourcePath).SequenceEqual(originalBytes),
            "Catalog and time-series, paired-data and location reads leave source DSS bytes unchanged");

        Expect<InvalidDataException>(() => DssRecordService.Read(new DssReadRequest(sourcePath,
            catalog.Revision, [regularA.Path, regularA.Path])),
            "Duplicate requested DSS paths are rejected before record reads");
        Expect<InvalidOperationException>(() => DssRecordService.Read(new DssReadRequest(sourcePath,
            catalog.Revision, ["/Round28/Not-A-Real-Path/Flow/31Dec2024/1Hour/Round28/"])),
            "A syntactically valid but uncataloged DSS pathname is rejected");
        Check(File.ReadAllBytes(sourcePath).SequenceEqual(originalBytes),
            "Rejected duplicate and fake-path reads leave the source DSS bytes unchanged");

        CheckStaleRevisionIsRejected(sourcePath, regularA.Path);
        string missingPath = Path.Combine(fixtureDirectory, "source-that-must-not-be-created.dss");
        Check(!File.Exists(missingPath), "The missing-source fixture begins absent");
        Expect<FileNotFoundException>(() => DssRecordService.Catalog(new DssCatalogRequest(missingPath)),
            "Cataloging a nonexistent source fails without creating it");
        Check(!File.Exists(missingPath), "Cataloging a nonexistent source does not create a DSS file");
        Check(File.ReadAllBytes(sourcePath).SequenceEqual(originalBytes),
            "All catalog and read attempts preserve the original DSS source bytes");

        CheckTimeSeriesStorageVariants(fixtureDirectory);

        Console.WriteLine("DSS record acceptance fixture: " + sourcePath);
    }

    private static void CheckTimeSeriesStorageVariants(string fixtureDirectory)
    {
        string path = Path.Combine(fixtureDirectory, "quality-and-culture-variants.dss");
        CultureInfo priorCulture = CultureInfo.CurrentCulture;
        try
        {
            foreach (bool irregular in new[] { false, true })
            foreach (bool saveAsFloat in new[] { false, true })
            {
                CultureInfo.CurrentCulture = CultureInfo.GetCultureInfo(saveAsFloat ? "fr-FR" : "zh-CN");
                DateTime start = new(2025, 4, 10, 10, 0, 5, DateTimeKind.Unspecified);
                if (!irregular) start = start.Date.AddHours(10);
                DateTime[] times = irregular
                    ? [start, start.AddSeconds(7), start.AddSeconds(63)]
                    : [start, start.AddHours(1), start.AddHours(2)];
                string pathname = "/Round28/Quality-" + irregular + "-" + saveAsFloat
                    + "/Flow/10Apr2025/" + (irregular ? "IR-Day" : "1Hour") + "/TwoWords/";
                int[] qualities = [11, 12, 21, 22, 31, 32];
                using (var writer = new DssWriter(path))
                {
                    var series = new TimeSeries(new DssPath(pathname), [1.25, Missing, 3.75], start, "CFS", "INST-VAL")
                    { Times = times, Qualities = qualities };
                    Check(writer.Write(series, saveAsFloat) == 0,
                        "Native storage accepts two quality words per value for " + pathname);
                }
                DssCatalogResponse catalog = DssRecordService.Catalog(new(path));
                DssRecordDescriptor descriptor = Record(catalog, pathname,
                    irregular ? "IrregularTimeSeries" : "RegularTimeSeries");
                DssReadResponse read = DssRecordService.Read(new(path, catalog.Revision, [descriptor.Path]));
                DssTimeSeriesData data = Result(read, descriptor.Path, "timeSeries").TimeSeries
                    ?? throw new InvalidOperationException("The quality-variant time series payload was missing.");
                CheckSeries(data, times, [1.25, null, 3.75], qualities, "CFS", "INST-VAL",
                    "Float/double and regular/irregular native storage preserves complete quality rows under "
                    + CultureInfo.CurrentCulture.Name + " for " + pathname);
            }
        }
        finally { CultureInfo.CurrentCulture = priorCulture; }
    }

    private static void WriteRealDssFile(string sourcePath)
    {
        DateTime regularStart = new(2024, 12, 31, 22, 0, 0, DateTimeKind.Unspecified);
        DateTime[] regularTimes = Enumerable.Range(0, 28).Select(index => regularStart.AddHours(index)).ToArray();
        double[] regularValues = Enumerable.Range(0, 28).Select(index => index == 7 ? Missing : index + 0.25).ToArray();
        int[] regularQualities = Enumerable.Range(0, 28).Select(index => index + 10).ToArray();
        DateTime secondStart = new(2025, 1, 2, 0, 0, 0, DateTimeKind.Unspecified);
        DateTime[] secondTimes = Enumerable.Range(0, 3).Select(index => secondStart.AddHours(index)).ToArray();
        DateTime irregularStart = new(2024, 12, 31, 23, 59, 40, DateTimeKind.Unspecified);
        DateTime[] irregularTimes = [irregularStart, irregularStart.AddSeconds(7), irregularStart.AddSeconds(55),
            irregularStart.AddSeconds(61), irregularStart.AddSeconds(90)];
        double[] irregularValues = [2.5, 4.5, Missing, 8.5, 10.5];
        int[] irregularQualities = [31, 32, 33, 34, 35];

        using var writer = new DssWriter(sourcePath);
        WriteTimeSeries(writer, new TimeSeries(new DssPath(RegularReachAPath), regularValues,
            regularStart, "CFS", "INST-VAL")
        {
            Times = regularTimes,
            Qualities = regularQualities
        }, "Cross-date regular time series");
        WriteTimeSeries(writer, new TimeSeries(new DssPath(RegularReachBPath), [91.5, 92.5, 93.5],
            secondStart, "CFS", "INST-VAL")
        {
            Times = secondTimes
        }, "Same-name regular time series at another path");
        WriteTimeSeries(writer, new TimeSeries(new DssPath(IrregularPath), irregularValues,
            irregularStart, "FT", "INST-VAL")
        {
            Times = irregularTimes,
            Qualities = irregularQualities
        }, "Irregular time series");

        var paired = new PairedData([0, 5, 10], new List<double[]>
        {
            new double[] { 10, 20, 30 },
            new double[] { 15, 25, 35 }
        }, ["Low Flow", "High Flow"], "FT", "STAGE", "CFS", "FLOW", PairedPath);
        writer.Write(paired);
        int locationStatus = writer.StoreLocation(PairedPath, new LocationInformation
        {
            XOrdinate = 500123.25,
            YOrdinate = 3765432.75,
            ZOrdiante = 18.5,
            CoordinateSystem = CoordinateSystem.UTM,
            CoordinateID = 26910,
            HorizontalUnits = 3,
            HorizontalDatum = 4,
            VerticalUnits = 5,
            VerticalDatum = 6,
            TimeZoneName = "America/Los_Angeles",
            Supplemental = "round28-position-fields"
        }, overwrite: true);
        Check(locationStatus == 0, "The retained writer stores paired-record location metadata");
    }

    private static void WriteTimeSeries(DssWriter writer, TimeSeries series, string description)
    {
        int status = writer.Write(series);
        Check(status == 0, description + " write succeeds with native status 0 (actual status " + status + ")");
    }

    private static string NewFixtureDirectory()
    {
        string? requested = Environment.GetEnvironmentVariable("HECRAS_DSS_ACCEPTANCE_DIRECTORY");
        string root = FindRepositoryRoot();
        string directory = string.IsNullOrWhiteSpace(requested)
            ? Path.Combine(root, "backend", "build", FixtureFolderName)
            : Path.IsPathFullyQualified(requested) ? Path.GetFullPath(requested) : Path.GetFullPath(requested, root);
        if (Directory.Exists(directory) || File.Exists(directory))
            throw new IOException("The DSS acceptance fixture directory already exists; refusing to overwrite it: " + directory);
        Directory.CreateDirectory(directory);
        return directory;
    }

    private static string FindRepositoryRoot()
    {
        foreach (string start in new[] { Directory.GetCurrentDirectory(), AppContext.BaseDirectory })
        {
            DirectoryInfo? current = new(Path.GetFullPath(start));
            while (current is not null)
            {
                if (File.Exists(Path.Combine(current.FullName, "backend", "Tests", "Ras.Backend.Tests.csproj")))
                    return current.FullName;
                current = current.Parent;
            }
        }
        throw new DirectoryNotFoundException("Could not locate the HEC-RAS repository root for the DSS fixture.");
    }

    private static DssRecordDescriptor Record(DssCatalogResponse catalog, string pathname, string expectedType)
    {
        DssPath expected = new(pathname);
        DssRecordDescriptor[] matches = catalog.Records.Where(item =>
        {
            return string.Equals(item.Parts[0], expected.Apart, StringComparison.OrdinalIgnoreCase)
                && string.Equals(item.Parts[1], expected.Bpart, StringComparison.OrdinalIgnoreCase)
                && string.Equals(item.Parts[2], expected.Cpart, StringComparison.OrdinalIgnoreCase)
                && string.Equals(item.Parts[4], expected.Epart, StringComparison.OrdinalIgnoreCase)
                && string.Equals(item.Parts[5], expected.Fpart, StringComparison.OrdinalIgnoreCase);
        }).ToArray();
        DssRecordDescriptor record = matches.SingleOrDefault()
            ?? throw new InvalidOperationException("DSS catalog omitted the expected real record: " + pathname);
        Check(record.RecordType == expectedType,
            "DSS record type for " + pathname + " is " + expectedType + " (actual " + record.RecordType + ")");
        return record;
    }

    private static DssRecordResult Result(DssReadResponse response, string pathname, string expectedKind)
    {
        DssRecordResult record = response.Records.SingleOrDefault(item => item.Path == pathname)
            ?? throw new InvalidOperationException("DSS read omitted the selected record: " + pathname);
        Check(record.Kind == expectedKind && record.Error is null,
            "DSS record read returned " + expectedKind + " data for " + pathname + " (kind "
            + record.Kind + ", error " + record.Error + ")");
        return record;
    }

    private static void CheckSeries(DssTimeSeriesData actual, DateTime[] expectedTimes,
        double?[] expectedValues, int[] expectedQualities, string units, string dataType, string description)
    {
        DateTime[] actualTimes = actual.Times.Select(value => DateTime.ParseExact(value,
            "yyyy-MM-dd'T'HH:mm:ss.fffffff", CultureInfo.InvariantCulture, DateTimeStyles.None)).ToArray();
        Check(actualTimes.SequenceEqual(expectedTimes)
            && actual.Values.SequenceEqual(expectedValues)
            && actual.Qualities is not null && actual.Qualities.SequenceEqual(expectedQualities)
            && actual.Units == units && actual.DataType == dataType, description);
    }

    private static void CheckStaleRevisionIsRejected(string sourcePath, string recordPath)
    {
        string directory = Path.Combine(Path.GetTempPath(), "HECRAS-DSS-stale-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        try
        {
            string stalePath = Path.Combine(directory, "stale.dss");
            File.Copy(sourcePath, stalePath);
            DssCatalogResponse staleCatalog = DssRecordService.Catalog(new DssCatalogRequest(stalePath));
            using (var stream = new FileStream(stalePath, FileMode.Append, FileAccess.Write, FileShare.None))
                stream.WriteByte(0x52);
            Expect<InvalidOperationException>(() => DssRecordService.Read(new DssReadRequest(stalePath,
                staleCatalog.Revision, [recordPath])),
                "A changed DSS source hash is rejected before any record is read");
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    private static void Expect<TException>(Action action, string description) where TException : Exception
    {
        try { action(); }
        catch (TException) { return; }
        throw new InvalidOperationException("DSS source regression failed: " + description
            + "; expected " + typeof(TException).Name + ".");
    }

    private static void Check(bool condition, string description)
    {
        if (!condition) throw new InvalidOperationException("DSS source regression failed: " + description);
    }
}
