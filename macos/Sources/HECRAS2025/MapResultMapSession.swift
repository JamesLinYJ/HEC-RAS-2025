import Combine
import CryptoKit
import Foundation
import RASWorkspaceCore

struct MapResultMapNode: Identifiable {
    let id: String
    let name: String
    let kind: String
    let selectedMapType: String?
    let profileIndex: Int?
    let profileCount: Int
    let isLoading: Bool
    let isRefreshing: Bool
    let layerCount: Int
    let unavailableMessage: String?
    let liveComputeStatus: WorkspaceResultComputeStatus?
    let liveComputeFraction: Double?
    let liveProfileMetadataCount: Int
    let isLiveProfileMetadataOnly: Bool
}

struct MapResultMapLayer: Identifiable, Hashable {
    let id: String
    let name: String
}

struct MapResultMapAvailability {
    let reason: String?
    let sourceStatuses: [MapResultRenderSourceStatus]
}

/// One independent timeline/provider per active .vis result node. Frames are
/// only installed as a complete viewport generation, so a pan cannot combine
/// newly sampled layers with stale layers from another node.
@MainActor
final class MapResultMapSession: ObservableObject {
    typealias ViewportLookup = @MainActor () -> RasterMapViewExtent?
    typealias CurrentCheck = @MainActor () -> Bool
    typealias AvailabilityLookup = @MainActor () -> MapResultMapAvailability

    struct PreparedNode {
        let presentation: MapProfilePresentation
        let provider: any ProfileProvider
        let initialUpdate: MapUpdate?
        let initialLegends: [MapLegend]
        let initialUnavailableReason: String?
        let initialSourceStatuses: [MapResultRenderSourceStatus]
        let renderedViewport: RasterMapViewExtent?
        let availability: AvailabilityLookup
        let legendLookup: (@MainActor () -> [MapLegend]?)?
        let velocityFieldSampler: MapResultVelocityFieldSampler?

        init(presentation: MapProfilePresentation, provider: any ProfileProvider,
             initialUpdate: MapUpdate?, initialLegends: [MapLegend],
             initialUnavailableReason: String?,
             initialSourceStatuses: [MapResultRenderSourceStatus],
             renderedViewport: RasterMapViewExtent?,
             legendLookup: (@MainActor () -> [MapLegend]?)? = nil,
             availability: @escaping AvailabilityLookup,
             velocityFieldSampler: MapResultVelocityFieldSampler? = nil) {
            self.presentation = presentation
            self.provider = provider
            self.initialUpdate = initialUpdate
            self.initialLegends = initialLegends
            self.initialUnavailableReason = initialUnavailableReason
            self.initialSourceStatuses = initialSourceStatuses
            self.renderedViewport = renderedViewport
            self.legendLookup = legendLookup
            self.availability = availability
            self.velocityFieldSampler = velocityFieldSampler
        }
    }

    struct PreparationRequest {
        let snapshot: MapResultSourcesSnapshot
        let node: MapResultChartActiveNode
        let mapID: UUID
        let viewport: ViewportLookup
        let blockedSelectionIndices: Set<Int>
        let liveKeyframeTimeline: MapResultRenderLiveKeyframeTimeline?

        init(snapshot: MapResultSourcesSnapshot,
             node: MapResultChartActiveNode,
             mapID: UUID,
             viewport: @escaping ViewportLookup,
             blockedSelectionIndices: Set<Int> = [],
             liveKeyframeTimeline: MapResultRenderLiveKeyframeTimeline? = nil) {
            self.snapshot = snapshot
            self.node = node
            self.mapID = mapID
            self.viewport = viewport
            self.blockedSelectionIndices = blockedSelectionIndices
            self.liveKeyframeTimeline = liveKeyframeTimeline
        }
    }

    typealias NodePreparer = @MainActor (PreparationRequest) async throws -> PreparedNode

    @Published private(set) var nodes: [MapResultMapNode] = []
    @Published private(set) var selectedNodeID: String?
    @Published private(set) var selectedLayerID: String?
    @Published private(set) var isLoading = false
    @Published private(set) var isReloading = false
    @Published private(set) var errorMessage: String?
    let velocityParticles = MapResultVelocityParticleSession()

    var didUpdate: (@MainActor ([MapRasterLayer], [MapLegend]) -> Void)?
    var liveRenderTargetsDidChange: (@MainActor () -> Void)?
    /// Persists only a direct user profile change. Viewport re-renders reload
    /// the current profile without modifying the saved map's ProfileIndex.
    var didSelectPersistableProfile: (@MainActor (CatalogTreeNodeLocator, String?, Int) -> Void)?

    @MainActor
    private final class NodeRuntime {
        struct LiveVelocityFrameOrder: Comparable {
            let targetSequence: UInt64
            let profileIndex: Int
            static func < (lhs: Self, rhs: Self) -> Bool {
                lhs.targetSequence == rhs.targetSequence
                    ? lhs.profileIndex < rhs.profileIndex
                    : lhs.targetSequence < rhs.targetSequence
            }
        }

        struct LiveRasterPresentation {
            let frame: PlanComputeLiveMapFrame
            let layer: MapRasterLayer
            let legend: MapLegend
        }

        var source: MapResultChartActiveNode
        let profileSession = MapProfileSession()
        var subscription: AnyCancellable?
        var availability: AvailabilityLookup?
        var legendLookup: (@MainActor () -> [MapLegend]?)?
        var velocityFieldSampler: MapResultVelocityFieldSampler?
        var initialLayers: [MapRasterLayer] = []
        var layers: [MapRasterLayer] = []
        var rasterSelectionIndicesByLayerID: [String: [Int]]?
        var rasterSourceIdentityByLayerID: [String: MapRasterSourceIdentity]?
        var legends: [MapLegend] = []
        var sourceStatuses: [MapResultRenderSourceStatus] = []
        var unavailableReason: String?
        var selectedLayerID: String?
        var isLoading = true
        var isRefreshing = false
        var renderedViewport: RasterMapViewExtent?
        var liveComputeEntry: WorkspaceResultComputeEntry?
        var liveComputeCapture: WorkspaceResultComputeCapture?
        var liveProfileOutputBlockName: String?
        var selectedLiveProfileIndex: Int?
        var blockedLiveSelections: [Int: WorkspaceResultComputeEntry] = [:]
        var expectedStoredSelections: [Int: MapResultChartSourceChoice] = [:]
        var liveSelectionModesBySlot: [Int: MapResultSelectionMode] = [:]
        var liveProfileTimelinesBySlot: [Int: LiveMapResultProfileTimeline] = [:]
        var liveRastersBySelectionIndex: [Int: LiveRasterPresentation] = [:]
        var currentLiveTargetsByID: [String: PlanComputeLiveMapTarget] = [:]
        var lastLiveVelocityFrameOrderByTargetID: [String: LiveVelocityFrameOrder] = [:]
        var computeReadLease: MapResultComputeReadLease?
        var computeReadableDuringLease = false
        var computeProtectedSourcePaths: Set<String> = []
        var computeBlockedSelectionIndices: Set<Int> = []

        init(source: MapResultChartActiveNode) { self.source = source }

        var id: String { source.id }
        var hasLiveProfileRaster: Bool {
            guard let live = liveRastersBySelectionIndex[0] else { return false }
            return currentLiveTargetsByID[live.frame.targetID] != nil
        }
        var presentationLayers: [MapRasterLayer] {
            let storedLayers: [MapRasterLayer]
            let needsComputeFiltering = computeReadLease != nil
                || !computeProtectedSourcePaths.isEmpty
                || !computeBlockedSelectionIndices.isEmpty
            if rasterSelectionIndicesByLayerID == nil
                && blockedLiveSelections.isEmpty && expectedStoredSelections.isEmpty
                && !needsComputeFiltering {
                storedLayers = layers
            } else {
                storedLayers = layers.filter { layer in
                    if let identity = rasterSourceIdentityByLayerID?[layer.id],
                       computeProtectedSourcePaths.contains(
                            SourceFilePaths.canonical(URL(fileURLWithPath: identity.resultPath))) {
                        return false
                    }
                    guard let ownerIndices = rasterSelectionIndicesByLayerID?[layer.id],
                          !ownerIndices.isEmpty else { return false }
                    // A shared result selected by both a readable and a live
                    // slot remains displayable through its readable owner.
                    return ownerIndices.contains { index in
                        guard !computeBlockedSelectionIndices.contains(index) else { return false }
                        if blockedLiveSelections[index] != nil,
                           liveSelectionModesBySlot[index] != nil { return false }
                        guard let expected = expectedStoredSelections[index] else { return true }
                        guard let actual = rasterSourceIdentityByLayerID?[layer.id] else { return false }
                        return SourceFilePaths.canonical(URL(fileURLWithPath: actual.resultPath))
                                == SourceFilePaths.canonical(URL(fileURLWithPath: expected.resultPath))
                            && actual.revision.caseInsensitiveCompare(expected.revision) == .orderedSame
                    }
                }
            }
            let liveLayers = liveRastersBySelectionIndex.keys.sorted().compactMap { index -> MapRasterLayer? in
                guard let live = liveRastersBySelectionIndex[index],
                      currentLiveTargetsByID[live.frame.targetID] != nil else { return nil }
                return live.layer
            }
            return storedLayers + liveLayers
        }
        var presentationLegends: [MapLegend] {
            let presentIDs = Set(presentationLayers.map(\.id))
            let live = liveRastersBySelectionIndex.values
                .filter { currentLiveTargetsByID[$0.frame.targetID] != nil }
                .map(\.legend)
            var seen: Set<String> = []
            return (legends + live).filter { presentIDs.contains($0.id) && seen.insert($0.id).inserted }
        }
        var availabilityMessage: String? {
            if let error = profileSession.error { return error }
            let latest = availability?()
            let failures = (latest?.sourceStatuses ?? sourceStatuses)
                .filter { !$0.available }
                .compactMap { status -> String? in
                    guard let reason = status.unavailableReason, !reason.isEmpty else { return nil }
                    return status.resultName.isEmpty ? reason : "\(status.resultName): \(reason)"
                }
            if presentationLayers.isEmpty {
                if !blockedLiveSelections.isEmpty || !expectedStoredSelections.isEmpty {
                    return L10n.text("The selected Result has no readable map payload during this compute.")
                }
                if let reason = latest?.reason ?? unavailableReason, !reason.isEmpty { return reason }
                if !failures.isEmpty { return failures.joined(separator: "\n") }
                if !isLoading { return L10n.text("No result raster layers are available for this source.") }
            } else if !failures.isEmpty {
                return failures.joined(separator: "\n")
            }
            return nil
        }
    }

    private struct Frame {
        let layers: [MapRasterLayer]
        let rasterSelectionIndicesByLayerID: [String: [Int]]?
        let rasterSourceIdentityByLayerID: [String: MapRasterSourceIdentity]?
        let legends: [MapLegend]?
        let sourceStatuses: [MapResultRenderSourceStatus]
        let unavailableReason: String?
    }

    private var configuredSnapshot: MapResultSourcesSnapshot?
    private var profileProjectSessionID: UUID?
    private var ownerProjectSessionID: UUID?
    private var activeComputeCapture: WorkspaceResultComputeCapture?
    private var computeReadLease: MapResultComputeReadLease?
    private var computeReadIsCurrent: CurrentCheck?
    private var computeRefreshEntry: WorkspaceResultComputeEntry?
    private var computeReadableNodeIDs: Set<String> = []
    private var computeHistoricalRefreshTask: Task<Void, Never>?
    private var computeHistoricalRefreshGeneration = 0
    private var pendingLiveProfileSelections: [String: (entry: WorkspaceResultComputeEntry,
        capture: WorkspaceResultComputeCapture, outputBlockName: String,
        profileIndex: Int, mapID: UUID)] = [:]
    private(set) var isSourceReadsSuspended = false
    private var viewportLookup: ViewportLookup?
    private var currentCheck: CurrentCheck?
    private var windVelocitySource: MapWindVelocityParticleSource?
    private var windVelocitySourceGeneration: Int?
    private var orderedNodeIDs: [String] = []
    private var runtimeByID: [String: NodeRuntime] = [:]
    private var sourceGeneration = 0
    private var viewportGeneration = 0
    private var requestedViewport: RasterMapViewExtent?
    private var appliedViewport: RasterMapViewExtent?
    private var activeViewportGeneration: Int?
    private var pendingInitialViewportRefresh = false
    private var stagedFrames: [String: Frame] = [:]
    private var sourceTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var refreshTaskID = 0
    private let prepareNode: NodePreparer
    private typealias WindFieldSampler = @MainActor
        (MapWindVelocityParticleSource, String, Int, String?, RasterMapViewExtent) async throws -> MapResultVelocityGrid
    private let sampleWindVelocityField: WindFieldSampler

    init(client: BackendProcessClient? = nil) {
        let windProvider = BackendMapWindVelocityFieldProvider(client: client)
        sampleWindVelocityField = { source, requestID, profileIndex, profileTime, viewport in
            try await windProvider.sample(source: source, requestID: requestID,
                profileIndex: profileIndex, viewport: viewport,
                expectedProfileTime: profileTime)
        }
        prepareNode = { request in
            let prepared = try await BackendMapResultRenderProvider.prepare(
                client: client, map: request.snapshot.map,
                selectionOverrides: request.snapshot.selectionOverrides,
                sources: request.snapshot.sources, node: request.node, mapID: request.mapID,
                viewport: request.viewport,
                blockedSelectionIndices: request.blockedSelectionIndices,
                liveKeyframeTimeline: request.liveKeyframeTimeline)
            return PreparedNode(
                presentation: prepared.presentation,
                provider: prepared.provider,
                initialUpdate: prepared.initialUpdate,
                initialLegends: Self.makeLegends(from: prepared.initial),
                initialUnavailableReason: prepared.provider.availabilityReason,
                initialSourceStatuses: prepared.provider.sourceStatuses,
                renderedViewport: prepared.renderedViewport,
                legendLookup: { prepared.provider.currentLegends },
                availability: {
                    MapResultMapAvailability(
                        reason: prepared.provider.availabilityReason,
                        sourceStatuses: prepared.provider.sourceStatuses)
                },
                velocityFieldSampler: { requestID, profileIndex, _, viewport in
                    try await prepared.provider.sampleVelocityField(requestID: requestID,
                        profileIndex: profileIndex, viewport: viewport)
                })
        }
        velocityParticles.targetConfigurationDidChange = { [weak self] in
            guard let self else { return }
            self.refreshVelocityParticles()
            self.liveRenderTargetsDidChange?()
        }
    }

