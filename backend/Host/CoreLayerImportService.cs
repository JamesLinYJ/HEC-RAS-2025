using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Xml.Linq;
using Ras.Layers;
using Utility.Files;

namespace Ras.Backend;

/// <summary>
/// Retains GenericImports.TryImportH5FileAsync's Geometry and Boundary
/// Condition dialog actions. Add Reference emits a typed, session-only source
/// capture for the map-tree transaction; Copy File copies the exact HDF bytes
/// into the corresponding project folder and never changes the map tree.
/// </summary>
public static class CoreLayerImportService
{
    private const int CopyBufferSize = 1024 * 1024;
    private const long MaximumProjectXmlBytes = 8L * 1024 * 1024;

    public static CoreLayerImportInspection Inspect(CoreLayerImportRequest request)
    {
        ArgumentNullException.ThrowIfNull(request);
        Project project = OpenSessionProject(request.ProjectPath, request.ProjectXml,
            request.ProjectSessionID, request.ProjectRevision, request.ProjectXmlRevision,
            request.CoreLayerContext);
        try
        {
            string sourcePath = ValidateSource(request.SourcePath, request.SourceRevision);
            (string kind, string name, string description) = ReadDialogLayer(sourcePath);
            var info = new FileInfo(sourcePath);
            return new(project.Filename, request.ProjectSessionID, request.ProjectRevision,
                request.ProjectXmlRevision, sourcePath, SourceFilePaths.Canonical(sourcePath),
                request.SourceRevision.ToUpperInvariant(), kind, name, description, info.Length,
                ["addReference", "copyFile"], ReferenceIsSessionOnly: true);
        }
        finally { DisposeProject(project); }
    }

    /// <summary>
    /// Re-reads one exact session reference after its source changed outside the
    /// application. This recovery route validates the full captured identity
    /// without opening every captured HDF; ordinary Project-rebuilding routes
    /// continue to validate all source hashes through ValidateContext.
    /// </summary>
    public static CoreLayerReferenceReloadReceipt ReloadReference(CoreLayerReferenceReloadRequest request)
    {
        ArgumentNullException.ThrowIfNull(request);
        ArgumentNullException.ThrowIfNull(request.CoreLayerContext);
        if (string.IsNullOrWhiteSpace(request.ProjectPath) || !Path.IsPathFullyQualified(request.ProjectPath) ||
            !Path.GetExtension(request.ProjectPath).Equals(".ras", StringComparison.OrdinalIgnoreCase))
            throw new ArgumentException("Open a saved HEC-RAS project before reloading a core-layer reference.");

        string projectPath = Path.GetFullPath(request.ProjectPath);
        string canonicalProject = SourceFilePaths.Canonical(projectPath);
        if (!File.Exists(canonicalProject))
            throw new FileNotFoundException("The current project file was not found.", projectPath);
        ValidateRevision(request.ProjectRevision);
        CoreLayerRequestContext context = request.CoreLayerContext;
        ValidateContextShape(context, canonicalProject);
        if (string.IsNullOrWhiteSpace(request.ProjectSessionID) ||
            !string.Equals(request.ProjectSessionID, context.ProjectSessionID, StringComparison.Ordinal) ||
            context.ProjectRevision is null ||
            !context.ProjectRevision.Equals(request.ProjectRevision, StringComparison.OrdinalIgnoreCase) ||
            !HashFile(canonicalProject, CancellationToken.None).Equals(request.ProjectRevision, StringComparison.OrdinalIgnoreCase))
            throw new SourceFileChangedException();

        if (string.IsNullOrWhiteSpace(request.TargetReferenceID)) throw new ArgumentException("Choose an exact core-layer reference to reload.");
        CoreLayerReferenceCapture[] matches = context.References.Where(reference =>
            string.Equals(reference.ReferenceID, request.TargetReferenceID, StringComparison.OrdinalIgnoreCase)).ToArray();
        if (matches.Length != 1) throw new SourceFileChangedException();
        CoreLayerReferenceCapture previous = matches[0];
        string sourcePath = Path.GetFullPath(previous.SourcePath);
        string canonicalSource = SourceFilePaths.Canonical(sourcePath);
        if (!SamePath(previous.CanonicalSourcePath, canonicalSource)) throw new SourceFileChangedException();

        string sourceRevisionBefore = HashFile(sourcePath, CancellationToken.None);
        (string kind, string name, _) = ReadDialogLayer(sourcePath);
        if (!string.Equals(kind, previous.Kind, StringComparison.Ordinal)) throw new SourceFileChangedException();
        string sourceRevisionAfter = HashFile(sourcePath, CancellationToken.None);
        if (!sourceRevisionBefore.Equals(sourceRevisionAfter, StringComparison.OrdinalIgnoreCase) ||
            !HashFile(canonicalProject, CancellationToken.None).Equals(request.ProjectRevision, StringComparison.OrdinalIgnoreCase))
            throw new SourceFileChangedException();

        string normalizedRevision = sourceRevisionAfter.ToUpperInvariant();
        var replacement = previous with
        {
            ReferenceID = ReferenceID(previous.ProjectSessionID, canonicalProject, previous.Kind,
                canonicalSource, normalizedRevision),
            SourceRevision = normalizedRevision,
            Name = name
        };
        CoreLayerReferenceCapture[] nextReferences = context.References.Select(reference =>
            string.Equals(reference.ReferenceID, previous.ReferenceID, StringComparison.OrdinalIgnoreCase)
                ? replacement : reference)
            .OrderBy(reference => reference.ReferenceID, StringComparer.Ordinal).ToArray();
        string nextIdentityToken = ContextIdentityToken(context.ProjectSessionID, canonicalProject,
            context.ProjectRevision, nextReferences);
        var nextContext = context with { References = nextReferences, IdentityToken = nextIdentityToken };
        ValidateContextShape(nextContext, canonicalProject);

        return new(canonicalProject, context.ProjectSessionID, request.ProjectRevision.ToUpperInvariant(),
            context.IdentityToken, previous.ReferenceID, replacement, nextContext);
    }

