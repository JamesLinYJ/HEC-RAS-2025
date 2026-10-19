using System.Globalization;
using Geospatial.GDALAssist;
using Geospatial.Vectors;
using Ras.Backend;
using Ras.Layers;
using Utility.Units;

internal static class ReprojectionChecks
{
    internal static void Run()
    {
        GDALSetup.InitializeMultiplatform();
        CheckWGS84AndWebMercator();
        CheckRowIsolation();
        CheckCurrentCultureParsing();
        CheckExplicitCultureParsing();
        CheckProjectProjectionStates();
        CheckCustomProjectionParsing();
        CheckProjectionFileIdentification();
        Console.WriteLine("Retained reprojection dialog behavior checks passed.");
    }

    private static void CheckWGS84AndWebMercator()
    {
        ReprojectionSnapshot projected = ReprojectionService.TransformReprojection(new(
            "WGS84", "WebMercator", null, null, null,
            [new ReprojectionRowInput("origin-near", "1", "1")]));
        ReprojectionRowResult result = projected.Rows.Single();
        Check(projected.ErrorCode is null && result.Status == "transformed"
            && Near(result.X, 111319.49079327357, 1e-6)
            && Near(result.Y, 111325.1428663851, 1e-6),
            "WGS84 to WebMercator uses retained Projector.TransformPoint");
        CheckSummaryMatches(projected.SourceProjectionSummary, WellKnownProjections.WGS84, "WGS84", "WGS84 source summary");
        CheckSummaryMatches(projected.DestinationProjectionSummary, WellKnownProjections.WebMercator, "WebMercator", "WebMercator destination summary");

        ReprojectionSnapshot geographic = ReprojectionService.TransformReprojection(new(
            "WebMercator", "WGS84", null, null, null,
            [new ReprojectionRowInput("round-trip", "111319.49079327357", "111325.1428663851")]));
        ReprojectionRowResult inverse = geographic.Rows.Single();
        Check(geographic.ErrorCode is null && inverse.Status == "transformed"
            && Near(inverse.X, 1, 1e-6) && Near(inverse.Y, 1, 1e-6),
            "WebMercator to WGS84 retains inverse native projection behavior");
    }

    private static void CheckRowIsolation()
    {
        ReprojectionSnapshot snapshot = ReprojectionService.TransformReprojection(new(
            "WGS84", "WebMercator", null, null, null,
            [
                new ReprojectionRowInput("valid", "0", "0"),
                new ReprojectionRowInput("nan", "NaN", "4"),
                new ReprojectionRowInput("empty", "", "4"),
                new ReprojectionRowInput("invalid", "not a coordinate", "4"),
                new ReprojectionRowInput("valid-after-error", "2", "3")
            ]));

        Check(snapshot.ErrorCode is null && snapshot.Rows.Select(row => row.ID)
                .SequenceEqual(["valid", "nan", "empty", "invalid", "valid-after-error"]),
            "Rows retain stable IDs and input order");
        Check(snapshot.Rows[0].Status == "transformed" && snapshot.Rows[0].X == 0 && snapshot.Rows[0].Y == 0,
            "A valid row before an invalid cell transforms");
        Check(snapshot.Rows[1].Status == "blank" && snapshot.Rows[1].X is null && snapshot.Rows[1].Y is null
            && snapshot.Rows[2].Status == "blank" && snapshot.Rows[2].X is null && snapshot.Rows[2].Y is null,
            "NaN and blank source cells become blank destination cells");
        Check(snapshot.Rows[3].Status == "invalid" && snapshot.Rows[3].X is null && snapshot.Rows[3].Y is null,
            "An unparseable raw coordinate clears only its own row");
        Check(snapshot.Rows[4].Status == "transformed" && Near(snapshot.Rows[4].X, 222638.98158654713, 1e-6),
            "A valid row after an invalid cell is still transformed");
    }

