using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Xml.Linq;
using Geospatial.PairedData;
using Ras.Backend;
using Ras.Layers;
using Ras.Layers.BoundaryConditions;
using Ras.Layers.Meteorology;
using Ras.Layers.Payloads;
using Utility.Files;

internal static class BoundaryInitialConditionsChecks
{
    private static readonly UTF8Encoding StrictUtf8 = new(false, true);

    internal static async Task Run()
    {
        string fixtureDirectory = RequiredDirectory("HECRAS_CULVERT_PARTICLE_ACCEPTANCE_DIRECTORY");
        using JsonDocument manifest = JsonDocument.Parse(File.ReadAllBytes(Path.Combine(fixtureDirectory, "acceptance.json")));
        JsonElement root = manifest.RootElement;
        string projectRelativePath = root.GetProperty("projectRelativePath").GetString()
            ?? throw new InvalidDataException("The retained Result fixture has no project path.");
        string boundaryRelativePath = root.GetProperty("boundaryConditionRelativePath").GetString()
            ?? throw new InvalidDataException("The retained Result fixture has no Boundary Condition path.");
        JsonElement signed = root.GetProperty("results").EnumerateArray()
            .Single(item => item.GetProperty("role").GetString() == "signed-flow");
        JsonElement zero = root.GetProperty("results").EnumerateArray()
            .Single(item => item.GetProperty("role").GetString() == "zero-flow");
        string signedRelativePath = signed.GetProperty("path").GetString()
            ?? throw new InvalidDataException("The retained signed Result path is missing.");
        string signedRevision = signed.GetProperty("revision").GetString()
            ?? throw new InvalidDataException("The retained signed Result revision is missing.");
        string zeroRelativePath = zero.GetProperty("path").GetString()
            ?? throw new InvalidDataException("The retained zero-flow Result path is missing.");
        string zeroRevision = zero.GetProperty("revision").GetString()
            ?? throw new InvalidDataException("The retained zero-flow Result revision is missing.");

        string exportedProjectPath = ResolveRelative(fixtureDirectory, projectRelativePath);
        string exportedBoundaryPath = ResolveRelative(fixtureDirectory, boundaryRelativePath);
        string exportedSignedResultPath = ResolveRelative(fixtureDirectory, signedRelativePath);
        string exportedZeroResultPath = ResolveRelative(fixtureDirectory, zeroRelativePath);
        byte[] exportedProjectBytes = File.ReadAllBytes(exportedProjectPath);
        byte[] exportedBoundaryBytes = File.ReadAllBytes(exportedBoundaryPath);
        byte[] exportedSignedResultBytes = File.ReadAllBytes(exportedSignedResultPath);
        byte[] exportedZeroResultBytes = File.ReadAllBytes(exportedZeroResultPath);

        using var temporary = new TemporaryDirectory();
        string copyRoot = Path.Combine(temporary.FullName, "initial-conditions-source-copy");
        CopyDirectory(fixtureDirectory, copyRoot);
        string projectPath = ResolveRelative(copyRoot, projectRelativePath);
        string boundaryPath = ResolveRelative(copyRoot, boundaryRelativePath);
        string signedResultPath = ResolveRelative(copyRoot, signedRelativePath);
        string zeroResultPath = ResolveRelative(copyRoot, zeroRelativePath);
        Check(HashFile(signedResultPath) == signedRevision && HashFile(zeroResultPath) == zeroRevision,
            "Copied Result HDFs retain the exact SHA values from the real CPU solver manifest.");

        AddEditableSourceRows(boundaryPath, projectPath);
        var copiedSourceFiles = Directory.EnumerateFiles(copyRoot, "*", SearchOption.AllDirectories)
            .Where(path => !path.Contains(Path.Combine(copyRoot, ".hecras-initial-conditions"), StringComparison.Ordinal))
            .ToDictionary(path => Path.GetRelativePath(copyRoot, path), File.ReadAllBytes, StringComparer.Ordinal);
        byte[] sourceProjectBytes = File.ReadAllBytes(projectPath);
        byte[] sourceBoundaryBytes = File.ReadAllBytes(boundaryPath);
        byte[] sourceResultBytes = File.ReadAllBytes(signedResultPath);
        string sourceProjectXml = File.ReadAllText(projectPath, StrictUtf8);
        string projectDraftXml = AddUnsavedProjectDraft(sourceProjectXml);
        string projectRevision = Hash(sourceProjectBytes);

        ModelSnapshot loaded = await ModelEditorAdapter.LoadAsync(
            new ModelRequest(boundaryPath, "Boundary Conditions", projectPath));
        Check(loaded.Boundary is { Lines.Length: >= 2 }, "The copied source Boundary Condition reopens with its retained source lines.");
        BoundaryEditorData boundaryDraft = loaded.Boundary!;
        BoundaryLineData lineToRename = boundaryDraft.Lines[0];
        string renamedLine = "Initial-condition transaction line 🌊";
        var fields = new Dictionary<string, string>
        {
            [lineToRename.Scope + "/DetailedBCLineHeaderControl/BoundaryConditionLine_Name"] = renamedLine
        };
        BoundaryPayloadData regularPayload = boundaryDraft.Lines.SelectMany(line => line.Payloads)
            .Single(payload => payload.Name == "Regular source samples");
        BoundarySeriesData sampledSeries = boundaryDraft.Series.Values
            .Single(series => series.Scope == regularPayload.Scope);
        ModelSample[] editedSamples = sampledSeries.Samples.Select(sample => sample with { }).ToArray();
        int sampleIndex = Array.FindIndex(editedSamples, sample => sample.Y.HasValue);
        Check(sampleIndex >= 0, "The retained source time-series payload exposes an editable sample.");
        double editedSampleValue = editedSamples[sampleIndex].Y!.Value + 3.25;
        editedSamples[sampleIndex] = editedSamples[sampleIndex] with { Y = editedSampleValue };

        BoundaryPayloadData spatialPayload = boundaryDraft.Lines.SelectMany(line => line.Payloads)
            .Single(payload => payload.Name == "Spatial source samples");
        BoundarySeriesData tableSeries = boundaryDraft.Series.Values
            .Single(series => series.Scope == spatialPayload.Scope && series.TableId is not null);
        ModelRow[] editedRows = tableSeries.Rows.Select(row => row with { Values = new(row.Values) }).ToArray();
        editedRows[0].Values["station/0"] = "123.5";
        var requestModel = new ModelSaveRequest(
            boundaryPath, "Boundary Conditions", projectPath, loaded.Revision, fields,
            loaded.Images, projectDraftXml, loaded.SourceState,
            Rows: new Dictionary<string, ModelRow[]> { [tableSeries.TableId!] = editedRows },
            Samples: new Dictionary<string, ModelSample[]> { [sampledSeries.PageId] = editedSamples });

        BoundaryInitialConditionsInspection inspection = ModelEditorAdapter.Inspect(
            new BoundaryInitialConditionsInspectRequest(requestModel, projectRevision,
                signedResultPath, "2026-10-17T00:00:00", "en-US",
                Hash(StrictUtf8.GetBytes(projectDraftXml))));
        Check(inspection.CanAttach && inspection.AssetRevision == loaded.Revision &&
              inspection.ResultRevision == signedRevision && inspection.ProjectRevision == projectRevision,
            "Inspection validates the exact copied Boundary Condition, saved Project, unsaved project draft and CPU Result revisions.");

        string invalidResult = Path.Combine(temporary.FullName, "not-a-result.h5");
        File.Copy(boundaryPath, invalidResult);
        BoundaryInitialConditionsInspection invalid = ModelEditorAdapter.Inspect(
            new BoundaryInitialConditionsInspectRequest(requestModel, projectRevision, invalidResult));
        Check(!invalid.CanAttach && invalid.ErrorMessage == "The selected file is not a valid RAS Result.",
            "Inspection returns a source-backed validation message for a non-Result HDF without mutating the editor sources.");
        await Expect<SourceFileChangedException>(() => ModelEditorAdapter.AttachAsync(
            new BoundaryInitialConditionsAttachRequest(requestModel, projectRevision,
                signedResultPath, new string('0', 64), "stale-result", "2026-10-17T00:00:00", "en-US",
                inspection.ProjectXmlFingerprint)));
        Check(File.ReadAllBytes(projectPath).SequenceEqual(sourceProjectBytes) &&
              File.ReadAllBytes(boundaryPath).SequenceEqual(sourceBoundaryBytes),
            "A stale result revision is rejected before publishing either target file.");

        string operationID = Guid.NewGuid().ToString("N");
        var attachRequest = new BoundaryInitialConditionsAttachRequest(requestModel, projectRevision,
            signedResultPath, signedRevision, operationID, "2026-10-17T00:00:00", "en-US",
            inspection.ProjectXmlFingerprint);
        BoundaryInitialConditionsReceipt receipt = await ModelEditorAdapter.AttachAsync(attachRequest);
        Check(!receipt.AlreadyCommitted && receipt.OperationID == operationID &&
              receipt.Timestamp == attachRequest.Timestamp && receipt.ConnectionName.Length > 0,
            "The retained setter returns its exact newly committed source connection and raw timestep text.");
        Check(receipt.ProjectRevision == Hash(StrictUtf8.GetBytes(receipt.ProjectXml)) &&
              receipt.Model.Revision == HashFile(boundaryPath),
            "The receipt revisions match the exact committed UTF-8 project XML and reopened Boundary Condition HDF.");
        BoundaryEditorData savedBoundary = receipt.Model.Boundary
            ?? throw new InvalidOperationException("The attach receipt has no refreshed Boundary Condition snapshot.");
        Check(savedBoundary.Lines.Single(line => line.Id == lineToRename.Id).Name == renamedLine,
            "The paired attach saves the pending Boundary Condition field edit through the ordinary model pipeline.");
        Check(savedBoundary.Series[sampledSeries.PageId].Samples[sampleIndex].Y == editedSampleValue &&
              savedBoundary.Series[tableSeries.PageId].Rows[0].Values["station/0"] == "123.5",
            "The same transaction preserves pending source time-series samples and spatial table cells.");
        Check(File.ReadAllBytes(signedResultPath).SequenceEqual(sourceResultBytes),
            "Attaching the Result stores a reference and never changes the consumed Result HDF.");

        AssertProjectConnection(receipt.ProjectXml, projectPath, signedResultPath, receipt.ConnectionName);
        AssertReopenedInitialConditions(projectPath, boundaryPath, signedResultPath,
            receipt.ConnectionName, "2026-10-17T00:00:00");
        XDocument savedProject = XDocument.Parse(receipt.ProjectXml, LoadOptions.PreserveWhitespace);
        Check(savedProject.Nodes().OfType<XComment>().Any(comment => comment.Value == "preserve R25 project comment") &&
              savedProject.Nodes().OfType<XProcessingInstruction>().Any(instruction => instruction.Target == "retain" && instruction.Data == "project-draft") &&
              savedProject.Root!.Elements().Any(element => element.Name.LocalName == "R25UnknownExtension" &&
                  (string?)element.Attribute("value") == "keep-this-xml"),
            "Appending the actual connection preserves outer comments, processing instructions and unknown project XML.");

        BoundaryInitialConditionsReceipt repeated = await ModelEditorAdapter.AttachAsync(attachRequest);
        Check(repeated.AlreadyCommitted && repeated.ProjectRevision == receipt.ProjectRevision &&
              repeated.ConnectionName == receipt.ConnectionName,
            "Retrying a lost response returns the same durable receipt without rerunning the retained setter.");
        BoundaryInitialConditionsStatus status = await ModelEditorAdapter.Status(
            new BoundaryInitialConditionsStatusRequest(requestModel, projectRevision,
                signedResultPath, signedRevision, operationID, "2026-10-17T00:00:00", "en-US",
                inspection.ProjectXmlFingerprint));
        BoundaryInitialConditionsReceipt? statusReceipt = status.Receipt;
        Check(status.State == "committed" && statusReceipt is { AlreadyCommitted: true } &&
              statusReceipt.ConnectionName == receipt.ConnectionName,
            "The read-only operation-status route retrieves the committed receipt by exact request identity.");

        ModelSnapshot nextDraft = await ModelEditorAdapter.LoadAsync(new ModelRequest(
            boundaryPath, "Boundary Conditions", projectPath, receipt.ProjectXml, receipt.Model.SourceState));
        var nilTimestampRequest = new BoundaryInitialConditionsAttachRequest(
            new ModelSaveRequest(boundaryPath, "Boundary Conditions", projectPath, nextDraft.Revision,
                [], nextDraft.Images, receipt.ProjectXml, nextDraft.SourceState),
            receipt.ProjectRevision, zeroResultPath, zeroRevision, Guid.NewGuid().ToString("N"),
            Timestamp: null, NumberCulture: "en-US",
            ProjectXmlFingerprint: Hash(StrictUtf8.GetBytes(receipt.ProjectXml)));
        BoundaryInitialConditionsReceipt nilTimestampReceipt = await ModelEditorAdapter.AttachAsync(nilTimestampRequest);
        Check(nilTimestampReceipt.Timestamp == "" && HashFile(zeroResultPath) == zeroRevision,
            "A missing timestamp remains the empty source value in the receipt while the second real Result stays unchanged.");
        AssertReopenedInitialConditions(projectPath, boundaryPath, zeroResultPath,
            nilTimestampReceipt.ConnectionName, "");

        string projectRelative = Path.GetRelativePath(copyRoot, projectPath);
        string boundaryRelative = Path.GetRelativePath(copyRoot, boundaryPath);
        foreach ((string relative, byte[] original) in copiedSourceFiles)
        {
            if (relative == projectRelative || relative == boundaryRelative ||
                relative.StartsWith(".hecras-initial-conditions" + Path.DirectorySeparatorChar, StringComparison.Ordinal)) continue;
            string current = Path.Combine(copyRoot, relative);
            Check(File.Exists(current) && File.ReadAllBytes(current).SequenceEqual(original),
                "Only the saved Project and selected Boundary Condition are replaced by the attach transaction: " + relative);
        }
        Check(File.ReadAllBytes(exportedProjectPath).SequenceEqual(exportedProjectBytes) &&
              File.ReadAllBytes(exportedBoundaryPath).SequenceEqual(exportedBoundaryBytes) &&
              File.ReadAllBytes(exportedSignedResultPath).SequenceEqual(exportedSignedResultBytes) &&
              File.ReadAllBytes(exportedZeroResultPath).SequenceEqual(exportedZeroResultBytes),
            "The exported retained-source fixture remains untouched while all attach mutations occur in its temporary copy.");
        Check(!Directory.EnumerateFiles(copyRoot, ".model-edit-*.pending", SearchOption.AllDirectories).Any(),
            "The coordinated transaction removes its temporary model staging file after commit.");
        Console.WriteLine("Retained Result attachment saves the exact Boundary Condition and Project pair, preserves editor drafts, and never edits the Result HDF.");
    }

