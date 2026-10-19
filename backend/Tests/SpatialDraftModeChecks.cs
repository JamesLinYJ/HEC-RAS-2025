using Geospatial.PairedData;
using Geospatial.Vectors;
using Ras.Backend;
using Ras.Layers;
using Ras.Layers.Meteorology;
using Utility.Units;

internal static class SpatialDraftModeChecks
{
    internal static async Task Run()
    {
        using var temporary = new TemporaryDirectory();
        string projectPath = Path.Combine(temporary.FullName, "输入模式草稿.ras");
        var project = Project.CreateNew(projectPath, UnitSystem.SI);
        var boundary = project.AddNewBoundaryCondition("模式保留", new DateTime(2026, 10, 16, 8, 0, 0), TimeSpan.FromHours(2));
        boundary.MetStations.Add(new MeteorologicStation("共享站点", new Point(1, 2)));
        project.Save(); string filename = boundary.Filename; boundary.Dispose();
        byte[] original = File.ReadAllBytes(filename), projectBytes = File.ReadAllBytes(projectPath);
        var current = await ModelEditorAdapter.LoadAsync(new(filename, "Boundary Conditions", projectPath));
        var fields = new Dictionary<string, string>();
        ModelSaveRequest Draft(ModelSnapshot snapshot) => new(filename, "Boundary Conditions", projectPath, snapshot.Revision, fields, [], SourceState: snapshot.SourceState,
            Rows: snapshot.Boundary!.Series.Values.Where(series => series.TableId != null).ToDictionary(series => series.TableId!, series => series.Rows));
        async Task Refresh() => current = await ModelEditorAdapter.TransformSpatialAsync(new(Draft(current), "precipitation", "refresh", null));
        string station = current.Boundary!.Spatial!["precipitation"].Stations[0].Id;
        current = await ModelEditorAdapter.TransformSpatialAsync(new(Draft(current), "precipitation", "addGauge", station));
        string scope = current.Boundary!.Spatial!["precipitation"].Inputs.Last().Scope, page = scope + "/Time Series";
        fields[scope + "/LocalDataType"] = "Table"; fields[scope + "/Interval"] = "3600";
        await Refresh(); Check(current.Boundary!.Series[page].Rows.Length == 3, "An empty new regular input shows derived rows");
        fields[scope + "/TimeSeriesType"] = "Irregular";
        await Refresh(); Check(current.Boundary!.Series[page].Rows.Length == 0, "Changing a newly created input to irregular does not turn regular padding into source rows");
        current = await ModelEditorAdapter.TransformSeriesAsync(new(Draft(current), page, "appendRow"));
        current = await ModelEditorAdapter.TransformSeriesAsync(new(Draft(current), page, "appendRow"));
        current.Boundary!.Series[page].Rows[0].Values["Value"] = "10"; current.Boundary.Series[page].Rows[1].Values["Value"] = "20";
        fields[scope + "/TimeSeriesType"] = "Regular"; fields[scope + "/Interval"] = "1800";
        await Refresh(); Check(current.Boundary!.Series[page].Rows.Length == 5, "Returning to regular derives timestamps while preserving actual input values");
        fields[scope + "/Interval"] = "900"; await Refresh();
        fields[scope + "/Interval"] = "600"; await Refresh();
        Check(current.Boundary!.Series[page].Rows.Length == 13 && current.Boundary.Series[page].Rows[1].Values["Value"] == "20", "Repeated unsaved interval changes use the prior draft projection rather than the original file projection");
        current.Boundary.Series[page].Rows[3].Values["Value"] = "33";
        current = await ModelEditorAdapter.TransformSeriesAsync(new(Draft(current), page, "clear"));
        await Refresh();
        fields[scope + "/LocalDataType"] = "Constant"; fields[scope + "/Constant"] = "7.5";
        await Refresh();
        Check(current.Boundary!.Spatial!["precipitation"].Inputs[0].PageId == null && current.Boundary.Series[page].Rows.Length == 4
            && current.Boundary.Series[page].Operations.Length == 0 && current.Boundary.Series[page].Columns.All(column => column.ReadOnly),
            "Constant mode retains the hidden table's actual cleared row count without advertising editing operations");
        Check(File.ReadAllBytes(filename).SequenceEqual(original), "All mode and interval transitions remain unsaved drafts");
        current = await ModelEditorAdapter.SaveAsync(Draft(current)); fields.Clear();
        using (var actual = new BoundaryCondition(filename, project))
            Check(actual.Precipitation.Gauges[0].LocalDataType == LocalDataType.Constant && actual.Precipitation.Gauges[0].Constant == 7.5
                && actual.Precipitation.Gauges[0].Table.Length == 4 && actual.Precipitation.Gauges[0].Table.All(double.IsNaN)
                && actual.Precipitation.Gauges[0].TableTimeSeries.RTSTimeSpan == TimeSpan.FromMinutes(10), "Independent source reads preserve all-missing arrays and time metadata even in constant mode");
        fields[scope + "/LocalDataType"] = "Table"; await Refresh();
        current.Boundary!.Series[page].Rows[2].Values["Value"] = "77";
        fields[scope + "/DataLocation"] = "Remote"; await Refresh();
        Check(current.Boundary!.Series[page].Rows.Length == 4 && current.Boundary.Series[page].Rows[2].Values["Value"] == "77", "Remote metadata mode retains locally edited table values in the same draft");
        current = await ModelEditorAdapter.SaveAsync(Draft(current)); fields.Clear();
        using (var actual = new BoundaryCondition(filename, project)) Check(actual.Precipitation.Gauges[0].DataLocation == DataLocation.Remote
            && actual.Precipitation.Gauges[0].Table[2] == 77 && actual.Precipitation.Gauges[0].Table.Length == 4, "Source HDF independently retains hidden local data across a remote mode save");
        fields[scope + "/DataLocation"] = "Local"; await Refresh();
        Check(current.Boundary!.Series[page].Rows.Length == 13 && current.Boundary.Series[page].Rows[2].Values["Value"] == "77", "Returning to local mode restores the real saved table");
        Check(File.ReadAllBytes(projectPath).SequenceEqual(projectBytes), "Input mode editing leaves project XML untouched");
        Console.WriteLine("New input mode transitions, repeated draft intervals, padding isolation and hidden cleared/remote table persistence passed.");
    }
    private static void Check(bool condition, string message) { if (!condition) throw new InvalidOperationException(message); }
}
