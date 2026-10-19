using System.Globalization;
using System.Reflection;
using Ras.Backend;
using Ras.Hydraulics.HydraulicDesign;

internal static class WilcockChecks
{
    internal static void Run()
    {
        CheckDefaultsAndCompleteOutputs();
        CheckCultureAndSectionIsolation();
        CheckCaseOperations();
        CheckImportConfirmationAndSourceSemantics();
        CheckUnsupportedCultureIsRejected();
        Console.WriteLine("Retained Wilcock calculators, tables, culture and case import checks passed.");
    }

    private static void CheckDefaultsAndCompleteOutputs()
    {
        WilcockWorkspaceSnapshot snapshot = WilcockService.Load(new WilcockLoadRequest("en-US"));
        WilcockDraft draft = snapshot.Draft;
        WilcockSbtmDraft sbtm = Required(draft.Sbtm, "SBTM defaults");
        WilcockIsbtmDraft isbtm = Required(draft.Isbtm, "ISBTM defaults");
        WilcockStabDraft stab = Required(draft.Stab, "STAB defaults");
        WilcockStateDraft state = Required(draft.State, "STATE defaults");
        string[] sbtmGrains = Required(sbtm.GrainDiameter, "SBTM grain diameter");
        string[] sbtmCDF = Required(sbtm.SurfaceCdf, "SBTM surface CDF");
        string[] isbtmGrains = Required(isbtm.GrainDiameter, "ISBTM grain diameter");
        string[] isbtmCDF = Required(isbtm.TransportCdf, "ISBTM transport CDF");
        string[] stabGrains = Required(stab.GrainDiameter, "STAB grain diameter");
        string[][] stabCases = Required(stab.TransportGrainSizes, "STAB transport grain sizes");
        string[] stateGrains = Required(state.GrainDiameter, "STATE grain diameter");
        string[] stateFirstCDF = Required(state.FirstTransportCdfGrainSize, "STATE first CDF");
        string[] stateSecondCDF = Required(state.SecondTransportCdfGrainSize, "STATE second CDF");
        string[] stateRates = Required(state.TransportRates, "STATE transport rates");
        string[] stateSlopes = Required(state.Slopes, "STATE slopes");
        Check(sbtmGrains.Length == 18 && sbtmCDF.Length == 18,
            "The SBTM source defaults retain all 18 grain and CDF values");
        Check(isbtmGrains.Length == 18 && isbtmCDF.Length == 18,
            "The ISBTM source defaults retain all 18 grain and CDF values");
        Check(stabGrains.Length == 18 && stabCases.Length == 2,
            "The STAB source defaults retain its 18-point grain grid and two transport cases");
        Check(stateGrains.Length == 19 && stateFirstCDF.Length == 17 && stateSecondCDF.Length == 19,
            "The STATE source defaults preserve the distinct 19/17/19 input lengths");
        Check(stateRates.Length == 22 && stateSlopes.Length == 10,
            "The STATE transport-rate and slope arrays retain their independent source lengths");

        Check(snapshot.Charts.Select(chart => chart.ID).SequenceEqual(
                new[] { "btm", "state", "stab.0", "stab.1", "stab.2", "stab.3", "stab.4", "stab.5", "stab.6", "stab.7" }),
            "The response exposes each retained BTM, STATE and eight STAB charts");
        Check(snapshot.Charts.SelectMany(chart => new[] { chart.TitleKey, chart.XAxisKey, chart.YAxisKey }
                .Concat(chart.Series.Select(series => series.LabelKey)))
                .All(value => !value.Contains("wilcock.", StringComparison.Ordinal)),
            "Chart labels are presentation text rather than internal IDs");

        string[] tableIDs = snapshot.Tables.Select(table => table.ID).ToArray();
        foreach (string required in new[]
        {
            "btm.sbtm.input", "btm.isbtm.input", "stab.caseInputs", "stab.grainSizeDistributions",
            "state.grainDistributions", "state.transportRates", "state.slopes", "btm.output",
            "stab.outputStatistics", "stab.completeOutput", "state.outputStatistics", "state.completeOutput"
        })
            Check(tableIDs.Contains(required, StringComparer.Ordinal), $"The complete source table {required} is available");

        WilcockSourceTable rates = snapshot.Tables.Single(table => table.ID == "state.transportRates");
        WilcockSourceTable slopes = snapshot.Tables.Single(table => table.ID == "state.slopes");
        Check(rates.Rows.Length == 22 && rates.Rows[0].ID == "value:0"
            && slopes.Rows.Length == 10 && slopes.Rows[0].ID == "value:0",
            "Editable STATE scalar arrays use the stable row identities consumed by the UI");

        CheckCompleteOutputTable(snapshot.Tables.Single(table => table.ID == "btm.output"), typeof(SBTMResults));
        CheckCompleteOutputTable(snapshot.Tables.Single(table => table.ID == "stab.completeOutput"), typeof(StabResults));
        CheckCompleteOutputTable(snapshot.Tables.Single(table => table.ID == "state.completeOutput"), typeof(StateResults));
        WilcockWorkspaceSnapshot isbtmSnapshot = WilcockService.Evaluate(new WilcockEvaluateRequest(
            draft with { BtmMode = "ISBTM" }));
        Check(isbtmSnapshot.Tables.Any(table => table.ID == "btm.output" && table.TitleKey == "ISBTM output and convergence"),
            "The ISBTM mode reports its own complete output and convergence table");
        CheckCompleteOutputTable(isbtmSnapshot.Tables.Single(table => table.ID == "btm.output"), typeof(ISBTMResults));
        CheckStabSurfaceSeriesMatchRetainedResults(snapshot);
        CheckChartGapsPreserveSourceOrdinals(draft);
    }

