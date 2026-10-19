import Foundation
import RASWorkspaceCore

/// A profile provider whose scope is one exact, active .vis Result or
/// MultiResult node. A MultiResult request returns every selected slot for
/// that node; it never changes another node's timeline or overlay.
@MainActor
final class BackendMapResultRenderProvider: ProfileProvider {
    typealias ViewportLookup = @MainActor () -> RasterMapViewExtent?

    struct Prepared {
        let presentation: MapProfilePresentation
        let provider: BackendMapResultRenderProvider
        let initial: MapResultRenderResult
        let renderedViewport: RasterMapViewExtent?
        let initialUpdate: MapUpdate
    }

    private let client: BackendProcessClient
    private let map: MapResultChartMapRequest
    private let selectionOverrides: [MapResultSelectionOverride]
    private let sources: MapResultChartSources
    private let node: MapResultChartActiveNode
    private let viewport: ViewportLookup
    private let blockedSelectionIndices: [Int]
    private let liveKeyframeTimeline: MapResultRenderLiveKeyframeTimeline?
    fileprivate let mapID: UUID
    private let expectedResultRevisions: [String: String]
    private var expectedTerrainFingerprints: [String: TerrainFingerprint] = [:]
    private let sourceID: String
    private let profileStepsByID: [Int: MapResultRenderStep]
    private var warmResponse: MapResultRenderResult?
    private var warmViewport: RasterMapViewExtent?
    private(set) var availabilityReason: String?
    private(set) var sourceStatuses: [MapResultRenderSourceStatus]
    private(set) var currentLegends: [MapLegend]

    private struct TerrainFingerprint: Equatable {
        let path: String
        let revision: String
    }

    private init(client: BackendProcessClient, map: MapResultChartMapRequest,
                selectionOverrides: [MapResultSelectionOverride], sources: MapResultChartSources,
                node: MapResultChartActiveNode, mapID: UUID,
                viewport: @escaping ViewportLookup, initialViewport: RasterMapViewExtent?,
                initial: MapResultRenderResult, blockedSelectionIndices: [Int],
                liveKeyframeTimeline: MapResultRenderLiveKeyframeTimeline?) {
        self.client = client
        self.map = map
        self.selectionOverrides = selectionOverrides
        self.sources = sources
        self.node = node
        self.mapID = mapID
        self.viewport = viewport
        self.blockedSelectionIndices = blockedSelectionIndices
        self.liveKeyframeTimeline = liveKeyframeTimeline
        sourceID = MapResultSelectionOverride(node: node.node, mode: .latest).nodeIdentity
        profileStepsByID = (liveKeyframeTimeline?.profiles.map {
            MapResultRenderStep(id: $0.index, label: $0.name, time: $0.time)
        } ?? initial.steps).reduce(into: [:]) { $0[$1.id] = $1 }
        expectedResultRevisions = node.selections.reduce(into: [:]) { revisions, slot in
            guard !blockedSelectionIndices.contains(slot.selectionIndex) else { return }
            guard let selected = slot.selectedResult else { return }
            revisions[Self.canonical(selected.resultPath)] = selected.revision
        }
        warmResponse = initial
        warmViewport = initialViewport
        availabilityReason = Self.availabilityReason(for: initial)
        sourceStatuses = initial.sources
        currentLegends = Self.legends(for: initial)
    }

