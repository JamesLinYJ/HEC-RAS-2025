using System.Drawing;
using System.Numerics;
using Geospatial.GDALAssist;
using Geospatial.IO;
using Geospatial.Rasters;
using Geospatial.Rendering.Layers;
using Geospatial.Transformers;
using Geospatial.Vectors;
using Utility.Memory;

namespace Ras.Backend;

/// <summary>Constructs the same three source renderer families as the retained importer.</summary>
internal static class MapRasterLayerRendering
{
    internal const string SingleBandMapType = "SingleBandRasterMapLayer";
    internal const string ImageMapType = "ImageRasterMapLayer";
    internal const string DiscreteMapType = "DiscreteRasterMapLayer";

    internal static string[] SupportedTypes { get; } = [SingleBandMapType, ImageMapType, DiscreteMapType];

    internal static string ResolveMapType(GDALRaster raster)
    {
        Type? dataType = raster.GetDataType();
        int bands = raster.GetBandCount();
        if (bands == 1 && (Equivalent(dataType, typeof(float)) || Equivalent(dataType, typeof(double))))
            return SingleBandMapType;
        if (bands == 3 && Equivalent(dataType, typeof(byte))) return ImageMapType;
        if (bands == 1 && (Equivalent(dataType, typeof(int)) || Equivalent(dataType, typeof(uint)) ||
                            Equivalent(dataType, typeof(byte)))) return DiscreteMapType;
        throw new NotSupportedException("The GDAL raster is readable, but its band count and cell type do not match a supported source map layer.");
    }

    internal static IDisposableRenderer Open(string sourcePath, string mapLayerType, Projection? targetProjection)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(sourcePath);
        string actualType;
        using (var metadata = new GDALRaster(sourcePath)) actualType = ResolveMapType(metadata);
        if (!string.Equals(actualType, mapLayerType, StringComparison.Ordinal))
            throw new SourceFileChangedException();

