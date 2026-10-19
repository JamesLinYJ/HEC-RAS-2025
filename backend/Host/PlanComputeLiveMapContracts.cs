namespace Ras.Backend;

/// <summary>
/// A map target captured from one native map state. The project/map/source
/// owner fields are echoed on frames; the Result revision intentionally does
/// not exist while the retained writer is active.
/// </summary>
public sealed record PlanComputeLiveMapRenderTarget(
    string TargetID,
    string ProjectSessionID,
    string OperationOwnerToken,
    string OperationContextID,
    string RunID,
    string ProjectPath,
    string ProjectRevision,
    string ProjectXmlFingerprint,
    string PlanPath,
    string PlanRevision,
    MapTreeRequest Map,
    string ContextToken,
    string NodeID,
    CatalogTreeNodeLocator Node,
    int SelectionIndex,
    string SelectionMode,
    string? SelectedResultPath,
    int ProfileIndex,
    string? ProfileTime,
    string OutputBlockName,
    string SelectedMapType,
    RasterMapViewExtent Viewport,
    bool CaptureVelocityParticles = false,
    string? ProfileName = null);

public sealed record PlanComputeLiveMapTargetUpdate(PlanComputeLiveMapRenderTarget[] Targets);

public sealed record PlanComputeLiveMapRenderFrame(
    string TargetID,
    string ProjectSessionID,
    string OperationOwnerToken,
    string OperationContextID,
    string RunID,
    string ResultPath,
    string OutputBlockName,
    string ContextToken,
    string MapID,
    string NodeID,
    int SelectionIndex,
    ulong TargetSequence,
    int ProfileIndex,
    string ProfileName,
    string Time,
    string MapType,
    string TerrainPath,
    string TerrainRevision,
    string Units,
    int Width,
    int Height,
    byte[] Rgba,
    double MinX,
    double MinY,
    double MaxX,
    double MaxY,
    float NoDataValue,
    MapResultRenderLegendStop[] LegendStops);

/// <summary>
/// Ephemeral writer-owned velocity field from the retained compute Result. It
/// deliberately carries no SHA: the output file is still being written.
/// Velocity arrays are interleaved little-endian float32 triples in row-major
/// raster order (Vx, Vy, magnitude).
/// </summary>
public sealed record PlanComputeLiveVelocityFrame(
    string TargetID,
    string ProjectSessionID,
    string OperationOwnerToken,
    string OperationContextID,
    string RunID,
    string ResultPath,
    string OutputBlockName,
    string ContextToken,
    string MapID,
    string NodeID,
    int SelectionIndex,
    ulong TargetSequence,
    int ProfileIndex,
    string ProfileName,
    string Time,
    string MapType,
    int Width,
    int Height,
    double CellSize,
    double MinX,
    double MinY,
    double MaxX,
    double MaxY,
    float NoDataValue,
    byte[] InterleavedVelocity);

/// <summary>A target-scoped source limitation for an ephemeral velocity field.</summary>
public sealed record PlanComputeLiveVelocityUnavailable(
    string TargetID,
    string ProjectSessionID,
    string OperationOwnerToken,
    string OperationContextID,
    string RunID,
    string ResultPath,
    string OutputBlockName,
    string ContextToken,
    string MapID,
    string NodeID,
    int SelectionIndex,
    ulong TargetSequence,
    string Message);

internal sealed class PlanComputeLiveMapTargetRegistry
{
    internal const int MaximumTargets = 64;
    internal const string RejectedTargetUpdateMessage =
        "Live map frames paused because the target update was rejected; existing requests were cleared.";

    private readonly object gate = new();
    private ulong sequence;
    private PlanComputeLiveMapRenderTarget[] targets = [];

    public PlanComputeLiveMapTargetUpdateResult Replace(ulong nextSequence,
        PlanComputeLiveMapRenderTarget[]? next)
    {
        lock (gate)
        {
            if (nextSequence == 0 || nextSequence <= sequence)
                return new(PlanComputeLiveMapTargetUpdateStatus.Stale, null);

            if (next is null)
            {
                sequence = nextSequence;
                targets = [];
                return new(PlanComputeLiveMapTargetUpdateStatus.RejectedAndCleared,
                    RejectedTargetUpdateMessage);
            }
            string? rejection = Validate(next);
            sequence = nextSequence;
            if (rejection is not null)
            {
                // Never leave the previous viewport subscriptions alive after
                // a newer request was rejected. Otherwise later source steps
                // could continue publishing a raster the user no longer owns.
                targets = [];
                return new(PlanComputeLiveMapTargetUpdateStatus.RejectedAndCleared,
                    RejectedTargetUpdateMessage);
            }
            targets = next.ToArray();
            return new(PlanComputeLiveMapTargetUpdateStatus.Applied, null);
        }
    }

