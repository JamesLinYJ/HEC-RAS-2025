import RASWorkspaceCore
import SwiftUI

struct BackupCatalogSummaryData: Sendable {
    let filename: String
    // The original summary uses the parent geometry's dates, not guessed
    // filesystem timestamps from the backup file.
    let dateCreated: String
    let dateLastModified: String
    var canSaveAsNewGeometry = false
    var revision: String? = nil
    var parentGeometryPath: String? = nil
    var parentGeometryRevision: String? = nil
    var projectRevision: String? = nil
}

// Strongly typed summary data emitted by the catalog adapter. `properties`
// remains available for source-specific fields that do not belong in the
// common summary header.
struct CatalogNodeSummaryData: Sendable, Equatable {
    var name: String? = nil
    var filename: String? = nil
    var dateCreated: String? = nil
    var dateLastModified: String? = nil
    var description: String? = nil
}

enum CatalogSummaryKind: String, CaseIterable, Sendable {
    case project, plan, geometry, terrain, nValue, classification, boundaryCondition, result

    var title: String {
        switch self {
        case .project: "Project"
        case .plan: "Plan"
        case .geometry: "Geometry"
        case .terrain: "Terrain"
        case .nValue: "N-Value Layer"
        case .classification: "Classification"
        case .boundaryCondition: "Boundary Condition"
        case .result: "Result"
        }
    }

    var showsMapPreview: Bool {
        switch self {
        case .geometry, .terrain, .nValue, .classification, .result: true
        case .project, .plan, .boundaryCondition: false
        }
    }

    init?(sourceClass: String) {
        switch sourceClass {
        case "ModelSectionContext", "ModelRootNode", "ProjectNode", "ProjectNodeVM": self = .project
        case "PlanRootContext", "PlanRootNode", "PlanNode", "PlanNodeVM", "ObservablePlan": self = .plan
        case "GeometryRootContext", "GeometryRootNode", "GeometryNode", "GeometryNodeVM", "ObservableGeometry": self = .geometry
        case "TerrainRootContext", "TerrainRootNode", "TerrainNode", "TerrainNodeVM", "ObservableTerrain": self = .terrain
        case "NValueRootContext", "NValueRootNode", "NValueNode", "NValueNodeVM", "ObservableNValueLayer": self = .nValue
        case "ClassificationRootContext", "ClassificationRootNode", "ClassificationNode", "ClassificationNodeVM", "ObservableClassificationLayer": self = .classification
        case "BoundaryConditionRootContext", "BoundaryConditionRootNode", "BoundaryConditionNode", "BoundaryConditionNodeVM", "ObservableBoundaryCondition": self = .boundaryCondition
        case "ResultRootContext", "ResultRootNode", "ResultNode", "ResultNodeVM", "MultiResultNode", "MultiResultNodeVM", "ObservableResult", "TransientResultComputeNode": self = .result
        default: return nil
        }
    }
}

// Original RasTreeV2/TreeNode/FolderVM presentation. These are logical tree
// nodes, not a filesystem directory scan or guessed HDF contents.
struct LayerTreeNode: Identifiable, Sendable {
    enum CheckState: Sendable { case checked, unchecked, mixed }
    struct Property: Identifiable, Sendable { let id: String; let label: String; let value: String }
    let id: String
    let sourceClass: String
    let name: String
    var localizeName = false
    var children: [LayerTreeNode]? = nil
    var checked: CheckState? = nil
    var isPinned = false
    var canPin = false
    var canRename = false
    var canMove = false
    var canAcceptChildren = false
    var canCreateFolder = false
    var assetID: String? = nil
    var properties: [Property] = []
    var contextMenu: [ContextMenuEntry] = []
    var backupSummary: BackupCatalogSummaryData? = nil
    var catalogSummary: CatalogNodeSummaryData? = nil
    /// Source diagnostics from this exact catalog node snapshot. `nil` means
    /// the node has no loaded/applicable diagnostic payload; `[]` means the
    /// source was loaded and reported no messages.
    var layerErrors: [CatalogLayerDiagnostic]? = nil
    var diagnosticStatus: String? = nil
    var diagnosticReadError: String? = nil
    var diagnosticSourceIdentity: String? = nil
    var diagnosticSourceRevision: String? = nil
    /// Persisted status is sourced from the exact Result summary. For a
    /// MultiResult map node, source identity belongs to the selected Result,
    /// not to the Plan group that owns the row.
    var resultComputeState: String? = nil
    var resultComputeFailureReason: String? = nil
    var resultComputeSourcePath: String? = nil
    var resultComputeSourceRevision: String? = nil
    /// Set only on an in-memory Result row projected from the live source
    /// compute callback; catalog snapshots never decode these local markers.
    var transientResultComputeRunID: String? = nil
    var transientResultComputeStatus: String? = nil
    var sourceLocator: CatalogTreeNodeLocator? = nil
    var catalogSummaryKind: CatalogSummaryKind? { CatalogSummaryKind(sourceClass: sourceClass) }
    var symbol: String {
        switch sourceClass {
        case "BackupNodeVM", "BackupRootNodeVM": "clock.arrow.circlepath"
        case "FolderNode": "folder"
        case "GeometryNode", "FlowAreaNode", "ObservableGeometry": "point.3.connected.trianglepath.dotted"
        case "PlanNode", "ObservablePlan": "play.rectangle"
        case "BoundaryConditionNode", "ObservableBoundaryCondition": "waveform.path"
        case "TerrainNode", "TerrainInputNode", "ObservableTerrain": "mountain.2"
        case "NValueNode", "ClassificationNode", "ObservableNValueLayer", "ObservableClassificationLayer": "square.3.layers.3d"
        case "CulvertBarrelLayerNode": "square.split.2x1"
        case "PointMapLayerNode": "mappin"
        case "PolylineMapLayerNode": "point.topleft.down.to.point.bottomright.curvepath"
        case "PolygonMapLayerNode": "pentagon"
        case "ResultNode", "MultiResultNode", "ObservableResult", "TransientResultComputeNode": "chart.xyaxis.line"
        case "MapDocumentNode": "map"
        case "ExternalConnectionCatalogNode", "ObservableExternalConnection": "link"
        case "ExternalFileConnectionCatalogNode": "doc.text"
        default: "square.stack.3d.up"
        }
    }
    func find(_ id: String) -> Self? {
        if self.id == id { return self }
        return children?.lazy.compactMap { $0.find(id) }.first
    }
    func ancestorIDs(of id: String) -> [String]? {
        if self.id == id { return [] }
        for child in children ?? [] {
            if let path = child.ancestorIDs(of: id) { return [self.id] + path }
        }
        return nil
    }
    func filtered(_ query: String) -> Self? {
        if query.isEmpty || name.localizedCaseInsensitiveContains(query) { return self }
        let matches = children?.compactMap { $0.filtered(query) } ?? []
        guard !matches.isEmpty else { return nil }
        var copy = self; copy.children = matches; return copy
    }
}