    private static void AddEditableSourceRows(string boundaryPath, string projectPath)
    {
        Project project = new(projectPath);
        try
        {
            BoundaryCondition boundary = project.BoundaryConditions.Single(item =>
                SourceFilePaths.SameSourceFile(item.Filename, boundaryPath));
            var lines = boundary.BoundaryConditionLines.Features.ToArray();
            TimeSeriesPayload regular = new("Flow", new RegularTimeSeriesDefinition(TimeSpan.FromHours(1)),
                new double[] { 1d, 2d, 3d }) { Name = "Regular source samples", IsEnabled = false };
            lines[0].Add(regular);
            SpatiallyVariableTimeSeriesPayload spatial = new("Stage", new RegularTimeSeriesDefinition(TimeSpan.FromHours(1)),
                new double[] { 0d, 1d }, [new double[] { 2, 3 }, new double[] { 4, 5 }, new double[] { 6, 7 }])
                { Name = "Spatial source samples", IsEnabled = false };
            lines[1].Add(spatial);
            boundary.Save();
        }
        finally
        {
            foreach (IDisposable layer in ProjectLayers(project)) layer.Dispose();
        }
    }

    private static void AssertProjectConnection(string projectXml, string projectPath, string resultPath, string connectionName)
    {
        XDocument document = XDocument.Parse(projectXml, LoadOptions.PreserveWhitespace);
        XElement connection = document.Root!.Elements().Where(element => element.Name.LocalName == "Connections")
            .SelectMany(element => element.Elements())
            .Single(element => element.Name.LocalName == "Connection" &&
                string.Equals((string?)element.Attribute("Name"), connectionName, StringComparison.Ordinal));
        Check((string?)connection.Attribute("Type") == FileExternalConnection.TypeName,
            "The project stores the retained FileExternalConnection serialization.");
        string? relative = connection.Elements().FirstOrDefault(element => element.Name.LocalName == "RelativePath")?.Value;
        string? absolute = connection.Elements().FirstOrDefault(element => element.Name.LocalName == "AbsolutePath")?.Value;
        Check((!string.IsNullOrEmpty(relative) && SourceFilePaths.SameSourceFile(
                  Path.Combine(Path.GetDirectoryName(projectPath)!, relative), resultPath)) ||
              (!string.IsNullOrEmpty(absolute) && SourceFilePaths.SameSourceFile(absolute, resultPath)),
            "The exact saved FileExternalConnection resolves to the captured Result HDF.");
    }