    public static CoreLayerImportReceipt Perform(CoreLayerImportRequest request) =>
        PerformAsync(request, CancellationToken.None).GetAwaiter().GetResult();

    internal static async Task<CoreLayerImportReceipt> PerformDuplexAsync(CoreLayerImportRequest request,
        Action<BackendOperationProgress>? report = null,
        BackendDuplexControlReader? duplexControls = null)
    {
        ArgumentNullException.ThrowIfNull(request);
        string action = NormalizeAction(request.Action);
        if (action == "addReference")
            return await Task.Run(() => PerformAddReference(request), CancellationToken.None).ConfigureAwait(false);

        using var cancellation = new CancellationTokenSource();
        Task? controlPump = duplexControls is null ? null : Task.Run(async () =>
        {
            try
            {
                await foreach (BackendDuplexControlFrame frame in duplexControls.ReadAllAsync(cancellation.Token)
                                   .ConfigureAwait(false))
                {
                    JsonElement control = frame.Control;
                    if (control.TryGetProperty("type", out JsonElement type) &&
                        string.Equals(type.GetString(), "cancel", StringComparison.Ordinal))
                    {
                        cancellation.Cancel();
                        return;
                    }
                }
            }
            catch (OperationCanceledException) when (cancellation.IsCancellationRequested) { }
            catch { cancellation.Cancel(); }
        }, CancellationToken.None);

        try
        {
            CoreLayerImportReceipt receipt = await Task.Run(
                () => CopyFile(request, cancellation.Token, report), CancellationToken.None).ConfigureAwait(false);
            return receipt;
        }
        finally
        {
            cancellation.Cancel();
            if (controlPump is not null)
            {
                try { await controlPump.ConfigureAwait(false); }
                catch (OperationCanceledException) when (cancellation.IsCancellationRequested) { }
            }
        }
    }