enum CatalogConnectionNodeRoute {
    static func isConnection(_ node: LayerTreeNode) -> Bool {
        node.sourceClass == "ExternalConnectionCatalogNode"
            || node.sourceClass == "ExternalFileConnectionCatalogNode"
            || node.sourceClass == "ObservableExternalConnection"
    }

    static func connection(for node: LayerTreeNode, in connections: [ProjectConnection]) -> ProjectConnection? {
        guard isConnection(node), node.id.hasPrefix("connection:"),
              let index = Int(node.id.dropFirst("connection:".count)), connections.indices.contains(index) else { return nil }
        let connection = connections[index]
        guard node.name == connection.name else { return nil }

        let properties = Dictionary(node.properties.map { ($0.id, $0.value) }, uniquingKeysWith: { _, latest in latest })
        guard let sourceType = properties["Type"], sourceType == connection.type else { return nil }
        if let relativePath = properties["RelativePath"], relativePath != connection.relativePath { return nil }
        if let absolutePath = properties["AbsolutePath"], absolutePath != connection.absolutePath { return nil }
        if let description = properties["Description"], description != connection.description { return nil }
        if let pattern = properties["SearchPattern"], (pattern.isEmpty ? "*" : pattern) != (connection.searchPattern.isEmpty ? "*" : connection.searchPattern) { return nil }
        if let recurse = properties["Recurse"], recurse.lowercased() != String(connection.recurse) { return nil }

        switch node.sourceClass {
        case "ExternalFileConnectionCatalogNode": guard connection.type == "File" else { return nil }
        case "ExternalConnectionCatalogNode": guard connection.type == "Directory" else { return nil }
        default: break
        }
        return connection
    }
}

struct LayerTreeContext: Hashable, Sendable {
    let projectSessionID: UUID
    let projectURL: URL?
    let mapID: UUID
    let mode: String
    let focusedGeometryIDs: [String]
    let focusedPlanIDs: [String]
    var projectRevision: String = ""
    var assetsRevision: Int = 0
    /// Exact slot-zero Result chosen for each active MultiResult owner. The
    /// retained source uses its real default Latest when this list is empty;
    /// explicit session choices are sent to map.tree.load so embedded
    /// Geometry/Boundary children are rebuilt from the same Result as the
    /// map raster workflow.
    var resultSelectionOverrides: [MapTreeResultSelectionOverride] = []
    var coreLayerContext: CoreLayerRequestContext? = nil
    /// A selected exact Result that cannot be bound to the serialized
    /// MultiResult owner must fail tree reads instead of silently falling back
    /// to the source's default Latest Result.
    var resultSelectionError: String? = nil
}

struct MapTreeResultSelectionOverride: Codable, Hashable, Sendable {
    let planAssetID: String
    let planName: String
    let selectedResultPath: String
    let selectedResultRevision: String
}
struct CatalogMapDocument: Codable, Hashable, Sendable {
    let id: String
    let name: String
    let kind: String
    var sourceIndex: Int? = nil
    var visualizationRevision: String? = nil
}
struct CatalogTreeNodeLocator: Codable, Hashable, Sendable {
    let rootName: String
    let nodeType: String
    let nodeName: String
    var nodePath: [Int]? = nil
    var assetID: String? = nil
    var mapType: String? = nil
    var filename: String? = nil
    var filenameRelative: String? = nil
    // Geometry child locators are tied to their exact parent HDF and tree
    // row. Other locator families leave these fields absent.
    var parentGeometryAssetID: String? = nil
    var parentGeometryNodePath: [Int]? = nil
    var parentGeometryNodeName: String? = nil
    // Plan-owned rows are bound to the exact focused Plan source and its
    // serialized parent path. This remains distinct from a Plan's display name
    // and from Project sidebar Plan nodes.
    var parentPlanAssetID: String? = nil
    var parentPlanNodePath: [Int]? = nil
    var parentPlanNodeName: String? = nil
    // Result/MultiResult-owned children are scoped to the selected embedded
    // Result in that exact serialized map-tree owner. The revision is the
    // selected Result HDF SHA, not the map's displayed title.
    var parentResultNodeType: String? = nil
    var parentResultAssetID: String? = nil
    var parentResultNodePath: [Int]? = nil
    var parentResultNodeName: String? = nil
    var parentResultRevision: String? = nil
    // WindLayer children belong to one exact serialized BoundaryCondition
    // row. This is separate from Result ownership: result-embedded Boundary
    // sources are not project Wind sources.
    var parentBoundaryConditionAssetID: String? = nil
    var parentBoundaryConditionNodePath: [Int]? = nil
    var parentBoundaryConditionNodeName: String? = nil
    // A shared association row refers to the actual linked source layer.
    // Display names do not establish Terrain/NValue/Classification ownership.
    var associationAssetID: String? = nil
    var associationKind: String? = nil

