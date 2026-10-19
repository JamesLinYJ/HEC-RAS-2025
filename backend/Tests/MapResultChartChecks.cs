using System.Buffers.Binary;
using System.Security.Cryptography;
using System.Text;
using System.Xml.Linq;
using Geospatial.PairedData;
using Geospatial.Rasters;
using Geospatial.IO.ORM;
using Geospatial.Vectors;
using Geospatial.Vectors.Meshes;
using H5Assist;
using Ras.Backend;
using Ras.Engine;
using Ras.Hydraulics;
using Ras.Layers;
using Ras.Layers.BoundaryConditions;
using Ras.Layers.Payloads;
using Ras.Layers.Results;
using Ras.Output;
using Utility.Units;
using Utility.Logging;
using BoundaryCondition = Ras.Layers.BoundaryCondition;

/// <summary>
/// Exercises map-scoped Result selection and sample-line callbacks with real
/// source Result HDF files containing deterministic OutputBlock test data.
/// The HDF fixture is not solver output.
/// </summary>
internal static class MapResultChartChecks
{
    private static readonly DateTime Start = new(2026, 10, 16, 0, 0, 0, DateTimeKind.Utc);

    internal static async Task Run()
    {
        using var temporary = new TemporaryDirectory();
        Fixture fixture = CreateFixture(temporary.FullName);
        CheckComputeReadLeaseFiltering(fixture, temporary.FullName);
        byte[] projectBefore = File.ReadAllBytes(fixture.ProjectPath);
        byte[] visualizationBefore = File.ReadAllBytes(fixture.VisualizationPath);
        byte[] vectorBefore = File.ReadAllBytes(fixture.VectorPath);
        Dictionary<string, byte[]> protectedLayerBytes = new[]
            { fixture.GeometryPath, fixture.BoundaryPath, fixture.PlanPath }
            .Distinct(StringComparer.Ordinal).ToDictionary(path => path, File.ReadAllBytes, StringComparer.Ordinal);
        Dictionary<string, byte[]> resultBytes = fixture.ResultPaths.ToDictionary(path => path,
            File.ReadAllBytes, StringComparer.Ordinal);
        ExportFixtureIfRequested(temporary.FullName);

        MapResultSourcesResult initial = MapResultChartService.Sources(new(fixture.Map, []));
        await CheckBoundaryLineTimeSeries(fixture, initial);
        MapResultActiveNode planGroup = initial.ActiveNodes.Single(node => node.NodeKind == "MultiResult");
        Check(initial.ActiveNodes.Length == 2 && initial.ActiveNodes.Any(node => node.NodeKind == "Result"),
            "The map resolver returns checked Result/MultiResult source nodes and excludes the unchecked plan group.");
        Check(planGroup.Selections.Length == 1 && planGroup.Selections[0].SelectionIndex == 0
            && planGroup.Selections[0].SelectionMode == "Latest"
            && planGroup.Selections[0].Choices.Length == 2
            && planGroup.Selections[0].Choices.All(choice => choice.PlanName == fixture.PlanName)
            && !planGroup.Selections[0].Choices.Any(choice => SamePath(choice.ResultPath, fixture.UnrelatedResultPath)),
            "MultiResult options come from the current project Results for that plan, not the synthetic tree children or unrelated plan.");
        Check(planGroup.SelectedMapType == "Depth" && planGroup.ProfileIndex == 0,
            "The map resolver reads the serialized source map type and profile index from the MultiResult context node.");
        string latestPath = planGroup.Selections[0].Choices[0].ResultPath;
        string previousPath = planGroup.Selections[0].Choices[1].ResultPath;
        Check(SamePath(planGroup.Selections[0].SelectedResult!.ResultPath, latestPath),
            "The default selection follows the source latest-result ordering.");

        MapResultSelectionOverride[] changedSlots =
        [
            new(planGroup.Node, 0, "Previous"),
            new(planGroup.Node, 1, "Explicit", latestPath,
                planGroup.Selections[0].Choices[0].Revision)
        ];
        MapResultSourcesResult changed = MapResultChartService.Selection(new MapResultSelectionRequest(
            fixture.Map, initial.ContextToken, [], changedSlots));
        MapResultActiveNode changedGroup = changed.ActiveNodes.Single(node => node.NodeKind == "MultiResult");
        Check(changedGroup.Selections.Length == 2
            && SamePath(changedGroup.Selections[0].SelectedResult!.ResultPath, previousPath)
            && SamePath(changedGroup.Selections[1].SelectedResult!.ResultPath, latestPath)
            && changedGroup.Selections[1].SelectionMode == "Latest",
            "Previous and explicit slots resolve to exact current HDF revisions, and choosing Latest normalizes to source tracking mode.");
        Check(File.ReadAllBytes(fixture.VisualizationPath).SequenceEqual(visualizationBefore),
            "Map result selection is session state and never writes the .vis file.");

        GeometryTopologyCoordinate[] line = [new(0.5, 0.05), new(0.5, 0.95)];
        var feature = new MapResultFeatureIdentity(fixture.VectorPath, Hash(fixture.VectorPath),
            "geojson:sample-line:geometry:0", CoordinateSHA(line));
        MapResultSampleLineRequest sampleRequest = new(fixture.Map, changed.ContextToken,
            changedSlots, feature, line, "Flow");
        MapResultSampleLineResult sampled = await MapResultChartService.SampleLine(sampleRequest);
        string sampledDiagnostics = string.Join(" | ", sampled.Series.Select(item =>
            $"name={item.Series.ResultName}; path={item.Series.ResultPath}; revision={item.Series.Revision}; "
            + $"available={item.Series.Available}; mode={item.Series.Mode}; quantity={item.Series.Quantity}; "
            + $"points={item.Series.Points.Length}; values=[{string.Join(",", item.Series.Points.Select(point => point.Value?.ToString("R", System.Globalization.CultureInfo.InvariantCulture) ?? "null"))}]; "
            + $"reason={item.Series.UnavailableReason ?? "<none>"}; selections={string.Join(",", item.Selections.Select(selection => $"{selection.Node.NodeType}:{selection.SelectionIndex}"))}"));
        string earlyPath = fixture.ResultPaths.Single(path => Path.GetFileNameWithoutExtension(path) == "Chart Early");
        string latestPathForFlow = fixture.ResultPaths.Single(path => Path.GetFileNameWithoutExtension(path) == "Chart Latest");
        MapResultSampleLineSeries? earlyFlow = sampled.Series.SingleOrDefault(item => SamePath(item.Series.ResultPath, earlyPath));
        MapResultSampleLineSeries? latestFlow = sampled.Series.SingleOrDefault(item => SamePath(item.Series.ResultPath, latestPathForFlow));
        double[] expectedEarlyFlow = [-2.9999957, -7.9999914, -14.9999866];
        double[] expectedLatestFlow = [-9.9999914, -23.9999828, -41.9999733];
        const double flowTolerance = 0.0001;
        Check(sampled.Series.Length == 2
            && earlyFlow is not null && latestFlow is not null
            && earlyFlow.Series.Available && latestFlow.Series.Available
            && ValuesMatch(earlyFlow.Series, expectedEarlyFlow, flowTolerance)
            && ValuesMatch(latestFlow.Series, expectedLatestFlow, flowTolerance),
            "The map route calls the retained Result.ComputeFlowTimeSeriesAsync algorithm for the two selected source contexts. Actual series: "
            + sampledDiagnostics);

        GeometryTopologyCoordinate[] reversedLine = line.Reverse().ToArray();
        MapResultFeatureIdentity reversedFeature = feature with { CoordinateSHA = CoordinateSHA(reversedLine) };
        MapResultSampleLineResult reversed = await MapResultChartService.SampleLine(sampleRequest with
        { Feature = reversedFeature, SampleLine = reversedLine });
        string reversedDiagnostics = string.Join(" | ", reversed.Series.Select(item =>
            $"path={item.Series.ResultPath}; values=[{string.Join(",", item.Series.Points.Select(point => point.Value?.ToString("R", System.Globalization.CultureInfo.InvariantCulture) ?? "null"))}]"));
        MapResultSampleLineSeries? reversedEarly = reversed.Series.SingleOrDefault(item => SamePath(item.Series.ResultPath, earlyPath));
        MapResultSampleLineSeries? reversedLatest = reversed.Series.SingleOrDefault(item => SamePath(item.Series.ResultPath, latestPathForFlow));
        Check(reversed.Series.Length == 2
            && reversedEarly is not null && reversedLatest is not null
            && reversedEarly.Series.Available && reversedLatest.Series.Available
            && ValuesMatch(reversedEarly.Series, expectedEarlyFlow.Select(value => -value).ToArray(), flowTolerance)
            && ValuesMatch(reversedLatest.Series, expectedLatestFlow.Select(value => -value).ToArray(), flowTolerance),
            "Reversing the same source sample line reverses the retained flow sign. Actual series: " + reversedDiagnostics);
        Check(sampled.Series.All(item => item.Selections.Length > 0)
            && sampled.Series.SelectMany(item => item.Selections).Any(selection => selection.Node.NodeType == "Result")
            && sampled.Series.SelectMany(item => item.Selections).Any(selection => selection.Node.NodeType == "MultiResult"),
            "The sample-line response preserves node/selection-slot attribution when source visual contexts are deduplicated.");
        Check(sampled.FeatureContextToken.Length == 64
            && sampled.SideEffects.Length == sampled.Series.Length
            && sampled.SideEffects.All(effect => effect.Code == "ResultPostProcessCacheMayBeCreatedOrUpdated"
                && effect.Path is not null),
            "The feature fingerprint binds the vector revision and coordinates, and the response names the source post-process cache side effect.");

        MapResultSelectionOverride[] duplicateOverrides =
        [
            new(planGroup.Node, 0, "Latest"),
            new(planGroup.Node, 1, "Explicit", latestPath,
                planGroup.Selections[0].Choices[0].Revision)
        ];
        MapResultSourcesResult duplicateSnapshot = MapResultChartService.Selection(
            new MapResultSelectionRequest(fixture.Map, changed.ContextToken, changedSlots, duplicateOverrides));
        MapResultSampleLineResult duplicateSlot = await MapResultChartService.SampleLine(sampleRequest with
        {
            ContextToken = duplicateSnapshot.ContextToken,
            SelectionOverrides = duplicateOverrides
        });
        Check(duplicateSlot.Series.Length == 1 && duplicateSlot.Series[0].Selections.Length == 3,
            "MapResultsChart's visual-context/map-type set deduplicates identical source Results across slots and a standalone Result node.");

        MapResultSampleLineResult cumulative = await MapResultChartService.SampleLine(sampleRequest with
        { Mode = "CumulativeVolume" });
        string cumulativeDiagnostics = string.Join(" | ", cumulative.Series.Select(item =>
            $"path={item.Series.ResultPath}; available={item.Series.Available}; mode={item.Series.Mode}; "
            + $"values=[{string.Join(",", item.Series.Points.Select(point => point.Value?.ToString("R", System.Globalization.CultureInfo.InvariantCulture) ?? "null"))}]; "
            + $"reason={item.Series.UnavailableReason ?? "<none>"}"));
        MapResultSampleLineSeries? earlyCumulative = cumulative.Series.SingleOrDefault(item => SamePath(item.Series.ResultPath, earlyPath));
        MapResultSampleLineSeries? latestCumulative = cumulative.Series.SingleOrDefault(item => SamePath(item.Series.ResultPath, latestPathForFlow));
        double[] expectedEarlyCumulative = [0, -9899.98839, -30599.96859];
        double[] expectedLatestCumulative = [0, -30599.97678, -89999.93727];
        Check(cumulative.Series.Length == 2
            && earlyCumulative is not null && latestCumulative is not null
            && earlyCumulative.Series.Available && latestCumulative.Series.Available
            && earlyCumulative.Series.Mode == "CumulativeVolume" && latestCumulative.Series.Mode == "CumulativeVolume"
            && ValuesMatch(earlyCumulative.Series, expectedEarlyCumulative, 0.1)
            && ValuesMatch(latestCumulative.Series, expectedLatestCumulative, 0.1),
            "Cumulative volume preserves the signed trapezoidal area from the retained RateTimeSeries algorithm. Actual series: "
            + cumulativeDiagnostics);

        Expect<SourceFileChangedException>(() => MapResultChartService.Selection(new MapResultSelectionRequest(
            fixture.Map, new string('0', 64), [], changedSlots)));
        Expect<SourceFileChangedException>(() => MapResultChartService.Sources(new MapResultSourcesRequest(fixture.Map,
            [new(planGroup.Node with { RootName = "Boundary Conditions" }, 0, "Latest")])));
        Expect<ArgumentException>(() => MapResultChartService.Sources(new MapResultSourcesRequest(fixture.Map,
            [new(planGroup.Node, 1, "Latest"), new(planGroup.Node, 2, "Latest")])));
        await ExpectAsync<SourceFileChangedException>(() => MapResultChartService.SampleLine(sampleRequest with
        {
            Feature = feature with { VectorRevision = new string('0', 64) }
        }));
        await ExpectAsync<ArgumentException>(() => MapResultChartService.SampleLine(sampleRequest with
        {
            Feature = feature with { CoordinateSHA = new string('0', 64) }
        }));
        await ExpectAsync<ArgumentException>(() => MapResultChartService.SampleLine(sampleRequest with
        {
            SampleLine = [line[0]]
        }));
        await ExpectAsync<SourceFileChangedException>(() => MapResultChartService.SampleLine(sampleRequest with
        { ContextToken = new string('0', 64) }));

        Check(File.ReadAllBytes(fixture.ProjectPath).SequenceEqual(projectBefore)
            && File.ReadAllBytes(fixture.VisualizationPath).SequenceEqual(visualizationBefore)
            && File.ReadAllBytes(fixture.VectorPath).SequenceEqual(vectorBefore)
            && protectedLayerBytes.All(pair => File.ReadAllBytes(pair.Key).SequenceEqual(pair.Value))
            && resultBytes.All(pair => File.ReadAllBytes(pair.Key).SequenceEqual(pair.Value)),
            "Selection, compute-lease filtering and sample-line reads preserve the .ras, .vis, vector source, Geometry, Boundary Condition, Plan and every Result HDF byte; only the reported post-process cache may be written.");

        Console.WriteLine("Map-scoped source Result selection, multi-slot latest/previous/explicit behavior, exact active node context, retained sample-line flow/cumulative algorithms, feature identity, stale checks and read-only source revisions passed.");
    }