    /// <summary>
    /// Rebuilds the current source Project plus only the external layer
    /// captures explicitly carried by this project session. Paths are never
    /// discovered implicitly as project-owned assets.
    /// </summary>
    internal static Project OpenSessionProject(string projectPath, string? projectXml,
        string? projectSessionID, string? expectedProjectRevision, string? expectedProjectXmlRevision,
        CoreLayerRequestContext? coreLayerContext)
    {
        if (string.IsNullOrWhiteSpace(projectPath) || !Path.IsPathFullyQualified(projectPath) ||
            !Path.GetExtension(projectPath).Equals(".ras", StringComparison.OrdinalIgnoreCase))
            throw new ArgumentException("Open a saved HEC-RAS project before importing a model layer.");
        string fullPath = Path.GetFullPath(projectPath);
        string canonicalPath = SourceFilePaths.Canonical(fullPath);
        if (!File.Exists(canonicalPath)) throw new FileNotFoundException("The current project file was not found.", fullPath);
        if (expectedProjectRevision is { Length: > 0 } expected &&
            !HashFile(canonicalPath, CancellationToken.None).Equals(expected, StringComparison.OrdinalIgnoreCase))
            throw new SourceFileChangedException();
        if (coreLayerContext is not null)
        {
            if (!string.Equals(coreLayerContext.ProjectSessionID, projectSessionID, StringComparison.Ordinal) ||
                !SamePath(coreLayerContext.ProjectPath, canonicalPath))
                throw new SourceFileChangedException();
            ValidateContext(coreLayerContext, canonicalPath);
        }
        if ((projectXml is null) != (expectedProjectXmlRevision is null))
            throw new ArgumentException("The current project XML and its revision must be supplied together.");
        XElement? projectMetadata = null;
        if (projectXml is not null)
        {
            byte[] bytes = Encoding.UTF8.GetBytes(projectXml);
            if (bytes.LongLength > MaximumProjectXmlBytes)
                throw new NotSupportedException("The current project XML snapshot is too large.");
            if (!HashBytes(bytes).Equals(expectedProjectXmlRevision, StringComparison.OrdinalIgnoreCase))
                throw new SourceFileChangedException();
            projectMetadata = XElement.Parse(projectXml);
            if (projectMetadata.Name != "Project")
                throw new InvalidDataException("The current project XML snapshot has an invalid Project root element.");
        }
        return OpenProjectWithMetadata(fullPath, projectMetadata, coreLayerContext);
    }

    /// <summary>Opens a project using an explicitly captured session context.</summary>
    internal static Project OpenProject(string projectPath, string? projectXml,
        CoreLayerRequestContext? coreLayerContext, Func<string, bool>? sourceFileReader = null)
    {
        XElement? projectMetadata = string.IsNullOrWhiteSpace(projectXml) ? null : XElement.Parse(projectXml);
        return OpenProjectWithMetadata(projectPath, projectMetadata, coreLayerContext, sourceFileReader);
    }

    /// <summary>Opens a project with parsed metadata and the exact optional session capture.</summary>
    internal static Project OpenProjectWithMetadata(string projectPath, XElement? projectMetadata,
        CoreLayerRequestContext? coreLayerContext, Func<string, bool>? sourceFileReader = null)
    {
        if (string.IsNullOrWhiteSpace(projectPath) || !Path.IsPathFullyQualified(projectPath))
            throw new ArgumentException("The current project path must be absolute.");
        string fullPath = Path.GetFullPath(projectPath);
        string canonicalPath = SourceFilePaths.Canonical(fullPath);
        if (!File.Exists(canonicalPath))
            throw new FileNotFoundException("The current project file was not found.", fullPath);
        if (coreLayerContext is not null) ValidateContext(coreLayerContext, canonicalPath);

        var project = new Project(fullPath, sourceFileReader);
        try
        {
            if (projectMetadata is not null)
            {
                if (projectMetadata.Name != "Project")
                    throw new InvalidDataException("The current project XML snapshot has an invalid Project root element.");
                project.ApplyEditorMetadata(projectMetadata);
            }
            if (coreLayerContext is not null)
                AttachExternalReferences(project, fullPath, coreLayerContext);
            return project;
        }
        catch
        {
            DisposeProject(project);
            throw;
        }
    }

