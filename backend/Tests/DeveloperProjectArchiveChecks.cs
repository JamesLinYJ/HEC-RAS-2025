using System.Text.Json;
using System.IO.Compression;
using System.Security.Cryptography;
using System.Xml.Linq;
using Ras.Backend;
using Ras.Layers;
using Utility.Units;

internal static class DeveloperProjectArchiveChecks
{
    internal static async Task Run()
    {
        ProjectArchiveUsesRetainedSourceMethodAndVerifiesItsInventory();
        ProjectArchivePreservesExternalConnectionPaths();
        ProjectArchiveRejectsStaleProjectsAndCleanupCannotDeleteArbitraryPaths();
        await ProjectArchiveCancellationRemovesTheOwnedStageAndArchive();
        Console.WriteLine("Developer uploads use the retained project archive operation and opaque cleanup capability.");
    }

    private static async Task ProjectArchiveCancellationRemovesTheOwnedStageAndArchive()
    {
        using var directory = new TemporaryDirectory();
        string projectPath = Path.Combine(directory.FullName, "Cancelled.ras");
        _ = Project.CreateNew(projectPath, UnitSystem.SI);
        string payloadPath = Path.Combine(directory.FullName, "large-support.bin");
        File.WriteAllBytes(payloadPath, new byte[32 * 1024 * 1024]);
        Dictionary<string, string> originalInventory = CaptureInventory(directory.FullName);
        string expectedRevision = Revision(projectPath);
        const string requestID = "developer-archive-cancel-check";
        var controlText = new CancellationControlTextReader();
        await using var controls = new BackendDuplexControlReader(requestID, controlText);
        int cancellationSent = 0;

        DeveloperProjectArchiveResult result = await DeveloperProjectArchiveService.PrepareDuplexAsync(
            new DeveloperProjectArchiveRequest(projectPath, IncludeResults: false, expectedRevision),
            update =>
            {
                if (update.Fraction is >= 0.05 && Interlocked.Exchange(ref cancellationSent, 1) == 0)
                {
                    controlText.SendCancel(requestID);
                    // Let the dedicated control pump consume the frame before
                    // the next copy chunk reaches its cancellation checkpoint.
                    Thread.Sleep(TimeSpan.FromMilliseconds(25));
                }
            }, controls);

        Check(Volatile.Read(ref cancellationSent) == 1,
            "The real duplex control path accepted a cancellation after staging had begun.");
        Check(result.State == "cancelled" && result.EntryCount == 0,
            "A source cancel is reported as cancelled rather than a completed upload archive.");
        Check(!StageExists(result.CleanupToken) && !File.Exists(result.ArchivePath),
            "Cancellation removes both the owned staging copy and any partial archive.");
        Check(InventoryMatches(originalInventory, CaptureInventory(directory.FullName)),
            "Cancellation leaves the original project inventory byte-for-byte unchanged.");
    }