    private static void CheckStabSurfaceSeriesMatchRetainedResults(WilcockWorkspaceSnapshot snapshot)
    {
        Dictionary<string, object?> results = Required(snapshot.StabResults, "retained STAB results");
        double?[][] sourceDiameters = ReadNumericRows(results, "gSDAtMeanWidthD");
        double?[][] sourceCumulativeFractions = ReadNumericRows(results, "gSDAtMeanWidthFi");
        string[][] sourceCases = Required(Required(snapshot.Draft.Stab, "STAB draft").TransportGrainSizes,
            "STAB transport cases");
        WilcockChart surfaceChart = snapshot.Charts.Single(chart => chart.ID == "stab.3");
        WilcockChartSeries[] surfaceSeries = surfaceChart.Series
            .Where(series => series.LabelKey == "Surface distribution at mean width")
            .ToArray();
        int expectedSeriesCount = Math.Min(sourceCases.Length,
            Math.Min(sourceDiameters.Length, sourceCumulativeFractions.Length));
        Check(expectedSeriesCount > 0, "The retained STAB result includes at least one paired surface distribution");
        Check(surfaceSeries.Length == expectedSeriesCount,
            "The source grain-size chart includes one surface series for each retained case row");

        for (int caseIndex = 0; caseIndex < expectedSeriesCount; caseIndex++)
        {
            WilcockChartSeries series = surfaceSeries.Single(item => item.CaseIndex == caseIndex);
            int expectedPointCount = Math.Min(sourceDiameters[caseIndex].Length,
                sourceCumulativeFractions[caseIndex].Length);
            Check(series.Points.Length == expectedPointCount,
                $"Surface grain-size series {caseIndex} preserves the paired source row length");
            for (int pointIndex = 0; pointIndex < expectedPointCount; pointIndex++)
            {
                WilcockChartPoint point = series.Points[pointIndex];
                Check(point.X == sourceDiameters[caseIndex][pointIndex]
                    && point.Y == sourceCumulativeFractions[caseIndex][pointIndex],
                    $"Surface grain-size series {caseIndex} pairs the retained X/Y values at source index {pointIndex}");
            }
        }
    }

    private static double?[][] ReadNumericRows(Dictionary<string, object?> results, string memberName)
    {
        if (!results.TryGetValue(memberName, out object? raw) || raw is not object?[] rows)
            throw new InvalidOperationException($"The retained STAB result omitted {memberName} rows.");
        var values = new double?[rows.Length][];
        for (int rowIndex = 0; rowIndex < rows.Length; rowIndex++)
        {
            if (rows[rowIndex] is not object?[] cells)
                throw new InvalidOperationException($"The retained STAB result row {memberName}[{rowIndex}] is invalid.");
            values[rowIndex] = new double?[cells.Length];
            for (int cellIndex = 0; cellIndex < cells.Length; cellIndex++)
            {
                if (cells[cellIndex] is null)
                {
                    values[rowIndex][cellIndex] = null;
                    continue;
                }
                if (cells[cellIndex] is not double number || !double.IsFinite(number))
                    throw new InvalidOperationException($"The retained STAB result cell {memberName}[{rowIndex}][{cellIndex}] is invalid.");
                values[rowIndex][cellIndex] = number;
            }
        }
        return values;
    }