    var isFocusedPlanOwner: Bool {
        rootName == "Focused Plans" && nodeType == "Plan"
            && parentGeometryAssetID == nil && parentGeometryNodePath == nil
            && parentGeometryNodeName == nil
            && parentPlanAssetID == nil && parentPlanNodePath == nil && parentPlanNodeName == nil
            && parentResultNodeType == nil && parentResultAssetID == nil
            && parentResultNodePath == nil && parentResultNodeName == nil && parentResultRevision == nil
    }

    var sourceIdentity: String {
        var values = [rootName, nodeType, nodeName,
            (nodePath ?? []).map(String.init).joined(separator: "."), assetID ?? "", mapType ?? "",
            filename ?? "", filenameRelative ?? "", parentGeometryAssetID ?? "",
            (parentGeometryNodePath ?? []).map(String.init).joined(separator: "."), parentGeometryNodeName ?? "",
            parentPlanAssetID ?? "", (parentPlanNodePath ?? []).map(String.init).joined(separator: "."),
            parentPlanNodeName ?? "", parentResultNodeType ?? "", parentResultAssetID ?? "",
            (parentResultNodePath ?? []).map(String.init).joined(separator: "."),
            parentResultNodeName ?? "", parentResultRevision ?? "",
            associationAssetID ?? "", associationKind ?? ""]
        if parentBoundaryConditionAssetID != nil || parentBoundaryConditionNodePath != nil
            || parentBoundaryConditionNodeName != nil {
            values.append(contentsOf: [parentBoundaryConditionAssetID ?? "",
                (parentBoundaryConditionNodePath ?? []).map(String.init).joined(separator: "."),
                parentBoundaryConditionNodeName ?? ""])
        }
        return values.map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
    }
}
struct LayerTreeSnapshot: Sendable {
    let roots: [LayerTreeNode]
    var hiddenLayerIDs: Set<String>? = nil
    var focusedGeometryIDs: Set<String>? = nil
    var focusedPlanIDs: Set<String>? = nil
    var selection: LayerTreeSelection? = nil
    var canCopyWholeLayer = false
    var canPasteLayer = false
    var acceptedClipboardTypes: [String] = []
    // Optional authoritative project asset list after source catalog mutations.
    // The UI does not infer a new geometry from a filename or a button click.
    var projectAssets: [ProjectAsset]? = nil
    var expandedNodeIDs: Set<String>? = nil
    var operationWarning: String? = nil
}
enum LayerTreeSelection: Sendable { case node(String), cleared }
enum LayerTreeAction: Sendable {
    case saveBackupAsNewGeometry(nodeID: String)
    case select(id: String?)
    case rename(id: String, name: String)
    case visibility(id: String, checked: Bool)
    case pin(id: String, pinned: Bool)
    case move(ids: [String], parentID: String)
    case newFolder(parentID: String, name: String)
    case contextCommand(nodeID: String, commandID: String, value: ContextMenuValue?)
}
@MainActor
protocol LayerTreeProvider {
    func load(_ context: LayerTreeContext) async throws -> LayerTreeSnapshot
    // The source adapter owns original tree/model mutation and persistence.
    // UI code does not invent HDF objects or move project files for FolderVM.
    func perform(_ action: LayerTreeAction, context: LayerTreeContext) async throws -> LayerTreeSnapshot
    func copyWholeLayer(context: LayerTreeContext) async throws -> [ClipboardItem]
    func pasteLayer(_ items: [ClipboardItem], context: LayerTreeContext) async throws -> LayerTreeSnapshot
}
extension LayerTreeProvider {
    func copyWholeLayer(context: LayerTreeContext) async throws -> [ClipboardItem] { throw CocoaError(.featureUnsupported) }
    func pasteLayer(_ items: [ClipboardItem], context: LayerTreeContext) async throws -> LayerTreeSnapshot { throw CocoaError(.featureUnsupported) }
}