    static func prepare(client: BackendProcessClient? = nil,
                        map: MapResultChartMapRequest,
                        selectionOverrides: [MapResultSelectionOverride],
                        sources: MapResultChartSources,
                        node: MapResultChartActiveNode,
                        mapID: UUID,
                        viewport: @escaping ViewportLookup,
                        blockedSelectionIndices: Set<Int> = [],
                        liveKeyframeTimeline: MapResultRenderLiveKeyframeTimeline? = nil) async throws -> Prepared {
        let backend = client ?? BackendProcessClient(executableURL: Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/Backend/HECRASBackend"))
        guard UUID(uuidString: map.mapID) == mapID,
              sources.mapID == map.mapID,
              sources.mapIndex == map.mapIndex,
              sources.mapName == map.mapName,
              sources.mapType == map.mapType,
              sources.projectXmlSHA == map.projectXmlSHA,
              sources.visualizationRevision == map.expectedVisualizationRevision,
              !sources.contextToken.isEmpty,
              sources.activeNodes.contains(where: { $0.id == node.id }) else {
            throw BackendServiceError(code: "sourceChanged", message: L10n.text("The selected result map context changed. Refresh the map tree before rendering."))
        }

        let blockedIndices = blockedSelectionIndices.sorted()
        guard blockedIndices.count <= 32,
              blockedIndices.allSatisfy({ (0..<32).contains($0) }),
              Set(blockedIndices).count == blockedIndices.count else {
            throw BackendServiceError(code: "invalidInput",
                message: L10n.text("The result render reply no longer matches the selected map node or profile."))
        }
        if let liveKeyframeTimeline {
            guard blockedIndices.contains(0), node.nodeKind == "MultiResult",
                  liveKeyframeTimeline.node == node.node,
                  !liveKeyframeTimeline.runID.isEmpty,
                  !liveKeyframeTimeline.resultPath.isEmpty,
                  !liveKeyframeTimeline.outputBlockName.isEmpty,
                  liveKeyframeTimeline.profileCount >= 0,
                  let lease = map.computeReadLease,
                  lease.runID.caseInsensitiveCompare(liveKeyframeTimeline.runID) == .orderedSame,
                  let callbackPath = lease.callbackResultPath,
                  Self.canonical(callbackPath) == Self.canonical(liveKeyframeTimeline.resultPath),
                  lease.canonicalProtectedSourcePaths.contains(Self.canonical(liveKeyframeTimeline.resultPath)),
                  Set(liveKeyframeTimeline.profiles.map(\.index)).count == liveKeyframeTimeline.profiles.count,
                  liveKeyframeTimeline.profiles.allSatisfy({ $0.index >= 0
                    && $0.index < liveKeyframeTimeline.profileCount
                    && !$0.name.isEmpty && !$0.time.isEmpty }) else {
                throw BackendServiceError(code: "sourceChanged",
                    message: L10n.text("The result render reply no longer matches the selected map node or profile."))
            }
        }

        let firstViewport = viewport()
        let request = MapResultRenderRequest(map: map, selectionOverrides: selectionOverrides,
            contextToken: sources.contextToken, node: node.node,
            profileIndex: node.profileIndex, viewport: firstViewport,
            blockedSelectionIndices: blockedIndices,
            liveKeyframeAnchor: liveKeyframeTimeline.flatMap { timeline in
                timeline.anchor(for: node.profileIndex ?? 0)
            })
        let initial = try await backend.request("map.resultRender", parameters: request, as: MapResultRenderResult.self)
        let provider = BackendMapResultRenderProvider(client: backend, map: map,
            selectionOverrides: selectionOverrides, sources: sources, node: node,
            mapID: mapID, viewport: viewport, initialViewport: firstViewport, initial: initial,
            blockedSelectionIndices: blockedIndices, liveKeyframeTimeline: liveKeyframeTimeline)
        try provider.validate(initial, requestedProfileIndex: node.profileIndex)

        let sourceSteps = liveKeyframeTimeline?.profiles.map {
            MapResultRenderStep(id: $0.index, label: $0.name, time: $0.time)
        } ?? initial.steps
        let steps = sourceSteps.map { step in
            ProfileStep(id: step.id, label: step.label, date: Self.sourceDate(step.time),
                sourceTime: step.time)
        }
        let preferredProfile = liveKeyframeTimeline == nil
            ? initial.selectedProfileIndex : node.profileIndex
        let selectedID = preferredProfile.flatMap { requested in
            steps.contains(where: { $0.id == requested }) ? requested : nil
        }
        if !steps.isEmpty && selectedID == nil {
            throw BackendServiceError(code: "protocolFailure", message: L10n.text("The result renderer returned a profile outside the source timeline."))
        }
        let presentation = MapProfilePresentation(sourceID: initial.sourceID,
            steps: steps, selectedID: selectedID)
        return Prepared(presentation: presentation, provider: provider, initial: initial,
            renderedViewport: firstViewport, initialUpdate: try initial.mapUpdate(expectedMapID: mapID))
    }

    func selectProfile(_ index: Int) async throws -> MapUpdate {
        guard sources.activeNodes.contains(where: { $0.id == node.id }),
              node.selections.contains(where: { $0.selectedResult != nil }),
              !expectedResultRevisions.isEmpty else {
            throw BackendServiceError(code: "sourceChanged", message: L10n.text("The selected result is no longer active on this map."))
        }

        if let warmResponse, warmResponse.selectedProfileIndex == index,
           warmViewport == viewport() {
            self.warmResponse = nil
            warmViewport = nil
            return try warmResponse.mapUpdate(expectedMapID: mapID)
        }

        let currentViewport = viewport()
        let request = MapResultRenderRequest(map: map, selectionOverrides: selectionOverrides,
            contextToken: sources.contextToken, node: node.node,
            profileIndex: index, viewport: currentViewport,
            blockedSelectionIndices: blockedSelectionIndices,
            liveKeyframeAnchor: liveKeyframeTimeline?.anchor(for: index))
        let result = try await client.request("map.resultRender", parameters: request, as: MapResultRenderResult.self)
        try validate(result, requestedProfileIndex: index)
        availabilityReason = Self.availabilityReason(for: result)
        sourceStatuses = result.sources
        currentLegends = Self.legends(for: result)
        return try result.mapUpdate(expectedMapID: mapID)
    }

    func sampleVelocityField(requestID: String, profileIndex: Int,
                             viewport: RasterMapViewExtent) async throws -> MapResultVelocityGrid {
        guard node.selectedMapType == "Velocity",
              sources.activeNodes.contains(where: { $0.id == node.id && $0.node == node.node }),
              let keyframe = node.selections.first(where: { $0.selectionIndex == 0 })?.selectedResult,
              expectedResultRevisions[Self.canonical(keyframe.resultPath)] == keyframe.revision,
              let step = profileStepsByID[profileIndex],
              viewport.minX.isFinite, viewport.minY.isFinite,
              viewport.maxX.isFinite, viewport.maxY.isFinite,
              viewport.minX < viewport.maxX, viewport.minY < viewport.maxY,
              viewport.pixelWidth > 0, viewport.pixelHeight > 0 else {
            throw BackendServiceError(code: "sourceChanged",
                message: L10n.text("The selected map has no stable Velocity Result profile to sample."))
        }
        guard let rasterViewport = MapVelocityRasterGeometry.boundedViewport(viewport) else {
            throw BackendServiceError(code: "invalidInput",
                message: L10n.text("The current map viewport cannot be sampled as a Velocity field."))
        }
        let request = MapResultVelocityFieldRequest(map: map,
            selectionOverrides: selectionOverrides, contextToken: sources.contextToken,
            node: node.node, requestID: requestID,
            expectedResultPath: keyframe.resultPath,
            expectedResultRevision: keyframe.revision,
            profileIndex: profileIndex, viewport: rasterViewport)
        let response = try await client.request("map.resultVelocityField",
            parameters: request, as: MapResultVelocityFieldResponse.self)
        let expectation = MapResultVelocityFieldExpectation(requestID: requestID,
            contextToken: sources.contextToken, sourceID: sourceID, mapID: map.mapID,
            node: node.node, resultPath: keyframe.resultPath,
            resultRevision: keyframe.revision, profileIndex: profileIndex,
            profileName: step.label, time: step.time, viewport: viewport)
        let grid = try response.makeGrid(expected: expectation)
        let sourcePath = Self.canonical(keyframe.resultPath)
        guard let terrainPath = grid.terrainPath, !terrainPath.isEmpty,
              let terrainRevision = grid.terrainRevision,
              terrainRevision.utf8.count == 64,
              terrainRevision.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else {
            throw BackendServiceError(code: "protocolFailure",
                message: L10n.text("The velocity field reply has an invalid terrain revision."))
        }
        let terrain = TerrainFingerprint(path: Self.canonical(terrainPath), revision: terrainRevision)
        if let expectedTerrain = expectedTerrainFingerprints[sourcePath], expectedTerrain != terrain {
            throw BackendServiceError(code: "sourceChanged",
                message: L10n.text("The associated terrain changed while sampling Result velocity."))
        }
        if let status = sourceStatuses.first(where: { Self.canonical($0.resultPath) == sourcePath }),
           let expectedTerrainPath = status.terrainPath,
           let expectedTerrainRevision = status.terrainRevision,
           (Self.canonical(expectedTerrainPath) != terrain.path || expectedTerrainRevision != terrain.revision) {
            throw BackendServiceError(code: "sourceChanged",
                message: L10n.text("The associated terrain changed while sampling Result velocity."))
        }
        expectedTerrainFingerprints[sourcePath] = terrain
        return grid
    }

    private static func availabilityReason(for result: MapResultRenderResult) -> String? {
        result.unavailableReason ?? result.sources.first(where: { !$0.available })?.unavailableReason
    }

    private static func legends(for result: MapResultRenderResult) -> [MapLegend] {
        result.layers.map { layer in
            let count = layer.legendStops.count
            let stops = layer.legendStops.enumerated().map { index, stop in
                MapLegend.Stop(id: "\(layer.id)|\(index)",
                    position: count <= 1 ? 1 : Double(index) / Double(count - 1),
                    color: stop.color,
                    label: stop.value.formatted(.number.precision(.significantDigits(1...4))))
            }
            return MapLegend(id: layer.id, title: layer.resultName + " · " + layer.mapType,
                units: layer.units, stops: stops)
        }
    }

    private func validate(_ result: MapResultRenderResult, requestedProfileIndex: Int?) throws {
        guard result.contextToken == sources.contextToken,
              result.sourceID == sourceID,
              (requestedProfileIndex == nil || result.selectedProfileIndex == requestedProfileIndex),
              Set(result.steps.map(\.id)).count == result.steps.count else {
            throw BackendServiceError(code: "sourceChanged", message: L10n.text("The result render reply no longer matches the selected map node or profile."))
        }
        var sourceByPath: [String: MapResultRenderSourceStatus] = [:]
        for source in result.sources {
            let path = Self.canonical(source.resultPath)
            guard expectedResultRevisions[path] == source.revision,
                  sourceByPath[path] == nil else {
                throw BackendServiceError(code: "sourceChanged", message: L10n.text("The result render reply no longer matches an active source result."))
            }
            sourceByPath[path] = source

            if let terrainPath = source.terrainPath, let terrainRevision = source.terrainRevision {
                let fingerprint = TerrainFingerprint(path: Self.canonical(terrainPath), revision: terrainRevision)
                if let expected = expectedTerrainFingerprints[path], expected != fingerprint {
                    throw BackendServiceError(code: "sourceChanged", message: L10n.text("The associated terrain changed while rendering result profiles. Reload the result map."))
                }
                expectedTerrainFingerprints[path] = fingerprint
            } else if source.terrainPath != nil || source.terrainRevision != nil {
                throw BackendServiceError(code: "protocolFailure", message: L10n.text("The result renderer returned incomplete terrain source identity."))
            }
        }
        guard Set(sourceByPath.keys) == Set(expectedResultRevisions.keys) else {
            throw BackendServiceError(code: "sourceChanged", message: L10n.text("The result renderer returned a different set of active source results."))
        }

        for layer in result.layers {
            let path = Self.canonical(layer.resultPath)
            guard expectedResultRevisions[path] == layer.revision,
                  let source = sourceByPath[path],
                  source.available,
                  source.terrainPath.map(Self.canonical) == Self.canonical(layer.terrainPath),
                  source.terrainRevision == layer.terrainRevision,
                  layer.sourceID == sourceID,
                  layer.profileIndex >= 0,
                  source.profileIndex == layer.profileIndex else {
                throw BackendServiceError(code: "sourceChanged", message: L10n.text("The result render reply no longer matches an active source result."))
            }
        }
    }

    private static func sourceDate(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.isLenient = false
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.fffffff"
        return formatter.date(from: value)
    }

    private static func canonical(_ path: String) -> String {
        SourceFilePaths.canonical(URL(fileURLWithPath: path))
    }

}

@MainActor
final class BackendMapWindVelocityFieldProvider {
    private let client: BackendProcessClient

