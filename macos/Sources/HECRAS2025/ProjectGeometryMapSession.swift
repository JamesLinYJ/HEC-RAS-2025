import Combine
import Foundation
import RASWorkspaceCore

struct ProjectGeometryMapPageProgress: Sendable {
    var sourceCount = 0
    var scannedCount = 0
    var returnedCount = 0
    var invalidCount = 0
    var complete = false
    var nextCursor: String?
}

struct ProjectGeometryMapSelection: Equatable, Sendable {
    let id: String
    let geometryName: String
    let layerTitle: String
    let featureLabel: String
}

struct ProjectGeometryMapFlowAreaGenerationPresentation: Sendable {
    enum Phase: String, Equatable, Sendable {
        case generating
        case childDraft
        case awaitingSavedSource
    }

    let identity: String
    let phase: Phase
    /// The exact GeometryMeshSession child preview. A nil map in the child
    /// draft phase intentionally means no saved source cells may be reused.
    let map: GeometryMeshMapData?
}

/// A runtime-only Geometry culvert draft extent used by the shared MapState
/// transform. It is scoped to the exact source capture and HDF revision; it
/// does not alter the persisted map or move an already established camera.
struct ProjectGeometryMapCulvertDraftPresentation: Sendable {
    let identity: String
    let captureIdentity: String
    let projectSessionID: UUID
    let mapID: UUID
    let mapWorkflowIdentity: String
    let geometryCanonicalPath: String
    let geometryRevision: String
    let extent: GeometryTopologyExtent?
    let featureCount: Int
}

struct ProjectGeometryMapSourceState: Identifiable, Sendable {
    let capture: ProjectGeometryMapCapture
    var snapshot: MapGeometrySnapshot?
    var error: String?
    var isLoading = false
    var topologyFeatures: [GeometryTopologyMapFeature] = []
    var cells: [GeometryMeshMapCell] = []
    var culvertFeatures: [GeometryCulvertFeatureRow] = []
    var topologyExtent: GeometryTopologyExtent?
    var flowAreasExtent: GeometryTopologyExtent?
    var culvertsExtent: GeometryTopologyExtent?
    var topologyProgress = ProjectGeometryMapPageProgress()
    var cellsProgress = ProjectGeometryMapPageProgress()
    var culvertsProgress = ProjectGeometryMapPageProgress()
    var viewportIdentity: String?
    var flowAreaGenerationPresentation: ProjectGeometryMapFlowAreaGenerationPresentation?
    var culvertDraftPresentation: ProjectGeometryMapCulvertDraftPresentation?
    /// The source FlowAreaLayer tree node that received the terminal
    /// Generate Mesh visibility state. This is a map-local presentation
    /// override; it never changes the saved map tree or its .vis revision.
    var flowAreaVisibilityOverrideLocatorIdentity: String?

    var id: String { capture.identity }
    var contextToken: String? { snapshot?.contextToken }
    var geometryRevision: String? { snapshot?.geometryRevision }
    var hasNextPage: Bool {
        guard let snapshot, snapshot.geometryEffectiveVisible else { return false }
        return needsPage(snapshot.topologyState, progress: topologyProgress)
            || (flowAreaGenerationPresentation == nil
                && needsPage(snapshot.flowAreasState, progress: cellsProgress,
                    forceVisible: flowAreaVisibilityOverrideLocatorIdentity != nil))
            || needsPage(snapshot.culvertsState, progress: culvertsProgress)
    }
    var presentedFlowAreaCells: [GeometryMeshMapCell] {
        guard let flowAreaGenerationPresentation else { return cells }
        switch flowAreaGenerationPresentation.phase {
        case .generating, .awaitingSavedSource: return []
        case .childDraft: return flowAreaGenerationPresentation.map?.cells ?? []
        }
    }
    var presentedFlowAreaExtent: GeometryTopologyExtent? {
        guard let flowAreaGenerationPresentation else { return flowAreasExtent }
        switch flowAreaGenerationPresentation.phase {
        case .generating, .awaitingSavedSource: return nil
        case .childDraft: return flowAreaGenerationPresentation.map?.extent
        }
    }
    var presentsFlowAreaData: Bool {
        guard let snapshot else { return false }
        if let flowAreaGenerationPresentation {
            switch flowAreaGenerationPresentation.phase {
            case .generating, .awaitingSavedSource: return false
            case .childDraft: return !presentedFlowAreaCells.isEmpty
            }
        }
        guard snapshot.flowAreasState.effectiveVisible
                || flowAreaVisibilityOverrideLocatorIdentity != nil else { return false }
        return snapshot.flowAreasState.status.hasSourceData
    }
    var visibleFeatureCount: Int {
        guard let snapshot, snapshot.geometryEffectiveVisible else { return 0 }
        var count = 0
        if snapshot.topologyState.effectiveVisible && snapshot.topologyState.status.hasSourceData {
            count += topologyFeatures.count
        }
        if presentsFlowAreaData {
            count += presentedFlowAreaCells.count
        }
        if snapshot.culvertsState.effectiveVisible && snapshot.culvertsState.status.hasSourceData {
            count += culvertDraftPresentation?.featureCount ?? culvertFeatures.count
        }
        return count
    }