    private static void AssertReopenedInitialConditions(string projectPath, string boundaryPath,
        string resultPath, string connectionName, string timestamp)
    {
        Project project = new(projectPath);
        try
        {
            BoundaryCondition boundary = project.BoundaryConditions.Single(item =>
                SourceFilePaths.SameSourceFile(item.Filename, boundaryPath));
            InitialStageLayer stage = boundary.InitialConditions.Stage;
            InitialVelocityLayer velocity = boundary.InitialConditions.Velocity;
            Check(stage.IsEnabled && velocity.IsEnabled &&
                  stage.SpatialDataType == SpatialDataType.Gridded && velocity.SpatialDataType == SpatialDataType.Gridded &&
                  stage.GridDataLocation == DataLocation.Remote &&
                  velocity.GridDataLocation == DataLocation.Remote,
                "Both source Initial Conditions reopen enabled as remote gridded inputs.");
            Check(stage.ExternalGriddedConnection == connectionName &&
                  velocity.ExternalGriddedConnection == connectionName &&
                  string.IsNullOrEmpty(stage.ExternalGriddedPath) && string.IsNullOrEmpty(velocity.ExternalGriddedPath) &&
                  (stage.SourceTimestep ?? "") == timestamp && (velocity.SourceTimestep ?? "") == timestamp,
                "Stage and Velocity reference the same one file connection, blank local path and unchanged source timestamp. " +
                JsonSerializer.Serialize(new { connectionName, timestamp,
                    stageConnection = stage.ExternalGriddedConnection, velocityConnection = velocity.ExternalGriddedConnection,
                    stagePath = stage.ExternalGriddedPath, velocityPath = velocity.ExternalGriddedPath,
                    stageTime = stage.SourceTimestep, velocityTime = velocity.SourceTimestep }));
            var connection = project.ConnectionSource.Connections.OfType<FileExternalConnection>()
                .Single(item => item.Name == connectionName);
            Check(SourceFilePaths.SameSourceFile(connection.AbsolutePath, resultPath),
                "An independent Project reload resolves the exact committed result path from its connection collection.");
        }
        finally
        {
            foreach (IDisposable layer in ProjectLayers(project)) layer.Dispose();
        }
    }

