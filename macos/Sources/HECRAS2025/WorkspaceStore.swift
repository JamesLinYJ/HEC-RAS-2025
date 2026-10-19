import AppKit
import Combine
import CryptoKit
import Foundation
import RASWorkspaceCore

enum TreeMode: String, CaseIterable, Identifiable {
    case project = "Project", geometry = "Geometry", plan = "Plan"
    var id: String { rawValue }
}
enum InspectorMode: String, CaseIterable, Identifiable {
    case properties = "Properties", components = "Components"
    var id: String { rawValue }
}
enum WorkspaceSidebarKind: String, CaseIterable, Identifiable {
    case catalog = "Catalog", projectTree = "Project Tree"
    var id: String { rawValue }
}
enum WorkspacePage: String, CaseIterable, Identifiable {
    case map = "Map", associations = "Associations", project = "Project"
    var id: String { rawValue }
    var symbol: String {
        switch self { case .map: "map"; case .associations: "point.3.connected.trianglepath.dotted"; case .project: "doc.text" }
    }
}
enum WorkspaceTab: Hashable {
    case page(WorkspacePage)
    case editor(ModelEditorKind)
    case map(UUID)
    case chat
    case chatDisplay(UUID)
}
struct MapDocument: Identifiable {
    enum Kind: Equatable {
        case project, buildable, plan, geometry, unsupported

        init(sourceType: String?) {
            switch sourceType {
            case "Project": self = .project
            case "Buildable": self = .buildable
            case "Plan": self = .plan
            case "Geometry": self = .geometry
            default: self = .unsupported
            }
        }

        var defaultSourceType: String? {
            switch self {
            case .project: "Project"
            case .buildable: "Buildable"
            case .plan: "Plan"
            case .geometry: "Geometry"
            case .unsupported: nil
            }
        }
    }
    let id: UUID
    var name: String
    var kind: Kind
    var sourceType: String? = nil

    init(id: UUID = UUID(), name: String, kind: Kind, sourceType: String? = nil) {
        self.id = id; self.name = name; self.kind = kind; self.sourceType = sourceType
    }
}

struct ProjectMigrationPresentation: Identifiable {
    let id = UUID()
    let sourceURL: URL
    let authorizedSourceDirectory: URL
}

@MainActor
struct MapResultSourceSetupFlight {
    let requestIdentity: String
    let token: UUID
    let task: Task<Void, Never>
}

@MainActor
final class MapResultSourceSetupCoordinator {
    private var flights: [UUID: MapResultSourceSetupFlight] = [:]

    func flight(for mapID: UUID) -> MapResultSourceSetupFlight? { flights[mapID] }

    func replace(_ flight: MapResultSourceSetupFlight, for mapID: UUID) {
        flights[mapID]?.task.cancel()
        flights[mapID] = flight
    }

    func finish(mapID: UUID, token: UUID) {
        guard flights[mapID]?.token == token else { return }
        flights.removeValue(forKey: mapID)
    }

    func cancel(mapID: UUID) {
        flights.removeValue(forKey: mapID)?.task.cancel()
    }
}

@MainActor
final class WorkspaceStore: ObservableObject {
    @Published private(set) var document: ProjectDocument?
    @Published private(set) var openingProject: ProjectOpening?
    private var projectOpenTask: Task<Void, Never>?
    private var projectOpenRevision = 0
    private var projectOpenLockLease: WorkspaceProjectOpenLock.Lease?
    private var projectOpenLockURL: URL?
    var isOpeningProject: Bool { openingProject != nil }
    @Published private(set) var assetsRevision = 0 {
        didSet {
            guard oldValue != assetsRevision else { return }
            refreshDynamicProfileWindowsForAssetRevision()
        }
    }
    @Published private(set) var assets: [ProjectAsset] = [] {
        didSet {
            assetsRevision += 1
        }
    }
    @Published private(set) var isModified = false
    @Published private(set) var messages: [WorkspaceMessage] = []
    @Published private(set) var attributeTableSessions: [UUID: AttributeTableSession] = [:]
    let attributeTableProvider: (any AttributeTableProvider)?
    func registerAttributeTable(_ session: AttributeTableSession) { attributeTableSessions[session.id] = session }
    func unregisterAttributeTable(_ session: AttributeTableSession) { attributeTableSessions.removeValue(forKey: session.id) }
    @Published private(set) var recentProjectHistory: [RecentProjectRecord] = []
    var recentProjects: [URL] { recentProjectHistory.map(\.url) }
    @Published private(set) var mapLayers: [MapVectorLayer] = []
    @Published private(set) var isMapLoading = false
    @Published var sourceMapVectorLoadStates: [UUID: MapVectorLoadState] = [:]
    var sourceMapVectorLoadTasks: [UUID: Task<Void, Never>] = [:]
    @Published private(set) var sourceMapVectorFamilyCaptures: [UUID: [String: MapSourceFamilyCapture]] = [:]
    private var mapLoadRevision = 0
    private var mapLoadTask: Task<Void, Never>?
    @Published var rasterLayers: [MapRasterLayer] = [] { didSet { rasterRevision += 1 } }
    @Published private(set) var rasterRevision = 0
    @Published private(set) var rasterMapSources: [RasterMapSourceDescriptor] = []
    @Published private(set) var rasterMapSourceInfoStats: [String: RasterImportContextSource] = [:]
    @Published private(set) var isRasterMapLoading = false
    private var visualizationMapIDs: [Int: UUID] = [:]
    private var visualizationMapIdentities: [Int: VisualizationMapIdentity] = [:]
    private var rasterMapLoadTask: Task<Void, Never>?
    private var rasterMapLoadRevision = 0
    var rasterMapSourcesForActiveMap: [RasterMapSourceDescriptor] {
        rasterMapSources.filter { $0.sourceMapID == lastActiveMapID }
    }
    @Published var mapLegends: [MapLegend] = []
    @Published private(set) var projectSessionID = UUID()
    private var mapStates: [UUID: MapState] = [:]
    private var mapStateSubscriptions: [UUID: AnyCancellable] = [:]
    private var mapMeshErrorSourceSubscriptions: [UUID: AnyCancellable] = [:]
    private var mapBackgroundSettingsSubscriptions: [UUID: AnyCancellable] = [:]
    private var isInstallingBackgroundSettings = false
    private var pendingBackgroundMapSettings: [UUID: (projectSessionID: UUID, settings: BackgroundMapSettings)] = [:]
    private var mapSelectedLayerSubscriptions: [UUID: AnyCancellable] = [:]
    private var mapLineSelectionSubscriptions: [UUID: AnyCancellable] = [:]
    private var mapEditingLineSubscriptions: [UUID: AnyCancellable] = [:]
    private var mapDynamicProfileSourceSubscriptions: [UUID: AnyCancellable] = [:]
    private var mapDynamicProfileSelectionSubscriptions: [UUID: AnyCancellable] = [:]
    let mapResultSourceSetupCoordinator = MapResultSourceSetupCoordinator()
    @Published private(set) var mapChartSessions: [UUID: MapResultChartSession] = [:]
    @Published private(set) var mapDynamicProfileWindows: [UUID: MapDynamicProfileWindowSession] = [:]
    var dynamicProfileBackendClient: BackendProcessClient? {
        (modelProvider as? BackendModelProvider)?.client
    }
    func registerMapChart(_ session: MapResultChartSession) -> UUID {
        let id = UUID(); mapChartSessions[id] = session; return id
    }
    func unregisterMapChart(_ id: UUID) { mapChartSessions.removeValue(forKey: id)?.close() }
    func invalidateMapCharts(mapID: UUID) {
        for session in mapChartSessions.values where session.context.mapID == mapID { session.invalidate() }
    }
    func registerMapDynamicProfileWindow(_ session: MapDynamicProfileWindowSession) -> UUID {
        mapDynamicProfileWindows[session.id] = session
        return session.id
    }
    func unregisterMapDynamicProfileWindow(_ id: UUID) {
        mapDynamicProfileWindows.removeValue(forKey: id)?.close()
    }
    private func refreshDynamicProfileWindowsForAssetRevision() {
        let projectSession = projectSessionID
        let mapIDs = Set(mapDynamicProfileWindows.values.filter(\.isValid).map(\.mapID))
        guard !mapIDs.isEmpty else { return }
        Task { @MainActor [weak self] in
            guard let self, self.projectSessionID == projectSession else { return }
            for mapID in mapIDs {
                guard self.projectSessionID == projectSession,
                      self.mapDynamicProfileWindows.values.contains(where: {
                          $0.mapID == mapID && $0.isValid
                      }) else { continue }
                self.rebindMapDynamicProfileSources(mapID: mapID)
                await self.configureMapResultSources(mapID)
            }
        }
    }
    func invalidateMapDynamicProfiles(mapID: UUID, reason: String? = nil) {
        for session in mapDynamicProfileWindows.values where session.mapID == mapID {
            session.invalidate(reason: reason ?? L10n.text("The selected map, result source, or polyline changed."))
        }
    }