    private static void CheckCompleteOutputTable(WilcockSourceTable table, Type resultType)
    {
        PropertyInfo[] properties = resultType.GetProperties(BindingFlags.Instance | BindingFlags.Public)
            .Where(property => property.CanRead && property.GetIndexParameters().Length == 0).ToArray();
        foreach (PropertyInfo property in properties)
        {
            string prefix = $"member:{property.Name}";
            Check(table.Rows.Any(row => row.ID == prefix || row.ID.StartsWith(prefix + ":", StringComparison.Ordinal)),
                $"The {table.ID} table includes the retained result member {property.Name}");
        }
        Check(table.Rows.All(row => row.TitleKey is null || !row.TitleKey.Contains("wilcock.", StringComparison.Ordinal)),
            $"The {table.ID} output row labels are user-facing text");
    }

    private static void CheckCultureAndSectionIsolation()
    {
        WilcockWorkspaceSnapshot localized = WilcockService.Load(new WilcockLoadRequest("de-DE"));
        WilcockSbtmDraft localizedSbtm = Required(localized.Draft.Sbtm, "localized SBTM defaults");
        Check(localized.Draft.NumberCulture == "de-DE" && localizedSbtm.ShearVelocity == "0,2",
            "The default raw numeric text is formatted with the requested number culture");
        WilcockWorkspaceSnapshot localizedResult = WilcockService.Evaluate(new WilcockEvaluateRequest(localized.Draft));
        Check(localizedResult.SbtmResults is not null,
            "The retained calculator accepts defaults parsed with the requested decimal separator");

        WilcockWorkspaceSnapshot initial = WilcockService.Load(new WilcockLoadRequest("en-US"));
        WilcockStateDraft initialState = Required(initial.Draft.State, "initial STATE draft");
        WilcockDraft malformedState = initial.Draft with
        {
            State = initialState with { Slopes = ["not a number"] }
        };
        WilcockWorkspaceSnapshot result = WilcockService.Evaluate(new WilcockEvaluateRequest(malformedState));
        Check(result.StateErrorKey == "Enter a valid number." && result.StateResults is null,
            "Invalid raw STATE input is reported against STATE without being normalized");
        WilcockStateDraft resultState = Required(result.Draft.State, "result STATE draft");
        Check(Required(resultState.Slopes, "result STATE slopes").SequenceEqual(new[] { "not a number" }),
            "Invalid user text remains available for correction");
        Check(result.SbtmResults is not null && result.StabResults is not null,
            "A STATE parse failure does not block independent SBTM or STAB calculations");
    }

    private static void CheckChartGapsPreserveSourceOrdinals(WilcockDraft source)
    {
        WilcockStabDraft sourceStab = Required(source.Stab, "source STAB draft");
        string[][] sourceCDFs = Required(sourceStab.TransportGrainSizes, "source STAB grain cases");
        string[] sourceGrains = Required(sourceStab.GrainDiameter, "source STAB grain grid");
        string[][] cdfs = sourceCDFs.Select(row => row.ToArray()).ToArray();
        cdfs[0][4] = "invalid chart sample";
        WilcockDraft draft = source with
        {
            Stab = sourceStab with
            {
                GrainDiameter = [.. sourceGrains.Take(3), "invalid chart coordinate", .. sourceGrains.Skip(4)],
                TransportGrainSizes = cdfs
            }
        };

        WilcockChartSeries series = WilcockService.Evaluate(new WilcockEvaluateRequest(draft))
            .Charts.Single(chart => chart.ID == "stab.3").Series
            .Single(item => item.CaseIndex == 0);
        Check(series.Points.Length == sourceGrains.Length
            && series.Points[4].X is not null && series.Points[4].Y is null
            && series.Points[3].X is null && series.Points[3].Y is not null,
            "Invalid chart samples remain explicit gaps at their original source ordinals");
    }