    private static async Task CheckBoundaryLineTimeSeries(Fixture fixture,
        MapResultSourcesResult sources)
    {
        MapResultActiveNode activeResult = sources.ActiveNodes.Single(node => node.NodeKind == "Result");
        MapResultSourceChoice selected = activeResult.Selections.Single().SelectedResult
            ?? throw new InvalidDataException("The chart fixture Result did not resolve a selected HDF.");
        MapResultActiveNode multiResult = sources.ActiveNodes.Single(node => node.NodeKind == "MultiResult");
        MapResultSourceChoice multiResultSelected = multiResult.Selections.Single().SelectedResult
            ?? throw new InvalidDataException("The chart fixture MultiResult did not resolve its latest HDF.");
        if (!SamePath(selected.ResultPath, multiResultSelected.ResultPath) ||
            !string.Equals(selected.Revision, multiResultSelected.Revision, StringComparison.OrdinalIgnoreCase))
            throw new InvalidDataException("The chart fixture must expose the same exact Result path and revision through both standalone and MultiResult source selections.");
        MapTreeSnapshot tree = MapTreeService.Load(fixture.Map);
        CatalogTreeNode resultRow = Flatten(tree.Roots).Single(node =>
            node.Locator?.NodeType == "Result" && node.Name == activeResult.Node.NodeName);
        CatalogTreeNode boundaryRow = Flatten(resultRow.Children ?? []).Single(node =>
            node.Locator?.NodeType == "BoundaryCondition");
        CatalogTreeNodeLocator boundaryLocator = boundaryRow.Locator
            ?? throw new InvalidDataException("The chart fixture Result boundary has no retained locator.");
        var owner = new MapResultGeometryOwner(activeResult.Node, sources.ContextToken,
            null, 0, selected.ResultPath, selected.Revision);
        MapBoundaryGeometrySnapshot sourceBoundary = await ModelEditorAdapter.LoadMapBoundaryGeometryAsync(
            new MapBoundaryGeometryRequest(fixture.Map, boundaryLocator, selected.Revision,
                ResultOwner: owner));
        if (sourceBoundary.Lines.Length != 2)
            throw new InvalidDataException("The deterministic chart fixture must contain two actual Boundary Condition lines.");

        MapBoundaryLineData[] sourceLines = sourceBoundary.Lines;
        string[] lineIDs = sourceLines.Select(line => line.Id).ToArray();
        MapBoundaryLineTimeSeriesResult flow = await ModelEditorAdapter.LoadMapBoundaryLineTimeSeriesAsync(
            new MapBoundaryLineTimeSeriesRequest(fixture.Map, boundaryLocator, selected.Revision,
                sourceBoundary.BoundarySourceState, sourceBoundary.ContextToken, owner,
                lineIDs, "Flow"));
        MapBoundaryLineTimeSeriesResult stage = await ModelEditorAdapter.LoadMapBoundaryLineTimeSeriesAsync(
            new MapBoundaryLineTimeSeriesRequest(fixture.Map, boundaryLocator, selected.Revision,
                sourceBoundary.BoundarySourceState, sourceBoundary.ContextToken, owner,
                lineIDs, "Stage"));
        var computeLease = new MapResultComputeReadLease(Guid.NewGuid().ToString("D"),
            Guid.NewGuid().ToString("D"), fixture.ProjectPath, [selected.ResultPath], selected.ResultPath);
        await ExpectAsync<SourceFileChangedException>(() =>
            ModelEditorAdapter.LoadMapBoundaryLineTimeSeriesAsync(new MapBoundaryLineTimeSeriesRequest(
                fixture.Map with { ComputeReadLease = computeLease }, boundaryLocator, selected.Revision,
                sourceBoundary.BoundarySourceState, sourceBoundary.ContextToken, owner,
                lineIDs, "Flow")));
        await ExpectAsync<SourceFileChangedException>(() =>
            ModelEditorAdapter.LoadMapBoundaryLineTimeSeriesAsync(new MapBoundaryLineTimeSeriesRequest(
                fixture.Map, boundaryLocator, selected.Revision,
                sourceBoundary.BoundarySourceState, sourceBoundary.ContextToken, owner,
                [lineIDs[0] + "/stale"], "Flow")));

        if (!Result.TryLoad(selected.ResultPath, out Result? loaded) || loaded?.BoundaryConditions is not { } condition)
            throw new InvalidDataException("Could not reopen the selected Result to compare retained Boundary Condition line series.");
        using (loaded)
        {
            BoundaryConditionLine[] sourceLinesInResult = condition.BoundaryConditionLines.Features.ToArray();
            if (sourceLinesInResult.Length != sourceLines.Length)
                throw new InvalidDataException("The deterministic chart fixture changed its Boundary Condition line count.");
            for (int lineIndex = 0; lineIndex < sourceLines.Length; lineIndex++)
            {
                BoundaryConditionLine line = sourceLinesInResult[lineIndex];
                MapBoundaryLineData sourceLine = sourceLines[lineIndex];
                OperationResult flowStatus = condition.TryGetBCLineFlowTimeSeries(line,
                    out double[] flowValues, out IReadOnlyList<DateTime> flowTimes);
                OperationResult stageStatus = condition.TryGetBCLineStageTimeSeries(line,
                    out double[] stageValues, out IReadOnlyList<DateTime> stageTimes);
                if (!(bool)flowStatus || !(bool)stageStatus)
                    throw new InvalidDataException("The deterministic chart fixture must support both source line result algorithms.");

                MapBoundaryLineTimeSeriesDataset simulatedFlow = flow.Datasets.Single(dataset =>
                    dataset.ID == sourceLine.Id + "/simulated");
                MapBoundaryLineTimeSeriesDataset simulatedStage = stage.Datasets.Single(dataset =>
                    dataset.ID == sourceLine.Id + "/simulated");
                CheckSeries(simulatedFlow, flowValues, flowTimes, ignoreNoData: true,
                    "The Boundary Condition Flow plot calls the retained Result.ComputeFlowTimeSeries method and preserves each selected line's values/times.");
                CheckSeries(simulatedStage, stageValues, stageTimes, ignoreNoData: true,
                    "The Boundary Condition Stage plot calls the retained TryGetBCLineStageTimeSeries sampler and preserves each selected line's values/times.");

                foreach (string variable in new[] { "Flow", "Stage" })
                {
                    MapBoundaryLineTimeSeriesResult actual = variable == "Flow" ? flow : stage;
                    TimeSeriesPayload[] expectedPayloads = line.Payloads.OfType<TimeSeriesPayload>()
                        .Where(payload => payload.Variable == variable && payload.Count > 0).ToArray();
                    MapBoundaryLineTimeSeriesDataset[] returnedPayloads = actual.Datasets
                        .Where(dataset => dataset.ID.StartsWith(sourceLine.Id + "/payload/", StringComparison.Ordinal))
                        .ToArray();
                    Check(returnedPayloads.Length == expectedPayloads.Length,
                        "Boundary Condition payload charts filter to the exact selected variable and time-series payload type.");
                    for (int index = 0; index < expectedPayloads.Length; index++)
                    {
                        TimeSeriesPayload payload = expectedPayloads[index];
                        MapBoundaryLineTimeSeriesDataset dataset = returnedPayloads[index];
                        DateTime[] times = payload.TimeSeriesDefinition.GetAbsoluteTimes(payload.Count,
                            condition.StartTime);
                        Check(dataset.Name == line.Name + " — " + (payload.Name ?? string.Empty)
                            && dataset.Points.Length == payload.Count
                            && dataset.Points.Select(point => point.Value)
                                .SequenceEqual(payload.Values.ToArray().Select(value => double.IsFinite(value) ? (double?)value : null))
                            && dataset.Points.Select(point => point.Time).SequenceEqual(times.Select(FormatTime)),
                            "Boundary Condition payload series retain source payload names, values, missing values and absolute time definitions.");
                    }
                }
            }
        }

        static void CheckSeries(MapBoundaryLineTimeSeriesDataset actual, IReadOnlyList<double> values,
            IReadOnlyList<DateTime> times, bool ignoreNoData, string message)
        {
            Check(actual.Points.Length == values.Count && values.Count == times.Count
                && actual.Points.Select(point => point.Time).SequenceEqual(times.Select(FormatTime))
                && actual.Points.Select((point, index) => point.Value ==
                    (double.IsFinite(values[index]) && (!ignoreNoData || values[index] != -9999.0)
                        ? values[index] : (double?)null)).All(matches => matches), message);
        }

        static string FormatTime(DateTime time) => time.ToString(
            "yyyy-MM-dd'T'HH:mm:ss.fffffff", System.Globalization.CultureInfo.InvariantCulture);
    }

