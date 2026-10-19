using System.Globalization;
using System.Xml.Linq;
using Geospatial.Vectors;
using Ras.Hydraulics;
using Ras.Layers;
using Utility.Files;

namespace Ras.Backend;

/// <summary>
/// Map-scoped adapter for FlowAreaLayerVisualContext.MeshErrorProperties.
/// The threshold and enable bit live on the exact sparse .vis FlowArea node;
/// scans reuse the retained MeshNodeDegreeScan over the source FlowArea meshes.
/// </summary>
public static partial class MapTreeService
{
    private const int MaximumMeshErrorIssues = 10_000;

    public static MapTreeMeshErrorSnapshot MeshErrors(MapTreeMeshErrorRequest request)
    {
        ArgumentNullException.ThrowIfNull(request);
        ValidateMeshErrorRequest(request);
        return request.Action switch
        {
            "load" => LoadMeshErrors(request),
            "draftSettings" => LoadMeshErrorDraftSettings(request),
            "set" => SetMeshErrors(request),
            _ => throw new NotSupportedException("The requested mesh error map action is not supported.")
        };
    }

    private static MapTreeMeshErrorSnapshot LoadMeshErrors(MapTreeMeshErrorRequest request)
    {
        MapTreeRequest mapRequest = request.Map;
        string projectPath = CanonicalPath(mapRequest.ProjectPath);
        string projectRevision = RevisionFile(projectPath);
        MapResultComputeReadLeaseScope? readLease = MapResultComputeReadLeaseScope.Resolve(mapRequest, projectPath);
        string sourcePath = CanonicalPath(request.SourcePath);
        if (!Path.IsPathFullyQualified(request.SourcePath) || !File.Exists(sourcePath) ||
            !IsHdfSource(sourcePath)) throw new SourceFileChangedException();

        // Read only the map document first. If this exact Geometry/Result is
        // protected by a live compute lease, return its persisted controls
        // without hashing or opening the writer-owned HDF.
        using OperationContext document = Open(mapRequest.ProjectPath, mapRequest.ProjectXml,
            mapRequest.ProjectXmlSHA, mapRequest.ExpectedVisualizationRevision, allowMissing: false);
        XElement savedMap = ResolveMap(document.Visualization, mapRequest.MapIndex,
            mapRequest.MapName, mapRequest.MapType);
        XElement? savedNode = ResolveNode(savedMap, request.FlowAreaNode, required: false);
        ValidateFlowAreaOwner(request, sourcePath);
        (bool enabled, int threshold) = ReadMeshErrorSettings(savedNode);

        if (readLease?.IsProtected(sourcePath) == true)
            return Snapshot(request, document, projectPath, projectRevision, sourcePath,
                enabled, threshold, isChecked: null, isEffectivelyVisible: null, "writerProtected",
                "Mesh diagnostics are waiting for the active compute writer to release this source.", [],
                omittedIssueCount: 0);

        VerifyMeshSourceRevision(sourcePath, request.SourceRevision);
        MeshErrorSource source = OpenMeshErrorSource(request, readLease, sourcePath);
        try
        {
            CatalogTreeNode exactNode = FindExactNode(source.Tree.Roots, request.FlowAreaNode);
            if (!string.Equals(exactNode.SourceClass, "FlowAreaLayerVisualContext", StringComparison.Ordinal))
                throw new SourceFileChangedException();
            bool isChecked = exactNode.Checked == "checked";
            bool isEffectivelyVisible = IsEffectivelyVisible(source.Tree.Roots, exactNode);
            FlowAreaLayer layer = source.Layer;
            if (!enabled)
                return Snapshot(request, document, projectPath, projectRevision, sourcePath,
                    enabled, threshold, isChecked, isEffectivelyVisible,
                    "disabled", null, [], omittedIssueCount: 0);

            IMeshCollection meshes = layer.AsMeshCollection();
            var errors = new List<MeshNodeDegreeError>();
            meshes.Lock.AcquireReaderLock(-1);
            try
            {
                for (int meshIndex = 0; meshIndex < meshes.Count; meshIndex++)
                    MeshNodeDegreeScan.FindHighDegreeNodes(meshes[meshIndex], meshIndex, threshold, errors);
            }
            finally
            {
                meshes.Lock.ReleaseReaderLock();
            }
            errors.Sort((left, right) => right.FaceCount.CompareTo(left.FaceCount));
            int omitted = Math.Max(0, errors.Count - MaximumMeshErrorIssues);
            MapTreeMeshErrorIssue[] issues = errors.Take(MaximumMeshErrorIssues)
                .Select(error => ProjectMeshError(error, meshes)).ToArray();

            VerifyMeshSourceRevision(sourcePath, request.SourceRevision);
            if (!string.Equals(RevisionFile(projectPath), projectRevision, StringComparison.OrdinalIgnoreCase))
                throw new SourceFileChangedException();
            if (!string.Equals(RevisionFile(document.VisualizationPath),
                    document.PreviousVisualizationRevision, StringComparison.OrdinalIgnoreCase))
                throw new SourceFileChangedException();
            return Snapshot(request, document, projectPath, projectRevision, sourcePath,
                enabled, threshold, isChecked, isEffectivelyVisible,
                omitted == 0 ? "available" : "partial",
                omitted == 0 ? null : $"{omitted.ToString(CultureInfo.InvariantCulture)} mesh errors were omitted from the map response.",
                issues, omitted);
        }
        finally
        {
            source.Dispose();
        }
    }