    private static string AddUnsavedProjectDraft(string sourceXml)
    {
        int rootStart = sourceXml.IndexOf("<Project", StringComparison.Ordinal);
        int close = sourceXml.LastIndexOf("</Project>", StringComparison.Ordinal);
        if (rootStart < 0 || close < rootStart) throw new InvalidDataException("The retained fixture Project XML shape changed.");
        string draft = sourceXml.Insert(rootStart, "<!--preserve R25 project comment--><?retain project-draft?>");
        close += "<!--preserve R25 project comment--><?retain project-draft?>".Length;
        draft = draft.Insert(close, "<R25UnknownExtension value=\"keep-this-xml\" />");
        _ = XDocument.Parse(draft, LoadOptions.PreserveWhitespace);
        return draft;
    }

    private static IEnumerable<IDisposable> ProjectLayers(Project project) => project.Plans.Cast<object>()
        .Concat(project.Geometries).Concat(project.Terrains).Concat(project.BoundaryConditions)
        .Concat(project.NValues).Concat(project.ClassificationLayers).Concat(project.Results)
        .OfType<IDisposable>();

    private static string RequiredDirectory(string variable)
    {
        string? value = Environment.GetEnvironmentVariable(variable);
        if (string.IsNullOrWhiteSpace(value) || !Directory.Exists(value))
            throw new DirectoryNotFoundException("The retained CPU Result fixture is required in " + variable + ".");
        return Path.GetFullPath(value);
    }