    internal static Fixture CreateFixture(string directory)
    {
        string projectPath = Path.Combine(directory, "Map Result Chart.ras");
        Project project = Project.CreateNew(projectPath, UnitSystem.USCustomary);
        string visualizationPath = Path.ChangeExtension(projectPath, ".vis");
        string vectorPath = Path.Combine(directory, "sample-line.geojson");
        try
        {
            Geometry geometry = CreateGeometry(project);
            BoundaryCondition boundary = project.AddNewBoundaryCondition("Chart Boundary", Start, TimeSpan.FromHours(2));
            BoundaryConditionLine chartBoundaryLine = boundary.BoundaryConditionLines.Add(
                new Polyline(new Point[] { new Point(0.5, 0), new Point(0.5, 1) }));
            chartBoundaryLine.Name = "Chart Boundary Line";
            chartBoundaryLine.Add(new TimeSeriesPayload("Flow",
                new RegularTimeSeriesDefinition(TimeSpan.FromHours(1)), new double[] { 1, double.NaN, 3 })
                { Name = "Flow Payload" });
            chartBoundaryLine.Add(new TimeSeriesPayload("Stage",
                new RegularTimeSeriesDefinition(TimeSpan.FromHours(1)), new double[] { 100, double.NaN, 102 })
                { Name = "Stage Payload" });
            BoundaryConditionLine secondChartBoundaryLine = boundary.BoundaryConditionLines.Add(
                new Polyline(new Point[] { new Point(0.5, 0), new Point(0.5, 1) }));
            secondChartBoundaryLine.Name = "Second Chart Boundary Line";
            secondChartBoundaryLine.Add(new TimeSeriesPayload("Flow",
                new RegularTimeSeriesDefinition(TimeSpan.FromHours(1)), new double[] { 4, double.NaN, 6 })
                { Name = "Second Flow Payload" });
            secondChartBoundaryLine.Add(new TimeSeriesPayload("Stage",
                new RegularTimeSeriesDefinition(TimeSpan.FromHours(1)), new double[] { 200, double.NaN, 202 })
                { Name = "Second Stage Payload" });
            Plan plan = project.AddNewPlan("Chart Plan", geometry, boundary);
            Plan unrelated = project.AddNewPlan("Unrelated Chart Plan", geometry, boundary);
            foreach (CoreLayerBase layer in Layers(project)) layer.Save();
            project.Save();
            Directory.CreateDirectory(project.ResultsDirectory);

            string firstResultPath = Path.Combine(project.ResultsDirectory, "Chart Early.h5");
            string secondResultPath = Path.Combine(project.ResultsDirectory, "Chart Latest.h5");
            string unrelatedResultPath = Path.Combine(project.ResultsDirectory, "Unrelated Chart.h5");
            CreateResult(firstResultPath, plan, geometry, boundary, velocityScale: 1f,
                stageOffset: 0f, summaryStart: Start);
            CreateResult(secondResultPath, plan, geometry, boundary, velocityScale: 2f,
                stageOffset: 1f, summaryStart: Start.AddHours(1));
            CreateResult(unrelatedResultPath, unrelated, geometry, boundary, velocityScale: 3f,
                stageOffset: 2f, summaryStart: Start.AddHours(2));

            File.WriteAllText(vectorPath,
                "{\"type\":\"FeatureCollection\",\"features\":[{\"type\":\"Feature\",\"id\":\"sample-line\",\"properties\":{},\"geometry\":{\"type\":\"LineString\",\"coordinates\":[[0.5,0.05],[0.5,0.95]]}}]}\n");

            string projectXml = File.ReadAllText(projectPath);
            string projectXmlSHA = Hash(Encoding.UTF8.GetBytes(projectXml));
            MapDocumentMutationReceipt created = MapTreeService.CreateMap(new MapDocumentRequest(
                projectPath, projectXml, projectXmlSHA, null, "Project", Name: "Chart map"));
            XDocument visualization = XDocument.Load(visualizationPath, LoadOptions.PreserveWhitespace);
            XElement map = visualization.Root!.Element("Maps")!.Elements("Map").Single();
            map.Add(new XElement("Tree", new XElement("Nodes",
                new XElement("Node", new XAttribute("Type", "Root"), new XAttribute("Name", "Results"),
                    new XElement("Node", new XAttribute("Type", "MultiResult"),
                        new XAttribute("Name", plan.Name), new XAttribute("IsChecked", true)),
                    new XElement("Node", new XAttribute("Type", "MultiResult"),
                        new XAttribute("Name", unrelated.Name), new XAttribute("IsChecked", false))),
                new XElement("Node", new XAttribute("Type", "Root"), new XAttribute("Name", "Map Layers"),
                    new XElement("Node", new XAttribute("Type", "MapLayer"),
                        new XAttribute("MapType", "PolylinesVector"), new XAttribute("Name", "Sample line"),
                        new XAttribute("Filename", vectorPath), new XAttribute("FilenameRelative", Path.GetFileName(vectorPath)),
                        new XAttribute("IsChecked", true))))));
            visualization.Save(visualizationPath, SaveOptions.DisableFormatting);

            // Place one checked individual Result alongside the MultiResult.
            // The source MapResultsChart shares the ResultVisualContext and
            // deduplicates the same result/map type across these two contexts.
            visualization = XDocument.Load(visualizationPath, LoadOptions.PreserveWhitespace);
            XElement resultTreeRoot = visualization.Root!.Element("Maps")!.Elements("Map").Single()
                .Element("Tree")!.Element("Nodes")!.Elements("Node")
                .Single(node => (string?)node.Attribute("Name") == "Results");
            resultTreeRoot.Add(new XElement("Node", new XAttribute("Type", "Result"),
                new XAttribute("Name", Path.GetFileNameWithoutExtension(secondResultPath)),
                new XAttribute("IsChecked", true), new XAttribute("SelectedMapType", "Depth"),
                new XAttribute("ProfileIndex", 0)));
            visualization.Save(visualizationPath, SaveOptions.DisableFormatting);

            string visualizationRevision = Hash(visualizationPath);
            var mapRequest = new MapTreeRequest(projectPath, projectXml, projectXmlSHA,
                "map-result-chart-fixture", created.MapIndex, created.MapName, created.MapType,
                visualizationRevision);
            return new Fixture(projectPath, visualizationPath, vectorPath,
                [firstResultPath, secondResultPath, unrelatedResultPath], unrelatedResultPath,
                geometry.Filename, boundary.Filename, plan.Filename, plan.Name, mapRequest);
        }
        finally
        {
            DisposeProject(project);
        }
    }