    /// <summary>
    /// Reads only the exact sparse .vis controls for an active generated mesh
    /// draft. The Geometry/Result HDF is deliberately not opened or hashed;
    /// the caller's subsequent geometry.mesh.degreeErrors request validates
    /// the exact source revision and scans the opaque draft payload.
    /// </summary>
    private static MapTreeMeshErrorSnapshot LoadMeshErrorDraftSettings(MapTreeMeshErrorRequest request)
    {
        string projectPath = CanonicalPath(request.Map.ProjectPath);
        string projectRevision = RevisionFile(projectPath);
        string sourcePath = CanonicalPath(request.SourcePath);
        using OperationContext document = Open(request.Map.ProjectPath, request.Map.ProjectXml,
            request.Map.ProjectXmlSHA, request.Map.ExpectedVisualizationRevision, allowMissing: false);
        XElement savedMap = ResolveMap(document.Visualization, request.Map.MapIndex,
            request.Map.MapName, request.Map.MapType);
        XElement? savedNode = ResolveNode(savedMap, request.FlowAreaNode, required: false);
        ValidateFlowAreaOwner(request, sourcePath);
        (bool enabled, int threshold) = ReadMeshErrorSettings(savedNode);
        return Snapshot(request, document, projectPath, projectRevision, sourcePath,
            enabled, threshold, isChecked: null, isEffectivelyVisible: null,
            "draftSettings", null, [], omittedIssueCount: 0);
    }

