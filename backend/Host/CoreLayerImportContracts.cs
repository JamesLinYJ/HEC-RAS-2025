namespace Ras.Backend;

/// <summary>
/// An explicitly authorized, session-scoped external core-layer reference.
/// The original project format does not persist this path; callers must carry
/// the capture on every backend request that rebuilds the current Project.
/// </summary>
public sealed record CoreLayerReferenceCapture(
    string ReferenceID,
    string ProjectSessionID,
    string ProjectPath,
    string Kind,
    string SourcePath,
    string CanonicalSourcePath,
    string SourceRevision,
    string Name,
    bool SessionOnly = true);

/// <summary>
/// Immutable capability context carried by every request that rebuilds the
/// current in-memory Project. The identity token prevents capture fields from
/// being mixed across maps or project sessions; it is not a persisted owner
/// marker and must be supplied explicitly by the caller.
/// </summary>
public sealed record CoreLayerRequestContext(
    string ProjectSessionID,
    string ProjectPath,
    string? ProjectRevision,
    CoreLayerReferenceCapture[] References,
    string IdentityToken);

public sealed record CoreLayerImportRequest(
    string ProjectPath,
    string ProjectSessionID,
    string ProjectRevision,
    string ProjectXml,
    string ProjectXmlRevision,
    string SourcePath,
    string SourceRevision,
    string? Action = null,
    CoreLayerRequestContext? CoreLayerContext = null);

public sealed record CoreLayerImportInspection(
    string ProjectPath,
    string ProjectSessionID,
    string ProjectRevision,
    string ProjectXmlRevision,
    string SourcePath,
    string CanonicalSourcePath,
    string SourceRevision,
    string Kind,
    string Name,
    string Description,
    long FileSize,
    string[] AvailableActions,
    bool ReferenceIsSessionOnly);

public sealed record CoreLayerImportReceipt(
    string Action,
    string ProjectPath,
    string ProjectSessionID,
    string ProjectRevision,
    string ProjectXmlRevision,
    string SourcePath,
    string CanonicalSourcePath,
    string SourceRevision,
    string Kind,
    string Name,
    CoreLayerReferenceCapture? Reference,
    string? ImportedAssetPath,
    string? ImportedAssetRevision,
    bool ReferenceIsSessionOnly);

/// <summary>
/// Requests an explicit recovery read for one existing session-only reference.
/// The target source path is taken from that exact captured reference; callers
/// cannot redirect a reload to a different file.
/// </summary>
public sealed record CoreLayerReferenceReloadRequest(
    string ProjectPath,
    string ProjectSessionID,
    string ProjectRevision,
    CoreLayerRequestContext CoreLayerContext,
    string TargetReferenceID);

public sealed record CoreLayerReferenceReloadReceipt(
    string ProjectPath,
    string ProjectSessionID,
    string ProjectRevision,
    string PreviousContextIdentityToken,
    string PreviousReferenceID,
    CoreLayerReferenceCapture Reference,
    CoreLayerRequestContext NextContext);