    private static Geometry CreateGeometry(Project project)
    {
        Geometry geometry = project.AddNewGeometry("Chart Geometry");
        Mesh mesh = CreateMesh();
        var elevation = new ConstantValueResampler<float>(100f, Extent.Infinite, -9999f);
        var roughness = new ConstantValueResampler<float>(0.03f, Extent.Infinite, -9999f);
        var computed = MeshPropertyTables.ComputeFrom(mesh, elevation, roughness,
            PropertyTableOptions.Default(UnitSystem.USCustomary), out MeshPropertyTables tables);
        Check(computed.Result, "The retained mesh property tables are prepared for the source Result HDF fixture.");
        geometry.FlowAreaLayer.Add(new FlowArea(mesh, "Chart Flow Area") { PropertyTables = tables });
        geometry.Save();
        return geometry;
    }

    private static void CheckComputeReadLeaseFiltering(Fixture fixture, string temporaryRoot)
    {
        string hdfResultPath = Path.Combine(Project.GetDefaultResultDirectory(
            Path.GetDirectoryName(fixture.ProjectPath)!), "Chart Existing Format.hdf");
        File.Copy(fixture.ResultPaths[0], hdfResultPath);
        try
        {
            Project withHdfResult = new(fixture.ProjectPath);
            try
            {
                Check(withHdfResult.Results.Any(item => SamePath(item.Filename, hdfResultPath)),
                    "The retained Project loader recognizes an existing Result stored with the .hdf suffix.");
            }
            finally { DisposeProject(withHdfResult); }

            MapResultSourcesResult sourcesWithHdf = MapResultChartService.Sources(new(fixture.Map, []));
            Check(sourcesWithHdf.ActiveNodes.SelectMany(node => node.Selections)
                    .SelectMany(selection => selection.Choices)
                    .Any(choice => SamePath(choice.ResultPath, hdfResultPath)),
                "Result revision capture includes stable .hdf files as well as .h5 files.");

            Project withoutProtectedHdf = new(fixture.ProjectPath,
                sourcePath => !SamePath(sourcePath, hdfResultPath));
            try
            {
                Check(!withoutProtectedHdf.Results.Any(item => SamePath(item.Filename, hdfResultPath)),
                    "The request-scoped predicate excludes a protected .hdf Result before Result.TryLoad opens it.");
            }
            finally { DisposeProject(withoutProtectedHdf); }
        }
        finally { File.Delete(hdfResultPath); }

        Project ordinary = new(fixture.ProjectPath);
        try
        {
            Check(ordinary.Geometries.Any(item => SamePath(item.Filename, fixture.GeometryPath))
                && ordinary.BoundaryConditions.Any(item => SamePath(item.Filename, fixture.BoundaryPath))
                && ordinary.Plans.Any(item => SamePath(item.Filename, fixture.PlanPath))
                && ordinary.Results.Any(item => SamePath(item.Filename, fixture.UnrelatedResultPath)),
                "The default Project constructor keeps loading Geometry, Boundary Condition, Plan and Result sources.");
        }
        finally { DisposeProject(ordinary); }

        string aliasPath = Path.Combine(temporaryRoot, "compute-writer-result-alias.h5");
        File.CreateSymbolicLink(aliasPath, fixture.UnrelatedResultPath);
        string hdfAliasPath = Path.Combine(temporaryRoot, "compute-writer-result-alias.hdf");
        File.CreateSymbolicLink(hdfAliasPath, fixture.UnrelatedResultPath);
        var protectedPaths = new HashSet<string>(StringComparer.Ordinal)
        {
            Path.GetFullPath(fixture.GeometryPath), Path.GetFullPath(fixture.BoundaryPath),
            Path.GetFullPath(fixture.PlanPath), Path.GetFullPath(fixture.UnrelatedResultPath)
        };
        Project filtered = new(fixture.ProjectPath, sourcePath =>
            !protectedPaths.Contains(Path.GetFullPath(sourcePath)));
        try
        {
            Check(!filtered.Geometries.Any(item => SamePath(item.Filename, fixture.GeometryPath))
                && !filtered.BoundaryConditions.Any(item => SamePath(item.Filename, fixture.BoundaryPath))
                && !filtered.Plans.Any(item => SamePath(item.Filename, fixture.PlanPath))
                && !filtered.Results.Any(item => SamePath(item.Filename, fixture.UnrelatedResultPath)),
                "The request-scoped Project predicate excludes protected non-Result Geometry, Boundary Condition and Plan HDFs as well as a Result before their model constructors run.");
            Check(filtered.Results.Any(item => SamePath(item.Filename, fixture.ResultPaths[0]))
                && filtered.Results.Any(item => SamePath(item.Filename, fixture.ResultPaths[1])),
                "A protected-source filter leaves unrelated stable Result files available.");
        }
        finally { DisposeProject(filtered); }

        var lease = new MapResultComputeReadLease(Guid.NewGuid().ToString("D"),
            Guid.NewGuid().ToString("D"), fixture.ProjectPath, [aliasPath], fixture.UnrelatedResultPath);
        MapTreeSnapshot unleasedTree = MapTreeService.Load(fixture.Map);
        Check(Flatten(unleasedTree.Roots).Any(node => node.Locator?.NodeType == "MultiResult" &&
                node.SelectedResultAssetID is { } path && SamePath(path, fixture.UnrelatedResultPath)),
            "Without a compute lease, the saved MultiResult group retains its exact selected Result identity.");

        MapTreeSnapshot leasedTree = MapTreeService.Load(fixture.Map with { ComputeReadLease = lease });
        Check(!Flatten(leasedTree.Roots).Any(node => node.Locator?.NodeType == "MultiResult" &&
                node.SelectedResultAssetID is { } path && SamePath(path, fixture.UnrelatedResultPath)),
            "The map tree canonicalizes a writer-path symlink and removes the protected selection before Project opens it.");
        MapResultSourcesResult leasedSources = MapResultChartService.Sources(new(
            fixture.Map with { ComputeReadLease = lease }, []));
        MapResultActiveNode group = leasedSources.ActiveNodes.Single(node => node.NodeKind == "MultiResult");
        Check(group.Selections[0].Choices.Length == 2
            && group.Selections[0].Choices.All(choice => !SamePath(choice.ResultPath, fixture.UnrelatedResultPath))
            && leasedSources.ContextToken != MapResultChartService.Sources(new(fixture.Map, [])).ContextToken,
            "Map Result source capture skips the leased file before hashing while preserving stable slots and binding the lease into its context token.");

        var hdfLease = new MapResultComputeReadLease(Guid.NewGuid().ToString("D"),
            Guid.NewGuid().ToString("D"), fixture.ProjectPath, [hdfAliasPath], hdfAliasPath);
        MapTreeSnapshot leasedHdfTree = MapTreeService.Load(fixture.Map with { ComputeReadLease = hdfLease });
        Check(!Flatten(leasedHdfTree.Roots).Any(node => node.Locator?.NodeType == "MultiResult" &&
                node.SelectedResultAssetID is { } path && SamePath(path, fixture.UnrelatedResultPath)),
            "The lease accepts an .hdf source identity and resolves its canonical alias before the Result selection is exposed.");

        Expect<SourceFileChangedException>(() => MapTreeService.Load(fixture.Map with
        {
            ComputeReadLease = lease with { ProtectedSourcePaths = [fixture.UnrelatedResultPath, aliasPath] }
        }));
        Expect<SourceFileChangedException>(() => MapTreeService.Load(fixture.Map with
        {
            ComputeReadLease = lease with { CallbackResultPath = Path.Combine(temporaryRoot, "not-protected.h5") }
        }));
        Expect<SourceFileChangedException>(() => MapTreeService.Load(fixture.Map with
        {
            ComputeReadLease = lease with
            {
                ProtectedSourcePaths = [Path.Combine(temporaryRoot, "unsupported.bin")]
            }
        }));
    }

