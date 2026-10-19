import Combine
import Foundation

@MainActor
final class MapTreeMeshErrorSession: ObservableObject {
    @Published private(set) var context: MapTreeMeshErrorContext?
    @Published private(set) var snapshot: MapTreeMeshErrorSnapshot?
    @Published private(set) var isLoading = false
    @Published private(set) var isApplying = false
    @Published private(set) var error: String?
    @Published private(set) var overlaySnapshots: [MapTreeMeshErrorSnapshot] = []
    @Published private(set) var overlayErrors: [String: String] = [:]
    @Published private(set) var isLoadingOverlays = false
    @Published private(set) var sourceReadsSuspended = false
    @Published var selectedIssueID: String?

    private var provider: (any MapTreeMeshErrorProviding)?
    private var task: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var overlayContexts: [MapTreeMeshErrorContext] = []
    private var overlayProvider: (any MapTreeMeshErrorProviding)?
    private var overlayTasks: [MapTreeMeshErrorContext: Task<Void, Never>] = [:]
    private var overlayByContext: [MapTreeMeshErrorContext: MapTreeMeshErrorSnapshot] = [:]
    private var overlayGeneration: UInt64 = 0

    func configure(_ context: MapTreeMeshErrorContext,
                   provider: any MapTreeMeshErrorProviding) async {
        if self.context != context {
            task?.cancel()
            task = nil
            generation &+= 1
            self.context = context
            snapshot = overlayByContext[context]
            error = overlayErrors[context.stableIdentity]
            selectedIssueID = nil
        }
        self.provider = provider
        guard !sourceReadsSuspended else {
            isLoading = false
            return
        }
        guard snapshot == nil, task == nil else { return }
        if let overlayTask = overlayTasks[context] {
            isLoading = true
            await overlayTask.value
            if self.context == context {
                snapshot = overlayByContext[context]
                error = overlayErrors[context.stableIdentity]
                isLoading = false
            }
            return
        }
        await loadCurrent()
    }

    func configureOverlayContexts(_ contexts: [MapTreeMeshErrorContext],
                                  provider: any MapTreeMeshErrorProviding) {
        var seen = Set<MapTreeMeshErrorContext>()
        let unique = contexts.filter { seen.insert($0).inserted }
        if unique != overlayContexts {
            overlayGeneration &+= 1
            for task in overlayTasks.values { task.cancel() }
            overlayTasks.removeAll()
            overlayContexts = unique
            overlayByContext = overlayByContext.filter { unique.contains($0.key) }
            overlayErrors = overlayErrors.filter { key, _ in
                unique.contains(where: { $0.stableIdentity == key })
            }
        }
        overlayProvider = provider
        publishOverlaySnapshots()
        guard !sourceReadsSuspended else { return }

        let token = overlayGeneration
        for context in unique where overlayByContext[context] == nil && overlayTasks[context] == nil {
            overlayTasks[context] = Task { @MainActor [weak self, provider] in
                do {
                    let loaded = try await provider.load(context)
                    guard let self, self.overlayGeneration == token, !Task.isCancelled,
                          self.overlayContexts.contains(context) else { return }
                    self.overlayByContext[context] = loaded
                    self.overlayErrors[context.stableIdentity] = nil
                    self.publishOverlaySnapshots()
                    if self.context == context {
                        self.snapshot = loaded
                        self.error = nil
                        self.isLoading = false
                    }
                } catch is CancellationError {
                } catch {
                    guard let self, self.overlayGeneration == token, !Task.isCancelled,
                          self.overlayContexts.contains(context) else { return }
                    self.overlayErrors[context.stableIdentity] = L10n.text(error.localizedDescription)
                    if self.context == context {
                        self.error = self.overlayErrors[context.stableIdentity]
                        self.isLoading = false
                    }
                }
                if let self, self.overlayGeneration == token {
                    self.overlayTasks[context] = nil
                    self.isLoadingOverlays = !self.overlayTasks.isEmpty
                }
            }
        }
        isLoadingOverlays = !overlayTasks.isEmpty
    }

    /// Cancels in-flight geometry reads before a compute process acquires its
    /// writer lease. Completed diagnostics stay cached for their exact source
    /// contexts and remain available until those contexts change.
    func suspendSourceReads() {
        guard !sourceReadsSuspended else { return }
        sourceReadsSuspended = true

        generation &+= 1
        task?.cancel()
        task = nil
        isLoading = false

        overlayGeneration &+= 1
        for task in overlayTasks.values { task.cancel() }
        overlayTasks.removeAll()
        isLoadingOverlays = false
        publishOverlaySnapshots()
    }

    /// Resumes reads after the writer lease ends, using the latest source rows.
    func resumeSourceReads() {
        guard sourceReadsSuspended else { return }
        sourceReadsSuspended = false
        if let overlayProvider {
            configureOverlayContexts(overlayContexts, provider: overlayProvider)
        }
        if snapshot == nil, let context, let provider {
            Task { @MainActor [weak self] in await self?.configure(context, provider: provider) }
        }
    }

    func refresh() async { await loadCurrent(force: true) }