        return mapLayerType switch
        {
            SingleBandMapType => OpenSingleBand(sourcePath, targetProjection),
            ImageMapType => OpenImage(sourcePath, targetProjection),
            DiscreteMapType => OpenDiscrete(sourcePath, targetProjection),
            _ => throw new NotSupportedException("The selected raster map type is not supported.")
        };
    }

    internal sealed class IDisposableRenderer : IDisposable
    {
        public Geospatial.Rendering.Layers.IRenderLayer Layer { get; }
        private readonly IDisposable? cleanup;
        internal IDisposableRenderer(Geospatial.Rendering.Layers.IRenderLayer layer, IDisposable? cleanup = null)
        { Layer = layer; this.cleanup = cleanup; }
        public void Dispose() => cleanup?.Dispose();
    }

    private static IDisposableRenderer OpenSingleBand(string path, Projection? targetProjection)
    {
        using var metadata = new GDALRaster(path);
        Type dataType = metadata.GetDataType();
        IResample<float>? resampler;
        IDisposable? cleanup;
        if (Equivalent(dataType, typeof(float)))
        {
            resampler = RasterReader.TryGetBestRasterizer<float>(path, out _, out cleanup);
        }
        else
        {
            IResample<double>? doubleResampler = RasterReader.TryGetBestRasterizer<double>(path,
                out _, out cleanup);
            if (doubleResampler is null)
                throw new InvalidDataException("The retained GDAL double-precision raster reader could not open the selected source.");
            resampler = doubleResampler.ConvertType(ConvertTypeResamplers.DoubleToFloatConverter,
                (float?)doubleResampler.NoDataValue);
        }
        if (resampler is null)
        {
            cleanup?.Dispose();
            throw new InvalidDataException("The retained GDAL raster reader could not open the selected source.");
        }
        try
        {
            Projection? sourceProjection = metadata.GetProjection();
            if (targetProjection is not null && sourceProjection is not null && !targetProjection.IsEqual(sourceProjection))
                resampler = resampler.WithTransformer(new ReprojectionTransformer(sourceProjection, targetProjection));
            var layer = new RasterRenderLayer(resampler);
            bool canResampleEfficiently = metadata.GetPyramidDefinition().CanResampleEfficiently(
                RasterLayerSymbologyOptions.Default().MaxBytesToSample / 4);
            if (canResampleEfficiently) layer.SetDefaultTerrainHistoSymbology();
            else layer.SetGrayscaleLinearSymbology(0d, 100d);
            return new IDisposableRenderer(layer, cleanup);
        }
        catch
        {
            cleanup?.Dispose();
            throw;
        }
    }

    private static IDisposableRenderer OpenImage(string path, Projection? targetProjection)
    {
        using var metadata = new GDALRaster(path);
        Projection? sourceProjection = metadata.GetProjection();
        GdalBandedRaster<byte> source = GdalBandedRaster<byte>.Pooled(path, out Pool<GDALRaster> pool);
        source.AllowParallelResampling = false;
        try
        {
            IMultiBandResampler<byte> resampler = source;
            if (targetProjection is not null && sourceProjection is not null && !targetProjection.IsEqual(sourceProjection))
                resampler = resampler.WithTransformer(new ReprojectionTransformer(sourceProjection, targetProjection));
            return new IDisposableRenderer(new ImageRenderLayer(resampler), new RasterPoolCleanup(pool));
        }
        catch
        {
            pool.ClearAll(raster => raster.Dispose());
            throw;
        }
    }

    private static IDisposableRenderer OpenDiscrete(string path, Projection? targetProjection)
    {
        using var metadata = new GDALRaster(path);
        Projection? sourceProjection = metadata.GetProjection();
        Type dataType = metadata.GetDataType();
        Tuple<byte, byte, byte, byte>[]? colors = metadata.GetColorMap(1);
        IDisposable? cleanup = null;
        try
        {
            DiscreteRasterRenderLayer layer;
            if (Equivalent(dataType, typeof(int)))
            {
                IResample<int> resampler = OpenDiscreteSource<int>(path, sourceProjection, targetProjection, out cleanup);
                layer = new DiscreteRasterRenderLayer(resampler);
            }
            else if (Equivalent(dataType, typeof(uint)))
            {
                IResample<uint> typed = OpenDiscreteSource<uint>(path, sourceProjection, targetProjection, out cleanup);
                IResample<int> resampler = ConvertDiscrete(typed);
                layer = new DiscreteRasterRenderLayer(resampler);
            }
            else if (Equivalent(dataType, typeof(byte)))
            {
                IResample<byte> typed = OpenDiscreteSource<byte>(path, sourceProjection, targetProjection, out cleanup);
                IResample<int> resampler = ConvertDiscrete(typed);
                layer = new DiscreteRasterRenderLayer(resampler);
            }
            else throw new NotSupportedException("The discrete raster renderer supports one byte, Int32, or UInt32 band.");

            if (colors is not null)
            {
                int noData = layer.NoDataValue;
                for (int value = 0; value < colors.Length; value++)
                {
                    if (value == noData) continue;
                    Tuple<byte, byte, byte, byte> color = colors[value];
                    layer.ColorMap.SetColor(value, Color.FromArgb(color.Item4, color.Item1, color.Item2, color.Item3));
                }
            }
            return new IDisposableRenderer(layer, cleanup);
        }
        catch
        {
            cleanup?.Dispose();
            throw;
        }
    }

    private static IResample<T> OpenDiscreteSource<T>(string path, Projection? sourceProjection,
        Projection? targetProjection, out IDisposable? cleanup) where T : unmanaged, IEquatable<T>
    {
        // Preserve the source context's fast TIFF reader where it can open the
        // dataset, and keep a GDAL resampler fallback for every other driver.
        TiffDataSource<T>? tiff = TiffDataSource<T>.TryLoad(path);
        cleanup = tiff;
        IResample<T> resampler = tiff is not null
            ? tiff.AsRasterizer()
            : new GdalBandedRaster<T>(path) { AllowParallelResampling = false }.AsSingleProfile(0);
        if (targetProjection is not null && sourceProjection is not null && !targetProjection.IsEqual(sourceProjection))
            resampler = resampler.WithTransformer(new ReprojectionTransformer(sourceProjection, targetProjection));
        return resampler;
    }

    private static IResample<int> ConvertDiscrete<T>(IResample<T> source) where T : unmanaged, INumber<T>
    {
        // Match DiscreteRasterMapLayerVisualContext: absent source no-data is
        // converted from T's default value, which is zero for the supported
        // integer cell types.
        int noData = int.CreateSaturating(source.NoDataValue.GetValueOrDefault());
        return new ConvertTypeResampler<T, int>(source, (Memory<T> input, Memory<int> output) =>
        {
            Span<T> inputSpan = input.Span;
            Span<int> outputSpan = output.Span;
            for (int index = 0; index < outputSpan.Length; index++)
                outputSpan[index] = int.CreateSaturating(inputSpan[index]);
        }, noData);
    }

    private static bool Equivalent(Type? candidate, Type expected) =>
        candidate is not null && candidate.IsEquivalentTo(expected);

    private sealed class RasterPoolCleanup : IDisposable
    {
        private readonly Pool<GDALRaster> pool;
        internal RasterPoolCleanup(Pool<GDALRaster> pool) => this.pool = pool;
        public void Dispose() => pool.ClearAll(raster => raster.Dispose());
    }
}
