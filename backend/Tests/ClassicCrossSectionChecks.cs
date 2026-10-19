using System.Security.Cryptography;
using System.Text.Json;
using Geospatial.PairedData;
using Geospatial.Vectors;
using Ras.Backend;
using Ras.Hydraulics;
using Ras.Layers.Classic;

internal static class ClassicCrossSectionChecks
{
    public static void Run()
    {
        string directory = Path.Combine(Path.GetTempPath(), "classic-cross-section-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        try
        {
            string path = Path.Combine(directory, "Classic profiles.h5");
            using (ClassicGeometry geometry = ClassicGeometry.CreateInMemory("Classic profiles"))
            {
                CrossSection overridden = Section("Repeated name", "Reach A", "10", [5, 0, 6]);
                overridden.OverrideStationElevation = new StationElevationProfile([0, 10, 20], [9, 4, 10]);
                overridden.BankProperties.LeftStation = 5; overridden.BankProperties.RightStation = 15;
                geometry.CrossSectionLayer.Add(overridden);
                geometry.CrossSectionLayer.Add(Section("Repeated name", "Reach B", "10", [3, 2, 3]));
                CrossSection empty = Section("Empty section", "Reach B", "20", [0, 0, 0], persistOverride: false);
                // StationElevation is transient in the retained FeatureIO schema.
                // An unsaved computation profile must not be fabricated on reopen.
                geometry.CrossSectionLayer.Add(empty);
                CrossSection gaps = Section("Profile gaps", "Reach B", "30", [3, 2, 3]);
                gaps.OverrideStationElevation = new StationElevationProfile([0, double.NaN, 20], [3, 2, double.NaN]);
                geometry.CrossSectionLayer.Add(gaps);
                CrossSection emptyWithBanks = Section("Empty with valid banks", "Reach B", "40", [0, 0, 0]);
                emptyWithBanks.OverrideStationElevation = new StationElevationProfile();
                emptyWithBanks.BankProperties.LeftStation = 5; emptyWithBanks.BankProperties.RightStation = 15;
                geometry.CrossSectionLayer.Add(emptyWithBanks);
                for (int index = 5; index < 260; index++)
                    geometry.CrossSectionLayer.Add(Section("Page section", "Reach C", index.ToString(System.Globalization.CultureInfo.InvariantCulture), [5, 1, 5]));
                geometry.SaveAs(path);
            }
            byte[] original = File.ReadAllBytes(path);
            string revision = Convert.ToHexString(SHA256.HashData(original));
            string scope = Guid.NewGuid().ToString();
            ClassicCrossSectionCatalog first = ClassicCrossSectionService.Catalog(new(scope, path, revision, Limit: 1));
            Check(first.TotalCount == 260 && first.Rows.Length == 1 && first.NextOffset == 1,
                "Classic source table uses real paged rows, including duplicate display names");
            ClassicCrossSectionCatalog second = ClassicCrossSectionService.Catalog(new(scope, path, revision, Offset: 1, Limit: 1));
            Check(first.ContextToken == second.ContextToken && first.Rows[0].NodeName == second.Rows[0].NodeName
                && first.Rows[0].RowToken != second.Rows[0].RowToken && second.Rows[0].Ordinal == 1,
                "Duplicate names retain revision-bound source ordinals and independent identities");
            ClassicCrossSectionRow row = first.Rows[0];
            var request = new ClassicCrossSectionProfileRequest(scope, path, revision, first.ContextToken, row.Ordinal, row.RowToken);
            ClassicCrossSectionProfile loaded = ClassicCrossSectionService.Profile(request);
            Check(loaded.HasProfile && loaded.Row.UsesOverride && loaded.Points.Select(point => point.Elevation).SequenceEqual(new double?[] { 9, 4, 10 }),
                "The computation profile uses the saved override ahead of the original source stations/elevations");
            Check(loaded.Banks.Select(point => point.Station).SequenceEqual(new double?[] { 5, 15 })
                && loaded.Banks.Select(point => point.Elevation).SequenceEqual(new double?[] { 6.5, 7 }),
                "Bank elevations use the retained StationElevationProfile.Sample at actual bank stations");
            ClassicCrossSectionProfile noBanks = ClassicCrossSectionService.Profile(request with
            { RowOrdinal = 1, RowToken = second.Rows[0].RowToken });
            Check(noBanks.Row.UsesOverride && noBanks.Banks.Length == 0 && noBanks.Points[1].Elevation == 2,
                "A source section without valid bank stations has no invented bank points");
            ClassicCrossSectionCatalog remaining = ClassicCrossSectionService.Catalog(new(scope, path, revision, Offset: 2));
            ClassicCrossSectionRow emptyRow = remaining.Rows[0], gapsRow = remaining.Rows[1];
            ClassicCrossSectionProfile emptyProfile = ClassicCrossSectionService.Profile(request with
            { RowOrdinal = emptyRow.Ordinal, RowToken = emptyRow.RowToken });
            Check(emptyProfile.Points.Length == 0 && emptyProfile.Banks.Length == 0,
                "Transient computation samples are not invented when the saved source has no profile samples");
            ClassicCrossSectionProfile gapProfile = ClassicCrossSectionService.Profile(request with
            { RowOrdinal = gapsRow.Ordinal, RowToken = gapsRow.RowToken });
            Check(gapProfile.Points.Length == 3 && gapProfile.Points[1].Station is null
                && gapProfile.Points[2].Elevation is null,
                "Nonfinite source values preserve ordinal gaps instead of fabricated finite samples");
            ClassicCrossSectionRow emptyBanksRow = remaining.Rows[2];
            ClassicCrossSectionProfile emptyBanks = ClassicCrossSectionService.Profile(request with
            { RowOrdinal = emptyBanksRow.Ordinal, RowToken = emptyBanksRow.RowToken });
            Check(emptyBanks.HasProfile && emptyBanks.Points.Length == 0
                && emptyBanks.Banks.Select(point => point.Station).SequenceEqual(new double?[] { 5, 15 })
                && emptyBanks.Banks.Select(point => point.Elevation).SequenceEqual(new double?[] { 0, 0 }),
                "An empty retained profile with valid banks keeps Sample's actual ReturnZero extrapolation behavior");
            _ = JsonSerializer.Serialize(gapProfile, BackendJson.Options);
            Expect<SourceFileChangedException>(() => ClassicCrossSectionService.Profile(request with { ScopeID = Guid.NewGuid().ToString() }));
            Expect<SourceFileChangedException>(() => ClassicCrossSectionService.Profile(request with { RowOrdinal = 1 }));
            Expect<SourceFileChangedException>(() => ClassicCrossSectionService.Catalog(new(scope, path, new string('0', 64))));
            Expect<ArgumentOutOfRangeException>(() => ClassicCrossSectionService.Catalog(new(scope, path, revision, Limit: 0)));

            string alias = Path.Combine(directory, "Classic alias.h5");
            File.CreateSymbolicLink(alias, path);
            ClassicCrossSectionCatalog aliased = ClassicCrossSectionService.Catalog(new(scope, alias, revision));
            Check(aliased.SourcePath == first.SourcePath && aliased.ContextToken == first.ContextToken,
                "An HDF alias resolves to the same physical ClassicGeometry source identity");
            Check(File.ReadAllBytes(path).SequenceEqual(original), "Catalog, selection, profile and failed reads leave the HDF unchanged");
            File.Delete(alias);
            ExportIfRequested(directory, path, revision);
            using (var file = new FileStream(path, FileMode.Append, FileAccess.Write)) file.WriteByte(0);
            Expect<SourceFileChangedException>(() => ClassicCrossSectionService.Profile(request));
        }
        finally { Directory.Delete(directory, recursive: true); }
    }

    private static CrossSection Section(string name, string reach, string station, double[] elevations, bool persistOverride = true)
    {
        var section = new CrossSection(new Polyline(new Point[] { new(0, 0), new(20, 0) }))
        {
            NodeName = name, RiverName = "Source river", ReachName = reach, RiverStation = station,
            Description = "Original source cross-section fixture",
            StationElevation = new StationElevationProfile([0, 10, 20], elevations)
        };
        if (persistOverride) section.OverrideStationElevation = new StationElevationProfile([0, 10, 20], elevations);
        section.BankProperties.LeftStation = double.NaN; section.BankProperties.RightStation = double.NaN;
        return section;
    }
    private static void ExportIfRequested(string directory, string path, string revision)
    {
        string? destination = Environment.GetEnvironmentVariable("HECRAS_CROSS_SECTION_ACCEPTANCE_DIRECTORY");
        if (string.IsNullOrWhiteSpace(destination)) return;
        if (Directory.Exists(destination) || File.Exists(destination))
            throw new IOException("Refusing to overwrite a Classic cross-section acceptance fixture.");
        Directory.CreateDirectory(destination);
        File.Copy(path, Path.Combine(destination, Path.GetFileName(path)));
        File.WriteAllText(Path.Combine(destination, "manifest.json"), JsonSerializer.Serialize(new
        { source = "retained ClassicGeometry/FeatureIO.SaveAs", sourceFile = Path.GetFileName(path), sourceRevision = revision, rowCount = 260, solverOutput = false }, BackendJson.Options));
        Check(Directory.GetFiles(directory).Length == 1, "Read-only profile services create no HDF sidecar files");
    }
    private static void Check(bool condition, string message)
    { if (!condition) throw new InvalidOperationException(message); }
    private static void Expect<T>(Action action) where T : Exception
    {
        try { action(); } catch (T) { return; }
        throw new InvalidOperationException("Expected " + typeof(T).Name);
    }
}
