using System.Security.Cryptography;
using System.Globalization;
using Geospatial.GDALAssist;
using OSGeo.GDAL;
using Ras.Backend;

internal static class RasterImportContextPropertiesChecks
{
    internal static void Run()
    {
        GDALSetup.InitializeMultiplatform();
        using var directory = new TemporaryDirectory();
        string rasterPath = Path.Combine(directory.FullName, "selected-dem.tif");
        Projection local = new EPSGProjection(32610);
        WriteRaster(rasterPath, local);
        byte[] original = File.ReadAllBytes(rasterPath);
        string expectedRevision = Convert.ToHexString(SHA256.HashData(original));

        RasterImportContextPropertiesSnapshot matching = RasterImportContextPropertiesService.Inspect(
            new RasterImportContextPropertiesRequest([rasterPath], local.GetWKT()));
        RasterImportContextSource source = matching.Sources.Single();
        Check(source.Path == SourceFilePaths.Canonical(rasterPath) && source.Revision == expectedRevision &&
              source.Error is null && source.Info is not null && source.Stats is not null,
            "The raster property snapshot is bound to the exact source path and SHA-256 revision.");
        Check(source.Info is { FileName: "selected-dem.tif", BandCount: 1,
                  ProjectionFriendlyText: "Matches Local", Driver: not null,
                  Size: not null, UncompressedSize: not null, CompressionRatio: not null } info &&
              info.OverviewsCount == info.Overviews?.Length && info.Overviews?.Length > 0 &&
              info.CellSize == 1d.ToString("F2", CultureInfo.CurrentCulture) && info.UnitSystem == "SI",
            "Raster file and summary properties use the actual GDAL driver, units, cell size, byte sizes and overview pyramid.");
        Check(source.Stats is { Min.Length: > 0, Max.Length: > 0,
                  Mean.Length: > 0, StandardDeviation.Length: > 0 },
            "Statistics retain the source GDAL ReadStats values as display strings.");

        RasterImportContextPropertiesSnapshot differentProjection = RasterImportContextPropertiesService.Inspect(
            new RasterImportContextPropertiesRequest([rasterPath], new EPSGProjection(4326).GetWKT()));
        Check(differentProjection.Sources.Single().Info?.ProjectionFriendlyText == "Differs from Local",
            "Projection comparison reflects the exact target projection rather than a name-only match.");
        Check(File.ReadAllBytes(rasterPath).SequenceEqual(original),
            "Raster property inspection leaves the selected raster bytes unchanged.");

        Expect<ArgumentException>(() => RasterImportContextPropertiesService.Inspect(
            new RasterImportContextPropertiesRequest([rasterPath, Path.Combine(directory.FullName, ".", "selected-dem.tif")])),
            "The same canonical source cannot appear twice in one inspection request.");
    }

    private static void WriteRaster(string path, Projection projection)
    {
        using var driver = Gdal.GetDriverByName("GTiff");
        using var dataset = driver.Create(path, 8, 8, 1, DataType.GDT_Float32, ["TILED=YES"]);
        dataset.SetGeoTransform([0, 1, 0, 8, 0, -1]);
        dataset.SetProjection(projection.GetWKT());
        using Band band = dataset.GetRasterBand(1);
        float[] values = Enumerable.Range(0, 64).Select(value => (float)value).ToArray();
        band.WriteRaster(0, 0, 8, 8, values, 8, 8, 0, 0);
    }

    private static void Check(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }

    private static void Expect<TError>(Action action, string message) where TError : Exception
    {
        try { action(); }
        catch (TError) { return; }
        throw new InvalidOperationException(message);
    }
}