    private static string ResolveRelative(string root, string relative)
    {
        string path = Path.GetFullPath(Path.Combine(root, relative.Replace('/', Path.DirectorySeparatorChar)));
        string prefix = Path.GetFullPath(root) + Path.DirectorySeparatorChar;
        if (!path.StartsWith(prefix, OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal))
            throw new InvalidDataException("The fixture manifest path escapes its root.");
        return path;
    }

    private static void CopyDirectory(string source, string destination)
    {
        Directory.CreateDirectory(destination);
        foreach (string file in Directory.EnumerateFiles(source, "*", SearchOption.AllDirectories))
        {
            string target = Path.Combine(destination, Path.GetRelativePath(source, file));
            Directory.CreateDirectory(Path.GetDirectoryName(target)!);
            File.Copy(file, target, overwrite: false);
        }
    }

    private static string HashFile(string path)
    {
        using Stream stream = File.OpenRead(path);
        return Convert.ToHexString(SHA256.HashData(stream));
    }

    private static string Hash(ReadOnlySpan<byte> bytes) => Convert.ToHexString(SHA256.HashData(bytes));

    private static void Check(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }

    private static async Task Expect<T>(Func<Task> action) where T : Exception
    {
        try { await action(); }
        catch (T) { return; }
        throw new InvalidOperationException("Expected " + typeof(T).Name);
    }
}