@MainActor
final class LayerTreeSession: ObservableObject {
    @Published private(set) var roots: [LayerTreeNode]?
    @Published private(set) var busy = false
    @Published var selectedID: String? {
        didSet {
            if oldValue != selectedID, let selectedID,
               let ancestors = roots?.lazy.compactMap({ $0.ancestorIDs(of: selectedID) }).first {
                expandedNodeIDs.formUnion(ancestors)
            }
        }
    }
    @Published private(set) var expandedNodeIDs: Set<String> = []
    @Published var error: String?
    @Published private(set) var canCopyWholeLayer = false
    @Published private(set) var canPasteLayer = false
    private var acceptedClipboardTypes: [String] = []
    private var provider: (any LayerTreeProvider)?
    private var context: LayerTreeContext?
    private var snapshotRoots: [LayerTreeNode]?
    private var transientResultRowsByPath: [String: TransientResultComputeRow] = [:]
    private var transientResultProjectSessionID: UUID?
    private var revision = 0
    var didInstall: ((LayerTreeSnapshot, LayerTreeContext) -> Void)?
    var activeContext: LayerTreeContext? { context }
    var selectedNode: LayerTreeNode? { selectedID.flatMap { id in roots?.lazy.compactMap { $0.find(id) }.first } }
    func node(withID id: String) -> LayerTreeNode? { roots?.lazy.compactMap { $0.find(id) }.first }
    func load(provider: (any LayerTreeProvider)?, context: LayerTreeContext) async {
        revision += 1; let captured = revision
        if self.context != context {
            let previousProjectSessionID = self.context?.projectSessionID
            let preservesTreeIdentity = self.context.map { previous in
                previous.projectSessionID == context.projectSessionID
                    && previous.projectURL?.standardizedFileURL == context.projectURL?.standardizedFileURL
                    && previous.mapID == context.mapID
                    && previous.mode == context.mode
            } ?? false
            snapshotRoots = nil
            if let previousProjectSessionID,
               previousProjectSessionID != context.projectSessionID {
                clearTransientResultRows()
            }
            if !preservesTreeIdentity {
                selectedID = nil
                expandedNodeIDs = []
            }
            rebuildRoots()
        }
        if let transientResultProjectSessionID,
           transientResultProjectSessionID != context.projectSessionID {
            clearTransientResultRows()
            rebuildRoots()
        }
        canCopyWholeLayer = false; canPasteLayer = false; acceptedClipboardTypes = []
        self.context = context; self.provider = provider
        error = nil
        guard let provider, context.projectURL != nil else {
            snapshotRoots = nil; rebuildRoots(); busy = false; return
        }
        busy = true
        defer { if captured == revision { busy = false } }
        do {
            let snapshot = try await provider.load(context)
            guard captured == revision, !Task.isCancelled else { return }
            install(snapshot)
        } catch { if captured == revision, !Task.isCancelled, !(error is CancellationError) { self.error = L10n.text(error.localizedDescription) } }
    }
    func perform(_ action: LayerTreeAction) async {
        _ = await performActionAndReturnAssetPath(action)
    }
    private func performActionAndReturnAssetPath(_ action: LayerTreeAction) async -> String? {
        guard let provider, let context, !busy else { return nil }
        if case .saveBackupAsNewGeometry(let nodeID) = action {
            guard let node = roots?.lazy.compactMap({ $0.find(nodeID) }).first,
                  node.sourceClass == "BackupNodeVM", node.backupSummary?.canSaveAsNewGeometry == true,
                  node.backupSummary?.revision != nil,
                  node.backupSummary?.parentGeometryPath != nil,
                  node.backupSummary?.parentGeometryRevision != nil,
                  node.backupSummary?.projectRevision != nil else { return nil }
        }
        let captured = revision
        busy = true; error = nil
        defer { if captured == revision { busy = false } }
        do {
            let snapshot = try await provider.perform(action, context: context)
            guard captured == revision, !Task.isCancelled else { return nil }
            install(snapshot)
            if case .saveBackupAsNewGeometry = action {
                return selectedNode?.assetID
            }
        } catch { if captured == revision, !Task.isCancelled, !(error is CancellationError) { self.error = L10n.text(error.localizedDescription) } }
        return nil
    }
    func select(_ id: String?) async {
        guard !busy else { return }
        if let id, roots?.contains(where: { $0.find(id) != nil }) != true { return }
        selectedID = id
        await perform(.select(id: id))
    }
    func saveBackupAsNewGeometry(_ nodeID: String) async -> String? {
        await performActionAndReturnAssetPath(.saveBackupAsNewGeometry(nodeID: nodeID))
    }
    func setExpanded(_ id: String, expanded: Bool) {
        guard !busy, roots?.contains(where: { $0.find(id) != nil }) == true else { return }
        if expanded { expandedNodeIDs.insert(id) } else { expandedNodeIDs.remove(id) }
    }
    func revealNode(_ id: String) {
        guard let roots, roots.contains(where: { $0.find(id) != nil }) else { return }
        selectedID = id
        for root in roots {
            if let ancestors = root.ancestorIDs(of: id) {
                expandedNodeIDs.formUnion(ancestors)
                return
            }
        }
    }
    func canMove(_ ids: [String], to parentID: String) -> Bool {
        guard !busy, !ids.isEmpty, let roots,
              let target = roots.lazy.compactMap({ $0.find(parentID) }).first, target.canAcceptChildren else { return false }
        return ids.allSatisfy { id in
            guard let node = roots.lazy.compactMap({ $0.find(id) }).first, node.canMove else { return false }
            return node.find(parentID) == nil
        }
    }
    func copyWholeLayer(system: any WorkspaceSystemServices) async {
        guard let provider, let context, canCopyWholeLayer, !busy else { return }
        let captured = revision
        busy = true; error = nil
        defer { if captured == revision { busy = false } }
        do {
            let items = try await provider.copyWholeLayer(context: context)
            guard captured == revision, !Task.isCancelled else { return }
            if !system.writeClipboard(items) { error = L10n.text("Could not copy this layer.") }
        } catch { if captured == revision, !Task.isCancelled, !(error is CancellationError) { self.error = L10n.text(error.localizedDescription) } }
    }
    func pasteLayer(system: any WorkspaceSystemServices) async {
        guard let provider, let context, canPasteLayer, !busy else { return }
        let items = system.readClipboard(types: acceptedClipboardTypes)
        guard !items.isEmpty else { error = L10n.text("Nothing on the clipboard can be pasted into this layer."); return }
        let captured = revision
        busy = true; error = nil
        defer { if captured == revision { busy = false } }
        do {
            let snapshot = try await provider.pasteLayer(items, context: context)
            guard captured == revision, !Task.isCancelled else { return }
            install(snapshot)
        } catch { if captured == revision, !Task.isCancelled, !(error is CancellationError) { self.error = L10n.text(error.localizedDescription) } }
    }
    func invalidate() {
        invalidateTree(preservingTransientResultRowsFor: nil)
    }
    func invalidate(preservingTransientResultRowsFor projectSessionID: UUID) {
        invalidateTree(preservingTransientResultRowsFor: projectSessionID)
    }
    func upsertTransientResultComputeRow(_ entry: WorkspaceResultComputeEntry) {
        guard entry.status == .running || entry.status.isTerminal,
              context?.mode == nil || context?.mode == "Catalog",
              context?.projectSessionID == nil || context?.projectSessionID == entry.projectSessionID else { return }
        if transientResultProjectSessionID != entry.projectSessionID {
            transientResultRowsByPath = [:]
            transientResultProjectSessionID = entry.projectSessionID
        }
        let row = TransientResultComputeRow(entry: entry)
        let isNewPath = transientResultRowsByPath[row.resultPath] == nil
        transientResultRowsByPath[row.resultPath] = row
        rebuildRoots()
        if isNewPath { expandTransientResultAncestors() }
    }
    func markUnconfirmedTransientResultComputeRowsUnknown(projectSessionID: UUID,
        editorID: UUID, operationOwnerToken: String, operationContextID: String) -> [String] {
        let paths = transientResultRowsByPath.compactMap { path, row in
            row.projectSessionID == projectSessionID
                && row.editorID == editorID
                && row.operationOwnerToken == operationOwnerToken
                && row.operationContextID == operationContextID
                && row.status == .running ? path : nil
        }
        for path in paths {
            guard var row = transientResultRowsByPath[path] else { continue }
            row.status = .unknown
            transientResultRowsByPath[path] = row
        }
        if !paths.isEmpty { rebuildRoots() }
        return paths
    }
    private func invalidateTree(preservingTransientResultRowsFor projectSessionID: UUID?) {
        revision += 1; provider = nil; context = nil; snapshotRoots = nil
        selectedID = nil; error = nil; busy = false
        expandedNodeIDs = []
        canCopyWholeLayer = false; canPasteLayer = false; acceptedClipboardTypes = []
        if projectSessionID != transientResultProjectSessionID { clearTransientResultRows() }
        rebuildRoots()
    }
    private func clearTransientResultRows() {
        transientResultRowsByPath = [:]
        transientResultProjectSessionID = nil
    }
    private func install(_ snapshot: LayerTreeSnapshot) {
        let selectedTransientPath = selectedID.flatMap { id in
            roots?.lazy.compactMap { $0.find(id) }.first
                .flatMap { $0.transientResultComputeRunID == nil ? nil : $0.resultComputeSourcePath }
        }
        snapshotRoots = snapshot.roots
        let sourcePaths = TransientResultComputeProjection.materializedResultPaths(in: snapshot.roots)
        transientResultRowsByPath = transientResultRowsByPath.filter { !sourcePaths.contains($0.key) }
        if transientResultRowsByPath.isEmpty { transientResultProjectSessionID = nil }
        rebuildRoots()
        if let expanded = snapshot.expandedNodeIDs { expandedNodeIDs = expanded }
        expandedNodeIDs = Set(expandedNodeIDs.filter { id in (roots ?? []).contains { $0.find(id) != nil } })
        canCopyWholeLayer = snapshot.canCopyWholeLayer; canPasteLayer = snapshot.canPasteLayer; acceptedClipboardTypes = snapshot.acceptedClipboardTypes
        if let selectedTransientPath,
           let materializedNode = findResultNode(path: selectedTransientPath, in: snapshot.roots) {
            selectedID = materializedNode.id
        }
        if let selection = snapshot.selection {
            switch selection { case .node(let id): selectedID = id; case .cleared: selectedID = nil }
        }
        if let selectedID, !(roots ?? []).contains(where: { $0.find(selectedID) != nil }) { self.selectedID = nil }
        expandTransientResultAncestors()
        if let warning = snapshot.operationWarning { error = L10n.text(warning) }
        if let context { didInstall?(snapshot, context) }
    }
    private func rebuildRoots() {
        roots = TransientResultComputeProjection.apply(snapshotRoots: snapshotRoots,
            rows: transientResultRowsByPath,
            projectSessionID: transientResultProjectSessionID ?? context?.projectSessionID)
    }
    private func expandTransientResultAncestors() {
        for row in transientResultRowsByPath.values {
            for root in roots ?? [] {
                if let ancestors = root.ancestorIDs(of: row.node.id) {
                    expandedNodeIDs.formUnion(ancestors)
                    break
                }
            }
        }
    }
    private func findResultNode(path: String, in roots: [LayerTreeNode]) -> LayerTreeNode? {
        let canonicalPath = SourceFilePaths.canonical(URL(fileURLWithPath: path))
        func find(_ node: LayerTreeNode) -> LayerTreeNode? {
            let nodePath = node.resultComputeSourcePath ?? node.assetID
            if ["ObservableResult", "ResultNode", "ResultNodeVM"].contains(node.sourceClass),
               let nodePath,
               SourceFilePaths.canonical(URL(fileURLWithPath: nodePath)) == canonicalPath {
                return node
            }
            return node.children?.lazy.compactMap(find).first
        }
        return roots.lazy.compactMap(find).first
    }
}