    func setCheckMeshErrors(_ value: Bool) async {
        await apply(checkMeshErrors: value, maxFacesPerNodeEntry: nil)
    }

    func setMaxFacesPerNode(_ value: Int) async {
        await apply(checkMeshErrors: nil, maxFacesPerNodeEntry: Double(min(max(value, 3), 64)))
    }

    func selectIssue(_ issue: MapTreeMeshErrorIssue?) {
        selectedIssueID = issue?.id
    }

    func invalidate() { clear() }

    func clear() {
        task?.cancel()
        task = nil
        generation &+= 1
        clearOverlayContexts()
        context = nil
        snapshot = nil
        error = nil
        selectedIssueID = nil
        isLoading = false
        isApplying = false
        sourceReadsSuspended = false
    }

    func clearOverlayContexts() {
        overlayGeneration &+= 1
        for task in overlayTasks.values { task.cancel() }
        overlayTasks.removeAll()
        overlayContexts = []
        overlayProvider = nil
        overlayByContext.removeAll()
        overlayErrors.removeAll()
        overlaySnapshots = []
        isLoadingOverlays = false
    }

    private func publishOverlaySnapshots() {
        overlaySnapshots = overlayContexts.compactMap { overlayByContext[$0] }
        isLoadingOverlays = !overlayTasks.isEmpty
    }

    private func loadCurrent(force: Bool = false) async {
        guard !sourceReadsSuspended, let context, let provider, !isApplying else { return }
        if !force, snapshot != nil { return }
        task?.cancel()
        task = nil
        generation &+= 1
        let token = generation
        isLoading = true
        error = nil
        task = Task { @MainActor [weak self] in
            do {
                let loaded = try await provider.load(context)
                guard let self, self.generation == token, !Task.isCancelled,
                      self.context == context else { return }
                self.snapshot = loaded
                if self.overlayContexts.contains(context) {
                    self.overlayByContext[context] = loaded
                    self.overlayErrors[context.stableIdentity] = nil
                    self.publishOverlaySnapshots()
                }
            } catch is CancellationError {
            } catch {
                guard let self, self.generation == token else { return }
                self.error = L10n.text(error.localizedDescription)
            }
            if let self, self.generation == token {
                self.task = nil
                self.isLoading = false
            }
        }
        await task?.value
    }

    private func apply(checkMeshErrors: Bool?, maxFacesPerNodeEntry: Double?) async {
        guard !sourceReadsSuspended, let context, let provider, !isLoading, !isApplying else { return }
        task?.cancel()
        task = nil
        generation &+= 1
        let token = generation
        isApplying = true
        error = nil
        defer {
            if generation == token { isApplying = false }
        }
        do {
            let (updatedContext, updatedSnapshot) = try await provider.set(context,
                checkMeshErrors: checkMeshErrors,
                maxFacesPerNodeEntry: maxFacesPerNodeEntry)
            guard generation == token, !Task.isCancelled, self.context == context else { return }
            self.context = updatedContext
            snapshot = updatedSnapshot
            selectedIssueID = nil
            // The .vis receipt changes the saved map revision. Retire old map
            // snapshots immediately; the Store reconfigures these exact rows
            // against the accepted revision and repopulates their overlays.
            clearOverlayContexts()
        } catch is CancellationError {
        } catch {
            guard generation == token else { return }
            self.error = L10n.text(error.localizedDescription)
        }
    }
}

@MainActor
extension WorkspaceStore {
    func mapTreeMeshErrorProvider(for mapState: MapState) -> any MapTreeMeshErrorProviding {
        let savedSource = BackendMapTreeMeshErrorProvider(
            isCurrent: { [weak self, weak mapState] context in
                guard let self, let mapState else { return false }
                return self.isCurrentMapTreeMeshErrorContext(context, mapState: mapState)
            },
            currentMap: { [weak self] mapID in self?.mapIdentityRequest(for: mapID) },
            currentLease: { [weak self] in self?.mapResultComputeReadLease },
            beginMutation: { [weak self] context in
                self?.beginMapMeshErrorMutation(mapID: context.mapID,
                    projectSessionID: context.projectSessionID,
                    workflowIdentity: context.mapWorkflowIdentity) ?? false
            },
            endMutation: { [weak self] in self?.endMapMeshErrorMutation() },
            acceptMapChange: { [weak self] oldRevision, newRevision in
                guard let self else { throw MapTreeMeshErrorError.staleContext }
                try self.acceptAssociatedRasterStyleMapChange(oldRevision: oldRevision,
                    newRevision: newRevision)
            })
        return MapTreeMeshErrorDraftProvider(savedSource: savedSource) { [weak self, weak mapState] context, threshold in
            guard let self, let mapState,
                  let draftIdentity = context.geometryMeshDraftIdentity,
                  self.isCurrentMapTreeMeshErrorContext(context, mapState: mapState),
                  let source = mapState.projectGeometryMap.sources.first(where: {
                      $0.capture.projectSessionID == context.projectSessionID
                          && $0.capture.mapID == context.mapID
                          && $0.capture.geometryCanonicalPath == context.sourcePath
                          && $0.snapshot?.flowAreasState.locator == context.flowAreaNode
                  }),
                  source.flowAreaGenerationPresentation?.identity == draftIdentity,
                  source.flowAreaGenerationPresentation?.phase == .childDraft,
                  let mesh = self.geometryMeshSession(assetID: context.sourcePath,
                      projectSessionID: context.projectSessionID),
                  let resultIdentity = mesh.meshGenerationResultIdentity,
                  let meshSnapshot = mesh.snapshot,
                  mesh.geometryMapOverlaySourceRevision(for: context.sourcePath) == context.sourceRevision,
                  MapTreeMeshErrorDraftIdentity.presentationIdentity(
                      captureIdentity: source.capture.identity, sourceRevision: context.sourceRevision,
                      resultIdentity: resultIdentity, snapshot: meshSnapshot) == draftIdentity else {
                throw MapTreeMeshErrorError.staleContext
            }
            let scan = try await mesh.scanDegreeErrorsForMapOverlay(sourceRevision: context.sourceRevision,
                draftState: meshSnapshot.draftState, generationResultIdentity: resultIdentity,
                maxFacesPerNode: threshold)
            guard self.isCurrentMapTreeMeshErrorContext(context, mapState: mapState) else {
                throw MapTreeMeshErrorError.staleContext
            }
            let isVisible = source.snapshot?.geometryEffectiveVisible == true
                && source.presentsFlowAreaData
            return MapTreeMeshErrorDraftScanResult(scan: scan, mapVisible: isVisible)
        }
    }