    init(client: BackendProcessClient? = nil) {
        self.client = client ?? BackendProcessClient(executableURL: Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/Backend/HECRASBackend"))
    }

    func sample(source: MapWindVelocityParticleSource, requestID: String,
                profileIndex: Int, viewport: RasterMapViewExtent,
                expectedProfileTime: String? = nil) async throws -> MapResultVelocityGrid {
        guard !requestID.isEmpty, profileIndex >= 0,
              source.boundaryNode.nodeType == "BoundaryCondition",
              source.windNode.nodeType == "WindLayer",
              source.contextToken.isEmpty == false,
              UUID(uuidString: source.map.mapID) != nil,
              SourceFilePaths.canonical(URL(fileURLWithPath: source.boundaryPath)).hasPrefix("/") else {
            throw BackendServiceError(code: "invalidInput",
                message: L10n.text("The selected Wind map source is missing its exact boundary identity."))
        }
        guard let rasterViewport = MapVelocityRasterGeometry.boundedViewport(viewport) else {
            throw BackendServiceError(code: "invalidInput",
                message: L10n.text("The current map viewport cannot be sampled as a Wind velocity field."))
        }
        let request = MapWindVelocityFieldRequest(map: source.map,
            boundaryNode: source.boundaryNode, windNode: source.windNode,
            expectedBoundaryPath: source.boundaryPath,
            expectedBoundaryRevision: source.boundaryRevision,
            contextToken: source.contextToken, requestID: requestID,
            profileIndex: profileIndex,
            expectedProfileTime: expectedProfileTime, viewport: rasterViewport)
        let response = try await client.request("map.windVelocityField", parameters: request,
            as: MapWindVelocityFieldResponse.self)
        let expectation = MapWindVelocityFieldExpectation(requestID: requestID,
            contextToken: source.contextToken, sourceID: source.windNode.sourceIdentity,
            mapID: source.map.mapID, boundaryNode: source.boundaryNode,
            windNode: source.windNode,
            boundaryPath: source.boundaryPath, boundaryRevision: source.boundaryRevision,
            profileIndex: profileIndex, profileTime: expectedProfileTime,
            spatialDataType: nil, viewport: viewport)
        return try response.makeGrid(expected: expectation)
    }
}