    var visiblePoints: [MapPoint] {
        guard let snapshot, snapshot.geometryEffectiveVisible else { return [] }
        var result: [MapPoint] = []
        if snapshot.topologyState.effectiveVisible && snapshot.topologyState.status.hasSourceData {
            appendExtent(topologyExtent, to: &result)
        }
        if presentsFlowAreaData {
            appendExtent(presentedFlowAreaExtent, to: &result)
        }
        if snapshot.culvertsState.effectiveVisible && snapshot.culvertsState.status.hasSourceData {
            if let culvertDraftPresentation {
                appendExtent(culvertDraftPresentation.extent, to: &result)
            } else {
                appendExtent(culvertsExtent, to: &result)
            }
        }
        return result.filter { $0.x.isFinite && $0.y.isFinite }
    }

    private func appendExtent(_ extent: GeometryTopologyExtent?, to points: inout [MapPoint]) {
        guard let extent, extent.minX.isFinite, extent.minY.isFinite,
              extent.maxX.isFinite, extent.maxY.isFinite,
              extent.minX <= extent.maxX, extent.minY <= extent.maxY else { return }
        points.append(MapPoint(x: extent.minX, y: extent.minY))
        points.append(MapPoint(x: extent.maxX, y: extent.maxY))
    }

    private func needsPage(_ state: MapGeometryLayerState,
                           progress: ProjectGeometryMapPageProgress,
                           forceVisible: Bool = false) -> Bool {
        (state.effectiveVisible || forceVisible) && state.status.hasSourceData && !progress.complete
    }
}

@MainActor
final class ProjectGeometryMapSession: ObservableObject {
    private struct FlowAreaVisibilitySuppression: Hashable {
        let projectSessionID: UUID
        let mapID: UUID
        let geometryPath: String
        let geometryNodeIdentity: String
        let flowAreaLocatorIdentity: String
        let generationResultIdentity: String

        init(capture: ProjectGeometryMapCapture, locator: CatalogTreeNodeLocator,
             generationResultIdentity: String) {
            projectSessionID = capture.projectSessionID
            mapID = capture.mapID
            geometryPath = capture.geometryCanonicalPath
            geometryNodeIdentity = capture.geometryNode.sourceIdentity
            flowAreaLocatorIdentity = locator.sourceIdentity
            self.generationResultIdentity = generationResultIdentity
        }

        func belongs(to capture: ProjectGeometryMapCapture) -> Bool {
            projectSessionID == capture.projectSessionID && mapID == capture.mapID
                && geometryPath == capture.geometryCanonicalPath
                && geometryNodeIdentity == capture.geometryNode.sourceIdentity
        }
    }

    @Published private(set) var sources: [ProjectGeometryMapSourceState] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isPaused = false
    @Published private(set) var isConfigured = false
    @Published private(set) var error: String?
    @Published private(set) var selection: ProjectGeometryMapSelection?
    @Published private(set) var preflightDiagnostics: [String] = []
    @Published private(set) var renderRevision: UInt64 = 0
    @Published private(set) var cameraExtentRevision: UInt64 = 0

    private var map: MapTreeMapIdentity?
    private var mapWorkflowIdentity: String?
    private var provider: (any ProjectGeometryMapProvider)?
    private var isCurrent: (@MainActor () -> Bool)?
    private var viewport: MapGeometryViewport?
    private var activeTask: Task<Void, Never>?
    private var viewportTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var flowAreaVisibilitySuppressions: Set<FlowAreaVisibilitySuppression> = []
    private var geometryPlotSessions: [String: GeometryMeshPlotSession] = [:]