    /// Result visibility and MultiResult slot changes replace only the chart's
    /// source snapshot. Keep the detached window when its exact map-line
    /// capture still belongs to this same project/map, then resample against
    /// the newly configured source context.
    func rebindMapDynamicProfileSources(mapID: UUID) {
        guard let state = existingMapState(for: mapID) else {
            invalidateMapDynamicProfiles(mapID: mapID)
            return
        }
        for session in mapDynamicProfileWindows.values where session.mapID == mapID && session.isValid {
            let generation = session.beginSourceRebind()
            let task = Task { @MainActor [weak self, weak state, weak session] in
                guard let self, let state, let session else { return }
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(100)) }
                    catch { return }
                    guard !Task.isCancelled, session.isCurrentSourceRebind(generation),
                          self.mapDynamicProfileWindows[session.id] === session else { return }
                    guard session.mapState === state,
                          self.isCurrentMapState(state, mapID: mapID,
                            projectSessionID: session.projectSessionID) else {
                        session.invalidate(reason: L10n.text("The project source context changed."))
                        return
                    }
                    guard let context = try? self.mapLineContext(mapID: mapID,
                            editingSelection: session.editingSelection),
                          session.matchesStableMapLine(projectSessionID: self.projectSessionID,
                              mapID: mapID, context: context,
                              editingSelection: session.editingSelection) else {
                        session.invalidate(reason: L10n.text("The selected map, result source, or polyline changed."))
                        return
                    }
                    if self.isRunningPlanCompute || state.resultSources.isLoading
                        || state.resultSources.isSelecting { continue }
                    if state.resultSources.isStale {
                        await self.configureMapResultSources(mapID)
                        guard !Task.isCancelled, session.isCurrentSourceRebind(generation) else { return }
                        if !self.isRunningPlanCompute && !state.resultSources.isLoading
                            && !state.resultSources.isSelecting && state.resultSources.isStale {
                            session.invalidate(reason: L10n.text("The selected map, result source, or polyline changed."))
                            return
                        }
                        continue
                    }
                    guard let snapshot = state.resultSources.snapshot else {
                        if state.resultSources.errorMessage != nil {
                            session.invalidate(reason: L10n.text("The selected map, result source, or polyline changed."))
                            return
                        }
                        await self.configureMapResultSources(mapID)
                        guard !Task.isCancelled, session.isCurrentSourceRebind(generation) else { return }
                        if !self.isRunningPlanCompute && !state.resultSources.isLoading
                            && !state.resultSources.isSelecting && state.resultSources.snapshot == nil {
                            session.invalidate(reason: L10n.text("The selected map, result source, or polyline changed."))
                            return
                        }
                        continue
                    }
                    let mapIdentity = self.mapWorkflowIdentity(mapID)
                    guard snapshot.map == context.mapRequest,
                          snapshot.identity == mapIdentity,
                          state.resultSources.snapshot == snapshot else {
                        await self.configureMapResultSources(mapID)
                        guard !Task.isCancelled, session.isCurrentSourceRebind(generation) else { return }
                        if !self.isRunningPlanCompute && !state.resultSources.isLoading
                            && !state.resultSources.isSelecting {
                            guard let latestContext = try? self.mapLineContext(mapID: mapID,
                                      editingSelection: session.editingSelection),
                                  session.matchesStableMapLine(projectSessionID: self.projectSessionID,
                                      mapID: mapID, context: latestContext,
                                      editingSelection: session.editingSelection),
                                  let latestSnapshot = state.resultSources.snapshot,
                                  latestSnapshot.map == latestContext.mapRequest,
                                  latestSnapshot.identity == self.mapWorkflowIdentity(mapID) else {
                                session.invalidate(reason: L10n.text("The selected map, result source, or polyline changed."))
                                return
                            }
                        }
                        continue
                    }
                    self.configureMapResultRendering(mapID)
                    let sourceIdentity = self.mapSourceWorkflowIdentity(mapID)
                    guard state.resultSourceIdentity == sourceIdentity else {
                        await self.configureMapResultSources(mapID)
                        guard !Task.isCancelled, session.isCurrentSourceRebind(generation) else { return }
                        if !self.isRunningPlanCompute && !state.resultSources.isLoading
                            && !state.resultSources.isSelecting,
                           state.resultSourceIdentity != self.mapSourceWorkflowIdentity(mapID) {
                            session.invalidate(reason: L10n.text("The selected map, result source, or polyline changed."))
                            return
                        }
                        continue
                    }
                    guard session.rebindSourceContext(projectSessionID: self.projectSessionID,
                            mapID: mapID, context: context, sources: snapshot,
                            sourceWorkflowIdentity: sourceIdentity,
                            mapWorkflowIdentity: mapIdentity) else { return }
                    return
                }
            }
            session.installSourceRebindTask(task, generation: generation)
        }
    }

    func isCurrentMapDynamicProfileWindow(_ session: MapDynamicProfileWindowSession,
                                          state: MapState) -> Bool {
        guard session.isValid,
              session.mapState === state,
              isCurrentMapState(state, mapID: session.mapID,
                  projectSessionID: session.projectSessionID),
              let context = try? mapLineContext(mapID: session.mapID,
                  editingSelection: session.editingSelection) else { return false }
        return session.matchesStableMapLine(projectSessionID: projectSessionID,
            mapID: session.mapID, context: context,
            editingSelection: session.editingSelection)
    }
    @Published private(set) var lastActiveMapID = MapState.projectMapID
    var activeMapState: MapState { mapState(for: lastActiveMapID) }
    var activeMapToolID: String {
        get { activeMapState.toolID }
        set { activeMapState.toolID = newValue }
    }
    private var pendingMapInputs: [MapInput] = []
    private var handlingMapInputs = false
    private var mapInputTask: Task<Void, Never>?
    var hiddenMapLayers: Set<String> {
        get { activeMapState.hiddenLayers }
        set { activeMapState.hiddenLayers = newValue }
    }
    @Published var selectedFeatureID: Int?
    @Published var descriptionDraft = ""
    @Published var treeMode = TreeMode.project
    @Published var inspectorMode = InspectorMode.properties
    @Published var activeTab = WorkspaceTab.page(.map) {
        didSet {
            if case .map(let id) = activeTab { lastActiveMapID = id }
            else if activeTab == .page(.map) { lastActiveMapID = MapState.projectMapID }
        }
    }
    @Published var openEditors: [ModelEditorKind] = []
    @Published private(set) var editorAssetRequests: [ModelEditorKind: String] = [:]
    @Published var pendingPlanDiagnosticNavigation: PlanDiagnosticNavigationRequest?
    @Published private(set) var editorToolPresentationRequest: EditorToolPresentationRequest?
    @Published var chatIsOpen = false
    @Published private(set) var chatSession = ChatSession()
    @Published private(set) var chatDisplayDocuments: [ChatDisplayDocument] = []
    private var chatDisplayCache: [UUID: ChatDisplayDocument] = [:]
    @Published var mapDocuments: [MapDocument] = []
    private var mapDocumentNames: [UUID: String] = [:]
    private var nextMapNumber = 1
    var page: WorkspacePage {
        get { if case .page(let page) = activeTab { return page }; return .map }
        set { activeTab = .page(newValue) }
    }
    @Published var selectedAssetID: String?
    @Published var selectedSection: ProjectSection?
    @Published var filter = ""
    @Published var sidebarSection = WorkspaceSidebarKind.catalog
    @Published var catalogFilter = ""
    @Published var showProjectTree = true
    @Published var showInspector = true
    @Published var showMessages = false
    @Published var isDebugMode = false
    @Published var enhancedMeshChecks = false
    @Published var partialMeshRecomplete = false
    @Published var forceInternalMatrixSolver = false
    var showGrid: Bool {
        get { activeMapState.showGrid }
        set { activeMapState.showGrid = newValue }
    }
    var showMinimap: Bool {
        get { activeMapState.showMinimap }
        set { activeMapState.showMinimap = newValue }
    }
    var showLegend: Bool {
        get { activeMapState.showLegend }
        set { activeMapState.showLegend = newValue }
    }
    @Published var showNewProject = false
    @Published var projectMigration: ProjectMigrationPresentation?
    private var pendingMigratedProjectURL: URL?
    @Published var showProjection = false
    @Published var showSearch = false
    @Published var showConnectionManager = false
    @Published var showConnectionEditor = false
    @Published var activeTool: ToolKind? {
        didSet {
            if activeTool != .reportIssue { reportIssueFromCrash = false }
            if activeTool != .addAttribute && activeTool != .renameAttribute { activeAttributeToolContext = nil }
            if activeTool != .spatialImport && activeTool != .griddedImport {
                activeSpatialImportLayerID = nil; activeSpatialImportEditorID = nil
            }
        }
    }
    @Published private(set) var reportIssueFromCrash = false
    func requestReportIssue(fromCrash: Bool = false) {
        reportIssueFromCrash = fromCrash
        activeTool = .reportIssue
    }
    @Published private(set) var activeSpatialImportLayerID: String?
    @Published private(set) var activeSpatialImportEditorID: UUID?
    func startSpatialImport(layerID: String, assetID: String?, tool: ToolKind, editorID: UUID? = nil) {
        guard tool == .spatialImport || tool == .griddedImport,
              let asset = assets.first(where: { $0.id == assetID }), asset.section == .boundaryConditions else { return }
        let ownerID = editorID ?? primaryEditorIDs[.boundaryCondition]
        if let ownerID {
            guard let editor = editorSessions[ownerID], editor.modelAssetID == asset.id else { return }
        }
        select(asset)
        activeSpatialImportLayerID = layerID; activeSpatialImportEditorID = ownerID; activeTool = tool
    }
    func spatialImportEditorSession(assetID: String) -> ModelEditorSession? {
        guard let id = activeSpatialImportEditorID, let session = editorSessions[id],
              session.modelAssetID == assetID else { return nil }
        return session
    }
    func performCumulusGridImport(session: ModelEditorSession, assetID: String, mapID: UUID,
                                 selection: CumulusGridImportSelection,
                                 progress: @escaping @MainActor (BackendProgressUpdate) -> Void) async -> Bool {
        guard editorSessions[session.id] === session, session.modelAssetID == assetID,
              activeSpatialImportEditorID == session.id, activeSpatialImportLayerID == selection.layerId,
              activeTool == .griddedImport, !isRunningProjectTool, !isOpeningProject,
              !isSavingAll, !isClosingTab, !session.isBusy,
              assets.contains(where: { $0.id == assetID && $0.section == .boundaryConditions }),
              existingMapState(for: mapID) != nil || mapID == MapState.projectMapID else { return false }
        let origin = projectSessionID
        cumulusGridImportOwnerID = session.id; isRunningCumulusGridImport = true
        defer {
            if origin == projectSessionID {
                isRunningCumulusGridImport = false; cumulusGridImportOwnerID = nil
            }
        }
        let saved = await session.importCumulusGrid(selection, progress: { [weak self, weak session] update in
            guard let self, let session, self.projectSessionID == origin,
                  self.editorSessions[session.id] === session else { return }
            progress(update)
        })
        guard projectSessionID == origin, editorSessions[session.id] === session,
              session.modelAssetID == assetID else { return false }
        if !saved, let error = session.error { errorMessage = error }
        return saved
    }
    @Published var activeAttributeToolContext: AttributeToolContext?
    @Published var showProjectLibrary = false
    private var pendingLibraryProjectURL: URL?
    func requestOpenFromLibrary(_ url: URL) {
        pendingLibraryProjectURL = url; showProjectLibrary = false
    }
    func finishLibraryPresentation() {
        guard let url = pendingLibraryProjectURL else { return }
        pendingLibraryProjectURL = nil; requestOpen(url)
    }
    @Published var showJobs = false
    @Published var showUpdates = false
    @Published var updateInitialChannel = "Beta"
    @Published var showDeveloperTools = false
    var developerProvider: (any DeveloperProvider)?
    var testingProvider: (any TestingProvider)?
    var testingUploadProvider: (any TestingUploadProvider)?
    var updateProvider: (any UpdateProvider)?
    var externalRecordProvider: (any ExternalRecordProvider)?
    var layerTreeProvider: (any LayerTreeProvider)?
    let layerTreeSession = LayerTreeSession()
    var catalogTreeProvider: (any LayerTreeProvider)?
    let catalogTreeSession = LayerTreeSession()
    private var catalogTreeSubscription: AnyCancellable?
    var inspectorTreeSession: LayerTreeSession { sidebarSection == .catalog ? catalogTreeSession : layerTreeSession }
    private var treeProjectRevision: String {
        let mapData = catalogMapDocuments
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let encodedMaps = (try? encoder.encode(mapData)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        return (document?.editorXML(overridingDescription: descriptionDraft) ?? "") + "\n" + encodedMaps
    }
    var catalogMapDocuments: [CatalogMapDocument] {
        let persisted = visualizationMapIdentities.keys.sorted().compactMap { index -> CatalogMapDocument? in
            guard let map = visualizationMapIdentities[index], let id = visualizationMapIDs[index] else { return nil }
            return CatalogMapDocument(id: id.uuidString, name: map.name, kind: map.type,
                sourceIndex: index, visualizationRevision: visualization?.sourceRevision)
        }
        let ids = Set(persisted.map(\.id))
        return persisted + mapDocuments.filter { !ids.contains($0.id.uuidString) }.map {
            CatalogMapDocument(id: $0.id.uuidString, name: $0.name,
                kind: $0.sourceType ?? $0.kind.defaultSourceType ?? "Unsupported")
        }
    }
    var catalogTreeContext: LayerTreeContext {
        LayerTreeContext(projectSessionID: projectSessionID, projectURL: document?.url, mapID: MapState.projectMapID, mode: "Catalog", focusedGeometryIDs: [], focusedPlanIDs: [], projectRevision: treeProjectRevision, assetsRevision: assetsRevision)
    }
    private var layerTreeSubscription: AnyCancellable?
    var layerTreeContext: LayerTreeContext {
        LayerTreeContext(projectSessionID: projectSessionID, projectURL: document?.url, mapID: lastActiveMapID, mode: treeMode.rawValue,
            focusedGeometryIDs: focusedGeometryIDs.sorted(), focusedPlanIDs: focusedPlanIDs.sorted(), projectRevision: treeProjectRevision, assetsRevision: assetsRevision)
    }
    /// A MultiResult owns a current project Plan even when it is placed
    /// directly in a Geometry/Project map rather than beneath a Plan row.
    /// Embedded Result descendants cannot be substituted for that owner.
    static func exactPlanOwnerForResultGroup(_ node: CatalogTreeNodeLocator)
        -> (assetID: String, name: String)? {
        guard node.nodeType == "MultiResult",
              node.parentResultNodeType == nil, node.parentResultAssetID == nil,
              node.parentResultNodePath == nil, node.parentResultNodeName == nil,
              node.parentResultRevision == nil else { return nil }
        let hasParent = node.parentPlanAssetID != nil || node.parentPlanNodePath != nil
            || node.parentPlanNodeName != nil
        if hasParent {
            guard let asset = node.parentPlanAssetID, !asset.isEmpty,
                  let name = node.parentPlanNodeName, !name.isEmpty else { return nil }
            return (SourceFilePaths.canonical(URL(fileURLWithPath: asset)), name)
        }
        guard let asset = node.assetID, !asset.isEmpty, !node.nodeName.isEmpty else { return nil }
        return (SourceFilePaths.canonical(URL(fileURLWithPath: asset)), node.nodeName)
    }

    func sourceMapTreeContext(_ mapID: UUID) -> LayerTreeContext {
        let state = mapState(for: mapID)
        var resultOverrides: [MapTreeResultSelectionOverride] = []
        var resultError: String?
        if let snapshot = state.resultSources.snapshot {
            var byPlan: [String: MapTreeResultSelectionOverride] = [:]
            for active in snapshot.sources.activeNodes where active.nodeKind == "MultiResult" {
                guard let slot = active.selections.first(where: { $0.selectionIndex == 0 }) else { continue }
                let current = snapshot.selectionOverrides.first(where: {
                    $0.nodeIdentity == active.id && $0.selectionIndex == 0
                })
                let mode = current?.mode ?? slot.selectionMode
                // The source-valid default Latest is deliberately omitted so
                // Host and retained MapTree use their own exact default. A
                // Previous/Explicit choice must be supplied by identity so
                // embedded Geometry and Boundary children follow the same
                // slot-zero Result as the chart source panel.
                guard mode != .latest else { continue }
                guard let choice = slot.selectedResult,
                      let planOwner = Self.exactPlanOwnerForResultGroup(active.node) else {
                    resultError = "The selected Result context cannot be matched to its exact Plan owner."
                    break
                }
                if mode == .explicit {
                    guard let path = current?.resultPath, let revision = current?.resultRevision,
                          SourceFilePaths.canonical(URL(fileURLWithPath: path))
                            == SourceFilePaths.canonical(URL(fileURLWithPath: choice.resultPath)),
                          revision.caseInsensitiveCompare(choice.revision) == .orderedSame else {
                        resultError = "The selected Result context no longer matches its exact source revision."
                        break
                    }
                }
                let override = MapTreeResultSelectionOverride(
                    planAssetID: planOwner.assetID,
                    planName: planOwner.name,
                    selectedResultPath: SourceFilePaths.canonical(URL(fileURLWithPath: choice.resultPath)),
                    selectedResultRevision: choice.revision.uppercased())
                let key = override.planAssetID + "|" + override.planName
                if let previous = byPlan[key], previous != override {
                    resultError = "The selected Result context has conflicting choices for one Plan owner."
                    break
                }
                byPlan[key] = override
            }
            resultOverrides = byPlan.values.sorted {
                ($0.planAssetID, $0.planName) < ($1.planAssetID, $1.planName)
            }
        } else if state.resultSelectionOverrides.contains(where: { $0.mode != .latest }) {
            // A Boundary-only retry may run while Result source metadata is
            // being reloaded. Never let a missing snapshot silently turn a
            // selected Previous/Explicit Result back into the source Latest.
            resultError = "The selected Result source context is no longer available."
        }
        return .init(projectSessionID: projectSessionID, projectURL: document?.url, mapID: mapID,
            mode: "Project", focusedGeometryIDs: [], focusedPlanIDs: [],
            projectRevision: treeProjectRevision, assetsRevision: assetsRevision,
            resultSelectionOverrides: resultOverrides, resultSelectionError: resultError)
    }
    var terrainDownloadProvider: (any TerrainDownloadProvider)?
    var rasterSymbologyProvider: (any RasterSymbologyProvider)?
    var vectorSymbologyProvider: (any VectorSymbologyProvider)?
    let globalVectorStylePreferences: GlobalVectorStylePreferences
    @Published private(set) var vectorStyleRevision: UInt64 = 0
    @Published private(set) var vectorSymbologyContextRevision: UInt64 = 0
    private var vectorStyleNodes: [UUID: [LayerTreeNode]] = [:]
    private var boundaryVectorStyleContexts: [String: BoundaryLineVisualContext] = [:]
    private struct SpecializedStyleCacheKey: Hashable {
        let projectSessionID: UUID
        let mapID: UUID
        let owner: SpecializedVectorVisualNodeIdentity
    }
    private struct SpecializedStyleCacheEntry {
        let settings: VectorVisualSettingsSnapshot
        let defaults: [String: VectorStyleValues]
    }
    private var specializedVectorStyleCache: [SpecializedStyleCacheKey: SpecializedStyleCacheEntry] = [:]
    let globalSymbologySession = VectorSymbologySession()
    let globalSymbologySessionID = UUID()
    var featureQueryProvider: (any FeatureQueryProvider)?
    @Published var showZoomLocation = false
    @Published var showSavedViews = false
    @Published private(set) var savedViews: [SavedMapView] = []
    private var visualization: VisualizationDocument?
    var canEditSavedViews: Bool { visualization != nil }
    var requestedViewport: ViewportRequest? {
        get { activeMapState.viewport }
        set { activeMapState.viewport = newValue }
    }
    @Published var jobs: [Job] = []
    @Published private(set) var pendingJobActions: Set<String> = []
    @Published var showDiscardConfirmation = false
    @Published var errorMessage: String?
    @Published var mapRevision = 0
    @Published private(set) var mapHistoryAvailability: [UUID: MapHistoryAvailability] = [:]
    @Published var theme = "System"
    @Published private(set) var isFirstLaunch = true
    @Published private(set) var projectDirectory = PlatformPaths.defaultProjectDirectory
    @Published private(set) var temporaryDirectory = PlatformPaths.temporaryDirectory
    @Published var interfaceLanguage = "System"
    var interfaceLocale: Locale { interfaceLanguage == "System" ? .current : Locale(identifier: interfaceLanguage) }
    @Published var pathMappings: [PathMapping] = []
    private var pendingAction: (() -> Void)?
    private var editorSessions: [UUID: ModelEditorSession] = [:]
    private var primaryEditorIDs: [ModelEditorKind: UUID] = [:]
    private var editorSubscriptions: [UUID: AnyCancellable] = [:]
    @Published private(set) var isSavingAll = false
    @Published private(set) var isRunningBackendTool = false
    @Published private(set) var isRunningLibraryImport = false
    @Published private(set) var isRunningCumulusGridImport = false
    private var cumulusGridImportOwnerID: UUID?
    @Published private(set) var isRunningRasterMutation = false
    @Published private(set) var isCreatingSurface = false
    @Published private(set) var isDeletingResult = false
    @Published private(set) var isRunningMapMutation = false
    @Published private(set) var isRunningCatalogModelAction = false
    @Published private(set) var isRunningPlanCompute = false {
        didSet {
            guard oldValue != isRunningPlanCompute, isRunningPlanCompute else { return }
            for session in mapDynamicProfileWindows.values where session.isValid {
                _ = session.beginSourceRebind()
            }
        }
    }
    @Published private(set) var liveResultComputeByPath: [String: WorkspaceResultComputeEntry] = [:]
    let terrainUSGSTileOverlay = TerrainUSGSTileOverlaySession()
    let streamMode: StreamModeSession
    let stableChannelDebug: StableChannelDebugSession
    private var stableChannelSubscription: AnyCancellable?
    private var jobsSubscription: AnyCancellable?
    @Published private(set) var isRunningInitialConditionsCommit = false
    private var initialConditionsCommitOwner: (projectID: UUID, editorID: UUID, operationID: String)?
    private var initialConditionsWorkflows: [UUID: (projectID: UUID, session: BoundaryInitialConditionsSession)] = [:]
    @Published var catalogModelActionPresentation: CatalogModelActionPresentation?
    private var planComputeOwnerID: UUID?
    private var planComputeWritePaths: Set<String> = []
    private var activePlanComputeCapture: WorkspaceResultComputeCapture?
    private var historicalResultReadTasks: [UUID: (id: UUID, task: Task<Void, Never>)] = [:]
    @Published private var planMatrixEmitLease: (id: UUID, projectSessionID: UUID, captureID: String)?
    var isRunningPlanMatrixEmit: Bool { planMatrixEmitLease != nil }

    func beginPlanMatrixEmit(projectSessionID expectedSession: UUID, captureID: String) -> UUID? {
        guard expectedSession == projectSessionID, document?.url != nil, !captureID.isEmpty,
              !isRunningProjectTool, !isSavingAll, !isOpeningProject, !isClosingTab,
              !hasBusyModelEditors else { return nil }
        let leaseID = UUID()
        planMatrixEmitLease = (leaseID, expectedSession, captureID)
        return leaseID
    }

    func isPlanMatrixEmitCurrent(leaseID: UUID, projectSessionID expectedSession: UUID,
                                captureID: String) -> Bool {
        guard let lease = planMatrixEmitLease else { return false }
        return lease.id == leaseID && lease.projectSessionID == expectedSession
            && projectSessionID == expectedSession && lease.captureID == captureID
    }

    func endPlanMatrixEmit(leaseID: UUID) {
        guard planMatrixEmitLease?.id == leaseID else { return }
        planMatrixEmitLease = nil
    }
    /// No file reader receives a lease before a real, owner-validated compute
    /// callback identifies the writing Result. Begin-compute alone is not proof.
    var mapResultComputeReadLease: MapResultComputeReadLease? {
        guard isRunningPlanCompute, let capture = activePlanComputeCapture,
              capture.projectSessionID == projectSessionID,
              capture.editorID == planComputeOwnerID,
              let compute = editorSessions[capture.editorID]?.planCompute,
              compute.currentOperationOwner == capture.operationOwnerToken,
              compute.currentOperationContextID == capture.operationContextID,
              let projectURL = document?.url,
              Self.computeCanonicalPath(projectURL.path) == capture.projectPath else { return nil }
        let entries = liveResultComputeByPath.values.filter {
            $0.status == .running && LiveMapResultRunIdentity(entry: $0).matches(capture)
        }
        guard entries.count == 1, let entry = entries.first,
              UUID(uuidString: entry.runID) != nil else { return nil }
        let protected = planComputeWritePaths.union([Self.computeCanonicalPath(entry.resultPath)])
        // A request cannot isolate the project XML while constructing Project.
        // Keep every reader blocked if a writer ever owns that exact file too.
        guard !protected.contains(capture.projectPath) else { return nil }
        return MapResultComputeReadLease(projectSessionID: projectSessionID.uuidString,
            runID: entry.runID, projectPath: capture.projectPath,
            protectedSourcePaths: protected.sorted(), callbackResultPath: entry.resultPath)
    }
    @Published private(set) var isExportingTerrainRaster = false
    private var terrainRasterExportOwner: (leaseID: UUID, projectSessionID: UUID, captureID: String)?
    @Published var surfaceCreation: SurfaceCreationKind?
    var isRunningProjectTool: Bool { isRunningLibraryImport || isRunningPlanMatrixEmit || isRunningBackendTool || isRunningCumulusGridImport || isRunningRasterMutation || isCreatingSurface || isDeletingResult || isRunningMapMutation || isRunningCatalogModelAction || isRunningPlanCompute || isRunningInitialConditionsCommit || isExportingTerrainRaster }
    @Published var showCloseTabConfirmation = false
    @Published private(set) var isClosingTab = false
    private var pendingCloseTab: WorkspaceTab?
    var showWorkspace: (() -> Void)?
    let system: any WorkspaceSystemServices
    let modelProvider: (any ModelEditorProvider)?
    let projectionProvider: (any ProjectionProvider)?
    let reprojectionProvider: (any ReprojectionProvider)?
    let wilcockProvider: (any WilcockProvider)?
    let initialConditionsProvider: (any BoundaryInitialConditionsProvider)?
    private let recentHistoryStore: RecentProjectHistoryStore
    let toolProvider: (any ToolProvider)?
    let libraryProvider: (any ProjectLibraryProvider)?
    let jobProvider: (any JobProvider)?
    let chatProvider: (any ChatProvider)?
    let mapInteractionProvider: (any MapInteractionProvider)?
    var selectedAsset: ProjectAsset? { assets.first { $0.id == selectedAssetID } }
    var selectedConnection: ProjectConnection? { document?.connections.first { "connection/" + $0.id == selectedAssetID } }
    var hasProject: Bool { document != nil }
    var runtimeInfoClient: BackendProcessClient? { (modelProvider as? BackendModelProvider)?.client }
    var hasUnsavedChanges: Bool { isModified || visualization?.modified == true || descriptionDraft != document?.description && document != nil || hasUnsavedModelEdits || hasUnsavedMapEdits }
    var hasUnsavedModelEdits: Bool { stableChannelDebug.hasUnsavedChanges || editorSessions.values.contains { $0.hasUnsavedEditorChanges } }
    var hasUnsavedMapEdits: Bool { mapStates.values.contains { $0.polylineEditor.hasUnsavedChanges } }
    var hasBusyMapEditors: Bool { mapStates.values.contains { $0.polylineEditor.isBusy } }
    func hasConflictingMapDraft(path: String, excluding mapID: UUID) -> Bool {
        let physicalPath = SourceFilePaths.canonical(URL(fileURLWithPath: path))
        return mapStates.values.contains { state in
            state.id != mapID && (state.polylineEditor.hasUnsavedChanges || state.polylineEditor.isBusy) &&
                state.polylineEditor.currentScope.map { SourceFilePaths.canonical(URL(fileURLWithPath: $0.canonicalPath)) == physicalPath } == true
        }
    }
    var hasBusyModelEditors: Bool { stableChannelDebug.isBusy || editorSessions.values.contains { $0.isBusy } || hasBusyMapEditors }
    var statusText: String { hasUnsavedChanges ? L10n.text("Unsaved changes") : document == nil ? L10n.text("Ready") : L10n.format("Ready · %d project files", assets.count) }
    var visibleSections: [ProjectSection] {
        switch treeMode {
        case .project: ProjectSection.allCases
        case .geometry: [.geometries, .terrains, .surfaceLayers, .mapLayers, .features]
        case .plan: [.plans, .geometries, .boundaryConditions, .terrains, .mapLayers]
        }
    }
    @Published var focusedGeometryIDs: Set<String> = []
    @Published var focusedPlanIDs: Set<String> = []
    var focusedAssets: [ProjectAsset] {
        let ids = treeMode == .geometry ? focusedGeometryIDs : focusedPlanIDs
        return assets.filter { ids.contains($0.id) }
    }
    var matchingAssets: [ProjectAsset] {
        guard let document else { return [] }
        let names = Set(focusedAssets.map(\.name))
        let group = treeMode == .geometry ? "GeometryAssociations" : "PlanAssociations"
        let fields: [String: ProjectSection] = treeMode == .geometry ? ["Terrain": .terrains, "N_Values": .surfaceLayers] : ["Geometry": .geometries, "BoundaryCondition": .boundaryConditions]
        let rows = document.associationRows(group: group).filter { names.contains($0.name) }
        return assets.filter { asset in
            rows.contains { row in fields.contains { field, section in section == asset.section && row.fields[field] == asset.name } }
                && !focusedAssets.contains(asset)
        }
    }
    func focus(_ asset: ProjectAsset) {
        if asset.section == .geometries { focusedGeometryIDs.insert(asset.id); treeMode = .geometry }
        else if asset.section == .plans { focusedPlanIDs.insert(asset.id); treeMode = .plan }
        select(asset)
    }

    let launchConfiguration: WorkspaceLaunchConfiguration
    let applicationUID: String
    private let applicationDefaults: UserDefaults
    let developerCredentialStore: any WorkspaceS3CredentialStoring
    private let testingSettings: WorkspaceTestingSettings
    var testingUtilityBaseURL: String { testingSettings.baseURL }

    func setTestingUtilityBaseURL(_ value: String) throws {
        try testingSettings.setBaseURL(value)
        objectWillChange.send()
    }
    var suppressesAppDataIO: Bool { launchConfiguration.suppressesAppDataIO }
    var launchDebugEnabled: Bool { launchConfiguration.launchDebugEnabled }

    init(system: any WorkspaceSystemServices = MacSystemServices(), modelProvider: (any ModelEditorProvider)? = nil, toolProvider: (any ToolProvider)? = nil, libraryProvider: (any ProjectLibraryProvider)? = nil, jobProvider: (any JobProvider)? = nil, chatProvider: (any ChatProvider)? = nil, mapInteractionProvider: (any MapInteractionProvider)? = nil, projectionProvider: (any ProjectionProvider)? = nil, reprojectionProvider: (any ReprojectionProvider)? = nil, wilcockProvider: (any WilcockProvider)? = nil, initialConditionsProvider: (any BoundaryInitialConditionsProvider)? = nil, attributeTableProvider: (any AttributeTableProvider)? = nil, recentHistoryStore: RecentProjectHistoryStore? = nil, globalVectorStylePreferences: GlobalVectorStylePreferences? = nil, externalRecordProvider: (any ExternalRecordProvider)? = nil, launchConfiguration: WorkspaceLaunchConfiguration = .standard, applicationDefaults: UserDefaults = .standard) {
        self.launchConfiguration = launchConfiguration
        self.applicationDefaults = applicationDefaults
        let credentialStore: any WorkspaceS3CredentialStoring = launchConfiguration.suppressesAppDataIO
            ? WorkspaceSessionS3Credentials() : WorkspaceS3KeychainStore.shared
        developerCredentialStore = credentialStore
        let testingSettings = WorkspaceTestingSettings(defaults: launchConfiguration.suppressesAppDataIO ? nil : applicationDefaults)
        self.testingSettings = testingSettings
        if launchConfiguration.suppressesAppDataIO {
            applicationUID = WorkspaceApplicationIdentity.generateUID()
            self.globalVectorStylePreferences = GlobalVectorStylePreferences(persistenceEnabled: false)
        } else {
            if let saved = applicationDefaults.string(forKey: "UID"), !saved.isEmpty { applicationUID = saved }
            else {
                let generated = WorkspaceApplicationIdentity.generateUID()
                applicationUID = generated
                applicationDefaults.set(generated, forKey: "UID")
            }
            self.globalVectorStylePreferences = globalVectorStylePreferences ?? GlobalVectorStylePreferences(defaults: applicationDefaults)
        }
        self.system = system
        self.modelProvider = modelProvider; self.toolProvider = toolProvider
        streamMode = StreamModeSession(provider: BackendStreamModeProvider(
            client: (modelProvider as? BackendModelProvider)?.client))
        stableChannelDebug = StableChannelDebugSession(provider: BackendStableChannelDebugProvider(
            client: (modelProvider as? BackendModelProvider)?.client))
        self.projectionProvider = projectionProvider
        self.reprojectionProvider = reprojectionProvider
        self.wilcockProvider = wilcockProvider
        self.initialConditionsProvider = initialConditionsProvider
        self.attributeTableProvider = attributeTableProvider
        self.externalRecordProvider = externalRecordProvider
        self.recentHistoryStore = recentHistoryStore ?? RecentProjectHistoryStore(defaults: applicationDefaults)
        self.libraryProvider = libraryProvider ?? BackendProjectLibraryProvider(
            client: (modelProvider as? BackendModelProvider)?.client,
            debugMode: launchConfiguration.debugMode,
            chooseDestinationFolder: { system.chooseFolder(title: L10n.text("Project Folder")) })
        self.updateProvider = BackendUpdateProvider(client: (modelProvider as? BackendModelProvider)?.client,
            debugMode: launchConfiguration.debugMode,
            credentials: { credentialStore.load() },
            clearCredentials: { try credentialStore.delete() },
            openFile: { system.openFile($0) })
        self.jobProvider = jobProvider ?? WorkspaceJobRegistry.shared
        self.developerProvider = WorkspaceDeveloperProvider(credentials: credentialStore,
            backend: (modelProvider as? BackendModelProvider)?.client)
        let testing = BackendTestingProvider(client: (modelProvider as? BackendModelProvider)?.client,
            utilityBaseURL: { testingSettings.baseURL }, credentials: credentialStore)
        testingProvider = testing
        testingUploadProvider = testing
        self.chatProvider = chatProvider
        self.mapInteractionProvider = mapInteractionProvider
        if let records = externalRecordProvider as? BackendDSSRecordProvider {
            records.authorizeFolders = { [weak self] in self?.system.authorizeExternalFolders($0) ?? false }
        }
        if let tools = toolProvider as? BackendToolProvider {
            tools.onRunningChanged = { [weak self] in self?.isRunningBackendTool = $0 }
            tools.pathMappings = { [weak self] in self?.pathMappings ?? [] }
            tools.authorizeFolders = { [weak self] in self?.system.authorizeExternalFolders($0) ?? false }
            tools.projectXML = { [weak self] in
                guard let self else { return nil }
                return self.document?.editorXML(overridingDescription: self.descriptionDraft)
            }
            tools.reportContext = { [weak self] in
                guard let self else { return nil }
                let geometries = self.assets.filter { $0.section == .geometries }.map { asset in
                    let path = SourceFilePaths.canonical(asset.url)
                    let revision = self.editorSessions.values.first {
                        $0.modelAssetID == asset.id
                    }?.sourceFileRevision
                    return BugReportGeometryChoice(assetID: asset.id, name: asset.name,
                        path: path, revision: revision)
                }
                return BugReportNativeContext(projectSessionID: self.projectSessionID,
                    projectPath: self.document?.url.map(SourceFilePaths.canonical),
                    projectRevision: self.document?.sourceRevision,
                    projectXML: self.document?.editorXML(overridingDescription: self.descriptionDraft),
                    applicationUID: self.applicationUID,
                    crashContext: self.launchConfiguration.postCrashLaunch
                        ? "The application was launched with the post-crash flag." : nil,
                    geometries: geometries)
            }
            tools.onMessage = { [weak self] severity, message in
                self?.enqueueMessage(WorkspaceMessage(operation: L10n.text("Report an Issue"),
                    text: message, severity: severity))
            }
            tools.onExported = { [weak self] url in
                guard let self else { return }
                self.system.reveal(url); self.log("Export Plan", url.path)
            }
            tools.onCreated = { [weak self] asset, changed in
                guard let self else { return }
                if changed { self.isModified = true }
                self.refreshAssets()
                self.selectedAssetID = asset.id; self.selectedSection = asset.section
                self.log("Create", asset.name)
            }
        }
        if !launchConfiguration.suppressesAppDataIO {
            recentProjectHistory = self.recentHistoryStore.load()
            theme = applicationDefaults.string(forKey: "SystemTheme") ?? "System"
            interfaceLanguage = applicationDefaults.string(forKey: "UILanguage") ?? "System"
            isFirstLaunch = !applicationDefaults.bool(forKey: "HasSeenFirstLaunch")
            if let path = applicationDefaults.string(forKey: "UserOverrideProjectDirectory"), !path.isEmpty { projectDirectory = URL(fileURLWithPath: path, isDirectory: true) }
            if let path = applicationDefaults.string(forKey: "UserOverrideTempDirectory"), !path.isEmpty { temporaryDirectory = URL(fileURLWithPath: path, isDirectory: true) }
            if let data = applicationDefaults.data(forKey: "PathMappings"), let mappings = try? JSONDecoder().decode([PathMapping].self, from: data) { pathMappings = mappings }
        } else { isFirstLaunch = true }
        L10n.language = interfaceLanguage
        if let library = self.libraryProvider as? BackendProjectLibraryProvider {
            library.onImportRunningChanged = { [weak self] in self?.isRunningLibraryImport = $0 }
        }
        layerTreeSubscription = layerTreeSession.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        catalogTreeSubscription = catalogTreeSession.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        stableChannelSubscription = stableChannelDebug.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        if let registry = self.jobProvider as? WorkspaceJobRegistry {
            jobsSubscription = registry.$jobs.sink { [weak self] in self?.jobs = $0 }
        }
        layerTreeSession.didInstall = { [weak self] snapshot, context in
            guard let self, self.projectSessionID == context.projectSessionID else { return }
            if let assets = snapshot.projectAssets { self.assets = assets }
            if let hidden = snapshot.hiddenLayerIDs { self.mapState(for: context.mapID).hiddenLayers = hidden }
            if let focused = snapshot.focusedGeometryIDs { self.focusedGeometryIDs = focused }
            if let focused = snapshot.focusedPlanIDs { self.focusedPlanIDs = focused }
            guard context.mode == "Catalog" else { return }
            let confirmed = WorkspaceResultComputeCatalogReconciliation.confirmedTerminalEntries(
                in: snapshot, projectSessionID: context.projectSessionID,
                liveEntries: self.liveResultComputeByPath)
            for entry in confirmed { self.retireConfirmedLiveResultCompute(entry) }
        }
        catalogTreeSession.didInstall = layerTreeSession.didInstall
        if let backend = modelProvider as? BackendModelProvider {
            featureQueryProvider = BackendFeatureQueryProvider(client: backend.client,
                mapIdentity: { [weak self] context in
                    guard let self, self.projectSessionID == context.projectSessionID,
                          !self.isOpeningProject, !self.isSavingAll, !self.isClosingTab,
                          !self.isRunningPlanCompute else { return nil }
                    return self.mapIdentityRequest(for: context.mapID)
                }, chooseOutputDirectory: { [weak self] in
                    self?.system.chooseFolder(title: L10n.text("Save to Disk"))
                }, didExport: { [weak self] sources, context, info, warnings in
                    guard let self, self.projectSessionID == context.projectSessionID else { throw CancellationError() }
                    for source in sources {
                        guard self.projectSessionID == context.projectSessionID else { throw CancellationError() }
                        let file = URL(fileURLWithPath: source.path)
                        guard await self.connectVectorSource(file, for: context.mapID,
                            expectedShapefileFamily: file.pathExtension.lowercased() == "shp" ? source.family : nil,
                            expectedSourceRevision: source.revision) else {
                            throw BackendServiceError(code: "featureImportFailed",
                                message: "The features were exported, but the map layer could not be added.")
                        }
                    }
                    self.log("Save to Disk", L10n.text(info))
                    for warning in warnings { self.log("Save to Disk", L10n.text(warning), severity: .warning) }
                    if !warnings.isEmpty { self.showMessages = true }
                    return MapUpdate(vectors: nil, rasters: nil, preview: [], selectedLayerID: nil,
                                     selectedFeatureID: nil, preserveInteractionState: true)
                })
            let xml: @MainActor () -> String? = { [weak self] in
                guard let self else { return nil }
                return self.document?.editorXML(overridingDescription: self.descriptionDraft)
            }
            let maps: @MainActor () -> [CatalogMapDocument] = { [weak self] in
                self?.catalogMapDocuments ?? []
            }
        let currentContext: @MainActor (LayerTreeContext) -> Bool = { [weak self] context in
            self?.projectSessionID == context.projectSessionID && self?.document?.url == context.projectURL
                && self?.isRunningPlanCompute == false
            }
            let beginBackupRestore: @MainActor () -> Bool = { [weak self] in
                guard let self, !self.isRunningProjectTool, !self.isSavingAll,
                      !self.isOpeningProject, !self.isClosingTab else { return false }
                self.isRunningCatalogModelAction = true
                return true
            }
            let endBackupRestore: @MainActor () -> Void = { [weak self] in self?.isRunningCatalogModelAction = false }
            catalogTreeProvider = BackendCatalogTreeProvider(client: backend.client, projectXML: xml, mapDocuments: maps,
                isContextCurrent: currentContext, beginBackupRestore: beginBackupRestore, endBackupRestore: endBackupRestore)
            let fallback = BackendCatalogTreeProvider(client: backend.client, projectXML: xml, mapDocuments: maps,
                isContextCurrent: currentContext, beginBackupRestore: beginBackupRestore, endBackupRestore: endBackupRestore)
            layerTreeProvider = BackendMapTreeProvider(client: backend.client, fallback: fallback,
                projectXML: xml, mapDocuments: maps,
                isContextCurrent: { [weak self] context in
                    self?.projectSessionID == context.projectSessionID && self?.document?.url == context.projectURL
                        && self?.isRunningPlanCompute == false
                },
                visualizationRevision: { [weak self] in self?.visualization?.sourceRevision },
                beginMapMutation: { [weak self] in
                    guard let self, !self.isRunningProjectTool, !self.isSavingAll,
                          !self.isOpeningProject, !self.isClosingTab else { return false }
                    self.isRunningMapMutation = true
                    return true
                }, endMapMutation: { [weak self] in self?.isRunningMapMutation = false },
                acceptMapChange: { [weak self] oldRevision, newRevision in
                    guard let self, let visualization = self.visualization else { throw ProjectFileError.modifiedExternally }
                    try visualization.acceptExternalMapChange(expectedPreviousRevision: oldRevision, newRevision: newRevision)
                    self.installVisualizationMaps(visualization)
                    try self.refreshRasterMapSources()
                    self.configureRasterSymbologyProvider()
                    self.loadRasterMapLayers()
                    self.assetsRevision += 1
                })
        }
        vectorSymbologyProvider = WorkspaceVectorSymbologyProvider(store: self,
            preferences: self.globalVectorStylePreferences,
            client: (modelProvider as? BackendModelProvider)?.client)
    }

    func openPanel() { if let url = system.chooseProject() { requestOpen(url) } }
    func requestOpen(_ url: URL) {
        guard projectMigration == nil else { return }
        if url.isFileURL, url.pathExtension.lowercased() == "prj" {
            guard !isSavingAll, !isClosingTab, !isRunningProjectTool,
                  let authorized = system.authorizeProjectFolder(for: url) else { return }
            cancelProjectOpening()
            // Conversion writes a separate project. Keep the current document
            // and its drafts until the converted project can actually open.
            projectMigration = ProjectMigrationPresentation(sourceURL: authorized,
                authorizedSourceDirectory: authorized.deletingLastPathComponent())
        } else {
            confirmReplacement { [weak self] in self?.beginOpeningProject(url) }
        }
    }
    func completeProjectMigration(_ url: URL) {
        pendingMigratedProjectURL = url
        projectMigration = nil
    }
    func finishProjectMigrationPresentation() {
        guard let url = pendingMigratedProjectURL else { return }
        pendingMigratedProjectURL = nil
        requestOpen(url)
    }
    func requestNewProject() { confirmReplacement { [weak self] in self?.showNewProject = true } }
    func requestClose() { confirmReplacement { [weak self] in self?.resetProjectWorkspace() } }
    func requestReload() { if let url = document?.url { requestOpen(url) } }
    private func confirmReplacement(_ action: @escaping () -> Void) {
        guard projectMigration == nil, !isSavingAll, !isClosingTab, !isRunningProjectTool, !hasBusyModelEditors else { return }
        cancelProjectOpening()
        if hasUnsavedChanges { pendingAction = action; showDiscardConfirmation = true }
        else { action() }
    }
    func discardAndContinue() {
        let action = pendingAction; pendingAction = nil; showDiscardConfirmation = false
        if hasUnsavedChanges, !discardAllChanges() { return }
        action?()
    }
    func cancelReplacement() { pendingAction = nil; showDiscardConfirmation = false }
    func saveAndContinue() { Task { if await saveAll() { discardAndContinue() } } }

    private func beginOpeningProject(_ url: URL) {
        guard let authorized = system.authorizeProjectFolder(for: url) else { return }
        cancelProjectOpening()
        let needsPreparation = ["zip", "h5"].contains(authorized.pathExtension.lowercased())
        let destination: URL?
        if needsPreparation {
            guard let selected = system.chooseFolder(title: L10n.text("Import Project")) else { return }
            destination = selected
        } else { destination = nil }
        let revision = projectOpenRevision
        openingProject = ProjectOpening(url: authorized)
        projectOpenTask = Task { [weak self] in
            do {
                let projectURL: URL
                if let destination {
                    guard let client = self?.runtimeInfoClient else { throw CocoaError(.featureUnsupported) }
                    let prepared = try await WorkspaceFileImportProvider(client: client)
                        .prepare(sourceURL: authorized, destinationDirectory: destination)
                    guard let self, !Task.isCancelled, self.projectOpenRevision == revision else { return }
                    projectURL = prepared.projectURL
                } else { projectURL = authorized }
                let opened = try await ProjectDocument.open(contentsOf: projectURL)
                guard let self, !Task.isCancelled, self.projectOpenRevision == revision else { return }
                self.openingProject = nil; self.projectOpenTask = nil
                // A detached editor may have changed while the file was read.
                // Recheck before replacing any live drafts.
                self.confirmReplacement { [weak self] in self?.installProject(opened) }
            } catch {
                guard let self, !Task.isCancelled, self.projectOpenRevision == revision else { return }
                self.openingProject = nil; self.projectOpenTask = nil
                self.report("Open Project", error)
            }
        }
    }

    func cancelProjectOpening() {
        projectOpenRevision += 1
        projectOpenTask?.cancel(); projectOpenTask = nil; openingProject = nil
    }

    @discardableResult
    private func installProject(_ opened: ProjectDocument) -> Bool {
        guard !isRunningPlanCompute, !isRunningInitialConditionsCommit,
              !hasBusyModelEditors, !hasUnsavedMapEdits,
              !editorSessions.values.contains(where: { $0.geometryMesh?.hasUnsavedDiagnosticsPreferences == true }) else { return false }
        let previousLease = projectOpenLockLease
        let previousURL = projectOpenLockURL
        let candidateLease: WorkspaceProjectOpenLock.Lease?
        do {
            if let url = opened.url {
                if let previousURL,
                   SourceFilePaths.canonical(previousURL.deletingLastPathComponent()) == SourceFilePaths.canonical(url.deletingLastPathComponent()),
                   let previousLease { candidateLease = previousLease }
                else { candidateLease = try WorkspaceProjectOpenLock.acquire(for: url) }
            } else { candidateLease = nil }
        } catch { report("Open Project", error); return false }
        // Keep the prior lease alive while reset commits. Reset must not
        // release a reused lease during a reload of the same project.
        projectOpenLockLease = nil; projectOpenLockURL = nil
        guard resetProjectWorkspace() else {
            if candidateLease !== previousLease { candidateLease?.release() }
            projectOpenLockLease = previousLease; projectOpenLockURL = previousURL
            return false
        }
        projectOpenLockLease = candidateLease; projectOpenLockURL = opened.url
        if candidateLease !== previousLease { previousLease?.release() }
        document = opened; assets = opened.assets; descriptionDraft = opened.description
        modelProvider?.setProject(opened)
        toolProvider?.setProject(opened, sessionID: projectSessionID)
        isModified = false; selectedAssetID = nil; selectedSection = nil; treeMode = .project
        loadMapLayers()
        if let projectURL = opened.url { loadVisualization(projectURL); recordRecent(projectURL) }
        log("Open Project", L10n.format("Opened %@.", opened.name))
        return true
    }

    @discardableResult
    private func open(_ url: URL) -> Bool {
        guard !isRunningProjectTool else { return false }
        do {
            guard let authorized = system.authorizeProjectFolder(for: url) else { return false }
            let opened = try ProjectDocument(contentsOf: authorized)
            return installProject(opened)
        } catch { report("Open Project", error); return false }
    }
    func createProject(name: String, units: String, description: String, directory: URL, projectionType: String, projectionValue: String) {
        guard !isRunningProjectTool, !hasBusyModelEditors,
              !editorSessions.values.contains(where: { $0.geometryMesh?.hasUnsavedDiagnosticsPreferences == true }) else { return }
        do {
            let newProject = try ProjectDocument(name: name, units: units)
            if projectionType != "Local" { try newProject.setProjection(type: projectionType, value: projectionValue) }
            let folder = directory.appendingPathComponent(name, isDirectory: true)
            try ProjectCreationDestination.validate(folder)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent(name + ".ras")
            newProject.description = description
            try newProject.save(to: url); try newProject.createDirectoryStructure()
            guard installProject(newProject) else { return }
            showNewProject = false
            log("New Project", L10n.format("Created %@.", name))
        } catch { report("New Project", error) }
    }

    @discardableResult
    func save(asCopy: Bool = false) -> Bool {
        guard let document, !isOpeningProject, !isRunningProjectTool, !stableChannelDebug.isBusy else { return false }
        do {
            try visualization?.validateSave()
            if document.description != descriptionDraft {
                isModified = true
                document.description = descriptionDraft
            }
            if asCopy || document.url == nil {
                guard let target = system.chooseProjectDestination(name: document.name) else { return false }
                // A copy's associations and relative file structure must travel together.
                if asCopy, !assets.isEmpty { throw ProjectFileError.invalid("Copy the project folder before saving under a new location so its associated files remain together.") }
                try document.save(to: target)
            } else { try document.save() }
            if let url = document.url, let revision = document.sourceRevision {
                _ = stableChannelDebug.acceptProjectSave(projectPath: SourceFilePaths.canonical(url),
                    projectSessionID: projectSessionID, projectRevision: revision)
            }
            try visualization?.save()
            try refreshRasterMapSources()
            isModified = false; objectWillChange.send()
            if let url = document.url { recordRecent(url) }
            log("Save Project", L10n.format("Saved %@.", document.name))
            return true
        } catch { report("Save Project", error); return false }
    }
    func registerEditor(_ session: ModelEditorSession, primaryKind: ModelEditorKind? = nil) {
        if let primaryKind {
            precondition(primaryEditorIDs[primaryKind] == nil || primaryEditorIDs[primaryKind] == session.id)
            primaryEditorIDs[primaryKind] = session.id
        }
        if editorSessions[session.id] == nil {
            editorSessions[session.id] = session
            let ownerProjectSession = projectSessionID
            session.workspaceWriteLocked = { [weak self, weak session] in
                guard let self else { return false }
                return self.isRunningPlanCompute || self.isRunningInitialConditionsCommit || self.isExportingTerrainRaster
                    || (self.isRunningCumulusGridImport && self.cumulusGridImportOwnerID != session?.id)
            }
            session.beginPlanCompute = { [weak self, weak session] inspection in
                guard let self, let session, self.projectSessionID == ownerProjectSession,
                      self.editorSessions[session.id] === session, let assetID = session.modelAssetID,
                      session.sourceFileRevision == inspection.revision, let document = self.document,
                      let projectURL = document.url, let projectRevision = document.sourceRevision,
                      projectRevision == inspection.projectRevision,
                      CatalogModelActionPublisher.digest(Data(document.editorXML.utf8)) == inspection.projectXmlFingerprint else { return false }
                guard let operationOwner = session.planCompute?.currentOperationOwner,
                      let operationContextID = session.planCompute?.currentOperationContextID else { return false }
                let capture = WorkspaceResultComputeCapture(
                    projectSessionID: ownerProjectSession, editorID: session.id,
                    operationOwnerToken: operationOwner, operationContextID: operationContextID,
                    projectPath: SourceFilePaths.canonical(projectURL),
                    projectRevision: inspection.projectRevision,
                    projectXmlFingerprint: inspection.projectXmlFingerprint,
                    planPath: assetID, planRevision: inspection.revision)
                return self.beginPlanCompute(editorID: session.id, assetID: assetID,
                    dependencyPaths: inspection.sourceDependencies.map(\.path),
                    writePaths: inspection.sourceDependencies.filter(\.willWrite).map(\.path),
                    projectSessionID: ownerProjectSession, capture: capture)
            }
            session.planCompute?.onResultComputeUpdate = { [weak self, weak session] envelope, update, operationOwner, operationContextID in
                guard let self, let session, self.projectSessionID == ownerProjectSession,
                      self.editorSessions[session.id] === session,
                      self.planComputeOwnerID == session.id, self.isRunningPlanCompute else { return }
                self.acceptResultComputeProgress(envelope, update: update, editorID: session.id,
                    projectSessionID: ownerProjectSession, operationOwnerToken: operationOwner,
                    operationContextID: operationContextID)
            }
            session.planCompute?.onLiveMapRasterFrame = { [weak self, weak session] frame, owner, contextID in
                guard let self, let session, self.projectSessionID == ownerProjectSession,
                      self.editorSessions[session.id] === session,
                      self.planComputeOwnerID == session.id, self.isRunningPlanCompute,
                      session.planCompute?.currentOperationOwner == owner,
                      session.planCompute?.currentOperationContextID == contextID,
                      let capture = self.activePlanComputeCapture,
                      capture.editorID == session.id,
                      capture.operationOwnerToken == owner, capture.operationContextID == contextID,
                      let entry = self.liveResultComputeByPath[Self.computeCanonicalPath(frame.resultPath)],
                      entry.status == .running,
                      LiveMapResultRunIdentity(entry: entry).matches(capture),
                      let mapID = UUID(uuidString: frame.mapID), let state = self.mapStates[mapID] else { return }
                state.resultMap.acceptLiveMapFrame(frame, capture: capture, entry: entry)
            }
            session.planCompute?.onLiveVelocityFieldFrame = { [weak self, weak session] frame, owner, contextID in
                guard let self, let session, self.projectSessionID == ownerProjectSession,
                      self.editorSessions[session.id] === session,
                      self.planComputeOwnerID == session.id, self.isRunningPlanCompute,
                      session.planCompute?.currentOperationOwner == owner,
                      session.planCompute?.currentOperationContextID == contextID,
                      let capture = self.activePlanComputeCapture,
                      capture.editorID == session.id,
                      capture.operationOwnerToken == owner, capture.operationContextID == contextID,
                      let entry = self.liveResultComputeByPath[Self.computeCanonicalPath(frame.resultPath)],
                      entry.status == .running, LiveMapResultRunIdentity(entry: entry).matches(capture),
                      let mapID = UUID(uuidString: frame.mapID), let state = self.mapStates[mapID] else { return }
                _ = state.resultMap.acceptLiveVelocityFrame(frame, capture: capture, entry: entry)
            }
            session.planCompute?.onLiveVelocityUnavailable = { [weak self, weak session] unavailable, owner, contextID in
                guard let self, let session, self.projectSessionID == ownerProjectSession,
                      self.editorSessions[session.id] === session,
                      self.planComputeOwnerID == session.id, self.isRunningPlanCompute,
                      session.planCompute?.currentOperationOwner == owner,
                      session.planCompute?.currentOperationContextID == contextID,
                      let capture = self.activePlanComputeCapture,
                      capture.editorID == session.id,
                      capture.operationOwnerToken == owner, capture.operationContextID == contextID,
                      let entry = self.liveResultComputeByPath[Self.computeCanonicalPath(unavailable.resultPath)],
                      entry.status == .running, LiveMapResultRunIdentity(entry: entry).matches(capture),
                      let mapID = UUID(uuidString: unavailable.mapID), let state = self.mapStates[mapID] else { return }
                _ = state.resultMap.acceptLiveVelocityUnavailable(unavailable, capture: capture, entry: entry)
            }
            session.endPlanCompute = { [weak self, weak session] in
                guard let self, let session else { return }
                self.endPlanCompute(editorID: session.id, projectSessionID: ownerProjectSession)
            }
            session.planCompute?.onNavigateDiagnosticTarget = { [weak self, weak session] target, contextID in
                guard let self, let session, self.projectSessionID == ownerProjectSession,
                      self.editorSessions[session.id] === session else { return false }
                return self.navigateToPlanDiagnosticTarget(target, projectSessionID: ownerProjectSession,
                    planEditorID: session.id, planContextID: contextID)
            }
            session.didComputePlan = { [weak self, weak session] result in
                guard let self, let session, self.projectSessionID == ownerProjectSession,
                      self.editorSessions[session.id] === session,
                      self.planComputeOwnerID == session.id else { return }
                self.acceptResultComputeTerminal(result, editorID: session.id,
                    projectSessionID: ownerProjectSession,
                    operationOwnerToken: session.planCompute?.currentOperationOwner,
                    operationContextID: session.planCompute?.currentOperationContextID)
                session.planResults?.invalidate()
                let title: String
                switch result.state {
                case "completed": title = "Plan compute completed."
                case "cancelled": title = "Plan compute was cancelled."
                default: title = "Plan compute failed."
                }
                self.log("Compute", [L10n.text(title), result.errorMessage, result.resultPath].compactMap { $0 }.joined(separator: "\n"),
                    severity: result.state == "completed" ? .information : result.state == "cancelled" ? .warning : .error,
                    defaultAction: session.modelAssetID.map {
                        .openEditor(projectSessionID: ownerProjectSession,
                            editorKind: ModelEditorKind.plan.rawValue, assetID: $0)
                    } ?? .showMessages)
            }
            session.persistDiagnosticsPreferences = { [weak self, weak session] capture in
                guard let self, let session, self.projectSessionID == ownerProjectSession,
                      self.editorSessions[session.id] === session else { throw CancellationError() }
                return try self.persistMeshDiagnosticsPreferences(capture)
            }
            session.didSave = { [weak self, weak session] in
                guard let self, let session, self.editorSessions[session.id] === session else { return }
                self.assetsRevision += 1
            }
            editorSubscriptions[session.id] = session.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        }
    }
    func boundaryInitialConditionsSession(for editor: ModelEditorSession) throws -> BoundaryInitialConditionsSession {
        guard editorSessions[editor.id] === editor, let document,
              let projectURL = document.url, let projectRevision = document.sourceRevision,
              let provider = initialConditionsProvider else {
            throw ProjectFileError.invalid("Open an editable boundary condition in a saved project before attaching initial conditions.")
        }
        if let existing = initialConditionsWorkflows[editor.id], existing.projectID == projectSessionID,
           existing.session.pendingOperationID != nil {
            // An ambiguous write owns its original capture across sheet close.
            // Reopening must not turn it into a second attachment operation.
            return existing.session
        }
        let capture = try editor.captureBoundaryInitialConditions(projectSessionID: projectSessionID,
            projectURL: projectURL, projectRevision: projectRevision, documentXML: document.editorXML,
            submittedProjectXML: document.editorXML(overridingDescription: descriptionDraft),
            descriptionDraft: descriptionDraft)
        let workflow: BoundaryInitialConditionsSession
        if let existing = initialConditionsWorkflows[editor.id], existing.projectID == projectSessionID {
            workflow = existing.session
        } else {
            workflow = BoundaryInitialConditionsSession(provider: provider)
            initialConditionsWorkflows[editor.id] = (projectSessionID, workflow)
        }
        workflow.configure(capture: capture, isCurrent: { [weak self] value in
            self?.isCurrentInitialConditionsCapture(value) == true
        }, beginCommit: { [weak self] value, request in
            self?.beginBoundaryInitialConditionsCommit(capture: value, request: request) == true
        }, endCommit: { [weak self] operationID in
            self?.endBoundaryInitialConditionsCommit(operationID: operationID)
        }, commit: { [weak self] value, receipt in
            guard let self else { return false }
            return try await self.acceptBoundaryInitialConditionsCommit(capture: value, receipt: receipt)
        })
        return workflow
    }

    func hasPendingInitialConditionsOperation(for editor: ModelEditorSession) -> Bool {
        guard let workflow = initialConditionsWorkflows[editor.id], workflow.projectID == projectSessionID else { return false }
        return workflow.session.pendingOperationID != nil
    }

    private func isCurrentInitialConditionsCapture(_ capture: BoundaryInitialConditionsCapture) -> Bool {
        guard capture.projectSessionID == projectSessionID, let document,
              let projectURL = document.url, let revision = document.sourceRevision,
              let editor = editorSessions[capture.editorID],
              assets.contains(where: { $0 == capture.asset && $0.section == .boundaryConditions }) else { return false }
        return editor.isCurrentBoundaryInitialConditionsCapture(capture, projectSessionID: projectSessionID,
            projectURL: projectURL, projectRevision: revision, documentXML: document.editorXML,
            submittedProjectXML: document.editorXML(overridingDescription: descriptionDraft))
    }

    private func beginBoundaryInitialConditionsCommit(capture: BoundaryInitialConditionsCapture,
        request: BoundaryInitialConditionsAttachRequest) -> Bool {
        if let owner = initialConditionsCommitOwner {
            return owner.projectID == projectSessionID && owner.projectID == capture.projectSessionID
                && owner.editorID == capture.editorID && owner.operationID == request.operationID
        }
        guard capture.projectSessionID == projectSessionID,
              let projectURL = document?.url,
              Self.computeCanonicalPath(projectURL.path) == Self.computeCanonicalPath(capture.projectPath),
              let editor = editorSessions[capture.editorID], editor.modelAssetID == capture.asset.id,
              assets.contains(capture.asset), !isRunningProjectTool, !isSavingAll,
              !isOpeningProject, !isClosingTab, !hasBusyModelEditors else { return false }
        let recovering = initialConditionsWorkflows[capture.editorID]?.session.pendingOperationID == request.operationID
        guard recovering || isCurrentInitialConditionsCapture(capture) else { return false }
        let target = Self.computeCanonicalPath(capture.asset.id)
        guard !editorSessions.values.contains(where: {
            $0.id != capture.editorID && $0.hasUnsavedEditorChanges
                && $0.modelAssetID.map { Self.computeCanonicalPath($0) == target } == true
        }), !mapStates.values.contains(where: {
            $0.polylineEditor.hasUnsavedChanges
                && $0.polylineEditor.currentScope.map { Self.computeCanonicalPath($0.canonicalPath) == target } == true
        }) else {
            errorMessage = L10n.text("Save or discard other edits to this boundary condition before attaching initial conditions.")
            return false
        }
        errorMessage = nil
        initialConditionsCommitOwner = (projectSessionID, capture.editorID, request.operationID)
        isRunningInitialConditionsCommit = true
        return true
    }

    private func endBoundaryInitialConditionsCommit(operationID: String) {
        guard let owner = initialConditionsCommitOwner, owner.projectID == projectSessionID,
              owner.operationID == operationID else { return }
        initialConditionsCommitOwner = nil
        isRunningInitialConditionsCommit = false
    }

    private func acceptBoundaryInitialConditionsCommit(capture: BoundaryInitialConditionsCapture,
        receipt: BoundaryInitialConditionsReceipt) async throws -> Bool {
        guard capture.projectSessionID == projectSessionID, let document,
              let projectURL = document.url,
              Self.computeCanonicalPath(projectURL.path) == Self.computeCanonicalPath(receipt.projectPath),
              Self.computeCanonicalPath(capture.projectPath) == Self.computeCanonicalPath(receipt.projectPath),
              Self.computeCanonicalPath(capture.asset.id) == Self.computeCanonicalPath(receipt.assetPath),
              let editor = editorSessions[capture.editorID], editor.modelAssetID == capture.asset.id,
              initialConditionsCommitOwner?.operationID == receipt.operationID,
              initialConditionsCommitOwner?.editorID == capture.editorID else { return false }
        _ = try receipt.model.editorSnapshot
        let remainingProjectDraft = try document.acceptInitialConditionsCommit(
            expectedSourceRevision: capture.projectRevision, capturedDocumentXML: capture.capturedDocumentXML,
            capturedDraftXML: capture.submittedProjectXML, committedProjectXML: receipt.projectXml,
            committedProjectRevision: receipt.projectRevision, connectionName: receipt.connectionName)
        isModified = remainingProjectDraft
        if descriptionDraft == capture.descriptionDraft { descriptionDraft = document.description }
        let accepted = editor.acknowledgeBoundaryInitialConditions(capture, receipt: receipt)
        // Other clean windows on the same HDF must adopt its new baseline;
        // unrelated model and map drafts keep their existing ownership.
        let sameSource = editorSessions.values.filter {
            $0.id != capture.editorID && !$0.hasUnsavedEditorChanges
                && $0.modelAssetID.map { Self.computeCanonicalPath($0) == Self.computeCanonicalPath(receipt.assetPath) } == true
        }
        for other in sameSource {
            guard capture.projectSessionID == projectSessionID,
                  initialConditionsCommitOwner?.operationID == receipt.operationID,
                  editorSessions[other.id] === other, !other.hasUnsavedEditorChanges else { continue }
            await other.load(capture.asset, kind: .boundaryCondition)
        }
        guard capture.projectSessionID == projectSessionID else { return false }
        assetsRevision += 1
        catalogTreeSession.invalidate()
        layerTreeSession.invalidate()
        refreshAssets()
        log("Attach Initial Conditions", L10n.text("Initial conditions attached.") + "\n" + receipt.connectionName)
        return accepted
    }

    func primaryEditorSession(_ kind: ModelEditorKind) -> ModelEditorSession {
        if let id = primaryEditorIDs[kind], let existing = editorSessions[id] { return existing }
        let session = ModelEditorSession(provider: modelProvider)
        registerEditor(session, primaryKind: kind); return session
    }
    func editorSession(_ id: UUID) -> ModelEditorSession? { editorSessions[id] }

    func capturePlanAnalysisDrafts(preferredEditorID: UUID? = nil) -> [PlanAnalysisPlanDraft]? {
        let planIDs = Set(assets.filter { $0.section == .plans }.map(\.id))
        let sessions = editorSessions.values.filter {
            $0.loaded && ($0.modelAssetID.map(planIDs.contains) == true || $0.id == preferredEditorID)
        }
        var grouped: [String: [(ModelEditorSession, PlanAnalysisPlanDraft)]] = [:]
        for session in sessions {
            guard let draft = PlanAnalysisPlanDraft.capture(session: session) else {
                errorMessage = L10n.text("Finish the open Plan editor input before comparing plans or creating a matrix.")
                return nil
            }
            grouped[draft.assetPath, default: []].append((session, draft))
        }
        var captured: [PlanAnalysisPlanDraft] = []
        for path in grouped.keys.sorted() {
            guard let entries = grouped[path] else { continue }
            let dirty = entries.filter { $0.0.hasUnsavedEditorChanges }
            let preferred = entries.first { $0.0.id == preferredEditorID }
            guard dirty.count <= 1,
                  dirty.isEmpty || preferred == nil || dirty[0].0.id == preferred?.0.id else {
                errorMessage = L10n.text("Save or discard conflicting Plan editor drafts before opening this analysis.")
                return nil
            }
            if let chosen = dirty.first ?? preferred
                ?? entries.sorted(by: { $0.0.id.uuidString < $1.0.id.uuidString }).first {
                captured.append(chosen.1)
            }
        }
        return captured
    }

    func arePlanAnalysisDraftsCurrent(_ drafts: [PlanAnalysisPlanDraft]) -> Bool {
        guard drafts.allSatisfy({ $0.isCurrent(in: self) }) else { return false }
        let capturedIDs = Set(drafts.map(\.editorID))
        let planIDs = Set(assets.filter { $0.section == .plans }.map(\.id))
        return !editorSessions.values.contains {
            $0.hasUnsavedEditorChanges && !capturedIDs.contains($0.id)
                && $0.modelAssetID.map(planIDs.contains) == true
        }
    }

    func planDiffWindowRoute(preferredEditorID: UUID? = nil) -> PlanDiffWindowRoute? {
        guard !isRunningProjectTool, !isSavingAll, !isOpeningProject, !isClosingTab,
              !hasBusyModelEditors, runtimeInfoClient != nil,
              let project = PlanAnalysisProjectCapture.capture(store: self),
              let drafts = capturePlanAnalysisDrafts(preferredEditorID: preferredEditorID) else { return nil }
        return .init(projectSessionID: project.projectSessionID, capture: project.capture,
            planDrafts: drafts)
    }

    func planMatrixWindowRoute(plan: ProjectAsset,
                               preferredEditorID: UUID? = nil) -> ReadyToRunMatrixWindowRoute? {
        guard !isRunningProjectTool, !isSavingAll, !isOpeningProject, !isClosingTab,
              !hasBusyModelEditors, runtimeInfoClient != nil,
              plan.section == .plans, assets.contains(where: { $0.id == plan.id && $0.section == .plans }),
              let project = PlanAnalysisProjectCapture.capture(store: self),
              let drafts = capturePlanAnalysisDrafts(preferredEditorID: preferredEditorID) else { return nil }
        return .init(projectSessionID: project.projectSessionID, capture: project.capture,
            planDrafts: drafts, initialPlanPath: SourceFilePaths.canonical(plan.url))
    }
    func capturePlanPrecomputeAssociatedDrafts(planEditorID: UUID, planContextID: String,
        projectSessionID expectedSessionID: UUID) throws -> PlanPrecomputeAssociatedDraftsCapture {
        guard projectSessionID == expectedSessionID, let document, let projectURL = document.url,
              let planSession = editorSessions[planEditorID],
              let plan = planSession.currentPlanPrecomputeContext(), plan.id == planContextID,
              plan.asset.section == .plans,
              assets.contains(where: { $0.id == plan.asset.id }) else {
            throw ProjectFileError.invalid("Reload the Plan and project before checking associated drafts.")
        }
        let rows = document.associationRows(group: "PlanAssociations").filter { $0.name == plan.asset.name }
        guard rows.count == 1, let row = rows.first else {
            throw ProjectFileError.invalid("The Plan association is missing or ambiguous.")
        }
        func capture(_ field: String, section: ProjectSection) throws -> PlanPrecomputeAssociatedEditorCapture? {
            guard let name = row.fields[field], !name.isEmpty else { return nil }
            let matches = assets.filter { $0.section == section && $0.isModelFile && $0.name == name }
            guard matches.count == 1, let associated = matches.first else {
                throw ProjectFileError.invalid("The associated model is missing or ambiguous.")
            }
            let path = SourceFilePaths.canonical(associated.url)
            let editors = editorSessions.values.filter { editor in
                guard let assetID = editor.modelAssetID,
                      let asset = assets.first(where: { $0.id == assetID }), asset.section == section else { return false }
                return SourceFilePaths.canonical(asset.url) == path && editor.hasUnsavedEditorChanges
            }
            guard editors.count <= 1 else {
                throw ProjectFileError.invalid("More than one editor has unsaved changes for the associated model.")
            }
            return try editors.first?.captureAssociatedPlanPrecomputeDraft()
        }
        let geometry = try capture("Geometry", section: .geometries)
        let boundary = try capture("BoundaryCondition", section: .boundaryConditions)
        let identity = [expectedSessionID.uuidString, projectURL.path, document.editorXML, planContextID,
            geometry?.editorID.uuidString ?? "", geometry?.contextID ?? "",
            boundary?.editorID.uuidString ?? "", boundary?.contextID ?? ""]
        let digest = SHA256.hash(data: try JSONEncoder().encode(identity))
            .map { String(format: "%02x", $0) }.joined()
        return .init(id: digest, planContextID: planContextID, projectSessionID: expectedSessionID,
            projectPath: projectURL.path, projectXML: document.editorXML,
            geometry: geometry, boundaryCondition: boundary)
    }
    func isCurrentPlanPrecomputeAssociatedDrafts(_ capture: PlanPrecomputeAssociatedDraftsCapture) -> Bool {
        guard let session = editorSessions.values.first(where: {
            $0.currentPlanPrecomputeContext()?.id == capture.planContextID
        }) else { return false }
        return (try? capturePlanPrecomputeAssociatedDrafts(planEditorID: session.id,
            planContextID: capture.planContextID, projectSessionID: capture.projectSessionID).id) == capture.id
    }
    func planPrecomputeAssociatedDraftsIdentity(for session: ModelEditorSession) -> String {
        guard let context = session.currentPlanPrecomputeContext() else { return "unavailable" }
        do {
            return try capturePlanPrecomputeAssociatedDrafts(planEditorID: session.id,
                planContextID: context.id, projectSessionID: projectSessionID).id
        } catch { return "unavailable|" + context.id + "|" + error.localizedDescription }
    }
    func effectiveVectorStyle(definitionID: String, localStyle: VectorStyleValues? = nil) -> VectorStyleValues {
        localStyle?.validatedForPersistence()
            ?? globalVectorStylePreferences.style(for: definitionID)
            ?? SourceVectorStyleCatalog.definition(for: definitionID)?.defaultStyle
            ?? SourceVectorStyleCatalog.fallbackStyle
    }
    func loadedVectorStyleMapStates() -> [MapState] { Array(mapStates.values) }

    func geometryMeshSession(assetID: String,
                             projectSessionID expectedSession: UUID) -> GeometryMeshSession? {
        guard expectedSession == projectSessionID else { return nil }
        let path = SourceFilePaths.canonical(URL(fileURLWithPath: assetID))
        let matches = editorSessions.values.compactMap { editor -> GeometryMeshSession? in
            guard editor.loaded, !editor.loadingSelection,
                  let owner = editor.modelAssetID, editor.sourceFileRevision != nil,
                  SourceFilePaths.canonical(URL(fileURLWithPath: owner)) == path else { return nil }
            return editor.geometryMesh
        }
        return matches.count == 1 ? matches.first : nil
    }

    func activeGeometryMeshGeneration(assetID: String,
                                      projectSessionID expectedSession: UUID) -> GeometryMeshSession? {
        guard expectedSession == projectSessionID else { return nil }
        let path = SourceFilePaths.canonical(URL(fileURLWithPath: assetID))
        let matches = editorSessions.values.compactMap { editor -> GeometryMeshSession? in
            guard let ownerPath = editor.modelAssetID,
                  SourceFilePaths.canonical(URL(fileURLWithPath: ownerPath)) == path,
                  let revision = editor.sourceFileRevision,
                  let mesh = editor.geometryMesh,
                  mesh.matchesActiveMeshGeneration(projectSessionID: expectedSession,
                    sourcePath: path, sourceRevision: revision) else { return nil }
            return mesh
        }
        return matches.count == 1 ? matches.first : nil
    }

    func vectorGlobalStylesDidChange() {
        vectorStyleRevision &+= 1
        let defaults = currentBoundaryGlobalDefaults()
        for (key, old) in boundaryVectorStyleContexts {
            let updated = BoundaryLineGlobalStyleResolver.updated(current: old.settings,
                previousDefaults: old.globalDefaults, newDefaults: defaults)
            boundaryVectorStyleContexts[key] = BoundaryLineVisualContext(settings: updated,
                projectSessionID: old.projectSessionID, mapIndex: old.mapIndex,
                mapName: old.mapName, mapType: old.mapType, boundaryName: old.boundaryName,
                assetID: old.assetID, visualizationRevision: old.visualizationRevision,
                localOverrides: old.localOverrides, globalDefaults: defaults,
                vectorStyleRevision: vectorStyleRevision)
        }
        for state in mapStates.values {
            for entry in state.boundaryMap.entries {
                do {
                    let options = try loadBoundaryMapVisualStyles(for: entry.capture)
                    _ = state.boundaryMap.installVisualStyles(options, for: entry.capture)
                } catch {
                    report("Boundary Line Style", error)
                }
            }
        }
        mapRevision += 1
    }
    private func currentBoundaryGlobalDefaults() -> BoundaryLineVisualSettings {
        BoundaryLineGlobalStyleResolver.defaults(
            line: effectiveVectorStyle(definitionID: "BC_Line_Symbology"),
            vertex: effectiveVectorStyle(definitionID: "BC_Line_Vertex_Symbology")) ?? .init()
    }
    func vectorSymbologyContexts(mapID: UUID) -> [VectorSymbologyContext] {
        guard let map = catalogMapDocuments.first(where: { $0.id == mapID.uuidString }),
              let index = map.sourceIndex, ["Project", "Buildable"].contains(map.kind) else { return [] }
        let generic: [VectorSymbologyContext] = (vectorStyleNodes[mapID] ?? []).compactMap { node in
            guard let locator = node.sourceLocator, locator.nodeType == "MapLayer",
                  let path = locator.nodePath, !path.isEmpty,
                  let layerType = locator.mapType,
                  let url = sourceMapVectorURL(node) else { return nil }
            let properties = Dictionary(node.properties.map { ($0.id, $0.value) }, uniquingKeysWith: { _, last in last })
            let identity = VectorVisualNodeIdentity(mapIndex: index, mapName: map.name,
                mapType: map.kind, rootName: locator.rootName, nodePath: path,
                nodeType: locator.nodeType, nodeName: locator.nodeName, mapLayerType: layerType,
                filename: locator.filename, filenameRelative: locator.filenameRelative,
                assetID: SourceFilePaths.canonical(url),
                gdbLayerName: properties["Source/GdbLayerName"], gdbVectorType: properties["Source/GdbVectorType"])
            guard identity.supportedStyleDefinitionIDs != nil else { return nil }
            let renderedLayerID = sourceVectorInstanceID(node, mapID: mapID)
            return VectorSymbologyContext(projectSessionID: projectSessionID, mapID: mapID,
                assetID: node.assetID ?? url.path, layerID: renderedLayerID,
                visualizationRevision: visualization?.sourceRevision, visualNode: identity)
        }
        return generic + specializedVectorSymbologyContexts(mapID: mapID)
    }
    func vectorSymbologyContext(mapID: UUID, assetID: String?) -> VectorSymbologyContext {
        let choices = vectorSymbologyContexts(mapID: mapID)
        if let selected = inspectorTreeSession.selectedNode?.sourceLocator,
           let exact = choices.first(where: { choice in
               choice.visualNode?.nodePath == selected.nodePath
                   && choice.visualNode?.rootName == selected.rootName
                   && choice.visualNode?.nodeType == selected.nodeType
                   && choice.visualNode?.nodeName == selected.nodeName
                   && choice.visualNode?.mapLayerType == selected.mapType
               || (choice.specializedNode?.nodePath == selected.nodePath
                   && choice.specializedNode?.rootName == selected.rootName
                   && choice.specializedNode?.nodeType == selected.nodeType
                   && choice.specializedNode?.nodeName == selected.nodeName)
           }) { return exact }
        let candidates = choices.filter { choice in
            guard let assetID else { return true }
            if choice.layerID == assetID || choice.assetID == assetID { return true }
            guard let sourcePath = choice.visualNode?.assetID else { return false }
            let assetURL = assets.first(where: { $0.id == assetID })?.url ?? URL(fileURLWithPath: assetID)
            return sourcePath == SourceFilePaths.canonical(assetURL)
        }
        if candidates.count == 1 { return candidates[0] }
        return VectorSymbologyContext(projectSessionID: projectSessionID, mapID: mapID, assetID: assetID)
    }
    func refreshVectorSymbologyContexts(mapID: UUID) async {
        let captured = mapWorkflowIdentity(mapID)
        do {
            let nodes = try await sourceMapLayerNodes(mapID)
            guard captured == mapWorkflowIdentity(mapID), !Task.isCancelled else { return }
            vectorStyleNodes[mapID] = nodes
            vectorSymbologyContextRevision &+= 1
        } catch {
            if captured == mapWorkflowIdentity(mapID), !Task.isCancelled, !(error is CancellationError) {
                log("Vector Symbology", L10n.text(error.localizedDescription))
            }
        }
    }
    func vectorStyleLayerSource(_ context: VectorSymbologyContext) throws -> VectorSymbologyLayerSource? {
        guard context.scope == .layer, context.projectSessionID == projectSessionID,
              let identity = context.visualNode, let visualization,
              context.visualizationRevision == visualization.sourceRevision,
              vectorSymbologyContexts(mapID: context.mapID).contains(context),
              let ids = identity.supportedStyleDefinitionIDs,
              let layerID = context.layerID,
              let layer = mapState(for: context.mapID).vectors(mapLayers).first(where: {
                  $0.id == layerID && SourceFilePaths.canonical($0.url) == identity.assetID
              }) else { return nil }
        let defaults = Dictionary(uniqueKeysWithValues: ids.map { ($0, effectiveVectorStyle(definitionID: $0)) })
        let settings = try visualization.vectorVisualSettings(identity: identity, defaults: defaults)
        return VectorSymbologyLayerSource(context: context, layer: layer, settings: settings, defaults: defaults)
    }
    /// The live source tree must bind the persisted Geometry ancestor to
    /// exactly one current model asset. The `.vis` format stores only its name.
    private func specializedVectorSymbologyContexts(mapID: UUID) -> [VectorSymbologyContext] {
        guard let visualization,
              let map = catalogMapDocuments.first(where: { $0.id == mapID.uuidString }),
              let mapIndex = map.sourceIndex, ["Project", "Buildable"].contains(map.kind) else { return [] }
        let geometryNodes = (vectorStyleNodes[mapID] ?? []).filter {
            $0.sourceLocator?.nodeType == "Geometry" && $0.sourceLocator?.nodePath?.isEmpty == false
        }
        return geometryNodes.flatMap { node -> [VectorSymbologyContext] in
            guard let locator = node.sourceLocator,
                  let sourceAssetID = node.assetID ?? locator.assetID,
                  let asset = assets.first(where: {
                      $0.section == .geometries && $0.isModelFile
                          && SourceFilePaths.canonical($0.url) == SourceFilePaths.canonical(URL(fileURLWithPath: sourceAssetID))
                  }), asset.name == locator.nodeName,
                  assets.filter({ $0.section == .geometries && $0.isModelFile && $0.name == asset.name }).count == 1,
                  let owners = try? visualization.specializedVectorVisualNodes(mapIndex: mapIndex,
                      geometryName: asset.name, geometryAssetID: asset.id) else { return [] }
            return owners.filter { owner in
                owner.geometryNodePath == locator.nodePath && owner.rootName == locator.rootName
            }.map { owner in
                let path = owner.nodePath.map(String.init).joined(separator: ".")
                return VectorSymbologyContext(projectSessionID: projectSessionID, mapID: mapID,
                    assetID: asset.id, layerID: "geometry-vector/\(mapID.uuidString)/\(path)",
                    visualizationRevision: visualization.sourceRevision, specializedNode: owner)
            }
        }
    }

    func specializedVectorStyleSource(_ context: VectorSymbologyContext) throws -> SpecializedVectorSymbologySource? {
        guard context.scope == .layer, context.projectSessionID == projectSessionID,
              let owner = context.specializedNode, let visualization,
              context.visualizationRevision == visualization.sourceRevision,
              specializedVectorSymbologyContexts(mapID: context.mapID).contains(context),
              let ids = owner.definitionIDs else { return nil }
        let defaults = Dictionary(uniqueKeysWithValues: ids.map { ($0, effectiveVectorStyle(definitionID: $0)) })
        let raw = try visualization.specializedVectorVisualSettings(identity: owner, defaults: defaults)
        let key = SpecializedStyleCacheKey(projectSessionID: projectSessionID, mapID: context.mapID, owner: owner)
        let settings: VectorVisualSettingsSnapshot
        if let cached = specializedVectorStyleCache[key], cached.settings.revision == raw.revision {
            settings = VectorVisualSettingsDefaultSync.resolve(raw: raw, previous: cached.settings,
                previousDefaults: cached.defaults, newDefaults: defaults)
        } else { settings = raw }
        specializedVectorStyleCache[key] = SpecializedStyleCacheEntry(settings: settings, defaults: defaults)
        return SpecializedVectorSymbologySource(context: context, settings: settings, defaults: defaults)
    }

    var geometryVectorStyleContextIdentity: String {
        "\(projectSessionID)|\(lastActiveMapID)|\(visualization?.sourceRevision ?? "")"
    }

    func effectiveGeometryVectorStyle(definitionID: String, session: ModelEditorSession, nodeType: String) -> VectorStyleValues {
        guard editorSessions[session.id] === session, session.loaded,
              let context = specializedVectorSymbologyContexts(mapID: lastActiveMapID).first(where: {
                  $0.assetID == session.modelAssetID && $0.specializedNode?.nodeType == nodeType
              }), let source = try? specializedVectorStyleSource(context),
              let local = source.settings.options[definitionID]?.values else {
            return effectiveVectorStyle(definitionID: definitionID)
        }
        return local
    }

    func effectiveGeometryVectorStyle(definitionID: String, session: GeometryTopologySession, nodeType: String) -> VectorStyleValues {
        guard let parent = editorSessions.values.first(where: { $0.geometryTopology === session }) else {
            return effectiveVectorStyle(definitionID: definitionID)
        }
        return effectiveGeometryVectorStyle(definitionID: definitionID, session: parent, nodeType: nodeType)
    }

    func effectiveGeometryVectorStyle(definitionID: String, session: GeometryMeshSession, nodeType: String) -> VectorStyleValues {
        guard let parent = editorSessions.values.first(where: { $0.geometryMesh === session }) else {
            return effectiveVectorStyle(definitionID: definitionID)
        }
        return effectiveGeometryVectorStyle(definitionID: definitionID, session: parent, nodeType: nodeType)
    }

    func commitSpecializedVectorStyleOptions(_ options: [String: VectorVisualSettingsOptions],
        context: VectorSymbologyContext, defaults: [String: VectorStyleValues]) throws {
        guard let source = try specializedVectorStyleSource(context), source.defaults == defaults,
              let owner = context.specializedNode, let visualization else { throw ProjectFileError.modifiedExternally }
        try visualization.saveSpecializedVectorVisualSettings(identity: owner, options: options,
            defaults: defaults, expectedRevision: context.visualizationRevision)
        installVisualizationMaps(visualization)
        do { try refreshRasterMapSources() } catch { report("Vector Symbology", error) }
        configureRasterSymbologyProvider()
        let key = SpecializedStyleCacheKey(projectSessionID: projectSessionID, mapID: context.mapID, owner: owner)
        specializedVectorStyleCache[key] = SpecializedStyleCacheEntry(
            settings: VectorVisualSettingsSnapshot(options: options, revision: visualization.sourceRevision), defaults: defaults)
        vectorStyleRevision &+= 1; vectorSymbologyContextRevision &+= 1; mapRevision &+= 1
    }

    func beginVectorStyleMutation() -> Bool {
        guard !isRunningProjectTool, !isSavingAll, !isOpeningProject, !isClosingTab else { return false }
        isRunningMapMutation = true
        return true
    }
    func endVectorStyleMutation() { isRunningMapMutation = false }

    // Keep map registry and visualization mutation state private while allowing
    // StoreMapWorkflows to use these narrowly scoped lifecycle operations.
    func isCurrentMapState(_ state: MapState, mapID: UUID) -> Bool {
        mapStates[mapID] === state
    }

    func isCurrentMapState(_ state: MapState, mapID: UUID, projectSessionID expectedSession: UUID) -> Bool {
        projectSessionID == expectedSession && mapStates[mapID] === state
    }

    /// Looks up a map state without creating one. Async map workflows use this
    /// after suspension so a cancelled request cannot resurrect a removed map.
    func existingMapState(for id: UUID) -> MapState? {
        mapStates[id]
    }

    @discardableResult
    func acceptSavedShapefileFamily(_ family: MapSourceFamilyCapture,
        previousFamily: MapSourceFamilyCapture, scope: PolylineMapEditingScope,
        expectedMapState: MapState) -> Bool {
        guard projectSessionID == scope.projectSessionID,
              mapStates[scope.mapID] === expectedMapState,
              expectedMapState.polylineEditor.currentScope == scope,
              SourceFilePaths.canonical(URL(fileURLWithPath: family.sourcePath)) == scope.canonicalPath,
              SourceFilePaths.canonical(URL(fileURLWithPath: previousFamily.sourcePath)) == scope.canonicalPath,
              family.family == previousFamily.family,
              URL(fileURLWithPath: scope.canonicalPath).pathExtension.lowercased() == "shp",
              family.files.contains(where: { $0.role == "source" && $0.exists && $0.revision != nil
                  && SourceFilePaths.canonical(URL(fileURLWithPath: $0.path)) == scope.canonicalPath }),
              let current = sourceMapVectorFamilyCaptures[scope.mapID]?[scope.canonicalPath],
              current == previousFamily || current == family else { return false }
        sourceMapVectorFamilyCaptures[scope.mapID, default: [:]][scope.canonicalPath] = family
        return true
    }

    func beginAssociatedRasterStyleMutation() -> Bool {
        guard !isRunningProjectTool, !isSavingAll, !isOpeningProject,
              !isClosingTab, !isRunningMapMutation else { return false }
        isRunningMapMutation = true
        return true
    }

    func endAssociatedRasterStyleMutation() {
        isRunningMapMutation = false
    }

    func beginMapMeshErrorMutation(mapID: UUID, projectSessionID expectedSession: UUID,
                                   workflowIdentity: String) -> Bool {
        guard projectSessionID == expectedSession, existingMapState(for: mapID) != nil,
              mapWorkflowIdentity(mapID) == workflowIdentity,
              !isRunningProjectTool, !isSavingAll, !isOpeningProject, !isClosingTab,
              !isRunningMapMutation, !hasBusyModelEditors else { return false }
        isRunningMapMutation = true
        return true
    }

    func endMapMeshErrorMutation() { isRunningMapMutation = false }

    func beginProjectUMLMutation() -> Bool {
        guard !isRunningProjectTool, !isSavingAll, !isOpeningProject, !isClosingTab,
              !isRunningMapMutation else { return false }
        isRunningMapMutation = true
        return true
    }

    func endProjectUMLMutation() {
        isRunningMapMutation = false
    }

    /// Persists only the Project UML section through the source `.vis` writer.
    /// The shared map-mutation gate prevents overlap with map/tree and style
    /// writes; VisualizationDocument then adopts only UML over its saved
    /// baseline, leaving pending Saved Views and map drafts untouched.
    @discardableResult
    func saveProjectUMLPositions(_ positions: [ProjectUMLPosition]) throws -> String {
        guard beginProjectUMLMutation() else {
            throw ProjectFileError.invalid("The project is busy. Try saving UML positions again.")
        }
        defer { endProjectUMLMutation() }
        guard let project = document, let projectURL = project.url, let visualization else {
            throw ProjectFileError.invalid("Open a saved project before changing UML positions.")
        }
        let expectedProjectSession = projectSessionID
        let expectedVisualization = visualization
        let expectedRevision = visualization.sourceRevision
        let newRevision = try ProjectUMLVisualizationFile.savePositions(
            projectURL: projectURL, positions: positions,
            expectedPreviousRevision: expectedRevision)
        guard projectSessionID == expectedProjectSession, document === project,
              project.url == projectURL, self.visualization === expectedVisualization else {
            throw ProjectFileError.modifiedExternally
        }
        try expectedVisualization.acceptExternalProjectUMLChange(
            expectedPreviousRevision: expectedRevision, newRevision: newRevision)

        installVisualizationMaps(expectedVisualization)
        vectorStyleRevision &+= 1
        vectorSymbologyContextRevision &+= 1
        layerTreeSession.invalidate()
        catalogTreeSession.invalidate()
        assetsRevision += 1
        mapRevision += 1
        do { try refreshRasterMapSources() }
        catch { report("Project UML", error) }
        configureRasterSymbologyProvider()
        loadRasterMapLayers()
        return newRevision
    }

    func acceptAssociatedRasterStyleMapChange(oldRevision: String?, newRevision: String) throws {
        guard let visualization else { throw ProjectFileError.modifiedExternally }
        try visualization.acceptExternalMapChange(expectedPreviousRevision: oldRevision,
            newRevision: newRevision)
        installVisualizationMaps(visualization)
        try refreshRasterMapSources()
        configureRasterSymbologyProvider()
        loadRasterMapLayers()
        assetsRevision += 1
    }

    func readBoundaryMapVisualOptions(identity: BoundaryVectorVisualNodeIdentity,
        defaults: [String: VectorStyleValues]) throws -> VectorVisualSettingsSnapshot {
        guard let visualization else { throw ProjectFileError.modifiedExternally }
        return try visualization.boundaryVectorVisualSettings(identity: identity, defaults: defaults)
    }

    /// The style provider validates the exact map/source owner and acquires the
    /// map-mutation lease before entering this synchronous atomic publication.
    /// The owned document merges its pending saved views with the new .vis map
    /// bytes, so editing line color cannot discard an unrelated view draft.
    func commitBoundaryMapVisualOptions(identity: BoundaryVectorVisualNodeIdentity,
        options: [String: VectorVisualSettingsOptions], defaults: [String: VectorStyleValues],
        expectedRevision: String, resetToDefaults: Bool) throws -> String {
        guard isRunningMapMutation, let visualization else { throw ProjectFileError.modifiedExternally }
        try visualization.saveBoundaryVectorVisualSettings(identity: identity, options: options,
            defaults: defaults, expectedRevision: expectedRevision, resetToDefaults: resetToDefaults)
        guard let revision = visualization.sourceRevision else { throw ProjectFileError.modifiedExternally }
        installVisualizationMaps(visualization)
        do { try refreshRasterMapSources() }
        catch { report("Boundary Line Style", error) }
        configureRasterSymbologyProvider()
        loadRasterMapLayers()
        vectorSymbologyContextRevision &+= 1
        assetsRevision &+= 1
        return revision
    }

    func commitVectorStyleOptions(_ options: [String: VectorVisualSettingsOptions],
        context: VectorSymbologyContext, defaults: [String: VectorStyleValues]) throws {
        guard context.projectSessionID == projectSessionID, let identity = context.visualNode,
              let source = try vectorStyleLayerSource(context), let visualization,
              source.defaults == defaults else {
            throw ProjectFileError.modifiedExternally
        }
        try visualization.saveVectorVisualSettings(identity: identity, options: options,
            defaults: defaults, expectedRevision: context.visualizationRevision)
        installVisualizationMaps(visualization)
        // The vector edit has already committed atomically. A malformed,
        // unrelated raster descriptor must not report this successful write
        // as a rejected style edit or prevent the new vector style rendering.
        do { try refreshRasterMapSources() }
        catch { report("Vector Symbology", error) }
        configureRasterSymbologyProvider()
        vectorSymbologyContextRevision &+= 1
        invalidateMapCharts(mapID: context.mapID)
    }
    func boundaryLineVisualOverrides(for session: ModelEditorSession) throws -> BoundaryLineVisualOverrides? {
        guard let context = try boundaryLineVisualContext(for: session), let visualization else { return nil }
        return try visualization.boundaryLineVisualOverrides(mapIndex: context.mapIndex, boundaryName: context.boundaryName)
    }
    func meshDiagnosticsPreferencesIdentity(for session: ModelEditorSession) -> String {
        "\(projectSessionID)|\(session.modelAssetID ?? "")|\(lastActiveMapID)|\(visualization?.sourceRevision ?? "")"
    }
    func boundaryLineVisualSettingsIdentity(for session: ModelEditorSession) -> String {
        "\(projectSessionID)|\(session.modelAssetID ?? "")|\(lastActiveMapID)|\(visualization?.sourceRevision ?? "")|\(session.loaded)"
    }
    func boundaryLineVisualContext(for session: ModelEditorSession) throws -> BoundaryLineVisualContext? {
        guard let visualization, session.loaded,
              editorSessions[session.id] === session,
              let asset = assets.first(where: { $0.id == session.modelAssetID && $0.section == .boundaryConditions && $0.isModelFile }) else { return nil }
        let source = visualizationMapIdentities.values.first { visualizationMapIDs[$0.index] == lastActiveMapID }
            ?? (visualization.maps.isEmpty && lastActiveMapID == MapState.projectMapID
                ? VisualizationMapIdentity(index: 0, name: "Map", type: "Project") : nil)
        guard let source, ["Project", "Buildable"].contains(source.type) else { return nil }
        guard assets.filter({ $0.section == .boundaryConditions && $0.isModelFile && $0.name == asset.name }).count == 1 else {
            throw ProjectFileError.invalid("The boundary condition has ambiguous visual contexts in this map.")
        }
        let defaults = currentBoundaryGlobalDefaults()
        let overrides = try visualization.boundaryLineVisualOverrides(mapIndex: source.index, boundaryName: asset.name)
        let key = "\(projectSessionID)|\(source.index)|\(asset.id)"
        let settings: BoundaryLineVisualSettings
        if let cached = boundaryVectorStyleContexts[key], cached.visualizationRevision == visualization.sourceRevision {
            settings = BoundaryLineGlobalStyleResolver.updated(current: cached.settings,
                previousDefaults: cached.globalDefaults, newDefaults: defaults)
        } else {
            settings = try visualization.boundaryLineVisualSettings(mapIndex: source.index,
                boundaryName: asset.name, globalDefaults: defaults)
        }
        let context = BoundaryLineVisualContext(settings: settings, projectSessionID: projectSessionID,
            mapIndex: source.index, mapName: source.name, mapType: source.type,
            boundaryName: asset.name, assetID: asset.id, visualizationRevision: visualization.sourceRevision,
            localOverrides: overrides, globalDefaults: defaults, vectorStyleRevision: vectorStyleRevision)
        boundaryVectorStyleContexts[key] = context
        return context
    }
    func saveBoundaryLineVisualSettings(_ settings: BoundaryLineVisualSettings,
        context: BoundaryLineVisualContext, session: ModelEditorSession) throws {
        guard context.vectorStyleRevision == vectorStyleRevision else {
            throw ProjectFileError.invalid("Global style defaults changed while the style editor was open. Reopen it to apply.")
        }
        guard !isRunningProjectTool, !isOpeningProject, !isSavingAll, !isClosingTab,
              !session.isBusy, !session.loadingSelection, let visualization,
              let current = try boundaryLineVisualContext(for: session), current == context else {
            throw ProjectFileError.modifiedExternally
        }
        isRunningMapMutation = true
        defer { isRunningMapMutation = false }
        try visualization.saveBoundaryLineVisualSettings(settings,
            mapIndex: context.mapIndex, boundaryName: context.boundaryName,
            globalDefaults: context.globalDefaults)
        installVisualizationMaps(visualization)
        // Adding a missing source node can change positional raster locators.
        // Refresh all descriptors before a later map writer consumes them.
        do { try refreshRasterMapSources() }
        catch { report("Boundary Line Style", error) }
        configureRasterSymbologyProvider()
        // Tree contexts include the .vis source revision through catalogMapDocuments,
        // so their keyed loads refresh the inserted source node while retaining a
        // still-valid selection. A style-only .vis edit does not change HDF assets.
        invalidateMapCharts(mapID: lastActiveMapID)
    }
    func installMeshDiagnosticsPreferences(for session: ModelEditorSession) {
        guard let visualization, let mesh = session.geometryMesh,
              let asset = assets.first(where: { $0.id == session.modelAssetID && $0.section == .geometries }),
              mesh.assetIdentity == asset.id else { return }
        let source = visualizationMapIdentities.values.first { visualizationMapIDs[$0.index] == lastActiveMapID }
            ?? (visualization.maps.isEmpty && lastActiveMapID == MapState.projectMapID
                ? VisualizationMapIdentity(index: 0, name: "Map", type: "Project") : nil)
        guard let source else { return }
        do {
            let settings = try visualization.meshDiagnosticsSettings(mapIndex: source.index, geometryName: asset.name)
            _ = mesh.installDiagnosticsPreferences(settings, scope: .init(mapIndex: source.index,
                mapName: source.name, mapType: source.type, geometryName: asset.name, assetID: asset.id,
                visualizationRevision: visualization.sourceRevision))
        } catch { mesh.error = L10n.text(error.localizedDescription) }
    }
    func persistMeshDiagnosticsPreferences(_ capture: GeometryMeshDiagnosticsPreferencesCapture) throws -> String {
        guard !isRunningProjectTool, !isOpeningProject,
              let visualization, visualization.sourceRevision == capture.scope.visualizationRevision,
              assets.contains(where: { $0.id == capture.scope.assetID && $0.section == .geometries
                  && $0.name == capture.scope.geometryName }) else { throw ProjectFileError.modifiedExternally }
        let map = visualization.maps.first { $0.index == capture.scope.mapIndex }
            ?? (visualization.maps.isEmpty && capture.scope.mapIndex == 0
                ? VisualizationMapIdentity(index: 0, name: "Map", type: "Project") : nil)
        guard map?.name == capture.scope.mapName, map?.type == capture.scope.mapType else {
            throw ProjectFileError.modifiedExternally
        }
        isRunningMapMutation = true
        defer { isRunningMapMutation = false }
        try visualization.saveMeshDiagnosticsSettings(capture.settings, mapIndex: capture.scope.mapIndex,
            geometryName: capture.scope.geometryName)
        installVisualizationMaps(visualization)
        // Node insertion can shift serialized raster node paths. Rebuild the
        // descriptors against the new .vis baseline before the next writer.
        do { try refreshRasterMapSources() }
        catch { report("Mesh Diagnostics", error) }
        configureRasterSymbologyProvider()
        layerTreeSession.invalidate(); assetsRevision += 1
        guard let revision = visualization.sourceRevision else { throw ProjectFileError.modifiedExternally }
        return revision
    }
    func unregisterEditor(_ session: ModelEditorSession) {
        guard !session.hasUnsavedEditorChanges, !session.isBusy,
              initialConditionsCommitOwner?.editorID != session.id else { return }
        editorSessions[session.id] = nil; editorSubscriptions[session.id] = nil
        primaryEditorIDs = primaryEditorIDs.filter { $0.value != session.id }
    }
    var canCloseActiveTab: Bool {
        switch activeTab { case .editor, .map, .chat, .chatDisplay: true; case .page: false }
    }
    func requestCloseActiveTab() { requestCloseTab(activeTab) }
    func requestCloseTab(_ tab: WorkspaceTab) {
        guard !isSavingAll, !isClosingTab, !isRunningProjectTool else { return }
        switch tab {
        case .page: return
        case .editor(let kind):
            guard openEditors.contains(kind) else { return }
            if let id = primaryEditorIDs[kind], editorSessions[id]?.isBusy == true {
                errorMessage = L10n.text("Wait for the model operation to finish before closing.")
                return
            }
            if let id = primaryEditorIDs[kind], let session = editorSessions[id],
               session.hasUnsavedEditorChanges {
                pendingCloseTab = tab; showCloseTabConfirmation = true; return
            }
        case .map(let id):
            guard mapDocuments.contains(where: { $0.id == id }) else { return }
            let editor = mapState(for: id).polylineEditor
            guard !editor.isBusy else { return }
            if editor.hasUnsavedChanges { pendingCloseTab = tab; showCloseTabConfirmation = true; return }
        case .chat: guard chatIsOpen else { return }
        case .chatDisplay(let id): guard chatDisplayDocuments.contains(where: { $0.id == id }) else { return }
        }
        finishClosingTab(tab)
    }
    @discardableResult
    func saveAndCloseTab() async -> Bool {
        guard let tab = pendingCloseTab, !isSavingAll, !isClosingTab else { return false }
        let project = projectSessionID
        isClosingTab = true; showCloseTabConfirmation = false
        defer { isClosingTab = false }
        if case .map(let id) = tab {
            let editor = mapState(for: id).polylineEditor
            guard !editor.isBusy, await editor.save(), !editor.hasUnsavedChanges, projectSessionID == project else { return false }
            finishClosingTab(tab); return true
        }
        guard case .editor(let kind) = tab, let id = primaryEditorIDs[kind], let session = editorSessions[id] else { return false }
        let saved = await session.saveLoadedModel()
        guard saved, !session.hasUnsavedEditorChanges, projectSessionID == project else {
            errorMessage = session.error ?? L10n.text("Some model edits are still unsaved. Save them before continuing.")
            pendingCloseTab = nil; return false
        }
        finishClosingTab(tab); return true
    }
    func discardAndCloseTab() {
        guard let tab = pendingCloseTab, !isClosingTab, !isSavingAll else { return }
        if case .map(let id) = tab {
            let editor = mapState(for: id).polylineEditor
            guard !editor.isBusy else { return }
            editor.discardForProjectReplacement()
        }
        if case .editor(let kind) = tab, let id = primaryEditorIDs[kind], let session = editorSessions[id] {
            guard !session.isBusy else { return }
            session.discardEdits()
            guard !session.hasUnsavedEditorChanges, !session.isBusy else { return }
        }
        finishClosingTab(tab)
    }
    func cancelCloseTab() { pendingCloseTab = nil; showCloseTabConfirmation = false }
    private func finishClosingTab(_ tab: WorkspaceTab) {
        switch tab {
        case .editor(let kind):
            openEditors.removeAll { $0 == kind }; editorAssetRequests[kind] = nil
            if let id = primaryEditorIDs[kind], let session = editorSessions[id] { unregisterEditor(session) }
        case .map(let id):
            // A detached map can still own this viewport. Keep its state until
            // project replacement, rather than resetting an open document.
            mapDocuments.removeAll { $0.id == id }
        case .chat: chatIsOpen = false
        case .chatDisplay(let id): chatDisplayDocuments.removeAll { $0.id == id }
        case .page: return
        }
        if activeTab == tab { activeTab = .page(.map) }
        pendingCloseTab = nil; showCloseTabConfirmation = false
    }
    @discardableResult
    func saveAll() async -> Bool {
        guard !isSavingAll, !isClosingTab, !isOpeningProject, !isRunningProjectTool else { return false }
        guard preflightIncompleteEditorInputs() else { return false }
        let currentProject = projectSessionID
        isSavingAll = true
        defer { isSavingAll = false }
        guard await persistModelEdits(in: currentProject) else { return false }
        for state in mapStates.values.sorted(by: { $0.id.uuidString < $1.id.uuidString }) where state.polylineEditor.hasUnsavedChanges {
            guard await state.polylineEditor.save(), currentProject == projectSessionID else {
                errorMessage = L10n.text(state.polylineEditor.errorMessage ?? "Some map edits are still unsaved. Save them before continuing.")
                return false
            }
        }
        guard projectSessionID == currentProject else { return false }
        if document != nil, !save() { return false }
        return !hasUnsavedChanges
    }
    @discardableResult
    func saveModelEditsOnly() async -> Bool {
        guard !isSavingAll, !isClosingTab, !isOpeningProject, !isRunningProjectTool else { return false }
        guard preflightIncompleteEditorInputs() else { return false }
        let currentProject = projectSessionID
        isSavingAll = true; defer { isSavingAll = false }
        return await persistModelEdits(in: currentProject) && projectSessionID == currentProject && !hasUnsavedModelEdits
    }
    private func preflightIncompleteEditorInputs() -> Bool {
        for editor in editorSessions.values.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            guard let issue = editor.incompleteEditorInputIssue else { continue }
            errorMessage = issue
            return false
        }
        return true
    }
    private func persistModelEdits(in currentProject: UUID) async -> Bool {
        if stableChannelDebug.hasUnsavedChanges {
            guard stableChannelDebug.projectOwner == currentProject,
                  await stableChannelDebug.save(), projectSessionID == currentProject else {
                errorMessage = L10n.text(stableChannelDebug.message ?? "Some model edits are still unsaved. Save them before continuing.")
                return false
            }
        }
        let editors = editorSessions.values.filter { $0.hasUnsavedEditorChanges }.sorted { $0.id.uuidString < $1.id.uuidString }
        for editor in editors {
            guard await editor.saveLoadedModel(), projectSessionID == currentProject else {
                if let message = editor.error { errorMessage = L10n.text(message) }
                else { errorMessage = L10n.text("Some model edits are still unsaved. Save them before continuing.") }
                return false
            }
        }
        return projectSessionID == currentProject
    }
    func discardAllChanges() -> Bool {
        guard !isSavingAll, !isRunningProjectTool, !hasBusyModelEditors else { return false }
        // This entry is reached after an explicit Discard decision. Ordinary
        // project replacement must not bypass a child visual-settings draft.
        for session in editorSessions.values { session.geometryMesh?.invalidateDiagnosticsPreferences() }
        stableChannelDebug.discard()
        for state in mapStates.values { state.polylineEditor.discardForProjectReplacement() }
        if let url = document?.url { return open(url) }
        resetProjectWorkspace(); return true
    }
    func presentSurfaceCreation(_ kind: SurfaceCreationKind) {
        guard document?.url != nil, modelProvider is BackendModelProvider,
              !isRunningProjectTool, !isSavingAll, !isClosingTab, !isOpeningProject else { return }
        surfaceCreation = kind
    }
    func setSurfaceCreationRunning(_ running: Bool) { isCreatingSurface = running }
    func completeSurfaceCreation(_ result: SurfaceCreationResult, kind: SurfaceCreationKind, projectID: UUID) {
        guard projectSessionID == projectID, result.section == kind.section.rawValue else {
            errorMessage = L10n.text("The project changed while the model was being created.")
            return
        }
        refreshAssets()
        let createdURL = URL(fileURLWithPath: result.assetPath).standardizedFileURL
        guard let asset = assets.first(where: { $0.url.standardizedFileURL == createdURL && $0.section == kind.section }) else {
            errorMessage = L10n.text("The created model could not be found in the project catalog.")
            return
        }
        surfaceCreation = nil
        assetsRevision += 1
        select(asset)
        openEditor(kind.editorKind, assetID: asset.id)
        log("Create", asset.name, defaultAction: .openEditor(projectSessionID: projectSessionID,
            editorKind: kind.editorKind.rawValue, assetID: asset.id))
    }
    func refreshAssets() {
        guard !isRunningRasterMutation, !isRunningPlanCompute else { return }
        do {
            try document?.reloadAssets(); assets = document?.assets ?? []; loadMapLayers()
            try refreshRasterMapSources(); configureRasterSymbologyProvider(); loadRasterMapLayers()
            log("Refresh", L10n.text("Refreshed project files."))
        }
        catch { report("Refresh", error) }
    }
    func setProjection(type: String, value: String) -> Bool {
        guard !isRunningRasterMutation, !isRunningPlanCompute else { return false }
        do {
            try document?.setProjection(type: type, value: value)
            assetsRevision += 1
            isModified = true; showProjection = false; loadRasterMapLayers(); return true
        }
        catch { report("Projection", error); return false }
    }
    func setAssociation(_ association: ProjectAssociation, field: String, value: String) {
        guard !isRunningProjectTool, !isSavingAll, !isClosingTab, !isOpeningProject,
              (association.group == "PlanAssociations" || !hasBusyModelEditors), let document,
              document.associationRows(group: association.group).first(where: { $0.id == association.id })?.fields[field] != value else { return }
        do {
            try document.setAssociation(association, field: field, value: value); isModified = true
            assetsRevision += 1
            if association.group == "PlanAssociations" {
                for session in editorSessions.values where session.modelName == association.name {
                    session.requestProjectContextRefresh()
                }
            } else if association.group == "GeometryAssociations" {
                for session in editorSessions.values where session.modelName == association.name && !session.isSourcePlan {
                    session.requestGeometryProjectContextRefresh()
                }
            }
        }
        catch { report("Associations", error) }
    }
    func setDefaultTerrain(_ value: String) {
        guard !isRunningProjectTool, !isSavingAll, !isClosingTab, !isOpeningProject,
              !hasBusyModelEditors, let document, document.defaultTerrain != value,
              assets.contains(where: { $0.section == .terrains && $0.isModelFile && $0.name == value }) else { return }
        document.defaultTerrain = value
        assetsRevision += 1
        isModified = true
        loadRasterMapLayers()
    }
    func revealProject() { if let url = document?.url { system.reveal(url) } }
    func revealSelected() { if let asset = selectedAsset { system.reveal(asset.url) } }
    func locateResult(asset: ProjectAsset) {
        guard asset.section == .results, assets.contains(asset) else { return }
        sidebarSection = .catalog
        select(asset)
        if let node = catalogTreeSession.roots?.lazy.compactMap({ root -> LayerTreeNode? in
            func find(_ node: LayerTreeNode) -> LayerTreeNode? {
                if node.assetID == asset.id { return node }
                return node.children?.lazy.compactMap(find).first
            }
            return find(root)
        }).first {
            catalogTreeSession.revealNode(node.id)
        }
    }
    func beginResultDeletion(assetID: String, projectSessionID expectedSession: UUID) -> Bool {
        guard projectSessionID == expectedSession, !isRunningProjectTool, !isSavingAll,
              !isClosingTab, !isOpeningProject, !hasBusyModelEditors,
              assets.contains(where: { $0.id == assetID && $0.section == .results }) else { return false }
        do { try visualization?.validateSourceUnchanged() }
        catch { report("Delete Result", error); return false }
        isDeletingResult = true
        return true
    }
    func endResultDeletion(projectSessionID expectedSession: UUID) {
        if projectSessionID == expectedSession { isDeletingResult = false }
    }
    func beginCatalogModelAction(assetID: String, projectSessionID expectedSession: UUID) -> Bool {
        errorMessage = nil
        guard projectSessionID == expectedSession, document?.url != nil,
              assets.contains(where: { $0.id == assetID && [.geometries, .plans, .terrains, .boundaryConditions, .surfaceLayers].contains($0.section) }),
              !isRunningProjectTool, !isSavingAll, !isClosingTab, !isOpeningProject, !hasBusyModelEditors else { return false }
        guard !editorSessions.values.contains(where: { $0.modelAssetID == assetID && $0.hasUnsavedEditorChanges }) else {
            errorMessage = L10n.text("Save or discard this model's editor changes before managing its source file.")
            return false
        }
        do { try visualization?.validateSourceUnchanged() }
        catch { errorMessage = L10n.text(error.localizedDescription); return false }
        isRunningCatalogModelAction = true
        return true
    }
    func beginPlanCompute(editorID: UUID, assetID: String, dependencyPaths: [String],
        writePaths: [String], projectSessionID expectedSession: UUID,
        capture: WorkspaceResultComputeCapture) -> Bool {
        errorMessage = nil
        if let issue = editorSessions[editorID]?.incompleteEditorInputIssue {
            errorMessage = issue
            return false
        }
        guard projectSessionID == expectedSession, document?.url != nil,
              let editor = editorSessions[editorID], editor.modelAssetID == assetID,
              capture.projectSessionID == expectedSession, capture.editorID == editorID,
              capture.planPath == Self.computeCanonicalPath(assetID),
              capture.planRevision == editor.sourceFileRevision,
              let projectURL = document?.url, let projectRevision = document?.sourceRevision,
              capture.projectPath == Self.computeCanonicalPath(projectURL.path),
              capture.projectRevision == projectRevision,
              assets.contains(where: { $0.id == assetID && $0.section == .plans }),
              !isRunningProjectTool, !isSavingAll, !isClosingTab, !isOpeningProject,
              editor.incompleteEditorInputIssue == nil,
              !editor.isSaving, !editor.isPerforming, !editor.isRefreshingContext,
              !editor.loadingSelection, !editor.hasPendingGeometryEdit,
              !hasBusyMapEditors, !catalogTreeSession.busy, !layerTreeSession.busy,
              !editorSessions.values.contains(where: { $0.id != editorID && $0.isBusy }) else {
            errorMessage = L10n.text("Finish the current project operation before computing the plan.")
            return false
        }
        let dependencies = Set(dependencyPaths.map(Self.computeCanonicalPath))
        guard dependencies.contains(Self.computeCanonicalPath(assetID)),
              Set(writePaths.map(Self.computeCanonicalPath)).isSubset(of: dependencies) else {
            errorMessage = L10n.text("The compute inspection no longer identifies the plan and its source dependencies.")
            return false
        }
        guard !editorSessions.values.contains(where: {
            $0.id != editorID && $0.hasUnsavedEditorChanges
                && $0.modelAssetID.map({ dependencies.contains(Self.computeCanonicalPath($0)) }) == true
        }) else {
            errorMessage = L10n.text("Save or discard the associated model editor changes before computing this plan.")
            return false
        }
        guard !mapStates.values.contains(where: { state in
            state.polylineEditor.hasUnsavedChanges && state.polylineEditor.currentScope.map {
                dependencies.contains(Self.computeCanonicalPath($0.canonicalPath))
            } == true
        }) else {
            errorMessage = L10n.text("Save or discard the associated map line edits before computing this plan.")
            return false
        }
        planComputeOwnerID = editorID
        planComputeWritePaths = Set(writePaths.map(Self.computeCanonicalPath))
        activePlanComputeCapture = capture
        isRunningPlanCompute = true
        // Keep the accepted map choices visible while stopping source readers
        // before the compute invocation opens its Result output for writing.
        for state in mapStates.values {
            state.terrainInputMap.suspendSourceReads()
            state.meshErrors.suspendSourceReads()
            state.resultSources.beginPlanCompute(capture)
            state.resultSources.suspendSourceReads()
            state.resultMap.beginPlanCompute(capture)
            state.resultMap.suspendSourceReads()
        }
        return true
    }
    private func acceptResultComputeProgress(_ envelope: BackendResultComputeUpdate,
        update: BackendProgressUpdate, editorID: UUID, projectSessionID expectedSession: UUID,
        operationOwnerToken: String, operationContextID: String) {
        guard projectSessionID == expectedSession,
              let capture = activePlanComputeCapture,
              let session = editorSessions[editorID],
              session.planCompute?.currentOperationOwner == operationOwnerToken,
              session.planCompute?.currentOperationContextID == operationContextID,
              let rawEntry = WorkspaceResultComputeReducer.acceptProgress(envelope, progress: update,
                capture: capture, activeCapture: activePlanComputeCapture,
                projectSessionID: projectSessionID, editorID: editorID,
                operationOwnerToken: operationOwnerToken, operationContextID: operationContextID),
              WorkspaceResultComputeReducer.shouldReplace(liveResultComputeByPath[rawEntry.resultPath], with: rawEntry) else { return }
        let entry = LiveMapResultSelectionProjection.carryingProfiles(
            from: liveResultComputeByPath[rawEntry.resultPath], into: rawEntry,
            update: update.resultProfiles)
        liveResultComputeByPath[entry.resultPath] = entry
        catalogTreeSession.upsertTransientResultComputeRow(entry)
        for state in mapStates.values { state.resultSources.acceptPlanComputeEntry(entry) }
        publishPlanComputeLiveMapTargets()
        refreshHistoricalResultsDuringCompute(capture: capture, entry: entry)
    }

    /// A validated writer callback permits isolated readers for other Result
    /// paths. Coalesce progress bursts per map and keep every read bound to
    /// the exact run, protected files and original map owner across awaits.
    private func refreshHistoricalResultsDuringCompute(capture: WorkspaceResultComputeCapture,
                                                       entry: WorkspaceResultComputeEntry) {
        guard let lease = mapResultComputeReadLease,
              activePlanComputeCapture == capture, entry.status == .running,
              LiveMapResultRunIdentity(entry: entry).matches(capture) else { return }
        for (mapID, state) in mapStates {
            guard historicalResultReadTasks[mapID] == nil else { continue }
            let workflow = mapWorkflowIdentity(mapID)
            let taskID = UUID()
            let task = Task { @MainActor [weak self, weak state] in
                guard let self, let state else { return }
                defer {
                    if self.historicalResultReadTasks[mapID]?.id == taskID {
                        self.historicalResultReadTasks.removeValue(forKey: mapID)
                    }
                }
                let current: @MainActor () -> Bool = { [weak self, weak state] in
                    guard let self, let state, !Task.isCancelled,
                          self.mapResultComputeReadLease == lease,
                          self.activePlanComputeCapture == capture,
                          self.isCurrentMapState(state, mapID: mapID,
                            projectSessionID: capture.projectSessionID),
                          self.mapWorkflowIdentity(mapID) == workflow,
                          let live = self.liveResultComputeByPath[entry.resultPath],
                          live.status == .running,
                          LiveMapResultRunIdentity(entry: live) == LiveMapResultRunIdentity(entry: entry)
                    else { return false }
                    return true
                }
                guard current(), let snapshot = await state.resultSources.refreshHistoricalResultsDuringCompute(
                    lease: lease, capture: capture, entry: entry, readIsCurrent: current),
                    current() else { return }
                _ = await state.resultMap.refreshHistoricalResultsDuringCompute(
                    snapshot: snapshot, capture: capture, entry: entry, lease: lease,
                    isCurrent: { [weak state] in
                        current() && state?.resultSources.snapshot?.sources.contextToken == snapshot.sources.contextToken
                            && state?.resultSources.snapshot?.map.computeReadLease == lease
                    })
            }
            historicalResultReadTasks[mapID] = (taskID, task)
        }
    }

    private func cancelHistoricalResultReads() {
        for flight in historicalResultReadTasks.values { flight.task.cancel() }
        historicalResultReadTasks = [:]
    }

    /// The compute process owns its writing Result. Send view requests to that
    /// process instead of opening a second HDF reader while it is writing.
    func publishPlanComputeLiveMapTargets() {
        guard let editorID = planComputeOwnerID,
              let compute = editorSessions[editorID]?.planCompute else { return }
        guard isRunningPlanCompute, let capture = activePlanComputeCapture,
              capture.projectSessionID == projectSessionID, capture.editorID == editorID,
              compute.currentOperationOwner == capture.operationOwnerToken,
              compute.currentOperationContextID == capture.operationContextID else {
            compute.updateLiveMapRenderTargets([])
            return
        }
        let entries = liveResultComputeByPath.values.filter {
            $0.status == .running && LiveMapResultRunIdentity(entry: $0).matches(capture)
        }
        guard entries.count == 1, let entry = entries.first else {
            compute.updateLiveMapRenderTargets([])
            return
        }
        let targets = mapStates.keys.sorted { $0.uuidString < $1.uuidString }.flatMap { id in
            mapStates[id]?.resultMap.liveMapRenderTargets(capture: capture, entry: entry) ?? []
        }
        compute.updateLiveMapRenderTargets(targets)
    }
    /// Retires transient live state only after a map-source reply confirms the
    /// exact Result path and SHA for this run. The persisted summary can then
    /// become authoritative again, including solver-cancelled partial output.
    func retireConfirmedLiveResultCompute(_ confirmed: WorkspaceResultComputeEntry) {
        guard projectSessionID == confirmed.projectSessionID,
              let current = liveResultComputeByPath[confirmed.resultPath],
              current.runID == confirmed.runID,
              current.operationOwnerToken == confirmed.operationOwnerToken,
              current.operationContextID == confirmed.operationContextID,
              current.status.isTerminal,
              let expectedRevision = confirmed.resultRevision,
              let currentRevision = current.resultRevision,
              expectedRevision.caseInsensitiveCompare(currentRevision) == .orderedSame else { return }
        liveResultComputeByPath.removeValue(forKey: confirmed.resultPath)
        publishPlanComputeLiveMapTargets()
    }
    private func acceptResultComputeTerminal(_ result: PlanComputeExecutionResult,
        editorID: UUID, projectSessionID expectedSession: UUID,
        operationOwnerToken: String?, operationContextID: String?) {
        guard let envelope = result.resultCompute,
              let capture = activePlanComputeCapture,
              let rawEntry = WorkspaceResultComputeReducer.acceptTerminal(envelope, result: result,
                capture: capture, activeCapture: activePlanComputeCapture,
                projectSessionID: expectedSession, editorID: editorID,
                operationOwnerToken: operationOwnerToken, operationContextID: operationContextID),
              WorkspaceResultComputeReducer.shouldReplace(liveResultComputeByPath[rawEntry.resultPath], with: rawEntry) else { return }
        let entry = LiveMapResultSelectionProjection.carryingProfiles(
            from: liveResultComputeByPath[rawEntry.resultPath], into: rawEntry)
        liveResultComputeByPath[entry.resultPath] = entry
        catalogTreeSession.upsertTransientResultComputeRow(entry)
        for state in mapStates.values { state.resultSources.acceptPlanComputeEntry(entry) }
        publishPlanComputeLiveMapTargets()
    }
    func endPlanCompute(editorID: UUID, projectSessionID expectedSession: UUID) {
        guard projectSessionID == expectedSession, planComputeOwnerID == editorID,
              isRunningPlanCompute else { return }
        cancelHistoricalResultReads()
        editorSessions[editorID]?.planCompute?.updateLiveMapRenderTargets([])
        let endingCapture = activePlanComputeCapture
        if activePlanComputeCapture?.projectSessionID == expectedSession,
           activePlanComputeCapture?.editorID == editorID {
            activePlanComputeCapture = nil
        }
        let written = planComputeWritePaths
        let reload = editorSessions.values.compactMap { session -> (ModelEditorSession, ProjectAsset, ModelEditorKind)? in
            guard session.id != editorID, !session.hasUnsavedEditorChanges,
                  let assetID = session.modelAssetID,
                  written.contains(Self.computeCanonicalPath(assetID)),
                  let asset = assets.first(where: { $0.id == assetID }),
                  let kind = ModelEditorKind.allCases.first(where: { $0.section == asset.section }) else { return nil }
            return (session, asset, kind)
        }
        // Keep the writer lease until source objects saved by the retained
        // compute path have been reloaded into their clean open editors.
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.projectSessionID == expectedSession, self.planComputeOwnerID == editorID {
                    self.planComputeOwnerID = nil; self.planComputeWritePaths = []
                    self.isRunningPlanCompute = false
                    self.flushPendingBackgroundMapSettings()
                    if let endingCapture {
                        for state in self.mapStates.values {
                            state.resultSources.endPlanCompute(endingCapture)
                            state.resultMap.endPlanCompute(endingCapture)
                        }
                        let mapIDs = Array(self.mapStates.keys)
                        Task { @MainActor [weak self] in
                            guard let self, self.projectSessionID == expectedSession else { return }
                            for mapID in mapIDs {
                                await self.configureMapResultSources(mapID)
                            }
                        }
                    }
                    // Asset discovery is guarded against an active writer;
                    // refresh after releasing it, before this MainActor turn ends.
                    self.refreshAssets()
                }
            }
            for (session, asset, kind) in reload {
                guard self.projectSessionID == expectedSession,
                      self.planComputeOwnerID == editorID,
                      self.editorSessions[session.id] === session,
                      !session.hasUnsavedEditorChanges else { continue }
                await session.load(asset, kind: kind)
            }
            guard self.projectSessionID == expectedSession, self.planComputeOwnerID == editorID else { return }
            if let endingCapture {
                let unconfirmedPaths = self.catalogTreeSession.markUnconfirmedTransientResultComputeRowsUnknown(
                    projectSessionID: expectedSession, editorID: editorID,
                    operationOwnerToken: endingCapture.operationOwnerToken,
                    operationContextID: endingCapture.operationContextID)
                for path in unconfirmedPaths {
                    guard let entry = self.liveResultComputeByPath[path], entry.status == .running,
                          entry.projectSessionID == expectedSession, entry.editorID == editorID,
                          entry.operationOwnerToken == endingCapture.operationOwnerToken,
                          entry.operationContextID == endingCapture.operationContextID else { continue }
                    self.liveResultComputeByPath.removeValue(forKey: path)
                }
            }
            // The defer owns the lease release and reader resumption on both
            // success and early exit. Clearing the owner here would skip it.
            self.assetsRevision += 1
            self.catalogTreeSession.invalidate(preservingTransientResultRowsFor: expectedSession)
            self.layerTreeSession.invalidate()
        }
    }
    private static func computeCanonicalPath(_ path: String) -> String {
        SourceFilePaths.canonical(URL(fileURLWithPath: path))
    }
    func endCatalogModelAction(projectSessionID expectedSession: UUID) {
        if projectSessionID == expectedSession { isRunningCatalogModelAction = false }
    }
    func beginTerrainRasterExport(projectSessionID expectedSession: UUID, captureID: String) -> UUID? {
        guard projectSessionID == expectedSession, hasProject, !isRunningProjectTool,
              !isSavingAll, !isOpeningProject, !isClosingTab, !hasBusyModelEditors,
              editorSessions.values.contains(where: { $0.captureTerrainRasterExportContext()?.id == captureID }) else { return nil }
        let leaseID = UUID()
        terrainRasterExportOwner = (leaseID, expectedSession, captureID)
        isExportingTerrainRaster = true
        return leaseID
    }
    func terrainRasterExportEditor(for asset: ProjectAsset) throws -> ModelEditorSession? {
        guard asset.section == .terrains, assets.contains(asset) else {
            throw ProjectFileError.invalid("The terrain source is no longer in the current project.")
        }
        let matches = editorSessions.values.filter { $0.modelAssetID == asset.id }
        let modified = matches.filter { $0.hasUnsavedEditorChanges }
        guard modified.count < 2 else {
            throw ProjectFileError.invalid("More than one terrain editor has unsaved changes. Choose which draft to keep before exporting.")
        }
        if let draft = modified.first { return draft }
        if let primary = primaryEditorIDs[.terrain], let editor = editorSessions[primary], editor.modelAssetID == asset.id { return editor }
        return matches.sorted { $0.id.uuidString < $1.id.uuidString }.first
    }
    func endTerrainRasterExport(_ leaseID: UUID) {
        guard let owner = terrainRasterExportOwner, owner.leaseID == leaseID,
              owner.projectSessionID == projectSessionID else { return }
        terrainRasterExportOwner = nil
        isExportingTerrainRaster = false
    }
    func applyCatalogModelAction(_ receipt: CatalogModelActionReceipt, assetID: String,
        projectSessionID expectedSession: UUID) throws {
        guard isRunningCatalogModelAction, projectSessionID == expectedSession, let document,
              let asset = assets.first(where: { $0.id == assetID }),
              CatalogModelActionPublisher.digest(Data(document.editorXML.utf8)) == receipt.projectXmlFingerprint else {
            throw ProjectFileError.modifiedExternally
        }
        func canonical(_ path: String) -> String {
            SourceFilePaths.canonical(URL(fileURLWithPath: path))
        }
        let changedSources = ["clone", "duplicate"].contains(receipt.action) ? Set<String>() : Set(
            [receipt.canonicalOriginalAssetPath] + receipt.stagedTargets.filter { $0.expectedTargetSHA != nil }.map(\.targetPath))
        guard !editorSessions.values.contains(where: { editor in
            editor.hasUnsavedEditorChanges && editor.modelAssetID.map { changedSources.contains(canonical($0)) } == true
        }) else { throw ProjectFileError.invalid("Save or discard the affected model editors before applying this action.") }
        let changedAssetIDs = Set(assets.filter { changedSources.contains(canonical($0.url.path)) }.map(\.id))
        try CatalogModelActionPublisher.publish(receipt, asset: asset, project: document,
            visualization: visualization, system: system)
        if !receipt.metadataMutations.isEmpty { isModified = true }
        // File publication and Trash have succeeded. Retire old source owners
        // even when a subsequent read-only asset/map refresh reports an error.
        for editor in Array(editorSessions.values) where editor.modelAssetID.map(changedAssetIDs.contains) == true {
            editor.invalidateForProjectReplacement(); unregisterEditor(editor)
        }
        editorAssetRequests = editorAssetRequests.filter { !changedAssetIDs.contains($0.value) }
        openEditors.removeAll { primaryEditorIDs[$0] == nil }
        if case .editor(let kind) = activeTab, !openEditors.contains(kind) { activeTab = .page(.map) }
        if selectedAssetID.map(changedAssetIDs.contains) == true { selectedAssetID = nil; selectedFeatureID = nil }
        for id in changedAssetIDs {
            mapLayers.removeAll { $0.id == id }; rasterLayers.removeAll { $0.id == id }
            for state in mapStates.values { state.removeLayer(id) }
        }
        catalogTreeSession.invalidate(); layerTreeSession.invalidate()
        refreshAssets()
        if let path = receipt.newAssetPath, let created = assets.first(where: { canonical($0.url.path) == canonical(path) }) { select(created) }
        if let visualization { installVisualizationMaps(visualization) }
        do { try refreshRasterMapSources() } catch { report("Catalog Action", error) }
        configureRasterSymbologyProvider(); loadMapLayers()
    }
    func completeResultDeletion(assetID: String, sourceName: String, projectSessionID expectedSession: UUID) throws {
        guard projectSessionID == expectedSession, isDeletingResult,
              let asset = assets.first(where: { $0.id == assetID && $0.section == .results }),
              !FileManager.default.fileExists(atPath: asset.url.path) else {
            throw ProjectFileError.invalid("The result deletion no longer matches the current project.")
        }
        // Once Trash succeeds, always retire the old in-memory result even if
        // another process changed the visualization document during the action.
        defer {
            for session in editorSessions.values { session.planResults?.removeResult(at: asset.url.path) }
            let removedSessions = editorSessions.values.filter { $0.modelAssetID == assetID }
            for session in removedSessions {
                session.invalidateForProjectReplacement()
                unregisterEditor(session)
            }
            editorAssetRequests = editorAssetRequests.filter { $0.value != assetID }
            if !primaryEditorIDs.keys.contains(.result) {
                openEditors.removeAll { $0 == .result }
                if activeTab == .editor(.result) { activeTab = .page(.map) }
            }
            if selectedAssetID == assetID { selectedAssetID = nil; selectedFeatureID = nil }
            mapLayers.removeAll { $0.id == assetID }
            rasterLayers.removeAll { $0.id == assetID }
            for state in mapStates.values { state.removeLayer(assetID) }
            catalogTreeSession.invalidate(); layerTreeSession.invalidate()
            refreshAssets()
        }
        try visualization?.removeResultReferences(named: sourceName)
    }
    func copyProjectPath() { if let url = document?.url { system.copy(url.path) } }
    func select(_ asset: ProjectAsset, clearTreeSelection: Bool = true) {
        if clearTreeSelection { layerTreeSession.selectedID = nil; catalogTreeSession.selectedID = nil }
        selectedAssetID = asset.id; selectedSection = asset.section; selectedFeatureID = nil; inspectorMode = .properties
    }
    func selectConnection(_ connection: ProjectConnection) {
        guard document?.connections.contains(where: { $0.id == connection.id }) == true else { return }
        layerTreeSession.selectedID = nil
        catalogTreeSession.selectedID = nil
        selectedAssetID = "connection/" + connection.id; selectedSection = nil; selectedFeatureID = nil; inspectorMode = .properties
    }
    func openEditor(_ kind: ModelEditorKind, assetID: String? = nil) {
        guard !isRunningPlanCompute else { return }
        if !openEditors.contains(kind) { openEditors.append(kind) }
        if let assetID { editorAssetRequests[kind] = assetID }
        activeTab = .editor(kind)
    }
    /// Global shortcuts select an exact model before handing presentation to
    /// its primary editor. The editor keeps ownership of loading and unsaved
    /// model-change prompts; this request never replaces or loads its draft.
    @discardableResult
    func requestEditorToolPresentation(action: ToolKind, assetID: String,
                                      spatialLayerID: String? = nil,
                                      featureKind: String? = nil) -> Bool {
        guard hasProject, !isRunningProjectTool, !isSavingAll,
              !isOpeningProject, !isClosingTab, !isRunningPlanCompute,
              let asset = assets.first(where: { $0.id == assetID }), asset.isModelFile else { return false }
        let kind: ModelEditorKind
        switch action {
        case .terrainImport: kind = .terrain
        case .classificationImport: kind = .surface
        case .griddedImport, .initialConditions: kind = .boundaryCondition
        case .tagCreate, .tagEdit:
            guard featureKind == "arc" || featureKind == "region", spatialLayerID == nil else { return false }
            kind = .geometry
        case .topology, .topologyRecipe, .tagFilter:
            guard featureKind == nil, spatialLayerID == nil else { return false }
            kind = .geometry
        case .arcPoints:
            guard featureKind == "arc", spatialLayerID == nil else { return false }
            kind = .geometry
        default: return false
        }
        guard asset.section == kind.section,
              action == .griddedImport || spatialLayerID == nil,
              action == .tagCreate || action == .tagEdit || action == .arcPoints || featureKind == nil else { return false }
        editorToolPresentationRequest = EditorToolPresentationRequest(id: UUID(),
            projectSessionID: projectSessionID, assetID: asset.id, action: action,
            spatialLayerID: spatialLayerID, featureKind: featureKind)
        openEditor(kind, assetID: asset.id)
        activeTool = nil
        return true
    }

    /// Clear only the accepted or explicitly cancelled handoff. A late sheet
    /// dismissal must not consume a newer shortcut for another target.
    func consumeEditorToolPresentationRequest(_ id: UUID) {
        guard editorToolPresentationRequest?.id == id else { return }
        editorToolPresentationRequest = nil
    }
    func addMapDocument(kind: MapDocument.Kind) {
        guard kind.defaultSourceType != nil else { return }
        if document != nil {
            let projectSession = projectSessionID
            Task { if projectSessionID == projectSession { _ = await createMapDocument(kind: kind) } }
            return
        }
        // A projectless workspace can host a temporary map view; maps in an
        // opened project always use the source visualization persistence path.
        let map = MapDocument(name: L10n.format("Map %d", nextMapNumber), kind: kind); nextMapNumber += 1
        mapDocumentNames[map.id] = map.name
        mapDocuments.append(map); _ = mapState(for: map.id); activeTab = .map(map.id)
    }
    @discardableResult
    func createMapDocument(kind: MapDocument.Kind) async -> Bool {
        guard let projectPath = document?.url,
              let provider = layerTreeProvider as? BackendMapTreeProvider,
              let sourceType = kind.defaultSourceType,
              !isRunningProjectTool, !isSavingAll, !isOpeningProject else { return false }
        let projectSession = projectSessionID
        do {
            let receipt = try await provider.createMap(projectPath: projectPath.standardizedFileURL.path, kind: sourceType)
            guard projectSessionID == projectSession, receipt.mapType == sourceType,
                  let id = visualizationMapIDs[receipt.mapIndex], let map = mapDocument(for: id),
                  map.name == receipt.mapName else { return false }
            guard map.sourceType == sourceType || map.kind.defaultSourceType == sourceType else { return false }
            openMapDocument(map)
            return true
        } catch { if projectSessionID == projectSession { report("Maps", error) }; return false }
    }
    func addBlankMapDocument() { addMapDocument(kind: .buildable) }
    func addProjectMapDocument() { addMapDocument(kind: .project) }
    func addGeometryMapDocument() { addMapDocument(kind: .geometry) }
    func isChatDisplayDocked(_ entryID: String) -> Bool { chatDisplayDocuments.contains { $0.entryID == entryID } }
    func dockChatDisplay(entryID: String, payload: ChatDisplayPayload, objects: [String: ChatDisplayObject]) {
        guard hasProject else { return }
        if let existing = chatDisplayDocuments.first(where: { $0.entryID == entryID }) { activeTab = .chatDisplay(existing.id); return }
        let document = ChatDisplayDocument(id: UUID(), entryID: entryID, payload: payload, objects: objects)
        chatDisplayCache[document.id] = document; chatDisplayDocuments.append(document); activeTab = .chatDisplay(document.id)
    }
    func chatDisplayDocument(_ id: UUID) -> ChatDisplayDocument? { chatDisplayCache[id] }
    func mapName(_ id: UUID) -> String { mapDocumentNames[id] ?? L10n.text("Project Map") }
    func mapDocument(for id: UUID) -> MapDocument? {
        if let map = mapDocuments.first(where: { $0.id == id }) { return map }
        guard id == MapState.projectMapID,
              let source = visualizationMapIdentities.values.first(where: { visualizationMapIDs[$0.index] == id }) else { return nil }
        return MapDocument(id: id, name: source.name, kind: .init(sourceType: source.type), sourceType: source.type)
    }
    func renameMap(_ id: UUID, name: String) {
        if document != nil {
            let projectSession = projectSessionID
            Task { if projectSessionID == projectSession { _ = await renameMapDocument(id, name: name) } }
            return
        }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let index = mapDocuments.firstIndex(where: { $0.id == id }) else { return }
        mapDocuments[index].name = name; mapDocumentNames[id] = name
    }
    @discardableResult
    func renameMapDocument(_ id: UUID, name: String) async -> Bool {
        guard let projectPath = document?.url,
              let provider = layerTreeProvider as? BackendMapTreeProvider,
              let map = catalogMapDocuments.first(where: { $0.id == id.uuidString }),
              !isRunningProjectTool, !isSavingAll, !isOpeningProject else { return false }
        let projectSession = projectSessionID
        do {
            let receipt = try await provider.renameMap(projectPath: projectPath.path, map: map, to: name)
            return projectSessionID == projectSession && mapName(id) == receipt.mapName
        } catch { if projectSessionID == projectSession { report("Maps", error) }; return false }
    }
    func mapState(for id: UUID) -> MapState {
        if let existing = mapStates[id] { return existing }
        let kind = mapDocuments.first(where: { $0.id == id })?.kind
            ?? visualizationMapIdentities.values.first(where: { visualizationMapIDs[$0.index] == id }).map { .init(sourceType: $0.type) }
            ?? .project
        let backend = modelProvider as? BackendModelProvider
        let sourceProvider = backend.map { BackendMapResultChartProvider(client: $0.client) }
        let boundaryProvider = BackendBoundaryMapProvider(client: backend?.client,
            isCurrent: { [weak self] capture in
                self?.mapSourceWorkflowIdentity(id) == capture.mapWorkflowIdentity
            })
        let state = MapState(kind: kind, id: id, resultSourceProvider: sourceProvider,
            resultClient: backend?.client, boundaryMapProvider: boundaryProvider); mapStates[id] = state
        state.sourceContextDidChange = { [weak self, weak state] in
            guard let self, let state, self.mapStates[id] === state else { return }
            self.configureStoredCulvertProfile(id)
            Task { [weak self] in await self?.configureWindVelocityParticles(mapID: id) }
        }
        state.lineStateDidChange = { [weak self] in
            self?.invalidateMapCharts(mapID: id)
            self?.rebindMapDynamicProfileSources(mapID: id)
        }
        state.polylineEditor.canEdit = { [weak self, weak state] in
            guard let self, let state, self.mapStates[id] === state,
                  !self.isRunningProjectTool, !self.isSavingAll, !self.isClosingTab,
                  !self.isOpeningProject, let scope = state.polylineEditor.currentScope,
                  scope.projectSessionID == self.projectSessionID else { return false }
            return !self.hasConflictingMapDraft(path: SourceFilePaths.canonical(URL(fileURLWithPath: scope.canonicalPath)), excluding: id)
        }
        state.polylineEditor.canSave = { [weak self, weak state] in
            guard let self, let state, self.mapStates[id] === state,
                  !self.isRunningProjectTool, !self.isOpeningProject,
                  let scope = state.polylineEditor.currentScope, scope.projectSessionID == self.projectSessionID else { return false }
            return !self.hasConflictingMapDraft(path: SourceFilePaths.canonical(URL(fileURLWithPath: scope.canonicalPath)), excluding: id)
        }
        state.toolPaletteSession.didUpdate = { [weak self] update, context in
            guard let self, self.projectSessionID == context.projectSessionID else { return }
            self.installMapUpdate(update, mapID: context.mapID)
        }
        state.resultMap.liveRenderTargetsDidChange = { [weak self, weak state] in
            guard let self, let state, self.mapStates[id] === state else { return }
            self.publishPlanComputeLiveMapTargets()
        }
        state.resultMap.didSelectPersistableProfile = { [weak self, weak state] node, mapType, profileIndex in
            guard let self, let state, self.mapStates[id] === state,
                  let snapshot = state.resultSources.snapshot,
                  snapshot.sources.activeNodes.contains(where: { $0.node == node }),
                  let runtime = state.resultMap.nodes.first(where: {
                      $0.id == MapResultSelectionOverride(node: node, mode: .latest).nodeIdentity
                  }),
                  profileIndex >= 0, profileIndex < runtime.profileCount else { return }
            let workflowIdentity = self.mapSourceWorkflowIdentity(id)
            Task { @MainActor [weak self, weak state] in
                guard let self, let state, self.mapStates[id] === state,
                      self.mapSourceWorkflowIdentity(id) == workflowIdentity else { return }
                _ = await self.persistSourceResultViewState(node: node, mapID: id,
                    selectedMapType: mapType, profileIndex: profileIndex,
                    expectedWorkflowIdentity: workflowIdentity)
            }
        }
        mapBackgroundSettingsSubscriptions[id] = state.backgroundMapSession.$settings.dropFirst().sink { [weak self, weak state] settings in
            guard let self, let state, self.mapStates[id] === state,
                  !self.isInstallingBackgroundSettings else { return }
            self.persistBackgroundMapSettings(settings, mapID: id)
        }
        mapStateSubscriptions[id] = state.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        mapMeshErrorSourceSubscriptions[id] = state.projectGeometryMap.$sources.sink { [weak self, weak state] sources in
            guard let self, let state, self.mapStates[id] === state else { return }
            self.configureMapMeshErrorOverlays(mapState: state, sources: sources)
        }
        mapSelectedLayerSubscriptions[id] = state.$selectedLayerID.dropFirst().sink { [weak self] _ in
            self?.rebindMapDynamicProfileSources(mapID: id)
        }
        mapLineSelectionSubscriptions[id] = state.$selectedLineIdentity.dropFirst().sink { [weak self] _ in
            self?.rebindMapDynamicProfileSources(mapID: id)
        }
        mapEditingLineSubscriptions[id] = state.polylineEditor.$selectedLineID.dropFirst().sink { [weak self] _ in
            self?.rebindMapDynamicProfileSources(mapID: id)
        }
        mapDynamicProfileSourceSubscriptions[id] = state.resultSources.$sources.dropFirst().sink { [weak self] _ in
            self?.rebindMapDynamicProfileSources(mapID: id)
        }
        mapDynamicProfileSelectionSubscriptions[id] = state.resultSources.$selectionOverrides.dropFirst().sink { [weak self] _ in
            self?.rebindMapDynamicProfileSources(mapID: id)
        }
        return state
    }
    func includeMapLayer(_ id: String, in mapID: UUID) { mapState(for: mapID).includeLayer(id) }
    func activateMap(_ id: UUID) { if lastActiveMapID != id { lastActiveMapID = id } }
    func openMapDocument(_ map: MapDocument) {
        activateMap(map.id)
        activeTab = map.id == MapState.projectMapID ? .page(.map) : .map(map.id)
    }
    func zoomToFullExtent() { activeMapState.resetViewport() }
    func saveCurrentView() {
        guard let extent = activeMapState.currentExtent, let visualization else { return }
        var name = L10n.text("View"); var suffix = 1
        while savedViews.contains(where: { $0.name == name }) { name = L10n.format("View %d", suffix); suffix += 1 }
        do { try visualization.add(SavedMapView(name: name, lowerLeft: extent.lowerLeft, upperRight: extent.upperRight)); savedViews = visualization.views }
        catch { report("Saved Views", error) }
    }
    func renameSavedView(_ view: SavedMapView, name: String) {
        var updated = view; updated.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        updateSavedView(updated)
    }
    func resetSavedView(_ view: SavedMapView) {
        guard let extent = activeMapState.currentExtent else { return }
        var updated = view; updated.lowerLeft = extent.lowerLeft; updated.upperRight = extent.upperRight
        updateSavedView(updated)
    }
    func setViewShortcut(_ view: SavedMapView, shortcut: String) {
        guard shortcut == "None" || ViewShortcut.decode(shortcut) != nil else {
            report("Saved Views", ProjectFileError.invalid("Invalid Key Binding")); return
        }
        let normalized = ViewShortcut.decode(shortcut)?.wireValue ?? "None"
        if normalized != "None", savedViews.contains(where: {
            $0.id != view.id && ViewShortcut.decode($0.shortcut)?.wireValue == normalized
        }) {
            report("Saved Views", ProjectFileError.invalid("This key bind is already assigned to another view.")); return
        }
        var updated = view; updated.shortcut = normalized; updateSavedView(updated)
    }
    private func updateSavedView(_ view: SavedMapView) {
        do { try visualization?.update(view); savedViews = visualization?.views ?? [] }
        catch { report("Saved Views", error) }
    }
    func removeSavedView(_ id: UUID) { visualization?.remove(id); savedViews = visualization?.views ?? [] }
    func jumpToView(_ view: SavedMapView) {
        activeTab = lastActiveMapID == MapState.projectMapID ? .page(.map) : .map(lastActiveMapID)
        activeMapState.viewport = ViewportRequest(lowerLeft: view.lowerLeft, upperRight: view.upperRight)
    }
    private func loadVisualization(_ projectURL: URL) {
        do {
            let opened = try VisualizationDocument(projectURL: projectURL)
            visualization = opened; savedViews = opened.views
            installVisualizationMaps(opened)
            try refreshRasterMapSources()
            configureRasterSymbologyProvider()
            loadRasterMapLayers()
        }
        catch { report("Saved Views", error) }
    }
    private func installVisualizationMaps(_ opened: VisualizationDocument, loadBackgroundSettings: Bool = true) {
        let firstProject = opened.maps.first { $0.type == "Project" }?.index
        for map in opened.maps {
            let id: UUID
            if visualizationMapIdentities[map.index]?.type == map.type, let existing = visualizationMapIDs[map.index] {
                id = existing
            } else { id = map.index == firstProject ? MapState.projectMapID : UUID() }
            visualizationMapIDs[map.index] = id; visualizationMapIdentities[map.index] = map
            mapDocumentNames[id] = map.name
            if loadBackgroundSettings {
                let wasInstalling = isInstallingBackgroundSettings
                isInstallingBackgroundSettings = true
                defer { isInstallingBackgroundSettings = wasInstalling }
                do {
                    let options = try opened.backgroundMapOptions(map: map)
                    mapState(for: id).backgroundMapSession.settings = try BackgroundMapSettings(visualOptions: options)
                } catch { report("Background Maps", error) }
            }
            if let existing = mapDocuments.firstIndex(where: { $0.id == id }) {
                mapDocuments[existing].name = map.name
                mapDocuments[existing].kind = .init(sourceType: map.type)
                mapDocuments[existing].sourceType = map.type
            } else if id != MapState.projectMapID {
                mapDocuments.append(MapDocument(id: id, name: map.name,
                    kind: .init(sourceType: map.type), sourceType: map.type))
            }
        }
    }
    func canEditBackgroundMaps(mapID: UUID, session: BackgroundMapSession) -> Bool {
        guard document != nil, let visualization,
              mapStates[mapID]?.backgroundMapSession === session,
              !isOpeningProject, !isRunningMapMutation, !isRunningRasterMutation,
              !isSavingAll else { return false }
        return visualizationMapIdentities.values.contains { visualizationMapIDs[$0.index] == mapID }
            || mapID == MapState.projectMapID && visualization.maps.isEmpty
    }

    private func persistBackgroundMapSettings(_ settings: BackgroundMapSettings, mapID: UUID) {
        guard let visualization, document != nil, !isOpeningProject,
              !isRunningMapMutation, !isRunningRasterMutation, !isSavingAll else { return }
        guard (-1...5).contains(settings.density), settings.satelliteOpacity.isFinite,
              (0...1).contains(settings.satelliteOpacity) else {
            report("Background Maps", ProjectFileError.invalid("The saved background map settings are invalid."))
            return
        }
        let source = visualizationMapIdentities.values.first { visualizationMapIDs[$0.index] == mapID }
        guard source != nil || mapID == MapState.projectMapID && visualization.maps.isEmpty else { return }
        if isRunningPlanCompute {
            // The local background preview can change immediately. Keep the
            // captured VIS revision stable for the writer's live Result targets
            // and publish these preferences when its lease is released.
            pendingBackgroundMapSettings[mapID] = (projectSessionID, settings)
            return
        }
        do {
            try visualization.saveBackgroundMapOptions(settings.visualOptions, map: source)
            installVisualizationMaps(visualization, loadBackgroundSettings: false)
            try refreshRasterMapSources()
            objectWillChange.send()
        } catch { report("Background Maps", error) }
    }

    private func flushPendingBackgroundMapSettings() {
        let pending = pendingBackgroundMapSettings
        pendingBackgroundMapSettings = [:]
        for mapID in pending.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard let entry = pending[mapID], entry.projectSessionID == projectSessionID,
                  let state = mapStates[mapID],
                  canEditBackgroundMaps(mapID: mapID, session: state.backgroundMapSession) else { continue }
            persistBackgroundMapSettings(entry.settings, mapID: mapID)
        }
    }

    private func refreshRasterMapSources() throws {
        guard let visualization else { rasterMapSources = []; rasterMapSourceInfoStats = [:]; return }
        rasterMapSources = try visualization.singleBandRasterMapSources().compactMap { source in
            visualizationMapIDs[source.mapIndex].map { source.assigning(mapID: $0) }
        }
        let validKeys = Set(rasterMapSources.compactMap { source in
            source.sourceMapID.map { $0.uuidString + "|" + source.id }
        })
        rasterMapSourceInfoStats = rasterMapSourceInfoStats.filter { validKeys.contains($0.key) }
    }
    private func installRasterMapLayer(_ layer: MapRasterLayer) {
        rasterLayers.removeAll { $0.id == layer.id && $0.sourceMapID == layer.sourceMapID }
        rasterLayers.append(layer)
        if let mapID = layer.sourceMapID { mapState(for: mapID).includeLayer(layer.id) }
    }
    private func configureRasterSymbologyProvider() {
        guard let backend = modelProvider as? BackendModelProvider else { return }
        // Each provider belongs to one project opening. An operation from an
        // earlier opening cannot install pixels or accept a new file baseline.
        let sourceSession = projectSessionID
        rasterSymbologyProvider = BackendRasterSymbologyProvider(client: backend.client,
            sources: { [weak self] in
                guard let self, self.projectSessionID == sourceSession else { return [] }
                return self.rasterMapSources
            },
            viewport: { [weak self] mapID in
                guard let self, self.projectSessionID == sourceSession,
                      let extent = self.mapState(for: mapID).currentExtent, extent.isFiniteAndOrdered else { return nil }
                return RasterMapViewExtent(minX: extent.lowerLeft.x, minY: extent.lowerLeft.y,
                    maxX: extent.upperRight.x, maxY: extent.upperRight.y, pixelWidth: 1024, pixelHeight: 768)
            },
            projectXML: { [weak self] in
                guard let self, self.projectSessionID == sourceSession else { return nil }
                return self.document?.editorXML(overridingDescription: self.descriptionDraft)
            },
            installLayer: { [weak self] layer in
                guard let self, self.projectSessionID == sourceSession else { return }
                self.installRasterMapLayer(layer)
            },
            acceptVisualization: { [weak self] oldRevision, newRevision in
                guard let self, self.projectSessionID == sourceSession, let visualization = self.visualization else {
                    throw BackendServiceError(code: "sourceChanged", message: "The project changed while the operation was running.")
                }
                try visualization.acceptExternalRasterSymbologyChange(expectedPreviousRevision: oldRevision, newRevision: newRevision)
                try self.refreshRasterMapSources()
            })
        (rasterSymbologyProvider as? BackendRasterSymbologyProvider)?.onMutationRunningChanged = { [weak self] running in
            guard let self, self.projectSessionID == sourceSession else { return }
            self.isRunningRasterMutation = running
        }
        (rasterSymbologyProvider as? BackendRasterSymbologyProvider)?.canBeginMutation = { [weak self] in
            guard let self, self.projectSessionID == sourceSession else { return false }
            return !self.isRunningProjectTool && !self.isSavingAll && !self.isOpeningProject
        }
    }
    private func loadRasterMapLayers() {
        rasterMapLoadTask?.cancel(); rasterMapLoadRevision += 1
        let revision = rasterMapLoadRevision, sessionID = projectSessionID
        guard let provider = rasterSymbologyProvider as? BackendRasterSymbologyProvider else {
            isRasterMapLoading = false; return
        }
        let sources = rasterMapSources
        rasterLayers.removeAll { $0.sourceMapID != nil }
        rasterMapSourceInfoStats = [:]
        isRasterMapLoading = !sources.isEmpty
        rasterMapLoadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if revision == self.rasterMapLoadRevision { self.isRasterMapLoading = false } }
            for source in sources {
                guard !Task.isCancelled, self.projectSessionID == sessionID,
                      self.rasterMapLoadRevision == revision else { return }
                do {
                    let loaded = try await provider.loadMapLayerWithProperties(source)
                    guard !Task.isCancelled, self.projectSessionID == sessionID,
                          self.rasterMapLoadRevision == revision,
                          self.rasterMapSources.contains(source),
                          let mapID = source.sourceMapID,
                          loaded.layer.sourceMapID == mapID else { return }
                    self.installRasterMapLayer(loaded.layer)
                    let key = mapID.uuidString + "|" + source.id
                    if let metadata = loaded.rasterInfoStats,
                       SourceFilePaths.canonical(URL(fileURLWithPath: metadata.path))
                            == SourceFilePaths.canonical(URL(fileURLWithPath: source.sourcePath)) {
                        self.rasterMapSourceInfoStats[key] = metadata
                    } else { self.rasterMapSourceInfoStats.removeValue(forKey: key) }
                } catch {
                    guard !Task.isCancelled, self.projectSessionID == sessionID,
                          self.rasterMapLoadRevision == revision else { return }
                    self.log("Raster Symbology", source.nodeName + ": " + L10n.text(error.localizedDescription))
                }
            }
        }
    }
    @discardableResult
    private func resetProjectWorkspace() -> Bool {
        guard !isRunningPlanCompute, !isRunningInitialConditionsCommit, !isRunningPlanMatrixEmit, !isRunningLibraryImport,
              !hasBusyModelEditors, !hasUnsavedMapEdits,
              !stableChannelDebug.hasUnsavedChanges,
              !editorSessions.values.contains(where: { $0.geometryMesh?.hasUnsavedDiagnosticsPreferences == true }) else { return false }
        guard stableChannelDebug.invalidateOwner() else { return false }
        releaseProjectOpenLock()
        terrainUSGSTileOverlay.clearAll()
        cancelHistoricalResultReads()
        (featureQueryProvider as? BackendFeatureQueryProvider)?.invalidate()
        for state in mapStates.values { state.backgroundMapSession.invalidate() }
        pendingBackgroundMapSettings = [:]
        for task in sourceMapVectorLoadTasks.values { task.cancel() }
        sourceMapVectorLoadTasks = [:]; sourceMapVectorLoadStates = [:]; sourceMapVectorFamilyCaptures = [:]
        pendingPlanDiagnosticNavigation = nil
        for workflow in initialConditionsWorkflows.values { workflow.session.invalidate() }
        initialConditionsWorkflows = [:]
        initialConditionsCommitOwner = nil
        cancelProjectOpening()
        chatSession.invalidate(); chatSession = ChatSession()
        layerTreeSession.invalidate()
        catalogTreeSession.invalidate()
        cancelMapLoading(); projectSessionID = UUID()
        liveResultComputeByPath = [:]; activePlanComputeCapture = nil
        rasterMapLoadTask?.cancel(); rasterMapLoadTask = nil; rasterMapLoadRevision += 1
        isRasterMapLoading = false; rasterMapSources = []; rasterMapSourceInfoStats = [:]; rasterSymbologyProvider = nil
        vectorStyleNodes = [:]; boundaryVectorStyleContexts = [:]; specializedVectorStyleCache = [:]
        vectorSymbologyContextRevision &+= 1
        isRunningRasterMutation = false
        isDeletingResult = false; isRunningMapMutation = false; isRunningCatalogModelAction = false
        catalogModelActionPresentation = nil
        visualizationMapIDs = [:]; visualizationMapIdentities = [:]
        mapInputTask?.cancel(); mapInputTask = nil; handlingMapInputs = false
        for session in editorSessions.values {
            session.invalidateForProjectReplacement()
        }
        editorSessions = [:]; editorSubscriptions = [:]; primaryEditorIDs = [:]; editorAssetRequests = [:]
        editorToolPresentationRequest = nil
        pendingCloseTab = nil; showCloseTabConfirmation = false
        pendingMapInputs = []; rasterLayers = []; mapLayers = []; mapLegends = []; mapHistoryAvailability = [:]
        for mapID in mapStates.keys {
            mapResultSourceSetupCoordinator.cancel(mapID: mapID)
        }
        for state in mapStates.values {
            state.toolPaletteSession.invalidate(); state.clearProfiles(); _ = state.polylineEditor.invalidate()
            state.mapSelectionMeasurement.invalidate()
            state.meshErrors.invalidate()
            state.resultSources.close(); state.resultMap.invalidate()
            state.projectGeometryMap.invalidate(); state.associatedMapLayers.invalidate(); state.terrainInputMap.invalidate()
            state.boundaryCaptureGeneration &+= 1
            state.boundaryMap.invalidate(); state.storedCulvertProfile.invalidate()
        }
        for chart in mapChartSessions.values { chart.close() }
        mapChartSessions = [:]
        for session in mapDynamicProfileWindows.values { session.close() }
        mapDynamicProfileWindows = [:]
        mapStates = [:]; mapStateSubscriptions = [:]; mapBackgroundSettingsSubscriptions = [:]; lastActiveMapID = MapState.projectMapID
        mapMeshErrorSourceSubscriptions = [:]
        mapSelectedLayerSubscriptions = [:]
        mapLineSelectionSubscriptions = [:]
        mapEditingLineSubscriptions = [:]
        mapDynamicProfileSourceSubscriptions = [:]
        mapDynamicProfileSelectionSubscriptions = [:]
        document = nil; assets = []; visualization = nil; savedViews = []
        modelProvider?.setProject(nil)
        toolProvider?.setProject(nil, sessionID: projectSessionID)
        selectedAssetID = nil; selectedSection = nil; selectedFeatureID = nil
        focusedGeometryIDs = []; focusedPlanIDs = []
        activeTab = .page(.map); openEditors = []; mapDocuments = []; chatIsOpen = false
        mapDocumentNames = [:]; nextMapNumber = 1
        chatDisplayDocuments = []; chatDisplayCache = [:]
        filter = ""; catalogFilter = ""; treeMode = .project; inspectorMode = .properties
        showProjection = false; showConnectionManager = false; showConnectionEditor = false; showZoomLocation = false; showSavedViews = false; activeTool = nil
        showNewProject = false; showProjectLibrary = false; showSearch = false; surfaceCreation = nil
        pendingLibraryProjectURL = nil
        showDeveloperTools = false
        descriptionDraft = ""; isModified = false
        return true
    }
    func releaseProjectOpenLock() {
        projectOpenLockLease?.release(); projectOpenLockLease = nil; projectOpenLockURL = nil
    }
    @discardableResult
    func addExternalConnection(type: String, name: String, target: URL, searchPattern: String, recurse: Bool) -> Bool {
        guard let document else { return false }
        do {
            let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, !document.connections.contains(where: { $0.name == title }) else { throw ProjectFileError.invalid("Connection names must be unique.") }
            if type == "Directory" { try document.connectDirectory(target, name: title, searchPattern: searchPattern, recurse: recurse) }
            else { try document.connectFile(target, name: title) } // Result references use Type=File in the original source.
            isModified = true; showConnectionEditor = false; loadMapLayers()
            return true
        } catch { report("File Connection", error); return false }
    }
    @discardableResult
    func addExternalFiles(_ entries: [ConnectionFileDraft], projectID: UUID) -> Bool {
        guard projectSessionID == projectID, let document else { return false }
        do {
            try document.connectFiles(entries.map { ($0.effectiveName, $0.url) })
            isModified = true; showConnectionEditor = false; loadMapLayers(); return true
        } catch { report("File Connection", error); return false }
    }
    func updateExternalConnection(_ connection: ProjectConnection, target: URL, description: String, pattern: String, recurse: Bool, projectID: UUID) throws {
        guard projectSessionID == projectID, let document else { throw ProjectFileError.invalid("The project changed. Reopen this window.") }
        try document.updateConnection(connection, target: target, description: description, searchPattern: pattern, recurse: recurse)
        isModified = true; loadMapLayers()
    }
    func markExternalConnectionRenamed(projectID: UUID) -> Bool {
        guard projectSessionID == projectID, document != nil, !isOpeningProject, !isSavingAll,
              !isClosingTab, !isRunningProjectTool else { return false }
        isModified = true
        loadMapLayers()
        return true
    }
    func removeConnection(_ connection: ProjectConnection) {
        do {
            try document?.removeConnection(id: connection.id)
            if selectedAssetID == "connection/" + connection.id { selectedAssetID = nil }
            try document?.reloadAssets(); assets = document?.assets ?? []
            isModified = true; loadMapLayers()
        }
        catch { report("File Connection", error) }
    }
    func revealConnection(_ connection: ProjectConnection) {
        guard let directory = document?.directory else { return }
        do { system.reveal(try connection.resolve(relativeTo: directory, mappings: pathMappings)) }
        catch { report("File Connection", error) }
    }
    func edit(_ asset: ProjectAsset, fromTree: Bool = false) {
        guard !isRunningPlanCompute else { return }
        select(asset, clearTreeSelection: !fromTree)
        if let kind = ModelEditorKind.allCases.first(where: { $0.section == asset.section }) { openEditor(kind, assetID: asset.id) }
    }
    func addMapLayer() { addMapLayer(for: lastActiveMapID) }
    func addMapLayer(for mapID: UUID) {
        guard mapState(for: mapID).kind != .unsupported else { return }
        guard let file = system.chooseMapLayer() else { return }
        let project = projectSessionID
        Task {
            guard projectSessionID == project else { return }
            _ = await connectMapSource(file, for: mapID)
        }
    }
    @discardableResult
    func connectMapSource(_ file: URL, for mapID: UUID) async -> Bool {
        if ["tif", "tiff"].contains(file.pathExtension.lowercased()) {
            return await connectRasterSource(file, for: mapID)
        }
        return await connectVectorSource(file, for: mapID)
    }
    func connectVector(_ file: URL) { connectVector(file, for: lastActiveMapID) }
    func connectVector(_ file: URL, for mapID: UUID) {
        let project = projectSessionID
        Task {
            guard projectSessionID == project else { return }
            _ = await connectVectorSource(file, for: mapID)
        }
    }
    @discardableResult
    func connectVectorSource(_ file: URL, for mapID: UUID, expectedShapefileFamily: MapSourceFamilyCapture? = nil,
                             expectedSourceRevision: String? = nil) async -> Bool {
        guard mapState(for: mapID).kind != .unsupported,
              let openedDocument = document, let openedURL = openedDocument.url, !isRunningProjectTool, !isOpeningProject,
              !isSavingAll, !isClosingTab else { return false }
        let project = projectSessionID
        do {
            guard let provider = layerTreeProvider as? BackendMapTreeProvider else {
                throw BackendServiceError(code: "unsupported", message: "This source map operation is unavailable for the selected map.")
            }
            let family: MapSourceFamilyCapture?
            let revision: String
            if file.pathExtension.lowercased() == "shp" {
                if let expectedShapefileFamily { family = expectedShapefileFamily }
                else { family = try await provider.captureShapefileFamily(sourcePath: file.standardizedFileURL.path) }
                guard let source = family?.files.first(where: { $0.role == "source" }),
                      source.exists, let sourceRevision = source.revision else { throw ProjectFileError.modifiedExternally }
                revision = sourceRevision
            } else {
                guard expectedShapefileFamily == nil else { throw ProjectFileError.modifiedExternally }
                let layer = try await Task.detached { try MapVectorLayer(contentsOf: file) }.value
                guard let sourceRevision = layer.sourceRevision else { throw ProjectFileError.modifiedExternally }
                revision = sourceRevision; family = nil
            }
            if let expectedSourceRevision,
               revision.caseInsensitiveCompare(expectedSourceRevision) != .orderedSame {
                throw ProjectFileError.modifiedExternally
            }
            guard document === openedDocument, openedDocument.url == openedURL,
                  projectSessionID == project, !isRunningProjectTool,
                  !isOpeningProject, !isSavingAll, !isClosingTab else { return false }
            guard let projectRevision = openedDocument.sourceRevision else {
                throw BackendServiceError(code: "unsupported", message: "This source map operation is unavailable for the selected map.")
            }
            // The retained source reader needs the prospective external-file
            // connection. Supply it in a snapshot without editing the live XML.
            let stagedXML = try openedDocument.editorXML(connectingFile: file, overridingDescription: descriptionDraft)
            let didPublish: @MainActor () throws -> Void = {
                    try openedDocument.connectFile(file)
                    self.isModified = true
                }
            let imported: MapVectorImportReceipt
            if let family {
                imported = try await provider.importShapefileVector(sourcePath: file.standardizedFileURL.path,
                    expectedFamily: family, projectXML: stagedXML, projectRevision: projectRevision,
                    context: sourceMapTreeContext(mapID), didPublish: didPublish)
            } else {
                imported = try await provider.importGeoJSONVector(sourcePath: file.standardizedFileURL.path, revision: revision,
                    projectXML: stagedXML, projectRevision: projectRevision, context: sourceMapTreeContext(mapID), didPublish: didPublish)
            }
            guard document === openedDocument, openedDocument.url == openedURL, projectSessionID == project else { return false }
            includeMapLayer(file.standardizedFileURL.path, in: mapID)
            await reloadMapLayersAndWait()
            guard document === openedDocument, openedDocument.url == openedURL, projectSessionID == project else { return false }
            await configureMapResultSources(mapID)
            guard document === openedDocument, openedDocument.url == openedURL, projectSessionID == project else { return false }
            if let asset = assets.first(where: { $0.url.standardizedFileURL == file.standardizedFileURL }) { select(asset) }
            if mapID == MapState.projectMapID { page = .map }
            else if mapDocuments.contains(where: { $0.id == mapID }) { activeTab = .map(mapID) }
            log("Add Map Layer", L10n.format("Connected %@.", file.lastPathComponent))
            if let warning = imported.refreshWarning {
                report("Add Map Layer", BackendServiceError(code: "refreshFailed",
                    message: L10n.format("The layer was imported, but the map could not be refreshed: %@.", warning)))
            }
            return true
        } catch is CancellationError {
            return false
        } catch {
            if document === openedDocument, projectSessionID == project { report("Add Map Layer", error) }
            return false
        }
    }
    /// Adds the actual TIFF context to one saved map. Used by source raster
    /// geoprocessing output and the native raster importer; pixels stay in the
    /// selected TIFF and the project connection follows ordinary project Save.
    @discardableResult
    func connectRasterSource(_ file: URL, for mapID: UUID,
                             expectedSourceRevision: String? = nil) async -> Bool {
        guard let mapState = existingMapState(for: mapID), mapState.kind != .unsupported,
              let openedDocument = document, let openedURL = openedDocument.url,
              !isRunningPlanCompute, !isRunningProjectTool, !isOpeningProject,
              !isSavingAll, !isClosingTab else { return false }
        let project = projectSessionID
        let mapIdentity = mapWorkflowIdentity(mapID)
        do {
            guard ["tif", "tiff"].contains(file.pathExtension.lowercased()),
                  let provider = layerTreeProvider as? BackendMapTreeProvider,
                  let projectRevision = openedDocument.sourceRevision else {
                throw BackendServiceError(code: "unsupported", message: "This source map operation is unavailable for the selected map.")
            }
            let sourceRevision = try await Task.detached {
                let handle = try FileHandle(forReadingFrom: file)
                defer { try? handle.close() }
                var hash = SHA256()
                while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
                    try Task.checkCancellation()
                    hash.update(data: data)
                }
                return hash.finalize().map { String(format: "%02X", $0) }.joined()
            }.value
            if let expectedSourceRevision,
               sourceRevision.caseInsensitiveCompare(expectedSourceRevision) != .orderedSame {
                throw ProjectFileError.modifiedExternally
            }
            guard document === openedDocument, openedDocument.url == openedURL,
                  projectSessionID == project, existingMapState(for: mapID) === mapState,
                  mapWorkflowIdentity(mapID) == mapIdentity,
                  !isRunningPlanCompute, !isRunningProjectTool, !isOpeningProject,
                  !isSavingAll, !isClosingTab else { return false }
            let stagedXML = try openedDocument.editorXML(connectingFile: file, overridingDescription: descriptionDraft)
            let imported = try await provider.importRaster(sourcePath: file.standardizedFileURL.path,
                revision: sourceRevision, projectXML: stagedXML, projectRevision: projectRevision,
                context: sourceMapTreeContext(mapID), didPublish: {
                    try openedDocument.connectFile(file)
                    self.isModified = true
                })
            guard document === openedDocument, projectSessionID == project,
                  existingMapState(for: mapID) === mapState else { return false }
            await configureMapResultSources(mapID)
            guard document === openedDocument, projectSessionID == project,
                  existingMapState(for: mapID) === mapState else { return false }
            if mapID == MapState.projectMapID { page = .map }
            else if mapDocuments.contains(where: { $0.id == mapID }) { activeTab = .map(mapID) }
            log("Add Map Layer", L10n.format("Connected %@.", file.lastPathComponent))
            if let warning = imported.refreshWarning {
                report("Add Map Layer", BackendServiceError(code: "refreshFailed",
                    message: L10n.format("The layer was imported, but the map could not be refreshed: %@.", warning)))
            }
            return true
        } catch is CancellationError { return false }
        catch {
            if document === openedDocument, projectSessionID == project { report("Add Map Layer", error) }
            return false
        }
    }
    private func loadMapLayers() {
        mapLoadTask?.cancel(); mapLoadRevision += 1
        let revision = mapLoadRevision
        mapLayers = []; selectedFeatureID = nil
        guard let openedDocument = document, let directory = openedDocument.directory else { isMapLoading = false; return }
        let files = assets.filter { ["geojson", "json"].contains($0.url.pathExtension.lowercased()) }.map(\.url)
        let connections = openedDocument.connections
        let mappings = pathMappings
        isMapLoading = true
        mapLoadTask = Task {
            defer { if revision == mapLoadRevision { isMapLoading = false } }
            let worker = Task.detached { try MapFileLoader.load(files: files, connections: connections, directory: directory, mappings: mappings) }
            do {
                let result = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                guard !Task.isCancelled, revision == mapLoadRevision, document === openedDocument else { return }
                mapLayers = result.layers
                for layer in result.layers where !assets.contains(where: { $0.url.standardizedFileURL == layer.url.standardizedFileURL }) {
                    assets.append(ProjectAsset(url: layer.url, section: .mapLayers))
                }
                for issue in result.issues { messages.append(WorkspaceMessage(operation: L10n.text("Map Layer"), text: L10n.text(issue), isError: true)) }
                for state in Array(mapStates.values) {
                    guard !Task.isCancelled, revision == mapLoadRevision, document === openedDocument else { return }
                    await (vectorSymbologyProvider as? WorkspaceVectorSymbologyProvider)?.refresh(mapID: state.id)
                }
                mapRevision += 1
            } catch is CancellationError {} catch { if revision == mapLoadRevision { report("Map Layer", error) } }
        }
    }
    func reloadMapLayersAndWait() async {
        loadMapLayers()
        let task = mapLoadTask
        await task?.value
    }
    func refreshSourceMapVectors(_ nodes: [LayerTreeNode], mapID: UUID) async {
        guard !Task.isCancelled else { return }
        sourceMapVectorLoadTasks[mapID]?.cancel()
        let operationID = UUID()
        let task = Task<Void, Never> { [weak self] in
            guard let self else { return }
            await self.loadSourceMapVectors(nodes, mapID: mapID, operationID: operationID)
        }
        sourceMapVectorLoadTasks[mapID] = task
        await withTaskCancellationHandler {
            _ = await task.value
        } onCancel: { task.cancel() }
    }
    private func loadSourceMapVectors(_ nodes: [LayerTreeNode], mapID: UUID, operationID: UUID) async {
        guard !Task.isCancelled, let map = mapIdentityRequest(for: mapID),
              let state = existingMapState(for: mapID) else { return }
        let expectedSession = projectSessionID
        let identity = mapWorkflowIdentity(mapID)
        guard isCurrentMapState(state, mapID: mapID, projectSessionID: expectedSession) else { return }
        let reads = sourceMapVectorReadRequests(nodes, mapID: mapID)
        sourceMapVectorLoadStates[mapID] = .init(operationID: operationID, projectSessionID: expectedSession,
            mapWorkflowIdentity: identity, phase: .loading, completedFiles: 0, totalFiles: reads.files.count,
            currentSourceName: reads.files.first?.displayName, issues: reads.issues)
        defer {
            if let current = sourceMapVectorLoadStates[mapID], current.operationID == operationID {
                if current.isActive {
                    sourceMapVectorLoadStates[mapID] = current.replacing(phase: .cancelled, currentSourceName: .some(nil))
                }
                sourceMapVectorLoadTasks[mapID] = nil
            }
        }
        vectorStyleNodes[mapID] = nodes
        vectorSymbologyContextRevision &+= 1
        var presentationURLs: [String: URL] = [:]
        for node in nodes {
            guard let url = sourceMapVectorURL(node) else { continue }
            let physicalPath = SourceFilePaths.canonical(url)
            if presentationURLs[physicalPath] == nil { presentationURLs[physicalPath] = url }
        }
        // Include unavailable node identities so their stale cached geometry is
        // removed even though the reader must only receive verified assets.
        let paths = Set((state.sourceVectorBindings ?? []).map(\.sourcePath))
            .union(presentationURLs.keys)
        state.sourceVectorPaths = paths
        do {
            let result = try await MixedMapVectorSourceReader.load(reads: reads, nodes: nodes, map: map,
                provider: BackendMapVectorSourceProvider(client: runtimeInfoClient)) { [weak self] update in
                guard let self, self.projectSessionID == expectedSession,
                      self.mapWorkflowIdentity(mapID) == identity,
                      let current = self.sourceMapVectorLoadStates[mapID],
                      current.operationID == operationID, current.phase == .loading,
                      update.completedFiles >= current.completedFiles else { return }
                self.sourceMapVectorLoadStates[mapID] = current.replacing(
                    completedFiles: update.completedFiles, currentSourceName: .some(update.currentSourceName), issues: update.issues)
            }
            guard !Task.isCancelled, sourceMapVectorLoadStates[mapID]?.operationID == operationID,
                  isCurrentMapState(state, mapID: mapID, projectSessionID: expectedSession),
                  mapIdentityRequest(for: mapID) == map,
                  mapWorkflowIdentity(mapID) == identity else { return }
            let loadedPaths = Set(result.layers.map { SourceFilePaths.canonical($0.url) })
            // Failed or missing sources must not keep stale cached geometry.
            // Editor draft ledgers are separate and remain available to save,
            // discard, or recover explicitly.
            var installed = mapLayers.filter {
                let path = SourceFilePaths.canonical($0.url)
                let belongsToMap = $0.sourceMapID == nil || $0.sourceMapID == mapID
                return !belongsToMap || !paths.contains(path) || loadedPaths.contains(path)
            }
            for layer in result.layers {
                let path = SourceFilePaths.canonical(layer.url)
                if let index = installed.firstIndex(where: {
                    SourceFilePaths.canonical($0.url) == path && $0.sourceMapID == layer.sourceMapID
                }) { installed[index] = layer }
                else { installed.append(layer) }
            }
            // Publish every accepted source together, with no suspension point
            // between stale removal and replacement installation.
            mapLayers = installed
            sourceMapVectorFamilyCaptures[mapID] = result.families
            if let current = sourceMapVectorLoadStates[mapID], current.operationID == operationID {
                sourceMapVectorLoadStates[mapID] = current.replacing(phase: .completed,
                    completedFiles: reads.files.count, currentSourceName: .some(nil), issues: result.issues)
            }
            for issue in result.issues { log("Map Layer", L10n.text(issue)) }
            for layer in result.layers {
                guard !Task.isCancelled, sourceMapVectorLoadStates[mapID]?.operationID == operationID,
                      isCurrentMapState(state, mapID: mapID, projectSessionID: expectedSession),
                      mapIdentityRequest(for: mapID) == map, mapWorkflowIdentity(mapID) == identity else { return }
                let path = SourceFilePaths.canonical(layer.url)
                for binding in state.sourceVectorBindings ?? [] where binding.sourcePath == path { state.includeLayer(binding.id) }
                let editor = state.polylineEditor
                if editor.currentScope?.canonicalPath == path, !editor.hasUnsavedChanges, !editor.isBusy,
                   editor.currentSourceRevision != layer.sourceRevision { _ = await editor.discard() }
            }
            guard !Task.isCancelled, sourceMapVectorLoadStates[mapID]?.operationID == operationID,
                  isCurrentMapState(state, mapID: mapID, projectSessionID: expectedSession),
                  mapIdentityRequest(for: mapID) == map, mapWorkflowIdentity(mapID) == identity else { return }
            await (vectorSymbologyProvider as? WorkspaceVectorSymbologyProvider)?.refresh(mapID: mapID)
        } catch is CancellationError {
            if projectSessionID == expectedSession, let current = sourceMapVectorLoadStates[mapID], current.operationID == operationID {
                sourceMapVectorLoadStates[mapID] = current.replacing(phase: .cancelled, currentSourceName: .some(nil))
            }
        } catch {
            guard !Task.isCancelled, sourceMapVectorLoadStates[mapID]?.operationID == operationID,
                  isCurrentMapState(state, mapID: mapID, projectSessionID: expectedSession),
                  mapIdentityRequest(for: mapID) == map,
                  mapWorkflowIdentity(mapID) == identity else { return }
            if let current = sourceMapVectorLoadStates[mapID], current.operationID == operationID {
                sourceMapVectorLoadStates[mapID] = current.replacing(phase: .failed, currentSourceName: .some(nil),
                    issues: current.issues + [error.localizedDescription])
            }
            report("Map Layer", error)
        }
    }
    func cancelMapLoading() {
        for mapID in Array(sourceMapVectorLoadTasks.keys) { cancelSourceMapVectorLoad(mapID: mapID) }
        mapLoadTask?.cancel(); mapLoadRevision += 1; isMapLoading = false
        rasterMapLoadTask?.cancel(); rasterMapLoadRevision += 1; isRasterMapLoading = false
    }
    private func persistApplicationPreference(_ value: Any?, forKey key: String) {
        guard !suppressesAppDataIO else { return }
        applicationDefaults.set(value, forKey: key)
    }
    private func removeApplicationPreference(forKey key: String) {
        guard !suppressesAppDataIO else { return }
        applicationDefaults.removeObject(forKey: key)
    }
    func setTheme(_ value: String) { theme = value; persistApplicationPreference(value, forKey: "SystemTheme") }
    func finishFirstLaunch() { isFirstLaunch = false; persistApplicationPreference(true, forKey: "HasSeenFirstLaunch") }
    func chooseProjectDirectory() {
        if let url = system.chooseFolder(title: L10n.text("Project Folder")) {
            projectDirectory = url; persistApplicationPreference(url.path, forKey: "UserOverrideProjectDirectory")
        }
    }
    func chooseTemporaryDirectory() {
        if let url = system.chooseFolder(title: L10n.text("Temporary Folder")) {
            temporaryDirectory = url; persistApplicationPreference(url.path, forKey: "UserOverrideTempDirectory")
        }
    }
    func resetDirectories() {
        projectDirectory = PlatformPaths.defaultProjectDirectory; temporaryDirectory = PlatformPaths.temporaryDirectory
        removeApplicationPreference(forKey: "UserOverrideProjectDirectory"); removeApplicationPreference(forKey: "UserOverrideTempDirectory")
    }
    func removeMappings(at offsets: IndexSet) {
        for index in offsets.sorted(by: >) { pathMappings.remove(at: index) }
        if let data = try? JSONEncoder().encode(pathMappings) { persistApplicationPreference(data, forKey: "PathMappings") }
    }
    func setLanguage(_ value: String) { interfaceLanguage = value; L10n.language = value; persistApplicationPreference(value, forKey: "UILanguage") }
    func addMapping(source: String) {
        guard let folder = system.chooseFolder(title: L10n.format("Map %@ to a folder", source)) else { return }
        pathMappings.removeAll { $0.sourceRoot.caseInsensitiveCompare(source) == .orderedSame }
        pathMappings.append(PathMapping(sourceRoot: source, destination: folder))
        if let data = try? JSONEncoder().encode(pathMappings) { persistApplicationPreference(data, forKey: "PathMappings") }
        loadMapLayers()
    }
    func clearRecentProjects() { recentProjectHistory = []; if !suppressesAppDataIO { recentHistoryStore.clear() } }
    func removeRecentProject(_ url: URL) {
        recentProjectHistory.removeAll { $0.url.standardizedFileURL == url.standardizedFileURL }
        if !suppressesAppDataIO { recentHistoryStore.save(recentProjectHistory) }
    }
    func enqueueMapInput(_ input: MapInput) {
        guard let provider = mapInteractionProvider else { return }
        // Pointer updates are replaceable; clicks and drags retain event order.
        if input.kind == .pointerMoved, pendingMapInputs.last?.kind == .pointerMoved { pendingMapInputs[pendingMapInputs.count - 1] = input }
        else { pendingMapInputs.append(input) }
        guard !handlingMapInputs else { return }
        handlingMapInputs = true
        let sessionID = projectSessionID
        mapInputTask = Task {
            defer { if projectSessionID == sessionID { handlingMapInputs = false } }
            while !pendingMapInputs.isEmpty, !Task.isCancelled, projectSessionID == sessionID {
                let next = pendingMapInputs.removeFirst()
                do {
                    let update = try await provider.handle(next)
                    guard !Task.isCancelled, projectSessionID == sessionID else { return }
                    installMapUpdate(update, mapID: next.mapID)
                }
                catch { if projectSessionID == sessionID { report("Map Tools", error); pendingMapInputs = [] } }
            }
        }
    }
    func undoMapEdit() async {
        guard let provider = mapInteractionProvider else { return }
        let sessionID = projectSessionID, mapID = lastActiveMapID
        do { let update = try await provider.undo(); if projectSessionID == sessionID { installMapUpdate(update, mapID: mapID) } }
        catch { if projectSessionID == sessionID { report("Map Tools", error) } }
    }
    func redoMapEdit() async {
        guard let provider = mapInteractionProvider else { return }
        let sessionID = projectSessionID, mapID = lastActiveMapID
        do { let update = try await provider.redo(); if projectSessionID == sessionID { installMapUpdate(update, mapID: mapID) } }
        catch { if projectSessionID == sessionID { report("Map Tools", error) } }
    }
    func mapAssetID(layerID: String, mapID: UUID) -> String? {
        if let layer = mapState(for: mapID).vectors(mapLayers).first(where: { $0.id == layerID }) {
            return assets.first { SourceFilePaths.canonical($0.url) == SourceFilePaths.canonical(layer.url) }?.id
        }
        return assets.first { $0.id == layerID }?.id
    }
    func installMapUpdate(_ update: MapUpdate, mapID: UUID) {
        let state = mapState(for: mapID)
        state.installProfile(update, isEditing: true)
        guard !update.preserveInteractionState else { return }
        mapHistoryAvailability[mapID] = update.history
        if let id = update.selectedLayerID { state.selectedLayerID = id }
        if let id = update.selectedFeatureID { state.selectedFeatureID = id }
        if lastActiveMapID == mapID {
            if let id = update.selectedLayerID { selectedAssetID = mapAssetID(layerID: id, mapID: mapID) }
            if let id = update.selectedFeatureID { selectedFeatureID = id }
        }
    }
    func configureProfiles(_ presentation: MapProfilePresentation, mapID: UUID, provider: (any ProfileProvider)?) throws {
        let state = mapState(for: mapID)
        let context = MapProfileContext(projectSessionID: projectSessionID, mapID: mapID, sourceID: presentation.sourceID)
        try state.profiles.configure(presentation, provider: provider, context: context)
        state.clearProfileRender()
        state.profiles.didSelect = { [weak self, weak state] update, returnedContext in
            guard let self, let state, self.projectSessionID == returnedContext.projectSessionID,
                  self.mapStates[returnedContext.mapID] === state else { return }
            state.installProfile(update)
            if self.lastActiveMapID == returnedContext.mapID {
                if let id = update.selectedLayerID { self.selectedAssetID = self.mapAssetID(layerID: id, mapID: returnedContext.mapID) }
                if let id = update.selectedFeatureID { self.selectedFeatureID = id }
            }
        }
        state.profiles.reloadCurrent()
    }
    func cancelJob(_ id: String) async {
        guard let jobProvider, !pendingJobActions.contains(id),
              let job = jobs.first(where: { $0.id == id }), !job.isComplete, job.isCancellable, !job.isCancelling else { return }
        pendingJobActions.insert(id); defer { pendingJobActions.remove(id) }
        do { try await jobProvider.cancel(id) } catch { report("Jobs", error) }
    }
    func removeJob(_ id: String) async {
        guard let jobProvider, !pendingJobActions.contains(id), jobs.contains(where: { $0.id == id && $0.canDelete }) else { return }
        pendingJobActions.insert(id); defer { pendingJobActions.remove(id) }
        do { try await jobProvider.remove(id) } catch { report("Jobs", error) }
    }
    func clearMessages() { messages = [] }
    func enqueueMessage(_ message: WorkspaceMessage) { messages.append(message) }
    func log(_ operation: String, _ text: String,
             severity: WorkspaceMessageSeverity = .information,
             defaultAction: WorkspaceMessageDefaultAction? = .showMessages) {
        try? WorkspaceApplicationLog.append(operation, text, level: severity.rawValue)
        enqueueMessage(WorkspaceMessage(operation: L10n.text(operation), text: text,
            severity: severity, defaultAction: defaultAction))
    }
    private func report(_ operation: String, _ error: Error,
                        defaultAction: WorkspaceMessageDefaultAction? = .showMessages) {
        errorMessage = L10n.text(error.localizedDescription)
        try? WorkspaceApplicationLog.append(operation, error.localizedDescription,
            level: WorkspaceMessageSeverity.error.rawValue, errorDetails: String(describing: error))
        enqueueMessage(WorkspaceMessage(operation: L10n.text(operation),
            text: L10n.text(error.localizedDescription), severity: .error,
            defaultAction: defaultAction))
        showMessages = true
    }
    @discardableResult
    func performMessageDefaultAction(_ message: WorkspaceMessage) -> Bool {
        guard messages.contains(where: { $0.id == message.id && $0.defaultAction == message.defaultAction }),
              let action = message.defaultAction else { return false }
        switch action {
        case .showMessages:
            showMessages = true
            return true
        case .openEditor(let sessionID, let rawKind, let assetID):
            guard sessionID == projectSessionID, hasProject,
                  !isRunningPlanCompute, !isOpeningProject, !isClosingTab,
                  !isSavingAll, !isRunningProjectTool,
                  let kind = ModelEditorKind(rawValue: rawKind),
                  assets.contains(where: { $0.id == assetID && $0.section == kind.section && $0.isModelFile }) else { return false }
            openEditor(kind, assetID: assetID)
            return true
        case .openMap(let sessionID, let mapID):
            guard sessionID == projectSessionID, hasProject,
                  !isOpeningProject, !isClosingTab else { return false }
            if mapID == MapState.projectMapID {
                activateMap(mapID)
                activeTab = .page(.map)
            } else {
                guard let map = mapDocuments.first(where: { $0.id == mapID }) else { return false }
                openMapDocument(map)
            }
            return true
        }
    }
    private func recordRecent(_ url: URL) {
        recentProjectHistory.removeAll { $0.url.standardizedFileURL == url.standardizedFileURL }
        recentProjectHistory.insert(.init(url: url, lastOpened: .now), at: 0)
        recentProjectHistory = Array(recentProjectHistory.prefix(20))
        if !suppressesAppDataIO { recentHistoryStore.save(recentProjectHistory) }
    }
}