    /// <summary>Rebases a committed transaction capture onto its resulting source revisions.</summary>
    internal static CoreLayerRequestContext? RebaseContext(CoreLayerRequestContext? context,
        string? projectRevision, string changedSourcePath, string changedSourceRevision)
    {
        if (context is null) return null;
        if (projectRevision is not null) ValidateRevision(projectRevision);
        ValidateRevision(changedSourceRevision);
        string canonicalSource = SourceFilePaths.Canonical(changedSourcePath);
        string revision = changedSourceRevision.ToUpperInvariant();
        bool changedReference = false;
        CoreLayerReferenceCapture[] references = context.References.Select(capture =>
        {
            if (!SamePath(capture.CanonicalSourcePath, canonicalSource)) return capture;
            if (changedReference) throw new SourceFileChangedException();
            changedReference = true;
            string sourcePath = ValidateSource(capture.SourcePath, revision);
            (string kind, string name, _) = ReadDialogLayer(sourcePath);
            if (!string.Equals(kind, capture.Kind, StringComparison.Ordinal))
                throw new SourceFileChangedException();
            // Read the committed HDF identity, not the old display capture. The
            // source name may have changed as part of this same save transaction.
            string referenceID = ReferenceID(capture.ProjectSessionID, context.ProjectPath,
                capture.Kind, canonicalSource, revision);
            return capture with { ReferenceID = referenceID, SourceRevision = revision, Name = name };
        }).ToArray();
        string? normalizedProjectRevision = projectRevision?.ToUpperInvariant();
        string identity = ContextIdentityToken(context.ProjectSessionID, context.ProjectPath,
            normalizedProjectRevision, references);
        var rebased = context with { ProjectRevision = normalizedProjectRevision, References = references,
            IdentityToken = identity };
        if (changedReference) ValidateContext(rebased, context.ProjectPath);
        return rebased;
    }

    internal static void ValidateContext(CoreLayerRequestContext context, string projectPath)
    {
        ValidateContextShape(context, projectPath);
        foreach (CoreLayerReferenceCapture capture in context.References)
        {
            string sourcePath = ValidateSource(capture.SourcePath, capture.SourceRevision);
            if (!SamePath(capture.CanonicalSourcePath, SourceFilePaths.Canonical(sourcePath)) ||
                !Project.IsValidCoreFile(sourcePath, out CoreFileType sourceType) ||
                !string.Equals(Kind(sourceType), capture.Kind, StringComparison.Ordinal))
                throw new SourceFileChangedException();
        }
    }

    /// <summary>Validates the explicit capture structure and token without touching reference files.</summary>
    internal static void ValidateContextShape(CoreLayerRequestContext context, string projectPath)
    {
        ArgumentNullException.ThrowIfNull(context);
        if (string.IsNullOrWhiteSpace(context.ProjectSessionID) ||
            string.IsNullOrWhiteSpace(context.ProjectPath) || !Path.IsPathFullyQualified(context.ProjectPath) ||
            !string.Equals(SourceFilePaths.Canonical(context.ProjectPath), SourceFilePaths.Canonical(projectPath),
                OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal))
            throw new SourceFileChangedException();
        if (context.ProjectRevision is { Length: > 0 } revision)
        {
            ValidateRevision(revision);
            if (!HashFile(SourceFilePaths.Canonical(projectPath), CancellationToken.None)
                    .Equals(revision, StringComparison.OrdinalIgnoreCase))
                throw new SourceFileChangedException();
        }
        if (context.References is null) throw new ArgumentException("The core-layer reference capture is missing.");
        var uniqueIDs = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (CoreLayerReferenceCapture capture in context.References)
        {
            if (capture is null || !capture.SessionOnly ||
                !string.Equals(capture.ProjectSessionID, context.ProjectSessionID, StringComparison.Ordinal) ||
                !SamePath(capture.ProjectPath, context.ProjectPath) ||
                !uniqueIDs.Add(capture.ReferenceID) || string.IsNullOrWhiteSpace(capture.ReferenceID) ||
                string.IsNullOrWhiteSpace(capture.Kind) || capture.Kind is not ("geometry" or "boundaryCondition") ||
                string.IsNullOrWhiteSpace(capture.SourcePath) || !Path.IsPathFullyQualified(capture.SourcePath) ||
                string.IsNullOrWhiteSpace(capture.CanonicalSourcePath) || !Path.IsPathFullyQualified(capture.CanonicalSourcePath) ||
                string.IsNullOrWhiteSpace(capture.SourceRevision) || string.IsNullOrWhiteSpace(capture.Name) ||
                capture.Name.IndexOfAny(['\r', '\n', '\t']) >= 0)
                throw new SourceFileChangedException();
            ValidateRevision(capture.SourceRevision);
            // The shape/token check must not resolve every stored SourcePath:
            // an unrelated session reference may have a symlink retargeted and
            // must still be removable or independently reloadable. The normal
            // ValidateContext path below rechecks all current filesystem aliases;
            // ReloadReference checks the selected target's physical path itself.
            if (!ReferenceID(capture.ProjectSessionID, context.ProjectPath, capture.Kind,
                    capture.CanonicalSourcePath, capture.SourceRevision)
                .Equals(capture.ReferenceID, StringComparison.OrdinalIgnoreCase))
                throw new SourceFileChangedException();
        }
        string expectedIdentity = ContextIdentityToken(context.ProjectSessionID, context.ProjectPath,
            context.ProjectRevision, context.References);
        if (!expectedIdentity.Equals(context.IdentityToken, StringComparison.OrdinalIgnoreCase))
            throw new SourceFileChangedException();
    }