    public PlanComputeLiveMapTargetUpdateResult Reject(ulong nextSequence)
    {
        lock (gate)
        {
            if (nextSequence == 0 || nextSequence <= sequence)
                return new(PlanComputeLiveMapTargetUpdateStatus.Stale, null);
            sequence = nextSequence;
            targets = [];
            return new(PlanComputeLiveMapTargetUpdateStatus.RejectedAndCleared,
                RejectedTargetUpdateMessage);
        }
    }

    public (ulong Sequence, PlanComputeLiveMapRenderTarget[] Targets) Snapshot()
    {
        lock (gate) return (sequence, targets.ToArray());
    }

    public void Clear()
    {
        lock (gate) targets = [];
    }

    private static string? Validate(PlanComputeLiveMapRenderTarget[] items)
    {
        if (items.Length > MaximumTargets) return "The target array exceeds its bounded capacity.";
        if (items.Any(target => target is null)) return "A target entry is null.";
        if (items.Select(target => target.TargetID).Distinct(StringComparer.Ordinal).Count() != items.Length)
            return "Target identifiers are duplicated.";

        foreach (PlanComputeLiveMapRenderTarget target in items)
        {
            if (string.IsNullOrWhiteSpace(target.TargetID) || string.IsNullOrWhiteSpace(target.RunID) ||
                string.IsNullOrWhiteSpace(target.ProjectSessionID) ||
                string.IsNullOrWhiteSpace(target.OperationOwnerToken) ||
                string.IsNullOrWhiteSpace(target.OperationContextID) ||
                string.IsNullOrWhiteSpace(target.ContextToken) ||
                string.IsNullOrWhiteSpace(target.ProjectPath) ||
                string.IsNullOrWhiteSpace(target.PlanPath) ||
                string.IsNullOrWhiteSpace(target.OutputBlockName) ||
                string.IsNullOrWhiteSpace(target.SelectedMapType))
                return "A target is missing required owner or source identity.";
            if (!Guid.TryParse(target.ProjectSessionID, out _) ||
                !Guid.TryParse(target.Map?.MapID, out _) || target.Map is null)
                return "A target has an invalid project-session or map identity.";
            if (target.Node is null || target.Node.NodeType != "MultiResult" ||
                string.IsNullOrWhiteSpace(target.Node.AssetID) ||
                target.SelectionIndex is < 0 or >= 32 || target.ProfileIndex < 0)
                return "A target has an invalid MultiResult selection.";
            if (target.SelectionMode is not ("Latest" or "Explicit") ||
                (target.SelectionMode == "Explicit" && string.IsNullOrWhiteSpace(target.SelectedResultPath)) ||
                string.IsNullOrWhiteSpace(target.ProfileTime))
                return "A target has an unsupported selection mode or profile identity.";
            if (target.CaptureVelocityParticles &&
                (target.SelectionIndex != 0 ||
                 !string.Equals(target.SelectedMapType, "Velocity", StringComparison.Ordinal) ||
                 string.IsNullOrWhiteSpace(target.ProfileName)))
                return "A live velocity target must identify the selected slot-zero Velocity profile.";
            RasterMapViewExtent viewport = target.Viewport;
            if (!double.IsFinite(viewport.MinX) || !double.IsFinite(viewport.MinY) ||
                !double.IsFinite(viewport.MaxX) || !double.IsFinite(viewport.MaxY) ||
                viewport.MinX >= viewport.MaxX || viewport.MinY >= viewport.MaxY ||
                viewport.PixelWidth <= 0 || viewport.PixelHeight <= 0)
                return "A target has an invalid viewport.";
        }
        return null;
    }
}

internal enum PlanComputeLiveMapTargetUpdateStatus
{
    Applied,
    Stale,
    RejectedAndCleared
}

internal sealed record PlanComputeLiveMapTargetUpdateResult(
    PlanComputeLiveMapTargetUpdateStatus Status, string? Message);