extension WorkspaceStore {
    /// Deletes one exact saved `.vis` map row. Remaining runtime IDs are
    /// remapped from the Host's previous-index receipt, so duplicate names do
    /// not transfer camera, selection, or source caches to another map.
    @discardableResult
    func deleteMapDocument(_ mapID: UUID) async -> Bool {
        guard !isSavingAll, !isRunningProjectTool, !isOpeningProject, !isClosingTab,
              !isRunningMapMutation,
              let projectURL = document?.url,
              let provider = layerTreeProvider as? BackendMapTreeProvider,
              let target = catalogMapDocuments.first(where: {
                  $0.id.caseInsensitiveCompare(mapID.uuidString) == .orderedSame
                      && $0.sourceIndex != nil
              }),
              let visualization else { return false }
        let targetState = mapState(for: mapID)
        guard !targetState.polylineEditor.isBusy,
              !targetState.polylineEditor.hasUnsavedChanges else {
            errorMessage = L10n.text("Save or discard the line edits before deleting this map.")
            return false
        }

        let projectSession = projectSessionID
        let oldMaps = catalogMapDocuments.filter { $0.sourceIndex != nil }.sorted {
            $0.sourceIndex! < $1.sourceIndex!
        }
        let oldIDByIndex = visualizationMapIDs
        let oldIdentityByIndex = visualizationMapIdentities
        guard let removedIndex = target.sourceIndex,
              oldMaps.contains(where: { $0.sourceIndex == removedIndex && $0.id == target.id }),
              oldMaps.allSatisfy({ map in
                  guard let index = map.sourceIndex else { return false }
                  return oldIDByIndex[index] != nil && oldIdentityByIndex[index] != nil
              }) else { return false }

        do {
            let receipt = try await provider.deleteMap(projectPath: projectURL.standardizedFileURL.path,
                map: target)
            guard projectSessionID == projectSession, document?.url == projectURL,
                  receipt.removedMapIndex == removedIndex,
                  receipt.removedMapName == target.name,
                  receipt.removedMapType == target.kind,
                  receipt.previousVisualizationRevision.caseInsensitiveCompare(
                    visualization.sourceRevision ?? "") == .orderedSame else { return false }

            let expectedRemaining = oldMaps.filter { $0.sourceIndex != removedIndex }
            guard receipt.mapIndexChanges.count == expectedRemaining.count else {
                throw BackendServiceError(code: "sourceChanged",
                    message: "The map deletion reply does not account for every remaining map.")
            }
            // The Host has already committed the deletion. Validate its new
            // source indices against those published bytes, not the old
            // in-memory map list which still includes the removed map.
            let publishedVisualization = try VisualizationDocument(projectURL: projectURL)
            guard publishedVisualization.sourceRevision?.caseInsensitiveCompare(
                receipt.visualizationRevision) == .orderedSame else {
                throw ProjectFileError.modifiedExternally
            }
            var newIDs: [Int: UUID] = [:]
            var newIdentities: [Int: VisualizationMapIdentity] = [:]
            var seenPrevious = Set<Int>()
            var seenIndices = Set<Int>()
            for change in receipt.mapIndexChanges {
                guard seenPrevious.insert(change.previousMapIndex).inserted,
                      seenIndices.insert(change.mapIndex).inserted,
                      change.previousMapIndex != removedIndex,
                      let oldMap = oldMaps.first(where: { $0.sourceIndex == change.previousMapIndex }),
                      let oldID = oldIDByIndex[change.previousMapIndex],
                      oldMap.name == change.mapName, oldMap.kind == change.mapType,
                      change.mapIndex == (change.previousMapIndex > removedIndex
                        ? change.previousMapIndex - 1 : change.previousMapIndex),
                      let persisted = publishedVisualization.maps.first(where: { $0.index == change.mapIndex }),
                      persisted.name == change.mapName, persisted.type == change.mapType else {
                    throw BackendServiceError(code: "sourceChanged",
                        message: "The map deletion reply does not match the remaining saved map identities.")
                }
                newIDs[change.mapIndex] = oldID
                newIdentities[change.mapIndex] = persisted
            }
            guard seenPrevious == Set(expectedRemaining.compactMap(\.sourceIndex)),
                  seenIndices == Set(expectedRemaining.compactMap { index in
                      guard let previous = index.sourceIndex else { return nil }
                      return previous > removedIndex ? previous - 1 : previous
                  }),
                  publishedVisualization.maps.count == expectedRemaining.count else {
                throw BackendServiceError(code: "sourceChanged",
                    message: "The map deletion reply is incomplete or ambiguous.")
            }

            try visualization.acceptExternalMapChange(
                expectedPreviousRevision: receipt.previousVisualizationRevision,
                newRevision: receipt.visualizationRevision)

            mapResultSourceSetupCoordinator.cancel(mapID: mapID)
            targetState.resultSources.invalidate()
            targetState.resultMap.invalidate()
            targetState.projectGeometryMap.invalidate()
            targetState.associatedMapLayers.invalidate()
            targetState.boundaryCaptureGeneration &+= 1
            targetState.boundaryMap.invalidate()
            targetState.storedCulvertProfile.invalidate()
            targetState.meshErrors.invalidate()
            targetState.mapSelectionMeasurement.invalidate()
            targetState.profiles.invalidate()
            targetState.polylineEditor.discardForProjectReplacement()
            invalidateMapCharts(mapID: mapID)
            invalidateMapDynamicProfiles(mapID: mapID,
                reason: L10n.text("The selected map, result source, or polyline changed."))

            visualizationMapIDs = newIDs
            visualizationMapIdentities = newIdentities
            mapDocuments.removeAll { $0.id == mapID }
            mapDocumentNames[mapID] = nil
            mapStates[mapID] = nil
            mapStateSubscriptions[mapID] = nil
            mapMeshErrorSourceSubscriptions[mapID] = nil
            mapSelectedLayerSubscriptions[mapID] = nil
            mapLineSelectionSubscriptions[mapID] = nil
            mapEditingLineSubscriptions[mapID] = nil
            mapDynamicProfileSourceSubscriptions[mapID] = nil
            mapDynamicProfileSelectionSubscriptions[mapID] = nil
            rasterLayers.removeAll { $0.sourceMapID == mapID }
            rasterMapSources.removeAll { $0.sourceMapID == mapID }
            rasterMapSourceInfoStats = rasterMapSourceInfoStats.filter { !$0.key.hasPrefix(mapID.uuidString + "|") }
            mapLayers.removeAll { $0.sourceMapID == mapID }
            installVisualizationMaps(visualization)
            try refreshRasterMapSources()
            configureRasterSymbologyProvider()
            loadRasterMapLayers()
            assetsRevision += 1

            // The receipt preserves each surviving runtime UUID by its old
            // source index, but every .vis-backed context is bound to the new
            // index and revision. Rebuild those captures now while retaining
            // the existing MapState camera, selection, and local drafts.
            for survivorID in newIDs.sorted(by: { $0.key < $1.key }).map(\.value) {
                await configureMapResultSources(survivorID)
                guard projectSessionID == projectSession else { return false }
            }

            let replacement = newIDs.sorted(by: { $0.key < $1.key }).first?.value
            if activeTab == .map(mapID) {
                if let replacement { activeTab = .map(replacement) }
                else { activeTab = .page(.map) }
            } else if lastActiveMapID == mapID {
                if let replacement { activateMap(replacement) }
                else { activeTab = .page(.map) }
            }
            return projectSessionID == projectSession
        } catch is CancellationError {
            return false
        } catch {
            if projectSessionID == projectSession { errorMessage = L10n.text(error.localizedDescription) }
            return false
        }
    }
}