    private static void CreateResult(string resultPath, Plan plan, Geometry geometry,
        BoundaryCondition boundary, float velocityScale, float stageOffset, DateTime summaryStart)
    {
        using (Result prepared = Result.PrepareResult(resultPath, plan, geometry, boundary, null!))
            Check(File.Exists(resultPath), "The retained Result writer creates the Result HDF fixture.");
        if (!Result.TryLoad(resultPath, out Result? loaded) || loaded is null)
            throw new InvalidDataException("Could not reopen the Result fixture for OutputBlock writing.");
        using (loaded)
        using (var output = OutputBlock.CreateNew(loaded, "Base Output"))
        {
            output.EnableWriting();
            double[][] faceVelocities =
            [
                [1f, 2f, 3f, 4f],
                [2f, 4f, 6f, 8f],
                [3f, 6f, 9f, 12f]
            ];
            for (int profile = 0; profile < faceVelocities.Length; profile++)
            {
                FlowArea area = loaded.Geometry.FlowAreaLayer[0];
                var state = new MeshWaterState(area.Mesh, area.PropertyTables)
                {
                    tMicros = profile * 1_800_000_000L,
                    CellElevation = [101.5f + stageOffset + profile * 0.5f],
                    FaceVelocity = faceVelocities[profile].Select(value => value * velocityScale).ToArray()
                };
                output.AddTimestep(new MeshTimestep(state, profile));
            }
            output.FinishWriting();
        }

        using H5Writer summaryWriter = new(resultPath);
        GeospatialH5Metadata.Write(new ComputeSummary
        {
            StartTime = summaryStart,
            TotalDuration = TimeSpan.Zero
        }, summaryWriter, "/Results/Compute Summary");
    }

