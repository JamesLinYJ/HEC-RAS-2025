import Combine
import Foundation
import RASWorkspaceCore

/// A separate instance belongs to each MapState. It never consults the
/// workspace's active-map selection and only installs a frame for its exact
/// saved-map/tree identity and current viewport generation.
@MainActor
final class AssociatedMapLayerSession: ObservableObject {
    typealias CurrentCheck = @MainActor () -> Bool

    @Published private(set) var entries: [AssociatedMapLayerState] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var preflightDiagnostics: [String] = []
    @Published private(set) var renderRevision: UInt64 = 0
    /// Changes only when the visible source set or its finite source bounds
    /// change. Camera fitting can observe this without reacting to each frame.
    @Published private(set) var sourceExtentRevision: UInt64 = 0

    private var map: MapTreeMapIdentity?
    private var workflowIdentity: String?
    private var captures: [AssociatedMapLayerCapture] = []
    private var rasterRuntimeOptions: [AssociatedMapLayerRasterRuntimeOption] = []
    private var provider: (any AssociatedMapLayerProvider)?
    private var currentCheck: CurrentCheck?
    private var viewport: RasterMapViewExtent?
    private var mapContextToken: String?
    private var generation: UInt64 = 0
    private var refreshTask: Task<Void, Never>?
    private var viewportTask: Task<Void, Never>?
    private var bootstrapTask: Task<Void, Never>?
    private var bootstrapAttemptedConfigurationIdentity: String?
    private struct SourceBoundsObservation: Equatable {
        let sourceRevision: String
        let extent: MapGeometryViewport?
    }
    private var sourceExtentsByIdentity: [String: SourceBoundsObservation] = [:]
    private var sourceExtentConfigurationIdentity: String?

    /// RasMap.RebuildRenderLayers reverses enabled tree order, then performs
    /// a stable kind sort: Terrain, Classification, NValue. Keep `entries`
    /// untouched for source identity and response validation; only the paint
    /// list receives the retained render order.
    var visibleLayers: [MapRasterLayer] {
        entries.enumerated()
            .sorted { lhs, rhs in
                let leftOrder = Self.renderOrder(lhs.element.capture.associationNode.associationKind)
                let rightOrder = Self.renderOrder(rhs.element.capture.associationNode.associationKind)
                return leftOrder == rightOrder ? lhs.offset > rhs.offset : leftOrder < rightOrder
            }
            .compactMap { $0.element.rasterLayer }
    }
    var visiblePoints: [MapPoint] { visibleLayers.flatMap(\.points) }
    /// Stable camera bounds supplied by the retained source objects. These do
    /// not use pixel raster corners, so panning cannot feed the current
    /// viewport back into its own fit calculation.
    var sourceReferencePoints: [MapPoint] {
        captures.compactMap { capture -> MapGeometryViewport? in
            guard capture.isChecked, capture.effectiveVisible else { return nil }
            return sourceExtentsByIdentity[capture.sourceExtentIdentity]?.extent
        }.flatMap { extent in
            [MapPoint(x: extent.minX, y: extent.minY), MapPoint(x: extent.maxX, y: extent.maxY)]
        }
    }
    var visibleLayerCount: Int { visibleLayers.count }
    var isConfigured: Bool { map != nil && workflowIdentity != nil }
    var hasUnavailableLayers: Bool {
        !preflightDiagnostics.isEmpty || entries.contains { state in
            guard let status = state.status else { return false }
            return status == .unavailable || status == .failed
        }
    }
    var hasLayerStatusMessages: Bool {
        entries.contains { $0.status != nil && $0.status != .available }
    }
    var legends: [AssociatedMapLayerLegend] {
        entries.compactMap { state in
            guard let payload = state.payload, payload.status == .available,
                  payload.isChecked, payload.effectiveVisible, !payload.legend.isEmpty else { return nil }
            return AssociatedMapLayerLegend(id: state.id,
                name: state.capture.associationNode.nodeName,
                kind: payload.kind, values: payload.legend)
        }
    }

