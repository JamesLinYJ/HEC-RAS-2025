using Geospatial.GDALAssist;
using Geospatial.IO;
using Ras.Backend;
using Ras.Layers;

internal static class ProjectionChecks
{
    public static void Run()
    {
        using (var reader = new ProjDBReader())
        {
            Check(reader.DatabasePath.StartsWith(AppContext.BaseDirectory, StringComparison.Ordinal) && File.Exists(reader.DatabasePath), "PROJ database resolves inside the actual package build layout");
            Console.WriteLine("Portable projection catalogue SQLite runtime: " + reader.SQLiteVersion);
        }
        var utm = ProjectionService.Evaluate(new("EPSG", "32650"));
        Check(utm.IsValid && utm.Units == "SI" && utm.EpsgCode == 32650 && utm.UtmZone == 50, "Actual EPSG evaluation and source unit/zone metadata");
        var utmProjection = new EPSGProjection(32650);
        Check(utm.Validity == utmProjection.IsValid().ToString()
            && utm.IsVertical == utmProjection.IsVertical()
            && utm.IsProjected == utmProjection.IsProjected(),
            "Projection evaluation exposes the retained validation enum and orientation flags separately from definition acceptance");
        Check(MatchesAreaOfUse(utm.AreaOfUse, utmProjection),
            "Projection evaluation carries the exact finite geographic and projected area-of-use bounds");
        var geographicEvaluation = ProjectionService.Evaluate(new("EPSG", "4326"));
        var geographicProjection = new EPSGProjection(4326);
        Check(!geographicEvaluation.IsValid, "Geographic coordinates cannot become a projected hydraulic project");
        Check(geographicEvaluation is { Validity: "Valid", IsProjected: false, EpsgCode: 4326 }
            && geographicEvaluation.UnitName == geographicProjection.GetSanitizedLinearUnitName()
            && MatchesAreaOfUse(geographicEvaluation.AreaOfUse, geographicProjection),
            "A rejected geographic project definition still exposes the constructed projection's real summary without becoming accepted");
        Check(ProjectionService.Evaluate(new("epsg", "32650")).NormalizedType == "EPSG", "Source projection type aliases normalize without changing their meaning");
        Check(!ProjectionService.Evaluate(new("EPSG", "987654321")).IsValid, "Unknown numeric EPSG code rejected by source parser");
        Check(ProjectionService.Evaluate(new("EPSG", "987654321")) is
            { Validity: null, IsVertical: null, IsProjected: null, AreaOfUse: null },
            "An unconstructed unsupported projection has no fabricated summary or bounds");
        Check(ProjectionService.Evaluate(new("Local", "SI")) is
            { IsValid: true, Units: "SI", EpsgCode: null, Validity: null, IsVertical: null, IsProjected: null, AreaOfUse: null },
            "Local metric source definition has no synthetic Projection summary or area");
        Check(!ProjectionService.Evaluate(new("Local", "invalid")).IsValid, "Invalid local units rejected");
        var exact = ProjectionService.Search(new(Query: "EPSG:32650"));
        Check(exact.Length == 1 && exact[0].Id == "EPSG:32650" && exact[0].Name.Contains("UTM zone 50N"), "Numeric EPSG lookup resolves the actual CRS, not an area code");
        Check(ProjectionService.Search(new(Query: "UTM zone 50N")).Any(match => match.Code == 32650), "Canonical CRS names are searchable without aliases");
        Check(ProjectionService.Search(new(Query: "%' OR 1=1 --")).Length == 0, "Projection search treats wildcard/punctuation as literal text");
        var locations = ProjectionService.Search(new(Longitude: 116.4, Latitude: 39.9, Limit: 100));
        Check(locations.Any(match => match.Code == 4548) && locations.Select(match => match.Id).Distinct().Count() == locations.Length, "Location search returns the regional CGCS2000 CRS and deduplicates shared extents");
        Check(!locations.Any(match => match.Code is 3857 or 3395), "Location suggestions retain the source exclusion of World extents");
        foreach (var match in locations.Take(20))
            Check(ProjectionService.Evaluate(new("EPSG", match.Code.ToString())).IsValid, "Location candidate is a real projected CRS: " + match.Id);
        bool rejected = false;
        try { ProjectionService.Search(new(Longitude: 181, Latitude: 0)); } catch (ArgumentOutOfRangeException) { rejected = true; }
        Check(rejected, "Location bounds validated");
        string file = Path.Combine(Path.GetTempPath(), "hecras-projection-" + Guid.NewGuid().ToString("N") + ".prj");
        try
        {
            new EPSGProjection(32650).ExportEsri(file);
            var imported = ProjectionService.Evaluate(new("ESRI", file));
            File.Delete(file);
            Check(imported is { IsValid: true, NormalizedType: "WKT" } && !string.IsNullOrEmpty(imported.NormalizedValue), "PRJ path is read and normalized to an embedded portable definition");
            Check(new ProjectionDefinition(ProjectionType.WKT, imported.NormalizedValue).Evaluate(out _, out _).Result, "Accepted PRJ definition remains valid after the source file is removed");
        }
        finally { if (File.Exists(file)) File.Delete(file); }
    }

    private static bool MatchesAreaOfUse(ProjectionAreaOfUse? actual, Projection projection)
    {
        bool available = projection.TryGetAreaOfUse(out var geographic, out var projected);
        bool allFinite = available
            && double.IsFinite(geographic.Left) && double.IsFinite(geographic.Right)
            && double.IsFinite(geographic.Bottom) && double.IsFinite(geographic.Top)
            && double.IsFinite(projected.Left) && double.IsFinite(projected.Right)
            && double.IsFinite(projected.Bottom) && double.IsFinite(projected.Top);
        if (!allFinite) return actual is null;

        return actual is not null
            && actual.Geographic.Left == geographic.Left
            && actual.Geographic.Right == geographic.Right
            && actual.Geographic.Bottom == geographic.Bottom
            && actual.Geographic.Top == geographic.Top
            && actual.Projected.Left == projected.Left
            && actual.Projected.Right == projected.Right
            && actual.Projected.Bottom == projected.Bottom
            && actual.Projected.Top == projected.Top;
    }

    private static void Check(bool condition, string name) { if (!condition) throw new InvalidOperationException(name); }
}