    private static Mesh CreateMesh()
    {
        Point[] points = [new(0, 0), new(1, 0), new(1, 1), new(0, 1)];
        Face[] faces = Enumerable.Range(0, 4)
            .Select(index => new Face { fpA = index, fpB = (index + 1) % 4, cellA = 0, cellB = -1 }).ToArray();
        FacePoint[] nodes = points.Select((point, index) => new FacePoint(point)
            { Faces = [(index + 3) % 4, index] }).ToArray();
        return new Mesh(new Polygon(points), [new Cell { Faces = new int[] { 0, 1, 2, 3 } }],
            faces, nodes, [new Point(0.5, 0.5)], null!);
    }

    private static IEnumerable<CoreLayerBase> Layers(Project project) => project.Plans.Cast<CoreLayerBase>()
        .Concat(project.Geometries).Concat(project.BoundaryConditions).Concat(project.Terrains)
        .Concat(project.NValues).Concat(project.ClassificationLayers);

    private static void DisposeProject(Project project)
    {
        foreach (CoreLayerBase layer in Layers(project)) layer.Dispose();
        foreach (Result result in project.Results) result.Dispose();
    }

    private static string CoordinateSHA(IEnumerable<GeometryTopologyCoordinate> coordinates)
    {
        using IncrementalHash hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        hash.AppendData(Encoding.UTF8.GetBytes("HECRAS-MAP-LINE-v1\0"));
        Span<byte> bytes = stackalloc byte[sizeof(ulong)];
        foreach (GeometryTopologyCoordinate point in coordinates)
        {
            BinaryPrimitives.WriteUInt64BigEndian(bytes, unchecked((ulong)BitConverter.DoubleToInt64Bits(point.X)));
            hash.AppendData(bytes);
            BinaryPrimitives.WriteUInt64BigEndian(bytes, unchecked((ulong)BitConverter.DoubleToInt64Bits(point.Y)));
            hash.AppendData(bytes);
        }
        return Convert.ToHexString(hash.GetHashAndReset());
    }