    private static MapTreeMeshErrorSnapshot SetMeshErrors(MapTreeMeshErrorRequest request)
    {
        if (request.Map.ComputeReadLease is not null)
            throw new SourceFileChangedException();
        if (request.CheckMeshErrors is null && request.MaxFacesPerNodeEntry is null)
            throw new ArgumentException("At least one mesh error setting is required.");
        string sourcePath = CanonicalPath(request.SourcePath);
        VerifyMeshSourceRevision(sourcePath, request.SourceRevision);
        int? threshold = request.MaxFacesPerNodeEntry is double entry
            ? RoundMeshErrorThreshold(entry)
            : null;
        bool? enabled = request.CheckMeshErrors;

        string projectPath = CanonicalPath(request.Map.ProjectPath);
        string projectRevision = RevisionFile(projectPath);
        (bool previousEnabled, int previousThreshold) = ReadCommittedMeshErrorSettings(request);

        MapTreeMutationResult mutation = MutateNode(request.Map, request.FlowAreaNode,
            (_, node, _) =>
            {
                VerifyMeshSourceRevision(sourcePath, request.SourceRevision);
                if (enabled is bool check)
                {
                    if (check) node.SetAttributeValue("CheckMeshErrors", true);
                    else node.Attribute("CheckMeshErrors")?.Remove();
                }
                if (threshold is int value)
                {
                    if (value == 8) node.Attribute("MaxFacesPerNode")?.Remove();
                    else node.SetAttributeValue("MaxFacesPerNode", value);
                }
                return true;
            }, materializeIfImplicit: true);

        if (mutation.PreviousVisualizationRevision is not null &&
            !mutation.PreviousVisualizationRevision.Equals(request.Map.ExpectedVisualizationRevision,
                StringComparison.OrdinalIgnoreCase)) throw new SourceFileChangedException();
        CatalogTreeNodeLocator rebasedFlowAreaNode = ResolveMaterializedFlowAreaLocator(
            mutation.Roots, request.FlowAreaNode);
        MapTreeMeshErrorRequest reread = request with
        {
            Map = request.Map with { ExpectedVisualizationRevision = mutation.VisualizationRevision },
            FlowAreaNode = rebasedFlowAreaNode,
            Action = request.ReadSettingsOnly ? "draftSettings" : "load",
            CheckMeshErrors = null,
            MaxFacesPerNodeEntry = null
        };
        try
        {
            if (request.ResultOwner is { } owner)
            {
                string refreshedContextToken = ResolvePostMutationResultContextToken(reread, owner);
                reread = reread with
                {
                    ContextToken = refreshedContextToken,
                    ResultOwner = owner with { ContextToken = refreshedContextToken }
                };
            }

            MapTreeMeshErrorSnapshot snapshot = request.ReadSettingsOnly
                ? LoadMeshErrorDraftSettings(reread)
                : LoadMeshErrors(reread);
            return snapshot with { PreviousVisualizationRevision = mutation.PreviousVisualizationRevision };
        }
        catch (Exception error) when (IsPostCommitReadbackFailure(error))
        {
            // The .vis mutation is already committed. Keep the receipt truthful
            // even if the subsequent HDF/context read cannot be completed.
            CatalogTreeNode savedNode = FindExactNode(mutation.Roots, rebasedFlowAreaNode);
            bool finalEnabled = enabled ?? previousEnabled;
            int finalThreshold = threshold ?? previousThreshold;
            return new MapTreeMeshErrorSnapshot(request.ProjectSessionID,
                request.MapWorkflowIdentity, reread.ContextToken, projectPath, projectRevision,
                request.Map.ProjectXmlSHA!, mutation.VisualizationRevision, request.Map.MapID,
                request.Map.MapIndex, request.Map.MapName, request.Map.MapType,
                rebasedFlowAreaNode, sourcePath, request.SourceRevision, finalEnabled,
                finalThreshold, request.ReadSettingsOnly ? null : savedNode.Checked == "checked",
                request.ReadSettingsOnly ? null : IsEffectivelyVisible(mutation.Roots, savedNode),
                "savedReadbackUnavailable",
                $"Mesh error settings were saved, but diagnostics could not be refreshed.\n{error.Message}",
                [], 0, 0, PreviousVisualizationRevision: mutation.PreviousVisualizationRevision);
        }
    }

    private static (bool Enabled, int Threshold) ReadCommittedMeshErrorSettings(
        MapTreeMeshErrorRequest request)
    {
        using OperationContext document = Open(request.Map.ProjectPath, request.Map.ProjectXml,
            request.Map.ProjectXmlSHA, request.Map.ExpectedVisualizationRevision, allowMissing: false);
        XElement map = ResolveMap(document.Visualization, request.Map.MapIndex,
            request.Map.MapName, request.Map.MapType);
        XElement? node = ResolveNode(map, request.FlowAreaNode, required: false);
        ValidateFlowAreaOwner(request, CanonicalPath(request.SourcePath));
        return ReadMeshErrorSettings(node);
    }

    private static CatalogTreeNodeLocator ResolveMaterializedFlowAreaLocator(
        IEnumerable<CatalogTreeNode> roots, CatalogTreeNodeLocator requested)
    {
        CatalogTreeNodeLocator[] matches = Descendants(roots)
            .Where(node => node.Locator is { } candidate &&
                LocatorIdentityEquals(candidate, requested, ignoreNodePath: true,
                    allowMaterializedGeometryPath: true) &&
                IsUnchangedOrMaterialized(requested.NodePath, candidate.NodePath) &&
                IsUnchangedOrMaterialized(requested.ParentGeometryNodePath,
                    candidate.ParentGeometryNodePath))
            .Select(node => node.Locator!)
            .ToArray();
        if (matches.Length != 1) throw new SourceFileChangedException();
        return matches[0];
    }

    private static bool IsUnchangedOrMaterialized(int[]? previous, int[]? current) =>
        OptionalIndicesEqual(previous, current) ||
        (previous is null && current is { Length: > 0 });

