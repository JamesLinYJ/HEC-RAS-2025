namespace Ras.Backend;

/// <summary>
/// Requests one map-scoped Result/MultiResult source node at a native map
/// profile index. MultiResult profile indices belong to the first selected
/// Result; child Results are matched to that timestamp with the retained
/// KeyedProfileState tolerance.
/// </summary>
public sealed record MapResultRenderRequest(
    MapTreeRequest Map,
    MapResultSelectionOverride[] SelectionOverrides,
    string ContextToken,
    CatalogTreeNodeLocator Node,
    int? ProfileIndex = null,
    RasterMapViewExtent? Viewport = null,
    int[]? BlockedSelectionIndices = null,
    MapResultRenderLiveKeyframeAnchor? LiveKeyframeAnchor = null,
    MapResultRenderOptionOverride[]? RenderOptions = null);

/// <summary>
/// Temporary per-map rendering preferences for one exact selected Result
/// slot. These settings are intentionally not written to the project's .vis.
/// </summary>
public sealed record MapResultRenderOptionOverride(
    int SelectionIndex,
    string ResultPath,
    string Revision,
    string VelocityDisplay,
    bool MapDiagnostics,
    bool ForceRecomputeMapPoints);

/// <summary>
/// An exact compute-callback profile identity used only while the callback
/// Result is protected by the request's compute read lease. This is a
/// temporary timestamp keyframe, never a stable Result revision or raster.
/// </summary>
public sealed record MapResultRenderLiveKeyframeAnchor(
    CatalogTreeNodeLocator Node,
    int SelectionIndex,
    string RunID,
    string ResultPath,
    string OutputBlockName,
    int ProfileCount,
    int ProfileIndex,
    string ProfileName,
    string Time);

public sealed record MapResultRenderStep(int Id, string Label, string Time);

public sealed record MapResultRenderLegendStop(string Color, double Value);

public sealed record MapResultRenderSourceStatus(
    string ResultPath,
    string Revision,
    string ResultName,
    int[] SelectionIndices,
    string? TerrainPath,
    string? TerrainRevision,
    bool Available,
    int? ProfileIndex,
    string? UnavailableReason);

public sealed record MapResultRenderLayerPayload(
    string Id,
    string SourceID,
    string SourceMapID,
    string ResultPath,
    string Revision,
    string ResultName,
    string MapType,
    string TerrainPath,
    string TerrainRevision,
    int ProfileIndex,
    string ProfileName,
    string Time,
    string Units,
    int Width,
    int Height,
    byte[] Rgba,
    double MinX,
    double MinY,
    double MaxX,
    double MaxY,
    float NoDataValue,
    MapResultRenderLegendStop[] LegendStops,
    int[]? SelectionIndices = null,
    string VelocityDisplay = "Magnitude",
    bool MapDiagnostics = false,
    bool ForceRecomputeMapPoints = false,
    MapResultRenderDiagnosticPoint[]? DiagnosticLabels = null);

public sealed record MapResultRenderDiagnosticPoint(string Text, double X, double Y);

public sealed record MapResultRenderResult(
    string ContextToken,
    string SourceID,
    int SelectedProfileIndex,
    string? SelectedProfileTime,
    MapResultRenderStep[] Steps,
    MapResultRenderLayerPayload[] Layers,
    MapResultRenderSourceStatus[] Sources,
    string? UnavailableReason);
