namespace Ras.Backend;

public sealed record GeometryTopologyModelRequest(string AssetPath, string Kind, string? ProjectPath, string? ProjectXml = null);
public sealed record GeometryTopologyLoadRequest(GeometryTopologyModelRequest Model, string? Revision = null);
public sealed record GeometryTopologyEditRequest(GeometryTopologyModelRequest Model, string Revision, string DraftState, GeometryTopologyMutation Mutation);
public sealed record GeometryTopologySaveRequest(GeometryTopologyModelRequest Model, string Revision, string DraftState);

/// <summary>A validated source mutation retained as part of an unsaved topology draft.</summary>
public sealed record GeometryTopologyMutation(string Operation, string FeatureKind, int[] FeatureIDs,
    string? FieldID = null, string? Value = null, string? TagName = null, string? TagType = null, string? TagValue = null)
{
    // The retained global factor tool can target both source collections in one
    // command. These fields remain optional so older topology draft payloads
    // keep their existing wire shape and replay behavior.
    public bool ApplyToSelectedOnly { get; init; }
    public string? FactorText { get; init; }
    public int[] ArcFeatureIDs { get; init; } = [];
    public int[] ControlPointFeatureIDs { get; init; } = [];
    public int[] NodeFeatureIDs { get; init; } = [];

    // Recipe text is intentionally opaque. The source setter preserves invalid
    // raw text; validation is returned by the read-only recipe query.
    public string? RecipeText { get; init; }
    public bool ForceSet { get; init; }

    // Arc-point rows are source identities, not rendered polyline positions.
    // PointKind is exactly "start", "internal", or "end". Internal indices
    // are zero-based; endpoint indices are source topology node indices.
    public string? PointKind { get; init; }
    public int? InternalPointIndex { get; init; }
    public int? EndpointNodeIndex { get; init; }
    public string? Axis { get; init; }
    public string? RawValue { get; init; }
}

public sealed record GeometryTopologyArcPointsRequest(GeometryTopologyModelRequest Model, string Revision,
    string DraftState, int ArcFID);
public sealed record GeometryTopologyArcPointsSnapshot(string Revision, string DraftIdentity, int ArcFID,
    GeometryTopologyArcPoint[] Rows);
public sealed record GeometryTopologyArcPoint(int RowIndex, string PointKind, int? InternalPointIndex,
    int? EndpointNodeIndex, double X, double Y);

public sealed record GeometryTopologyRecipeRequest(GeometryTopologyModelRequest Model, string Revision,
    string DraftState, int[] ControlPointFIDs, string? RecipeText = null);
public sealed record GeometryTopologyRecipeSnapshot(string Revision, string DraftIdentity,
    int[] ControlPointFIDs, bool HasSelection, bool HasMismatch, string? CommonRecipe,
    string RawText, bool IsValid, string? ParseIssue, GeometryTopologyRecipeStep[] Steps,
    GeometryTopologyRecipeStepSchema[] StepSchema, GeometryTopologyControlPointRecipe[] SelectedRecipes,
    string[]? SelectedPatchTypes = null);
public sealed record GeometryTopologyControlPointRecipe(int FID, string Recipe);
public sealed record GeometryTopologyRecipeStep(string Name, Dictionary<string, string> Parameters);
public sealed record GeometryTopologyRecipeStepSchema(string Name, string[] Aliases,
    GeometryTopologyRecipeParameter[] Parameters);
public sealed record GeometryTopologyRecipeParameter(string Name, string SourceType, string DefaultValue);

public sealed record GeometryTopologyFilterRequest(GeometryTopologyModelRequest Model, string Revision,
    string DraftState, string FeatureKind, GeometryTopologyFilterClause[] Clauses);
public sealed record GeometryTopologyFilterClause(string Type, string? TagDefinitionID,
    string? PropertyColumnID, string Operator, string? Value = null);
public sealed record GeometryTopologyFilterSnapshot(string Revision, string DraftIdentity, string FeatureKind,
    int[] MatchedFeatureIDs, GeometryTopologyPropertyDescriptor[] PropertyDescriptors,
    GeometryTopologyTagDefinition[] TagDefinitions);
