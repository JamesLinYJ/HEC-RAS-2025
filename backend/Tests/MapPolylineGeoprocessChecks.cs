using Ras.Backend;

internal static class MapPolylineGeoprocessChecks
{
    internal static void Run()
    {
        double[][] source = [[0, 0], [1, 0.1], [2, 0], [3, 4]];
        MapPolylineGeoprocessResult filtered = MapPolylineGeoprocessService.Transform(
            new("filter", source, Epsilon: 0.2));
        Check(CoordinatesEqual(filtered.Coordinates, [[0, 0], [2, 0], [3, 4]]),
            "Filter uses the retained Douglas-Peucker XY reduction and keeps its source tolerance semantics");

        double[][] smoothingSource = [[0, 0], [1, 0], [2, 2], [3, 0], [4, 0]];
        MapPolylineGeoprocessResult smoothed = MapPolylineGeoprocessService.Transform(
            new("smooth", smoothingSource, WindowSize: 3, Iterations: 1));
        Check(smoothed.Coordinates.Length == 5 &&
              smoothed.Coordinates[0].SequenceEqual([0d, 0d]) &&
              smoothed.Coordinates[1].SequenceEqual([1d, 2d / 3d]) &&
              smoothed.Coordinates[2].SequenceEqual([2d, 2d / 3d]) &&
              smoothed.Coordinates[3].SequenceEqual([3d, 2d / 3d]) &&
              smoothed.Coordinates[4].SequenceEqual([4d, 0d]),
            "Smooth uses the retained moving average, fixed endpoints and source window semantics");

        MapPolylineGeoprocessResult clamped = MapPolylineGeoprocessService.Transform(
            new("smooth", smoothingSource, WindowSize: 1, Iterations: 0));
        Check(CoordinatesEqual(clamped.Coordinates, smoothed.Coordinates),
            "The source algorithm clamps a short window and zero passes to its documented minimums");

        Expect<ArgumentException>(() => MapPolylineGeoprocessService.Transform(
            new("filter", [[0, 0], [1, 1, 2]], Epsilon: 1)));
        Expect<ArgumentException>(() => MapPolylineGeoprocessService.Transform(
            new("filter", [[0, 0], [double.NaN, 1]], Epsilon: 1)));
        Expect<ArgumentException>(() => MapPolylineGeoprocessService.Transform(
            new("filter", [[1, 1], [1, 1]], Epsilon: 1)));
        Expect<ArgumentException>(() => MapPolylineGeoprocessService.Transform(
            new("filter", source, Epsilon: 0)));
        Expect<ArgumentException>(() => MapPolylineGeoprocessService.Transform(
            new("smooth", smoothingSource, WindowSize: 102, Iterations: 1)));
        double[][] excessive = Enumerable.Range(0, 10_001).Select(index => new[] { (double)index, 0d }).ToArray();
        Expect<ArgumentException>(() => MapPolylineGeoprocessService.Transform(new("filter", excessive, Epsilon: 1)));
        Expect<ArgumentException>(() => MapPolylineGeoprocessService.Transform(
            new("buffer", source)));

        Console.WriteLine("Polyline filter and smooth route the retained XY algorithms and reject unsupported coordinate payloads.");
    }

    private static void Check(bool condition, string description)
    {
        if (!condition) throw new InvalidOperationException(description);
    }

    private static bool CoordinatesEqual(double[][] left, double[][] right) =>
        left.Length == right.Length && left.Zip(right).All(pair => pair.First.SequenceEqual(pair.Second));

    private static void Expect<T>(Action action) where T : Exception
    {
        try { action(); }
        catch (T) { return; }
        throw new InvalidOperationException("Expected " + typeof(T).Name + ".");
    }
}