struct LayerTreeView: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var session: LayerTreeSession
    var filter: String? = nil
    var body: some View {
        List(selection: Binding(get: { session.selectedID }, set: { id in Task { await session.select(id) } })) {
            ForEach((session.roots ?? []).compactMap { $0.filtered(filter ?? store.filter) }) { node in
                TreeOutlineNode(node: node, session: session, store: store)
            }
        }.listStyle(.sidebar).disabled(session.busy)
            .onKeyPress("c", phases: .down) { press in
                guard press.modifiers.intersection([.command, .control, .option, .shift]) == .command, !store.system.isTextInputActive, session.canCopyWholeLayer else { return .ignored }
                Task { await session.copyWholeLayer(system: store.system) }; return .handled
            }
            .onKeyPress("v", phases: .down) { press in
                guard press.modifiers.intersection([.command, .control, .option, .shift]) == .command, !store.system.isTextInputActive, session.canPasteLayer else { return .ignored }
                Task { await session.pasteLayer(system: store.system) }; return .handled
            }
            .overlay(alignment: .bottom) { if session.busy { ProgressView().controlSize(.small).padding(10).workspaceGlass() } }
            .onChange(of: session.selectedID) { _, _ in
                if let id = session.selectedNode?.assetID, let asset = store.assets.first(where: { $0.id == id }) { store.select(asset, clearTreeSelection: false) }
            }
    }
}
private struct TreeOutlineNode: View {
    let node: LayerTreeNode
    @ObservedObject var session: LayerTreeSession
    @ObservedObject var store: WorkspaceStore
    var body: some View {
        if let children = node.children {
            DisclosureGroup(isExpanded: Binding(get: { session.expandedNodeIDs.contains(node.id) }, set: { session.setExpanded(node.id, expanded: $0) })) {
                ForEach(children) { child in TreeOutlineNode(node: child, session: session, store: store) }
            } label: { LayerTreeRow(node: node, session: session, store: store) }.tag(node.id)
        } else { LayerTreeRow(node: node, session: session, store: store).tag(node.id) }
    }
}
struct LayerTreeRow: View {
    let node: LayerTreeNode
    @ObservedObject var session: LayerTreeSession
    @ObservedObject var store: WorkspaceStore
    @State private var renaming = false
    @State private var name = ""
    @State private var showNewFolder = false
    @State private var folderName = ""
    @State private var pendingMenu: ContextMenuEntry?
    @State private var commandValue = ""
    @State private var pendingValue: ContextMenuValue?
    @State private var pendingMapRemoval: CatalogMapLayerRemovalRequest?
    @State private var geometryBackupPresentation: CatalogGeometryNamedBackupPresentation?
    @FocusState private var editingName: Bool
    private var title: String { node.localizeName ? L10n.text(node.name) : node.name }
    private var modelTarget: CatalogModelActionTarget? {
        CatalogModelActionTarget.resolve(node: node, assets: store.assets)
    }
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: node.symbol).foregroundStyle(.secondary)
            if renaming {
                TextField("Name", text: $name).textFieldStyle(.plain).focused($editingName)
                    .onSubmit { rename() }.onExitCommand { renaming = false }
            } else { Text(title).lineLimit(1) }
            CatalogLayerDiagnosticsRow(node: node, store: store)
            FlowAreaComputeProgressIndicator(node: node, treeSession: session, store: store)
            if ResultComputePresentationPath.applies(to: node.sourceClass) {
                ResultComputeStatusIndicator(node: node, store: store)
            }
            Spacer(minLength: 0)
            if node.canPin {
                Button { Task { await session.perform(.pin(id: node.id, pinned: !node.isPinned)) } } label: { Label(node.isPinned ? "Unpin" : "Pin", systemImage: node.isPinned ? "pin.fill" : "pin") }.labelStyle(.iconOnly).buttonStyle(.borderless)
            }
            visibilityControl
        }.contentShape(Rectangle())
            .onTapGesture(count: 2) {
                if node.sourceClass == "FolderNode", node.canRename { beginRename() }
                else if let id = node.assetID, let asset = store.assets.first(where: { $0.id == id }) { store.edit(asset, fromTree: true) }
            }
            .contextMenu {
                ContextMenuContents(entries: node.contextMenu, invoke: invoke)
                if !node.contextMenu.isEmpty { Divider() }
                if let modelTarget {
                    CatalogModelActionMenuItems(store: store, asset: modelTarget.asset,
                        kind: modelTarget.kind, caller: .projectTree)
                    if modelTarget.kind == .geometry || modelTarget.kind == .plan {
                        Button("Focus", systemImage: "scope") { store.focus(modelTarget.asset) }
                            .disabled(store.isRunningProjectTool || store.isSavingAll)
                    }
                    if modelTarget.kind == .geometry, node.sourceClass == "ObservableGeometry" {
                        Button("Create Named Geometry Backup", systemImage: "plus.square.on.square") {
                            geometryBackupPresentation = CatalogGeometryNamedBackupPresentation(geometry: modelTarget.asset)
                        }
                        .disabled(store.isRunningProjectTool || store.isSavingAll || store.isClosingTab || store.isOpeningProject)
                    }
                    if modelTarget.kind == .terrain {
                        Button("Open Editor", systemImage: "pencil") {
                            store.openEditor(.terrain, assetID: modelTarget.asset.id)
                        }
                        .disabled(store.isRunningProjectTool || store.isSavingAll || store.isClosingTab || store.isOpeningProject)
                    }
                    if modelTarget.kind == .classification {
                        Button("Open Editor", systemImage: "pencil") {
                            store.openEditor(.surface, assetID: modelTarget.asset.id)
                        }
                        .disabled(store.isRunningProjectTool || store.isSavingAll || store.isClosingTab || store.isOpeningProject)
                    }
                    if modelTarget.kind == .terrain {
                        Button("Set as Default Terrain", systemImage: "checkmark.circle") {
                            store.setDefaultTerrain(modelTarget.asset.name)
                        }
                        .disabled(store.isRunningProjectTool || store.isSavingAll
                            || store.document?.defaultTerrain == modelTarget.asset.name)
                    }
                    if modelTarget.kind == .plan {
                        Button("Export Plan…", systemImage: "square.and.arrow.up") {
                            store.select(modelTarget.asset, clearTreeSelection: false)
                            store.activeTool = .planExport
                        }
                        .disabled(store.isRunningProjectTool || store.isSavingAll
                            || store.isClosingTab || store.isOpeningProject)
                    }
                    Divider()
                }
                if let path = CatalogSourceContextRoutes.mapLayerFilePath(for: node) {
                    Divider()
                    Button("Remove from Map", systemImage: "minus.circle", role: .destructive) {
                        requestMapLayerRemoval()
                    }
                    .disabled(store.isRunningProjectTool || store.isSavingAll || store.isOpeningProject || store.isClosingTab)
                    Button("Show in Finder", systemImage: "folder") {
                        store.system.reveal(URL(fileURLWithPath: path))
                    }
                    Button("Copy File Path", systemImage: "doc.on.doc") { store.system.copy(path) }
                } else if let id = node.assetID, let asset = store.assets.first(where: { $0.id == id }) {
                    Button("Edit") { store.edit(asset, fromTree: true) }
                    Button("Show in Finder") { store.system.reveal(asset.url) }
                    Button("Copy File Path") { store.system.copy(asset.url.path) }
                }
                Button("Properties") { Task { await session.select(node.id) }; store.showInspector = true }
                if session.selectedID == node.id {
                    if session.canCopyWholeLayer { Button("Copy Layer") { Task { await session.copyWholeLayer(system: store.system) } } }
                    if session.canPasteLayer { Button("Paste") { Task { await session.pasteLayer(system: store.system) } } }
                }
                if node.canRename { Button("Rename…") { beginRename() } }
                if node.canCreateFolder { Button("New Folder…") { folderName = ""; showNewFolder = true } }
                if node.canPin { Button(node.isPinned ? "Unpin" : "Pin") { Task { await session.perform(.pin(id: node.id, pinned: !node.isPinned)) } } }
            }
            .modifier(TreeDrag(id: node.id, enabled: node.canMove))
            .dropDestination(for: String.self) { ids, _ in
                guard session.canMove(ids, to: node.id) else { return false }
                Task { await session.perform(.move(ids: ids, parentID: node.id)) }; return true
            }
            .alert("New Folder", isPresented: $showNewFolder) {
                TextField("Folder Name", text: $folderName)
                Button("Create") { Task { await session.perform(.newFolder(parentID: node.id, name: folderName)) } }.disabled(folderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Cancel", role: .cancel) {}
            }
            .alert(pendingMenu?.prompt.map { L10n.text($0.title) } ?? pendingMenu?.displayTitle ?? "", isPresented: Binding(get: { pendingMenu != nil }, set: { if !$0 { pendingMenu = nil } })) {
                if let prompt = pendingMenu?.prompt { TextField(L10n.text(prompt.label), text: $commandValue) }
                Button("OK", role: pendingMenu?.destructive == true ? .destructive : nil) {
                    guard let item = pendingMenu else { return }
                    let value: ContextMenuValue? = item.prompt != nil ? .text(commandValue) : pendingValue
                    pendingMenu = nil; execute(item, value)
                }.disabled(pendingMenu?.prompt?.allowsEmpty == false && commandValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Cancel", role: .cancel) { pendingMenu = nil }
            } message: { Text(pendingMenu?.prompt.map { L10n.text($0.message) } ?? pendingMenu?.confirmation.map(L10n.text) ?? "") }
            .confirmationDialog("Remove this source from the map?", isPresented: Binding(
                get: { pendingMapRemoval != nil }, set: { if !$0 { pendingMapRemoval = nil } }), titleVisibility: .visible) {
                Button("Remove from Map", role: .destructive) { confirmMapLayerRemoval() }
                Button("Cancel", role: .cancel) { pendingMapRemoval = nil }
            } message: {
                if let pendingMapRemoval { Text(pendingMapRemoval.displayName) }
            }
            .sheet(item: $geometryBackupPresentation) { presentation in
                GeometryNamedBackupSheet(store: store, geometry: presentation.geometry)
            }
    }
    private func requestMapLayerRemoval() {
        guard let context = session.activeContext,
              context.projectSessionID == store.projectSessionID,
              context.mapID == store.lastActiveMapID,
              let request = CatalogMapLayerRemovalRequest(node: node, context: context) else { return }
        pendingMapRemoval = request
    }
    private func confirmMapLayerRemoval() {
        guard let request = pendingMapRemoval else { return }
        pendingMapRemoval = nil
        guard request.matches(session.node(withID: request.nodeID),
                activeContext: session.activeContext,
                projectSessionID: store.projectSessionID,
                activeMapID: store.lastActiveMapID),
              let currentNode = session.node(withID: request.nodeID) else { return }
        Task { _ = await store.removeMapSourceNode(currentNode, mapID: request.context.mapID) }
    }
    private func checkBindings(_ state: LayerTreeNode.CheckState) -> [Binding<Bool>] {
        let mapContext = session.activeContext
        return (state == .mixed ? [true, false] : [state == .checked]).map { value in
            Binding(get: { value }, set: { checked in
                if let mapContext {
                    _ = FlowAreaMapGenerationVisibility.clearLocalVisibilityOverride(node: node,
                        mapID: mapContext.mapID, projectSessionID: mapContext.projectSessionID, store: store)
                }
                Task { await session.perform(.visibility(id: node.id, checked: checked)) }
            })
        }
    }
    private func displayedVisibilityState(for checked: LayerTreeNode.CheckState) -> LayerTreeNode.CheckState {
        guard let context = session.activeContext,
              FlowAreaMapGenerationVisibility.hasLocalVisibilityOverride(node: node,
                  mapID: context.mapID, projectSessionID: context.projectSessionID, store: store) else {
            return checked
        }
        return .checked
    }
    @ViewBuilder private var visibilityControl: some View {
        if isTransientTerrainInput {
            if let context = session.activeContext,
               context.projectSessionID == store.projectSessionID,
               let mapState = store.existingMapState(for: context.mapID) {
                let workflowIdentity = store.mapSourceWorkflowIdentity(context.mapID)
                TerrainInputVisibilityToggle(node: node, mapID: context.mapID,
                    projectSessionID: context.projectSessionID,
                    mapSession: mapState.terrainInputMap,
                    isCurrent: {
                        session.activeContext == context
                            && store.projectSessionID == context.projectSessionID
                            && store.existingMapState(for: context.mapID) === mapState
                            && store.mapSourceWorkflowIdentity(context.mapID) == workflowIdentity
                    },
                    setVisibility: { checked in
                        Task { _ = await store.setSourceMapVisibility(node, checked: checked, mapID: context.mapID) }
                    })
            } else {
                Toggle("Visible", isOn: .constant(false)).toggleStyle(.checkbox).labelsHidden().disabled(true)
            }
        } else if let mesh = activeFlowAreaGenerationSession {
            Toggle("Visible", isOn: .constant(false)).toggleStyle(.checkbox).labelsHidden().disabled(true)
                .accessibilityValue(L10n.text(mesh.isCancellingMeshGeneration
                    ? "Cancelling mesh generation" : "Generating mesh"))
        } else if let checked = node.checked {
            let displayedState = displayedVisibilityState(for: checked)
            Toggle("Visible", sources: checkBindings(displayedState), isOn: \.self)
                .toggleStyle(.checkbox).labelsHidden()
        }
    }
    private var activeFlowAreaGenerationSession: GeometryMeshSession? {
        guard node.sourceClass == "FlowAreaLayerVisualContext",
              let context = session.activeContext,
              context.projectSessionID == store.projectSessionID else { return nil }
        let locator = node.sourceLocator
        let geometryPath: String?
        if let parentPath = locator?.parentGeometryAssetID {
            geometryPath = parentPath
        } else {
            var paths = Set<String>()
            for root in session.roots ?? [] {
                guard let ancestorIDs = root.ancestorIDs(of: node.id) else { continue }
                for ancestorID in ancestorIDs {
                    guard let ancestor = root.find(ancestorID),
                          ancestor.catalogSummaryKind == .geometry,
                          let assetID = ancestor.assetID else { continue }
                    paths.insert(SourceFilePaths.canonical(URL(fileURLWithPath: assetID)))
                }
            }
            geometryPath = paths.count == 1 ? paths.first : nil
        }
        guard let geometryPath else { return nil }
        return FlowAreaMapGenerationVisibility.activeSession(geometryPath: geometryPath,
            parentNodePath: locator?.parentGeometryNodePath,
            parentNodeName: locator?.parentGeometryNodeName,
            mapID: context.mapID, projectSessionID: context.projectSessionID, store: store)
    }
    private var isTransientTerrainInput: Bool {
        node.id.hasPrefix("terrain-input:") && [
            "ChannelModTerrainInputParentVC", "LeveeModTerrainInputVC",
            "PolygonRasterModTerrainInputVisualContext"
        ].contains(node.sourceClass)
    }
    private func beginRename() { name = node.name; renaming = true; editingName = true }
    private func invoke(_ item: ContextMenuEntry, _ value: ContextMenuValue?) {
        guard item.enabled else { return }
        if item.prompt != nil || item.confirmation != nil {
            commandValue = item.prompt?.initialValue ?? ""; pendingValue = value; pendingMenu = item
        } else { execute(item, value) }
    }
    private func execute(_ item: ContextMenuEntry, _ value: ContextMenuValue?) {
        Task { await session.perform(.contextCommand(nodeID: node.id, commandID: item.id, value: value)) }
    }
    private func rename() {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        renaming = false
        if name != node.name { Task { await session.perform(.rename(id: node.id, name: name)) } }
    }
}

private struct TreeDrag: ViewModifier {
    let id: String
    let enabled: Bool
    func body(content: Content) -> some View {
        if enabled { content.draggable(id) } else { content }
    }
}