    internal static string ContextIdentityToken(string projectSessionID, string projectPath,
        string? projectRevision, CoreLayerReferenceCapture[] references)
    {
        var parts = new List<string>
        {
            "core-layer-context-v1",
            projectSessionID.ToLowerInvariant(),
            SourceFilePaths.Canonical(projectPath),
            projectRevision?.ToUpperInvariant() ?? ""
        };
        parts.AddRange(references.OrderBy(item => item.ReferenceID, StringComparer.Ordinal)
            .Select(item => string.Join("\t", item.ReferenceID.ToLowerInvariant(), item.Kind,
                SourceFilePaths.Canonical(item.CanonicalSourcePath), item.SourceRevision.ToUpperInvariant(), item.Name)));
        return HashBytes(Encoding.UTF8.GetBytes(string.Join("\n", parts))).ToLowerInvariant();
    }

    private static void ValidateRevision(string revision)
    {
        if (revision.Length != 64 || revision.Any(character => !Uri.IsHexDigit(character)))
            throw new ArgumentException("The project revision is invalid.");
    }

    private static string HashBytes(byte[] bytes) => Convert.ToHexString(SHA256.HashData(bytes));

    internal static void AttachExternalReferences(Project project, string projectPath,
        string? projectSessionID, CoreLayerReferenceCapture[]? externalReferences)
    {
        if (externalReferences is not { Length: > 0 }) return;
        if (string.IsNullOrWhiteSpace(projectSessionID))
            throw new ArgumentException("An external core-layer reference requires the owning project session.");

        string canonicalProject = SourceFilePaths.Canonical(projectPath);
        var prepared = new List<CoreLayerBase>();
        try
        {
            foreach (CoreLayerReferenceCapture capture in externalReferences)
            {
                if (capture is null || !capture.SessionOnly ||
                    !string.Equals(capture.ProjectSessionID, projectSessionID, StringComparison.OrdinalIgnoreCase) ||
                    !SamePath(capture.ProjectPath, canonicalProject))
                    throw new SourceFileChangedException();

                string sourcePath = ValidateSource(capture.SourcePath, capture.SourceRevision);
                string canonicalSource = SourceFilePaths.Canonical(sourcePath);
                if (!SamePath(capture.CanonicalSourcePath, canonicalSource) ||
                    !ReferenceID(capture.ProjectSessionID, canonicalProject, capture.Kind,
                        canonicalSource, capture.SourceRevision).Equals(capture.ReferenceID, StringComparison.OrdinalIgnoreCase))
                    throw new SourceFileChangedException();

                if (!Project.IsValidCoreFile(sourcePath, out CoreFileType sourceType) ||
                    !string.Equals(Kind(sourceType), capture.Kind, StringComparison.Ordinal))
                    throw new SourceFileChangedException();

                switch (capture.Kind)
                {
                    case "geometry":
                    {
                        Geometry[] existing = project.Geometries.Where(item => SamePath(item.Filename, sourcePath)).ToArray();
                        if (existing.Length > 1) throw new SourceFileChangedException();
                        if (existing.Length == 1)
                        {
                            if (!string.Equals(existing[0].Name, capture.Name, StringComparison.Ordinal))
                                throw new SourceFileChangedException();
                            break;
                        }
                        var layer = new Geometry(sourcePath);
                        if (!string.Equals(layer.Name, capture.Name, StringComparison.Ordinal))
                        {
                            layer.Dispose();
                            throw new SourceFileChangedException();
                        }
                        prepared.Add(layer);
                        break;
                    }
                    case "boundaryCondition":
                    {
                        BoundaryCondition[] existing = project.BoundaryConditions
                            .Where(item => SamePath(item.Filename, sourcePath)).ToArray();
                        if (existing.Length > 1) throw new SourceFileChangedException();
                        if (existing.Length == 1)
                        {
                            if (!string.Equals(existing[0].Name, capture.Name, StringComparison.Ordinal))
                                throw new SourceFileChangedException();
                            break;
                        }
                        var layer = new BoundaryCondition(sourcePath);
                        if (!string.Equals(layer.Name, capture.Name, StringComparison.Ordinal))
                        {
                            layer.Dispose();
                            throw new SourceFileChangedException();
                        }
                        prepared.Add(layer);
                        break;
                    }
                    default:
                        throw new NotSupportedException("Only retained Geometry and Boundary Condition references are supported by this dialog.");
                }
            }

            foreach (CoreLayerBase layer in prepared)
            {
                switch (layer)
                {
                    case Geometry geometry: project.AddGeometry(geometry); break;
                    case BoundaryCondition boundary: project.AddBoundaryCondition(boundary); break;
                    default: throw new InvalidOperationException("An imported core-layer type was not expected.");
                }
            }
            prepared.Clear();
        }
        finally
        {
            foreach (CoreLayerBase layer in prepared) layer.Dispose();
        }
    }