    private static void ProjectArchiveUsesRetainedSourceMethodAndVerifiesItsInventory()
    {
        using var directory = new TemporaryDirectory();
        string projectPath = Path.Combine(directory.FullName, "Upload.ras");
        Project project = Project.CreateNew(projectPath, UnitSystem.SI);
        string resultPath = Path.Combine(project.ResultsDirectory, "Result payload.txt");
        Directory.CreateDirectory(project.ResultsDirectory);
        File.WriteAllText(Path.Combine(directory.FullName, "supporting data.txt"), "project support");
        File.WriteAllText(Path.Combine(directory.FullName, ".lock"), "excluded by the source method");
        File.WriteAllText(resultPath, "result payload");
        string requestedProjectSHA = Revision(projectPath);
        byte[] originalProjectBytes = File.ReadAllBytes(projectPath);
        string supportingPath = Path.Combine(directory.FullName, "supporting data.txt");
        string lockPath = Path.Combine(directory.FullName, ".lock");
        byte[] originalSupportingBytes = File.ReadAllBytes(supportingPath);
        byte[] originalResultsBytes = File.ReadAllBytes(resultPath);
        Dictionary<string, string> originalInventory = CaptureInventory(directory.FullName);

        DeveloperProjectArchiveResult withoutResults = DeveloperProjectArchiveService.Prepare(new(
            projectPath, IncludeResults: false, requestedProjectSHA));
        Check(!StageExists(withoutResults.CleanupToken),
            "The private staging copy is removed before the prepared archive is returned.");
        try
        {
            Check(withoutResults.State == "completed" && withoutResults.ProjectPath == projectPath,
                "The completed archive reports its actual project path and terminal state.");
            Check(withoutResults.SourceProjectSHA256 == requestedProjectSHA,
                "The archive receipt preserves the project revision captured by the caller.");
            Check(IsSHA256(withoutResults.InventorySHA256) && withoutResults.EntryCount >= 2,
                "The archive receipt carries a verified file inventory and entry count.");

            using ZipArchive archive = ZipFile.OpenRead(withoutResults.ArchivePath);
            string rootName = Path.GetFileName(directory.FullName);
            ZipArchiveEntry projectEntry = archive.GetEntry(rootName + "/Upload.ras")
                ?? throw new InvalidOperationException("The archive omitted its project XML.");
            Check(Revision(projectEntry) == withoutResults.ProjectSHA256,
                "The receipt identifies the saved staged project XML bytes inside the archive.");
            Check(archive.Entries.Any(entry => entry.FullName == rootName + "/Upload.ras"),
                "The retained source ZIP layout includes the project directory as its root entry prefix.");
            Check(archive.Entries.Any(entry => entry.FullName == rootName + "/supporting data.txt"),
                "Project support files are included in the source archive.");
            Check(!archive.Entries.Any(entry => entry.FullName.EndsWith("/.lock", StringComparison.Ordinal)
                    || entry.FullName == ".lock"),
                "The retained source method excludes .lock files.");
            Check(!archive.Entries.Any(entry => entry.FullName.StartsWith(rootName + "/Results/",
                    StringComparison.OrdinalIgnoreCase)),
                "Disabling Results excludes the same Results directory content as ZipFullProject.");
        }
        finally
        {
            DeveloperProjectArchiveService.Cleanup(new(withoutResults.CleanupToken));
        }

        Check(!File.Exists(withoutResults.ArchivePath),
            "Cleanup removes only the archive owned by the returned opaque token.");
        Check(File.ReadAllBytes(projectPath).SequenceEqual(originalProjectBytes) &&
              File.ReadAllBytes(supportingPath).SequenceEqual(originalSupportingBytes) &&
              File.ReadAllBytes(resultPath).SequenceEqual(originalResultsBytes) &&
              File.Exists(lockPath),
            "Creating an upload archive leaves every original project file byte-for-byte unchanged.");
        Check(InventoryMatches(originalInventory, CaptureInventory(directory.FullName)),
            "Creating an upload archive leaves the complete original project inventory byte-for-byte unchanged.");
        Check(DeveloperProjectArchiveService.Cleanup(new(withoutResults.CleanupToken)).Cleaned,
            "Cleanup is idempotent after its own archive has been removed.");

        DeveloperProjectArchiveResult withResults = DeveloperProjectArchiveService.Prepare(new(
            projectPath, IncludeResults: true, Revision(projectPath)));
        Check(!StageExists(withResults.CleanupToken),
            "The staging copy is removed when Results are included.");
        try
        {
            using ZipArchive archive = ZipFile.OpenRead(withResults.ArchivePath);
            string rootName = Path.GetFileName(directory.FullName);
            Check(archive.Entries.Any(entry => entry.FullName == rootName + "/Results/Result payload.txt"),
                "Enabling Results includes result files.");
            Check(withResults.EntryCount == archive.Entries.Count,
                "The receipt count equals the verified archive entry count.");
        }
        finally
        {
            DeveloperProjectArchiveService.Cleanup(new(withResults.CleanupToken));
        }
        Check(InventoryMatches(originalInventory, CaptureInventory(directory.FullName)),
            "Creating an archive with Results enabled leaves the complete original project inventory unchanged.");
    }

    private static void ProjectArchiveRejectsStaleProjectsAndCleanupCannotDeleteArbitraryPaths()
    {
        using var directory = new TemporaryDirectory();
        string projectPath = Path.Combine(directory.FullName, "Stale.ras");
        _ = Project.CreateNew(projectPath, UnitSystem.SI);
        string actualRevision = Revision(projectPath);
        File.AppendAllText(projectPath, " changed after the caller snapshot");

        bool rejectedAsStale = false;
        try { _ = DeveloperProjectArchiveService.Prepare(new(projectPath, true, actualRevision)); }
        catch (SourceFileChangedException) { rejectedAsStale = true; }
        catch (Exception error)
        {
            throw new InvalidOperationException("A stale source project should use the source-changed error.", error);
        }
        Check(rejectedAsStale, "A project that differs from the caller's captured revision is rejected.");

        string outside = Path.Combine(directory.FullName, "keep.txt");
        File.WriteAllText(outside, "must survive invalid cleanup input");
        DeveloperProjectArchiveCleanupResult rejected = DeveloperProjectArchiveService.Cleanup(new(
            "../../" + Path.GetFileName(outside)));
        Check(!rejected.Cleaned && File.ReadAllText(outside) == "must survive invalid cleanup input",
            "Invalid cleanup text cannot turn into an arbitrary filesystem delete.");
    }