    private static string ResolvePostMutationResultContextToken(
        MapTreeMeshErrorRequest request, MapResultGeometryOwner owner)
    {
        MapResultSourcesResult sources = MapResultChartService.Sources(
            new MapResultSourcesRequest(request.Map, owner.SelectionOverrides));
        if (!sources.VisualizationRevision.Equals(request.Map.ExpectedVisualizationRevision,
                StringComparison.OrdinalIgnoreCase) ||
            !sources.MapID.Equals(request.Map.MapID, StringComparison.OrdinalIgnoreCase))
            throw new SourceFileChangedException();

        MapResultActiveNode[] nodes = sources.ActiveNodes.Where(node =>
            SameMeshErrorLocator(node.Node, owner.ResultNode)).ToArray();
        if (nodes.Length != 1) throw new SourceFileChangedException();
        MapResultSelectionState[] selections = nodes[0].Selections.Where(selection =>
            selection.SelectionIndex == owner.SelectionIndex).ToArray();
        if (selections.Length != 1 || selections[0].SelectedResult is not { } selected ||
            !SameCanonical(selected.ResultPath, owner.SelectedResultPath) ||
            !selected.Revision.Equals(owner.SelectedResultRevision, StringComparison.OrdinalIgnoreCase) ||
            sources.ContextToken.Length != 64 || !sources.ContextToken.All(Uri.IsHexDigit))
            throw new SourceFileChangedException();
        return sources.ContextToken;
    }

    private static bool IsPostCommitReadbackFailure(Exception error) =>
        error is IOException or InvalidDataException or ArgumentException or
            InvalidOperationException or NotSupportedException;

    private static MeshErrorSource OpenMeshErrorSource(MapTreeMeshErrorRequest request,
        MapResultComputeReadLeaseScope? readLease, string sourcePath)
    {
        if (request.ResultOwner is { } owner)
        {
            ResolvedMapResultContext context = MapResultChartService.ResolveContext(request.Map,
                owner.SelectionOverrides, owner.ContextToken);
            try
            {
                ResolvedMapResultNode[] results = context.ResultContexts.Where(candidate =>
                    candidate.Selections.Any(selection =>
                        selection.SelectionIndex == owner.SelectionIndex &&
                        SameMeshErrorLocator(selection.Node, owner.ResultNode)) &&
                    SameCanonical(candidate.ResultPath, sourcePath) &&
                    candidate.Revision.Equals(request.SourceRevision, StringComparison.OrdinalIgnoreCase)).ToArray();
                if (results.Length != 1) throw new SourceFileChangedException();
                CatalogTreeNode node = FindExactNode(context.Tree.Roots, request.FlowAreaNode);
                if (!string.Equals(node.SourceClass, "FlowAreaLayerVisualContext", StringComparison.Ordinal))
                    throw new SourceFileChangedException();
                ValidateResultFlowAreaOwner(request, owner, sourcePath);
                FlowAreaLayer layer = results[0].Result.Geometry?.FlowAreaLayer
                    ?? throw new InvalidDataException("The selected Result has no embedded FlowAreaLayer.");
                return new MeshErrorSource(layer, context.Tree, context.Dispose);
            }
            catch
            {
                context.Dispose();
                throw;
            }
        }

        MapTreeSnapshot tree = Load(request.Map);
        CatalogTreeNode exact = FindExactNode(tree.Roots, request.FlowAreaNode);
        if (!string.Equals(exact.SourceClass, "FlowAreaLayerVisualContext", StringComparison.Ordinal))
            throw new SourceFileChangedException();
        if (request.FlowAreaNode.ParentGeometryAssetID is not { Length: > 0 } geometryPath ||
            !SameCanonical(geometryPath, sourcePath)) throw new SourceFileChangedException();

        var project = new Project(request.Map.ProjectPath,
            candidate => readLease?.IsProtected(candidate) != true);
        try
        {
            if (request.Map.ProjectXml is { Length: > 0 } xml)
                project.ApplyEditorMetadata(XElement.Parse(xml, LoadOptions.PreserveWhitespace));
            Geometry[] geometries = project.Geometries.Where(geometry =>
                SameCanonical(geometry.Filename, sourcePath) &&
                string.Equals(geometry.Name, request.FlowAreaNode.ParentGeometryNodeName, StringComparison.Ordinal)).ToArray();
            if (geometries.Length != 1) throw new SourceFileChangedException();
            FlowAreaLayer layer = geometries[0].FlowAreaLayer;
            VerifyMeshSourceRevision(sourcePath, request.SourceRevision);
            return new MeshErrorSource(layer, tree, () => MapResultChartService.DisposeProject(project));
        }
        catch
        {
            MapResultChartService.DisposeProject(project);
            throw;
        }
    }