    internal static void AttachExternalReferences(Project project, string projectPath,
        CoreLayerRequestContext coreLayerContext)
    {
        ValidateContext(coreLayerContext, projectPath);
        AttachExternalReferences(project, projectPath, coreLayerContext.ProjectSessionID,
            coreLayerContext.References);
    }

    internal static string ReferenceID(string projectSessionID, string projectPath, string kind,
        string canonicalSourcePath, string sourceRevision)
    {
        string material = string.Join("\n", projectSessionID.ToLowerInvariant(),
            SourceFilePaths.Canonical(projectPath), kind, SourceFilePaths.Canonical(canonicalSourcePath),
            sourceRevision.ToUpperInvariant());
        return HashBytes(Encoding.UTF8.GetBytes(material)).ToLowerInvariant();
    }

    private static async Task<CoreLayerImportReceipt> PerformAsync(CoreLayerImportRequest request,
        CancellationToken cancellationToken)
    {
        string action = NormalizeAction(request.Action);
        if (action == "addReference") return PerformAddReference(request);
        return await Task.Run(() => CopyFile(request, cancellationToken, null), CancellationToken.None)
            .ConfigureAwait(false);
    }

    private static CoreLayerImportReceipt PerformAddReference(CoreLayerImportRequest request)
    {
        Project project = OpenSessionProject(request.ProjectPath, request.ProjectXml,
            request.ProjectSessionID, request.ProjectRevision, request.ProjectXmlRevision,
            request.CoreLayerContext);
        try
        {
            string sourcePath = ValidateSource(request.SourcePath, request.SourceRevision);
            (string kind, string name, _) = ReadDialogLayer(sourcePath);
            string canonicalProject = SourceFilePaths.Canonical(project.Filename);
            string canonicalSource = SourceFilePaths.Canonical(sourcePath);
            var reference = new CoreLayerReferenceCapture(
                ReferenceID(request.ProjectSessionID, canonicalProject, kind, canonicalSource, request.SourceRevision),
                request.ProjectSessionID, canonicalProject, kind, sourcePath, canonicalSource,
                request.SourceRevision.ToUpperInvariant(), name);
            // No copy or project/map write occurs here. The caller must submit this
            // capture to the exact active map-tree action before claiming success.
            return new("addReference", canonicalProject, request.ProjectSessionID, request.ProjectRevision,
                request.ProjectXmlRevision, sourcePath, canonicalSource, request.SourceRevision.ToUpperInvariant(),
                kind, name, reference, null, null, ReferenceIsSessionOnly: true);
        }
        finally { DisposeProject(project); }
    }

