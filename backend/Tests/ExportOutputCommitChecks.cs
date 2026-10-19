using Ras.Backend;

internal static class ExportOutputCommitChecks
{
    internal static async Task Run()
    {
        using var temporary = new TemporaryDirectory();
        await CheckDestinationLeaseUsesOneWorkerThread(temporary.FullName).ConfigureAwait(false);
        CheckShapefilePublishesFromPreparedReceipts(temporary.FullName);
        CheckShapefileRollbackPreservesExternallyChangedMembers(temporary.FullName);
        Console.WriteLine("Export output commit lease and Shapefile receipt/rollback checks passed.");
    }

    private static async Task CheckDestinationLeaseUsesOneWorkerThread(string root)
    {
        string destination = Path.Combine(root, "lease", "output.tif");
        Directory.CreateDirectory(Path.GetDirectoryName(destination)!);
        using var started = new ManualResetEventSlim();
        Task<bool> secondWorker;
        using (ExportDestinationLease.Acquire(destination))
        {
            secondWorker = Task.Run(() =>
            {
                started.Set();
                using ExportDestinationLease secondLease = ExportDestinationLease.Acquire(destination);
                return true;
            });
            Check(started.Wait(TimeSpan.FromSeconds(5)), "A competing export worker starts.");
            Check(!secondWorker.Wait(TimeSpan.FromMilliseconds(100)),
                "A competing backend worker waits for the same destination lease.");
        }
        Check(await secondWorker.WaitAsync(TimeSpan.FromSeconds(5)).ConfigureAwait(false),
            "The waiting worker acquires and releases its lease on its owning thread.");
    }

    private static void CheckShapefilePublishesFromPreparedReceipts(string root)
    {
        string stagedDirectory = Path.Combine(root, "prepared-shapefile");
        string outputDirectory = Path.Combine(root, "prepared-output");
        Directory.CreateDirectory(stagedDirectory);
        Directory.CreateDirectory(outputDirectory);
        string stagedShp = Path.Combine(stagedDirectory, "contours.shp");
        string destinationShp = Path.Combine(outputDirectory, "contours.shp");
        WriteFamily(stagedShp, includeProjection: true);

        ExportOutputCommit.PreparedShapefileFamily prepared =
            ExportOutputCommit.PrepareShapefileFamily(stagedShp, destinationShp);
        string[] preparedExtensions = prepared.Receipts.Select(receipt => Path.GetExtension(receipt.Path)).ToArray();
        Check(preparedExtensions.SequenceEqual([".shx", ".dbf", ".prj", ".shp"], StringComparer.Ordinal),
            "The final Shapefile receipt is prepared before publication and orders the .shp visibility marker last.");
        ExportOutputCommit.VerifyPreparedShapefileFamily(prepared);

        ExportArtifactReceipt[] published = ExportOutputCommit.CommitPreparedShapefileFamily(prepared);
        Check(published.SequenceEqual(prepared.Receipts),
            "Commit returns the exact already-prepared artifact receipts.");
        foreach (ExportArtifactReceipt receipt in published)
        {
            Check(File.Exists(receipt.Path), "Every committed Shapefile component exists.");
            Check(ExportOutputCommit.Describe(receipt.Path).SHA256 == receipt.SHA256,
                "Each returned receipt describes its committed component.");
        }
        Check(File.Exists(destinationShp), "The .shp marker exists after all sidecars were committed.");
    }

    private static void CheckShapefileRollbackPreservesExternallyChangedMembers(string root)
    {
        string stagedDirectory = Path.Combine(root, "rollback-shapefile");
        string outputDirectory = Path.Combine(root, "rollback-output");
        Directory.CreateDirectory(stagedDirectory);
        Directory.CreateDirectory(outputDirectory);
        string stagedShp = Path.Combine(stagedDirectory, "depth.shp");
        string destinationShp = Path.Combine(outputDirectory, "depth.shp");
        WriteFamily(stagedShp, includeProjection: false);
        ExportOutputCommit.PreparedShapefileFamily prepared =
            ExportOutputCommit.PrepareShapefileFamily(stagedShp, destinationShp);

        IOException failure = ExpectIOException(() => ExportOutputCommit.CommitPreparedShapefileFamily(
            prepared, (source, destination) =>
            {
                string extension = Path.GetExtension(source);
                if (extension.Equals(".shp", StringComparison.OrdinalIgnoreCase))
                {
                    File.WriteAllText(destination, "external file created during publication");
                    throw new IOException("Simulated final marker publication failure.");
                }
                File.Move(source, destination);
                if (extension.Equals(".dbf", StringComparison.OrdinalIgnoreCase))
                    File.WriteAllText(destination, "external edit after sidecar publication");
            }));

        string dbf = Path.ChangeExtension(destinationShp, ".dbf");
        string shx = Path.ChangeExtension(destinationShp, ".shx");
        Check(failure.Message.Contains(dbf, StringComparison.Ordinal) &&
              failure.Message.Contains("contents changed", StringComparison.Ordinal),
            "Rollback reports the externally changed component it deliberately preserves.");
        Check(File.ReadAllText(dbf) == "external edit after sidecar publication",
            "Rollback never deletes a published sidecar whose bytes changed externally.");
        Check(!File.Exists(shx), "Rollback removes a published sidecar only while its SHA still matches.");
        Check(File.ReadAllText(destinationShp) == "external file created during publication",
            "Rollback leaves a competing external .shp path untouched.");
    }

    private static void WriteFamily(string stagedShp, bool includeProjection)
    {
        File.WriteAllText(stagedShp, "shape bytes");
        File.WriteAllText(Path.ChangeExtension(stagedShp, ".shx"), "index bytes");
        File.WriteAllText(Path.ChangeExtension(stagedShp, ".dbf"), "attribute bytes");
        if (includeProjection)
            File.WriteAllText(Path.ChangeExtension(stagedShp, ".prj"), "projection bytes");
    }

    private static IOException ExpectIOException(Action action)
    {
        try { action(); }
        catch (IOException error) { return error; }
        throw new InvalidOperationException("Expected an IOException.");
    }

    private static void Check(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }
}
