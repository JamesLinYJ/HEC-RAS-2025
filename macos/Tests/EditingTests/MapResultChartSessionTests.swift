import CryptoKit
import Foundation
import Testing
import RASWorkspaceCore
@testable import HECRAS2025

@MainActor
private final class ControlledMapResultChartProvider: MapResultChartProvider {
    private(set) var sourceRequests: [(map: MapResultChartMapRequest, overrides: [MapResultSelectionOverride])] = []
    private(set) var selectionRequests: [(map: MapResultChartMapRequest, token: String,
        current: [MapResultSelectionOverride], requested: [MapResultSelectionOverride])] = []
    private(set) var computeRequests: [MapResultChartSampleLineRequest] = []
    private var sourceContinuations: [Int: CheckedContinuation<MapResultChartSources, any Error>] = [:]
    private var selectionContinuations: [Int: CheckedContinuation<MapResultChartSources, any Error>] = [:]
    private var computeContinuations: [Int: CheckedContinuation<MapResultChartSeries, any Error>] = [:]
    private(set) var computeProgress: [Int: @Sendable (BackendProgressUpdate) -> Void] = [:]

    func loadSources(map: MapResultChartMapRequest,
                     selectionOverrides: [MapResultSelectionOverride]) async throws -> MapResultChartSources {
        sourceRequests.append((map, selectionOverrides))
        let request = sourceRequests.count
        return try await withCheckedThrowingContinuation { sourceContinuations[request] = $0 }
    }

    func selectSources(map: MapResultChartMapRequest, expectedContextToken: String,
                       currentSelectionOverrides: [MapResultSelectionOverride],
                       selectionOverrides: [MapResultSelectionOverride]) async throws -> MapResultChartSources {
        selectionRequests.append((map, expectedContextToken, currentSelectionOverrides, selectionOverrides))
        let request = selectionRequests.count
        return try await withCheckedThrowingContinuation { selectionContinuations[request] = $0 }
    }

    func compute(_ request: MapResultChartSampleLineRequest,
                 progress: @escaping @Sendable (BackendProgressUpdate) -> Void) async throws -> MapResultChartSeries {
        computeRequests.append(request)
        let index = computeRequests.count
        computeProgress[index] = progress
        return try await withCheckedThrowingContinuation { computeContinuations[index] = $0 }
    }

    func finishSources(_ index: Int, with value: MapResultChartSources) {
        sourceContinuations.removeValue(forKey: index)?.resume(returning: value)
    }

    func finishSelection(_ index: Int, with value: MapResultChartSources) {
        selectionContinuations.removeValue(forKey: index)?.resume(returning: value)
    }

    func finishCompute(_ index: Int, with value: MapResultChartSeries) {
        computeContinuations.removeValue(forKey: index)?.resume(returning: value)
    }
}

@MainActor
private final class MapResultChartCurrentState {
    var isCurrent: Bool

    init(_ isCurrent: Bool = true) {
        self.isCurrent = isCurrent
    }
}

private enum MapResultChartTestData {
    static let mapID = UUID(uuidString: "CA5DB39A-1D3C-4804-A1FA-5F85FD7AC9A1")!
    static let projectPath = "/tmp/map-result-chart/model.ras"
    static let projectXML = "<Project><Map name=\"Chart\" /></Project>"
    static let vectorPath = "/tmp/map-result-chart/lines.geojson"
    static let vectorRevision = String(repeating: "A", count: 64)
    static let visualizationRevision = String(repeating: "B", count: 64)
    static let projectRevision = String(repeating: "C", count: 64)
    static let primaryPath = "/tmp/map-result-chart/Run 2.h5"
    static let previousPath = "/tmp/map-result-chart/Run 1.h5"
    static let primaryRevision = String(repeating: "D", count: 64)
    static let previousRevision = String(repeating: "E", count: 64)

    static func mapRequest() -> MapResultChartMapRequest {
        .init(projectPath: projectPath, projectXml: projectXML,
            projectXmlSHA: digest(Data(projectXML.utf8)), mapID: mapID.uuidString,
            mapIndex: 2, mapName: "Map Chart", mapType: "Plan",
            expectedVisualizationRevision: visualizationRevision)
    }