    init(prepareNode: @escaping NodePreparer) {
        let windProvider = BackendMapWindVelocityFieldProvider()
        sampleWindVelocityField = { source, requestID, profileIndex, profileTime, viewport in
            try await windProvider.sample(source: source, requestID: requestID,
                profileIndex: profileIndex, viewport: viewport,
                expectedProfileTime: profileTime)
        }
        self.prepareNode = prepareNode
        velocityParticles.targetConfigurationDidChange = { [weak self] in
            guard let self else { return }
            self.refreshVelocityParticles()
            self.liveRenderTargetsDidChange?()
        }
    }

    var selectedTimeline: MapProfileSession? {
        selectedNodeID.flatMap { runtimeByID[$0]?.profileSession }
    }

    var selectedNode: MapResultMapNode? {
        selectedNodeID.flatMap { id in nodes.first { $0.id == id } }
    }

    var selectedLayers: [MapResultMapLayer] {
        guard let selectedNodeID, let runtime = runtimeByID[selectedNodeID] else { return [] }
        return runtime.presentationLayers.map { MapResultMapLayer(id: $0.id, name: $0.name) }
    }

    var selectedLegend: MapLegend? {
        guard let selectedNodeID, let runtime = runtimeByID[selectedNodeID],
              let selectedLayerID,
              runtime.presentationLayers.contains(where: { $0.id == selectedLayerID }) else { return nil }
        return runtime.presentationLegends.first { $0.id == selectedLayerID }
    }

    var unavailableMessage: String? {
        if let errorMessage { return errorMessage }
        guard let selectedNodeID else {
            return configuredSnapshot == nil || !nodes.isEmpty
                ? nil : L10n.text("No active Result map nodes are available.")
        }
        return runtimeByID[selectedNodeID]?.availabilityMessage
    }

    var resultLayers: [MapRasterLayer] {
        orderedNodeIDs.compactMap { runtimeByID[$0] }.flatMap(\.presentationLayers)
    }

    var resultLegends: [MapLegend] {
        let presentIDs = Set(resultLayers.map(\.id))
        return orderedNodeIDs.compactMap { runtimeByID[$0] }
            .flatMap(\.presentationLegends).filter { presentIDs.contains($0.id) }
    }

    /// Returns only the raster payload owned by this exact source-tree row.
    /// The same map can contain several Result/MultiResult nodes; callers must
    /// not use the selected node's arrays for a different row.
    func layers(for locator: CatalogTreeNodeLocator) -> [MapRasterLayer] {
        orderedNodeIDs.compactMap { runtimeByID[$0] }
            .filter { $0.source.node == locator }
            .flatMap(\.presentationLayers)
    }

    func legends(for locator: CatalogTreeNodeLocator) -> [MapLegend] {
        let layers = layers(for: locator)
        let layerIDs = Set(layers.map(\.id))
        return orderedNodeIDs.compactMap { runtimeByID[$0] }
            .filter { $0.source.node == locator }
            .flatMap(\.presentationLegends)
            .filter { layerIDs.contains($0.id) }
    }

    /// Returns diagnostics for exactly one active source-tree Result row.
    /// Duplicate locators are ambiguous and therefore have no property view.
    func availability(for locator: CatalogTreeNodeLocator) -> MapResultMapAvailability? {
        let matches = orderedNodeIDs.compactMap { runtimeByID[$0] }
            .filter { $0.source.node == locator }
        guard matches.count == 1, let runtime = matches.first else { return nil }
        let latest = runtime.availability?()
        return MapResultMapAvailability(
            reason: latest?.reason ?? runtime.unavailableReason,
            sourceStatuses: latest?.sourceStatuses ?? runtime.sourceStatuses)
    }

    func configure(snapshot: MapResultSourcesSnapshot,
                   projectSessionID: UUID? = nil,
                   viewport: @escaping ViewportLookup,
                   isCurrent: @escaping CurrentCheck) {
        guard !(isSourceReadsSuspended && activeComputeCapture != nil) else { return }
        guard isCurrent() else { invalidate(); return }
        viewportLookup = viewport
        currentCheck = isCurrent
        ownerProjectSessionID = projectSessionID
            ?? Self.contextID(for: snapshot.identity)
        guard configuredSnapshot != snapshot else {
            if isSourceReadsSuspended && activeComputeCapture == nil { resumeSourceReads() }
            viewportChanged()
            return
        }
        beginConfiguration(snapshot)
        liveRenderTargetsDidChange?()
    }

    func beginPlanCompute(_ capture: WorkspaceResultComputeCapture) {
        guard ownerProjectSessionID == nil || ownerProjectSessionID == capture.projectSessionID else { return }
        computeHistoricalRefreshTask?.cancel()
        computeHistoricalRefreshTask = nil
        computeHistoricalRefreshGeneration &+= 1
        computeReadLease = nil
        computeReadIsCurrent = nil
        computeRefreshEntry = nil
        computeReadableNodeIDs = []
        activeComputeCapture = capture
        suspendSourceReads()
        velocityParticles.invalidate(unavailableMessage: "Result velocity sampling is paused during plan compute.")
        for runtime in runtimeByID.values where runtime.liveComputeEntry != nil
            || runtime.profileSession.isMetadataOnly {
            runtime.liveComputeEntry = nil
            runtime.liveComputeCapture = nil
            runtime.liveProfileOutputBlockName = nil
            runtime.selectedLiveProfileIndex = nil
            runtime.profileSession.invalidate()
            runtime.unavailableReason = L10n.text("Waiting for the active Result output to become available.")
        }
        pendingLiveProfileSelections = [:]
        refreshPublishedNodes()
        liveRenderTargetsDidChange?()
    }

    func endPlanCompute(_ capture: WorkspaceResultComputeCapture) {
        guard activeComputeCapture == capture else { return }
        computeHistoricalRefreshTask?.cancel()
        computeHistoricalRefreshTask = nil
        computeHistoricalRefreshGeneration &+= 1
        computeReadLease = nil
        computeReadIsCurrent = nil
        computeRefreshEntry = nil
        computeReadableNodeIDs = []
        activeComputeCapture = nil
        for runtime in runtimeByID.values where runtime.computeReadLease != nil {
            runtime.profileSession.suspendSourceReads()
            runtime.computeReadableDuringLease = false
        }
        resumeSourceReads()
        liveRenderTargetsDidChange?()
    }