    private static MapTreeMeshErrorIssue ProjectMeshError(MeshNodeDegreeError error, IMeshCollection meshes)
    {
        if (error.MeshIndex < 0 || error.MeshIndex >= meshes.Count)
            throw new InvalidDataException("The retained mesh scan returned an invalid mesh index.");
        Mesh mesh = meshes[error.MeshIndex];
        var cells = new List<MapTreeMeshErrorCell>();
        foreach (int cellIndex in error.Cells)
        {
            if (cellIndex < 0 || cellIndex >= mesh.CellCount) continue;
            Geospatial.Vectors.Polygon polygon = mesh.CellPolygon(cellIndex);
            Point[] points = polygon.GetPointBufferUnsafe().Span.ToArray();
            if (points.Length < 3 || points.Any(point => !double.IsFinite(point.X) || !double.IsFinite(point.Y)))
                continue;
            cells.Add(new MapTreeMeshErrorCell(cellIndex,
                points.Select(point => new MapTreeMeshErrorCoordinate(point.X, point.Y)).ToArray()));
        }
        Extent extent = error.CellsExtent(mesh);
        bool hasExtent = !extent.IsNull() && double.IsFinite(extent.MinX) && double.IsFinite(extent.MinY) &&
            double.IsFinite(extent.MaxX) && double.IsFinite(extent.MaxY);
        return new MapTreeMeshErrorIssue(
            $"{error.MeshIndex}:{error.NodeIndex}", error.MeshIndex, error.NodeIndex, error.FaceCount,
            new MapTreeMeshErrorCoordinate(error.NodePoint.X, error.NodePoint.Y),
            hasExtent ? extent.MinX : null, hasExtent ? extent.MinY : null,
            hasExtent ? extent.MaxX : null, hasExtent ? extent.MaxY : null, cells.ToArray());
    }

    private static MapTreeMeshErrorSnapshot Snapshot(MapTreeMeshErrorRequest request,
        OperationContext document, string projectPath, string projectRevision, string sourcePath,
        bool enabled, int threshold, bool? isChecked, bool? isEffectivelyVisible,
        string status, string? diagnostic,
        MapTreeMeshErrorIssue[] issues, int omittedIssueCount) => new(
        request.ProjectSessionID, request.MapWorkflowIdentity, request.ContextToken,
        projectPath, projectRevision, request.Map.ProjectXmlSHA!,
        document.PreviousVisualizationRevision!, request.Map.MapID, request.Map.MapIndex,
        request.Map.MapName, request.Map.MapType, request.FlowAreaNode,
        sourcePath, request.SourceRevision, enabled, threshold, isChecked, isEffectivelyVisible, status,
        diagnostic, issues, issues.Length + omittedIssueCount, omittedIssueCount,
        PreviousVisualizationRevision: document.PreviousVisualizationRevision);

    private static (bool Enabled, int Threshold) ReadMeshErrorSettings(XElement? node)
    {
        bool enabled = bool.TryParse((string?)node?.Attribute("CheckMeshErrors"), out bool parsed) && parsed;
        int threshold = int.TryParse((string?)node?.Attribute("MaxFacesPerNode"),
            NumberStyles.Integer, CultureInfo.InvariantCulture, out int value) ? Math.Clamp(value, 3, 64) : 8;
        return (enabled, threshold);
    }

    private static int RoundMeshErrorThreshold(double value)
    {
        if (!double.IsFinite(value)) throw new ArgumentOutOfRangeException(nameof(value));
        double rounded = Math.Round(value, MidpointRounding.AwayFromZero);
        if (rounded <= 3) return 3;
        if (rounded >= 64) return 64;
        return (int)rounded;
    }

    private static void ValidateMeshErrorRequest(MapTreeMeshErrorRequest request)
    {
        if (!Guid.TryParse(request.ProjectSessionID, out Guid session) || session == Guid.Empty ||
            string.IsNullOrWhiteSpace(request.MapWorkflowIdentity) ||
            string.IsNullOrWhiteSpace(request.ContextToken) ||
            string.IsNullOrWhiteSpace(request.Map.ProjectXmlSHA) ||
            string.IsNullOrWhiteSpace(request.SourcePath) || !Path.IsPathFullyQualified(request.SourcePath) ||
            request.SourceRevision.Length != 64 || !request.SourceRevision.All(Uri.IsHexDigit) ||
            request.FlowAreaNode.NodeType != "FlowAreaLayer" ||
            string.IsNullOrWhiteSpace(request.FlowAreaNode.RootName) ||
            string.IsNullOrWhiteSpace(request.FlowAreaNode.NodeName) ||
            !Guid.TryParse(request.Map.MapID, out Guid mapID) || mapID == Guid.Empty)
            throw new ArgumentException("The mesh error map context is incomplete.");
        if (request.Action == "set" && request.Map.ComputeReadLease is not null)
            throw new SourceFileChangedException();
        ValidateFlowAreaOwner(request, CanonicalPath(request.SourcePath));
        if (request.ResultOwner is { } owner)
            ValidateResultFlowAreaOwner(request, owner, CanonicalPath(request.SourcePath));
    }