    var canRefreshSources: Bool { isConfigured && map != nil && provider != nil }
    var visiblePoints: [MapPoint] { sources.flatMap(\.visiblePoints) }
    var hasFlowAreaGenerationPresentation: Bool {
        sources.contains { $0.flowAreaGenerationPresentation.map { _ in true } ?? false }
    }
    var visibleChildLayerCount: Int {
        sources.reduce(into: 0) { count, source in
            guard let snapshot = source.snapshot, snapshot.geometryEffectiveVisible else { return }
            count += [snapshot.topologyState, snapshot.culvertsState]
                .filter(\.effectiveVisible).count
            let generatedPreview = source.flowAreaGenerationPresentation?.phase == .childDraft
            if snapshot.flowAreasState.effectiveVisible || generatedPreview
                || source.flowAreaVisibilityOverrideLocatorIdentity != nil { count += 1 }
        }
    }
    var hasVisibleGeometryData: Bool { !visiblePoints.isEmpty }
    var visibleGeometryFeatureCount: Int { sources.reduce(0) { $0 + $1.visibleFeatureCount } }
    var hasIncompletePages: Bool { sources.contains(where: \.hasNextPage) }
    var canContinuePaging: Bool {
        sources.contains { $0.snapshot == nil || $0.error != nil || $0.hasNextPage }
    }

    /// Returns the runtime-only plot owner for one current Geometry capture.
    /// An unavailable result is inert; stale details views cannot create a
    /// renderer after their map owner has been retired.
    func geometryPlotSession(for captureIdentity: String) -> GeometryMeshPlotSession {
        guard isConfigured,
              sources.contains(where: { $0.capture.identity == captureIdentity }) else {
            return .retiredSession
        }
        if let existing = geometryPlotSessions[captureIdentity] { return existing }
        let plotSession = GeometryMeshPlotSession(owner: self, captureIdentity: captureIdentity)
        plotSession.onChange = { [weak self] in
            guard let self, self.geometryPlotSessions[captureIdentity] === plotSession else { return }
            self.renderRevision &+= 1
        }
        geometryPlotSessions[captureIdentity] = plotSession
        return plotSession
    }

    /// Confirms that both the current map lease and source snapshot still
    /// match the capture before a backend request or reply is accepted.
    func ownsPlotSnapshot(_ source: ProjectGeometryMapSourceState) -> Bool {
        guard isConfigured,
              mapWorkflowIdentity == source.capture.mapWorkflowIdentity,
              let map,
              map.mapID == source.capture.mapID.uuidString,
              map.projectPath == source.capture.map.projectPath,
              map.projectXmlSHA.caseInsensitiveCompare(source.capture.map.projectXmlSHA) == .orderedSame,
              let current = sources.first(where: { $0.capture.identity == source.capture.identity }),
              current.capture == source.capture,
              let currentSnapshot = current.snapshot,
              let snapshot = source.snapshot else { return false }
        return currentSnapshot.contextToken == snapshot.contextToken
            && currentSnapshot.mapID == snapshot.mapID
            && currentSnapshot.projectRevision == snapshot.projectRevision
            && currentSnapshot.projectXmlSHA?.caseInsensitiveCompare(snapshot.projectXmlSHA ?? "") == .orderedSame
            && currentSnapshot.visualizationRevision == snapshot.visualizationRevision
            && currentSnapshot.geometryNode == snapshot.geometryNode
            && currentSnapshot.geometryCanonicalPath == snapshot.geometryCanonicalPath
            && currentSnapshot.geometryRevision == snapshot.geometryRevision
    }

    func configure(map: MapTreeMapIdentity, workflowIdentity: String,
                   captures: [ProjectGeometryMapCapture],
                   provider: any ProjectGeometryMapProvider,
                   preflightDiagnostics: [String] = [],
                   isCurrent: @escaping @MainActor () -> Bool) async {
        let requestedCaptureIdentities = Set(captures.map(\.identity))
        let loadedCaptureIdentities = Set(sources.map { $0.capture.identity })
        if self.mapWorkflowIdentity == workflowIdentity, isConfigured,
           requestedCaptureIdentities == loadedCaptureIdentities {
            // Completed source pages remain in the MapState. An interrupted or
            // failed automatic drain resumes on re-entry unless the user paused it.
            if !isLoading && !isPaused && canContinuePaging { startPaging(clearTokens: false) }
            return
        }
        retireGeometryPlotSessions()
        cancel()
        self.map = map
        self.mapWorkflowIdentity = workflowIdentity
        self.provider = provider
        self.isCurrent = isCurrent
        self.preflightDiagnostics = preflightDiagnostics
        self.viewport = nil
        flowAreaVisibilitySuppressions = flowAreaVisibilitySuppressions.filter { suppression in
            captures.contains { suppression.belongs(to: $0) }
        }
        self.sources = captures.map { ProjectGeometryMapSourceState(capture: $0) }
        self.selection = nil
        isConfigured = true
        isPaused = false
        error = nil
        renderRevision &+= 1
        cameraExtentRevision &+= 1
        // Start without a viewport. The backend returns the true source extent;
        // the saved map establishes its camera and requests that view's pages.
        reload(viewport: nil, force: true)
    }