    /// Installs only the historical Result nodes whose exact source paths do
    /// not intersect the active writer lease. The existing runtimes, logical
    /// slots, and writer-owned live frames stay in place.
    @discardableResult
    func refreshHistoricalResultsDuringCompute(
        snapshot: MapResultSourcesSnapshot,
        capture: WorkspaceResultComputeCapture,
        entry: WorkspaceResultComputeEntry,
        lease: MapResultComputeReadLease,
        isCurrent: @escaping CurrentCheck
    ) async -> Bool {
        guard isSourceReadsSuspended,
              activeComputeCapture == capture,
              ownerProjectSessionID == capture.projectSessionID,
              profileProjectSessionID == capture.projectSessionID,
              let snapshotMapID = UUID(uuidString: snapshot.map.mapID),
              LiveMapResultRunIdentity(entry: entry).matches(capture),
              lease.validates(map: snapshot.map, capture: capture, entry: entry),
              snapshot.map.computeReadLease == lease,
              snapshot.sources.mapID == snapshot.map.mapID,
              snapshot.sources.contextToken.isEmpty == false,
              Self.samePath(snapshot.sources.projectPath, capture.projectPath),
              Self.sameDigest(snapshot.sources.projectRevision, capture.projectRevision),
              Self.sameDigest(snapshot.sources.projectXmlSHA, capture.projectXmlFingerprint),
              isCurrent() else { return false }

        let liveProfileTimelineChanged = computeRefreshEntry?.profileTimeline != entry.profileTimeline
        if computeReadLease == lease, configuredSnapshot == snapshot,
           computeReadIsCurrent?() == true,
           requestedViewport == viewportLookup?(),
           !liveProfileTimelineChanged {
            computeRefreshEntry = entry
            return true
        }

        computeHistoricalRefreshTask?.cancel()
        computeHistoricalRefreshTask = nil
        computeHistoricalRefreshGeneration &+= 1
        let generation = computeHistoricalRefreshGeneration
        computeReadLease = lease
        computeReadIsCurrent = isCurrent
        computeRefreshEntry = entry
        configuredSnapshot = snapshot
        currentCheck = isCurrent
        let protected = lease.canonicalProtectedSourcePaths
        let nodeByID = Dictionary(uniqueKeysWithValues: snapshot.sources.activeNodes.map { ($0.id, $0) })
        var readableIDs: Set<String> = []

        for runtime in runtimeByID.values {
            runtime.computeReadLease = lease
            runtime.computeProtectedSourcePaths = protected
            runtime.computeReadableDuringLease = false
            runtime.profileSession.suspendSourceReads()
            runtime.isLoading = false
            runtime.isRefreshing = false
            guard let source = nodeByID[runtime.id], source.node == runtime.source.node,
                  source.nodeKind == runtime.source.nodeKind else {
                runtime.computeBlockedSelectionIndices.formUnion(
                    runtime.rasterSelectionIndicesByLayerID?.values.flatMap { $0 } ?? [])
                continue
            }
            runtime.source = source
            let readableSelectionIndices = updateComputeSelectionExpectations(
                runtime: runtime, source: source, protectedPaths: protected)
            let requestedPaths = computeSourcePaths(for: source, runtime: runtime,
                readableSelectionIndices: readableSelectionIndices)
            guard !readableSelectionIndices.isEmpty,
                  !requestedPaths.isEmpty,
                  requestedPaths.isDisjoint(with: protected) else {
                runtime.computeBlockedSelectionIndices.formUnion(
                    source.selections.map(\.selectionIndex))
                runtime.unavailableReason = L10n.text("The selected Result has no readable map payload during this compute.")
                continue
            }
            runtime.computeReadableDuringLease = true
            readableIDs.insert(runtime.id)
        }
        computeReadableNodeIDs = readableIDs
        ensureSelectedLayerForAllNodes()
        if let selectedNodeID { selectedLayerID = runtimeByID[selectedNodeID]?.selectedLayerID }
        refreshPublishedNodes()
        publishFrames()
        liveRenderTargetsDidChange?()

        guard !readableIDs.isEmpty else { return true }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.prepareHistoricalNodesDuringCompute(snapshot: snapshot, mapID: snapshotMapID,
                capture: capture, entry: entry, lease: lease,
                generation: generation, nodeIDs: readableIDs)
        }
        computeHistoricalRefreshTask = task
        await task.value
        return generation == computeHistoricalRefreshGeneration
            && computeReadLease == lease && configuredSnapshot == snapshot
            && computeReadIsCurrent?() == true && isCurrent()
    }

    func suspendSourceReads() {
        guard !isSourceReadsSuspended else { return }
        isSourceReadsSuspended = true
        velocityParticles.invalidate(unavailableMessage: "Result velocity sampling is paused during plan compute.")
        sourceGeneration &+= 1
        sourceTask?.cancel(); sourceTask = nil
        refreshTask?.cancel(); refreshTask = nil
        refreshTaskID &+= 1
        activeViewportGeneration = nil
        stagedFrames = [:]
        pendingInitialViewportRefresh = false
        isLoading = false
        isReloading = false
        for runtime in runtimeByID.values {
            runtime.isLoading = false
            runtime.isRefreshing = false
            runtime.profileSession.suspendSourceReads()
        }
        refreshPublishedNodes()
        liveRenderTargetsDidChange?()
    }

    func resumeSourceReads() {
        guard isSourceReadsSuspended else { return }
        isSourceReadsSuspended = false
        let mapID = configuredSnapshot.flatMap { UUID(uuidString: $0.map.mapID) }
        for runtime in runtimeByID.values {
            if runtime.computeReadLease != nil {
                runtime.profileSession.suspendSourceReads()
                continue
            }
            if let mapID {
                bindRenderCallbacks(runtime: runtime, generation: sourceGeneration, mapID: mapID)
            }
            runtime.profileSession.resumeSourceReads()
        }
        refreshPublishedNodes()
        refreshVelocityParticles()
    }

    func updateLiveComputeSelection(nodeID: String, selectionIndex: Int,
                                    selectionMode: MapResultSelectionMode = .latest,
                                    entry: WorkspaceResultComputeEntry?,
                                    timeline: LiveMapResultProfileTimeline?,
                                    selectedStoredChoice: MapResultChartSourceChoice? = nil) {
        guard let ownerProjectSessionID,
              let runtime = runtimeByID[nodeID],
              runtime.source.nodeKind == "MultiResult",
              ownerProjectSessionID == self.ownerProjectSessionID else { return }

        if selectionIndex > 0 {
            guard (0..<32).contains(selectionIndex) else { return }
            if let entry {
                let capture = activeComputeCapture ?? runtime.liveComputeCapture
                    ?? Self.capture(for: entry)
                guard ownerProjectSessionID == capture.projectSessionID,
                      LiveMapResultRunIdentity(entry: entry).matches(capture),
                      LiveMapResultSelectionProjection.nodeMatches(runtime.source,
                        projectSessionID: ownerProjectSessionID, capture: capture, entry: entry) else { return }
                runtime.liveComputeCapture = capture
                runtime.blockedLiveSelections[selectionIndex] = entry
                runtime.expectedStoredSelections.removeValue(forKey: selectionIndex)
                runtime.liveSelectionModesBySlot[selectionIndex] = selectionMode
                if let timeline { runtime.liveProfileTimelinesBySlot[selectionIndex] = timeline }
                runtime.liveRastersBySelectionIndex.removeValue(forKey: selectionIndex)
            } else {
                runtime.liveSelectionModesBySlot.removeValue(forKey: selectionIndex)
                runtime.liveProfileTimelinesBySlot.removeValue(forKey: selectionIndex)
                runtime.liveRastersBySelectionIndex.removeValue(forKey: selectionIndex)
                if let selectedStoredChoice {
                    runtime.blockedLiveSelections.removeValue(forKey: selectionIndex)
                    runtime.expectedStoredSelections[selectionIndex] = selectedStoredChoice
                } else {
                    runtime.blockedLiveSelections.removeValue(forKey: selectionIndex)
                    runtime.expectedStoredSelections.removeValue(forKey: selectionIndex)
                }
            }
            ensureSelectedLayer(runtime)
            if selectedNodeID == runtime.id { selectedLayerID = runtime.selectedLayerID }
            publishFrames()
            refreshPublishedNodes()
            liveRenderTargetsDidChange?()
            return
        }
        guard selectionIndex == 0 else { return }

        if let entry {
            guard let capture = activeComputeCapture ?? runtime.liveComputeCapture,
                  ownerProjectSessionID == capture.projectSessionID,
                  isSourceReadsSuspended || runtime.liveComputeEntry.map({
                    LiveMapResultRunIdentity(entry: $0) == LiveMapResultRunIdentity(entry: entry)
                  }) == true else { return }
            guard LiveMapResultRunIdentity(entry: entry).matches(capture),
                  LiveMapResultSelectionProjection.nodeMatches(runtime.source,
                    projectSessionID: ownerProjectSessionID, capture: capture, entry: entry) else { return }
            runtime.liveComputeCapture = capture
            runtime.blockedLiveSelections[0] = entry
            runtime.expectedStoredSelections.removeValue(forKey: 0)
            runtime.liveSelectionModesBySlot[0] = selectionMode
            if let timeline { runtime.liveProfileTimelinesBySlot[0] = timeline }
            installLiveMetadata(entry: entry, timeline: timeline, runtime: runtime)
            liveRenderTargetsDidChange?()
            return
        }

        guard runtime.liveComputeEntry != nil || isSourceReadsSuspended else { return }

        if let current = runtime.liveComputeEntry {
            // Keep the previous slot's cached raster masked until an exact
            // stored source frame is accepted. A deselection alone is not
            // evidence that the cached pixels belong to the newly selected
            // Result.
            runtime.blockedLiveSelections[0] = current
        }
        runtime.expectedStoredSelections[0] = selectedStoredChoice
        runtime.liveSelectionModesBySlot.removeValue(forKey: 0)
        runtime.liveProfileTimelinesBySlot.removeValue(forKey: 0)
        runtime.liveRastersBySelectionIndex.removeValue(forKey: 0)
        runtime.liveComputeEntry = nil
        runtime.liveComputeCapture = nil
        runtime.liveProfileOutputBlockName = nil
        runtime.selectedLiveProfileIndex = nil
        pendingLiveProfileSelections.removeValue(forKey: nodeID)
        installMetadataOnlyTimeline(runtime: runtime, entry: nil, outputBlock: nil, timeline: nil)
        runtime.unavailableReason = L10n.text("The selected Result has no readable map payload during this compute.")
        publishFrames()
        refreshPublishedNodes()
        liveRenderTargetsDidChange?()
    }

    /// Produces only the current MapState's exact source slots and viewport.
    /// WorkspaceStore combines these across maps before sending the target set
    /// to the compute-owned child process.
    func liveMapRenderTargets(capture: WorkspaceResultComputeCapture,
                              entry: WorkspaceResultComputeEntry) -> [PlanComputeLiveMapTarget] {
        var targets: [PlanComputeLiveMapTarget] = []
        let mapID = configuredSnapshot.flatMap { UUID(uuidString: $0.map.mapID) }
        let eligible = activeComputeCapture == capture
            && ownerProjectSessionID == capture.projectSessionID
            && profileProjectSessionID == capture.projectSessionID
            && LiveMapResultRunIdentity(entry: entry).matches(capture)
            && configuredSnapshot.map { snapshot in
                Self.samePath(snapshot.map.projectPath, capture.projectPath)
                    && Self.sameDigest(snapshot.sources.projectRevision, capture.projectRevision)
                    && Self.sameDigest(snapshot.map.projectXmlSHA, capture.projectXmlFingerprint)
                    && Self.sameDigest(snapshot.sources.projectXmlSHA, capture.projectXmlFingerprint)
                    && snapshot.sources.contextToken.isEmpty == false
            } == true
            && currentCheck?() == true
        let viewport = viewportLookup?()

        if eligible, let snapshot = configuredSnapshot, let mapID, let viewport,
           viewport.minX.isFinite, viewport.minY.isFinite, viewport.maxX.isFinite, viewport.maxY.isFinite,
           viewport.minX < viewport.maxX, viewport.minY < viewport.maxY,
           viewport.pixelWidth > 0, viewport.pixelHeight > 0 {
            for nodeID in orderedNodeIDs {
                guard let runtime = runtimeByID[nodeID], runtime.source.nodeKind == "MultiResult",
                      LiveMapResultSelectionProjection.nodeMatches(runtime.source,
                        projectSessionID: capture.projectSessionID, capture: capture, entry: entry),
                      let mapType = runtime.source.selectedMapType, !mapType.isEmpty else { continue }

                let selectedProfile = runtime.profileSession.currentID
                    ?? runtime.selectedLiveProfileIndex
                let keyProfileTime: String? = {
                    if let time = runtime.profileSession.currentStep?.sourceTime, !time.isEmpty { return time }
                    guard let selectedProfile,
                          let timeline = runtime.liveProfileTimelinesBySlot[0] ?? runtime.liveComputeEntry?.profileTimeline,
                          let blockName = runtime.liveProfileOutputBlockName,
                          let profile = timeline.outputBlocks[blockName]?.profilesByIndex[selectedProfile] else { return nil }
                    return profile.time
                }()

                var nodeTargets: [String: PlanComputeLiveMapTarget] = [:]
                let candidateIndices = Set(runtime.blockedLiveSelections.keys)
                for selectionIndex in candidateIndices.sorted() {
                    guard let selectedEntry = runtime.blockedLiveSelections[selectionIndex],
                          LiveMapResultRunIdentity(entry: selectedEntry) == LiveMapResultRunIdentity(entry: entry),
                          let mode = runtime.liveSelectionModesBySlot[selectionIndex],
                          mode == .latest || mode == .explicit,
                          let timeline = runtime.liveProfileTimelinesBySlot[selectionIndex] ?? selectedEntry.profileTimeline,
                          timeline.identity == LiveMapResultRunIdentity(entry: entry),
                          timeline.blocks.count == 1,
                          let block = timeline.blocks.first,
                          block.errorMessage == nil,
                          block.profileCount > 0,
                          let selectedProfile else { continue }

                    let profileIndex: Int
                    let profileTime: String
                    if selectionIndex == 0 {
                        profileIndex = selectedProfile
                        guard let profile = block.profilesByIndex[profileIndex] else { continue }
                        profileTime = profile.time
                    } else {
                        guard let keyProfileTime else { continue }
                        // The backend resolves nonzero slots by the exact
                        // slot-zero source timestamp, as KeyedProfileState does.
                        profileIndex = selectedProfile
                        profileTime = keyProfileTime
                    }
                    guard let profileName = block.profilesByIndex[profileIndex]?.name,
                          !profileName.isEmpty else { continue }

                    let capturesVelocityParticles = velocityParticles.settings.isEnabled
                        && selectedNodeID == runtime.id
                        && selectionIndex == 0
                        && mapType == "Velocity"

                    let targetID = Self.liveTargetID(projectSessionID: capture.projectSessionID,
                        operationOwnerToken: capture.operationOwnerToken,
                        operationContextID: capture.operationContextID, runID: entry.runID,
                        mapID: mapID, contextToken: snapshot.sources.contextToken,
                        nodeID: runtime.source.id, selectionIndex: selectionIndex,
                        profileIndex: profileIndex, profileTime: profileTime,
                        outputBlockName: block.name, mapType: mapType, viewport: viewport)
                    let target = PlanComputeLiveMapTarget(targetID: targetID,
                        projectSessionID: capture.projectSessionID.uuidString,
                        operationOwnerToken: capture.operationOwnerToken,
                        operationContextID: capture.operationContextID, runID: entry.runID,
                        projectPath: capture.projectPath, projectRevision: capture.projectRevision,
                        projectXmlFingerprint: capture.projectXmlFingerprint,
                        planPath: capture.planPath, planRevision: capture.planRevision,
                        map: snapshot.map, contextToken: snapshot.sources.contextToken,
                        nodeID: runtime.source.id, node: runtime.source.node,
                        selectionIndex: selectionIndex, selectionMode: mode.rawValue,
                        selectedResultPath: mode == .explicit ? entry.resultPath : nil,
                        profileIndex: profileIndex, profileTime: profileTime,
                        outputBlockName: block.name, selectedMapType: mapType, viewport: viewport,
                        captureVelocityParticles: capturesVelocityParticles,
                        profileName: profileName)
                    nodeTargets[targetID] = target
                    targets.append(target)
                }

            }
        }

        let targetIDsByNode = Dictionary(grouping: targets, by: \.nodeID).mapValues { values in
            Dictionary(uniqueKeysWithValues: values.map { ($0.targetID, $0) })
        }
        var presentationChanged = false
        var streamingVelocityIdentity: MapResultVelocityParticleTargetIdentity?
        for runtime in runtimeByID.values where runtime.source.nodeKind == "MultiResult" {
            let next = targetIDsByNode[runtime.source.id] ?? [:]
            if runtime.currentLiveTargetsByID != next {
                let previousFrameCount = runtime.liveRastersBySelectionIndex.count
                runtime.currentLiveTargetsByID = next
                runtime.liveRastersBySelectionIndex = runtime.liveRastersBySelectionIndex.filter {
                    next[$0.value.frame.targetID] != nil
                }
                runtime.lastLiveVelocityFrameOrderByTargetID = runtime.lastLiveVelocityFrameOrderByTargetID
                    .filter { next[$0.key]?.captureVelocityParticles == true }
                presentationChanged = presentationChanged
                    || previousFrameCount != runtime.liveRastersBySelectionIndex.count
            }
            if runtime.id == selectedNodeID,
               let target = next.values.first(where: { $0.captureVelocityParticles }),
               let targetMapID = UUID(uuidString: target.map.mapID),
               target.profileIndex >= 0, let time = target.profileTime, !time.isEmpty {
                streamingVelocityIdentity = MapResultVelocityParticleTargetIdentity(
                    sourceKind: .liveResult, targetID: target.targetID,
                    sourceGeneration: sourceGeneration,
                    projectSessionID: capture.projectSessionID,
                    mapID: targetMapID, contextToken: target.contextToken,
                    nodeID: target.nodeID, node: target.node,
                    resultPath: SourceFilePaths.canonical(URL(fileURLWithPath: entry.resultPath)),
                    resultRevision: nil, runID: entry.runID,
                    profileIndex: target.profileIndex,
                    profileName: target.profileName ?? "", time: time,
                    viewport: target.viewport)
            }
        }
        velocityParticles.setStreamingTarget(streamingVelocityIdentity)
        if presentationChanged {
            ensureSelectedLayerForAllNodes()
            if let selectedNodeID { selectedLayerID = runtimeByID[selectedNodeID]?.selectedLayerID }
            refreshPublishedNodes()
            publishFrames()
        }
        return targets
    }

    @discardableResult
    func acceptLiveMapFrame(_ frame: PlanComputeLiveMapFrame,
                            capture: WorkspaceResultComputeCapture,
                            entry: WorkspaceResultComputeEntry) -> Bool {
        guard activeComputeCapture == capture,
              ownerProjectSessionID == capture.projectSessionID,
              LiveMapResultRunIdentity(entry: entry).matches(capture),
              frame.projectSessionID == capture.projectSessionID.uuidString,
              frame.operationOwnerToken == capture.operationOwnerToken,
              frame.operationContextID == capture.operationContextID,
              frame.runID == entry.runID,
              currentCheck?() == true,
              Self.samePath(frame.resultPath, entry.resultPath),
              let mapID = UUID(uuidString: configuredSnapshot?.map.mapID ?? ""),
              frame.mapID.caseInsensitiveCompare(mapID.uuidString) == .orderedSame,
              let runtime = runtimeByID[frame.nodeID], runtime.source.nodeKind == "MultiResult",
              runtime.blockedLiveSelections[frame.selectionIndex].map({
                  LiveMapResultRunIdentity(entry: $0) == LiveMapResultRunIdentity(entry: entry)
              }) == true,
              let target = runtime.currentLiveTargetsByID[frame.targetID],
              target.nodeID == frame.nodeID,
              target.selectionIndex == frame.selectionIndex,
              target.runID == frame.runID,
              target.contextToken == frame.contextToken,
              target.outputBlockName == frame.outputBlockName,
              let targetProfileTime = target.profileTime,
              target.map.mapID.caseInsensitiveCompare(frame.mapID) == .orderedSame,
              target.viewport == viewportLookup?(),
              frame.profileIndex >= 0,
              frame.targetSequence > 0 else { return false }
        if frame.selectionIndex == 0 {
            guard frame.profileIndex == target.profileIndex,
                  targetProfileTime == frame.time else { return false }
        } else if !Self.sourceTimesMatchWithinKeyframeTolerance(frame.time, targetProfileTime) {
            return false
        }
        if let previous = runtime.liveRastersBySelectionIndex[frame.selectionIndex],
           previous.frame.targetID == frame.targetID,
           previous.frame.targetSequence >= frame.targetSequence { return false }
        do {
            let layer = try frame.makeLayer(expectedMapID: mapID)
            runtime.liveRastersBySelectionIndex[frame.selectionIndex] = .init(
                frame: frame, layer: layer, legend: frame.legend)
        } catch { return false }
        ensureSelectedLayer(runtime)
        if selectedNodeID == runtime.id { selectedLayerID = runtime.selectedLayerID }
        refreshPublishedNodes()
        publishFrames()
        return true
    }

    @discardableResult
    func acceptLiveVelocityFrame(_ frame: PlanComputeLiveVelocityFrame,
                                 capture: WorkspaceResultComputeCapture,
                                 entry: WorkspaceResultComputeEntry) -> Bool {
        guard activeComputeCapture == capture,
              ownerProjectSessionID == capture.projectSessionID,
              entry.status == .running,
              LiveMapResultRunIdentity(entry: entry).matches(capture),
              frame.projectSessionID == capture.projectSessionID.uuidString,
              frame.operationOwnerToken == capture.operationOwnerToken,
              frame.operationContextID == capture.operationContextID,
              frame.runID == entry.runID,
              currentCheck?() == true,
              Self.samePath(frame.resultPath, entry.resultPath),
              let snapshot = configuredSnapshot,
              let mapID = UUID(uuidString: snapshot.map.mapID),
              UUID(uuidString: frame.mapID) == mapID,
              targetMapContextMatches(snapshot.map, capture: capture),
              let runtime = runtimeByID[frame.nodeID],
              runtime.source.nodeKind == "MultiResult",
              selectedNodeID == runtime.id,
              runtime.source.selectedMapType == "Velocity",
              velocityParticles.settings.isEnabled,
              runtime.blockedLiveSelections[0].map({
                  LiveMapResultRunIdentity(entry: $0) == LiveMapResultRunIdentity(entry: entry)
              }) == true,
              let target = runtime.currentLiveTargetsByID[frame.targetID],
              target.captureVelocityParticles,
              target.node == runtime.source.node,
              target.nodeID == frame.nodeID,
              target.selectionIndex == 0, frame.selectionIndex == 0,
              target.runID == frame.runID,
              target.contextToken == frame.contextToken,
              target.outputBlockName == frame.outputBlockName,
              target.selectedMapType == "Velocity",
              let expectedTime = target.profileTime,
              target.profileIndex == frame.profileIndex,
              target.profileName == frame.profileName,
              expectedTime == frame.time,
              target.viewport == viewportLookup?(),
              target.map.mapID.caseInsensitiveCompare(frame.mapID) == .orderedSame,
              target.map == snapshot.map,
              frame.targetSequence > 0,
              runtime.liveProfileOutputBlockName == target.outputBlockName,
              let timeline = runtime.liveProfileTimelinesBySlot[0] ?? runtime.liveComputeEntry?.profileTimeline,
              timeline.identity == LiveMapResultRunIdentity(entry: entry),
              let profile = timeline.blocks.first(where: { $0.name == target.outputBlockName })?.profilesByIndex[frame.profileIndex],
              profile.name == frame.profileName,
              profile.time == frame.time else { return false }
        if let previous = runtime.lastLiveVelocityFrameOrderByTargetID[frame.targetID],
           previous >= NodeRuntime.LiveVelocityFrameOrder(
                targetSequence: frame.targetSequence, profileIndex: frame.profileIndex) { return false }
        let identity = MapResultVelocityParticleTargetIdentity(
            sourceKind: .liveResult, targetID: target.targetID,
            sourceGeneration: sourceGeneration, projectSessionID: capture.projectSessionID,
            mapID: mapID, contextToken: target.contextToken, nodeID: target.nodeID,
            node: target.node,
            resultPath: SourceFilePaths.canonical(URL(fileURLWithPath: entry.resultPath)),
            resultRevision: nil, runID: entry.runID, profileIndex: target.profileIndex,
            profileName: target.profileName ?? "", time: expectedTime,
            viewport: target.viewport)
        do {
            let grid = try frame.makeGrid(expected: identity,
                expectedResultPath: entry.resultPath,
                expectedOutputBlockName: target.outputBlockName)
            guard velocityParticles.installLiveGrid(grid, identity: identity) else { return false }
        } catch { return false }
        runtime.lastLiveVelocityFrameOrderByTargetID[frame.targetID] = .init(
            targetSequence: frame.targetSequence, profileIndex: frame.profileIndex)
        return true
    }

    @discardableResult
    func acceptLiveVelocityUnavailable(_ unavailable: PlanComputeLiveVelocityUnavailable,
                                      capture: WorkspaceResultComputeCapture,
                                      entry: WorkspaceResultComputeEntry) -> Bool {
        guard activeComputeCapture == capture,
              ownerProjectSessionID == capture.projectSessionID,
              entry.status == .running,
              LiveMapResultRunIdentity(entry: entry).matches(capture),
              unavailable.projectSessionID == capture.projectSessionID.uuidString,
              unavailable.operationOwnerToken == capture.operationOwnerToken,
              unavailable.operationContextID == capture.operationContextID,
              unavailable.runID == entry.runID,
              currentCheck?() == true,
              Self.samePath(unavailable.resultPath, entry.resultPath),
              let snapshot = configuredSnapshot,
              let mapID = UUID(uuidString: snapshot.map.mapID),
              UUID(uuidString: unavailable.mapID) == mapID,
              targetMapContextMatches(snapshot.map, capture: capture),
              let runtime = runtimeByID[unavailable.nodeID],
              runtime.source.nodeKind == "MultiResult", selectedNodeID == runtime.id,
              runtime.source.selectedMapType == "Velocity", velocityParticles.settings.isEnabled,
              runtime.blockedLiveSelections[0].map({
                  LiveMapResultRunIdentity(entry: $0) == LiveMapResultRunIdentity(entry: entry)
              }) == true,
              let target = runtime.currentLiveTargetsByID[unavailable.targetID],
              target.captureVelocityParticles, target.node == runtime.source.node,
              target.selectionIndex == 0, unavailable.selectionIndex == 0,
              target.runID == unavailable.runID, target.contextToken == unavailable.contextToken,
              target.outputBlockName == unavailable.outputBlockName,
              target.targetID == unavailable.targetID,
              target.map == snapshot.map,
              mapID.uuidString.caseInsensitiveCompare(unavailable.mapID) == .orderedSame,
              target.viewport == viewportLookup?(), target.profileIndex >= 0,
              unavailable.targetSequence > 0 else { return false }
        let order = NodeRuntime.LiveVelocityFrameOrder(
            targetSequence: unavailable.targetSequence, profileIndex: target.profileIndex)
        if let previous = runtime.lastLiveVelocityFrameOrderByTargetID[unavailable.targetID],
           previous >= order { return false }
        let identity = MapResultVelocityParticleTargetIdentity(
            sourceKind: .liveResult, targetID: target.targetID,
            sourceGeneration: sourceGeneration, projectSessionID: capture.projectSessionID,
            mapID: mapID, contextToken: target.contextToken, nodeID: target.nodeID,
            node: target.node,
            resultPath: SourceFilePaths.canonical(URL(fileURLWithPath: entry.resultPath)),
            resultRevision: nil, runID: entry.runID,
            profileIndex: target.profileIndex, profileName: target.profileName ?? "",
            time: target.profileTime ?? "", viewport: target.viewport)
        guard velocityParticles.installLiveUnavailable(unavailable.message, identity: identity) else {
            return false
        }
        runtime.lastLiveVelocityFrameOrderByTargetID[unavailable.targetID] = order
        return true
    }

    /// Called by the owning map state after extent, pan, zoom, or raster pixel
    /// dimensions change. Repeated calls coalesce into one latest generation.
    func viewportChanged() {
        guard configuredSnapshot != nil else { return }
        let nextViewport = viewportLookup?()
        guard nextViewport != requestedViewport else { return }
        requestedViewport = nextViewport
        viewportGeneration &+= 1
        refreshVelocityParticles()
        // Retire only live pixels. Stored nodes keep their last complete
        // viewport until every refreshed node is ready to publish atomically.
        var removedLiveFrame = false
        for runtime in runtimeByID.values {
            removedLiveFrame = removedLiveFrame || !runtime.liveRastersBySelectionIndex.isEmpty
            runtime.liveRastersBySelectionIndex = [:]
            runtime.currentLiveTargetsByID = [:]
        }
        if removedLiveFrame {
            ensureSelectedLayerForAllNodes()
            if let selectedNodeID { selectedLayerID = runtimeByID[selectedNodeID]?.selectedLayerID }
            refreshPublishedNodes()
            publishFrames()
        }
        liveRenderTargetsDidChange?()
        guard !isSourceReadsSuspended else {
            scheduleComputeHistoricalViewportRefresh()
            return
        }
        guard !isLoading else { return }
        startViewportRefresh()
    }

    private struct ComputeHistoricalPreparation {
        let runtime: NodeRuntime
        let source: MapResultChartActiveNode
        let prepared: PreparedNode
        let selectedProfileID: Int?
        let liveKeyframeTimeline: MapResultRenderLiveKeyframeTimeline?
    }

    private func scheduleComputeHistoricalViewportRefresh() {
        guard isSourceReadsSuspended,
              let capture = activeComputeCapture,
              let entry = computeRefreshEntry,
              let lease = computeReadLease,
              let snapshot = configuredSnapshot,
              let isCurrent = computeReadIsCurrent,
              !computeReadableNodeIDs.isEmpty,
              isCurrent() else { return }
        computeHistoricalRefreshTask?.cancel()
        computeHistoricalRefreshGeneration &+= 1
        let generation = computeHistoricalRefreshGeneration
        let nodeIDs = computeReadableNodeIDs
        let mapID = UUID(uuidString: snapshot.map.mapID)
        guard let mapID else { return }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.prepareHistoricalNodesDuringCompute(snapshot: snapshot, mapID: mapID,
                capture: capture, entry: entry, lease: lease,
                generation: generation, nodeIDs: nodeIDs)
        }
        computeHistoricalRefreshTask = task
    }

    private func prepareHistoricalNodesDuringCompute(
        snapshot: MapResultSourcesSnapshot,
        mapID: UUID,
        capture: WorkspaceResultComputeCapture,
        entry: WorkspaceResultComputeEntry,
        lease: MapResultComputeReadLease,
        generation: Int,
        nodeIDs: Set<String>
    ) async {
        let requestedViewport = viewportLookup?()
        let requestedViewportGeneration = viewportGeneration
        let sourcesByID = Dictionary(uniqueKeysWithValues: snapshot.sources.activeNodes.map { ($0.id, $0) })
        var staged: [ComputeHistoricalPreparation] = []
        var failures: [String: String] = [:]
        for nodeID in orderedNodeIDs where nodeIDs.contains(nodeID) {
            guard computeRefreshIsCurrent(generation: generation, capture: capture,
                entry: entry, lease: lease, snapshot: snapshot),
                  let runtime = runtimeByID[nodeID],
                  computeReadableNodeIDs.contains(nodeID),
                  let source = sourcesByID[nodeID], source.node == runtime.source.node else { return }
            runtime.isRefreshing = true
            let hasLiveKeyframeSlot = runtime.liveSelectionModesBySlot[0] != nil
                && runtime.blockedLiveSelections[0].map {
                    LiveMapResultRunIdentity(entry: $0) == LiveMapResultRunIdentity(entry: entry)
                } == true
            let selectedProfileID = hasLiveKeyframeSlot
                ? runtime.profileSession.currentID ?? runtime.selectedLiveProfileIndex
                : runtime.profileSession.currentID ?? runtime.source.profileIndex
            let liveKeyframeTimeline = hasLiveKeyframeSlot
                ? makeLiveKeyframeTimeline(runtime: runtime, entry: entry, lease: lease)
                : nil
            let requestedNode = MapResultChartActiveNode(node: source.node,
                nodeKind: source.nodeKind, name: source.name, selections: source.selections,
                selectedMapType: source.selectedMapType, profileIndex: selectedProfileID)
            do {
                let request = PreparationRequest(snapshot: snapshot, node: requestedNode,
                    mapID: mapID, viewport: viewportLookup ?? { nil },
                    blockedSelectionIndices: runtime.computeBlockedSelectionIndices,
                    liveKeyframeTimeline: liveKeyframeTimeline)
                let prepared = try await prepareNode(request)
                guard computeRefreshIsCurrent(generation: generation, capture: capture,
                    entry: entry, lease: lease, snapshot: snapshot), !Task.isCancelled else { return }
                staged.append(ComputeHistoricalPreparation(runtime: runtime, source: source,
                    prepared: prepared, selectedProfileID: selectedProfileID,
                    liveKeyframeTimeline: liveKeyframeTimeline))
            } catch {
                guard !Task.isCancelled else { return }
                failures[nodeID] = L10n.text(error.localizedDescription)
            }
        }

        guard computeRefreshIsCurrent(generation: generation, capture: capture,
                entry: entry, lease: lease, snapshot: snapshot), !Task.isCancelled else { return }
        guard viewportGeneration == requestedViewportGeneration,
              viewportLookup?() == requestedViewport else {
            for nodeID in nodeIDs {
                runtimeByID[nodeID]?.isRefreshing = false
            }
            refreshPublishedNodes()
            scheduleComputeHistoricalViewportRefresh()
            return
        }

        if failures.isEmpty, staged.count == nodeIDs.count {
            for item in staged {
                let runtime = item.runtime
                runtime.source = item.source
                runtime.availability = item.prepared.availability
                runtime.legendLookup = item.prepared.legendLookup
                runtime.velocityFieldSampler = item.prepared.velocityFieldSampler
                runtime.initialLayers = item.prepared.initialUpdate?.rasters ?? []
                runtime.layers = runtime.initialLayers
                runtime.rasterSelectionIndicesByLayerID = item.prepared.initialUpdate?.rasterSelectionIndicesByLayerID
                runtime.rasterSourceIdentityByLayerID = item.prepared.initialUpdate?.rasterSourceIdentityByLayerID
                runtime.legends = item.prepared.initialLegends
                runtime.sourceStatuses = item.prepared.initialSourceStatuses
                runtime.unavailableReason = item.prepared.initialUnavailableReason
                runtime.renderedViewport = item.prepared.renderedViewport
                if item.prepared.initialUpdate == nil && !item.prepared.initialLegends.isEmpty {
                    runtime.unavailableReason = L10n.text("The result renderer returned an invalid raster.")
                }
                bindRenderCallbacks(runtime: runtime, generation: sourceGeneration, mapID: mapID)
                let isLiveKeyframeNode = runtime.blockedLiveSelections[0].map {
                    LiveMapResultRunIdentity(entry: $0) == LiveMapResultRunIdentity(entry: entry)
                } == true
                if isLiveKeyframeNode {
                    runtime.profileSession.resumeSourceReads()
                    if let timeline = item.liveKeyframeTimeline,
                       let block = timeline.blocks.first,
                       timeline.blocks.count == 1 {
                        let context = MapProfileContext(projectSessionID: capture.projectSessionID,
                            mapID: mapID, sourceID: liveProfileSourceID(entry: entry,
                                outputBlockName: block.name))
                        if !runtime.profileSession.attachProviderToMetadataOnlyTimeline(
                            item.prepared.provider, context: context) {
                            runtime.unavailableReason = L10n.text(
                                "The selected Result has no readable map payload during this compute.")
                        }
                    }
                } else {
                    let presentation = item.prepared.presentation
                    let preferredID = item.selectedProfileID.flatMap { requested in
                        presentation.steps.contains(where: { $0.id == requested }) ? requested : nil
                    } ?? presentation.selectedID
                    let selectedPresentation = MapProfilePresentation(sourceID: presentation.sourceID,
                        steps: presentation.steps, selectedID: preferredID)
                    let context = MapProfileContext(projectSessionID: capture.projectSessionID,
                        mapID: mapID, sourceID: selectedPresentation.sourceID)
                    do {
                        try runtime.profileSession.configure(selectedPresentation,
                            provider: item.prepared.provider, context: context)
                    } catch {
                        runtime.unavailableReason = L10n.text(error.localizedDescription)
                    }
                }
                runtime.subscription = runtime.profileSession.objectWillChange.sink { [weak self] _ in
                    Task { @MainActor [weak self] in self?.refreshPublishedNodes() }
                }
                runtime.isLoading = false
                runtime.isRefreshing = false
            }
            appliedViewport = requestedViewport
        } else {
            for nodeID in nodeIDs {
                guard let runtime = runtimeByID[nodeID] else { continue }
                runtime.isLoading = false
                runtime.isRefreshing = false
                runtime.computeReadableDuringLease = false
                runtime.profileSession.suspendSourceReads()
                if let message = failures[nodeID] { runtime.unavailableReason = message }
            }
        }
        ensureSelectedLayerForAllNodes()
        if let selectedNodeID { selectedLayerID = runtimeByID[selectedNodeID]?.selectedLayerID }
        refreshPublishedNodes()
        publishFrames()
        liveRenderTargetsDidChange?()
        if computeHistoricalRefreshGeneration == generation {
            computeHistoricalRefreshTask = nil
        }
    }

    private func computeRefreshIsCurrent(generation: Int,
                                         capture: WorkspaceResultComputeCapture,
                                         entry: WorkspaceResultComputeEntry,
                                         lease: MapResultComputeReadLease,
                                         snapshot: MapResultSourcesSnapshot) -> Bool {
        generation == computeHistoricalRefreshGeneration
            && activeComputeCapture == capture
            && computeReadLease == lease
            && computeRefreshEntry?.runID == entry.runID
            && configuredSnapshot == snapshot
            && computeReadIsCurrent?() == true
            && currentCheck?() == true
            && isSourceReadsSuspended
    }

    private func makeLiveKeyframeTimeline(runtime: NodeRuntime,
                                          entry: WorkspaceResultComputeEntry,
                                          lease: MapResultComputeReadLease)
        -> MapResultRenderLiveKeyframeTimeline? {
        let identity = LiveMapResultRunIdentity(entry: entry)
        guard runtime.source.nodeKind == "MultiResult",
              runtime.liveSelectionModesBySlot[0] != nil,
              let capture = runtime.liveComputeCapture,
              identity.matches(capture),
              ownerProjectSessionID == capture.projectSessionID,
              runtime.blockedLiveSelections[0].map({
                  LiveMapResultRunIdentity(entry: $0) == identity
              }) == true,
              runtime.liveComputeEntry.map({ LiveMapResultRunIdentity(entry: $0) == identity }) == true,
              lease.runID.caseInsensitiveCompare(entry.runID) == .orderedSame,
              let callbackPath = lease.callbackResultPath,
              SourceFilePaths.canonical(URL(fileURLWithPath: callbackPath)) == identity.resultPath,
              lease.canonicalProtectedSourcePaths.contains(identity.resultPath) else { return nil }

        let timeline = runtime.liveProfileTimelinesBySlot[0] ?? entry.profileTimeline
        guard let timeline, timeline.identity == identity,
              timeline.metadataError == nil,
              timeline.blocks.count == 1,
              let block = timeline.blocks.first,
              block.errorMessage == nil,
              block.profileCount >= 0,
              Set(block.profiles.map(\.index)).count == block.profiles.count,
              block.profiles.allSatisfy({ $0.index >= 0 && $0.index < block.profileCount }) else {
            return nil
        }
        if let currentBlockName = runtime.liveProfileOutputBlockName,
           currentBlockName != block.name { return nil }
        return MapResultRenderLiveKeyframeTimeline(node: runtime.source.node,
            runID: entry.runID, resultPath: entry.resultPath, outputBlockName: block.name,
            profileCount: block.profileCount,
            profiles: block.profiles.map { .init(index: $0.index, name: $0.name, time: $0.time) })
    }

    private func updateComputeSelectionExpectations(runtime: NodeRuntime,
                                                    source: MapResultChartActiveNode,
                                                    protectedPaths: Set<String>) -> Set<Int> {
        let existingOwners = Set(runtime.rasterSelectionIndicesByLayerID?.values.flatMap { $0 } ?? [])
        let activeLiveIndices = Set(runtime.liveSelectionModesBySlot.keys.filter {
            runtime.blockedLiveSelections[$0] != nil
        })
        var blocked = activeLiveIndices
        var nextExpected: [Int: MapResultChartSourceChoice] = [:]
        let slotsByIndex = Dictionary(uniqueKeysWithValues: source.selections.map { ($0.selectionIndex, $0) })
        let allIndices = existingOwners.union(slotsByIndex.keys).union(runtime.blockedLiveSelections.keys)
            .union(runtime.expectedStoredSelections.keys)
        for index in allIndices {
            guard !activeLiveIndices.contains(index),
                  let choice = slotsByIndex[index]?.selectedResult
                    ?? runtime.expectedStoredSelections[index],
                  !choice.isComputing else {
                blocked.insert(index)
                continue
            }
            let path = SourceFilePaths.canonical(URL(fileURLWithPath: choice.resultPath))
            guard !protectedPaths.contains(path) else {
                blocked.insert(index)
                continue
            }
            let terrainIsProtected = runtime.sourceStatuses.contains { status in
                guard status.selectionIndices.contains(index),
                      SourceFilePaths.canonical(URL(fileURLWithPath: status.resultPath)) == path,
                      status.revision.caseInsensitiveCompare(choice.revision) == .orderedSame,
                      let terrainPath = status.terrainPath else { return false }
                return protectedPaths.contains(
                    SourceFilePaths.canonical(URL(fileURLWithPath: terrainPath)))
            }
            guard !terrainIsProtected else {
                blocked.insert(index)
                continue
            }
            nextExpected[index] = choice
        }
        runtime.expectedStoredSelections = nextExpected
        runtime.computeBlockedSelectionIndices = blocked
        return Set(nextExpected.keys)
    }

    private func computeSourcePaths(for source: MapResultChartActiveNode,
                                    runtime: NodeRuntime,
                                    readableSelectionIndices: Set<Int>) -> Set<String> {
        var paths: Set<String> = []
        func append(_ path: String?) {
            guard let path, URL(fileURLWithPath: path).path.hasPrefix("/"),
                  ["h5", "hdf"].contains(URL(fileURLWithPath: path).pathExtension.lowercased()) else { return }
            paths.insert(SourceFilePaths.canonical(URL(fileURLWithPath: path)))
        }
        for selection in source.selections where readableSelectionIndices.contains(selection.selectionIndex) {
            guard let choice = selection.selectedResult
                    ?? runtime.expectedStoredSelections[selection.selectionIndex] else { continue }
            append(choice.resultPath)
            if let status = runtime.sourceStatuses.first(where: { status in
                status.selectionIndices.contains(selection.selectionIndex)
                    && SourceFilePaths.canonical(URL(fileURLWithPath: status.resultPath))
                        == SourceFilePaths.canonical(URL(fileURLWithPath: choice.resultPath))
                    && status.revision.caseInsensitiveCompare(choice.revision) == .orderedSame
            }) {
                append(status.terrainPath)
            }
        }
        return paths
    }

    func selectNode(_ id: String) {
        guard runtimeByID[id] != nil, selectedNodeID != id else { return }
        selectedNodeID = id
        selectedLayerID = runtimeByID[id]?.selectedLayerID
        refreshPublishedNodes()
        refreshVelocityParticles()
    }

    func clearSelection() {
        guard selectedNodeID != nil || selectedLayerID != nil else { return }
        selectedNodeID = nil
        selectedLayerID = nil
        refreshPublishedNodes()
        refreshVelocityParticles()
    }

    /// Selects which rendered node layer supplies the focused legend. All
    /// current result rasters remain installed on the map.
    func selectResultLayer(_ id: String) {
        guard let selectedNodeID, let runtime = runtimeByID[selectedNodeID],
              runtime.presentationLayers.contains(where: { $0.id == id }) else { return }
        runtime.selectedLayerID = id
        selectedLayerID = id
        refreshPublishedNodes()
    }

    /// Installs the currently selected, exact Wind child captured by the
    /// owning map workflow. A BoundaryCondition parent alone is never enough
    /// to select Wind particles.
    func setWindVelocityParticleSource(_ source: MapWindVelocityParticleSource?) {
        guard let source else {
            windVelocitySource = nil
            windVelocitySourceGeneration = nil
            refreshVelocityParticles()
            return
        }
        guard let snapshot = configuredSnapshot,
              let projectSessionID = ownerProjectSessionID,
              source.projectSessionID == projectSessionID,
              source.mapWorkflowIdentity.isEmpty == false,
              Self.matchesWindSource(source, snapshot: snapshot),
              currentCheck?() == true else {
            windVelocitySource = nil
            windVelocitySourceGeneration = nil
            velocityParticles.invalidate(unavailableMessage:
                "The selected Wind source no longer matches this map context.")
            return
        }
        guard windVelocitySource != source || windVelocitySourceGeneration != sourceGeneration else { return }
        windVelocitySource = source
        windVelocitySourceGeneration = sourceGeneration
        refreshVelocityParticles()
    }

    /// Carries a previously selected Wind profile into a fresh capture only
    /// when the exact map workflow and Wind source revision are unchanged.
    /// The profile index/time themselves remain sourced from the accepted
    /// Wind sampler response, never inferred from the Boundary Condition row.
    func selectedWindProfile(for source: MapWindVelocityParticleSource)
        -> (index: Int, time: String?)? {
        guard let current = windVelocitySource,
              windVelocitySourceGeneration == sourceGeneration,
              current.projectSessionID == source.projectSessionID,
              current.mapWorkflowIdentity == source.mapWorkflowIdentity,
              current.map == source.map,
              current.contextToken == source.contextToken,
              current.selectionIdentity == source.selectionIdentity,
              current.boundaryNode == source.boundaryNode,
              current.windNode == source.windNode,
              SourceFilePaths.canonical(URL(fileURLWithPath: current.boundaryPath))
                == SourceFilePaths.canonical(URL(fileURLWithPath: source.boundaryPath)),
              current.boundaryRevision.caseInsensitiveCompare(source.boundaryRevision) == .orderedSame,
              let snapshot = configuredSnapshot,
              ownerProjectSessionID == source.projectSessionID,
              Self.matchesWindSource(current, snapshot: snapshot),
              Self.matchesWindSource(source, snapshot: snapshot),
              currentCheck?() == true else { return nil }
        return velocityParticles.selectedWindProfile(matching: source)
    }

    /// Reindexes live-slot masks and cached raster ownership when a MultiResult
    /// slot is removed. Pixel buffers remain cached; removed-only layers stay
    /// hidden until a fresh source frame gives them valid ownership again.
    func removeLiveComputeSelectionSlot(nodeID: String, selectionIndex: Int) {
        guard selectionIndex > 0, let runtime = runtimeByID[nodeID],
              runtime.source.nodeKind == "MultiResult" else { return }
        let hadLiveMasks = !runtime.blockedLiveSelections.isEmpty
            || !runtime.expectedStoredSelections.isEmpty
        var reindexed: [Int: WorkspaceResultComputeEntry] = [:]
        for (index, entry) in runtime.blockedLiveSelections where index != selectionIndex {
            reindexed[index > selectionIndex ? index - 1 : index] = entry
        }
        runtime.blockedLiveSelections = reindexed
        var expectedReindexed: [Int: MapResultChartSourceChoice] = [:]
        for (index, choice) in runtime.expectedStoredSelections where index != selectionIndex {
            expectedReindexed[index > selectionIndex ? index - 1 : index] = choice
        }
        runtime.expectedStoredSelections = expectedReindexed
        if let ownership = runtime.rasterSelectionIndicesByLayerID {
            runtime.rasterSelectionIndicesByLayerID = ownership.mapValues { indices in
                Array(Set(indices.compactMap { index -> Int? in
                    guard index != selectionIndex else { return nil }
                    return index > selectionIndex ? index - 1 : index
                })).sorted()
            }
        } else if hadLiveMasks {
            // There is no safe way to infer which cached layers belonged to
            // the removed slot, so keep every layer hidden until a fresh frame
            // arrives with explicit source ownership.
            runtime.rasterSelectionIndicesByLayerID = [:]
        }
        ensureSelectedLayer(runtime)
        if selectedNodeID == runtime.id { selectedLayerID = runtime.selectedLayerID }
        publishFrames()
        refreshPublishedNodes()
        liveRenderTargetsDidChange?()
    }

    func reload() {
        guard configuredSnapshot != nil, !isSourceReadsSuspended else { return }
        requestedViewport = viewportLookup?()
        viewportGeneration &+= 1
        guard !isLoading else { return }
        startViewportRefresh()
    }

    func invalidate() {
        sourceGeneration &+= 1
        sourceTask?.cancel(); sourceTask = nil
        refreshTask?.cancel(); refreshTask = nil
        computeHistoricalRefreshTask?.cancel(); computeHistoricalRefreshTask = nil
        computeHistoricalRefreshGeneration &+= 1
        for runtime in runtimeByID.values {
            runtime.profileSession.invalidate()
            runtime.subscription = nil
        }
        configuredSnapshot = nil
        profileProjectSessionID = nil
        ownerProjectSessionID = nil
        activeComputeCapture = nil
        computeReadLease = nil
        computeReadIsCurrent = nil
        computeRefreshEntry = nil
        computeReadableNodeIDs = []
        pendingLiveProfileSelections = [:]
        isSourceReadsSuspended = false
        viewportLookup = nil
        currentCheck = nil
        orderedNodeIDs = []
        runtimeByID = [:]
        requestedViewport = nil
        appliedViewport = nil
        activeViewportGeneration = nil
        pendingInitialViewportRefresh = false
        stagedFrames = [:]
        selectedNodeID = nil
        selectedLayerID = nil
        isLoading = false
        isReloading = false
        errorMessage = nil
        nodes = []
        velocityParticles.invalidate()
        didUpdate?([], [])
        liveRenderTargetsDidChange?()
    }

    private func beginConfiguration(_ snapshot: MapResultSourcesSnapshot) {
        computeHistoricalRefreshTask?.cancel(); computeHistoricalRefreshTask = nil
        computeHistoricalRefreshGeneration &+= 1
        computeReadLease = nil
        computeReadIsCurrent = nil
        computeRefreshEntry = nil
        computeReadableNodeIDs = []
        velocityParticles.invalidate(unavailableMessage: "Loading the selected Result map context.")
        windVelocitySource = nil
        windVelocitySourceGeneration = nil
        let previousSnapshot = configuredSnapshot
        let previousProjectSessionID = profileProjectSessionID
        let nextProjectSessionID = ownerProjectSessionID ?? Self.contextID(for: snapshot.identity)
        let canCarryLiveMasks = previousSnapshot?.map.mapID == snapshot.map.mapID
            && previousProjectSessionID == nextProjectSessionID
        let previousLiveMasks = runtimeByID.mapValues { runtime in
            (node: runtime.source.node, selections: runtime.blockedLiveSelections,
             expected: runtime.expectedStoredSelections)
        }
        let snapshotMapID = UUID(uuidString: snapshot.map.mapID)
        var restoredLiveProfileSelections: [String: (entry: WorkspaceResultComputeEntry,
            capture: WorkspaceResultComputeCapture, outputBlockName: String,
            profileIndex: Int, mapID: UUID)] = [:]
        if canCarryLiveMasks, let snapshotMapID {
            for source in snapshot.sources.activeNodes where pendingLiveProfileSelections[source.id] == nil {
                guard let runtime = runtimeByID[source.id], runtime.source.node == source.node,
                      let entry = runtime.liveComputeEntry,
                      let capture = runtime.liveComputeCapture,
                      let outputBlockName = runtime.liveProfileOutputBlockName,
                      let profileIndex = runtime.selectedLiveProfileIndex ?? runtime.profileSession.currentID,
                      runtime.profileSession.steps.contains(where: { $0.id == profileIndex }),
                      LiveMapResultSelectionProjection.nodeMatches(source,
                        projectSessionID: nextProjectSessionID, capture: capture, entry: entry),
                      Self.sourceSnapshotConfirms(entry, selectionIndex: 0, in: source) else { continue }
                restoredLiveProfileSelections[source.id] = (entry, capture, outputBlockName,
                    profileIndex, snapshotMapID)
            }
        }
        sourceGeneration &+= 1
        let generation = sourceGeneration
        sourceTask?.cancel(); sourceTask = nil
        refreshTask?.cancel(); refreshTask = nil
        for runtime in runtimeByID.values { runtime.profileSession.invalidate() }

        configuredSnapshot = snapshot
        profileProjectSessionID = ownerProjectSessionID ?? Self.contextID(for: snapshot.identity)
        orderedNodeIDs = snapshot.sources.activeNodes.map(\.id)
        let activeNodeIDs = Set(orderedNodeIDs)
        for (nodeID, request) in restoredLiveProfileSelections where pendingLiveProfileSelections[nodeID] == nil {
            pendingLiveProfileSelections[nodeID] = request
        }
        pendingLiveProfileSelections = pendingLiveProfileSelections.filter {
            activeNodeIDs.contains($0.key) && $0.value.mapID == snapshotMapID
        }
        runtimeByID = [:]
        requestedViewport = viewportLookup?()
        appliedViewport = nil
        viewportGeneration = 0
        activeViewportGeneration = nil
        pendingInitialViewportRefresh = false
        stagedFrames = [:]
        selectedNodeID = orderedNodeIDs.first
        selectedLayerID = nil
        errorMessage = nil
        isLoading = !orderedNodeIDs.isEmpty
        isReloading = false
        didUpdate?([], [])
        refreshPublishedNodes()
        liveRenderTargetsDidChange?()

        guard Set(orderedNodeIDs).count == orderedNodeIDs.count else {
            isLoading = false
            errorMessage = L10n.text("The active result map contains duplicate node identities.")
            refreshPublishedNodes()
            return
        }
        guard let mapID = UUID(uuidString: snapshot.map.mapID) else {
            isLoading = false
            errorMessage = L10n.text("The active result map has an invalid map identity.")
            refreshPublishedNodes()
            return
        }
        guard !orderedNodeIDs.isEmpty else {
            isLoading = false
            refreshPublishedNodes()
            return
        }

        runtimeByID = Dictionary(uniqueKeysWithValues: snapshot.sources.activeNodes.map {
            let runtime = NodeRuntime(source: $0)
            if canCarryLiveMasks,
               let previous = previousLiveMasks[runtime.id],
               previous.node == runtime.source.node {
                runtime.expectedStoredSelections = previous.expected
                for (selectionIndex, entry) in previous.selections {
                    if entry.status != .running,
                       let selected = runtime.source.selections.first(where: {
                           $0.selectionIndex == selectionIndex
                       })?.selectedResult, !selected.isComputing {
                        // This runtime has no old cached pixels. A terminal
                        // slot may now select another stored Result, but only
                        // a fresh frame with this exact path and SHA can show.
                        runtime.expectedStoredSelections[selectionIndex] = selected
                    } else if !Self.sourceSnapshotConfirms(entry,
                        selectionIndex: selectionIndex, in: runtime.source) {
                        runtime.blockedLiveSelections[selectionIndex] = entry
                    }
                }
            }
            return (runtime.id, runtime)
        })
        refreshPublishedNodes()

        let initialViewport = requestedViewport
        let initialViewportGeneration = viewportGeneration
        sourceTask = Task { [weak self] in
            await self?.prepareNodes(snapshot: snapshot, mapID: mapID,
                generation: generation, initialViewport: initialViewport,
                initialViewportGeneration: initialViewportGeneration)
        }
    }

    private func prepareNodes(snapshot: MapResultSourcesSnapshot, mapID: UUID,
                              generation: Int, initialViewport: RasterMapViewExtent?,
                              initialViewportGeneration: Int) async {
        defer {
            if generation == sourceGeneration {
                sourceTask = nil
                isLoading = false
                refreshPublishedNodes()
                if pendingInitialViewportRefresh, !orderedNodeIDs.isEmpty {
                    pendingInitialViewportRefresh = false
                    startViewportRefresh()
                }
            }
        }
        for source in snapshot.sources.activeNodes {
            guard generation == sourceGeneration, !Task.isCancelled,
                  !isSourceReadsSuspended else { return }
            guard currentCheck?() == true else { invalidate(); return }
            guard let runtime = runtimeByID[source.id] else { continue }
            do {
                var preparedNode = source
                var liveProfileRequest = pendingLiveProfileSelections[source.id]
                if let pendingRequest = liveProfileRequest {
                    liveProfileRequest = nil
                    let sameMap = pendingRequest.mapID == mapID
                        && pendingRequest.mapID == UUID(uuidString: snapshot.map.mapID)
                    let ownerStillMatches = sameMap && LiveMapResultSelectionProjection.nodeMatches(source,
                        projectSessionID: pendingRequest.capture.projectSessionID,
                        capture: pendingRequest.capture, entry: pendingRequest.entry)
                    let stableChoice = ownerStillMatches
                        ? LiveMapResultSelectionProjection.stableChoice(
                            for: pendingRequest.entry, in: source)
                        : nil
                    let currentSourceMatches = Self.sourceSnapshotConfirms(
                        pendingRequest.entry, selectionIndex: 0, in: source)
                    if stableChoice != nil, currentSourceMatches {
                        liveProfileRequest = pendingRequest
                        preparedNode = MapResultChartActiveNode(node: source.node,
                            nodeKind: source.nodeKind, name: source.name, selections: source.selections,
                            selectedMapType: source.selectedMapType,
                            profileIndex: pendingRequest.profileIndex)
                    } else if !sameMap || !LiveMapResultSelectionProjection.nodeMatches(source,
                        projectSessionID: pendingRequest.capture.projectSessionID,
                        capture: pendingRequest.capture, entry: pendingRequest.entry) {
                        pendingLiveProfileSelections.removeValue(forKey: source.id)
                    } else if stableChoice != nil && !currentSourceMatches {
                        // The terminal Result exists in the catalog, but the
                        // current slot has moved to another source. Do not
                        // carry the old live profile into that selection.
                        pendingLiveProfileSelections.removeValue(forKey: source.id)
                    }
                }
                let request = PreparationRequest(snapshot: snapshot, node: preparedNode,
                    mapID: mapID, viewport: viewportLookup ?? { nil })
                let prepared = try await prepareNode(request)
                guard generation == sourceGeneration, !Task.isCancelled else { return }
                guard currentCheck?() == true else { invalidate(); return }

                runtime.availability = prepared.availability
                runtime.legendLookup = prepared.legendLookup
                runtime.velocityFieldSampler = prepared.velocityFieldSampler
                runtime.initialLayers = prepared.initialUpdate?.rasters ?? []
                runtime.rasterSelectionIndicesByLayerID = prepared.initialUpdate?.rasterSelectionIndicesByLayerID
                runtime.rasterSourceIdentityByLayerID = prepared.initialUpdate?.rasterSourceIdentityByLayerID
                runtime.legends = prepared.initialLegends
                runtime.sourceStatuses = prepared.initialSourceStatuses
                runtime.unavailableReason = prepared.initialUnavailableReason
                runtime.renderedViewport = prepared.renderedViewport
                if prepared.initialUpdate == nil && !prepared.initialLegends.isEmpty {
                    runtime.unavailableReason = L10n.text("The result renderer returned an invalid raster.")
                }
                bindRenderCallbacks(runtime: runtime, generation: generation, mapID: mapID)
                let context = MapProfileContext(projectSessionID: profileProjectSessionID ?? UUID(),
                    mapID: mapID, sourceID: prepared.presentation.sourceID)
                var presentation = prepared.presentation
                if let liveProfileRequest,
                   presentation.steps.contains(where: { $0.id == liveProfileRequest.profileIndex }) {
                    presentation = MapProfilePresentation(sourceID: presentation.sourceID,
                        steps: presentation.steps, selectedID: liveProfileRequest.profileIndex)
                }
                try runtime.profileSession.configure(presentation,
                    provider: prepared.provider, context: context)
                runtime.profileSession.didChooseMetadataOnlyProfile = { [weak self, weak runtime] index, context in
                    guard let self, let runtime else { return }
                    self.chooseLiveProfile(index, context: context, runtime: runtime)
                }
                if let liveProfileRequest,
                   runtime.profileSession.steps.contains(where: { $0.id == liveProfileRequest.profileIndex }) {
                    pendingLiveProfileSelections.removeValue(forKey: source.id)
                }
                runtime.subscription = runtime.profileSession.objectWillChange.sink { [weak self] _ in
                    Task { @MainActor [weak self] in self?.refreshPublishedNodes() }
                }
            } catch {
                guard generation == sourceGeneration, !Task.isCancelled else { return }
                runtime.unavailableReason = L10n.text(error.localizedDescription)
            }
            runtime.isLoading = false
            refreshPublishedNodes()
        }

        guard generation == sourceGeneration, !Task.isCancelled else { return }
        guard currentCheck?() == true else { invalidate(); return }
        let initialFramesAgree = viewportGeneration == initialViewportGeneration
            && viewportLookup?() == initialViewport
            && orderedNodeIDs.allSatisfy { runtimeByID[$0]?.renderedViewport == initialViewport }
        if initialFramesAgree {
            for id in orderedNodeIDs {
                guard let runtime = runtimeByID[id] else { continue }
                runtime.layers = runtime.initialLayers
                runtime.sourceStatuses = runtime.availability?().sourceStatuses ?? runtime.sourceStatuses
                ensureSelectedLayer(runtime)
            }
            appliedViewport = initialViewport
            if let selectedNodeID { selectedLayerID = runtimeByID[selectedNodeID]?.selectedLayerID }
            publishFrames()
        } else {
            requestedViewport = viewportLookup?()
            viewportGeneration &+= 1
            pendingInitialViewportRefresh = true
        }
        liveRenderTargetsDidChange?()
        refreshVelocityParticles()
    }

    private func bindRenderCallbacks(runtime: NodeRuntime, generation: Int, mapID: UUID) {
        runtime.profileSession.didSelect = { [weak self, weak runtime] update, context in
            guard let self, let runtime else { return }
            self.profileDidSelect(update, context: context, runtime: runtime,
                sourceGeneration: generation)
        }
        runtime.profileSession.didSelectPersistableProfile = { [weak self, weak runtime] index, context in
            guard let self, let runtime,
                  !self.isSourceReadsSuspended,
                  generation == self.sourceGeneration,
                  self.runtimeByID[runtime.id] === runtime,
                  context.projectSessionID == self.profileProjectSessionID,
                  context.mapID == mapID,
                  self.currentCheck?() == true else { return }
            self.didSelectPersistableProfile?(runtime.source.node,
                runtime.source.selectedMapType, index)
        }
    }

    private func profileDidSelect(_ update: MapUpdate, context: MapProfileContext,
                                  runtime: NodeRuntime, sourceGeneration: Int) {
        guard canAcceptProfileRead(runtime),
              sourceGeneration == self.sourceGeneration,
              runtimeByID[runtime.id] === runtime,
              context.projectSessionID == profileProjectSessionID,
              let mapID = UUID(uuidString: configuredSnapshot?.map.mapID ?? ""),
              context.mapID == mapID else { return }
        guard currentCheck?() == true else { invalidate(); return }
        let frame = Frame(layers: update.rasters ?? [],
            rasterSelectionIndicesByLayerID: update.rasterSelectionIndicesByLayerID,
            rasterSourceIdentityByLayerID: update.rasterSourceIdentityByLayerID,
            legends: runtime.legendLookup?(),
            sourceStatuses: runtime.availability?().sourceStatuses ?? runtime.sourceStatuses,
            unavailableReason: runtime.availability?().reason ?? runtime.unavailableReason)
        if let generation = activeViewportGeneration {
            guard generation == viewportGeneration,
                  runtime.isRefreshing,
                  requestedViewport == viewportLookup?() else { return }
            stagedFrames[runtime.id] = frame
            return
        }
        runtime.layers = frame.layers
        runtime.rasterSelectionIndicesByLayerID = frame.rasterSelectionIndicesByLayerID
        runtime.rasterSourceIdentityByLayerID = frame.rasterSourceIdentityByLayerID
        if let legends = frame.legends { runtime.legends = legends }
        runtime.sourceStatuses = frame.sourceStatuses
        runtime.unavailableReason = frame.unavailableReason
        ensureSelectedLayer(runtime)
        if selectedNodeID == runtime.id { selectedLayerID = runtime.selectedLayerID }
        refreshPublishedNodes()
        publishFrames()
        liveRenderTargetsDidChange?()
        refreshVelocityParticles()
    }

    private func canAcceptProfileRead(_ runtime: NodeRuntime) -> Bool {
        if let runtimeLease = runtime.computeReadLease {
            return isSourceReadsSuspended
                && runtime.computeReadableDuringLease
                && computeReadLease == runtimeLease
                && computeReadIsCurrent?() == true
        }
        return !isSourceReadsSuspended
    }

    private func refreshVelocityParticles() {
        guard !isSourceReadsSuspended else {
            // The stable source reader is suspended by the compute lease, but
            // an already installed writer-owned duplex target remains valid.
            // The next target publication replaces or clears it atomically.
            if activeComputeCapture == nil {
                velocityParticles.invalidate(unavailableMessage: "Result velocity sampling is paused during plan compute.")
            }
            return
        }
        if let source = windVelocitySource {
            guard windVelocitySourceGeneration == sourceGeneration,
                  let snapshot = configuredSnapshot,
                  let projectSessionID = ownerProjectSessionID,
                  source.projectSessionID == projectSessionID,
                  Self.matchesWindSource(source, snapshot: snapshot),
                  let viewport = viewportLookup?(), currentCheck?() == true else {
                windVelocitySource = nil
                windVelocitySourceGeneration = nil
                velocityParticles.invalidate(unavailableMessage:
                    "The selected Wind source no longer matches this map context.")
                return
            }
            let sampler = sampleWindVelocityField
            let selectedProfile = velocityParticles.selectedWindProfile(matching: source)
            let profileIndex = selectedProfile?.index ?? source.profileIndex
            let selectedTime = selectedProfile?.time ?? source.profileTime ?? ""
            let identity = MapResultVelocityParticleTargetIdentity(
                sourceKind: .wind, sourceGeneration: sourceGeneration,
                projectSessionID: projectSessionID,
                mapID: UUID(uuidString: source.map.mapID)!,
                contextToken: source.contextToken,
                nodeID: source.selectionIdentity,
                node: source.windNode,
                resultPath: SourceFilePaths.canonical(URL(fileURLWithPath: source.boundaryPath)),
                resultRevision: source.boundaryRevision,
                profileIndex: profileIndex,
                profileName: selectedTime, time: selectedTime,
                viewport: viewport)
            velocityParticles.setTarget(MapResultVelocityParticleTarget(identity: identity,
                sample: { requestID, profileIndex, profileTime, requestViewport in
                    try await sampler(source, requestID, profileIndex, profileTime, requestViewport)
                }))
            return
        }
        guard let selectedNodeID,
              let runtime = runtimeByID[selectedNodeID],
              let snapshot = configuredSnapshot,
              let projectSessionID = ownerProjectSessionID,
              let mapID = UUID(uuidString: snapshot.map.mapID),
              let viewport = viewportLookup?(),
              currentCheck?() == true else {
            velocityParticles.invalidate(unavailableMessage: "Select a visible Result Velocity map before showing velocity particles.")
            return
        }
        guard !runtime.isLoading,
              !runtime.profileSession.isMetadataOnly,
              let sampler = runtime.velocityFieldSampler,
              runtime.source.selectedMapType == "Velocity",
              let sourceChoice = runtime.source.selections.first(where: { $0.selectionIndex == 0 })?.selectedResult,
              !sourceChoice.isComputing,
              let profileIndex = runtime.profileSession.currentID,
              let profileStep = runtime.profileSession.steps.first(where: { $0.id == profileIndex }) else {
            velocityParticles.invalidate(unavailableMessage: "The selected Result has no stable Velocity source.")
            return
        }
        let identity = MapResultVelocityParticleTargetIdentity(
            sourceGeneration: sourceGeneration, projectSessionID: projectSessionID,
            mapID: mapID, contextToken: snapshot.sources.contextToken,
            nodeID: runtime.id, node: runtime.source.node,
            resultPath: SourceFilePaths.canonical(URL(fileURLWithPath: sourceChoice.resultPath)),
            resultRevision: sourceChoice.revision, profileIndex: profileIndex,
            profileName: profileStep.label, time: profileStep.sourceTime ?? "",
            viewport: viewport)
        velocityParticles.setTarget(MapResultVelocityParticleTarget(identity: identity,
            sample: sampler))
    }

    private static func matchesWindSource(_ source: MapWindVelocityParticleSource,
                                          snapshot: MapResultSourcesSnapshot) -> Bool {
        let map = source.map
        let current = snapshot.map
        guard source.selectionIdentity == source.windNode.sourceIdentity,
              source.boundaryNode.nodeType == "BoundaryCondition",
              source.windNode.nodeType == "WindLayer",
              source.boundaryNode.parentResultNodeType == nil,
              source.boundaryNode.parentResultAssetID == nil,
              source.boundaryNode.parentResultNodePath == nil,
              source.boundaryNode.parentResultNodeName == nil,
              source.boundaryNode.parentResultRevision == nil,
              source.windNode.parentResultNodeType == nil,
              source.windNode.parentResultAssetID == nil,
              source.windNode.parentResultNodePath == nil,
              source.windNode.parentResultNodeName == nil,
              source.windNode.parentResultRevision == nil,
              source.boundaryNode.rootName == source.windNode.rootName,
              let boundaryPath = source.boundaryNode.nodePath,
              let windPath = source.windNode.nodePath,
              boundaryPath.count + 1 == windPath.count,
              Array(windPath.prefix(boundaryPath.count)) == boundaryPath,
              source.windNode.parentBoundaryConditionAssetID == source.boundaryNode.assetID,
              source.windNode.parentBoundaryConditionNodePath == boundaryPath,
              source.windNode.parentBoundaryConditionNodeName == source.boundaryNode.nodeName,
              let windAsset = source.windNode.assetID,
              let boundaryAsset = source.boundaryNode.assetID,
              SourceFilePaths.canonical(URL(fileURLWithPath: windAsset))
                == SourceFilePaths.canonical(URL(fileURLWithPath: boundaryAsset)),
              SourceFilePaths.canonical(URL(fileURLWithPath: source.boundaryPath))
                == SourceFilePaths.canonical(URL(fileURLWithPath: boundaryAsset)),
              source.boundaryRevision.count == 64,
              source.boundaryRevision.allSatisfy(\.isHexDigit),
              !source.contextToken.isEmpty,
              UUID(uuidString: map.mapID) != nil,
              map.mapID == current.mapID, map.mapIndex == current.mapIndex,
              map.mapName == current.mapName, map.mapType == current.mapType,
              SourceFilePaths.canonical(URL(fileURLWithPath: map.projectPath))
                == SourceFilePaths.canonical(URL(fileURLWithPath: current.projectPath)),
              map.projectXmlSHA.caseInsensitiveCompare(current.projectXmlSHA) == .orderedSame,
              map.expectedVisualizationRevision.caseInsensitiveCompare(current.expectedVisualizationRevision)
                == .orderedSame else { return false }
        return true
    }

    private func startViewportRefresh() {
        guard refreshTask == nil, !orderedNodeIDs.isEmpty, !isLoading,
              !isSourceReadsSuspended else { return }
        refreshTaskID &+= 1
        let taskID = refreshTaskID
        let sourceRevision = sourceGeneration
        refreshTask = Task { [weak self] in
            await self?.drainViewportRefresh(taskID: taskID, sourceGeneration: sourceRevision)
        }
    }

    private func drainViewportRefresh(taskID: Int, sourceGeneration: Int) async {
        defer {
            if taskID == refreshTaskID {
                refreshTask = nil
                isReloading = false
                activeViewportGeneration = nil
                for runtime in runtimeByID.values { runtime.isRefreshing = false }
                refreshPublishedNodes()
            }
        }
        isReloading = true
        refreshPublishedNodes()

        while !Task.isCancelled, sourceGeneration == self.sourceGeneration {
            guard currentCheck?() == true else { invalidate(); return }
            let generation = viewportGeneration
            let targetViewport = requestedViewport
            activeViewportGeneration = generation
            stagedFrames = [:]
            var failed = false

            for id in orderedNodeIDs {
                guard !Task.isCancelled, sourceGeneration == self.sourceGeneration else { return }
                guard generation == viewportGeneration else { break }
                guard let runtime = runtimeByID[id] else { continue }
                runtime.isRefreshing = true
                if runtime.profileSession.canSelect, runtime.profileSession.position != nil {
                    runtime.profileSession.reloadCurrent()
                    await waitForProfileSession(runtime.profileSession)
                } else {
                    stagedFrames[id] = Frame(layers: runtime.layers,
                        rasterSelectionIndicesByLayerID: runtime.rasterSelectionIndicesByLayerID,
                        rasterSourceIdentityByLayerID: runtime.rasterSourceIdentityByLayerID,
                        legends: runtime.legends,
                        sourceStatuses: runtime.sourceStatuses,
                        unavailableReason: runtime.unavailableReason)
                }
                runtime.isRefreshing = false
                if generation != viewportGeneration { break }
                if let error = runtime.profileSession.error {
                    runtime.unavailableReason = error
                    failed = true
                    break
                }
                if stagedFrames[id] == nil {
                    failed = true
                    runtime.unavailableReason = L10n.text("The result renderer did not return the requested map frame.")
                    break
                }
            }

            if generation != viewportGeneration || targetViewport != viewportLookup?() {
                activeViewportGeneration = nil
                stagedFrames = [:]
                refreshPublishedNodes()
                continue
            }
            activeViewportGeneration = nil
            if failed {
                stagedFrames = [:]
                refreshPublishedNodes()
                break
            }
            for id in orderedNodeIDs {
                guard let runtime = runtimeByID[id], let frame = stagedFrames[id] else { continue }
                runtime.layers = frame.layers
                runtime.rasterSelectionIndicesByLayerID = frame.rasterSelectionIndicesByLayerID
                runtime.rasterSourceIdentityByLayerID = frame.rasterSourceIdentityByLayerID
                if let legends = frame.legends { runtime.legends = legends }
                runtime.sourceStatuses = frame.sourceStatuses
                runtime.unavailableReason = frame.unavailableReason
                ensureSelectedLayer(runtime)
            }
            stagedFrames = [:]
            appliedViewport = targetViewport
            if let selectedNodeID { selectedLayerID = runtimeByID[selectedNodeID]?.selectedLayerID }
            publishFrames()
            refreshPublishedNodes()
            if generation == viewportGeneration { break }
        }
    }

    private func waitForProfileSession(_ session: MapProfileSession) async {
        while session.busy, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func ensureSelectedLayer(_ runtime: NodeRuntime) {
        if let selected = runtime.selectedLayerID,
           runtime.presentationLayers.contains(where: { $0.id == selected }) { return }
        runtime.selectedLayerID = runtime.presentationLayers.first?.id
    }

    private func ensureSelectedLayerForAllNodes() {
        for runtime in runtimeByID.values { ensureSelectedLayer(runtime) }
    }

    private func refreshPublishedNodes() {
        for runtime in runtimeByID.values where runtime.profileSession.isMetadataOnly {
            let timeline = runtime.liveProfileTimelinesBySlot[0]
                ?? runtime.liveComputeEntry?.profileTimeline
            let blocks = timeline?.blocks ?? []
            let message: String
            if let error = timeline?.metadataError ?? blocks.first?.errorMessage {
                message = L10n.text(error)
            } else if blocks.count > 1 {
                message = L10n.text("Live profile output blocks are kept separate and cannot share a single Result timeline.")
            } else if blocks.isEmpty {
                message = L10n.text("Live Result profile metadata is waiting for the first written timestep.")
            } else {
                message = L10n.text("Waiting for the active Result output to become available.")
            }
            runtime.profileSession.updateMetadataAvailability(runtime.hasLiveProfileRaster ? nil : message)
        }
        nodes = orderedNodeIDs.compactMap { id in
            guard let runtime = runtimeByID[id] else { return nil }
            return MapResultMapNode(id: id, name: runtime.source.name,
                kind: runtime.source.nodeKind, selectedMapType: runtime.source.selectedMapType,
                profileIndex: runtime.profileSession.currentID,
                profileCount: runtime.profileSession.steps.count,
                isLoading: runtime.isLoading || runtime.profileSession.busy,
                isRefreshing: runtime.isRefreshing,
                layerCount: runtime.presentationLayers.count,
                unavailableMessage: runtime.availabilityMessage,
                liveComputeStatus: runtime.liveComputeEntry?.status,
                liveComputeFraction: runtime.liveComputeEntry?.fraction,
                liveProfileMetadataCount: runtime.liveProfileOutputBlockName.flatMap { name in
                    runtime.liveComputeEntry?.profileTimeline?.outputBlocks[name]?.profiles.count
                } ?? 0,
                isLiveProfileMetadataOnly: runtime.profileSession.isMetadataOnly && !runtime.hasLiveProfileRaster)
        }
    }

    private func publishFrames() {
        didUpdate?(resultLayers, resultLegends)
    }

    private static func makeLegends(from result: MapResultRenderResult) -> [MapLegend] {
        result.layers.map { layer in
            let count = layer.legendStops.count
            let stops = layer.legendStops.enumerated().map { index, stop in
                MapLegend.Stop(id: "\(layer.id)|\(index)",
                    position: count <= 1 ? 1 : Double(index) / Double(count - 1),
                    color: stop.color,
                    label: stop.value.formatted(.number.precision(.significantDigits(1...4))))
            }
            return MapLegend(id: layer.id,
                title: layer.resultName + " · " + layer.mapType,
                units: layer.units, stops: stops)
        }
    }

    private static func capture(for entry: WorkspaceResultComputeEntry) -> WorkspaceResultComputeCapture {
        WorkspaceResultComputeCapture(projectSessionID: entry.projectSessionID,
            editorID: entry.editorID, operationOwnerToken: entry.operationOwnerToken,
            operationContextID: entry.operationContextID, projectPath: entry.projectPath,
            projectRevision: entry.projectRevision,
            projectXmlFingerprint: entry.projectXmlFingerprint, planPath: entry.planPath,
            planRevision: entry.planRevision)
    }

    private static func sourceSnapshotConfirms(_ entry: WorkspaceResultComputeEntry,
                                               selectionIndex: Int,
                                               in node: MapResultChartActiveNode) -> Bool {
        guard let revision = entry.resultRevision, !revision.isEmpty,
              let slot = node.selections.first(where: { $0.selectionIndex == selectionIndex }),
              let selected = slot.selectedResult else { return false }
        let resultPath = SourceFilePaths.canonical(URL(fileURLWithPath: entry.resultPath))
        return SourceFilePaths.canonical(URL(fileURLWithPath: selected.resultPath)) == resultPath
            && selected.revision.caseInsensitiveCompare(revision) == .orderedSame
    }

    private static func contextID(for identity: String) -> UUID {
        for component in identity.split(whereSeparator: { ":|/".contains($0) }) {
            if let value = UUID(uuidString: String(component)) { return value }
        }
        return UUID()
    }

    private static func samePath(_ left: String, _ right: String) -> Bool {
        SourceFilePaths.canonical(URL(fileURLWithPath: left))
            == SourceFilePaths.canonical(URL(fileURLWithPath: right))
    }

    private func targetMapContextMatches(_ map: MapResultChartMapRequest,
                                        capture: WorkspaceResultComputeCapture) -> Bool {
        guard let snapshot = configuredSnapshot,
              SourceFilePaths.canonical(URL(fileURLWithPath: map.projectPath))
                == SourceFilePaths.canonical(URL(fileURLWithPath: capture.projectPath)),
              Self.samePath(snapshot.sources.projectPath, capture.projectPath),
              Self.sameDigest(snapshot.sources.projectRevision, capture.projectRevision),
              Self.sameDigest(map.projectXmlSHA, capture.projectXmlFingerprint),
              Self.sameDigest(snapshot.sources.projectXmlSHA, capture.projectXmlFingerprint),
              map.mapID == snapshot.map.mapID,
              Self.sameDigest(map.expectedVisualizationRevision, snapshot.map.expectedVisualizationRevision),
              !snapshot.sources.contextToken.isEmpty else { return false }
        return true
    }

    private static func sameDigest(_ left: String, _ right: String) -> Bool {
        left.caseInsensitiveCompare(right) == .orderedSame
    }

    private static func sourceTimesMatchWithinKeyframeTolerance(_ left: String, _ right: String) -> Bool {
        if left == right { return true }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func parse(_ value: String) -> Date? {
            formatter.date(from: value)
                ?? formatter.date(from: value + "Z")
        }
        guard let lhs = parse(left), let rhs = parse(right) else { return false }
        return abs(lhs.timeIntervalSince(rhs)) <= 0.01
    }

    private static func liveTargetID(projectSessionID: UUID, operationOwnerToken: String,
                                     operationContextID: String, runID: String, mapID: UUID,
                                     contextToken: String, nodeID: String, selectionIndex: Int,
                                     profileIndex: Int, profileTime: String, outputBlockName: String,
                                     mapType: String, viewport: RasterMapViewExtent) -> String {
        let fields = [projectSessionID.uuidString, operationOwnerToken, operationContextID,
            runID, mapID.uuidString, contextToken, nodeID, String(selectionIndex),
            String(profileIndex), profileTime, outputBlockName, mapType,
            String(viewport.minX.bitPattern), String(viewport.minY.bitPattern),
            String(viewport.maxX.bitPattern), String(viewport.maxY.bitPattern),
            String(viewport.pixelWidth), String(viewport.pixelHeight)]
        let digest = SHA256.hash(data: Data(fields.joined(separator: "\0").utf8))
        return "live-map-" + digest.map { String(format: "%02x", $0) }.joined()
    }

    private func installLiveMetadata(entry: WorkspaceResultComputeEntry,
                                     timeline: LiveMapResultProfileTimeline?,
                                     runtime: NodeRuntime) {
        let isSameRun = runtime.liveComputeEntry?.runID == entry.runID
            && runtime.liveComputeEntry.map { LiveMapResultRunIdentity(entry: $0) }
                == LiveMapResultRunIdentity(entry: entry)
        if !isSameRun {
            runtime.liveRastersBySelectionIndex = [:]
            runtime.currentLiveTargetsByID = [:]
            pendingLiveProfileSelections.removeValue(forKey: runtime.id)
        }
        runtime.liveComputeEntry = entry
        if var pending = pendingLiveProfileSelections[runtime.id],
           LiveMapResultRunIdentity(entry: pending.entry) == LiveMapResultRunIdentity(entry: entry),
           LiveMapResultRunIdentity(entry: entry).matches(pending.capture),
           UUID(uuidString: configuredSnapshot?.map.mapID ?? "") == pending.mapID {
            // Carry the actual terminal revision forward with the user's
            // selection; the running capture deliberately had no revision.
            pending.entry = entry
            pendingLiveProfileSelections[runtime.id] = pending
        }

        let blocks = timeline?.blocks ?? []
        guard blocks.count == 1, let block = blocks.first else {
            runtime.liveProfileOutputBlockName = nil
            let reason = blocks.isEmpty
                ? L10n.text("Live Result profile metadata is waiting for the first written timestep.")
                : L10n.text("Live profile output blocks are kept separate and cannot share a single Result timeline.")
            installMetadataOnlyTimeline(runtime: runtime, entry: entry, outputBlock: nil,
                timeline: timeline, unavailableMessage: reason)
            runtime.unavailableReason = liveComputeUnavailableMessage(entry)
            publishFrames()
            refreshPublishedNodes()
            return
        }

        runtime.liveProfileOutputBlockName = block.name
        let preferredID = runtime.selectedLiveProfileIndex
            ?? runtime.profileSession.currentID ?? runtime.source.profileIndex
        let steps = block.profiles.map { profile in
            ProfileStep(id: profile.index, label: "\(profile.name) · \(profile.time)",
                sourceTime: profile.time)
        }
        let selectedID = preferredID.flatMap { requested in
            steps.contains(where: { $0.id == requested }) ? requested : nil
        }
        let sourceID = liveProfileSourceID(entry: entry, outputBlockName: block.name)
        let context = MapProfileContext(projectSessionID: profileProjectSessionID ?? UUID(),
            mapID: UUID(uuidString: configuredSnapshot?.map.mapID ?? "") ?? UUID(), sourceID: sourceID)
        let presentation = MapProfilePresentation(sourceID: sourceID,
            steps: steps, selectedID: selectedID)
        let availability = block.errorMessage.map(L10n.text)
            ?? timeline?.metadataError.map(L10n.text)
            ?? L10n.text("Waiting for the active Result output to become available.")
        do {
            if isSameRun && runtime.profileSession.isMetadataOnly {
                try runtime.profileSession.replaceMetadataOnlySteps(presentation,
                    context: context, availabilityMessage: availability)
            } else {
                try runtime.profileSession.configureMetadataOnly(presentation,
                    context: context, availabilityMessage: availability)
                runtime.profileSession.didChooseMetadataOnlyProfile = { [weak self, weak runtime] index, context in
                    guard let self, let runtime else { return }
                    self.chooseLiveProfile(index, context: context, runtime: runtime)
                }
            }
        } catch {
            runtime.unavailableReason = L10n.text(error.localizedDescription)
        }
        runtime.unavailableReason = liveComputeUnavailableMessage(entry)
        if let selected = runtime.profileSession.currentID { runtime.selectedLiveProfileIndex = selected }
        publishFrames()
        refreshPublishedNodes()
        liveRenderTargetsDidChange?()
    }

    private func installMetadataOnlyTimeline(runtime: NodeRuntime,
                                             entry: WorkspaceResultComputeEntry?,
                                             outputBlock: LiveMapResultOutputBlock?,
                                             timeline: LiveMapResultProfileTimeline?,
                                             unavailableMessage: String? = nil) {
        let sourceID = entry.map { liveProfileSourceID(entry: $0,
            outputBlockName: outputBlock?.name ?? "unresolved") }
            ?? "live-selection|\(runtime.id)"
        let mapID = UUID(uuidString: configuredSnapshot?.map.mapID ?? "") ?? UUID()
        let context = MapProfileContext(projectSessionID: profileProjectSessionID ?? UUID(),
            mapID: mapID, sourceID: sourceID)
        let presentation = MapProfilePresentation(sourceID: sourceID, steps: [], selectedID: nil)
        let message = unavailableMessage ?? timeline?.metadataError.map(L10n.text)
            ?? L10n.text("Live profile metadata is not available for this Result yet.")
        do {
            try runtime.profileSession.configureMetadataOnly(presentation,
                context: context, availabilityMessage: message)
            runtime.profileSession.didChooseMetadataOnlyProfile = { [weak self, weak runtime] index, context in
                guard let self, let runtime else { return }
                self.chooseLiveProfile(index, context: context, runtime: runtime)
            }
        } catch {
            runtime.unavailableReason = L10n.text(error.localizedDescription)
        }
    }

    private func chooseLiveProfile(_ index: Int, context: MapProfileContext,
                                   runtime: NodeRuntime) {
        guard runtime.profileSession.isMetadataOnly,
              runtimeByID[runtime.id] === runtime,
              context.projectSessionID == profileProjectSessionID,
              UUID(uuidString: configuredSnapshot?.map.mapID ?? "") == context.mapID,
              let entry = runtime.liveComputeEntry,
              let capture = runtime.liveComputeCapture,
              LiveMapResultRunIdentity(entry: entry).matches(capture),
              runtime.profileSession.steps.contains(where: { $0.id == index }),
              let blockName = runtime.liveProfileOutputBlockName else { return }
        runtime.selectedLiveProfileIndex = index
        pendingLiveProfileSelections[runtime.id] = (entry, capture, blockName, index, context.mapID)
        refreshPublishedNodes()
        liveRenderTargetsDidChange?()
    }

    private func liveProfileSourceID(entry: WorkspaceResultComputeEntry,
                                     outputBlockName: String) -> String {
        "\(entry.runID)|\(SourceFilePaths.canonical(URL(fileURLWithPath: entry.resultPath)))|\(outputBlockName)"
    }

    private func liveComputeUnavailableMessage(_ entry: WorkspaceResultComputeEntry) -> String {
        switch entry.status {
        case .running:
            L10n.text("Waiting for the active Result output to become available.")
        case .completed:
            L10n.text("The compute completed; waiting for a stable Result revision before loading map data.")
        case .failed:
            L10n.text("The compute failed; checking whether its exact Result output has a stable readable revision.")
        case .cancelled:
            L10n.text("The compute was cancelled; checking whether its exact Result output has a stable readable revision.")
        case .unknown:
            L10n.text("The Result has no confirmed stable revision; map raster data is unavailable.")
        }
    }
}
