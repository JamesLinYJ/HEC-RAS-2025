using System.ComponentModel.DataAnnotations;
using Geospatial.PairedData;
using Geospatial.Vectors;
using H5Assist;
using Ras.Backend;
using Ras.Layers;
using Ras.Layers.Payloads;
using Utility.Units;

internal static class BoundarySeriesChecks
{
    internal static async Task Run()
    {
        using var temporary = new TemporaryDirectory();
        string projectPath = Path.Combine(temporary.FullName, "时间序列.ras");
        var project = Project.CreateNew(projectPath, UnitSystem.SI);
        DateTime start = new(2026, 10, 15, 8, 0, 0);
        var boundary = project.AddNewBoundaryCondition("真实边界序列", start, TimeSpan.FromHours(1));
        var first = boundary.BoundaryConditionLines.Add(new Polyline(new Point[] { new(0, 0), new(10, 0) })); first.Name = "第一条边界";
        var regular = new TimeSeriesPayload("Flow", new RegularTimeSeriesDefinition(TimeSpan.FromMinutes(20)), new double[] { 1, double.NaN, 5 }) { Name = "同名载荷" };
        first.Add(regular); first.Add(new ConstantPayload("Stage", 2.5) { Name = "常数水位", IsEnabled = false });
        var second = boundary.BoundaryConditionLines.Add(new Polyline(new Point[] { new(0, 1), new(10, 1) })); second.Name = "空间变化边界";
        var spatial = new SpatiallyVariableTimeSeriesPayload("Stage", new RegularTimeSeriesDefinition(TimeSpan.FromMinutes(20)), new double[] { 0, 5, 10 },
            [new double[] { 0, double.NaN, 10 }, new double[] { 10, double.NaN, 30 }, new double[] { 20, 30, 40 }]) { Name = "空间水位" };
        second.Add(spatial);
        var third = boundary.BoundaryConditionLines.Add(new Polyline(new Point[] { new(0, 2), new(10, 2) })); third.Name = "不规则边界";
        third.Add(new TimeSeriesPayload("Flow", new IrregularAbsoluteTimeSeriesDefinition([start.AddMilliseconds(125), start.AddSeconds(7), start.AddSeconds(55)]), new double[] { 2, 4, 6 }) { Name = "同名载荷" });
        third.Add(new TimeSeriesPayload("Stage", IrregularRelativeTimeSeriesDefinition.FromSeconds(new double[] { 0, 8, 60 }), new double[] { 10, 20, 30 }) { Name = "相对时间", IsEnabled = false });
        project.Save(); string filename = boundary.Filename; boundary.Dispose();
        using (var writer = new H5Writer(filename)) writer.WriteAttribute(BoundaryCondition.HDFGroupName, "Unknown Series Metadata", "保留 🌊");
        var initialFiles = Directory.EnumerateFiles(temporary.FullName, "*", SearchOption.AllDirectories).ToDictionary(file => Path.GetRelativePath(temporary.FullName, file), File.ReadAllBytes);
        var request = new ModelRequest(filename, "Boundary Conditions", projectPath);
        var loaded = await ModelEditorAdapter.LoadAsync(request); var data = loaded.Boundary!;
        Check(data.Lines.Length == 3 && data.Series.Count == 4 && loaded.SourceState != null, "Actual source lines and four series are projected");
        Check(loaded.Fields["BoundaryConditionCatalogSummary/Context_Name"] == "真实边界序列" && loaded.Fields["BoundaryConditionCatalogSummary/Context_Filename"] == filename
            && DateTimeOffset.TryParse(loaded.Fields["BoundaryConditionCatalogSummary/Context_Layer_DateCreated"], out _)
            && DateTimeOffset.TryParse(loaded.Fields["BoundaryConditionCatalogSummary/Context_Layer_DateLastModified"], out _), "Boundary catalog reads actual source name, file and timestamps");
        var scalarData = data.Series.Values.Single(item => item.Scope == data.Lines[0].Payloads[0].Scope);
        var spatialData = data.Series.Values.Single(item => item.Scope == data.Lines[1].Payloads[0].Scope);
        Check(loaded.FieldGroups.Values.Any(group => group.Contains("BoundaryConditionsSummary/BoundaryCondition_StartTime")
            && group.Contains("BoundaryConditionTimeWindow/BoundaryCondition_StartTime")
            && group.Contains(scalarData.Scope + "/RegularTimeSeriesPayloadEditor/BoundaryConditionLine_BoundaryCondition_StartTime")), "Summary, dedicated time window and payload dates share one actual source alias group");
        Check(scalarData.Samples[1].Y == null && scalarData.Samples.Length == 4 && !scalarData.CanEditX, "Regular source dates and missing/padded values preserve source table semantics");
        Check(spatialData.Stations.Length == 3 && spatialData.Columns.Length == 4, "Spatial source columns use actual station count");
        string firstId = data.Lines[0].Payloads[0].Id, otherId = data.Lines[2].Payloads[0].Id;
        Check(firstId != otherId && data.Lines[0].Payloads[0].Name == data.Lines[2].Payloads[0].Name, "Duplicate display names never identify payloads");
        byte[] original = File.ReadAllBytes(filename);
        ModelSaveRequest Draft(ModelSnapshot snapshot, Dictionary<string, string>? fields = null, Dictionary<string, ModelRow[]>? rows = null, Dictionary<string, ModelSample[]>? samples = null) =>
            new(filename, "Boundary Conditions", projectPath, snapshot.Revision, fields ?? [], [], SourceState: snapshot.SourceState, Rows: rows, Samples: samples);
        var interpolated = await ModelEditorAdapter.TransformSeriesAsync(new(Draft(loaded), scalarData.PageId, "interpolate"));
        Check(interpolated.Boundary!.Series[scalarData.PageId].Samples[1].Y == 3 && File.ReadAllBytes(filename).SequenceEqual(original), "Retained observable interpolation changes only the draft");
        var editedSamples = interpolated.Boundary.Series[scalarData.PageId].Samples;
        var saved = await ModelEditorAdapter.SaveAsync(Draft(interpolated,
            new() { [data.Lines[0].Scope + "/DetailedBCLineHeaderControl/BoundaryConditionLine_Name"] = "中文重命名边界" },
            samples: new() { [scalarData.PageId] = editedSamples }));
        Check(saved.Boundary!.Lines[0].Id == data.Lines[0].Id && saved.Boundary.Series.ContainsKey(scalarData.PageId), "Source identities survive a save and independent source reload");
        using (var actual = new BoundaryCondition(filename, project))
        {
            var payload = (TimeSeriesPayload)actual.BoundaryConditionLines.First().Payloads[0];
            Check(payload.Values.Length == 3 && payload.Values.Span.SequenceEqual(new double[] { 1, 3, 5 }), "Independent HDF reader sees interpolated values without storing unused display rows");
            Check(actual.BoundaryConditionLines.First().Name == "中文重命名边界", "Scoped source line rename persists");
        }
        using (var reader = new H5Reader(filename)) Check(reader.TryReadStringAttributeScalar(BoundaryCondition.HDFGroupName, "Unknown Series Metadata") == "保留 🌊", "Source series saves retain unknown HDF metadata");
        string interval = scalarData.Scope + "/RegularTimeSeriesPayloadEditor/TimeSeriesDefinition_Interval";
        var refreshed = await ModelEditorAdapter.TransformSeriesAsync(new(Draft(saved, new() { [interval] = "900" }), scalarData.PageId, "refresh"));
        Check(refreshed.Boundary!.Series[scalarData.PageId].Samples[1].X - refreshed.Boundary.Series[scalarData.PageId].Samples[0].X == 900 && refreshed.Revision == saved.Revision,
            "Draft interval refresh uses source time definitions without saving");
        var stationDraft = await ModelEditorAdapter.TransformSeriesAsync(new(Draft(saved), spatialData.PageId, "addStation"));
        var expanded = stationDraft.Boundary!.Series[spatialData.PageId];
        Check(expanded.Stations.Length == 4 && expanded.Columns.Length == 5, "Actual source AddNewStation grows rows and station data");
        var rows = expanded.Rows.Select(row => row with { Values = new(row.Values) }).ToArray(); rows[0].Values["station/0"] = "123";
        var stations = expanded.Stations.Select(row => row with { Values = new(row.Values) }).ToArray(); stations[3].Values["Station"] = "15";
        var rowsByTable = new Dictionary<string, ModelRow[]> { [expanded.TableId!] = rows, [expanded.PageId + "/Stations"] = stations };
        var spatialSaved = await ModelEditorAdapter.SaveAsync(Draft(stationDraft, rows: rowsByTable,
            samples: new() { [spatialData.PageId] = expanded.Samples }));
        using (var actual = new BoundaryCondition(filename, project))
        {
            var payload = (SpatiallyVariableTimeSeriesPayload)actual.BoundaryConditionLines.Skip(1).First().Payloads[0];
            Check(payload.StationCount == 4 && payload.Stations.Span[3] == 15 && payload.Values[0].Span[0] == 123,
                "Station draft and edited table cells persist; stale graph samples cannot replace table edits");
            Check(payload.Values.Count == 3 && payload.Values.All(value => value.Length == 4), "Source station resize keeps aligned value rows and no padded display rows");
        }
        var irregular = spatialSaved.Boundary!.Series.Values.Single(item => item.Scope == spatialSaved.Boundary.Lines[2].Payloads[0].Scope);
        var changed = irregular.Samples.Select(sample => sample with { }).ToArray(); changed[1] = changed[1] with { X = changed[1].X + 1, Y = 99 };
        var irregularSaved = await ModelEditorAdapter.SaveAsync(Draft(spatialSaved, samples: new() { [irregular.PageId] = changed }));
        using (var actual = new BoundaryCondition(filename, project))
        {
            var payload = (TimeSeriesPayload)actual.BoundaryConditionLines.Skip(2).First().Payloads[0];
            var definition = (IrregularAbsoluteTimeSeriesDefinition)payload.TimeSeriesDefinition;
            Check(definition.Times.Span[0] == start.AddMilliseconds(125) && definition.Times.Span[1] == start.AddSeconds(8) && payload.Values.Span[1] == 99,
                "Irregular date/value edits persist without rounding untouched subsecond timestamps");
        }
        byte[] beforeReject = File.ReadAllBytes(filename);
        await Reject<SourceFileChangedException>(() => ModelEditorAdapter.SaveAsync(Draft(loaded, new() { [interval] = "2" })));
        await Reject<ValidationException>(() => ModelEditorAdapter.SaveAsync(Draft(irregularSaved, new() { [interval] = "0" })));
        string readOnly = irregularSaved.ReadOnlyFields!.First();
        await Reject<ArgumentException>(() => ModelEditorAdapter.SaveAsync(Draft(irregularSaved, new() { [readOnly] = "2026-10-16T00:00:00+08:00" })));
        var duplicate = changed.Append(changed[0]).ToArray();
        await Reject<ArgumentException>(() => ModelEditorAdapter.SaveAsync(Draft(irregularSaved, samples: new() { [irregular.PageId] = duplicate })));
        Check(File.ReadAllBytes(filename).SequenceEqual(beforeReject) && !Directory.EnumerateFiles(temporary.FullName, ".model-edit-*.pending", SearchOption.AllDirectories).Any(),
            "Rejected series edits preserve HDF bytes and clean staging files");
        if (Environment.GetEnvironmentVariable("HECRAS_BOUNDARY_SERIES_ACCEPTANCE_DIRECTORY") is string fixture)
        {
            if (Directory.Exists(fixture)) throw new IOException("Acceptance fixture destination already exists.");
            Directory.CreateDirectory(fixture);
            foreach (var file in initialFiles)
            {
                string target = Path.Combine(fixture, file.Key); Directory.CreateDirectory(Path.GetDirectoryName(target)!); File.WriteAllBytes(target, file.Value);
            }
        }
        Console.WriteLine("Actual boundary line identities, regular/irregular/spatial source series, interpolation, station growth, draft isolation and independent HDF persistence passed.");
    }
    private static async Task Reject<T>(Func<Task<ModelSnapshot>> action) where T : Exception
    {
        try { await action(); } catch (T) { return; }
        throw new InvalidOperationException("Expected " + typeof(T).Name);
    }
    private static void Check(bool condition, string message) { if (!condition) throw new InvalidOperationException(message); }
}