    private static void CheckCaseOperations()
    {
        WilcockWorkspaceSnapshot initial = WilcockService.Load(new WilcockLoadRequest("en-US"));
        WilcockStabDraft initialStab = Required(initial.Draft.Stab, "initial STAB draft");
        string[] initialWater = Required(initialStab.WaterDischarges, "initial water discharges");
        string[] initialSupply = Required(initialStab.SedimentSupplyRates, "initial sediment supply rates");
        string[][] initialGrainCases = Required(initialStab.TransportGrainSizes, "initial STAB cases");
        WilcockWorkspaceSnapshot added = WilcockService.Evaluate(new WilcockEvaluateRequest(
            initial.Draft, Action: "addCase"));
        WilcockStabDraft addedStab = Required(added.Draft.Stab, "added STAB draft");
        Check(added.Cases.Length == initial.Cases.Length + 1
            && Required(addedStab.WaterDischarges, "added water discharges").Length == initialWater.Length + 1
            && Required(addedStab.SedimentSupplyRates, "added sediment supply rates").Length == initialSupply.Length + 1
            && Required(addedStab.TransportGrainSizes, "added STAB cases").Length == initialGrainCases.Length + 1,
            "Adding a STAB case appends aligned source arrays and a corresponding row");
        Check(added.Cases[^1].ID == $"case:{added.Cases.Length - 1}"
            && added.Draft.SelectedCaseID == "case:0",
            "STAB case identities remain source-order indices after append");

        WilcockWorkspaceSnapshot removed = WilcockService.Evaluate(new WilcockEvaluateRequest(
            added.Draft, Action: "removeCase", CaseID: "case:1"));
        WilcockStabDraft removedStab = Required(removed.Draft.Stab, "removed STAB draft");
        Check(removed.Cases.Length == added.Cases.Length - 1
            && Required(removedStab.WaterDischarges, "removed water discharges").Length
                == Required(addedStab.WaterDischarges, "added water discharges").Length - 1
            && Required(removedStab.SedimentSupplyRates, "removed sediment supply rates").Length
                == Required(addedStab.SedimentSupplyRates, "added sediment supply rates").Length - 1
            && Required(removedStab.TransportGrainSizes, "removed STAB cases").Length
                == Required(addedStab.TransportGrainSizes, "added STAB cases").Length - 1,
            "Removing a selected STAB case removes that source ordinal from every parallel array");

        string[][] oneCaseCdfs = Required(initialStab.TransportGrainSizes, "initial STAB cases");
        WilcockDraft oneCase = initial.Draft with
        {
            Stab = initialStab with
            {
                WaterDischarges = [initialWater[0]],
                SedimentSupplyRates = [initialSupply[0]],
                TransportGrainSizes = [oneCaseCdfs[0]]
            }
        };
        ExpectArgumentMessage(() => WilcockService.Evaluate(new WilcockEvaluateRequest(
            oneCase, Action: "removeCase", CaseID: "case:0")), "At least one Wilcock case must remain.");
    }