    func invalidate() {
        retireGeometryPlotSessions()
        cancel()
        isConfigured = false
        map = nil
        mapWorkflowIdentity = nil
        provider = nil
        isCurrent = nil
        viewport = nil
        sources = []
        selection = nil
        error = nil
        preflightDiagnostics = []
        renderRevision &+= 1
        cameraExtentRevision &+= 1
    }

    func invalidateIfWorkflowChanged(_ workflowIdentity: String) {
        guard mapWorkflowIdentity != workflowIdentity else { return }
        invalidate()
    }

    func reportConfigurationError(_ message: String) {
        retireGeometryPlotSessions()
        cancel()
        map = nil
        mapWorkflowIdentity = nil
        provider = nil
        isCurrent = nil
        viewport = nil
        isConfigured = true
        error = message
        sources = []
        selection = nil
        preflightDiagnostics = []
        renderRevision &+= 1
        cameraExtentRevision &+= 1
    }

    func cancel() {
        generation &+= 1
        activeTask?.cancel()
        activeTask = nil
        viewportTask?.cancel()
        viewportTask = nil
        isLoading = false
        for index in sources.indices { sources[index].isLoading = false }
    }

    private func retireGeometryPlotSessions() {
        let sessions = Array(geometryPlotSessions.values)
        geometryPlotSessions.removeAll()
        for plotSession in sessions { plotSession.retire() }
    }

    func refresh() async {
        // Refresh is an explicit restart action, so it also clears a prior
        // user pause before loading the current viewport from the source again.
        isPaused = false
        reload(viewport: viewport, force: true)
    }

    func select(_ feature: ProjectGeometryMapSelection?) {
        guard selection != feature else { return }
        selection = feature
        renderRevision &+= 1
    }

    /// A Geometry editor's mesh child draft owns a transient map projection.
    /// It never changes the persisted per-map visibility flag or source pages.
    func setFlowAreaGenerationPresentation(
        _ presentation: ProjectGeometryMapFlowAreaGenerationPresentation?,
        captureIdentity: String
    ) {
        guard let index = sources.firstIndex(where: { $0.capture.identity == captureIdentity }),
              sources[index].flowAreaGenerationPresentation?.identity != presentation?.identity else { return }
        let previousCameraBounds = cameraBoundsIdentity
        sources[index].flowAreaGenerationPresentation = presentation
        if let selected = selection,
           selected.id.hasPrefix(captureIdentity + "|flow-area|") {
            selection = nil
        }
        renderRevision &+= 1
        if previousCameraBounds != cameraBoundsIdentity { cameraExtentRevision &+= 1 }
    }

    /// Installs the exact loaded Geometry child draft as a map-local extent.
    /// Unlike a source extent change, an editor draft must not reset an
    /// established camera; MapState uses this range after explicit full-fit or
    /// before it has established reference points.
    func setCulvertDraftPresentation(
        _ presentation: ProjectGeometryMapCulvertDraftPresentation?,
        captureIdentity: String
    ) {
        guard let index = sources.firstIndex(where: { $0.capture.identity == captureIdentity }) else { return }
        var source = sources[index]
        if let presentation {
            guard source.capture.resultOwner == nil,
                  presentation.captureIdentity == source.capture.identity,
                  presentation.projectSessionID == source.capture.projectSessionID,
                  presentation.mapID == source.capture.mapID,
                  presentation.mapWorkflowIdentity == source.capture.mapWorkflowIdentity,
                  presentation.geometryCanonicalPath == source.capture.geometryCanonicalPath,
                  source.snapshot?.geometryRevision.caseInsensitiveCompare(presentation.geometryRevision) == .orderedSame,
                  source.snapshot?.geometryEffectiveVisible == true,
                  source.snapshot?.culvertsState.effectiveVisible == true,
                  source.snapshot?.culvertsState.status.hasSourceData == true,
                  presentation.featureCount >= 0,
                  presentation.extent.map({ extent in
                      extent.minX.isFinite && extent.minY.isFinite && extent.maxX.isFinite && extent.maxY.isFinite
                          && extent.minX <= extent.maxX && extent.minY <= extent.maxY
                  }) ?? true else { return }
        }
        guard source.culvertDraftPresentation?.identity != presentation?.identity else { return }
        source.culvertDraftPresentation = presentation
        sources[index] = source
        if presentation == nil,
           selection?.id.hasPrefix(captureIdentity + "|culvert|parent-draft|") == true {
            selection = nil
        }
        renderRevision &+= 1
    }