    private static CoreLayerImportReceipt CopyFile(CoreLayerImportRequest request,
        CancellationToken cancellationToken, Action<BackendOperationProgress>? report)
    {
        cancellationToken.ThrowIfCancellationRequested();
        Project project = OpenSessionProject(request.ProjectPath, request.ProjectXml,
            request.ProjectSessionID, request.ProjectRevision, request.ProjectXmlRevision,
            request.CoreLayerContext);
        bool completed = false;
        try
        {
        string sourcePath = ValidateSource(request.SourcePath, request.SourceRevision);
        (string kind, string name, _) = ReadDialogLayer(sourcePath);
        string targetDirectory = kind == "geometry" ? project.GeometriesDirectory : project.BoundaryConditionDirectory;
        Directory.CreateDirectory(targetDirectory);
        string initialCandidate = FileHelpers.UniqueFilename(Path.Combine(targetDirectory, Path.GetFileName(sourcePath)));
        string partialPath = Path.Combine(targetDirectory, ".core-layer-import-" + Guid.NewGuid().ToString("N") + ".partial");
        try
        {
            using (var input = new FileStream(sourcePath, FileMode.Open, FileAccess.Read, FileShare.Read,
                       CopyBufferSize, FileOptions.SequentialScan))
            using (var output = new FileStream(partialPath, FileMode.CreateNew, FileAccess.Write, FileShare.None,
                       CopyBufferSize, FileOptions.SequentialScan))
            {
                byte[] buffer = new byte[CopyBufferSize];
                long copied = 0;
                int read;
                while ((read = input.Read(buffer, 0, buffer.Length)) > 0)
                {
                    cancellationToken.ThrowIfCancellationRequested();
                    output.Write(buffer, 0, read);
                    copied += read;
                    if (copied % (16L * CopyBufferSize) < read)
                        report?.Invoke(new BackendOperationProgress(Message: "Copying model layer…"));
                }
                output.Flush(flushToDisk: true);
            }

            cancellationToken.ThrowIfCancellationRequested();
            if (!HashFile(sourcePath, cancellationToken).Equals(request.SourceRevision, StringComparison.OrdinalIgnoreCase) ||
                !HashFile(partialPath, cancellationToken).Equals(request.SourceRevision, StringComparison.OrdinalIgnoreCase))
                throw new SourceFileChangedException();

            string targetPath = initialCandidate;
            while (true)
            {
                cancellationToken.ThrowIfCancellationRequested();
                try
                {
                    if (!HashFile(project.Filename, cancellationToken).Equals(request.ProjectRevision, StringComparison.OrdinalIgnoreCase))
                        throw new SourceFileChangedException();
                    if (request.CoreLayerContext is not null)
                        ValidateContext(request.CoreLayerContext, project.Filename);
                    if (!HashFile(sourcePath, cancellationToken).Equals(request.SourceRevision, StringComparison.OrdinalIgnoreCase))
                        throw new SourceFileChangedException();
                    var receipt = new CoreLayerImportReceipt("copyFile", SourceFilePaths.Canonical(project.Filename),
                        request.ProjectSessionID, request.ProjectRevision, request.ProjectXmlRevision, sourcePath,
                        SourceFilePaths.Canonical(sourcePath), request.SourceRevision.ToUpperInvariant(), kind, name,
                        null, Path.GetFullPath(targetPath), request.SourceRevision.ToUpperInvariant(), ReferenceIsSessionOnly: false);
                    cancellationToken.ThrowIfCancellationRequested();
                    File.Move(partialPath, targetPath, overwrite: false);
                    // The atomic no-clobber rename commits the already verified bytes.
                    // Cancellation and cleanup after this point must preserve the receipt.
                    completed = true;
                    return receipt;
                }
                catch (IOException) when (File.Exists(targetPath) || Directory.Exists(targetPath))
                {
                    targetPath = FileHelpers.UniqueFilename(targetPath);
                }
            }

        }
        finally
        {
            try { if (File.Exists(partialPath)) File.Delete(partialPath); }
            catch (Exception error) when (completed) { System.Diagnostics.Trace.TraceWarning("Core layer copy cleanup failed after commit: {0}", error.Message); }
        }
        }
        finally
        {
            try { DisposeProject(project); }
            catch (Exception error) when (completed) { System.Diagnostics.Trace.TraceWarning("Core layer copy release failed after commit: {0}", error.Message); }
        }
    }

