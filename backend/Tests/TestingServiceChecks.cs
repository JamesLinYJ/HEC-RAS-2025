using Ras.Backend;
using Testing.Core;
using Testing.Core.Regression;

internal static class TestingServiceChecks
{
    internal static async Task Run()
    {
        using var temporary = new TemporaryDirectory();
        string poiPath = PoiShapefile.PathFor(temporary.FullName);
        PoiShapefile.Write(poiPath,
        [
            new PoiPoint(12.5, -7.25, "中文 POI"),
            new PoiPoint(0, 1, "Second")
        ]);
        TestingPoint[] imported = await TestingService.ImportPointsAsync(new TestingPoiImportRequest(poiPath))
            .ConfigureAwait(false);
        Check(imported.Length == 2 && imported[0] == new TestingPoint(null, "中文 POI", 12.5, -7.25)
            && imported[1] == new TestingPoint(null, "Second", 0, 1),
            "Testing POI import reads actual retained Shapefile geometry and name values.");

        (string type, int id) = TestingService.ParseObjectID("project:42");
        Check(type == "project" && id == 42, "Testing object IDs preserve source object kind and server ID.");
        (type, id) = TestingService.ParseObjectID("geometry:7");
        Check(type == "geometry" && id == 7, "Geometry run targets preserve source object kind and server ID.");
        Expect<ArgumentException>(() => TestingService.ParseObjectID("project:0"));
        Expect<ArgumentException>(() => TestingService.ParseObjectID("other:42"));
        Expect<ArgumentException>(() => TestingService.ParseObjectID("project:42:extra"));

        TestingRunRequest normalized = TestingService.CreateRunRequest("abc123", "nightly", 3,
            42, "Hydraulic model", "geometry");
        AddTestRequest source = TestingService.CreateSourceRunRequest(normalized);
        Check(source.CommitHash == "abc123" && source.Tag == "nightly" && source.NumRuntimeIterations == 3
            && source.TestObjectIdNames is [{ Id: 42, Name: "Hydraulic model", ObjectTypeName: "geometry" }],
            "Queue request maps to the retained Testing.Core AddTestRequest shape without changing target identity.");
        TestingUploadOutcome partial = new("Upload completed; run queue status could not be confirmed.", "project:42", false,
            UploadCompleted: true, ContinuationError: "The server could not read back the object.");
        Check(partial.UploadCompleted && !partial.RunQueued && partial.ContinuationError is not null,
            "A failed post-upload continuation retains the completed upload state without reporting a queued run.");
        Expect<ArgumentOutOfRangeException>(() => TestingService.CreateRunRequest("abc123", "", 0,
            42, "Hydraulic model", "project"));
        Expect<ArgumentOutOfRangeException>(() => TestingService.CreateRunRequest("abc123", "", 1,
            0, "Hydraulic model", "project"));
        Console.WriteLine("Testing Utility source POI import, server identity, and run-request contract checks passed.");
    }

    private static void Expect<TException>(Action action) where TException : Exception
    {
        try { action(); }
        catch (TException) { return; }
        throw new InvalidOperationException($"Expected {typeof(TException).Name} from Testing Utility validation.");
    }

    private static void Check(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }

    private sealed class TemporaryDirectory : IDisposable
    {
        public string FullName { get; } = Path.Combine(Path.GetTempPath(),
            "hecras-testing-service-" + Guid.NewGuid().ToString("N"));

        public TemporaryDirectory() => Directory.CreateDirectory(FullName);

        public void Dispose()
        {
            try { if (Directory.Exists(FullName)) Directory.Delete(FullName, recursive: true); }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }
    }
}
