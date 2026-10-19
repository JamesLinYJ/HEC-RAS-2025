using System.Security.Cryptography;
using System.Xml.Linq;
using Geospatial.Rasters;
using OSGeo.GDAL;
using Ras.Backend;
using Ras.Layers;
using Utility.Units;

internal static class SpatialGridChecks
{
    internal static async Task Run()
    {
        using var temporary = new TemporaryDirectory();
        string root = temporary.FullName, path = Path.Combine(root, "格网集成.ras");
        var project = Project.CreateNew(path, UnitSystem.SI);
        DateTime start = new(2026, 10, 16, 8, 0, 0);
        var boundary = project.AddNewBoundaryCondition("真实气象格网", start, TimeSpan.FromHours(2));
        project.Save(); string asset = boundary.Filename; boundary.Dispose();
        byte[] xml = File.ReadAllBytes(path);
        string pressure = Raster("气压.tif", 100000, "Pa"), x = Raster("风场X.tif", 3, "m/s"), y = Raster("风场Y.tif", 7, "m/s"), rain = Raster("降水.tif", .25, "in/hr");
        string Raster(string name, double first, string units)
        {
            string file = Path.Combine(root, name);
            using var driver = Gdal.GetDriverByName("GTiff");
            using var dataset = driver.Create(file, 16, 16, 2, DataType.GDT_Float32, ["TILED=YES", "BLOCKXSIZE=16", "BLOCKYSIZE=16"]);
            dataset.SetGeoTransform([100, 1, 0, 216, 0, -1]);
            for (int bandIndex = 1; bandIndex <= 2; bandIndex++)
            {
                using var band = dataset.GetRasterBand(bandIndex);
                band.Fill(first + (name.StartsWith("气压", StringComparison.Ordinal) ? 1000 : 1) * (bandIndex - 1), 0);
                band.SetMetadataItem("Timestamp", start.AddHours(bandIndex - 1).ToString("yyyy-MM-dd HH:mm:ss"), "");
                band.SetMetadataItem("units", units, ""); band.SetNoDataValue(-9999);
                if (name.StartsWith("气压", StringComparison.Ordinal) && bandIndex == 1)
                    band.WriteRaster(0, 0, 1, 1, new float[] { -9999 }, 1, 1, 0, 0);
            }
            // Use a genuine timestamped GDAL VRT. The retained parser exposes
            // VRT timestamps, while plain TIFFs require explicit UI timestamps.
            dataset.FlushCache();
            var vrt = new XElement("VRTDataset", new XAttribute("rasterXSize", 16), new XAttribute("rasterYSize", 16),
                new XElement("GeoTransform", "100,1,0,216,0,-1"));
            for (int index = 1; index <= 2; index++) vrt.Add(new XElement("VRTRasterBand", new XAttribute("dataType", "Float32"), new XAttribute("band", index),
                new XElement("NoDataValue", -9999), new XElement("Metadata",
                    new XElement("MDI", new XAttribute("key", "Timestamp"), start.AddHours(index - 1).ToString("yyyy-MM-dd HH:mm:ss")),
                    new XElement("MDI", new XAttribute("key", "units"), units)),
                new XElement("SimpleSource", new XElement("SourceFilename", new XAttribute("relativeToVRT", 1), name), new XElement("SourceBand", index),
                    new XElement("SrcRect", new XAttribute("xOff", 0), new XAttribute("yOff", 0), new XAttribute("xSize", 16), new XAttribute("ySize", 16)),
                    new XElement("DstRect", new XAttribute("xOff", 0), new XAttribute("yOff", 0), new XAttribute("xSize", 16), new XAttribute("ySize", 16)))));
            string manifest = Path.ChangeExtension(file, ".vrt"); vrt.Save(manifest); return manifest;
        }
        var current = await ModelEditorAdapter.LoadAsync(new(asset, "Boundary Conditions", path));
        ModelSaveRequest Draft() => new(asset, "Boundary Conditions", path, current.Revision, [], [], SourceState: current.SourceState);
        string Hash() => Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(asset)));
        string original = Hash();
        var inspection = await ModelEditorAdapter.InspectGridAsync(new(Draft(), "airPressure", [pressure]));
        Check(inspection.Bands.Length == 2 && inspection.Bands.All(band => band.Time != null) && inspection.Preview?.Minimum == 100000,
            "Inspection reads actual GDAL bands, timestamps, units and pixel preview");
        Check(inspection.Units == "Pa" && Hash() == original, "Inspection preserves source units and does not save HDF");
        Check(inspection.Preview!.Rgba[3] == 0, "Source NoData remains transparent in the native raster preview");
        var invalid = inspection.Bands.Select(band => band with { Time = inspection.Bands[0].Time }).ToArray();
        await Reject<ArgumentException>(() => ModelEditorAdapter.ImportGridAsync(new(Draft(), new("airPressure", invalid, "Pa", "inst-val"))));
        Check(Hash() == original, "Rejected overlapping timesteps preserve original HDF");
        var savedRequest = Draft() with { Fields = new() { ["BoundaryConditionsSummary/BoundaryCondition_Description"] = "格网与草稿同时保存" } };
        current = await ModelEditorAdapter.ImportGridAsync(new(savedRequest, new("airPressure", inspection.Bands, "Pa", "inst-val")));
        Check(current.Grids!["airPressure"].Times.Length == 2, "Saved grid exposes actual HDF timesteps");
        using (var actual = new BoundaryCondition(asset, project))
        {
            bool opened = actual.AirPressure.GetNativeGriddedRaster(out var data, out _).Result;
            Check(actual.Description == "格网与草稿同时保存" && opened,
                "Grid import and captured model metadata persist together");
            Check(data.GetBand(0)[0] == -9999 && data.GetBand(0).Skip(1).All(value => Math.Abs(value - 1000) < 1e-4) && data.GetBand(1).All(value => Math.Abs(value - 1010) < 1e-4),
                "Independent source HDF reads actual Pa-to-millibar grid conversion");
        }
        original = Hash();
        var frame = await ModelEditorAdapter.GridFrameAsync(new(Draft(), "airPressure", current.Grids!["airPressure"].Times[1]));
        Check(frame.Preview?.Minimum == 1010 && frame.Preview.Maximum == 1010 && Hash() == original, "Selecting a frame reads actual HDF pixels without saving");
        await Reject<ArgumentException>(() => ModelEditorAdapter.GridFrameAsync(new(Draft(), "airPressure", "missing")));
        var wind = await ModelEditorAdapter.InspectGridAsync(new(Draft(), "wind", [x, y]));
        var paired = wind.Bands.Select(band => band with { Component = band.File == x ? "X" : "Y" }).ToArray();
        await Reject<ArgumentException>(() => ModelEditorAdapter.ImportGridAsync(new(Draft(), new("wind", wind.Bands, "m/s", "inst-val"))));
        Check(Hash() == original, "Missing wind component rejects the complete import without replacing HDF");
        current = await ModelEditorAdapter.ImportGridAsync(new(Draft(), new("wind", paired, "m/s", "inst-val")));
        using (var actual = new BoundaryCondition(asset, project))
        {
            Check(actual.Wind.GetNativeGriddedRaster(out var data, out _).Result, "Source wind grid opens");
            float[] vx = new float[256], vy = new float[256], magnitude = new float[256];
            data.ResampleVxVy(new ResampleArgs(data.RasterDefinition), 0, vx, vy, magnitude);
            Check(vx.All(value => value == 3) && vy.All(value => value == 7), "Source wind reader retains independent X/Y rasters rather than using X twice");
        }
        var windFrame = await ModelEditorAdapter.GridFrameAsync(new(Draft(), "wind", current.Grids!["wind"].Times[0], "Y"));
        Check(windFrame.Preview?.Minimum == 7, "Wind Y frame reads the actual second component");
        var precipitation = await ModelEditorAdapter.InspectGridAsync(new(Draft(), "precipitation", [rain]));
        current = await ModelEditorAdapter.ImportGridAsync(new(Draft(), new("precipitation", precipitation.Bands, "in/hr", "per-avg")));
        using (var actual = new BoundaryCondition(asset, project))
        {
            actual.Precipitation.GetNativeGriddedRaster(out var data, out _);
            Check(data.GetBand(0).All(value => Math.Abs(value - 6.35) < 1e-4), "Original precipitation importer converts inch/hour raster to SI millimeter/hour");
        }
        original = Hash();
        File.AppendAllText(Path.ChangeExtension(pressure, ".tif"), "source changed");
        await Reject<SourceFileChangedException>(() => ModelEditorAdapter.ImportGridAsync(new(Draft(), new("airPressure", inspection.Bands, "Pa", "inst-val"))));
        Check(Hash() == original && File.ReadAllBytes(path).SequenceEqual(xml), "Stale source rasters reject import; project XML is never implicitly saved");
        string? fixture = Environment.GetEnvironmentVariable("HECRAS_GRID_FIXTURE_DIRECTORY");
        if (!string.IsNullOrEmpty(fixture))
        {
            foreach (string source in Directory.EnumerateFiles(root, "*", SearchOption.AllDirectories))
            {
                string target = Path.Combine(fixture, Path.GetRelativePath(root, source));
                Directory.CreateDirectory(Path.GetDirectoryName(target)!); File.Copy(source, target, true);
            }
        }
        using (var remote = new BoundaryCondition(asset, project)) { remote.AirPressure.GridDataLocation = Ras.Layers.Meteorology.DataLocation.Remote; remote.Save(); }
        await DssGridImportChecks.Run();
        var remoteState = await ModelEditorAdapter.LoadAsync(new(asset, "Boundary Conditions", path));
        Check(remoteState.Grids!["airPressure"].Times.Length == 0 && remoteState.Grids["airPressure"].Error != null,
            "Remote mode reports its actual source limitation rather than displaying a retained local raster as active remote data");
        Console.WriteLine("Actual grid inspection, atomic model import, pressure/precipitation conversion, independent wind components, HDF frames and stale-file rejection passed.");
    }
    private static void Check(bool condition, string message) { if (!condition) throw new InvalidOperationException(message); }
    private static async Task Reject<T>(Func<Task> operation) where T : Exception
    {
        try { await operation(); } catch (T) { return; }
        throw new InvalidOperationException("Expected " + typeof(T).Name);
    }
}
