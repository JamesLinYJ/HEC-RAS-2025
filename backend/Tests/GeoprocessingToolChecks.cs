using System.Security.Cryptography;
using Geospatial.GDALAssist;
using Geospatial.IO;
using Geospatial.Vectors;
using Ras.Backend;

internal static class GeoprocessingToolChecks
{
    internal static void Run()
    {
        string workspace = Path.Combine(Path.GetTempPath(), "hecras-geoprocessing-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(workspace);
        try
        {
            string sourcePath = Path.Combine(workspace, "source.geojson");
            byte[] sourceBytes = """
                {"type":"FeatureCollection","features":[
                  {"type":"Feature","id":"stable-a","properties":{},"geometry":{"type":"LineString","coordinates":[[0,0],[1,0.01],[2,0]]}},
                  {"type":"Feature","id":"reverse-feature","properties":{},"geometry":{"type":"LineString","coordinates":[[0,0],[1,0.01],[2,0]]}},
                  {"type":"Feature","id":"long-feature","properties":{},"geometry":{"type":"LineString","coordinates":[[0,0],[2,0]]}},
                  {"type":"Feature","id":"short-feature","properties":{},"geometry":{"type":"LineString","coordinates":[[0,1],[1,1]]}},
                  {"type":"Feature","id":"kept-feature","properties":{},"geometry":{"type":"LineString","coordinates":[[0,2],[2,2]]}},
                  {"type":"Feature","id":"merge-a","properties":{},"geometry":{"type":"LineString","coordinates":[[0,3],[1,3]]}},
                  {"type":"Feature","id":"merge-b","properties":{},"geometry":{"type":"LineString","coordinates":[[1,3],[2,3]]}},
                  {"type":"Feature","id":"offset-feature","properties":{},"geometry":{"type":"LineString","coordinates":[[0,4],[2,4]]}}
                ]}
                """u8.ToArray();
            File.WriteAllBytes(sourcePath, sourceBytes);
            string revision = Convert.ToHexString(SHA256.HashData(sourceBytes));
            GeoprocessingPolylineInput[] capturedLines = [
                new("feature:stable-a", "path:stable-a:0", 0, 0, [[0, 0], [1, 0.01], [2, 0]])
            ];

            GeoprocessingPolylineResponse filtered = GeoprocessingToolService.Execute(new(
                sourcePath, revision, workspace, "Local", "English", "Filter", "All", capturedLines,
                CultureName: "en-US", ToleranceText: "0.05", OutputHandler: "Clipboard"));
            Check(filtered.CanExecute && filtered.OutputPath is null
                  && filtered.ClipboardText == new Polyline().ToString(),
                "Clipboard returns the retained source Polyline text representation");
            Check(filtered.Outputs.Length == 1 && filtered.Outputs[0].Coordinates.Length == 2
                  && filtered.Outputs[0].FeatureIdentity == "feature:stable-a"
                  && filtered.Outputs[0].PathIdentity == "path:stable-a:0",
                "Filter calls the retained Polyline.Filter and preserves exact map feature/path identity");
            Check(filtered.Outputs[0].Coordinates.Length == 2,
                "The typed clipboard line contains the filtered source coordinates");
            Check(File.ReadAllBytes(sourcePath).SequenceEqual(sourceBytes),
                "The source GeoJSON bytes are unchanged after processing");

            GeoprocessingPolylineResponse invalid = GeoprocessingToolService.Execute(new(
                sourcePath, revision, workspace, "Local", "English", "Filter", "All", capturedLines,
                CultureName: "en-US", ToleranceText: "0", OutputHandler: "Clipboard"));
            Check(!invalid.CanExecute && invalid.ClipboardText is null
                  && invalid.ValidationIssues.Any(issue => issue.Field == "Tolerance"
                      && issue.Severity == "Error"
                      && issue.Message == "The current input can not be less than or equal to zero."),
                "Filter returns the retained GreaterThanZero validation message and severity");

            GeoprocessingPolylineResponse localized = GeoprocessingToolService.Execute(new(
                sourcePath, revision, workspace, "Local", "English", "Filter", "All", capturedLines,
                CultureName: "de-DE", ToleranceText: "0,05", OutputHandler: "Clipboard"));
            Check(localized.CanExecute, "Tolerance uses the caller's culture when parsing source number text");

            GeoprocessingPolylineResponse smoothed = GeoprocessingToolService.Execute(new(
                sourcePath, revision, workspace, "Local", "English", "Smooth", "Selected", capturedLines,
                CultureName: "en-US", MovingAverageWindowText: "5", MovingAveragePassesText: "1",
                OutputHandler: "Clipboard"));
            var sourceLine = new Polyline(3);
            sourceLine.Add(new Point(0, 0)); sourceLine.Add(new Point(1, 0.01)); sourceLine.Add(new Point(2, 0));
            double[][] expected = sourceLine.CloneWithMovingAverageSmoothing(5, 1).Points
                .Select(point => new[] { point.X, point.Y }).ToArray();
            Check(smoothed.CanExecute && smoothed.Outputs.Length == 1
                  && smoothed.Outputs[0].Coordinates.Length == expected.Length
                  && smoothed.Outputs[0].Coordinates.Zip(expected).All(pair =>
                      pair.First[0] == pair.Second[0] && pair.First[1] == pair.Second[1]),
                "Smooth uses the retained Moving Average implementation with the source defaults");

            GeoprocessingPolylineResponse invalidRange = GeoprocessingToolService.Execute(new(
                sourcePath, revision, workspace, "Local", "English", "Smooth", "Selected", capturedLines,
                CultureName: "en-US", MovingAverageWindowText: "2", MovingAveragePassesText: "1",
                OutputHandler: "Clipboard"));
            Check(!invalidRange.CanExecute && invalidRange.ValidationIssues.Any(issue =>
                    issue.Field == "MovingAverageWindow" && issue.Severity == "Error"),
                "Moving Average preserves the source Range(3, 101) contract");

            GeoprocessingPolylineValidationResponse liveRange = GeoprocessingToolService.ValidateInputs(new(
                "Smooth", CultureName: "en-US", MovingAverageWindowText: "2", MovingAveragePassesText: "1"));
            Check(liveRange.ValidationIssues.Any(issue => issue.Field == "MovingAverageWindow" && issue.Severity == "Error"),
                "Parameter-only validation exposes the retained source range before execution.");
            GeoprocessingPolylineValidationResponse liveType = GeoprocessingToolService.ValidateInputs(new(
                "Filter", CultureName: "en-US", ToleranceText: "not a number"));
            Check(liveType.ValidationIssues.Any(issue => issue.Field == "Tolerance" && issue.Severity == "TypeError"),
                "Parameter-only validation preserves the source typed-input severity.");
            GeoprocessingPolylineValidationResponse liveName = GeoprocessingToolService.ValidateInputs(new(
                "Reverse", OutputHandler: "Shapefile", OutputName: ""));
            Check(liveName.ValidationIssues.Any(issue => issue.Field == "OutputName" && issue.Severity == "Error"),
                "Parameter-only validation applies the output Name validation only when that handler uses it.");
            GeoprocessingPolylineValidationResponse liveMergeRange = GeoprocessingToolService.ValidateInputs(new(
                "MergePolylines", CultureName: "en-US", MergeToleranceText: "10001"));
            Check(liveMergeRange.ValidationIssues.Any(issue => issue.Field == "Tolerance" && issue.Severity == "Error"),
                "Merge tolerance preserves the source Range(0, 10000) contract.");

            GeoprocessingPolylineResponse invalidTypedValue = GeoprocessingToolService.Execute(new(
                sourcePath, revision, workspace, "Local", "English", "Filter", "All", capturedLines,
                CultureName: "en-US", ToleranceText: "not a number", OutputHandler: "Clipboard"));
            Check(!invalidTypedValue.CanExecute && invalidTypedValue.Outputs.Length == 0
                  && invalidTypedValue.ClipboardText is null
                  && invalidTypedValue.ValidationIssues.Any(issue => issue.Field == "Tolerance" && issue.Severity == "TypeError"),
                "A source TypeError blocks execution instead of silently using a fallback number.");

            var reverseInput = new GeoprocessingPolylineInput("reverse-feature", "reverse-path", 3, 0,
                [[0, 0], [1, 0.01], [2, 0]], ["10", "20", "30"], ["1", "2", "3"]);
            Polyline expectedReverse = ToSourcePolyline(reverseInput);
            expectedReverse.Reverse();
            GeoprocessingPolylineResponse reversed = GeoprocessingToolService.Execute(new(
                sourcePath, revision, workspace, "Local", "English", "Reverse", "All", [reverseInput],
                OutputHandler: "Clipboard"));
            Check(reversed.CanExecute && reversed.Outputs.Length == 1
                  && OutputMatches(reversed.Outputs[0], expectedReverse)
                  && reversed.Outputs[0].PathIdentity == reverseInput.PathIdentity
                  && reversed.Outputs[0].ZValues is ["30", "20", "10"]
                  && reversed.Outputs[0].MValues is ["3", "2", "1"],
                "Reverse uses the retained clone-and-reverse operation while preserving path identity and ordinate order.");

            var longLine = new GeoprocessingPolylineInput("long-feature", "long-path", 4, 0, [[0, 0], [2, 0]]);
            Polyline expectedDensified = ToSourcePolyline(longLine);
            expectedDensified.Densify(0.5);
            GeoprocessingPolylineResponse densified = GeoprocessingToolService.Execute(new(
                sourcePath, revision, workspace, "Local", "English", "DensifyPolylines", "All", [longLine],
                CultureName: "de-DE", MaxSegmentLengthText: "0,5", OutputHandler: "Clipboard"));
            Check(densified.CanExecute && densified.Outputs.Length == 1
                  && OutputMatches(densified.Outputs[0], expectedDensified)
                  && densified.Outputs[0].PathIdentity == longLine.PathIdentity,
                "Densify parses localized numbers and matches the retained Polyline.Densify result.");

            var shortLine = new GeoprocessingPolylineInput("short-feature", "short-path", 5, 0, [[0, 1], [1, 1]]);
            var keptLine = new GeoprocessingPolylineInput("kept-feature", "kept-path", 6, 0, [[0, 2], [2, 2]]);
            GeoprocessingPolylineResponse culled = GeoprocessingToolService.Execute(new(
                sourcePath, revision, workspace, "Local", "English", "CullByLength", "All", [shortLine, keptLine],
                CultureName: "en-US", MinimumLengthText: "1.5", OutputHandler: "Clipboard"));
            Check(culled.CanExecute && culled.Outputs.Length == 1
                  && culled.Outputs[0].FeatureIdentity == keptLine.FeatureIdentity
                  && culled.Outputs[0].PathIdentity == keptLine.PathIdentity
                  && OutputMatches(culled.Outputs[0], ToSourcePolyline(keptLine)),
                "CullByLength retains only source lines at least as long as MinLength and keeps their identities.");

            var mergeFirst = new GeoprocessingPolylineInput("merge-a", "merge-path-a", 7, 0, [[0, 3], [1, 3]]);
            var mergeSecond = new GeoprocessingPolylineInput("merge-b", "merge-path-b", 8, 0, [[1, 3], [2, 3]]);
            Polyline[] mergeInputs = [ToSourcePolyline(mergeFirst), ToSourcePolyline(mergeSecond)];
            PolylineMergeHelpers.MergeResult expectedMerge = PolylineMergeHelpers.MergePolylines(
                mergeInputs, 0.1, MergeMode.PreferClosest);
            List<Polyline> expectedMergedLines = [.. expectedMerge.MergedPolylines];
            expectedMergedLines.AddRange(expectedMerge.UnmergedIndices.Select(index => mergeInputs[index].Clone()));
            GeoprocessingPolylineResponse merged = GeoprocessingToolService.Execute(new(
                sourcePath, revision, workspace, "Local", "English", "MergePolylines", "All", [mergeFirst, mergeSecond],
                CultureName: "en-US", MergeToleranceText: "0.1", MergeMode: "PreferClosest", OutputHandler: "Clipboard"));
            Check(merged.CanExecute && merged.Outputs.Length == expectedMergedLines.Count
                  && merged.Outputs.Select((output, index) => OutputMatches(output, expectedMergedLines[index])).All(value => value)
                  && merged.Outputs.Select((output, index) => output.PathIdentity == "geoprocessing-output-path:" + index).All(value => value),
                "Merge uses the retained merge helper and preserves its merged-then-unmerged output ordering.");

            var offsetInput = new GeoprocessingPolylineInput("offset-feature", "offset-path", 9, 0, [[0, 4], [2, 4]]);
            var expectedOffsetLines = new List<Polyline>();
            _ = OffsetPolylineFactory.TryComputeOffsetParts(ToSourcePolyline(offsetInput), 0.5,
                OffsetSides.Left, includeEndpoints: true, results: expectedOffsetLines);
            GeoprocessingPolylineResponse offset = GeoprocessingToolService.Execute(new(
                sourcePath, revision, workspace, "Local", "English", "LineOffset", "All", [offsetInput],
                CultureName: "de-DE", OffsetText: "0,5", OffsetSides: "Left", IncludeEndpoints: true,
                OutputHandler: "Clipboard"));
            Check(offset.CanExecute && offset.Outputs.Length == expectedOffsetLines.Count
                  && offset.Outputs.Select((output, index) => OutputMatches(output, expectedOffsetLines[index])).All(value => value)
                  && offset.Outputs.Select((output, index) => output.PathIdentity == "geoprocessing-output-path:" + index).All(value => value),
                "Offset uses the retained factory with localized width, selected bank, and endpoint option.");
            Check(File.ReadAllBytes(sourcePath).SequenceEqual(sourceBytes),
                "All additional retained operations leave the captured GeoJSON source bytes unchanged.");

            Expect<SourceFileChangedException>(() => GeoprocessingToolService.Execute(new(
                sourcePath, new string('0', 64), workspace, "Local", "English", "Filter", "All", capturedLines,
                OutputHandler: "Clipboard")));
            Expect<InvalidDataException>(() => GeoprocessingToolService.Execute(new(
                sourcePath, revision, workspace, "Local", "English", "Filter", "Selected", [
                    capturedLines[0], capturedLines[0]
                ], OutputHandler: "Clipboard")));

            string shapePath = Path.Combine(workspace, "source-lines.shp");
            var shapeLine = new Polyline(new Point[] { new(4, 2), new(5, 2.02), new(6, 2) });
            shapeLine.TrackZ([10, 20, 30]);
            shapeLine.TrackM([1, 2, 3]);
            var shapeProjection = new EPSGProjection(32650);
            Check(ShapefileIO.Write(shapePath, new List<Polyline> { shapeLine }, projection: shapeProjection).Result,
                "Actual retained Shapefile writer creates a line-source fixture.");
            string projectionPath = ShapefileIO.PRJFilename(shapePath);
            MapSourceFamilyCapture family = MapTreeService.CaptureShapefileFamily(shapePath);
            string shapeRevision = family.Files.Single(file => file.Role == "source").Revision!;
            var familyBytes = family.Files.Where(file => file.Exists)
                .ToDictionary(file => file.Path, file => File.ReadAllBytes(file.Path), StringComparer.Ordinal);
            GeoprocessingPolylineInput shapeInput = new(
                "shape-feature-0", "shape-path-0", 0, 0, [[4, 2], [5, 2.02], [6, 2]],
                ["10", "20", "30"], ["1", "2", "3"]);
            GeoprocessingPolylineResponse shapeResult = GeoprocessingToolService.Execute(new(
                shapePath, shapeRevision, workspace, "EPSG", "32650", "Filter", "All", [shapeInput],
                CultureName: "en-US", ToleranceText: "0.05", OutputHandler: "Clipboard",
                SourceFamily: family, TargetProjectionWKT: shapeProjection.GetWKT()));
            Check(shapeResult.CanExecute && shapeResult.Outputs.Length == 1
                  && shapeResult.Outputs[0].PathIdentity == shapeInput.PathIdentity
                  && shapeResult.Outputs[0].ZValues is ["10", "30"]
                  && shapeResult.Outputs[0].MValues is ["1", "3"],
                "Shapefile processing uses the loaded stable line identity and a full captured source family.");

            GeoprocessingPolylineResponse smoothShape = GeoprocessingToolService.Execute(new(
                shapePath, shapeRevision, workspace, "EPSG", "32650", "Smooth", "All", [shapeInput],
                CultureName: "en-US", MovingAverageWindowText: "5", MovingAveragePassesText: "1",
                OutputHandler: "Clipboard", SourceFamily: family, TargetProjectionWKT: shapeProjection.GetWKT()));
            Check(smoothShape.CanExecute && smoothShape.Outputs.Length == 1
                  && smoothShape.Outputs[0].ZValues is null && smoothShape.Outputs[0].MValues is null,
                "Moving Average keeps the source XY-only smoothing semantics instead of inventing Z/M interpolation.");

            GeoprocessingPolylineResponse shapeFileOutput = GeoprocessingToolService.Execute(new(
                shapePath, shapeRevision, workspace, "EPSG", "32650", "Filter", "All", [shapeInput],
                CultureName: "en-US", ToleranceText: "0.05", OutputHandler: "Shapefile",
                OutputName: "Filtered Lines", SourceFamily: family, TargetProjectionWKT: shapeProjection.GetWKT()));
            string outputShapePath = shapeFileOutput.OutputPath ?? "";
            Check(shapeFileOutput.CanExecute && Path.IsPathFullyQualified(outputShapePath)
                  && File.Exists(outputShapePath) && File.Exists(ShapefileIO.SHXFilename(outputShapePath))
                  && File.Exists(ShapefileIO.DBFFilename(outputShapePath))
                  && File.Exists(ShapefileIO.PRJFilename(outputShapePath)),
                "Shapefile output writes a real complete file family under the project Exports directory.");
            Check(new WKTProjection(File.ReadAllText(ShapefileIO.PRJFilename(outputShapePath))).IsEqual(shapeProjection),
                "The output sidecar records the captured map target projection.");
            Check(familyBytes.All(pair => File.ReadAllBytes(pair.Key).SequenceEqual(pair.Value)),
                "Successful processing leaves every captured Shapefile source-family byte unchanged.");
            Expect<InvalidDataException>(() => GeoprocessingToolService.Execute(new(
                shapePath, shapeRevision, workspace, "EPSG", "32650", "Filter", "All", [shapeInput],
                CultureName: "en-US", ToleranceText: "0.05", OutputHandler: "Clipboard",
                SourceFamily: family, TargetProjectionWKT: new EPSGProjection(32651).GetWKT())));
            File.WriteAllText(projectionPath, "changed source projection sidecar");
            Expect<SourceFileChangedException>(() => GeoprocessingToolService.Execute(new(
                shapePath, shapeRevision, workspace, "Local", "English", "Filter", "All", [shapeInput],
                CultureName: "en-US", ToleranceText: "0.05", OutputHandler: "Clipboard",
                SourceFamily: family)));
        }
        finally
        {
            if (Directory.Exists(workspace)) Directory.Delete(workspace, recursive: true);
        }

        Console.WriteLine("Retained line geoprocessors use source algorithms, preserve captured path identity and culture-aware validation, and leave source bytes unchanged.");
    }

    private static void Check(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }

    private static Polyline ToSourcePolyline(GeoprocessingPolylineInput input)
    {
        var polyline = new Polyline(input.Coordinates.Length);
        foreach (double[] coordinate in input.Coordinates) polyline.Add(new Point(coordinate[0], coordinate[1]));
        if (input.ZValues is not null)
            polyline.TrackZ(input.ZValues.Select(value => double.Parse(value, System.Globalization.CultureInfo.InvariantCulture)).ToList());
        if (input.MValues is not null)
            polyline.TrackM(input.MValues.Select(value => double.Parse(value, System.Globalization.CultureInfo.InvariantCulture)).ToList());
        return polyline;
    }

    private static bool OutputMatches(GeoprocessingPolylineOutput output, Polyline expected) =>
        output.Coordinates.Length == expected.Count
        && output.Coordinates.Select((coordinate, index) =>
            coordinate[0] == expected.Points[index].X && coordinate[1] == expected.Points[index].Y).All(value => value);

    private static void Expect<TException>(Action action) where TException : Exception
    {
        try { action(); }
        catch (TException) { return; }
        throw new InvalidOperationException("Expected " + typeof(TException).Name + ".");
    }
}
