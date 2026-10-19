using System;
using System.Buffers;
using System.Threading;
using Geospatial.Rasters;
using Geospatial.Rendering.Recolor;
using Geospatial.Vectors;
using Utility.Memory;

namespace Geospatial.Rendering.Layers;

public class ImageRenderLayer : RenderLayer
{
	private readonly IMultiBandResampler<byte> _raster;

	private long _version = 1L;

	private byte _opacity = byte.MaxValue;

	public override Extent ValidExtent { get; }

	public long Version => _version;

	public byte Opacity
	{
		get
		{
			return _opacity;
		}
		set
		{
			_opacity = value;
			Interlocked.Increment(ref _version);
		}
	}

	public IRecolorer Recolorer { get; set; }

	public ImageRenderLayer(IMultiBandResampler<byte> raster)
	{
		ValidExtent = raster.ValidExtent;
		_raster = raster;
	}

	protected override bool RenderInternal(PlotRequest request, ref object cache)
	{
		if (!request.RasterQuery.Extent.Overlaps(ValidExtent))
		{
			return false;
		}
		if (_raster.ProfileCount == 1)
		{
			RenderSingleBandInternal(request);
			return true;
		}
		if (_raster.ProfileCount == 3)
		{
			Render3BandDataInternal(request);
			return true;
		}
		if (_raster.ProfileCount == 4)
		{
			throw new NotImplementedException();
		}
		return false;
	}

	private void RenderSingleBandInternal(PlotRequest request)
	{
		ResampleArgs args = new ResampleArgs(request.RasterQuery);
		RasterDefinition rasterQuery = request.RasterQuery;
		int cellCount = rasterQuery.CellCount;
		PixelRange pixelRange = rasterQuery.GetPixelRange(ValidExtent).ClipTo(rasterQuery);
		Memory<byte> mem;
		using (SharedMemoryPool<byte>.Rent(cellCount, out mem))
		{
			_raster.Resample(args, 0, mem);
			Memory<int> mem2;
			using (SharedMemoryPool<int>.Rent(cellCount, 0, out mem2))
			{
				Span<int> mem2Span = mem2.Span;
				if (Recolorer == null)
				{
					if (!pixelRange.IsNull())
					{
						Span<byte> memSpan = mem.Span;
						int opacityTerm = Opacity << 24;
						int cols = rasterQuery.Cols;
						for (int i = pixelRange.MinRow; i <= pixelRange.MaxRow; i++)
						{
							int colsTerm = i * cols;
							for (int j = pixelRange.MinCol; j <= pixelRange.MaxCol; j++)
							{
								int index = colsTerm + j;
								byte b = memSpan[index];
								mem2Span[index] = opacityTerm | (b << 16) | (b << 8) | b;
							}
						}
					}
					request.Splat(mem2Span);
				}
				else
				{
					Recolorer.RecolorBrightness(mem, mem2);
					RasterOperations.PreserveRegion(rasterQuery, mem2, ValidExtent, 0);
					request.SplatPremultiplied(mem2Span);
				}
			}
		}
	}

	private void Render3BandDataInternal(PlotRequest request)
	{
		ResampleArgs args = new ResampleArgs(request.RasterQuery);
		RasterDefinition rasterQuery = request.RasterQuery;
		int cellCount = rasterQuery.CellCount;
		PixelRange pixelRange = rasterQuery.GetPixelRange(ValidExtent).ClipTo(rasterQuery);
		Memory<byte>[] byteSpanArray = new Memory<byte>[3];
		using IMemoryOwner<byte> memoryOwner = SharedMemoryPool<byte>.Rent(_raster.ProfileCount * cellCount);
		byteSpanArray[0] = memoryOwner.Memory.Slice(0, cellCount);
		byteSpanArray[1] = memoryOwner.Memory.Slice(cellCount, cellCount);
		byteSpanArray[2] = memoryOwner.Memory.Slice(cellCount * 2, cellCount);
		_raster.Resample(args, 0, 3, byteSpanArray);
		Memory<int> mem;
		using (SharedMemoryPool<int>.Rent(cellCount, 0, out mem))
		{
			Span<int> memSpan = mem.Span;
			Span<byte> byteSpan = byteSpanArray[0].Span;
			Span<byte> byteSpan2 = byteSpanArray[1].Span;
			Span<byte> byteSpan3 = byteSpanArray[2].Span;
			if (Recolorer == null)
			{
				if (!pixelRange.IsNull())
				{
					int opacityTerm = Opacity << 24;
					int cols = rasterQuery.Cols;
					for (int i = pixelRange.MinRow; i <= pixelRange.MaxRow; i++)
					{
						int colsTerm = i * cols;
						for (int j = pixelRange.MinCol; j <= pixelRange.MaxCol; j++)
						{
							int index = colsTerm + j;
							memSpan[index] = opacityTerm | (byteSpan[index] << 16) | (byteSpan2[index] << 8) | byteSpan3[index];
						}
					}
				}
				request.Splat(memSpan);
			}
			else
			{
				for (int k = 0; k < cellCount; k++)
				{
					int ordinal = byteSpan[k];
					int ordinal2 = byteSpan2[k];
					int ordinal3 = byteSpan3[k];
					memSpan[k] = (ordinal << 16) | (ordinal2 << 8) | ordinal3;
				}
				Recolorer.RecolorARGB(mem, mem);
				RasterOperations.PreserveRegion(rasterQuery, mem, ValidExtent, 0);
				request.SplatPremultiplied(memSpan);
			}
		}
	}

	protected override long GetInternalRenderState()
	{
		return base.GetInternalRenderState() + _version;
	}
}
