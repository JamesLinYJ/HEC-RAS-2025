using System.Globalization;
using Geospatial.Features;
using Geospatial.GDALAssist;
using Geospatial.IO;
using Geospatial.Vectors;
using Ras.Backend;
using Utility.Memory;

internal static class MapShapefilePolylineDraftChecks
{
    internal static void Run()
    {
        using var temporary = new TemporaryDirectory();
        string root = temporary.FullName;
        string sourcePath = Path.Combine(root, "edited-lines.shp");
        var first = new Polyline(new Point[] { new(116.0, 39.0), new(116.1, 39.1), new(116.2, 39.2) });
        first.TrackZ([10, 20, 30]);
        first.TrackM([100, 200, 300]);
        var second = new Polyline(new Point[] { new(116.3, 39.3), new(116.4, 39.4) });
        second.TrackZ([40, 50]);
        second.TrackM([400, 500]);
        Table attributes = CreateAttributes();
        Check(ShapefileIO.Write(sourcePath, new List<Polyline> { first, second }, attributes).Result,
            "The retained Shapefile writer creates two actual XYZM source records.");
        string projectionPath = ShapefileIO.PRJFilename(sourcePath);
        new EPSGProjection(4326).ExportEsri(projectionPath);
        byte[] originalProjection = File.ReadAllBytes(projectionPath);
        var sourceProjection = new ESRIProjection(projectionPath);
        var mapProjection = new EPSGProjection(32650);
        MapSourceFamilyCapture initialFamily = MapTreeService.CaptureShapefileFamily(sourcePath);

        double[][] firstMapLine = Project(first, sourceProjection, mapProjection);
        firstMapLine[1][0] += 4.0;
        firstMapLine[1][1] -= 2.0;
        double[][] secondMapLine = Project(second, sourceProjection, mapProjection);
        double[] editedSourceVertex = ProjectPoint(mapProjection, sourceProjection, firstMapLine[1]);
        MapShapefilePolylineDraftSaveResponse oneToOne = MapShapefilePolylineDraftService.Save(
            Request(sourcePath, initialFamily, sourceProjection, mapProjection,
            [
                Record(0, firstMapLine, [10, 20, 30], [100, 200, 300]),
                Record(1, secondMapLine, [40, 50], [400, 500])
            ]));

        Check(oneToOne.Family.SourcePath == Path.GetFullPath(sourcePath) &&
              oneToOne.Family.Files.Single(file => file.Role == "source").Revision !=
                  initialFamily.Files.Single(file => file.Role == "source").Revision,
            "One-to-one in-place save updates the exact source revision without changing its physical identity.");
        Check(File.ReadAllBytes(projectionPath).SequenceEqual(originalProjection),
            "Saving edited line coordinates preserves the exact source projection sidecar bytes.");
        Check(ShapefileIO.TryRead(sourcePath, out PolylineCollectionFeatureCollection afterOneToOne).Result,
            "The saved one-to-one Shapefile opens through the retained polyline reader.");
        Polyline[] oneToOneLines = afterOneToOne.ToExplodedPolylineCollection().ToArray();
        Check(oneToOneLines.Length == 2 && oneToOneLines.All(line => line.HasZ && line.HasM) &&
              Near(oneToOneLines[0][1].X, editedSourceVertex[0], 1e-8) &&
              Near(oneToOneLines[0][1].Y, editedSourceVertex[1], 1e-8) &&
              oneToOneLines[0].Z.SequenceEqual([10d, 20d, 30d]) &&
              oneToOneLines[1].M.SequenceEqual([400d, 500d]),
            "One-to-one save writes the edited reprojected XY coordinates and retains every Z/M ordinate.");
        Check((string?)afterOneToOne.AttributeTable.Rows[0][0] == "Reach A" &&
              (string?)afterOneToOne.AttributeTable.Rows[1][0] == "Reach B" &&
              Convert.ToInt32(afterOneToOne.AttributeTable.Rows[1][1], CultureInfo.InvariantCulture) == 2 &&
              !Convert.ToBoolean(afterOneToOne.AttributeTable.Rows[1][2], CultureInfo.InvariantCulture),
            "One-to-one save preserves DBF row order and typed values for each original source feature.");

        MapSourceFamilyCapture beforeCardinalityChange = oneToOne.Family;
        var generatedFirst = new Polyline(new Point[] { new(116.0, 39.05), new(116.05, 39.1) });
        generatedFirst.TrackZ([11, 12]);
        generatedFirst.TrackM([101, 102]);
        var generatedSecond = new Polyline(new Point[] { new(116.05, 39.1), new(116.1, 39.15) });
        generatedSecond.TrackZ([13, 14]);
        generatedSecond.TrackM([103, 104]);
        MapShapefilePolylineDraftSaveResponse cardinalityChange = MapShapefilePolylineDraftService.Save(
            Request(sourcePath, beforeCardinalityChange, sourceProjection, mapProjection,
            [
                Record(0, Project(oneToOneLines[0], sourceProjection, mapProjection), [10, 20, 30], [100, 200, 300]),
                Record(null, Project(generatedFirst, sourceProjection, mapProjection), [11, 12], [101, 102]),
                Record(null, Project(generatedSecond, sourceProjection, mapProjection), [13, 14], [103, 104])
            ]));

        Check(ShapefileIO.TryRead(sourcePath, out PolylineCollectionFeatureCollection afterCardinalityChange).Result &&
              afterCardinalityChange.Count == 3 && afterCardinalityChange.AttributeTable.Rows.Count == 3,
            "A cardinality-changing edit writes actual line and DBF records for all retained and generated outputs.");
        string?[] labels = afterCardinalityChange.AttributeTable.Rows.Select(row => row[0] as string).ToArray();
        Check(labels[0] == "Reach A" && labels[1] != "Reach A" && labels[1] != "Reach B" &&
              labels[2] != "Reach A" && labels[2] != "Reach B",
            "Generated in-place lines receive new default DBF rows instead of inheriting removed feature attributes.");
        Table savedAttributes = afterCardinalityChange.AttributeTable;
        Check(savedAttributes.Columns.Select(column => column.Type)
                  .SequenceEqual([typeof(string), typeof(int), typeof(bool)]) &&
              savedAttributes.Rows[1][0] is string firstGeneratedName && firstGeneratedName.Length == 0 &&
              savedAttributes.Rows[2][0] is string secondGeneratedName && secondGeneratedName.Length == 0 &&
              savedAttributes.Rows[1][1] is null && savedAttributes.Rows[1][2] is null &&
              savedAttributes.Rows[2][1] is null && savedAttributes.Rows[2][2] is null,
            "Generated DBF rows preserve source field types and round-trip character blanks with typed numeric/logical nulls.");
        Polyline[] changedLines = afterCardinalityChange.ToExplodedPolylineCollection().ToArray();
        Check(changedLines.Length == 3 && changedLines.All(line => line.HasZ && line.HasM) &&
              changedLines[1].Z.SequenceEqual([11d, 12d]) && changedLines[2].M.SequenceEqual([103d, 104d]),
            "Cardinality-changing save retains the generated XYZM geometry and output order.");
        Check(File.ReadAllBytes(projectionPath).SequenceEqual(originalProjection),
            "Repeated edit-stack saves continue to retain the original projection bytes.");

        MapSourceFamilyCapture staleCapture = MapTreeService.CaptureShapefileFamily(sourcePath);
        File.WriteAllBytes(projectionPath, File.ReadAllBytes(projectionPath).Append((byte)0x20).ToArray());
        string[] familyPaths = [sourcePath, ShapefileIO.SHXFilename(sourcePath),
            ShapefileIO.DBFFilename(sourcePath), projectionPath];
        byte[][] changedFamilyBytes = familyPaths.Select(File.ReadAllBytes).ToArray();
        Expect<SourceFileChangedException>(() => MapShapefilePolylineDraftService.Save(
            Request(sourcePath, staleCapture, sourceProjection, mapProjection,
                [Record(0, Project(changedLines[0], sourceProjection, mapProjection), [10, 20, 30], [100, 200, 300])])),
            "A changed sidecar after family capture is rejected before the source can be overwritten.");
        Check(familyPaths.Select(File.ReadAllBytes).Zip(changedFamilyBytes)
                .All(pair => pair.First.SequenceEqual(pair.Second)),
            "A stale family rejection leaves every current Shapefile component byte-for-byte unchanged.");

        Console.WriteLine("Shapefile line editing preserves exact source family identity, CRS sidecar, typed attributes, and XYZM geometry across one-to-one and cardinality-changing saves; stale families are rejected without writes.");
    }