    func configure(map: MapTreeMapIdentity, workflowIdentity: String,
                   captures: [AssociatedMapLayerCapture],
                   provider: any AssociatedMapLayerProvider,
                   isCurrent: @escaping CurrentCheck,
                   preflightDiagnostics: [String] = [],
                   rasterRuntimeOptions: [AssociatedMapLayerRasterRuntimeOption] = []) async {
        updateSourceExtentConfiguration(map: map, workflowIdentity: workflowIdentity,
            captures: captures)
        let changed = self.map != map || self.workflowIdentity != workflowIdentity
            || self.captures != captures || self.preflightDiagnostics != preflightDiagnostics
            || self.rasterRuntimeOptions != rasterRuntimeOptions
        if changed {
            cancelPendingWork()
            mapContextToken = nil
            errorMessage = nil
            entries = captures.map { AssociatedMapLayerState(capture: $0, payload: nil, viewport: nil) }
            renderRevision &+= 1
        }
        self.map = map
        self.workflowIdentity = workflowIdentity
        self.captures = captures
        self.rasterRuntimeOptions = rasterRuntimeOptions
        self.provider = provider
        currentCheck = isCurrent
        self.preflightDiagnostics = preflightDiagnostics

        guard !captures.isEmpty else {
            isLoading = false
            return
        }
        guard viewport != nil else { return }
        await refresh()
    }

    func setRasterRuntimeOptions(_ options: [AssociatedMapLayerRasterRuntimeOption]) {
        let selected = options.filter { option in captures.contains { option.matches($0) } }
        guard selected != rasterRuntimeOptions else { return }
        cancelPendingWork()
        rasterRuntimeOptions = selected
        mapContextToken = nil
        errorMessage = nil
        entries = captures.map { AssociatedMapLayerState(capture: $0, payload: nil, viewport: nil) }
        renderRevision &+= 1
    }

    func invalidate() {
        cancelPendingWork()
        clearSourceExtentConfiguration()
        map = nil
        workflowIdentity = nil
        captures = []
        rasterRuntimeOptions = []
        provider = nil
        currentCheck = nil
        viewport = nil
        mapContextToken = nil
        entries = []
        errorMessage = nil
        preflightDiagnostics = []
        isLoading = false
        renderRevision &+= 1
    }

    func reportConfigurationError(_ message: String) {
        cancelPendingWork()
        clearSourceExtentConfiguration()
        map = nil
        workflowIdentity = nil
        captures = []
        provider = nil
        currentCheck = nil
        viewport = nil
        mapContextToken = nil
        entries = []
        errorMessage = message
        preflightDiagnostics = []
        isLoading = false
        renderRevision &+= 1
    }

