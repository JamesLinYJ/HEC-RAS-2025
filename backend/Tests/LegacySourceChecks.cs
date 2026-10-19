using Geospatial.GDALAssist;
using OSGeo.GDAL;
using RasMapperLib;
using RasMapperLib.Functional;
using RasMapperLib.Mapping;

internal static class LegacySourceChecks
{
    internal static void Run()
    {
        Check(OutputModes.DynamicPoint.IsPoint && OutputModes.StoredPoint.IsPoint && !OutputModes.DynamicSurface.IsPoint, "Source output modes distinguish point and surface maps");
        var regular = new RegularTimeSeries(new DateTime(2026, 1, 1), new double[] { 1, 2 }, TimeSpan.FromHours(1));
        regular.set_Value(1, 7);
        Check(regular.get_Value(1) == 7, "Regular series setter uses its actual argument");
        var irregular = new IrregularTimeSeries(new double[] { 1, 2 }, new DateTime[] { new(2026, 1, 1), new(2026, 1, 2) });
        irregular.set_Value(0, 9);
        Check(irregular.get_Value(0) == 9, "Irregular series setter uses its actual argument");
        var arrayHelpers = typeof(RegularTimeSeries).Assembly.GetType("RasMapperLib.ArrayExtensionMethods", throwOnError: true)!;
        var resizeAndFill = arrayHelpers.GetMethods(System.Reflection.BindingFlags.Public | System.Reflection.BindingFlags.Static)
            .Single(method => method.Name == "SetAll" && method.GetParameters().Length == 3)
            .MakeGenericMethod(typeof(int));
        object[] resizeArguments = [Array.Empty<int>(), 4, 3];
        resizeAndFill.Invoke(null, resizeArguments);
        var resized = (int[])resizeArguments[0];
        Check(resized.SequenceEqual(new[] { 4, 4, 4 }), "VB array replacement retains by-reference assignment");
        var raster = new RasterM(1, 2, 2, 0, 1, 0);
        var wind = new TableWindLayer("Wind", new float[] { 3, 0 }, new float[] { 4, 12 }, raster);
        float[] magnitude = null!;
        Check(wind.Resample(raster, ref magnitude) && magnitude.SequenceEqual(new float[] { 5, 12 }), "Table wind maps source vector magnitudes using its real native grid");
        Check(!new TableWindLayer().Resample(raster, ref magnitude), "A table without a native grid does not report successful resampling");

        using var directory = new TemporaryDirectory();
        string filename = Path.Combine(directory.FullName, "多波段.tif");
        using (var driver = Gdal.GetDriverByName("GTiff"))
        using (var dataset = driver.Create(filename, 2, 1, 2, DataType.GDT_Float32, []))
        {
            dataset.SetGeoTransform(new double[] { 0, 1, 0, 1, 0, -1 });
            using var first = dataset.GetRasterBand(1);
            using var second = dataset.GetRasterBand(2);
            first.WriteRaster(0, 0, 2, 1, new float[] { 1, 2 }, 2, 1, 0, 0);
            second.WriteRaster(0, 0, 2, 1, new float[] { 7, 8 }, 2, 1, 0, 0);
        }
        var source = new MultiBandInterpolatedLayer(filename);
        float[] values = null!;
        DateTime[] times = null!;
        Check(source.GetTimeSeries(new PointM(.5, .5), ref values, ref times) && values.SequenceEqual(new float[] { 1, 7 }), "Legacy raster layer reads actual native TIFF bands");
        using (var dataset = Gdal.Open(filename, Access.GA_Update))
        using (var first = dataset.GetRasterBand(1)) first.WriteRaster(0, 0, 2, 1, new float[] { 42, 2 }, 2, 1, 0, 0);
        source.ResetData();
        Check(source.GetTimeSeries(new PointM(.5, .5), ref values, ref times) && values[0] == 42, "Reset invalidates loaded raster data before reading changed input");
        Console.WriteLine("Legacy source time series, wind grid, output modes and native raster reload checks passed on this Mac.");
    }
    private static void Check(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }
}
