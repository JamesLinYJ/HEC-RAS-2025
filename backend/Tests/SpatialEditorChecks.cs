using System.ComponentModel.DataAnnotations;
using Geospatial.PairedData;
using Geospatial.Vectors;
using Ras.Backend;
using Ras.Layers;
using Ras.Layers.Meteorology;
using Utility.Units;

internal static class SpatialEditorChecks
{
    internal static async Task Run()
    {
        using var temporary = new TemporaryDirectory();
        string projectPath = Path.Combine(temporary.FullName, "站点编辑.ras");
        var project = Project.CreateNew(projectPath, UnitSystem.SI);
        DateTime start = new(2026, 10, 16, 8, 0, 0);
        var boundary = project.AddNewBoundaryCondition("站点模型", start, TimeSpan.FromHours(2));
        var station = new MeteorologicStation("原站点", new Point(100, 200)); boundary.MetStations.Add(station);
        boundary.Precipitation.IsEnabled = true; boundary.Precipitation.SpatialDataType = SpatialDataType.Point;
        boundary.Precipitation.Gauges.Add(MetGaugedData.FromTableData(station, TimeSeriesDefinition.Regular(Time.Hours, 1), [1, 2, 3]));
        var wind = MetGaugedData.FromTableData(station, TimeSeriesDefinition.Irregular([0.125, 3600.125], null), [4, 5]);
        wind.Table2 = [6, double.NaN]; boundary.Wind.Gauges.Add(wind);
        project.Save(); string filename = boundary.Filename; boundary.Dispose();
        byte[] original = File.ReadAllBytes(filename), projectBytes = File.ReadAllBytes(projectPath);
        var fixtureFiles = Directory.EnumerateFiles(temporary.FullName, "*", SearchOption.AllDirectories).ToDictionary(file => Path.GetRelativePath(temporary.FullName, file), File.ReadAllBytes);
        var current = await ModelEditorAdapter.LoadAsync(new(filename, "Boundary Conditions", projectPath));
        Dictionary<string, string> fields = [];
        ModelSaveRequest Draft(ModelSnapshot snapshot) => new(filename, "Boundary Conditions", projectPath, snapshot.Revision, fields, [], SourceState: snapshot.SourceState,
            Rows: snapshot.Boundary!.Series.Values.Where(series => series.TableId != null).ToDictionary(series => series.TableId!, series => series.Rows),
            Samples: snapshot.Boundary.Series.Values.Where(series => series.TableId == null).ToDictionary(series => series.PageId, series => series.Samples));
        string stationId = current.Boundary!.Spatial!["precipitation"].Stations[0].Id;
        string stationScope = current.Boundary.Spatial["wind"].Stations[0].Scope;
        Check(current.Boundary.Spatial.Count == 5 && current.Boundary.Spatial.Values.All(data => data.Stations[0].Id == stationId), "All five source layer editors use one shared station identity");
        Check(current.Boundary.Spatial["wind"].Unit == "m/s" && current.Boundary.Spatial["airPressure"].Unit == "mbar", "Point input units retain the actual source conventions");
        string precipScope = current.Boundary.Spatial["precipitation"].Inputs[0].Scope, precipPage = precipScope + "/Time Series";
        string windPage = current.Boundary.Spatial["wind"].Inputs[0].PageId!;
        Check(current.Boundary.Series[windPage].Rows[0].Values["Time"].Contains("125", StringComparison.Ordinal), "Irregular station timestamps expose original subsecond precision");
        current.Boundary.Series[precipPage].Rows[1].Values["Value"] = "2.75";
        current.Boundary.Series[windPage].Rows[1].Values["Value2"] = "-8.25";
        fields[stationScope + "/Name"] = "共享中文站点"; fields[stationScope + "/X"] = "101.5"; fields[stationScope + "/ElevationOffGround"] = "3.25";
        fields[precipScope + "/Interval"] = "1800";
        current = await ModelEditorAdapter.TransformSpatialAsync(new(Draft(current), "precipitation", "refresh", null));
        Check(current.Boundary!.Series[precipPage].Rows.Length == 5 && current.Boundary.Series[precipPage].Rows[1].Values["Value"] == "2.75", "Changing regular station interval refreshes derived rows while retaining actual values");
        current.Boundary.Series[precipPage].Rows[4].Values["Value"] = "9.5";
        current = await ModelEditorAdapter.TransformSpatialAsync(new(Draft(current), "airPressure", "addStation", null));
        var added = current.Boundary!.Spatial!["airPressure"].Stations.Last(); fields[added.Scope + "/Name"] = "新增站点";
        foreach (string layer in new[] { "precipitation", "evapotranspiration", "wind", "airPressure", "airDensity" })
        {
            current = await ModelEditorAdapter.TransformSpatialAsync(new(Draft(current), layer, "addGauge", stationId));
            string scope = current.Boundary!.Spatial![layer].Inputs.Last().Scope;
            fields[scope + "/Constant"] = layer == "airPressure" ? "1008.5" : "1.25";
            if (layer == "wind") fields[scope + "/Constant2"] = "-2.5";
        }
        Check(File.ReadAllBytes(filename).SequenceEqual(original), "Station creation, cross-layer inputs, edits and refresh are all unsaved source drafts");
        var saved = await ModelEditorAdapter.SaveAsync(Draft(current));
        Check(saved.Boundary!.Spatial!["precipitation"].Stations[0].Id == stationId && saved.Boundary.Series.ContainsKey(windPage), "Saving rebases shared station and input identities");
        using (var reread = new BoundaryCondition(filename, project))
        {
            Check(reread.MetStations.Count == 2 && reread.MetStations[0].Name == "共享中文站点" && reread.MetStations[0].Location.X == 101.5 && reread.MetStations[0].ElevationOffGround == 3.25f,
                "Independent original HDF reads verify station name, coordinates and height");
            Check(reread.Precipitation.Gauges[0].Table.SequenceEqual(new double[] { 1, 2.75, 3, double.NaN, 9.5 }) && reread.Precipitation.Gauges[0].TableTimeSeries.RTSTimeSpan == TimeSpan.FromMinutes(30),
                "Regular station edits extend only actual data and preserve missing values");
            Check(reread.Wind.Gauges[0].Table2[1] == -8.25 && reread.Wind.Gauges[0].TableTimeSeries.IrregularRelativeTimes.SequenceEqual(new double[] { .125, 3600.125 }),
                "Both wind components and unchanged relative subsecond timestamps persist exactly");
            Check(reread.AirPressure.Gauges.Single().Constant == 1008.5 && ReferenceEquals(reread.AirPressure.Gauges[0].Station, reread.Wind.Gauges[0].Station), "Shared station associations remain actual source references across layers");
        }
        fields.Clear(); byte[] savedBytes = File.ReadAllBytes(filename);
        fields[added.Scope + "/Name"] = "共享中文站点";
        await Reject<ValidationException>(() => ModelEditorAdapter.SaveAsync(Draft(saved))); fields.Clear();
        var forged = Draft(saved); forged.Rows![precipPage + "/Values"][0].Values["Forged"] = "1";
        await Reject<ArgumentException>(() => ModelEditorAdapter.SaveAsync(forged));
        saved = await ModelEditorAdapter.LoadAsync(new(filename, "Boundary Conditions", projectPath, SourceState: saved.SourceState));
        Check(File.ReadAllBytes(filename).SequenceEqual(savedBytes), "Rejected station names and unknown table columns preserve source bytes");
        var removed = await ModelEditorAdapter.TransformSpatialAsync(new(Draft(saved), "wind", "removeStation", stationId));
        Check(removed.Boundary!.Spatial!.Values.All(data => data.Inputs.All(input => input.StationId != stationId)) && File.ReadAllBytes(filename).SequenceEqual(savedBytes), "Shared station removal clears every source layer association in the draft");
        removed = await ModelEditorAdapter.SaveAsync(Draft(removed));
        using (var reread = new BoundaryCondition(filename, project)) Check(reread.MetStations.Count == 1 && reread.Precipitation.Gauges[0].Station == null && reread.Wind.Gauges[0].Table2[1] == -8.25,
            "Station deletion reopens without dangling references and preserves input values");
        await Reject<SourceFileChangedException>(() => ModelEditorAdapter.TransformSpatialAsync(new(Draft(saved), "wind", "addStation", null)));
        string remaining = removed.Boundary!.Spatial!["airDensity"].Stations.Single().Id;
        var empty = await ModelEditorAdapter.TransformSpatialAsync(new(Draft(removed), "airDensity", "addGauge", remaining));
        var emptyInput = empty.Boundary!.Spatial!["airDensity"].Inputs.Last();
        fields[emptyInput.Scope + "/LocalDataType"] = "Table"; fields[emptyInput.Scope + "/TimeSeriesType"] = "Irregular"; fields[emptyInput.Scope + "/ExpressedTimeType"] = "Absolute";
        empty = await ModelEditorAdapter.TransformSpatialAsync(new(Draft(empty), "airDensity", "refresh", null));
        string emptyPage = emptyInput.Scope + "/Time Series";
        Check(empty.Boundary!.Series[emptyPage].Rows.Length == 0, "New irregular source station inputs begin with zero actual rows");
        empty = await ModelEditorAdapter.TransformSeriesAsync(new(Draft(empty), emptyPage, "appendRow"));
        DateTime explicitLocal = DateTime.SpecifyKind(start.AddMilliseconds(125), DateTimeKind.Local);
        empty.Boundary!.Series[emptyPage].Rows[0].Values["Time"] = explicitLocal.ToString("O"); empty.Boundary.Series[emptyPage].Rows[0].Values["Value"] = "1.75";
        empty = await ModelEditorAdapter.SaveAsync(Draft(empty));
        using (var reread = new BoundaryCondition(filename, project)) Check(reread.AirDensity.Gauges.Last().Table.Single() == 1.75
            && reread.AirDensity.Gauges.Last().TableTimeSeries.IrregularAbsoluteTimes.Single() == explicitLocal
            && reread.AirDensity.Gauges.Last().TableTimeSeries.IrregularAbsoluteTimes.Single().Kind == DateTimeKind.Local,
            "Absolute irregular source timestamps preserve milliseconds and DateTime binary kind during HDF reload");
        Check(File.ReadAllBytes(projectPath).SequenceEqual(projectBytes), "Point data edits never overwrite project XML");
        if (Environment.GetEnvironmentVariable("HECRAS_SPATIAL_POINT_ACCEPTANCE_DIRECTORY") is string fixture)
        {
            if (Directory.Exists(fixture)) throw new IOException("Acceptance fixture destination already exists.");
            foreach (var file in fixtureFiles) { string target = Path.Combine(fixture, file.Key); Directory.CreateDirectory(Path.GetDirectoryName(target)!); File.WriteAllBytes(target, file.Value); }
        }
        Console.WriteLine("Actual five-layer station/input drafts, source tables, vector components, relative subsecond dates, HDF persistence and shared deletion passed.");
    }
    private static async Task Reject<T>(Func<Task<ModelSnapshot>> action) where T : Exception { try { await action(); } catch (T) { return; } throw new InvalidOperationException("Expected " + typeof(T).Name); }
    private static void Check(bool condition, string message) { if (!condition) throw new InvalidOperationException(message); }
}