    func updateViewport(_ next: RasterMapViewExtent?) async {
        guard viewport != next else { return }
        viewport = next
        generation &+= 1
        bootstrapTask?.cancel()
        bootstrapTask = nil
        refreshTask?.cancel()
        refreshTask = nil
        viewportTask?.cancel()
        viewportTask = nil
        isLoading = false
        errorMessage = nil
        // The Host context token binds viewport bounds and raster dimensions;
        // carrying it into a pan/zoom would make the next valid frame stale.
        mapContextToken = nil
        entries = captures.map { AssociatedMapLayerState(capture: $0, payload: nil, viewport: nil) }
        renderRevision &+= 1

        guard let next, Self.validViewport(next), !captures.isEmpty,
              map != nil, provider != nil, currentCheck?() == true else { return }
        let requestedGeneration = generation
        viewportTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(120)) }
            catch { return }
            guard let self, !Task.isCancelled,
                  self.generation == requestedGeneration else { return }
            self.viewportTask = nil
            await self.load(generation: requestedGeneration)
        }
    }

    func refresh() async {
        guard let viewport, Self.validViewport(viewport), !captures.isEmpty,
              map != nil, provider != nil, currentCheck?() == true else { return }
        generation &+= 1
        let requestedGeneration = generation
        bootstrapTask?.cancel()
        bootstrapTask = nil
        viewportTask?.cancel()
        viewportTask = nil
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            await self?.load(generation: requestedGeneration)
        }
        await refreshTask?.value
    }

    /// Loads real source bounds when no other visible map source can establish
    /// an initial camera. The bounded seed frame is metadata-only: its pixels,
    /// viewport and context token are never installed into the map session.
    func bootstrapSourceExtents() async {
        guard viewport == nil, sourceReferencePoints.isEmpty, isConfigured,
              let map, let workflowIdentity, let provider, let currentCheck,
              currentCheck(), let configurationIdentity = sourceExtentConfigurationIdentity,
              captures.contains(where: { $0.isChecked && $0.effectiveVisible }) else { return }
        if let bootstrapTask {
            await bootstrapTask.value
            return
        }
        guard bootstrapAttemptedConfigurationIdentity != configurationIdentity else { return }

        generation &+= 1
        let requestedGeneration = generation
        let selectedCaptures = captures
        refreshTask?.cancel()
        refreshTask = nil
        viewportTask?.cancel()
        viewportTask = nil
        isLoading = true
        errorMessage = nil
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.loadBootstrap(generation: requestedGeneration, map: map,
                workflowIdentity: workflowIdentity, configurationIdentity: configurationIdentity,
                captures: selectedCaptures, provider: provider, currentCheck: currentCheck)
        }
        bootstrapTask = task
        await task.value
        if generation == requestedGeneration {
            bootstrapTask = nil
            isLoading = false
        }
    }

    private func load(generation requestedGeneration: UInt64) async {
        guard generation == requestedGeneration,
              let map, let workflowIdentity, let viewport, let provider,
              let currentCheck, currentCheck(), Self.validViewport(viewport),
              !captures.isEmpty else { return }
        let selectedCaptures = captures
        let request: AssociatedMapLayersRequest
        guard let mapViewport = MapGeometryViewport(rasterExtent: viewport) else {
            errorMessage = "The current map viewport is invalid."
            isLoading = false
            return
        }
        let owners = Self.requestOwners(for: selectedCaptures)
        request = AssociatedMapLayersRequest(
            map: map,
            geometryNodes: owners.geometryNodes,
            planNodes: owners.planNodes,
            resultOwners: owners.resultOwners,
            associationNodes: selectedCaptures.map(\.associationNode),
            viewport: mapViewport,
            width: viewport.pixelWidth,
            height: viewport.pixelHeight,
            contextToken: mapContextToken, rasterRuntimeOptions: rasterRuntimeOptions)

        isLoading = true
        errorMessage = nil
        do {
            let snapshot = try await provider.load(request, captures: selectedCaptures)
            guard generation == requestedGeneration,
                  self.map == map, self.workflowIdentity == workflowIdentity,
                  self.captures == selectedCaptures else { return }
            guard currentCheck(), !Task.isCancelled else {
                discardFrameForStaleContext(selectedCaptures)
                return
            }
            if let expectedToken = mapContextToken, expectedToken != snapshot.contextToken {
                throw AssociatedMapLayerError.sourceChanged
            }
            mapContextToken = snapshot.contextToken
            let payloadByLocator = Dictionary(uniqueKeysWithValues: snapshot.layers.map { ($0.locator, $0) })
            installSourceExtents(from: payloadByLocator, captures: selectedCaptures)
            entries = selectedCaptures.map { capture in
                AssociatedMapLayerState(capture: capture,
                    payload: payloadByLocator[capture.associationNode], viewport: snapshot.viewport)
            }
            renderRevision &+= 1
        } catch is CancellationError {
            guard generation == requestedGeneration else { return }
            isLoading = false
            if !currentCheck() { discardFrameForStaleContext(selectedCaptures) }
            return
        } catch {
            guard generation == requestedGeneration,
                  self.map == map, self.workflowIdentity == workflowIdentity,
                  self.captures == selectedCaptures else { return }
            guard currentCheck() else {
                discardFrameForStaleContext(selectedCaptures)
                return
            }
            entries = selectedCaptures.map { AssociatedMapLayerState(capture: $0, payload: nil, viewport: nil) }
            renderRevision &+= 1
            mapContextToken = nil
            errorMessage = error.localizedDescription
        }
        guard generation == requestedGeneration else { return }
        isLoading = false
    }

    private func loadBootstrap(generation requestedGeneration: UInt64,
                               map: MapTreeMapIdentity,
                               workflowIdentity: String,
                               configurationIdentity: String,
                               captures selectedCaptures: [AssociatedMapLayerCapture],
                               provider: any AssociatedMapLayerProvider,
                               currentCheck: CurrentCheck) async {
        guard generation == requestedGeneration, viewport == nil,
              self.map == map, self.workflowIdentity == workflowIdentity,
              self.captures == selectedCaptures,
              sourceExtentConfigurationIdentity == configurationIdentity,
              currentCheck(), !Task.isCancelled else { return }

        let owners = Self.requestOwners(for: selectedCaptures)
        // The source extent is independent of the requested pixels. A small
        // finite seed lets the retained service return that metadata even
        // when the real map has no existing fit points.
        let seedViewport = MapGeometryViewport(minX: 0, minY: 0, maxX: 1, maxY: 1)
        let request = AssociatedMapLayersRequest(map: map,
            geometryNodes: owners.geometryNodes,
            planNodes: owners.planNodes,
            resultOwners: owners.resultOwners,
            associationNodes: selectedCaptures.map(\.associationNode),
            viewport: seedViewport, width: 1, height: 1, contextToken: nil,
            rasterRuntimeOptions: rasterRuntimeOptions)

        do {
            let snapshot = try await provider.load(request, captures: selectedCaptures)
            guard generation == requestedGeneration, viewport == nil,
                  self.map == map, self.workflowIdentity == workflowIdentity,
                  self.captures == selectedCaptures,
                  sourceExtentConfigurationIdentity == configurationIdentity else { return }
            guard currentCheck(), !Task.isCancelled else {
                discardFrameForStaleContext(selectedCaptures)
                return
            }
            let payloadByLocator = Dictionary(uniqueKeysWithValues: snapshot.layers.map { ($0.locator, $0) })
            installSourceExtents(from: payloadByLocator, captures: selectedCaptures)
            bootstrapAttemptedConfigurationIdentity = configurationIdentity
            let diagnostics = snapshot.layers
                .filter { $0.status == .unavailable || $0.status == .failed }
                .compactMap(\.diagnostic)
                .filter { !$0.isEmpty }
            if !diagnostics.isEmpty { errorMessage = diagnostics.joined(separator: "\n") }
        } catch is CancellationError {
            guard generation == requestedGeneration else { return }
        } catch {
            guard generation == requestedGeneration,
                  self.map == map, self.workflowIdentity == workflowIdentity,
                  self.captures == selectedCaptures,
                  sourceExtentConfigurationIdentity == configurationIdentity else { return }
            guard currentCheck() else {
                discardFrameForStaleContext(selectedCaptures)
                return
            }
            errorMessage = error.localizedDescription
        }
        guard generation == requestedGeneration else { return }
        isLoading = false
    }

    private func cancelPendingWork() {
        generation &+= 1
        bootstrapTask?.cancel()
        bootstrapTask = nil
        refreshTask?.cancel()
        refreshTask = nil
        viewportTask?.cancel()
        viewportTask = nil
        isLoading = false
    }

    private func updateSourceExtentConfiguration(map: MapTreeMapIdentity,
                                                 workflowIdentity: String,
                                                 captures: [AssociatedMapLayerCapture]) {
        let ownerChanged = self.map != map || self.workflowIdentity != workflowIdentity
        if ownerChanged { sourceExtentsByIdentity.removeAll(keepingCapacity: true) }
        else {
            let currentSources = Set(captures.map(\.sourceExtentIdentity))
            sourceExtentsByIdentity = sourceExtentsByIdentity.filter { currentSources.contains($0.key) }
        }

        let cameraSources = captures.filter { $0.isChecked && $0.effectiveVisible }
            .map(\.sourceExtentIdentity)
        let identity = [workflowIdentity, map.mapID, String(map.mapIndex), map.mapName,
            map.mapType, map.projectPath, map.projectXmlSHA,
            map.expectedVisualizationRevision,
            cameraSources.map { "\($0.utf8.count):\($0)" }.joined()]
            .map { "\($0.utf8.count):\($0)" }.joined()
        guard sourceExtentConfigurationIdentity != identity else { return }
        sourceExtentConfigurationIdentity = identity
        bootstrapAttemptedConfigurationIdentity = nil
        sourceExtentRevision &+= 1
    }

    private func clearSourceExtentConfiguration() {
        let hadCameraState = sourceExtentConfigurationIdentity != nil || !sourceExtentsByIdentity.isEmpty
        sourceExtentsByIdentity.removeAll(keepingCapacity: false)
        sourceExtentConfigurationIdentity = nil
        bootstrapAttemptedConfigurationIdentity = nil
        if hadCameraState { sourceExtentRevision &+= 1 }
    }

    private func installSourceExtents(
        from payloadByLocator: [CatalogTreeNodeLocator: AssociatedMapLayerPayload],
        captures: [AssociatedMapLayerCapture]
    ) {
        var didChange = false
        for capture in captures where capture.isChecked && capture.effectiveVisible {
            guard let payload = payloadByLocator[capture.associationNode] else { continue }
            let identity = capture.sourceExtentIdentity
            let previous = sourceExtentsByIdentity[identity]
            let extent: MapGeometryViewport?
            if let responseExtent = payload.sourceExtent {
                guard Self.validSourceExtent(responseExtent) else { continue }
                extent = responseExtent
            } else if previous?.sourceRevision == payload.revision {
                // Viewport-local empty pages do not erase bounds already
                // established for the same immutable source revision.
                extent = previous?.extent
            } else {
                // A new source revision with no finite extent (for example an
                // infinite constant NValue) invalidates the old source bounds.
                extent = nil
            }
            let next = SourceBoundsObservation(sourceRevision: payload.revision, extent: extent)
            if previous?.extent != next.extent
                || (previous != nil && previous?.sourceRevision != next.sourceRevision) {
                didChange = true
            }
            sourceExtentsByIdentity[identity] = next
        }
        if didChange { sourceExtentRevision &+= 1 }
    }

    private func discardFrameForStaleContext(_ selectedCaptures: [AssociatedMapLayerCapture]) {
        entries = selectedCaptures.map { AssociatedMapLayerState(capture: $0, payload: nil, viewport: nil) }
        mapContextToken = nil
        errorMessage = "The selected saved map changed before associated layers could be loaded."
        isLoading = false
        renderRevision &+= 1
    }

    private static func validViewport(_ value: RasterMapViewExtent) -> Bool {
        [value.minX, value.minY, value.maxX, value.maxY].allSatisfy(\.isFinite)
            && value.minX < value.maxX && value.minY < value.maxY
            && value.pixelWidth > 0 && value.pixelHeight > 0
            && !value.pixelWidth.multipliedReportingOverflow(by: value.pixelHeight).overflow
    }

    private static func validSourceExtent(_ value: MapGeometryViewport) -> Bool {
        value.hasFinitePositiveArea
    }

    private static func renderOrder(_ rawKind: String?) -> Int {
        switch AssociatedMapLayerCapture.supportedKind(rawKind) {
        case .terrain: 0
        case .classification: 1
        case .nValue: 2
        case nil: Int.max
        }
    }

    private static func requestOwners(
        for captures: [AssociatedMapLayerCapture]
    ) -> (geometryNodes: [CatalogTreeNodeLocator],
          planNodes: [CatalogTreeNodeLocator],
          resultOwners: [MapResultGeometryOwner]) {
        var geometryNodes: [CatalogTreeNodeLocator] = []
        var planNodes: [CatalogTreeNodeLocator] = []
        var resultOwners: [MapResultGeometryOwner] = []
        var ownerIDs: Set<String> = []
        for capture in captures {
            for node in capture.geometryNodes where !geometryNodes.contains(node) {
                geometryNodes.append(node)
            }
            for node in capture.planNodes where !planNodes.contains(node) {
                planNodes.append(node)
            }
            for owner in capture.resultOwners where ownerIDs.insert(owner.identity).inserted {
                resultOwners.append(owner)
            }
        }
        return (geometryNodes, planNodes, resultOwners)
    }
}