    /// Mirrors the retained source job's terminal IsChecked=true state for
    /// this exact map/Geometry/FlowArea row. It remains local until the user
    /// changes that node or the map workflow/Geometry owner is retired.
    func setFlowAreaGenerationVisibilityOverride(_ locator: CatalogTreeNodeLocator?,
                                                 captureIdentity: String) {
        guard let index = sources.firstIndex(where: { $0.capture.identity == captureIdentity }) else { return }
        let identity: String?
        if let locator,
           locator.nodeType == "FlowAreaLayer",
           Self.flowAreaLocator(locator, belongsTo: sources[index].capture) {
            identity = locator.sourceIdentity
        } else {
            identity = nil
        }
        guard sources[index].flowAreaVisibilityOverrideLocatorIdentity != identity else { return }
        let previousCameraBounds = cameraBoundsIdentity
        sources[index].flowAreaVisibilityOverrideLocatorIdentity = identity
        renderRevision &+= 1
        if previousCameraBounds != cameraBoundsIdentity { cameraExtentRevision &+= 1 }
    }

    func hasFlowAreaGenerationVisibilityOverride(locator: CatalogTreeNodeLocator,
                                                  mapID: UUID,
                                                  projectSessionID: UUID,
                                                  mapWorkflowIdentity: String) -> Bool {
        guard let source = uniqueSource(for: locator, mapID: mapID,
            projectSessionID: projectSessionID, mapWorkflowIdentity: mapWorkflowIdentity) else { return false }
        return source.flowAreaVisibilityOverrideLocatorIdentity == locator.sourceIdentity
    }

    @discardableResult
    func suppressFlowAreaGenerationVisibilityOverride(locator: CatalogTreeNodeLocator,
                                                       captureIdentity: String,
                                                       generationResultIdentity: String) -> Bool {
        guard let source = sources.first(where: { $0.capture.identity == captureIdentity }),
              Self.flowAreaLocator(locator, belongsTo: source.capture),
              source.flowAreaVisibilityOverrideLocatorIdentity == locator.sourceIdentity,
              !generationResultIdentity.isEmpty else { return false }
        flowAreaVisibilitySuppressions.insert(FlowAreaVisibilitySuppression(
            capture: source.capture, locator: locator,
            generationResultIdentity: generationResultIdentity))
        return true
    }

    @discardableResult
    func suppressFlowAreaGenerationVisibilityOverride(locator: CatalogTreeNodeLocator,
                                                       mapID: UUID,
                                                       projectSessionID: UUID,
                                                       mapWorkflowIdentity: String,
                                                       generationResultIdentity: String) -> Bool {
        guard let source = uniqueSource(for: locator, mapID: mapID,
                  projectSessionID: projectSessionID,
                  mapWorkflowIdentity: mapWorkflowIdentity) else { return false }
        return suppressFlowAreaGenerationVisibilityOverride(locator: locator,
            captureIdentity: source.capture.identity,
            generationResultIdentity: generationResultIdentity)
    }

    func isFlowAreaGenerationVisibilitySuppressed(locator: CatalogTreeNodeLocator,
                                                   captureIdentity: String,
                                                   generationResultIdentity: String) -> Bool {
        guard let source = sources.first(where: { $0.capture.identity == captureIdentity }),
              Self.flowAreaLocator(locator, belongsTo: source.capture) else { return false }
        return flowAreaVisibilitySuppressions.contains(FlowAreaVisibilitySuppression(
            capture: source.capture, locator: locator,
            generationResultIdentity: generationResultIdentity))
    }

    func clearFlowAreaGenerationVisibilityState(capture: ProjectGeometryMapCapture) {
        if let index = sources.firstIndex(where: { $0.capture.identity == capture.identity }) {
            let previousCameraBounds = cameraBoundsIdentity
            sources[index].flowAreaVisibilityOverrideLocatorIdentity = nil
            renderRevision &+= 1
            if previousCameraBounds != cameraBoundsIdentity { cameraExtentRevision &+= 1 }
        }
        flowAreaVisibilitySuppressions = flowAreaVisibilitySuppressions.filter { !$0.belongs(to: capture) }
    }

    @discardableResult
    func clearFlowAreaGenerationVisibilityOverride(locator: CatalogTreeNodeLocator,
                                                    mapID: UUID,
                                                    projectSessionID: UUID,
                                                    mapWorkflowIdentity: String) -> Bool {
        guard let index = sources.firstIndex(where: { source in
            source.capture.mapID == mapID
                && source.capture.projectSessionID == projectSessionID
                && source.capture.mapWorkflowIdentity == mapWorkflowIdentity
                && Self.flowAreaLocator(locator, belongsTo: source.capture)
                && source.flowAreaVisibilityOverrideLocatorIdentity == locator.sourceIdentity
        }) else { return false }
        let previousCameraBounds = cameraBoundsIdentity
        sources[index].flowAreaVisibilityOverrideLocatorIdentity = nil
        renderRevision &+= 1
        if previousCameraBounds != cameraBoundsIdentity { cameraExtentRevision &+= 1 }
        return true
    }