    private static void ValidateFlowAreaOwner(MapTreeMeshErrorRequest request, string sourcePath)
    {
        CatalogTreeNodeLocator node = request.FlowAreaNode;
        if (request.ResultOwner is { } owner)
        {
            if (!SameCanonical(owner.SelectedResultPath, sourcePath) ||
                !owner.SelectedResultRevision.Equals(request.SourceRevision, StringComparison.OrdinalIgnoreCase) ||
                node.ParentResultNodeType != owner.ResultNode.NodeType ||
                node.RootName != owner.ResultNode.RootName ||
                node.ParentResultNodeName != owner.ResultNode.NodeName ||
                node.ParentResultNodePath is null || owner.ResultNode.NodePath is null ||
                !node.ParentResultNodePath.SequenceEqual(owner.ResultNode.NodePath) ||
                node.ParentResultAssetID is null || !SameCanonical(node.ParentResultAssetID, sourcePath) ||
                !string.Equals(node.ParentResultRevision, owner.SelectedResultRevision, StringComparison.OrdinalIgnoreCase))
                throw new SourceFileChangedException();
            return;
        }
        if (node.ParentGeometryAssetID is not { Length: > 0 } geometryPath ||
            !SameCanonical(geometryPath, sourcePath) ||
            string.IsNullOrWhiteSpace(node.ParentGeometryNodeName))
            throw new SourceFileChangedException();
    }

    private static void ValidateResultFlowAreaOwner(MapTreeMeshErrorRequest request,
        MapResultGeometryOwner owner, string sourcePath)
    {
        CatalogTreeNodeLocator flowArea = request.FlowAreaNode;
        if (owner.ResultNode.NodeType is not ("Result" or "MultiResult") ||
            flowArea.RootName != owner.ResultNode.RootName ||
            flowArea.ParentResultNodeType != owner.ResultNode.NodeType ||
            flowArea.ParentResultNodeName != owner.ResultNode.NodeName ||
            flowArea.ParentResultNodePath is null || owner.ResultNode.NodePath is null ||
            !flowArea.ParentResultNodePath.SequenceEqual(owner.ResultNode.NodePath) ||
            !SameCanonical(owner.SelectedResultPath, sourcePath))
            throw new SourceFileChangedException();
    }

    private static void VerifyMeshSourceRevision(string path, string revision)
    {
        if (!File.Exists(path) ||
            !RevisionFile(path).Equals(revision, StringComparison.OrdinalIgnoreCase))
            throw new SourceFileChangedException();
    }

    private static bool IsHdfSource(string path) =>
        Path.GetExtension(path).Equals(".h5", StringComparison.OrdinalIgnoreCase) ||
        Path.GetExtension(path).Equals(".hdf", StringComparison.OrdinalIgnoreCase);

    private static bool SameCanonical(string left, string right) =>
        string.Equals(CanonicalPath(left), CanonicalPath(right),
            OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal);

    private static bool SameMeshErrorLocator(CatalogTreeNodeLocator left,
        CatalogTreeNodeLocator right) => left.RootName == right.RootName &&
        left.NodeType == right.NodeType && left.NodeName == right.NodeName &&
        (left.NodePath ?? []).SequenceEqual(right.NodePath ?? []) &&
        (left.AssetID is null && right.AssetID is null || left.AssetID is not null && right.AssetID is not null &&
            (left.AssetID == right.AssetID || Path.IsPathFullyQualified(left.AssetID) &&
                Path.IsPathFullyQualified(right.AssetID) && SameCanonical(left.AssetID, right.AssetID)));

    private sealed class MeshErrorSource(FlowAreaLayer layer, MapTreeSnapshot tree, Action dispose) : IDisposable
    {
        internal FlowAreaLayer Layer { get; } = layer;
        internal MapTreeSnapshot Tree { get; } = tree;
        public void Dispose() => dispose();
    }
}
