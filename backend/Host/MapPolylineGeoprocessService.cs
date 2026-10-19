using Geospatial.Vectors;

namespace Ras.Backend;

public sealed record MapPolylineGeoprocessRequest(string Operation, double[][] Coordinates,
    double? Epsilon = null, int? WindowSize = null, int? Iterations = null);

public sealed record MapPolylineGeoprocessResult(double[][] Coordinates);

/// <summary>
/// Runs the retained XY-only polyline transforms without touching a source
/// file. The native editor applies the returned coordinates to its lossless
/// GeoJSON AST after checking its captured draft identity.
/// </summary>
public static class MapPolylineGeoprocessService
{
    private const int MaximumPointCount = 10_000;
    private const int MaximumWindowSize = 101;
    private const int MaximumIterations = 20;

    public static MapPolylineGeoprocessResult Transform(MapPolylineGeoprocessRequest request)
    {
        ArgumentNullException.ThrowIfNull(request);
        if (request.Operation is not ("filter" or "smooth"))
            throw new ArgumentException("Polyline operation must be Filter or Smooth.");

        double[][] coordinates = request.Coordinates ?? throw new ArgumentException("Polyline coordinates are required.");
        if (coordinates.Length < 2 || coordinates.Length > MaximumPointCount ||
            coordinates.Any(point => point is null || point.Length != 2 ||
                !double.IsFinite(point[0]) || !double.IsFinite(point[1])))
            throw new ArgumentException("Polyline operations require finite two-dimensional coordinates and a supported point count.");
        if (!IsNonzero(coordinates))
            throw new ArgumentException("Polyline operations require a nonzero line with at least two vertices.");

        var source = new Polyline(coordinates.Length);
        foreach (double[] coordinate in coordinates)
            source.Add(new Point(coordinate[0], coordinate[1]));

        Polyline transformed;
        switch (request.Operation)
        {
            case "filter":
            {
                double epsilon = request.Epsilon ?? 1.0;
                if (!double.IsFinite(epsilon) || epsilon <= 0)
                    throw new ArgumentException("Filter tolerance must be finite and positive.");
                transformed = new Polyline(source.DouglasPeuckerReduction(epsilon));
                break;
            }
            case "smooth":
            {
                int windowSize = request.WindowSize ?? 3;
                int iterations = request.Iterations ?? 2;
                if (windowSize < 1 || windowSize > MaximumWindowSize || iterations < 0 || iterations > MaximumIterations)
                    throw new ArgumentException("Smooth window and passes are outside the supported range.");
                // The retained source algorithm itself clamps WindowSize to an
                // odd value >= 3 and passes to >= 1.
                transformed = source.CloneWithMovingAverageSmoothing(windowSize, iterations);
                break;
            }
            default:
                throw new ArgumentException("Polyline operation must be Filter or Smooth.");
        }

        double[][] result = transformed.Points.Select(point => new[] { point.X, point.Y }).ToArray();
        if (result.Length < 2 || result.Length > coordinates.Length ||
            result.Any(point => !double.IsFinite(point[0]) || !double.IsFinite(point[1])) || !IsNonzero(result))
            throw new InvalidDataException("The geometry operation produced an invalid line.");
        return new MapPolylineGeoprocessResult(result);
    }

    private static bool IsNonzero(IReadOnlyList<double[]> coordinates)
    {
        for (int index = 1; index < coordinates.Count; index++)
            if (coordinates[index][0] != coordinates[index - 1][0] || coordinates[index][1] != coordinates[index - 1][1])
                return true;
        return false;
    }
}