    func clearFlowAreaGenerationVisibilityOverride(captureIdentity: String) {
        guard let index = sources.firstIndex(where: {
            $0.capture.identity == captureIdentity
                && $0.flowAreaVisibilityOverrideLocatorIdentity != nil
        }) else { return }
        let previousCameraBounds = cameraBoundsIdentity
        sources[index].flowAreaVisibilityOverrideLocatorIdentity = nil
        renderRevision &+= 1
        if previousCameraBounds != cameraBoundsIdentity { cameraExtentRevision &+= 1 }
    }

    private func uniqueSource(for locator: CatalogTreeNodeLocator, mapID: UUID,
                              projectSessionID: UUID,
                              mapWorkflowIdentity: String) -> ProjectGeometryMapSourceState? {
        let matches = sources.filter { source in
            source.capture.mapID == mapID
                && source.capture.projectSessionID == projectSessionID
                && source.capture.mapWorkflowIdentity == mapWorkflowIdentity
                && Self.flowAreaLocator(locator, belongsTo: source.capture)
        }
        return matches.count == 1 ? matches.first : nil
    }

    private static func flowAreaLocator(_ locator: CatalogTreeNodeLocator,
                                        belongsTo capture: ProjectGeometryMapCapture) -> Bool {
        guard locator.nodeType == "FlowAreaLayer",
              locator.rootName == capture.geometryNode.rootName,
              let parentPath = locator.parentGeometryAssetID,
              SourceFilePaths.canonical(URL(fileURLWithPath: parentPath)) == capture.geometryCanonicalPath,
              locator.parentGeometryNodePath == capture.geometryNode.nodePath,
              locator.parentGeometryNodeName == capture.geometryNode.nodeName else { return false }
        let owner = capture.geometryNode
        return locator.parentPlanAssetID == owner.parentPlanAssetID
            && locator.parentPlanNodePath == owner.parentPlanNodePath
            && locator.parentPlanNodeName == owner.parentPlanNodeName
            && locator.parentResultNodeType == owner.parentResultNodeType
            && locator.parentResultAssetID.map { SourceFilePaths.canonical(URL(fileURLWithPath: $0)) }
                == owner.parentResultAssetID.map { SourceFilePaths.canonical(URL(fileURLWithPath: $0)) }
            && locator.parentResultNodePath == owner.parentResultNodePath
            && locator.parentResultNodeName == owner.parentResultNodeName
            && locator.parentResultRevision == owner.parentResultRevision
    }

