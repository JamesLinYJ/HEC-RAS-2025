using Geospatial.IO;
using Geospatial.Vectors;
using H5Assist;
using Utility.Files;

internal static class VectorDimensionChecks
{
    internal static void Run()
    {
        using var folder = new TemporaryDirectory(); string path = Path.Combine(folder.FullName, "dimensions.h5");
        var polygons = new List<Polygon>(); var lines = new List<Polyline>();
        for (int mode = 0; mode < 4; mode++)
        {
            var polygon = new Polygon(new Point[] { new(0, 0), new(1, 0), new(1, 1), new(0, 1) });
            var line = new Polyline(new Point[] { new(0, 0), new(1, 0), new(1, 1) });
            if ((mode & 1) != 0) { polygon.TrackZ(new double[] { 1, 2, double.NaN, 4 }); line.TrackZ(new double[] { 1, double.NaN, 3 }); }
            if ((mode & 2) != 0) { polygon.TrackM(new double[] { 10, 20, double.NaN, 40 }); line.TrackM(new double[] { 10, double.NaN, 30 }); }
            polygons.Add(polygon); lines.Add(line);
        }
        using (var writer = new H5Writer(path))
        {
            HDF5VectorReader.Write(writer, polygons, "/Polygons"); HDF5VectorReader.Write(writer, lines, "/Lines");
            writer.WriteDataset("/LegacyFloatXYZ", new float[,] { { 0, 0, 1 }, { 1, 0, 2 }, { 1, 1, float.NaN } });
            writer.WriteAttribute("/LegacyFloatXYZ", "Start", new int[] { 0 }); writer.WriteAttribute("/LegacyFloatXYZ", "Count", new int[] { 3 });
            writer.WriteDataset("/LegacyDoubleXYZM", new double[,] { { 0, 0, 1, 10 }, { 1, 0, 2, 20 }, { 1, 1, double.NaN, 30 } });
            writer.WriteAttribute("/LegacyDoubleXYZM", "Start", new int[] { 0 }); writer.WriteAttribute("/LegacyDoubleXYZM", "Count", new int[] { 3 });
        }
        using (var reader = new H5Reader(path))
        {
            var readPolygons = HDF5VectorReader.TryReadPolygons(reader, "/Polygons"); var readLines = HDF5VectorReader.TryReadPolylines(reader, "/Lines");
            Check(readPolygons?.Length == 4 && readLines?.Length == 4, "Mixed-dimensional feature counts");
            for (int index = 0; index < 4; index++) { Equal(polygons[index], readPolygons![index]); Equal(lines[index], readLines![index]); }
            var xyz = HDF5VectorReader.TryReadPolylines(reader, "/LegacyFloatXYZ").Single();
            Check(xyz.HasZ && !xyz.HasM && xyz.Z[1] == 2 && double.IsNaN(xyz.Z[2]), "Legacy float XYZ is readable without new dimension attributes");
            var xyzm = HDF5VectorReader.TryReadPolygons(reader, "/LegacyDoubleXYZM").Single();
            Check(xyzm.HasZ && xyzm.HasM && xyzm.M[2] == 30 && double.IsNaN(xyzm.Z[2]), "Legacy double XYZM remains readable without new flags");
        }
        Console.WriteLine("Source HDF XY/XYZ/XYM/XYZM polygon/polyline collections, per-feature dimension flags, NaN ordinates and legacy float/double vectors passed.");
    }
    private static void Equal(PointCollection expected, PointCollection actual)
    {
        Check(expected.HasZ == actual.HasZ && expected.HasM == actual.HasM && expected.Points.SequenceEqual(actual.Points), "Per-feature XY/Z/M dimensions are retained");
        if (expected.HasZ) Check(expected.Z.SequenceEqual(actual.Z), "Exact source Z values including NaN");
        if (expected.HasM) Check(expected.M.SequenceEqual(actual.M), "Exact source M values including NaN");
    }
    private static void Check(bool value, string message) { if (!value) throw new InvalidOperationException(message); }
}
