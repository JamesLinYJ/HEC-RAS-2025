using Geospatial.Vectors.Rasterizers;
using System.Runtime.Intrinsics.X86;
using Ras.Mapping;

internal static class PortableResultMapperChecks
{
	internal static void Run()
	{
		float[] stencilWeights =
		[
			0.1f, -0.3f, 0.5f, 1.2f, 0.7f, -0.2f, 0.8f, 0.4f,
			-0.5f, 0.25f, 1.1f, -0.75f, 0.6f, 0.9f, -0.4f, 1.3f,
			2f, -1f, 0.5f, 0.25f, -2f, 0.75f, 0.1f, -0.25f
		];
		float[] waterSurfaceValues = [1.25f, -2f, 0.5f, 3.75f];
		float[] faceValues = [2f, -1.5f, 4.25f, 0.75f];
		float[] combinedValues = [.. waterSurfaceValues, .. faceValues];
		var cell = new SlopingCellMap(0, new PointRange[] { new(0, 2, 0) }, stencilWeights);
		float[] expected = new float[3];
		cell.PaintCell_8Stencil(waterSurfaceValues, faceValues, expected);

		float[] sseOutput = new float[3];
		float[] avxOutput = new float[3];
		unsafe
		{
			fixed (float* waterSurfacePointer = waterSurfaceValues)
			fixed (float* facePointer = faceValues)
			fixed (float* combinedPointer = combinedValues)
			{
				cell.PaintCell_8Stencil_4FaceSSE(waterSurfacePointer, facePointer, sseOutput);
				cell.PaintCell_8Stencil_4FaceAVX(combinedPointer, avxOutput);
			}
		}

		AssertSame(expected, sseOutput, "SSE stencil matches generic stencil");
		AssertSame(expected, avxOutput, "AVX stencil or unsupported-CPU fallback matches generic stencil");
		CheckDepthSubtraction();
		Console.WriteLine($"Portable sloping-cell stencil parity passed (SSE4.1={Sse41.IsSupported}, AVX={Avx.IsSupported}).");
	}

	private static void CheckDepthSubtraction()
	{
		// Cross both eight-value vector boundaries and the scalar tail, including
		// source no-data in either input and valid dry/negative depth values.
		float[] surfaces = [102f, -9999f, 103f, 0f, -2f, 20f, 15f, 12f,
			105f, 106f, 107f, 108f, 109f, 110f, 111f, -9999f, 113f, 114f, 115f];
		float[] terrain = [100f, 100f, -9999f, 1f, -5f, 20f, 16f, 10f,
			100f, 100f, 100f, 100f, 100f, 100f, 100f, 100f, -9999f, 100f, 100f];
		float[] expected = [2f, -9999f, -9999f, -1f, 3f, 0f, -1f, 2f,
			5f, 6f, 7f, 8f, 9f, 10f, 11f, -9999f, -9999f, 14f, 15f];
		float[] output = new float[surfaces.Length];
		DepthMapper.SubtractTerrainAVX(surfaces, terrain, output);
		AssertSame(expected, output, "Depth subtraction preserves no-data and source values across vector boundaries");
		DepthMapper.SubtractTerrainAVX(Memory<float>.Empty, Memory<float>.Empty, Memory<float>.Empty);
		try
		{
			DepthMapper.SubtractTerrainAVX(surfaces, terrain.AsMemory(1), output);
			throw new InvalidOperationException("Depth subtraction accepted mismatched terrain dimensions.");
		}
		catch (ArgumentException) { }
	}

	private static void AssertSame(float[] expected, float[] actual, string message)
	{
		if (expected.Length != actual.Length)
			throw new InvalidOperationException(message + ": output length differs.");
		for (int index = 0; index < expected.Length; index++)
		{
			float tolerance = 1e-5f * Math.Max(1f, MathF.Abs(expected[index]));
			if (!float.IsFinite(actual[index]) || MathF.Abs(expected[index] - actual[index]) > tolerance)
				throw new InvalidOperationException($"{message}: pixel {index}, expected {expected[index]}, actual {actual[index]}.");
		}
	}
}