    private static void CheckProjectProjectionStates()
    {
        ReprojectionSnapshot absent = ReprojectionService.TransformReprojection(new(
            "WGS84", "Project", null, null, null,
            [new ReprojectionRowInput("row", "1", "1")]));
        Check(absent.ErrorCode == "noProjectDestination" && absent.Rows.Single().Status == "unavailable"
            && absent.Rows.Single().X is null && absent.Rows.Single().Y is null,
            "Selecting Project without a projection clears destination output without claiming success");
        CheckSummaryMatches(absent.SourceProjectionSummary, WellKnownProjections.WGS84, "WGS84", "Unavailable destination retains real source summary");
        Check(absent.DestinationProjectionSummary is null,
            "A missing project projection has no synthetic destination summary or area bounds");

        ReprojectionSnapshot local = ReprojectionService.TransformReprojection(new(
            "Project", "WGS84", new ProjectionRequest("Local", "SI"), null, null,
            [new ReprojectionRowInput("local", "100", "200")]));
        Check(local.ErrorCode == "noProjectSource" && local.Rows.Single().Status == "unavailable",
            "A Local project has units but no spatial transform, matching the source VM's null projection");

        ReprojectionSnapshot geographicProject = ReprojectionService.TransformReprojection(new(
            "Project", "WGS84", new ProjectionRequest("EPSG", "4326"), null, null,
            [new ReprojectionRowInput("geographic", "1", "1")]));
        Check(geographicProject.ErrorCode == "invalidProjectProjection"
            && geographicProject.Rows.Single().Status == "unavailable",
            "Project projection definitions retain projected-coordinate and unit validation");

        ReprojectionSnapshot validProject = ReprojectionService.TransformReprojection(new(
            "Project", "WGS84", new ProjectionRequest("EPSG", "32650"), null, null,
            [new ReprojectionRowInput("utm-center", "500000", "0")]));
        Check(validProject.ErrorCode is null && validProject.Rows.Single().Status == "transformed"
            && Near(validProject.Rows.Single().X, 117, 1e-5)
            && Near(validProject.Rows.Single().Y, 0, 1e-5),
            "A valid projected project definition is evaluated before transformation");
    }

    private static void CheckCurrentCultureParsing()
    {
        CultureInfo originalCulture = CultureInfo.CurrentCulture;
        try
        {
            CultureInfo.CurrentCulture = CultureInfo.GetCultureInfo("en-US");
            ReprojectionSnapshot grouped = ReprojectionService.TransformReprojection(new(
                "WebMercator", "WebMercator", null, null, null,
                [new ReprojectionRowInput("grouped", "1,000", "2,000")]));
            Check(grouped.ErrorCode is null && grouped.Rows.Single().Status == "transformed"
                && Near(grouped.Rows.Single().X, 1000, 1e-9)
                && Near(grouped.Rows.Single().Y, 2000, 1e-9),
                "Coordinate cells use the current culture's default grouping parser");

            CultureInfo.CurrentCulture = CultureInfo.GetCultureInfo("fr-FR");
            ReprojectionSnapshot decimalComma = ReprojectionService.TransformReprojection(new(
                "WGS84", "WebMercator", null, null, null,
                [new ReprojectionRowInput("decimal-comma", "1,5", "2,5")]));
            Check(decimalComma.ErrorCode is null && decimalComma.Rows.Single().Status == "transformed"
                && Near(decimalComma.Rows.Single().X, 166979.23618991036, 1e-6)
                && Near(decimalComma.Rows.Single().Y, 278387.0759542351, 1e-6),
                "Coordinate cells use the current culture's decimal separator");

            ReprojectionSnapshot customEPSG = ReprojectionService.TransformReprojection(new(
                "Custom", "WebMercator", null, "4326", null,
                [new ReprojectionRowInput("custom-epsg-current-culture", "1,5", "2,5")]));
            Check(customEPSG.ErrorCode is null && customEPSG.Rows.Single().Status == "transformed"
                && Near(customEPSG.Rows.Single().X, 166979.23618991036, 1e-6)
                && Near(customEPSG.Rows.Single().Y, 278387.0759542351, 1e-6),
                "Custom EPSG input follows default int.TryParse while coordinates follow default double.TryParse");
        }
        finally
        {
            CultureInfo.CurrentCulture = originalCulture;
        }
    }