public sealed record GeometryTopologyPropertyDescriptor(string Name, string ColumnName, string SourceType,
    bool IsEnum = false);

public sealed record GeometryTopologySnapshot(string Revision, string DraftState, bool CanEdit, bool IsDirty,
    GeometryTopologyFeatureTable Arcs, GeometryTopologyFeatureTable Regions, GeometryTopologyFeatureTable Nodes,
    GeometryTopologyTagDefinition[] ArcTags, GeometryTopologyTagDefinition[] RegionTags,
    GeometryTopologyRecentTag[] RecentArcTags, GeometryTopologyRecentTag[] RecentRegionTags,
    GeometryTopologyMap? Map = null, GeometryTopologyCompletionResult? Completion = null,
    bool CanUndo = false, bool CanRedo = false);

/// <summary>
/// The real, ephemeral result from retained conceptual-mesh topology completion.
/// It is not written into the geometry HDF. SourceRevision identifies the saved
/// baseline; DraftIdentity identifies the exact opaque DraftState returned with it.
/// </summary>
public sealed record GeometryTopologyCompletionResult(string SourceRevision, string DraftIdentity,
    bool IsComplete, GeometryTopologyCompletionMessage[] Messages);
public sealed record GeometryTopologyCompletionMessage(string ID, string Code, string Severity,
    string? RegionCompletionSeverity, string Text, GeometryTopologyLogValue[] LogData,
    GeometryTopologyDiagnosticTarget[] Targets);
public sealed record GeometryTopologyLogValue(string Key, string Value, string ValueType,
    int? IntegerValue = null);
/// <summary>A safely resolved source feature and the exact map feature IDs it represents.</summary>
public sealed record GeometryTopologyDiagnosticTarget(string FeatureKind, int FID,
    string TableRowID, string[] MapFeatureIDs);

public sealed record GeometryTopologyFeatureTable(string FeatureKind, GeometryTopologyColumn[] Columns,
    GeometryTopologyField[] EditableFields, GeometryTopologyFeatureRow[] Rows);
public sealed record GeometryTopologyColumn(string ID, string Title, string SourceType, bool ReadOnly = true,
    bool IsTag = false);
public sealed record GeometryTopologyField(string ID, string Title, string SourceType, string[] Choices,
    bool ReadOnly = false);
public sealed record GeometryTopologyFeatureRow(string ID, int FID, Dictionary<string, string> Values,
    double? X = null, double? Y = null, int? StartNodeID = null, int? EndNodeID = null);
public sealed record GeometryTopologyCoordinate(double X, double Y);
public sealed record GeometryTopologyExtent(double MinX, double MinY, double MaxX, double MaxY);
public sealed record GeometryTopologyMapFeature(string ID, string FeatureKind, int? FID, string GeometryType,
    string[] SelectionIDs, GeometryTopologyCoordinate[][] Paths, GeometryTopologyIncidentArc[]? IncidentArcs = null);
/// <summary>
/// A source NodeArcConnection in source order. Length is the real topology
/// polyline length for ArcID, not a rendered or inferred screen measurement.
/// </summary>
public sealed record GeometryTopologyIncidentArc(int ArcID, double Length);
public sealed record GeometryTopologyMap(GeometryTopologyExtent? Extent, GeometryTopologyMapFeature[] Features);
public sealed record GeometryTopologyTagDefinition(string ID, string Type);
public sealed record GeometryTopologyRecentTag(string Name, string Type, string Value);

/// <summary>
/// JSON is passed back as an opaque string because the backend protocol launches
/// one process per request. Mutations stay in memory on the client until Save.
/// </summary>
public sealed record GeometryTopologyDraftState(string AssetPath, string Revision,
    GeometryTopologyMutation[] Mutations, GeometryTopologyRecentTag[] RecentArcTags, GeometryTopologyRecentTag[] RecentRegionTags)
{
    /// <summary>Commands undone most recently are kept in pop order at the array tail.</summary>
    public GeometryTopologyMutation[] RedoMutations { get; init; } = [];
}