    static func capture() throws -> MapResultChartLineCapture {
        try .init(projectSessionID: UUID(uuidString: "AFD32C4B-4B8C-4F82-8AD5-10BFB3A95353")!,
            mapID: mapID, projectPath: URL(fileURLWithPath: projectPath), projectXML: projectXML,
            mapIndex: 2, mapName: "Map Chart", mapType: "Plan",
            visualizationRevision: visualizationRevision, layerID: vectorPath,
            vectorPath: URL(fileURLWithPath: vectorPath), vectorRevision: vectorRevision,
            stableFeatureIdentity: "geojson-id:string:feature-9|feature[0].geometry:coordinates[0]",
            coordinates: [.init(x: 0.25, y: 0.5), .init(x: 1.75, y: 0.5)], draftGeneration: "line-draft-7")
    }

    static let nodeA = CatalogTreeNodeLocator(rootName: "Results", nodeType: "MultiResult",
        nodeName: "Plan A", nodePath: [0, 2], assetID: "multi-a", mapType: "Depth")
    static let nodeB = CatalogTreeNodeLocator(rootName: "Results", nodeType: "MultiResult",
        nodeName: "Plan B", nodePath: [0, 3], assetID: "multi-b", mapType: "Depth")

    static let latest = MapResultChartSourceChoice(resultPath: primaryPath,
        revision: primaryRevision, resultName: "Run 2", planName: "Plan A",
        endTime: "2026-10-16T02:00:00Z", isComputing: false)
    static let previous = MapResultChartSourceChoice(resultPath: previousPath,
        revision: previousRevision, resultName: "Run 1", planName: "Plan A",
        endTime: "2026-10-15T02:00:00Z", isComputing: false)

    static func activeNode(_ locator: CatalogTreeNodeLocator = nodeA,
                           selections: [MapResultChartSelectionSlot]? = nil) -> MapResultChartActiveNode {
        .init(node: locator, nodeKind: "MultiResult", name: locator.nodeName,
            selections: selections ?? [
                .init(selectionIndex: 0, selectionMode: .latest,
                    selectedResult: latest, choices: [latest, previous]),
                .init(selectionIndex: 1, selectionMode: .previous,
                    selectedResult: previous, choices: [latest, previous])
            ], selectedMapType: "Depth", profileIndex: 0)
    }

    static func sources(map: MapResultChartMapRequest? = nil, token: String = "sources-token",
                        nodes: [MapResultChartActiveNode]? = nil) -> MapResultChartSources {
        let map = map ?? mapRequest()
        return .init(projectPath: map.projectPath, projectRevision: projectRevision,
            mapID: map.mapID, mapIndex: map.mapIndex, mapName: map.mapName, mapType: map.mapType,
            projectXmlSHA: map.projectXmlSHA, visualizationRevision: map.expectedVisualizationRevision,
            contextToken: token, activeNodes: nodes ?? [activeNode()])
    }

    static func sampleResponse(context: MapResultChartContext, snapshot: MapResultSourcesSnapshot,
                               selections: [MapResultChartSelectionIdentity],
                               resultPath: String = primaryPath,
                               revision: String = primaryRevision,
                               mode: MapResultChartMode = .flow,
                               feature: MapResultFeatureIdentity? = nil,
                               points: [ResultProfileSampleLinePoint] = []) -> MapResultChartSeries {
        .init(projectPath: context.projectPath,
            projectRevision: snapshot.sources.projectRevision,
            projectXmlSHA: context.projectXMLSHA, mapID: context.mapID.uuidString,
            mapIndex: context.mapIndex, mapName: context.mapName, mapType: context.mapType,
            visualizationRevision: context.visualizationRevision,
            contextToken: snapshot.sources.contextToken,
            featureContextToken: context.expectedFeatureContextToken(
                contextToken: snapshot.sources.contextToken, mode: mode),
            feature: feature ?? .init(vectorPath: context.vectorPath, vectorRevision: context.vectorRevision,
                featureID: context.stableFeatureIdentity, coordinateSHA: context.coordinateSHA),
            mode: mode.rawValue, sampleLine: context.sampleLine,
            series: [.init(selections: selections, selectedMapType: "Depth", profileIndex: 0,
                series: .init(resultPath: resultPath, revision: revision, resultName: "Run 2",
                    mode: mode.rawValue, quantity: mode == .flow ? "Flow" : "Volume", units: mode == .flow ? "m³/s" : "m³",
                    available: true, unavailableReason: nil, points: points))])
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02X", $0) }.joined()
    }
}