    private static string NormalizeAction(string? action) => action?.Trim() switch
    {
        "addReference" => "addReference",
        "copyFile" => "copyFile",
        _ => throw new NotSupportedException("Choose Add Reference or Copy File.")
    };

    private static string ValidateSource(string path, string expectedRevision)
    {
        if (string.IsNullOrWhiteSpace(path) || !Path.IsPathFullyQualified(path))
            throw new ArgumentException("Choose an absolute path to a core model file.");
        if (string.IsNullOrWhiteSpace(expectedRevision) || expectedRevision.Length != 64 ||
            expectedRevision.Any(character => !Uri.IsHexDigit(character)))
            throw new ArgumentException("The selected source file revision is required.");
        string fullPath = Path.GetFullPath(path);
        if (!File.Exists(fullPath)) throw new FileNotFoundException("The selected model file was not found.", fullPath);
        if (!HashFile(fullPath, CancellationToken.None).Equals(expectedRevision, StringComparison.OrdinalIgnoreCase))
            throw new SourceFileChangedException();
        if (!Project.IsValidCoreFile(fullPath, out CoreFileType type) ||
            type is not (CoreFileType.Geometry or CoreFileType.BoundaryCondition))
            throw new InvalidDataException("The selected file is not a supported Geometry or Boundary Condition core layer.");
        return fullPath;
    }

    private static (string Kind, string Name, string Description) ReadDialogLayer(string path)
    {
        if (!Project.IsValidCoreFile(path, out CoreFileType type))
            throw new InvalidDataException("The selected file is not a valid HEC-RAS core model layer.");
        CoreLayerBase layer = type switch
        {
            CoreFileType.Geometry => new Geometry(path),
            CoreFileType.BoundaryCondition => new BoundaryCondition(path),
            _ => throw new InvalidDataException("The Core Layer Import dialog accepts Geometry and Boundary Condition files.")
        };
        try
        {
            if (layer.HasLoadErrors)
                throw new InvalidDataException("The selected core layer could not be read by the retained model loader.");
            return (Kind(type), layer.Name, layer.Description ?? "");
        }
        finally { layer.Dispose(); }
    }

    private static string Kind(CoreFileType type) => type switch
    {
        CoreFileType.Geometry => "geometry",
        CoreFileType.BoundaryCondition => "boundaryCondition",
        _ => throw new NotSupportedException("This importer only retains the CoreLayerImportDialog types.")
    };

    private static void DisposeProject(Project project)
    {
        foreach (CoreLayerBase layer in project.Plans.Cast<CoreLayerBase>().Concat(project.Geometries)
                     .Concat(project.Terrains).Concat(project.BoundaryConditions).Concat(project.NValues)
                     .Concat(project.ClassificationLayers)) layer.Dispose();
        foreach (Result result in project.Results) result.Dispose();
    }

    private static string HashFile(string path, CancellationToken cancellationToken)
    {
        using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read,
            CopyBufferSize, FileOptions.SequentialScan);
        using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        byte[] buffer = new byte[CopyBufferSize];
        int read;
        while ((read = stream.Read(buffer, 0, buffer.Length)) > 0)
        {
            cancellationToken.ThrowIfCancellationRequested();
            hash.AppendData(buffer, 0, read);
        }
        return Convert.ToHexString(hash.GetHashAndReset());
    }

    private static bool SamePath(string first, string second) =>
        string.Equals(SourceFilePaths.Canonical(first), SourceFilePaths.Canonical(second),
            OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal);
}
