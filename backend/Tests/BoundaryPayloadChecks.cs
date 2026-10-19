using System.ComponentModel.DataAnnotations;
using Geospatial.PairedData;
using Geospatial.Vectors;
using H5Assist;
using Ras.Backend;
using Ras.Layers;
using Ras.Layers.Payloads;
using Utility.Units;

internal static class BoundaryPayloadChecks
{
    internal static async Task Run()
    {
        using var temporary = new TemporaryDirectory();
        string projectPath = Path.Combine(temporary.FullName, "载荷编辑.ras");
        var project = Project.CreateNew(projectPath, UnitSystem.SI);
        string externalFile = Path.Combine(temporary.FullName, "源数据.dss"); File.WriteAllText(externalFile, "connection metadata only");
        project.ConnectionSource.AddFileConnection("中文连接", externalFile);
        DateTime start = new(2026, 10, 16, 8, 0, 0);
        var boundary = project.AddNewBoundaryCondition("载荷模型", start, TimeSpan.FromHours(2));
        var line = boundary.BoundaryConditionLines.Add(new Polyline(new Point[] { new(0, 0), new(10, 0) })); line.Name = "载荷边界";
        line.Add(new ConstantPayload("Flow", 1) { Name = "同名载荷" });
        line.Add(new RatingCurvePayload("Stage", "Flow", new double[] { 1, 2 }, new double[] { 10, 20 }) { Name = "率定曲线", IsEnabled = false });
        line.Add(new FunctionalPayload("Stage") { Name = "源函数载荷", Description = "原源模型没有公式实现", IsEnabled = false });
        project.Save(); string filename = boundary.Filename; boundary.Dispose();
        using (var writer = new H5Writer(filename)) writer.WriteAttribute(BoundaryCondition.HDFGroupName, "Unknown Payload Metadata", "保留 🌊");
        var initialFiles = Directory.EnumerateFiles(temporary.FullName, "*", SearchOption.AllDirectories).ToDictionary(file => Path.GetRelativePath(temporary.FullName, file), File.ReadAllBytes);
        byte[] original = File.ReadAllBytes(filename), originalProject = File.ReadAllBytes(projectPath);
        var initial = await ModelEditorAdapter.LoadAsync(new(filename, "Boundary Conditions", projectPath));
        string lineId = initial.Boundary!.Lines[0].Id;
        Check(initial.Boundary.Lines[0].NewPayload.Choices["NewPayloadPage/ViewModel_HydraulicDataType"].All(choice => choice.Id != "Functional"), "Original unsupported Functional creation is not advertised");
        Dictionary<string, string> changed = [];
        ModelSaveRequest Draft(ModelSnapshot snapshot) => new(filename, "Boundary Conditions", projectPath, snapshot.Revision, changed, [], SourceState: snapshot.SourceState,
            Rows: snapshot.Boundary!.Series.Values.Where(series => series.TableId != null).SelectMany(series => new[] { new KeyValuePair<string, ModelRow[]>(series.TableId!, series.Rows), new(series.PageId + "/Stations", series.Stations) }).ToDictionary(),
            Samples: snapshot.Boundary.Series.Values.Where(series => series.TableId == null).ToDictionary(series => series.PageId, series => series.Samples));
        Dictionary<string, string> Creation(string type, string variable = "Flow", string timeType = "Regular")
        {
            var fields = new Dictionary<string, string>(initial.Boundary.Lines[0].NewPayload.Fields);
            fields["NewPayloadPage/ViewModel_PayloadName"] = "同名载荷";
            fields["NewPayloadPage/ViewModel_HydraulicDataType"] = type;
            fields["NewPayloadPage/ViewModel_HydraulicType"] = variable;
            fields["NewPayloadPage/ViewModel_TimeSeriesType"] = timeType;
            fields["NewPayloadPage/ViewModel_HydraulicConstantValue"] = "7.5";
            return fields;
        }
        var created = await ModelEditorAdapter.TransformBoundaryAsync(new(Draft(initial), lineId, "create", null, Creation("Constant")));
        var constant = created.Boundary!.Lines[0].Payloads.Last();
        Check(created.Boundary.SelectedPayloadId == constant.Id && constant.Id != initial.Boundary.Lines[0].Payloads[0].Id, "New same-name payload has its own selected identity");
        Check(!created.Boundary.Lines[0].Payloads[0].IsEnabled && constant.IsEnabled && File.ReadAllBytes(filename).SequenceEqual(original), "Source AddPayload enforces hydraulic exclusivity only in the draft");
        changed[constant.Scope + "/ConstantPayloadEditor/ConstantPayload_Value"] = "11";
        changed[constant.Scope + "/PayloadDetails/Description"] = "中文载荷说明";
        changed["BoundaryConditionsSummary/BoundaryCondition_Description"] = "未保存的边界说明";
        var irregular = await ModelEditorAdapter.TransformBoundaryAsync(new(Draft(created), lineId, "create", null, Creation("Tabular", "Stage", "Irregular")));
        string irregularPage = irregular.Boundary!.Lines[0].Payloads.Last().Scope + "/Time Series";
        irregular = await ModelEditorAdapter.TransformSeriesAsync(new(Draft(irregular), irregularPage, "appendRow"));
        var irregularData = irregular.Boundary!.Series[irregularPage];
        Check(irregularData.Samples.Length == 1 && irregularData.Samples[0].Y == null, "Empty irregular source series can accept its first editable row");
        irregularData.Samples[0] = irregularData.Samples[0] with { X = irregularData.Samples[0].X + 7.125, Y = 22 };
        var spatial = await ModelEditorAdapter.TransformBoundaryAsync(new(Draft(irregular), lineId, "create", null, Creation("SpatiallyVariableTabular", "StageVelocityVelocity", "Irregular")));
        string spatialPage = spatial.Boundary!.Lines[0].Payloads.Last().Scope + "/Time Series";
        spatial = await ModelEditorAdapter.TransformSeriesAsync(new(Draft(spatial), spatialPage, "addStation"));
        spatial = await ModelEditorAdapter.TransformSeriesAsync(new(Draft(spatial), spatialPage, "appendRow"));
        spatial.Boundary!.Series[spatialPage].Rows[0].Values["station/0"] = "33";
        var externalFields = Creation("Remote"); externalFields["NewPayloadPage/ViewModel_SelectedExternalConnection"] = "中文连接"; externalFields["NewPayloadPage/ViewModel_Path"] = "/中文/流量/";
        var draft = await ModelEditorAdapter.TransformBoundaryAsync(new(Draft(spatial), lineId, "create", null, externalFields));
        Check(File.ReadAllBytes(filename).SequenceEqual(original) && File.ReadAllBytes(projectPath).SequenceEqual(originalProject), "Multiple payload constructors and table edits never implicitly save HDF or project XML");
        string ratingPage = initial.Boundary.Lines[0].Payloads[1].Scope + "/Time Series";
        draft.Boundary!.Series[ratingPage].Samples[1] = draft.Boundary.Series[ratingPage].Samples[1] with { X = 2.5, Y = 25 };
        draft = await ModelEditorAdapter.TransformSeriesAsync(new(Draft(draft), ratingPage, "appendRow"));
        draft.Boundary!.Series[ratingPage].Samples[2] = draft.Boundary.Series[ratingPage].Samples[2] with { Y = 35 };
        var saved = await ModelEditorAdapter.SaveAsync(Draft(draft));
        Check(saved.Boundary!.Lines[0].Payloads.Select(payload => payload.Id).SequenceEqual(draft.Boundary.Lines[0].Payloads.Select(payload => payload.Id)), "Structural identities rebase to persisted source after Save");
        using (var actual = new BoundaryCondition(filename, project))
        {
            var payloads = actual.BoundaryConditionLines.First().Payloads;
            Check(payloads.Count == 7 && ((ConstantPayload)payloads[3]).Value == 11 && payloads[3].Description == "中文载荷说明", "Real source file contains created payload data and description");
            var points = (TimeSeriesPayload)payloads[4];
            Check(points.Count == 1 && points.Values.Span[0] == 22 && ((IrregularAbsoluteTimeSeriesDefinition)points.TimeSeriesDefinition).Times.Span[0] == start.AddSeconds(7.125), "Created irregular source rows and millisecond dates persist");
            var matrix = (SpatiallyVariableTimeSeriesPayload)payloads[5];
            Check(matrix.StationCount == 1 && matrix.Values.Count == 1 && matrix.Values[0].Span[0] == 33, "Created spatial irregular source rows/stations persist together");
            var remote = (ExternalPayload)payloads[6];
            Check(remote.ExternalConnection == "中文连接" && remote.ExternalPath == "/中文/流量/", "External constructor stores source connection and path metadata");
            var curve = (RatingCurvePayload)payloads[1];
            Check(curve.IndependentVariable == "Stage" && curve.Count == 3 && curve.InputValues.Span[1] == 2.5 && curve.OutputValues.Span[1] == 25 && curve.OutputValues.Span[2] == 35, "Existing rating curve source arrays and variable are editable and persistent");
            Check(payloads[2] is FunctionalPayload && payloads[2].Description == "原源模型没有公式实现", "Functional source metadata roundtrips without inventing formula behavior");
        }
        using (var reader = new H5Reader(filename)) Check(reader.TryReadStringAttributeScalar(BoundaryCondition.HDFGroupName, "Unknown Payload Metadata") == "保留 🌊", "Payload edits retain unknown HDF metadata");
        changed.Clear(); byte[] savedBytes = File.ReadAllBytes(filename);
        var removed = await ModelEditorAdapter.TransformBoundaryAsync(new(Draft(saved), lineId, "remove", constant.Id, []));
        Check(removed.Boundary!.Lines[0].Payloads.Length == 6 && File.ReadAllBytes(filename).SequenceEqual(savedBytes), "Payload removal remains an unsaved draft");
        var removedSaved = await ModelEditorAdapter.SaveAsync(Draft(removed));
        using (var actual = new BoundaryCondition(filename, project)) Check(actual.BoundaryConditionLines.First().Payloads.Count == 6, "Explicit save persists payload deletion");
        await Reject<SourceFileChangedException>(() => ModelEditorAdapter.TransformBoundaryAsync(new(Draft(saved), lineId, "remove", constant.Id, [])));
        await Reject<NotSupportedException>(() => ModelEditorAdapter.TransformBoundaryAsync(new(Draft(removedSaved), lineId, "create", null, Creation("Functional"))));
        await Reject<ValidationException>(() => ModelEditorAdapter.TransformBoundaryAsync(new(Draft(removedSaved), lineId, "create", null, Creation("Tabular", "Normal Depth"))));
        Check(File.ReadAllBytes(projectPath).SequenceEqual(originalProject), "Payload save never writes project XML");
        if (Environment.GetEnvironmentVariable("HECRAS_BOUNDARY_PAYLOAD_ACCEPTANCE_DIRECTORY") is string fixture)
        {
            if (Directory.Exists(fixture)) throw new IOException("Acceptance fixture destination already exists.");
            Directory.CreateDirectory(fixture);
            foreach (var file in initialFiles) { string target = Path.Combine(fixture, file.Key); Directory.CreateDirectory(Path.GetDirectoryName(target)!); File.WriteAllBytes(target, file.Value); }
        }
        Console.WriteLine("Actual payload draft creation/removal, source constructor validation, rating curves, empty irregular/spatial rows and explicit HDF persistence passed.");
    }
    private static async Task Reject<T>(Func<Task<ModelSnapshot>> action) where T : Exception
    { try { await action(); } catch (T) { return; } throw new InvalidOperationException("Expected " + typeof(T).Name); }
    private static void Check(bool condition, string message) { if (!condition) throw new InvalidOperationException(message); }
}