    private static void CheckExplicitCultureParsing()
    {
        CultureInfo originalCulture = CultureInfo.CurrentCulture;
        try
        {
            CultureInfo.CurrentCulture = CultureInfo.GetCultureInfo("en-US");
            ReprojectionSnapshot explicitFrench = ReprojectionService.TransformReprojection(new(
                "WGS84", "WebMercator", null, null, null,
                [new ReprojectionRowInput("explicit-fr", "1,5", "2,5")],
                NumberCulture: "fr-FR"));
            Check(explicitFrench.ErrorCode is null && explicitFrench.Rows.Single().Status == "transformed"
                && Near(explicitFrench.Rows.Single().X, 166979.23618991036, 1e-6)
                && Near(explicitFrench.Rows.Single().Y, 278387.0759542351, 1e-6),
                "A request's explicit BCP-47 culture overrides backend CurrentCulture without changing the process setting");

            ReprojectionSnapshot unsupported = ReprojectionService.TransformReprojection(new(
                "WGS84", "WebMercator", null, null, null,
                [new ReprojectionRowInput("unsupported-culture", "1", "2")],
                NumberCulture: "invalid/culture"));
            Check(unsupported.ErrorCode == "unsupportedNumberCulture"
                && unsupported.ErrorMessage == "The requested number culture is not supported."
                && unsupported.Rows.Single().Status == "unavailable"
                && unsupported.Rows.Single().X is null && unsupported.Rows.Single().Y is null,
                "Unsupported number cultures return a structured unavailable response rather than silently falling back");
            Check(CultureInfo.CurrentCulture.Name == "en-US",
                "Per-request culture parsing does not mutate the backend process culture");
        }
        finally
        {
            CultureInfo.CurrentCulture = originalCulture;
        }
    }

    private static void CheckCustomProjectionParsing()
    {
        ReprojectionSnapshot customEPSG = ReprojectionService.TransformReprojection(new(
            "Custom", "WGS84", null, "4326", null,
            [new ReprojectionRowInput("custom-epsg", "1", "1")]));
        Check(customEPSG.ErrorCode is null && customEPSG.Rows.Single().Status == "transformed"
            && Near(customEPSG.Rows.Single().X, 1, 1e-6) && Near(customEPSG.Rows.Single().Y, 1, 1e-6),
            "A numeric custom definition follows the source EPSG parser path");

        ReprojectionSnapshot invalid = ReprojectionService.TransformReprojection(new(
            "Custom", "WGS84", null, "not a valid projection", null,
            [new ReprojectionRowInput("invalid-custom", "1", "1")]));
        Check(invalid.ErrorCode == "invalidCustomSource" && invalid.Rows.Single().Status == "unavailable"
            && invalid.Rows.Single().X is null && invalid.Rows.Single().Y is null,
            "Invalid custom WKT is reported as unavailable and never serialized as NaN");
    }