    private static void CheckImportConfirmationAndSourceSemantics()
    {
        WilcockWorkspaceSnapshot initial = WilcockService.Load(new WilcockLoadRequest("en-US"));
        WilcockDraft initialDraft = initial.Draft;
        WilcockSbtmDraft initialSbtm = Required(initialDraft.Sbtm, "initial SBTM draft");
        WilcockStabDraft initialStab = Required(initialDraft.Stab, "initial STAB draft");
        string[][] initialCases = Required(initialStab.TransportGrainSizes, "initial STAB cases");
        string[] initialGrains = Required(initialStab.GrainDiameter, "initial STAB grain grid");
        WilcockDraft importDraft = initial.Draft with
        {
            // Both values are not read by the retained import action. Their
            // invalid raw text must not disable importing a valid BTM curve.
            Sbtm = initialSbtm with { WaterDensity = "invalid unrelated value" },
            Stab = initialStab with { BMin = "invalid unrelated value" }
        };
        WilcockStabDraft importStab = Required(importDraft.Stab, "import STAB draft");
        WilcockSbtmDraft importSbtm = Required(importDraft.Sbtm, "import SBTM draft");
        WilcockWorkspaceSnapshot preflight = WilcockService.Evaluate(new WilcockEvaluateRequest(
            importDraft, Action: "importCaseFromBTM", ConfirmImport: false));
        Check(preflight.CanImportCase && preflight.BtmImportPolicy == "append"
            && preflight.ImportConfirmationRequired && !preflight.ReplacedExistingCases,
            "A compatible BTM import requires confirmation before appending");
        Check(Required(Required(preflight.Draft.Stab, "preflight STAB draft").TransportGrainSizes,
                "preflight STAB cases").Length == Required(importStab.TransportGrainSizes,
                "import STAB cases").Length
            && Required(preflight.Draft.Sbtm, "preflight SBTM draft").WaterDensity == "invalid unrelated value"
            && Required(preflight.Draft.Stab, "preflight STAB draft").BMin == "invalid unrelated value",
            "Import preflight leaves every editable value unchanged");

        WilcockWorkspaceSnapshot appended = WilcockService.Evaluate(new WilcockEvaluateRequest(
            importDraft, Action: "importCaseFromBTM", ConfirmImport: true));
        WilcockStabDraft appendedStab = Required(appended.Draft.Stab, "appended STAB draft");
        WilcockSbtmDraft appendedSbtm = Required(appended.Draft.Sbtm, "appended SBTM draft");
        Check(!appended.ImportConfirmationRequired && !appended.ReplacedExistingCases
            && Required(appendedStab.TransportGrainSizes, "appended STAB cases").Length
                == Required(importStab.TransportGrainSizes, "import STAB cases").Length + 1
            && appendedSbtm.WaterDensity == "invalid unrelated value"
            && appendedStab.BMin == "invalid unrelated value",
            "Confirmed compatible import appends the source case while preserving unrelated invalid inputs");
        Check(appended.StabErrorKey == "Enter a valid number."
            && appended.SbtmErrorKey == "Enter a valid number.",
            "Independent section parse errors remain visible after a successful source import");

        string[] sourceSurfaceCDF = Required(initialSbtm.SurfaceCdf, "source SBTM surface CDF");
        double expectedFirstCDF = double.Parse(sourceSurfaceCDF[0], CultureInfo.GetCultureInfo("en-US"));
        double importedFirstCDF = double.Parse(Required(appendedStab.TransportGrainSizes,
            "appended STAB cases")[^1][0], CultureInfo.GetCultureInfo("en-US"));
        Check(importedFirstCDF.Equals(expectedFirstCDF),
            "The imported case uses the retained merged SBTM Surface CDF, not a synthesized transport CDF");

        WilcockDraft incompatible = initial.Draft with
        {
            Stab = initialStab with
            {
                GrainDiameter = ["65", .. initialGrains.Skip(1)]
            }
        };
        WilcockWorkspaceSnapshot replacementPreflight = WilcockService.Evaluate(new WilcockEvaluateRequest(
            incompatible, Action: "importCaseFromBTM", ConfirmImport: false));
        WilcockStabDraft replacementPreflightStab = Required(replacementPreflight.Draft.Stab,
            "replacement preflight STAB draft");
        Check(replacementPreflight.BtmImportPolicy == "replaceExistingCases"
            && replacementPreflight.ImportConfirmationRequired
            && replacementPreflight.Cases.Length == initial.Cases.Length
            && Required(replacementPreflightStab.GrainDiameter, "replacement preflight grain grid")[0] == "65",
            "A mismatched grain grid also requires confirmation and preserves the visible draft");
        WilcockWorkspaceSnapshot replaced = WilcockService.Evaluate(new WilcockEvaluateRequest(
            incompatible, Action: "importCaseFromBTM", ConfirmImport: true));
        WilcockStabDraft replacedStab = Required(replaced.Draft.Stab, "replaced STAB draft");
        string[] replacedGrains = Required(replacedStab.GrainDiameter, "replaced STAB grain grid");
        string[] sbtmGrains = Required(initialSbtm.GrainDiameter, "initial SBTM grain grid");
        Check(replaced.ReplacedExistingCases && replaced.Cases.Length == 1
            && Required(replacedStab.WaterDischarges, "replaced water discharges").SequenceEqual(new[] { "80" })
            && replacedGrains.SequenceEqual(sbtmGrains),
            "Confirmed incompatible import follows the retained replace-existing-case defaults");
    }

    private static void CheckUnsupportedCultureIsRejected()
    {
        ExpectArgumentMessage(() => WilcockService.Load(new WilcockLoadRequest("not/a-culture")),
            "The requested number culture is not supported.");
        ExpectArgumentMessage(() => WilcockService.Load(new WilcockLoadRequest(" ")),
            "The requested number culture is not supported.");
        WilcockDraft draft = WilcockService.Load(new WilcockLoadRequest("en-US")).Draft;
        ExpectArgumentMessage(() => WilcockService.Evaluate(new WilcockEvaluateRequest(
                draft with { NumberCulture = "not/a-culture" })),
            "The requested number culture is not supported.");
    }

    private static void ExpectArgumentMessage(Action action, string expectedMessage)
    {
        try { action(); }
        catch (ArgumentException exception) when (exception.Message.StartsWith(expectedMessage, StringComparison.Ordinal))
        {
            return;
        }
        throw new InvalidOperationException("Expected ArgumentException: " + expectedMessage);
    }

    private static void Check(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }

    private static T Required<T>(T? value, string description) where T : class
        => value ?? throw new InvalidOperationException($"The source omitted required {description}.");
}