    /// Geometry requests are debounced while the user pans. The first metadata
    /// reply establishes source bounds; viewport paging starts only after that.
    func updateViewport(_ newValue: ViewportRequest?) async {
        let next = newValue.flatMap(MapGeometryViewport.init(extent:))
        guard next?.identity != viewport?.identity,
              sources.contains(where: { $0.snapshot != nil }) else { return }
        viewportTask?.cancel()
        viewportTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(160)) }
            catch { return }
            guard let self, !Task.isCancelled, self.isConfigured else { return }
            self.viewportTask = nil
            self.reload(viewport: next, force: false)
        }
    }

    func pausePaging() {
        guard isLoading || hasIncompletePages || sources.contains(where: { $0.snapshot == nil }) else { return }
        isPaused = true
    }

    func resumePaging() {
        guard isConfigured else { return }
        isPaused = false
        // If a debounced pan/zoom is pending, let that reload start the new
        // viewport instead of briefly requesting pages for the old one.
        guard viewportTask == nil, !isLoading, canContinuePaging else { return }
        startPaging(clearTokens: false)
    }

    func resumeInterruptedPaging() {
        guard isConfigured, !isPaused, !isLoading, viewportTask == nil, canContinuePaging else { return }
        startPaging(clearTokens: false)
    }

    /// The former Load Next action is now a pause/resume control around the
    /// automatic page drain; retry resumes from the retained source cursor.
    func loadNextPage() async {
        togglePaging()
    }

    func togglePaging() {
        if isPaused || !isLoading { resumePaging() } else { pausePaging() }
    }

    private func reload(viewport newViewport: MapGeometryViewport?, force: Bool) {
        guard isConfigured else { return }
        let preservePause = isPaused && !force
        // A response for the previous viewport must not install after this
        // reload. In paused mode this cancels the task without starting its
        // replacement until the user explicitly continues.
        cancel()
        let previousCameraBounds = cameraBoundsIdentity
        viewport = newViewport
        for index in sources.indices { clearPages(at: index, clearToken: force) }
        selection = nil
        error = nil
        renderRevision &+= 1
        if previousCameraBounds != cameraBoundsIdentity { cameraExtentRevision &+= 1 }
        isPaused = preservePause
        if !isPaused { startPaging(clearTokens: force) }
    }

    private func clearPages(at index: Int, clearToken: Bool) {
        let oldSnapshot = sources[index].snapshot
        sources[index].topologyFeatures = []
        sources[index].cells = []
        sources[index].culvertFeatures = []
        sources[index].topologyProgress = ProjectGeometryMapPageProgress()
        sources[index].cellsProgress = ProjectGeometryMapPageProgress()
        sources[index].culvertsProgress = ProjectGeometryMapPageProgress()
        sources[index].viewportIdentity = viewport?.identity ?? "full-source"
        sources[index].error = nil
        if clearToken {
            sources[index].snapshot = nil
            sources[index].topologyExtent = nil
            sources[index].flowAreasExtent = nil
            sources[index].culvertsExtent = nil
            sources[index].culvertDraftPresentation = nil
        } else {
            sources[index].snapshot = oldSnapshot
        }
    }

    private func startPaging(clearTokens: Bool) {
        guard let map, let provider, let isCurrent,
              isCurrent(), isConfigured else {
            if isConfigured { error = ProjectGeometryMapError.staleContext.localizedDescription }
            return
        }
        activeTask?.cancel()
        generation &+= 1
        let capturedGeneration = generation
        let capturedIdentity = mapWorkflowIdentity
        let selectedViewport = viewport
        isLoading = true
        error = nil
        for index in sources.indices { sources[index].isLoading = true }
        activeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performAutomaticPaging(map: map, provider: provider, isCurrent: isCurrent,
                generation: capturedGeneration, identity: capturedIdentity,
                viewport: selectedViewport, clearTokens: clearTokens)
            guard self.generation == capturedGeneration else { return }
            self.activeTask = nil
            self.isLoading = false
            for index in self.sources.indices { self.sources[index].isLoading = false }
        }
    }

    private func performAutomaticPaging(map: MapTreeMapIdentity,
                                        provider: any ProjectGeometryMapProvider,
                                        isCurrent: @escaping @MainActor () -> Bool,
                                        generation capturedGeneration: UInt64,
                                        identity capturedIdentity: String?,
                                        viewport selectedViewport: MapGeometryViewport?,
                                        clearTokens: Bool) async {
        for sourceIndex in sources.indices {
            while true {
                guard shouldContinue(generation: capturedGeneration, identity: capturedIdentity,
                                     isCurrent: isCurrent) else { return }
                let source = sources[sourceIndex]
                let hasSnapshot = source.snapshot != nil
                let request = MapGeometryRequest(
                    map: map, geometryNode: source.capture.geometryNode, viewport: selectedViewport,
                    contextToken: clearTokens && !hasSnapshot ? nil : source.contextToken,
                    planNodes: source.capture.planNodes,
                    topologyCursor: source.topologyProgress.nextCursor,
                    cellCursor: source.cellsProgress.nextCursor,
                    culvertCursor: source.culvertsProgress.nextCursor,
                    skipTopologyPage: hasSnapshot && skipPage(
                        source.snapshot?.topologyState, progress: source.topologyProgress),
                    skipFlowAreasPage: hasSnapshot && (source.flowAreaGenerationPresentation != nil
                        || skipPage(source.snapshot?.flowAreasState, progress: source.cellsProgress,
                            forceVisible: source.flowAreaVisibilityOverrideLocatorIdentity != nil)),
                    skipCulvertsPage: hasSnapshot && skipPage(
                        source.snapshot?.culvertsState, progress: source.culvertsProgress))
                do {
                    let response = try await provider.load(request, capture: source.capture)
                    guard shouldContinue(generation: capturedGeneration, identity: capturedIdentity,
                                         isCurrent: isCurrent), sources.indices.contains(sourceIndex),
                          sources[sourceIndex].id == source.id else { return }
                    install(response, at: sourceIndex, viewport: selectedViewport)
                } catch is CancellationError {
                    return
                } catch {
                    guard shouldContinue(generation: capturedGeneration, identity: capturedIdentity,
                                         isCurrent: isCurrent) else { return }
                    sources[sourceIndex].error = error.localizedDescription
                    // Retain a partial snapshot and its cursor so Retry resumes
                    // from the exact page that failed.
                    break
                }
                guard !isPaused else { break }
                if !sources[sourceIndex].hasNextPage { break }
            }
        }
        guard generation == capturedGeneration else { return }
        renderRevision &+= 1
    }

    private func shouldContinue(generation capturedGeneration: UInt64, identity capturedIdentity: String?,
                                isCurrent: @MainActor () -> Bool) -> Bool {
        !Task.isCancelled && generation == capturedGeneration
            && mapWorkflowIdentity == capturedIdentity && isCurrent()
    }

    private func install(_ response: MapGeometrySnapshot, at index: Int,
                         viewport selectedViewport: MapGeometryViewport?) {
        let previousCameraBounds = cameraBoundsIdentity
        var source = sources[index]
        let viewportID = selectedViewport?.identity ?? "full-source"
        if source.viewportIdentity != viewportID {
            source.topologyFeatures = []
            source.cells = []
            source.culvertFeatures = []
            source.topologyProgress = ProjectGeometryMapPageProgress()
            source.cellsProgress = ProjectGeometryMapPageProgress()
            source.culvertsProgress = ProjectGeometryMapPageProgress()
        }
        source.viewportIdentity = viewportID
        source.error = nil
        source.snapshot = response
        if let culvertDraftPresentation = source.culvertDraftPresentation,
           (response.geometryRevision.caseInsensitiveCompare(culvertDraftPresentation.geometryRevision) != .orderedSame
            || !response.geometryEffectiveVisible || !response.culvertsState.effectiveVisible
            || !response.culvertsState.status.hasSourceData) {
            source.culvertDraftPresentation = nil
        }
        if let page = response.topology {
            source.topologyExtent = page.sourceExtent
            appendUnique(page.features, to: &source.topologyFeatures, identity: \.id)
            source.topologyProgress.sourceCount = page.sourceFeatureCount
            source.topologyProgress.scannedCount += page.scannedFeatureCount
            source.topologyProgress.returnedCount = source.topologyFeatures.count
            source.topologyProgress.invalidCount += page.invalidFeatureCount
            source.topologyProgress.complete = page.complete
            source.topologyProgress.nextCursor = page.nextCursor
        }
        if let page = response.flowAreas {
            source.flowAreasExtent = page.sourceExtent
            appendUnique(page.cells, to: &source.cells, identity: \.id)
            source.cellsProgress.sourceCount = page.sourceCellCount
            source.cellsProgress.scannedCount += page.scannedSourceCellCount
            source.cellsProgress.returnedCount = source.cells.count
            source.cellsProgress.invalidCount += page.invalidCellCount
            source.cellsProgress.complete = page.complete
            source.cellsProgress.nextCursor = page.nextCursor
        }
        if let page = response.culverts {
            source.culvertsExtent = page.sourceExtent
            appendUnique(page.features, to: &source.culvertFeatures, identity: \.id)
            source.culvertsProgress.sourceCount = page.sourceBarrelCount
            source.culvertsProgress.scannedCount += page.scannedSourceBarrelCount
            source.culvertsProgress.returnedCount = source.culvertFeatures.count
            source.culvertsProgress.invalidCount += page.invalidFeatureCount
            source.culvertsProgress.complete = page.complete
            source.culvertsProgress.nextCursor = page.nextCursor
        }
        sources[index] = source
        renderRevision &+= 1
        if previousCameraBounds != cameraBoundsIdentity { cameraExtentRevision &+= 1 }
    }

    private var cameraBoundsIdentity: String {
        func extentIdentity(_ extent: GeometryTopologyExtent?) -> String {
            guard let extent else { return "missing" }
            return [extent.minX, extent.minY, extent.maxX, extent.maxY]
                .map { String($0.bitPattern, radix: 16) }.joined(separator: ":")
        }
        return sources.map { source in
            guard let snapshot = source.snapshot, snapshot.geometryEffectiveVisible else { return "" }
            let flowAreasVisible = source.presentsFlowAreaData
            let values: [(String, Bool, GeometryTopologyExtent?)] = [
                ("topology", snapshot.topologyState.effectiveVisible && snapshot.topologyState.status.hasSourceData, source.topologyExtent),
                ("flow", flowAreasVisible,
                    source.presentedFlowAreaExtent),
                ("culvert", snapshot.culvertsState.effectiveVisible && snapshot.culvertsState.status.hasSourceData, source.culvertsExtent)
            ]
            return values.map { item in
                let (name, visible, extent) = item
                guard visible else { return name + ":hidden" }
                return name + ":" + extentIdentity(extent)
            }.joined(separator: "|")
        }.joined(separator: "||")
    }

    private func appendUnique<Value, ID: Hashable>(_ incoming: [Value], to existing: inout [Value],
                                                   identity: KeyPath<Value, ID>) {
        var seen = Set(existing.map { $0[keyPath: identity] })
        for value in incoming where seen.insert(value[keyPath: identity]).inserted { existing.append(value) }
    }

    private func skipPage(_ state: MapGeometryLayerState?,
                          progress: ProjectGeometryMapPageProgress,
                          forceVisible: Bool = false) -> Bool {
        guard let state else { return false }
        return progress.complete || (!state.effectiveVisible && !forceVisible) || !state.status.hasSourceData
    }
}