    private static void CheckProjectionFileIdentification()
    {
        using var directory = new TemporaryDirectory();
        string unknownPath = Path.Combine(directory.FullName, "not a projection.txt");
        File.WriteAllText(unknownPath, "not a recognized projection source");
        string prjPath = Path.Combine(directory.FullName, "identified.prj");
        new EPSGProjection(32650).ExportEsri(prjPath);
        string projectPath = Path.Combine(directory.FullName, "identified.ras");
        _ = Project.CreateNew(projectPath, new ProjectionDefinition(ProjectionType.EPSG, "32650"));
        byte[] prjBytes = File.ReadAllBytes(prjPath);
        byte[] projectBytes = File.ReadAllBytes(projectPath);

        ReprojectionIdentifySnapshot unidentified = ReprojectionService.IdentifyProjection(new([unknownPath]));
        Check(unidentified.RecognizedPath is null && unidentified.Wkt is null && unidentified.ProjectionSummary is null,
            "Unrecognized dropped files do not fabricate a projection");

        ReprojectionIdentifySnapshot identified = ReprojectionService.IdentifyProjection(new([unknownPath, prjPath, projectPath]));
        Projection retainedPrj = Ras.GeospatialHelpers.TryIdentifyProjection(prjPath)
            ?? throw new InvalidOperationException("The retained helper did not recognize the generated PRJ fixture.");
        Check(identified.RecognizedPath == prjPath
            && identified.Wkt == retainedPrj.GetWKT(),
            "File-drop identification returns the first retained-recognized PRJ in input order with the retained WKT");
        CheckSummaryMatches(identified.ProjectionSummary, retainedPrj, "Custom", "identified PRJ");

        ReprojectionSnapshot transformedFromIdentified = ReprojectionService.TransformReprojection(new(
            "Custom", "WebMercator", null, identified.Wkt, null,
            [new ReprojectionRowInput("identified-prj-transform", "1", "1")]));
        Point retainedTransform = Projector.TransformPoint(retainedPrj, WellKnownProjections.WebMercator, new Point(1, 1));
        Check(transformedFromIdentified.Rows.Single().Status == "transformed"
            && Near(transformedFromIdentified.Rows.Single().X, retainedTransform.X, 1e-6)
            && Near(transformedFromIdentified.Rows.Single().Y, retainedTransform.Y, 1e-6),
            "The identified WKT transforms equivalently to the projection returned by the retained helper");

        ReprojectionIdentifySnapshot project = ReprojectionService.IdentifyProjection(new([projectPath]));
        Projection retainedProject = Ras.GeospatialHelpers.TryIdentifyProjection(projectPath)
            ?? throw new InvalidOperationException("The retained helper did not recognize the generated RAS project fixture.");
        Check(project.RecognizedPath == projectPath
            && project.Wkt == retainedProject.GetWKT(),
            "A retained RAS project file supplies the exact projection definition returned by the retained helper");
        CheckSummaryMatches(project.ProjectionSummary, retainedProject, "Custom", "identified RAS project");
        Check(File.ReadAllBytes(prjPath).SequenceEqual(prjBytes)
            && File.ReadAllBytes(projectPath).SequenceEqual(projectBytes),
            "Projection file identification reads source files without writing them");
    }

    private static void CheckSummaryMatches(
        ReprojectionProjectionSummary? actual,
        Projection projection,
        string option,
        string context)
    {
        bool hasEPSG = projection.TryGetEPSGCode(out int epsg);
        bool hasUTM = projection.TryGetUTMZone(out int zone);
        var expected = new ReprojectionProjectionSummary(option, projection.GetName(),
            projection.IsValid().ToString(), projection.GetSanitizedLinearUnitName(),
            projection.IsVertical(), projection.IsProjected(),
            hasEPSG ? epsg.ToString(CultureInfo.InvariantCulture) : null,
            hasUTM ? zone.ToString(CultureInfo.InvariantCulture) : null,
            ExpectedAreaOfUse(projection));
        Check(actual == expected,
            $"{context}: typed summary should match retained getters; expected {expected}, got {actual?.ToString() ?? "<null>"}");
    }

    private static ProjectionAreaOfUse? ExpectedAreaOfUse(Projection projection)
    {
        if (!projection.TryGetAreaOfUse(out var geographic, out var projected)) return null;
        if (!double.IsFinite(geographic.Left) || !double.IsFinite(geographic.Right)
            || !double.IsFinite(geographic.Bottom) || !double.IsFinite(geographic.Top)
            || !double.IsFinite(projected.Left) || !double.IsFinite(projected.Right)
            || !double.IsFinite(projected.Bottom) || !double.IsFinite(projected.Top))
            return null;

        return new ProjectionAreaOfUse(
            new ProjectionAreaBounds(geographic.Left, geographic.Right, geographic.Bottom, geographic.Top),
            new ProjectionAreaBounds(projected.Left, projected.Right, projected.Bottom, projected.Top));
    }

    private static bool Near(double? actual, double expected, double tolerance) =>
        actual is double value && double.IsFinite(value) && Math.Abs(value - expected) <= tolerance;

    private static void Check(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }
}