    private static Table CreateAttributes()
    {
        var table = new Table();
        table.AddColumn("Name", typeof(string));
        table.AddColumn("Order", typeof(int));
        table.AddColumn("Active", typeof(bool));
        table.AddNewRow(["Reach A", 1, true]);
        table.AddNewRow(["Reach B", 2, false]);
        return table;
    }

    private static MapShapefilePolylineDraftSaveRequest Request(string path, MapSourceFamilyCapture family,
        Projection sourceProjection, Projection targetProjection, MapShapefilePolylineDraftRecord[] records) =>
        new(path, "projected", sourceProjection.GetWKT(), targetProjection.GetWKT(), family, records);

    private static MapShapefilePolylineDraftRecord Record(int? sourceFeatureIndex, double[][] xy,
        double[] z, double[] m) => new(sourceFeatureIndex, xy,
        z.Select(value => value.ToString("R", CultureInfo.InvariantCulture)).ToArray(),
        m.Select(value => value.ToString("R", CultureInfo.InvariantCulture)).ToArray());

    private static double[][] Project(Polyline line, Projection source, Projection target) =>
        Enumerable.Range(0, line.Count).Select(index => ProjectPoint(source, target, [line[index].X, line[index].Y])).ToArray();

    private static double[] ProjectPoint(Projection source, Projection target, double[] xy)
    {
        Point transformed = Projector.TransformPoint(source, target, new Point(xy[0], xy[1]));
        return [transformed.X, transformed.Y];
    }

    private static bool Near(double actual, double expected, double tolerance) =>
        Math.Abs(actual - expected) <= tolerance;

    private static void Check(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }

    private static void Expect<T>(Action action, string message) where T : Exception
    {
        try { action(); }
        catch (T) { return; }
        throw new InvalidOperationException("Expected " + typeof(T).Name + ": " + message);
    }
}