    private static string Hash(string path)
    {
        using Stream stream = File.OpenRead(path);
        return Convert.ToHexString(SHA256.HashData(stream));
    }

    private static string Hash(byte[] bytes) => Convert.ToHexString(SHA256.HashData(bytes));

    private static bool ValuesMatch(ResultProfileSampleLineSeries series, IReadOnlyList<double> expected,
        double tolerance) => series.Points.Length == expected.Count
        && series.Points.Select((point, index) => point.Value is double value
            && Math.Abs(value - expected[index]) <= tolerance).All(matches => matches);

    private static bool SamePath(string left, string right) => MapSourceTestPaths.SameFile(left, right);

    private static IEnumerable<CatalogTreeNode> Flatten(IEnumerable<CatalogTreeNode> nodes)
    {
        foreach (CatalogTreeNode node in nodes)
        {
            yield return node;
            if (node.Children is { Length: > 0 } children)
                foreach (CatalogTreeNode child in Flatten(children)) yield return child;
        }
    }

    private static void ExportFixtureIfRequested(string sourceRoot)
    {
        string? destination = Environment.GetEnvironmentVariable("HECRAS_MAP_RESULT_CHART_ACCEPTANCE_DIRECTORY");
        if (string.IsNullOrWhiteSpace(destination)) return;
        string target = Path.GetFullPath(destination);
        string source = Path.GetFullPath(sourceRoot);
        if (Directory.Exists(target) || File.Exists(target) ||
            target.StartsWith(source + Path.DirectorySeparatorChar, StringComparison.Ordinal))
            throw new IOException("The map-result chart acceptance directory already exists or is inside the source fixture.");
        Directory.CreateDirectory(target);
        foreach (string path in Directory.EnumerateFiles(source, "*", SearchOption.AllDirectories))
        {
            string copy = Path.Combine(target, Path.GetRelativePath(source, path));
            Directory.CreateDirectory(Path.GetDirectoryName(copy)!);
            File.Copy(path, copy);
        }
        File.WriteAllText(Path.Combine(target, "ACCEPTANCE.txt"),
            "Map result chart source fixture. Result HDF OutputBlock values are deterministic test data, not solver output. "
            + "Map tree identity: Chart map / Project, index 0. Active Result context: Chart Plan, latest and previous source Results. "
            + "Polyline feature identity: geojson:sample-line:geometry:0. Source sampling must use Result.ComputeFlowTimeSeriesAsync.");
    }

    private static void Check(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }

    private static void Expect<T>(Action action) where T : Exception
    {
        try { action(); }
        catch (T) { return; }
        throw new InvalidOperationException("Expected " + typeof(T).Name + ".");
    }

    private static async Task ExpectAsync<T>(Func<Task> action) where T : Exception
    {
        try { await action(); }
        catch (T) { return; }
        throw new InvalidOperationException("Expected " + typeof(T).Name + ".");
    }

    internal sealed record Fixture(string ProjectPath, string VisualizationPath, string VectorPath,
        string[] ResultPaths, string UnrelatedResultPath, string GeometryPath, string BoundaryPath,
        string PlanPath, string PlanName, MapTreeRequest Map);
}
