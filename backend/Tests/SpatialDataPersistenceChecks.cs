using Geospatial.PairedData;
using Geospatial.Rasters;
using Geospatial.Vectors;
using H5Assist;
using Ras.Layers;
using Ras.Layers.Meteorology;
using Utility.Units;

internal static class SpatialDataPersistenceChecks
{
    internal static void Run()
    {
        using var directory = new TemporaryDirectory();
        string projectPath = Path.Combine(directory.FullName, "空间数据保留.ras");
        var project = Project.CreateNew(projectPath, UnitSystem.SI);
        DateTime start = new(2026, 10, 16, 8, 0, 0);
        var boundary = project.AddNewBoundaryCondition("实际点格网", start, TimeSpan.FromHours(2));
        var station = new MeteorologicStation("共享中文站点", new Point(100, 200));
        Check(station.GetActualElevationOffGround(UnitSystem.SI) == 20 && station.GetActualElevationOffGround(UnitSystem.USCustomary) == 70,
            "Missing station elevation uses the actual source SI/US defaults rather than comparing NaN for equality");
        station.ElevationOffGround = 3.5f;
        Check(station.GetActualElevationOffGround(UnitSystem.SI) == 3.5f && station.GetActualElevationOffGround(UnitSystem.USCustomary) == 3.5f,
            "Explicit station elevation retains its source value");
        boundary.MetStations.Add(station);
        boundary.Precipitation.Gauges.Add(MetGaugedData.FromTableData(station, TimeSeriesDefinition.Regular(Time.Hours, 1), [1, 2, 3]));
        var windGauge = MetGaugedData.FromTableData(station, TimeSeriesDefinition.Regular(Time.Hours, 1), [4, 5, 6]);
        windGauge.Table2 = [7, 8, 9]; boundary.Wind.Gauges.Add(windGauge);
        project.Save(); string filename = boundary.Filename;
        var definition = new RasterDefinition(new Point(0, 2), 1, 2, 2);
        var raster = new MemoryBandedRaster<float>(definition, [new float[] { 1, 2, 3, 4 }, new float[] { 5, 6, 7, 8 }]);
        boundary.AirPressure.ImportRaster(raster.AsTimeSeriesRaster([start, start.AddHours(1)]), null!, "inst-val", "mbar");
        boundary.AirPressure.SetDefault();
        project.Save(); boundary.Dispose();
        using (var actual = new BoundaryCondition(filename, project))
        {
            Check(actual.Precipitation.Gauges.Count == 1 && actual.Wind.Gauges.Count == 1,
                "Changing to disabled default scalar mode preserves stored point inputs in every source layer");
            Check(actual.Precipitation.Gauges[0].Table.SequenceEqual(new double[] { 1, 2, 3 })
                && actual.Wind.Gauges[0].Table2.SequenceEqual(new double[] { 7, 8, 9 }), "Independent HDF source reads retain scalar and vector gauge tables");
            Check(ReferenceEquals(actual.Precipitation.Gauges[0].Station, actual.Wind.Gauges[0].Station)
                && actual.MetStations[0].Name == "共享中文站点", "Layer gauges resolve to the same actual shared station");
            actual.AirPressure.SpatialDataType = SpatialDataType.Gridded;
            Check(actual.AirPressure.GetNativeGriddedRaster(out var imported, out _).Result && imported.ProfileCount == 2
                && imported.GetBand(0).SequenceEqual(new float[] { 1, 2, 3, 4 }) && imported.GetBand(1).SequenceEqual(new float[] { 5, 6, 7, 8 }),
                "Switching to disabled default mode preserves the actual imported raster, times and source pixel bands");
            actual.MetStations.Remove(actual.MetStations[0]);
            Check(actual.Precipitation.Gauges[0].Station == null && string.IsNullOrEmpty(actual.Precipitation.Gauges[0].StationName)
                && actual.Wind.Gauges[0].Station == null && string.IsNullOrEmpty(actual.Wind.Gauges[0].StationName),
                "Removing a loaded station clears both live and persisted references across source layers");
            actual.Save();
        }
        using (var actual = new BoundaryCondition(filename, project))
        {
            Check(actual.MetStations.Count == 0 && actual.Precipitation.Gauges.Count == 1 && actual.Precipitation.Gauges[0].Station == null
                && actual.Precipitation.Gauges[0].Table.SequenceEqual(new double[] { 1, 2, 3 }),
                "After station removal the original gauge data can reopen without a dangling-name load failure");
        }
        Console.WriteLine("Actual source point/grid persistence across default-mode switches, shared station removal/reopen and NaN elevation defaults passed.");
    }
    private static void Check(bool condition, string message) { if (!condition) throw new InvalidOperationException(message); }
}