@Suite(.serialized)
struct MapResultChartSessionTests {
    @Test @MainActor
    func sourceSessionCarriesFullMultiResultSlotOverridesAndRejectsStaleReplies() async throws {
        let provider = ControlledMapResultChartProvider()
        let session = MapResultSourcesSession(provider: provider)
        let map = MapResultChartTestData.mapRequest()
        let currentState = MapResultChartCurrentState()
        session.configure(map: map, identity: "map-session-1",
            selectionOverrides: [], isCurrent: { currentState.isCurrent })
        let firstLoad = Task { await session.loadSources() }
        try await waitForMapResultChart { provider.sourceRequests.count == 1 }
        #expect(provider.sourceRequests[0].map == map)
        #expect(provider.sourceRequests[0].overrides.isEmpty)

        session.configure(map: map, identity: "map-session-2",
            selectionOverrides: [], isCurrent: { currentState.isCurrent })
        provider.finishSources(1, with: MapResultChartTestData.sources(map: map))
        #expect(await firstLoad.value == false)
        #expect(session.sources == nil, "A response from a replaced map session must not install.")

        let secondLoad = Task { await session.loadSources() }
        try await waitForMapResultChart { provider.sourceRequests.count == 2 }
        let original = MapResultChartTestData.sources(map: map, token: "fresh-token")
        provider.finishSources(2, with: original)
        #expect(await secondLoad.value == true)
        #expect(session.snapshot?.sources.contextToken == "fresh-token")

        let nextSlots = [
            MapResultChartSelectionSlot(selectionIndex: 0, selectionMode: .latest,
                selectedResult: MapResultChartTestData.latest,
                choices: [MapResultChartTestData.latest, MapResultChartTestData.previous]),
            MapResultChartSelectionSlot(selectionIndex: 1, selectionMode: .latest,
                selectedResult: MapResultChartTestData.latest,
                choices: [MapResultChartTestData.latest, MapResultChartTestData.previous])
        ]
        let updated = MapResultChartTestData.sources(map: map, token: "next-token",
            nodes: [MapResultChartTestData.activeNode(selections: nextSlots)])
        let selection = Task {
            await session.setSelection(nodeID: updated.activeNodes[0].id,
                selectionIndex: 1, mode: .explicit, choice: MapResultChartTestData.latest)
        }
        try await waitForMapResultChart { provider.selectionRequests.count == 1 }
        let request = provider.selectionRequests[0]
        #expect(request.token == "fresh-token")
        #expect(request.current.isEmpty)
        #expect(request.requested.count == 2)
        #expect(request.requested.map(\.selectionIndex).sorted() == [0, 1])
        #expect(request.requested[0].mode == .latest)
        #expect(request.requested[1].mode == .explicit)
        #expect(request.requested[1].resultPath == MapResultChartTestData.latest.resultPath)
        provider.finishSelection(1, with: updated)
        await selection.value
        #expect(session.selectionOverrides.count == 2)
        #expect(session.selectionOverrides[1].mode == .latest,
            "Selecting the current latest Result follows the source tracking behavior.")
        #expect(session.selectionOverrides[1].resultPath == nil)
        #expect(session.snapshot?.sources.contextToken == "next-token")
        currentState.isCurrent = false
        session.invalidate()
        #expect(session.snapshot == nil)
    }

    @Test @MainActor
    func liveComputeSelectionKeepsPreviousAndAddSemanticsWhileTheWriterIsActive() async throws {
        let provider = ControlledMapResultChartProvider()
        let session = MapResultSourcesSession(provider: provider)
        let map = MapResultChartTestData.mapRequest()
        let capture = try MapResultChartTestData.capture()
        let planPath = "/tmp/map-result-chart/Plan A.p02"
        let nodeLocator = CatalogTreeNodeLocator(rootName: "Results", nodeType: "MultiResult",
            nodeName: "Plan A", nodePath: [0, 0], assetID: planPath, mapType: "Depth")
        let node = MapResultChartTestData.activeNode(nodeLocator, selections: [
            .init(selectionIndex: 0, selectionMode: .latest,
                selectedResult: MapResultChartTestData.latest,
                choices: [MapResultChartTestData.latest, MapResultChartTestData.previous])
        ])
        let projectSessionID = capture.projectSessionID
        session.configure(map: map, identity: "map-session-live", projectSessionID: projectSessionID,
            selectionOverrides: [], canReadSource: { !session.isComputeLeaseActive },
            isCurrent: { true })
        let load = Task { await session.loadSources() }
        try await waitForMapResultChart { provider.sourceRequests.count == 1 }
        provider.finishSources(1, with: MapResultChartTestData.sources(map: map, nodes: [node]))
        #expect(await load.value)

        let runID = "F67C4F88-671C-42C7-8DA0-DBDE94069D71"
        let captureToken = WorkspaceResultComputeCapture(projectSessionID: projectSessionID,
            editorID: UUID(uuidString: "1A6D5C90-6B5E-4D93-894A-3C897393E7A5")!,
            operationOwnerToken: "owner-live", operationContextID: "context-live",
            projectPath: MapResultChartTestData.projectPath, projectRevision: "project-revision",
            projectXmlFingerprint: map.projectXmlSHA, planPath: planPath, planRevision: "plan-revision")
        session.beginPlanCompute(captureToken)
        let live = liveEntry(runID: runID, capture: captureToken,
            resultPath: "/tmp/map-result-chart/Plan A live.h5", revision: nil, status: .running)
        session.acceptPlanComputeEntry(live)
        #expect(session.selectedLiveEntry(nodeID: node.id, selectionIndex: 0)?.runID == runID)

        await session.addSelection(nodeID: node.id)
        let firstAddition = session.displayNode(node).selections
        #expect(firstAddition.count == 2)
        #expect(firstAddition[1].selectionMode == .previous,
            "When the first unselected effective option is the source Previous, Add must keep tracking Previous.")
        #expect(firstAddition[1].selectedResult?.resultPath == MapResultChartTestData.primaryPath,
            "With the live Result at Latest, the cached old Latest is the source Previous.")
        await session.addSelection(nodeID: node.id)
        let slots = session.displayNode(node).selections
        #expect(slots.count == 3)
        #expect(slots[2].selectionMode == .explicit)
        #expect(slots[2].selectedResult?.resultPath == MapResultChartTestData.previousPath,
            "Older unselected stored results remain explicit after Previous is already selected.")

        await session.removeSelection(nodeID: node.id, selectionIndex: 2)
        await session.setSelection(nodeID: node.id, selectionIndex: 0, mode: .explicit,
            choice: MapResultChartTestData.previous)
        await session.addSelection(nodeID: node.id)
        let afterAddingUnselectedActive = session.displayNode(node).selections
        #expect(afterAddingUnselectedActive[2].selectionMode == .latest,
            "Add tracks Latest when its first effective option is the active Result.")
        #expect(session.selectedLiveEntry(nodeID: node.id, selectionIndex: 2)?.runID == runID)

        let nextCapture = WorkspaceResultComputeCapture(projectSessionID: projectSessionID,
            editorID: captureToken.editorID, operationOwnerToken: "owner-next-live",
            operationContextID: "context-next-live", projectPath: captureToken.projectPath,
            projectRevision: captureToken.projectRevision,
            projectXmlFingerprint: captureToken.projectXmlFingerprint,
            planPath: captureToken.planPath, planRevision: captureToken.planRevision)
        session.beginPlanCompute(nextCapture)
        let nextLive = liveEntry(runID: "6A1A1E40-5AA2-4287-AFC9-594E04C3B3EE",
            capture: nextCapture, resultPath: "/tmp/map-result-chart/Plan A next-live.h5",
            revision: nil, status: .running)
        session.acceptPlanComputeEntry(nextLive)
        #expect(session.selectedStoredChoice(nodeID: node.id, selectionIndex: 1)?.resultPath
            == MapResultChartTestData.primaryPath,
            "The Previous slot advances to the cached Latest when a later run becomes active.")
        #expect(session.selectedLiveEntry(nodeID: node.id, selectionIndex: 2)?.runID == nextLive.runID,
            "The Latest slot follows the next exact active run.")
        session.endPlanCompute(nextCapture)
    }

    @Test @MainActor
    func chartSendsCapturedLineAndSourceSlotsAndPlotsOnlyReturnedStoredValues() async throws {
        let provider = ControlledMapResultChartProvider()
        let capture = try MapResultChartTestData.capture()
        let context = MapResultChartContext(capture: capture)
        let nodeA = MapResultChartTestData.activeNode(MapResultChartTestData.nodeA,
            selections: [.init(selectionIndex: 0, selectionMode: .explicit,
                selectedResult: MapResultChartTestData.latest,
                choices: [MapResultChartTestData.latest])])
        let nodeB = MapResultChartTestData.activeNode(MapResultChartTestData.nodeB,
            selections: [.init(selectionIndex: 0, selectionMode: .explicit,
                selectedResult: MapResultChartTestData.latest,
                choices: [MapResultChartTestData.latest])])
        let sources = MapResultChartTestData.sources(map: context.mapRequest, nodes: [nodeA, nodeB])
        let snapshot = MapResultSourcesSnapshot(map: context.mapRequest, identity: "captured-map",
            sources: sources, selectionOverrides: [])
        let session = MapResultChartSession(context: context, sourceSnapshot: snapshot,
            mode: .flow, provider: provider, isCurrent: { true })
        let compute = Task { await session.compute() }
        try await waitForMapResultChart { provider.computeRequests.count == 1 }
        let request = provider.computeRequests[0]
        #expect(request.map == context.mapRequest)
        #expect(request.contextToken == sources.contextToken)
        #expect(request.sampleLine == capture.coordinates)
        #expect(request.feature.vectorPath == capture.vectorPath)
        #expect(request.feature.vectorRevision == capture.vectorRevision)
        #expect(request.feature.featureID == capture.stableFeatureIdentity)
        #expect(request.feature.coordinateSHA == context.coordinateSHA)

        let pairs = [nodeA, nodeB].map {
            MapResultChartSelectionIdentity(node: $0.node, selectionIndex: 0)
        }
        let reply = MapResultChartTestData.sampleResponse(context: context, snapshot: snapshot,
            selections: pairs, points: [
                .init(profileIndex: 0, time: "2026-10-16T00:00:00.0000000", value: 1.25),
                .init(profileIndex: 1, time: "2026-10-16T00:01:00.0000000", value: nil)
            ])
        provider.finishCompute(1, with: reply)
        await compute.value
        #expect(session.result?.series.count == 1)
        let loadedResult = try #require(session.result)
        let samples = MapResultChartData.samples(for: loadedResult)
        #expect(samples.count == 2)
        #expect(samples[0].y == 1.25)
        #expect(samples[1].y.isNaN, "A stored null stays a chart gap rather than a fabricated value.")
        session.close()
    }

    @Test @MainActor
    func invalidatedWindowCancelsAndIgnoresLateBackendReply() async throws {
        let provider = ControlledMapResultChartProvider()
        let context = MapResultChartContext(capture: try MapResultChartTestData.capture())
        let node = MapResultChartTestData.activeNode(selections: [
            .init(selectionIndex: 0, selectionMode: .explicit,
                selectedResult: MapResultChartTestData.latest,
                choices: [MapResultChartTestData.latest])
        ])
        let sources = MapResultChartTestData.sources(map: context.mapRequest, nodes: [node])
        let snapshot = MapResultSourcesSnapshot(map: context.mapRequest, identity: "map-line-identity",
            sources: sources, selectionOverrides: [])
        let lineState = MapResultChartCurrentState()
        let session = MapResultChartSession(context: context, sourceSnapshot: snapshot,
            mode: .cumulativeVolume, provider: provider, isCurrent: { lineState.isCurrent })
        let compute = Task { await session.compute() }
        try await waitForMapResultChart { provider.computeRequests.count == 1 }
        #expect(provider.computeRequests[0].mode == MapResultChartMode.cumulativeVolume.rawValue)
        lineState.isCurrent = false
        session.invalidate()
        let late = MapResultChartTestData.sampleResponse(context: context, snapshot: snapshot,
            selections: [.init(node: node.node, selectionIndex: 0)], mode: .cumulativeVolume)
        provider.finishCompute(1, with: late)
        await compute.value
        #expect(session.result == nil)
        #expect(session.isStale)
        #expect(session.errorMessage != nil)
    }

    @Test @MainActor
    func cumulativeVolumeChartUsesBackendValuesAndUnits() async throws {
        let provider = ControlledMapResultChartProvider()
        let context = MapResultChartContext(capture: try MapResultChartTestData.capture())
        let node = MapResultChartTestData.activeNode(selections: [
            .init(selectionIndex: 0, selectionMode: .explicit,
                selectedResult: MapResultChartTestData.latest,
                choices: [MapResultChartTestData.latest])
        ])
        let sources = MapResultChartTestData.sources(map: context.mapRequest, nodes: [node])
        let snapshot = MapResultSourcesSnapshot(map: context.mapRequest, identity: "captured-map",
            sources: sources, selectionOverrides: [])
        let session = MapResultChartSession(context: context, sourceSnapshot: snapshot,
            mode: .cumulativeVolume, provider: provider, isCurrent: { true })
        let compute = Task { await session.compute() }
        try await waitForMapResultChart { provider.computeRequests.count == 1 }
        #expect(provider.computeRequests[0].mode == "CumulativeVolume")
        let reply = MapResultChartTestData.sampleResponse(context: context, snapshot: snapshot,
            selections: [.init(node: node.node, selectionIndex: 0)], mode: .cumulativeVolume,
            points: [
                .init(profileIndex: 0, time: "2026-10-16T00:00:00.0000000", value: 0.0),
                .init(profileIndex: 1, time: "2026-10-16T00:01:00.0000000", value: 3.75)
            ])
        provider.finishCompute(1, with: reply)
        await compute.value
        let loaded = try #require(session.result)
        #expect(loaded.series[0].series.quantity == "Volume")
        #expect(loaded.series[0].series.units == "m³")
        let samples = MapResultChartData.samples(for: loaded)
        #expect(samples.map(\.y) == [0.0, 3.75],
            "The chart presents values returned by the source calculation without integrating them again.")
        session.close()
    }

    @Test @MainActor
    func chartRejectsReplyForAnotherStableMapFeature() async throws {
        let provider = ControlledMapResultChartProvider()
        let context = MapResultChartContext(capture: try MapResultChartTestData.capture())
        let node = MapResultChartTestData.activeNode(selections: [
            .init(selectionIndex: 0, selectionMode: .explicit,
                selectedResult: MapResultChartTestData.latest,
                choices: [MapResultChartTestData.latest])
        ])
        let sources = MapResultChartTestData.sources(map: context.mapRequest, nodes: [node])
        let snapshot = MapResultSourcesSnapshot(map: context.mapRequest, identity: "captured-map",
            sources: sources, selectionOverrides: [])
        let session = MapResultChartSession(context: context, sourceSnapshot: snapshot,
            mode: .flow, provider: provider, isCurrent: { true })
        let compute = Task { await session.compute() }
        try await waitForMapResultChart { provider.computeRequests.count == 1 }

        let wrongFeature = MapResultFeatureIdentity(vectorPath: context.vectorPath,
            vectorRevision: context.vectorRevision, featureID: "different-source-feature",
            coordinateSHA: context.coordinateSHA)
        let reply = MapResultChartTestData.sampleResponse(context: context, snapshot: snapshot,
            selections: [.init(node: node.node, selectionIndex: 0)], feature: wrongFeature)
        provider.finishCompute(1, with: reply)
        await compute.value
        #expect(session.result == nil)
        #expect(session.errorMessage != nil)
    }

    @MainActor
    private func waitForMapResultChart(_ predicate: () -> Bool) async throws {
        for _ in 0..<250 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        throw CocoaError(.fileReadUnknown, userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for a controlled map-result chart request."])
    }

    private func liveEntry(runID: String, capture: WorkspaceResultComputeCapture,
                           resultPath: String, revision: String?,
                           status: WorkspaceResultComputeStatus) -> WorkspaceResultComputeEntry {
        WorkspaceResultComputeEntry(runID: runID, projectSessionID: capture.projectSessionID,
            editorID: capture.editorID, operationOwnerToken: capture.operationOwnerToken,
            operationContextID: capture.operationContextID, projectPath: capture.projectPath,
            projectRevision: capture.projectRevision,
            projectXmlFingerprint: capture.projectXmlFingerprint, planPath: capture.planPath,
            planRevision: capture.planRevision, resultPath: resultPath,
            resultName: "Plan A live", resultRevision: revision, status: status,
            fraction: status == .running ? 0.4 : 1, message: nil,
            taskName: nil, failureReason: nil)
    }
}
