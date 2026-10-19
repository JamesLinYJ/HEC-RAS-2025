using System.Security.Cryptography;
using System.Globalization;
using System.Text;
using Ras.Backend;

internal static class VectorSymbologyChecks
{
    internal static void Run()
    {
        string directory = Path.Combine(Path.GetTempPath(), "HECRASVectorSymbology-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        try
        {
            using var culture = new CultureScope(CultureInfo.InvariantCulture);
            string path = Path.Combine(directory, "mixed.geojson");
            File.WriteAllText(path, MixedGeoJson, new UTF8Encoding(encoderShouldEmitUTF8Identifier: false));
            string revision = Hash(path);
            var inspection = VectorSymbologyService.Inspect(new(path, revision));

            Check(inspection.SourceFeatureCount == 5 && inspection.Revision == revision,
                "Inspection reports the complete source collection and exact byte revision");
            var point = inspection.Buckets.Single(bucket => bucket.GeometryType == "point");
            var line = inspection.Buckets.Single(bucket => bucket.GeometryType == "line");
            var polygon = inspection.Buckets.Single(bucket => bucket.GeometryType == "polygon");
            Check(point.SourceFeatureIndices.SequenceEqual([0, 3]) && line.SourceFeatureIndices.SequenceEqual([1]) &&
                  polygon.SourceFeatureIndices.SequenceEqual([4]),
                "Typed source-table rows map to original indices across mixed geometry buckets and an unlocated feature");
            Check(new[] { point, line, polygon }.All(bucket => bucket.OrdinalBindingProven &&
                  bucket.RenderFeatureCount == bucket.TableRowCount && bucket.RenderFeatureCount == bucket.SourceFeatureIndices.Length),
                "Every reported source bucket proves feature-to-table ordinal binding");
            Check(point.Columns.Select(column => column.Name).SequenceEqual(["Name", "Score", "Ratio", "Active"]) &&
                  point.Columns.Single(column => column.Name == "Score").Type == "int64" &&
                  point.Columns.Single(column => column.Name == "Ratio").Type == "string" &&
                  point.Columns.Single(column => column.Name == "Active").Type == "unsupported" &&
                  point.Columns.Single(column => column.Name == "Score").ID == "column/1" &&
                  point.Columns.Single(column => column.Name == "Ratio").ID == "column/2" &&
                  line.Columns.Single(column => column.Name == "Ratio").Type == "float64",
                "Inspection preserves source column order, mixed numeric promotion to text, typed columns and stable ordinal identities");
            Check(point.SupportedDefinitionIDs.SequenceEqual(["Point_Map_Layer_Symbology"]) &&
                  line.SupportedDefinitionIDs.Contains("Polyline_Line_Symbology") &&
                  line.SupportedDefinitionIDs.Contains("Polyline_Vertex_Symbology") &&
                  polygon.SupportedDefinitionIDs.Contains("Polygon_Map_Layer_Shape_Symbology") &&
                  polygon.SupportedDefinitionIDs.Contains("Polygon_Map_Layer_Vertex_Symbology"),
                "Style definition capabilities come from the retained point, line, and polygon contexts");

            var evaluated = VectorSymbologyService.Evaluate(new(path, revision, "point", [3, 0],
            [
                new("Point_Map_Layer_Symbology", "PointSize",
                [
                    new("Score", ">=", "5", "9"),
                    new("Name", "equals", "beta", "12")
                ]),
                new("Point_Map_Layer_Symbology", "FillColor",
                [new("Name", "equals", "beta", "#00ff00")])
            ]));
            var matchedSize = evaluated.Overrides.Single(item => item.SourceFeatureIndex == 3 && item.Property == "PointSize");
            var unmatchedSize = evaluated.Overrides.Single(item => item.SourceFeatureIndex == 0 && item.Property == "PointSize");
            var matchedColor = evaluated.Overrides.Single(item => item.SourceFeatureIndex == 3 && item.Property == "FillColor");
            Check(matchedSize.HasMatch && matchedSize.IntegerValue == 9 && matchedSize.NumberValue is null &&
                  !unmatchedSize.HasMatch && unmatchedSize.IntegerValue is null,
                "Typed source values use first matching rule and explicitly preserve no-match fallback");
            Check(matchedColor.HasMatch && matchedColor.ColorValue == "#FF00FF00" && matchedColor.IntegerValue is null,
                "Source ColorTranslator values return canonical ARGB without coercing property kinds");

            var lineWidth = VectorSymbologyService.Evaluate(new(path, revision, "line", [1],
            [new("Polyline_Line_Symbology", "PenWidth", [new("Ratio", ">", "2", "2.75")])]));
            var width = lineWidth.Overrides.Single();
            Check(width.HasMatch && width.NumberValue == 2.75 && width.ColorValue is null && width.IntegerValue is null,
                "Numeric conditional output remains a finite source-compatible double");

            var wrongFamily = new VectorSymbologyEvaluateRequest(path, revision, "line", [3], []);
            var unsupportedColumn = new VectorSymbologyEvaluateRequest(path, revision, "point", [0],
                [new("Point_Map_Layer_Symbology", "PointSize", [new("Active", "==", "true", "4")])]);
            var missingColumn = new VectorSymbologyEvaluateRequest(path, revision, "point", [0],
                [new("Point_Map_Layer_Symbology", "PointSize", [new("Missing", "==", "1", "4")])]);
            var invalidResult = new VectorSymbologyEvaluateRequest(path, revision, "point", [0],
                [new("Point_Map_Layer_Symbology", "PointSize", [new("Score", "==", "1", "2147483648")])]);
            var unsupportedDefinition = new VectorSymbologyEvaluateRequest(path, revision, "point", [0],
                [new("Polyline_Line_Symbology", "PenWidth", [])]);
            Expect<ArgumentException>(() => VectorSymbologyService.Evaluate(wrongFamily));
            Expect<NotSupportedException>(() => VectorSymbologyService.Evaluate(unsupportedColumn));
            Expect<ArgumentException>(() => VectorSymbologyService.Evaluate(missingColumn));
            Expect<ArgumentException>(() => VectorSymbologyService.Evaluate(invalidResult));
            Expect<NotSupportedException>(() => VectorSymbologyService.Evaluate(unsupportedDefinition));
            Check(Hash(path) == revision, "Inspection and evaluation leave the source GeoJSON bytes unchanged");

            string geometryCollectionPath = Path.Combine(directory, "unsupported.geojson");
            File.WriteAllText(geometryCollectionPath, GeometryCollectionGeoJson, new UTF8Encoding(false));
            Expect<NotSupportedException>(() => VectorSymbologyService.Inspect(new(geometryCollectionPath, Hash(geometryCollectionPath))));

            File.WriteAllText(path, MixedGeoJson.Replace("\"Name\":\"beta\"", "\"Name\":\"changed\"", StringComparison.Ordinal), new UTF8Encoding(false));
            Expect<SourceFileChangedException>(() => VectorSymbologyService.Evaluate(new(path, revision, "point", [0], [])));
            Console.WriteLine("Vector symbology source checks cover typed reader buckets, original-index binding, source predicates, capability failures and unchanged source bytes.");
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    private static string Hash(string path) => Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(path)));

    private static void Check(bool value, string message)
    {
        if (!value) throw new InvalidOperationException(message);
    }

    private static void Expect<TException>(Action action) where TException : Exception
    {
        try { action(); }
        catch (TException) { return; }
        throw new InvalidOperationException("Expected " + typeof(TException).Name + ".");
    }

    private sealed class CultureScope : IDisposable
    {
        private readonly CultureInfo previous = CultureInfo.CurrentCulture;
        public CultureScope(CultureInfo culture) => CultureInfo.CurrentCulture = culture;
        public void Dispose() => CultureInfo.CurrentCulture = previous;
    }

    private const string MixedGeoJson = """
    {
      "type":"FeatureCollection",
      "features":[
        {"type":"Feature","geometry":{"type":"Point","coordinates":[1,2]},"properties":{"Name":"alpha","Score":2,"Ratio":1.5,"Active":true}},
        {"type":"Feature","geometry":{"type":"LineString","coordinates":[[0,0],[1,1]]},"properties":{"Name":"line","Score":5,"Ratio":2.25,"Active":false}},
        {"type":"Feature","geometry":null,"properties":{"Name":"unlocated","Score":6}},
        {"type":"Feature","geometry":{"type":"MultiPoint","coordinates":[[3,4],[5,6]]},"properties":{"Name":"beta","Score":7,"Ratio":3,"Active":true}},
        {"type":"Feature","geometry":{"type":"Polygon","coordinates":[[[0,0],[2,0],[2,2],[0,2],[0,0]]]},"properties":{"Name":"polygon","Score":9,"Ratio":4.5,"Active":false}}
      ]
    }
    """;

    private const string GeometryCollectionGeoJson = """
    {"type":"FeatureCollection","features":[{"type":"Feature","geometry":{"type":"GeometryCollection","geometries":[]},"properties":{"Name":"unsupported"}}]}
    """;
}