    func configureMapMeshErrorOverlays(mapState: MapState,
                                       sources: [ProjectGeometryMapSourceState]) {
        guard existingMapState(for: mapState.id) === mapState,
              hasProject,
              mapWorkflowIdentity(mapState.id).isEmpty == false,
              !isOpeningProject, !isClosingTab, !isSavingAll else {
            mapState.meshErrors.clearOverlayContexts()
            return
        }
        // During compute, the exact host read lease filters every protected
        // path before Project.Load opens HDF. Other project tools have no such
        // proof, so they do not trigger map-layer diagnostics reads.
        if isRunningProjectTool && mapResultComputeReadLease == nil {
            mapState.meshErrors.clearOverlayContexts()
            return
        }
        if !isRunningPlanCompute {
            mapState.meshErrors.resumeSourceReads()
        }
        let workflow = mapWorkflowIdentity(mapState.id)
        let contexts = MapTreeMeshErrorContext.checkedVisibleContexts(in: sources).filter {
            $0.projectSessionID == projectSessionID && $0.mapID == mapState.id
                && $0.mapWorkflowIdentity == workflow
        }
        mapState.meshErrors.configureOverlayContexts(contexts,
            provider: mapTreeMeshErrorProvider(for: mapState))
    }

    private func isCurrentMapTreeMeshErrorContext(_ context: MapTreeMeshErrorContext,
                                                 mapState: MapState) -> Bool {
        guard projectSessionID == context.projectSessionID,
              existingMapState(for: context.mapID) === mapState,
              mapWorkflowIdentity(context.mapID) == context.mapWorkflowIdentity,
              let map = mapIdentityRequest(for: context.mapID),
              map == context.map else { return false }
        let matches = mapState.projectGeometryMap.sources.filter { source in
            guard source.capture.projectSessionID == context.projectSessionID,
                  source.capture.mapID == context.mapID,
                  source.capture.mapWorkflowIdentity == context.mapWorkflowIdentity,
                  source.capture.geometryCanonicalPath == context.sourcePath,
                  source.capture.resultOwner == context.resultOwner,
                  source.capture.geometryNode.rootName == context.flowAreaNode.rootName,
                  source.capture.geometryNode.nodeName == context.flowAreaNode.parentGeometryNodeName,
                  source.capture.geometryNode.nodePath == context.flowAreaNode.parentGeometryNodePath,
                  source.snapshot?.geometryRevision.caseInsensitiveCompare(context.sourceRevision) == .orderedSame,
                  source.snapshot?.contextToken == context.contextToken,
                  source.snapshot?.flowAreasState.locator == context.flowAreaNode else { return false }
            return true
        }
        guard matches.count == 1, let source = matches.first else { return false }
        if let draftIdentity = context.geometryMeshDraftIdentity {
            guard let presentation = source.flowAreaGenerationPresentation,
                  presentation.phase == .childDraft, presentation.identity == draftIdentity,
                  presentation.map != nil,
                  let mesh = geometryMeshSession(assetID: context.sourcePath,
                      projectSessionID: context.projectSessionID),
                  let resultIdentity = mesh.meshGenerationResultIdentity,
                  let meshSnapshot = mesh.snapshot,
                  mesh.geometryMapOverlaySourceRevision(for: context.sourcePath) == context.sourceRevision,
                  MapTreeMeshErrorDraftIdentity.presentationIdentity(
                      captureIdentity: source.capture.identity, sourceRevision: context.sourceRevision,
                      resultIdentity: resultIdentity, snapshot: meshSnapshot) == draftIdentity else { return false }
            return true
        }
        return source.flowAreaGenerationPresentation == nil
    }
}