    private static void ProjectArchivePreservesExternalConnectionPaths()
    {
        using var directory = new TemporaryDirectory();
        string projectDirectory = Path.Combine(directory.FullName, "Project");
        string sharedDirectory = Path.Combine(directory.FullName, "Shared");
        Directory.CreateDirectory(projectDirectory);
        Directory.CreateDirectory(sharedDirectory);
        string projectPath = Path.Combine(projectDirectory, "Connected.ras");
        string externalPath = Path.Combine(sharedDirectory, "boundary.dss");
        File.WriteAllText(externalPath, "external connection target");
        Project project = Project.CreateNew(projectPath, UnitSystem.SI);
        project.ConnectionSource.AddFileConnection("Boundary data", externalPath);
        project.Save();
        (string Name, string Relative, string Absolute)[] sourceConnections = ReadConnectionPaths(projectPath);
        Dictionary<string, string> sourceInventory = CaptureInventory(projectDirectory);
        string expectedRevision = Revision(projectPath);

        DeveloperProjectArchiveResult result = DeveloperProjectArchiveService.Prepare(new(
            projectPath, IncludeResults: false, expectedRevision));
        try
        {
            using ZipArchive archive = ZipFile.OpenRead(result.ArchivePath);
            using Stream projectEntry = (archive.GetEntry("Project/Connected.ras")
                ?? throw new InvalidOperationException("The archive omitted its project XML.")).Open();
            (string Name, string Relative, string Absolute)[] archivedConnections = ReadConnectionPaths(projectEntry);
            Check(sourceConnections.SequenceEqual(archivedConnections),
                "Staging preserves external connection paths instead of rebasing them to the temporary folder.");
        }
        finally
        {
            DeveloperProjectArchiveService.Cleanup(new(result.CleanupToken));
        }
        Check(!StageExists(result.CleanupToken),
            "The external-connection staging copy is removed after archive creation.");
        Check(InventoryMatches(sourceInventory, CaptureInventory(projectDirectory)),
            "Preparing a project with external connections leaves its complete source inventory unchanged.");
    }

    private static string Revision(string path)
    {
        using FileStream stream = File.OpenRead(path);
        return Convert.ToHexString(SHA256.HashData(stream)).ToLowerInvariant();
    }

    private static string Revision(ZipArchiveEntry entry)
    {
        using Stream stream = entry.Open();
        return Convert.ToHexString(SHA256.HashData(stream)).ToLowerInvariant();
    }

    private static Dictionary<string, string> CaptureInventory(string root) =>
        Directory.EnumerateFiles(root, "*", SearchOption.AllDirectories)
            .OrderBy(path => path, StringComparer.Ordinal)
            .ToDictionary(path => Path.GetRelativePath(root, path).Replace(Path.DirectorySeparatorChar, '/'),
                Revision, StringComparer.Ordinal);

    private static bool StageExists(string cleanupToken) => Directory.Exists(Path.Combine(
        Path.GetTempPath(), "HECRAS2025-DeveloperArchives", ".stage-" + cleanupToken));

    private static bool InventoryMatches(IReadOnlyDictionary<string, string> expected,
        IReadOnlyDictionary<string, string> actual) => expected.Count == actual.Count &&
        expected.All(pair => actual.TryGetValue(pair.Key, out string? revision) &&
            string.Equals(pair.Value, revision, StringComparison.Ordinal));

    private sealed class CancellationControlTextReader : TextReader
    {
        private readonly TaskCompletionSource<string?> nextLine =
            new(TaskCreationOptions.RunContinuationsAsynchronously);

        public void SendCancel(string id) => nextLine.TrySetResult(JsonSerializer.Serialize(new
        {
            id,
            controlSequence = 1,
            control = new { type = "cancel" }
        }));

        public override ValueTask<string?> ReadLineAsync(CancellationToken cancellationToken) =>
            new(nextLine.Task.WaitAsync(cancellationToken));
    }

    private static (string Name, string Relative, string Absolute)[] ReadConnectionPaths(string path) =>
        ReadConnectionPaths(XDocument.Load(path));

    private static (string Name, string Relative, string Absolute)[] ReadConnectionPaths(Stream stream) =>
        ReadConnectionPaths(XDocument.Load(stream));

    private static (string Name, string Relative, string Absolute)[] ReadConnectionPaths(XDocument document) =>
        document.Descendants("Connection").Select(connection => (
            connection.Attribute("Name")?.Value ?? "",
            connection.Element("Source")?.Element("RelativePath")?.Value ?? "",
            connection.Element("Source")?.Element("AbsolutePath")?.Value ?? "")).ToArray();

    private static bool IsSHA256(string value) => value.Length == 64 &&
        value.All(character => character is >= '0' and <= '9' or >= 'a' and <= 'f');

    private static void Check(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }
}
