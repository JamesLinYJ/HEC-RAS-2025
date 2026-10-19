import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

@MainActor
private final class MapResultMapViewportBox {
    var extent: RasterMapViewExtent?
}

@MainActor
private final class MapResultMapPreparedIndexCapture {
    var values: [(String, Int?)] = []
}

@MainActor
private final class DeferredMapProfileProvider: ProfileProvider {
    struct Request {
        let index: Int
        let viewport: RasterMapViewExtent?
    }

    private let viewport: MapResultMapSession.ViewportLookup
    private(set) var requests: [Request] = []
    private var continuations: [Int: CheckedContinuation<MapUpdate, any Error>] = [:]

    init(viewport: @escaping MapResultMapSession.ViewportLookup) {
        self.viewport = viewport
    }

    func selectProfile(_ index: Int) async throws -> MapUpdate {
        requests.append(Request(index: index, viewport: viewport()))
        let requestID = requests.count
        return try await withCheckedThrowingContinuation { continuation in
            continuations[requestID] = continuation
        }
    }

    func finish(_ requestID: Int, layer: MapRasterLayer) {
        continuations.removeValue(forKey: requestID)?.resume(returning:
            MapUpdate(vectors: nil, rasters: [layer], preview: [],
                selectedLayerID: nil, selectedFeatureID: nil))
    }
}

@MainActor
private final class ImmediateMapProfileProvider: ProfileProvider {
    private let mapID: UUID
    init(mapID: UUID) { self.mapID = mapID }

    func selectProfile(_ index: Int) async throws -> MapUpdate {
        let layer = try MapRasterLayer(id: "profile-\(index)", name: "Profile \(index)",
            width: 1, height: 1, rgba: Data([20, 30, 40, 255]),
            lowerLeft: MapPoint(x: 0, y: 0), upperRight: MapPoint(x: 1, y: 1),
            sourceMapID: mapID)
        return MapUpdate(vectors: nil, rasters: [layer], preview: [],
            selectedLayerID: nil, selectedFeatureID: nil)
    }
}

@MainActor
private final class FixedMapOwnershipProfileProvider: ProfileProvider {
    private let update: MapUpdate
    init(update: MapUpdate) { self.update = update }
    func selectProfile(_ index: Int) async throws -> MapUpdate { update }
}

@MainActor
private final class SlotOwnedMapProfileProvider: ProfileProvider {
    private let mapID: UUID
    private let choice: MapResultChartSourceChoice
    private let selectionIndex: Int
    private let idPrefix: String
    private(set) var requestedIndices: [Int] = []

    init(mapID: UUID, choice: MapResultChartSourceChoice,
         selectionIndex: Int, idPrefix: String) {
        self.mapID = mapID
        self.choice = choice
        self.selectionIndex = selectionIndex
        self.idPrefix = idPrefix
    }

    func selectProfile(_ index: Int) async throws -> MapUpdate {
        requestedIndices.append(index)
        let id = "\(idPrefix)-profile-\(index)"
        let layer = try MapRasterLayer(id: id, name: id, width: 1, height: 1,
            rgba: Data([20, 30, 40, 255]), lowerLeft: MapPoint(x: 0, y: 0),
            upperRight: MapPoint(x: 1, y: 1), sourceMapID: mapID)
        return MapUpdate(vectors: nil, rasters: [layer], preview: [],
            selectedLayerID: nil, selectedFeatureID: nil,
            rasterSelectionIndicesByLayerID: [id: [selectionIndex]],
            rasterSourceIdentityByLayerID: [id: MapRasterSourceIdentity(
                resultPath: choice.resultPath, revision: choice.revision)])
    }
}

@Suite(.serialized)
struct MapResultMapSessionTests {
    @Test @MainActor
    func liveMultiResultMetadataOwnsOnlySlotZeroAndRestoresItsSelectedSourceProfile() async throws {
        let projectSessionID = UUID(uuidString: "1E29D408-4055-4B77-8B89-7A6E2413B8E0")!
        let mapID = UUID(uuidString: "CA5DB39A-1D3C-4804-A1FA-5F85FD7AC9A1")!
        let planPath = "/tmp/map-result-map/Plan CPU.p02"
        let runPath = "/tmp/map-result-map/Plan CPU live.hdf"
        let map = MapResultChartMapRequest(projectPath: "/tmp/map-result-map/model.ras",
            projectXml: "<Project><Map name=\"Map\" /></Project>", projectXmlSHA: "project-sha",
            mapID: mapID.uuidString, mapIndex: 0, mapName: "Map", mapType: "Plan",
            expectedVisualizationRevision: "vis-1")
        let liveNode = CatalogTreeNodeLocator(rootName: "Results", nodeType: "MultiResult",
            nodeName: "Plan CPU", nodePath: [0, 0], assetID: planPath, mapType: "WSE")
        let otherNode = CatalogTreeNodeLocator(rootName: "Results", nodeType: "MultiResult",
            nodeName: "Plan Other", nodePath: [0, 1], assetID: "/tmp/map-result-map/Plan Other.p02", mapType: "Depth")
        let oldChoice = MapResultChartSourceChoice(resultPath: "/tmp/map-result-map/old.hdf",
            revision: "old-revision", resultName: "Old", planName: "Plan CPU",
            endTime: nil, isComputing: false)
        func makeNode(_ locator: CatalogTreeNodeLocator, profileIndex: Int? = 0,
                      selected: MapResultChartSourceChoice? = nil,
                      choices: [MapResultChartSourceChoice] = []) -> MapResultChartActiveNode {
            MapResultChartActiveNode(node: locator, nodeKind: "MultiResult", name: locator.nodeName,
                selections: [.init(selectionIndex: 0, selectionMode: .latest,
                    selectedResult: selected ?? oldChoice, choices: choices.isEmpty ? [oldChoice] : choices)],
                selectedMapType: locator.mapType, profileIndex: profileIndex)
        }
        func makeSnapshot(contextToken: String, activeNodes: [MapResultChartActiveNode]) -> MapResultSourcesSnapshot {
            let sources = MapResultChartSources(projectPath: map.projectPath,
                projectRevision: "project-revision", mapID: map.mapID, mapIndex: map.mapIndex,
                mapName: map.mapName, mapType: map.mapType, projectXmlSHA: map.projectXmlSHA,
                visualizationRevision: map.expectedVisualizationRevision,
                contextToken: contextToken, activeNodes: activeNodes)
            return MapResultSourcesSnapshot(map: map, identity: projectSessionID.uuidString + "|map|sources",
                sources: sources, selectionOverrides: [])
        }

        let initialSnapshot = makeSnapshot(contextToken: "before-compute",
            activeNodes: [makeNode(liveNode, choices: [oldChoice]), makeNode(otherNode)])
        let viewport = MapResultMapViewportBox()
        viewport.extent = extent(0)
        let preparedNodeProfileIndices = MapResultMapPreparedIndexCapture()
        let session = MapResultMapSession(prepareNode: { request in
            preparedNodeProfileIndices.values.append((request.node.id, request.node.profileIndex))
            let provider = ImmediateMapProfileProvider(mapID: request.mapID)
            let preparedSource = request.node.selections.first?.selectedResult ?? oldChoice
            let steps = [ProfileStep(id: 0, label: "source profile 0"),
                ProfileStep(id: 1, label: "source profile 1")]
            let presentation = MapProfilePresentation(sourceID: request.node.id,
                steps: steps, selectedID: request.node.profileIndex ?? 0)
            let layer = try MapRasterLayer(id: request.node.name + "-prepared-" + String(request.node.profileIndex ?? 0),
                name: request.node.name, width: 1, height: 1, rgba: Data([10, 20, 30, 255]),
                lowerLeft: MapPoint(x: 0, y: 0), upperRight: MapPoint(x: 1, y: 1),
                sourceMapID: request.mapID)
            return MapResultMapSession.PreparedNode(presentation: presentation,
                provider: provider,
                initialUpdate: MapUpdate(vectors: nil, rasters: [layer], preview: [],
                    selectedLayerID: nil, selectedFeatureID: nil,
                    rasterSelectionIndicesByLayerID: [layer.id: [0]],
                    rasterSourceIdentityByLayerID: [layer.id: MapRasterSourceIdentity(
                        resultPath: preparedSource.resultPath, revision: preparedSource.revision)]),
                initialLegends: [], initialUnavailableReason: nil, initialSourceStatuses: [],
                renderedViewport: request.viewport(),
                availability: { MapResultMapAvailability(reason: nil, sourceStatuses: []) })
        })

        session.configure(snapshot: initialSnapshot, projectSessionID: projectSessionID,
            viewport: { viewport.extent }, isCurrent: { true })
        try await waitUntil { !session.isLoading && session.resultLayers.count == 2 }
        let otherInitialLayer = try #require(session.layers(for: otherNode).first)
        let capture = WorkspaceResultComputeCapture(projectSessionID: projectSessionID,
            editorID: UUID(uuidString: "A2B99B75-772D-4BC6-9B03-7D354DD55F80")!,
            operationOwnerToken: "owner-live", operationContextID: "context-live",
            projectPath: map.projectPath, projectRevision: "project-revision",
            projectXmlFingerprint: map.projectXmlSHA, planPath: planPath, planRevision: "plan-revision")
        var live = WorkspaceResultComputeEntry(runID: "73D6596D-0FC3-43E6-87E4-893AC8EB145D",
            projectSessionID: projectSessionID, editorID: capture.editorID,
            operationOwnerToken: capture.operationOwnerToken, operationContextID: capture.operationContextID,
            projectPath: capture.projectPath, projectRevision: capture.projectRevision,
            projectXmlFingerprint: capture.projectXmlFingerprint, planPath: capture.planPath,
            planRevision: capture.planRevision, resultPath: runPath, resultName: "Plan CPU live",
            resultRevision: nil, status: .running, fraction: 0.4, message: nil, taskName: "Solving",
            failureReason: nil)
        var profileMetadata = LiveMapResultProfileTimeline(identity: .init(entry: live))
        let acceptedMetadata = profileMetadata.append(BackendResultProfilesUpdate(outputBlockName: "BaseOutput",
            startIndex: 0, profileCount: 2, profiles: [
                .init(index: 0, name: "T0", time: "2025-01-01T00:00:00"),
                .init(index: 1, name: "T1", time: "2025-01-01T01:00:00")
            ]))
        #expect(acceptedMetadata)
        live.profileTimeline = profileMetadata

        session.beginPlanCompute(capture)
        let liveNodeID = initialSnapshot.sources.activeNodes[0].id
        session.updateLiveComputeSelection(nodeID: liveNodeID,
            selectionIndex: 1, entry: live, timeline: profileMetadata)
        #expect(session.layers(for: liveNode).first != nil,
            "A live selection in a non-keyframe slot must not replace slot-zero map context.")
        session.updateLiveComputeSelection(nodeID: MapResultChartActiveNode(
            node: liveNode, nodeKind: "MultiResult", name: "Plan CPU",
            selections: initialSnapshot.sources.activeNodes[0].selections,
            selectedMapType: "WSE", profileIndex: 0).id,
            selectionIndex: 0, entry: live, timeline: profileMetadata)
        let metadataNode = try #require(session.nodes.first { $0.name == "Plan CPU" })
        #expect(metadataNode.isLiveProfileMetadataOnly)
        #expect(metadataNode.profileCount == 2)
        #expect(session.layers(for: liveNode).isEmpty,
            "The writer-owned HDF cannot provide a live raster frame; only source profile metadata is selectable.")
        #expect(session.layers(for: otherNode).first?.id == otherInitialLayer.id,
            "Starting one Plan compute must retain other Result nodes' accepted frame cache.")
        session.selectNode(metadataNode.id)
        session.selectedTimeline?.select(position: 1)
        #expect(session.selectedTimeline?.currentID == 1)
        let liveTarget = try #require(session.liveMapRenderTargets(capture: capture, entry: live)
            .first { $0.selectionIndex == 0 })
        let targetViewport = liveTarget.viewport
        let liveFrame = PlanComputeLiveMapFrame(targetID: liveTarget.targetID,
            projectSessionID: projectSessionID.uuidString,
            operationOwnerToken: capture.operationOwnerToken,
            operationContextID: capture.operationContextID, runID: live.runID,
            resultPath: live.resultPath, outputBlockName: liveTarget.outputBlockName,
            contextToken: liveTarget.contextToken, mapID: mapID.uuidString,
            nodeID: liveTarget.nodeID, selectionIndex: 0, targetSequence: 1,
            profileIndex: liveTarget.profileIndex, profileName: "T1",
            time: try #require(liveTarget.profileTime), mapType: liveTarget.selectedMapType,
            terrainPath: "/tmp/map-result-map/terrain.h5", terrainRevision: "terrain-revision",
            units: "m", width: targetViewport.pixelWidth, height: targetViewport.pixelHeight,
            rgba: Data(repeating: 255, count: targetViewport.pixelWidth * targetViewport.pixelHeight * 4),
            minX: targetViewport.minX, minY: targetViewport.minY,
            maxX: targetViewport.maxX, maxY: targetViewport.maxY,
            noDataValue: -9999, legendStops: [])
        #expect(session.acceptLiveMapFrame(liveFrame, capture: capture, entry: live))
        #expect(session.layers(for: liveNode).count == 1)
        #expect(session.nodes.first { $0.id == metadataNode.id }?.isLiveProfileMetadataOnly == false)
        #expect(session.selectedTimeline?.availabilityMessage == nil,
            "A real current live raster must retire the old metadata-only availability disclaimer.")
        var viewportPublications = 0
        session.didUpdate = { _, _ in viewportPublications += 1 }
        viewport.extent = extent(10)
        session.viewportChanged()
        #expect(viewportPublications == 1,
            "Viewport changes retire actual live pixels once, independently of the target-owner callback.")
        #expect(session.nodes.first { $0.id == metadataNode.id }?.isLiveProfileMetadataOnly == true)
        #expect(session.selectedTimeline?.availabilityMessage != nil)
        #expect(session.layers(for: liveNode).isEmpty)
        #expect(session.layers(for: otherNode).first?.id == otherInitialLayer.id)
        #expect(!session.acceptLiveMapFrame(liveFrame, capture: capture, entry: live),
            "An old viewport frame cannot return after its targets have been retired.")

        live = WorkspaceResultComputeEntry(runID: live.runID, projectSessionID: live.projectSessionID,
            editorID: live.editorID, operationOwnerToken: live.operationOwnerToken,
            operationContextID: live.operationContextID, projectPath: live.projectPath,
            projectRevision: live.projectRevision, projectXmlFingerprint: live.projectXmlFingerprint,
            planPath: live.planPath, planRevision: live.planRevision, resultPath: live.resultPath,
            resultName: live.resultName, resultRevision: "stable-result-sha", status: .completed,
            fraction: 1, message: nil, taskName: nil, failureReason: nil,
            profileTimeline: profileMetadata)
        session.updateLiveComputeSelection(nodeID: metadataNode.id, selectionIndex: 0,
            entry: live, timeline: profileMetadata)
        session.endPlanCompute(capture)

        let stableChoice = MapResultChartSourceChoice(resultPath: runPath,
            revision: "stable-result-sha", resultName: "Plan CPU live", planName: "Plan CPU",
            endTime: nil, isComputing: false)
        let stableSnapshot = makeSnapshot(contextToken: "stable-result-revision",
            activeNodes: [makeNode(liveNode, profileIndex: 0, selected: stableChoice,
                choices: [stableChoice, oldChoice]), makeNode(otherNode)])
        session.configure(snapshot: stableSnapshot, projectSessionID: projectSessionID,
            viewport: { viewport.extent }, isCurrent: { true })
        try await waitUntil { !session.isLoading && session.resultLayers.count == 2 }
        #expect(preparedNodeProfileIndices.values.contains { $0.0 == metadataNode.id && $0.1 == 1 },
            "The exact path+SHA snapshot must restore the chosen source profile index into preparation.")
        #expect(session.selectedTimeline?.currentID == 1)
        #expect(session.layers(for: liveNode).first?.id == "Plan CPU-prepared-1")
        #expect(session.layers(for: otherNode).count == 1)

        let nextCapture = WorkspaceResultComputeCapture(projectSessionID: projectSessionID,
            editorID: capture.editorID, operationOwnerToken: "owner-live-next",
            operationContextID: "context-live-next", projectPath: capture.projectPath,
            projectRevision: capture.projectRevision,
            projectXmlFingerprint: capture.projectXmlFingerprint,
            planPath: capture.planPath, planRevision: "plan-revision-next")
        var nextLive = WorkspaceResultComputeEntry(runID: "28D44236-4498-4599-8EE5-8712015DFF51",
            projectSessionID: projectSessionID, editorID: nextCapture.editorID,
            operationOwnerToken: nextCapture.operationOwnerToken,
            operationContextID: nextCapture.operationContextID, projectPath: nextCapture.projectPath,
            projectRevision: nextCapture.projectRevision,
            projectXmlFingerprint: nextCapture.projectXmlFingerprint,
            planPath: nextCapture.planPath, planRevision: nextCapture.planRevision,
            resultPath: "/tmp/map-result-map/Plan CPU next.hdf", resultName: "Plan CPU next",
            resultRevision: nil, status: .running, fraction: 0.5, message: nil,
            taskName: "Solving", failureReason: nil)
        var nextProfileMetadata = LiveMapResultProfileTimeline(identity: .init(entry: nextLive))
        let appendedNextProfiles = nextProfileMetadata.append(BackendResultProfilesUpdate(outputBlockName: "BaseOutput",
            startIndex: 0, profileCount: 2, profiles: [
                .init(index: 0, name: "T0", time: "2025-01-02T00:00:00"),
                .init(index: 1, name: "T1", time: "2025-01-02T01:00:00")
            ]))
        #expect(appendedNextProfiles)
        nextLive.profileTimeline = nextProfileMetadata
        session.beginPlanCompute(nextCapture)
        session.updateLiveComputeSelection(nodeID: metadataNode.id, selectionIndex: 0,
            entry: nextLive, timeline: nextProfileMetadata)
        session.selectedTimeline?.select(position: 0)
        session.selectedTimeline?.select(position: 1)
        #expect(session.selectedTimeline?.currentID == 1)

        let nextStableChoice = MapResultChartSourceChoice(
            resultPath: nextLive.resultPath, revision: "next-stable-sha",
            resultName: "Plan CPU next", planName: "Plan CPU", endTime: nil, isComputing: false)
        let terminalNextLive = WorkspaceResultComputeEntry(runID: nextLive.runID,
            projectSessionID: nextLive.projectSessionID, editorID: nextLive.editorID,
            operationOwnerToken: nextLive.operationOwnerToken,
            operationContextID: nextLive.operationContextID, projectPath: nextLive.projectPath,
            projectRevision: nextLive.projectRevision,
            projectXmlFingerprint: nextLive.projectXmlFingerprint, planPath: nextLive.planPath,
            planRevision: nextLive.planRevision, resultPath: nextLive.resultPath,
            resultName: nextLive.resultName, resultRevision: nextStableChoice.revision,
            status: .completed, fraction: 1, message: nil, taskName: nil,
            failureReason: nil, profileTimeline: nextProfileMetadata)
        session.updateLiveComputeSelection(nodeID: metadataNode.id, selectionIndex: 0,
            entry: terminalNextLive, timeline: nextProfileMetadata)
        session.endPlanCompute(nextCapture)

        let changedStoredNode = MapResultChartActiveNode(node: liveNode,
            nodeKind: "MultiResult", name: "Plan CPU",
            selections: [.init(selectionIndex: 0, selectionMode: .explicit,
                selectedResult: oldChoice, choices: [nextStableChoice, oldChoice])],
            selectedMapType: "WSE", profileIndex: 0)
        let switchedSnapshot = makeSnapshot(contextToken: "terminal-but-stored-source-selected",
            activeNodes: [changedStoredNode, makeNode(otherNode)])
        session.configure(snapshot: switchedSnapshot, projectSessionID: projectSessionID,
            viewport: { viewport.extent }, isCurrent: { true })
        try await waitUntil { !session.isLoading && session.resultLayers.count == 2 }
        #expect(preparedNodeProfileIndices.values.last(where: { $0.0 == metadataNode.id })?.1 == 0,
            "A terminal Result present in choices must not restore its profile after slot zero selects another exact source.")
        #expect(session.selectedTimeline?.currentID == 0)
        session.invalidate()
    }

    @Test @MainActor
    func nonzeroLiveSlotMasksOnlyItsRasterAndStoredChoiceNeedsExactFrameIdentity() async throws {
        let projectSessionID = UUID(uuidString: "FCEB4638-5B79-4CBB-A209-5C18990D2BA6")!
        let mapID = UUID(uuidString: "7B6069FD-CA8D-4D4D-A20C-26A4BC70BCA3")!
        let planPath = "/tmp/map-result-map/Plan Live.p02"
        let map = MapResultChartMapRequest(projectPath: "/tmp/map-result-map/model.ras",
            projectXml: "<Project><Map name=\"Map\" /></Project>", projectXmlSHA: "project-sha",
            mapID: mapID.uuidString, mapIndex: 0, mapName: "Map", mapType: "Plan",
            expectedVisualizationRevision: "vis-live-mask")
        let locator = CatalogTreeNodeLocator(rootName: "Results", nodeType: "MultiResult",
            nodeName: "Plan Live", nodePath: [0, 0], assetID: planPath, mapType: "WSE")
        let otherLocator = CatalogTreeNodeLocator(rootName: "Results", nodeType: "MultiResult",
            nodeName: "Other Plan", nodePath: [0, 1], assetID: "/tmp/map-result-map/Other.p02", mapType: "Depth")
        let oldSlotZero = MapResultChartSourceChoice(resultPath: "/tmp/map-result-map/slot-zero.hdf",
            revision: "zero-sha", resultName: "Slot zero", planName: "Plan Live", endTime: nil, isComputing: false)
        let oldSlotOne = MapResultChartSourceChoice(resultPath: "/tmp/map-result-map/slot-one.hdf",
            revision: "one-sha", resultName: "Slot one", planName: "Plan Live", endTime: nil, isComputing: false)
        let newStoredChoice = MapResultChartSourceChoice(resultPath: "/tmp/map-result-map/new-live.hdf",
            revision: "new-sha", resultName: "New stored", planName: "Plan Live", endTime: nil, isComputing: false)
        let slotZero = MapResultChartSelectionSlot(selectionIndex: 0, selectionMode: .explicit,
            selectedResult: oldSlotZero, choices: [oldSlotZero, oldSlotOne, newStoredChoice])
        let slotOne = MapResultChartSelectionSlot(selectionIndex: 1, selectionMode: .explicit,
            selectedResult: oldSlotOne, choices: [oldSlotZero, oldSlotOne, newStoredChoice])
        let firstNode = MapResultChartActiveNode(node: locator, nodeKind: "MultiResult",
            name: "Plan Live", selections: [slotZero, slotOne], selectedMapType: "WSE", profileIndex: 0)
        let otherChoice = MapResultChartSourceChoice(resultPath: "/tmp/map-result-map/other.hdf",
            revision: "other-sha", resultName: "Other", planName: "Other Plan", endTime: nil, isComputing: false)
        let otherNode = MapResultChartActiveNode(node: otherLocator, nodeKind: "MultiResult",
            name: "Other Plan", selections: [.init(selectionIndex: 0, selectionMode: .latest,
                selectedResult: otherChoice, choices: [otherChoice])], selectedMapType: "Depth", profileIndex: 0)
        func snapshot(_ token: String, nodes: [MapResultChartActiveNode]) -> MapResultSourcesSnapshot {
            let sources = MapResultChartSources(projectPath: map.projectPath, projectRevision: "project-revision",
                mapID: map.mapID, mapIndex: map.mapIndex, mapName: map.mapName, mapType: map.mapType,
                projectXmlSHA: map.projectXmlSHA, visualizationRevision: map.expectedVisualizationRevision,
                contextToken: token, activeNodes: nodes)
            return MapResultSourcesSnapshot(map: map, identity: projectSessionID.uuidString + "|map|sources",
                sources: sources, selectionOverrides: [])
        }
        let zeroLayer = try makeLayer(id: "slot-zero", mapID: mapID)
        let staleOneLayer = try makeLayer(id: "stale-slot-one", mapID: mapID)
        let unknownLayer = try makeLayer(id: "unmapped", mapID: mapID)
        let freshOneLayer = try makeLayer(id: "fresh-slot-one", mapID: mapID)
        let otherLayer = try makeLayer(id: "other-node", mapID: mapID)
        let zeroIdentity = MapRasterSourceIdentity(resultPath: oldSlotZero.resultPath, revision: oldSlotZero.revision)
        let staleOneIdentity = MapRasterSourceIdentity(resultPath: oldSlotOne.resultPath, revision: oldSlotOne.revision)
        let freshOneIdentity = MapRasterSourceIdentity(resultPath: newStoredChoice.resultPath, revision: newStoredChoice.revision)
        let firstUpdate = MapUpdate(vectors: nil, rasters: [zeroLayer, staleOneLayer, unknownLayer], preview: [],
            selectedLayerID: nil, selectedFeatureID: nil,
            rasterSelectionIndicesByLayerID: [zeroLayer.id: [0], staleOneLayer.id: [1]],
            rasterSourceIdentityByLayerID: [zeroLayer.id: zeroIdentity, staleOneLayer.id: staleOneIdentity])
        let freshUpdate = MapUpdate(vectors: nil, rasters: [zeroLayer, freshOneLayer], preview: [],
            selectedLayerID: nil, selectedFeatureID: nil,
            rasterSelectionIndicesByLayerID: [zeroLayer.id: [0], freshOneLayer.id: [1]],
            rasterSourceIdentityByLayerID: [zeroLayer.id: zeroIdentity, freshOneLayer.id: freshOneIdentity])
        let firstSnapshot = snapshot("before-slot-one-live", nodes: [firstNode, otherNode])
        let viewport = MapResultMapViewportBox()
        let session = MapResultMapSession(prepareNode: { request in
            let isTarget = request.node.id == firstNode.id
            let provider: any ProfileProvider = isTarget
                ? FixedMapOwnershipProfileProvider(update: freshUpdate)
                : ImmediateMapProfileProvider(mapID: request.mapID)
            let layer = isTarget ? zeroLayer : otherLayer
            let update: MapUpdate
            if isTarget {
                update = request.snapshot.sources.contextToken == "exact-terminal-path-sha"
                    ? freshUpdate : firstUpdate
            } else {
                update = MapUpdate(vectors: nil, rasters: [layer], preview: [],
                    selectedLayerID: nil, selectedFeatureID: nil)
            }
            return MapResultMapSession.PreparedNode(presentation: .init(sourceID: request.node.id,
                steps: [.init(id: 0, label: "T0"), .init(id: 1, label: "T1")], selectedID: 0),
                provider: provider, initialUpdate: update, initialLegends: [],
                initialUnavailableReason: nil, initialSourceStatuses: [], renderedViewport: request.viewport(),
                availability: { MapResultMapAvailability(reason: nil, sourceStatuses: []) })
        })
        let persistedProfiles = MapResultMapPreparedIndexCapture()
        session.didSelectPersistableProfile = { locator, _, index in
            persistedProfiles.values.append((locator.nodeName, index))
        }
        session.configure(snapshot: firstSnapshot, projectSessionID: projectSessionID,
            viewport: { viewport.extent }, isCurrent: { true })
        try await waitUntil { !session.isLoading && session.resultLayers.count == 3 }
        let capture = WorkspaceResultComputeCapture(projectSessionID: projectSessionID,
            editorID: UUID(uuidString: "3A8A46E1-CB7C-43E3-B923-ABDEB0D79F3C")!,
            operationOwnerToken: "owner-slot-one", operationContextID: "context-slot-one",
            projectPath: map.projectPath, projectRevision: "project-revision",
            projectXmlFingerprint: map.projectXmlSHA, planPath: planPath, planRevision: "plan-revision")
        let live = WorkspaceResultComputeEntry(runID: "E9A1F75C-3A0A-474A-BEF4-315C9570678C",
            projectSessionID: projectSessionID, editorID: capture.editorID,
            operationOwnerToken: capture.operationOwnerToken, operationContextID: capture.operationContextID,
            projectPath: capture.projectPath, projectRevision: capture.projectRevision,
            projectXmlFingerprint: capture.projectXmlFingerprint, planPath: capture.planPath,
            planRevision: capture.planRevision, resultPath: "/tmp/map-result-map/new-live.hdf",
            resultName: "New live", resultRevision: nil, status: .running, fraction: 0.6,
            message: nil, taskName: "Solving", failureReason: nil)
        session.beginPlanCompute(capture)
        session.updateLiveComputeSelection(nodeID: firstNode.id, selectionIndex: 1,
            entry: live, timeline: nil)
        #expect(session.resultLayers.map(\.id).sorted() == ["other-node", "slot-zero"],
            "The unreadable slot is masked; slot zero and another node remain, and unmapped layers stay hidden.")
        #expect(session.selectedTimeline?.currentID == 0,
            "A nonzero live selection must not replace or reset the slot-zero keyframe timeline.")

        session.updateLiveComputeSelection(nodeID: firstNode.id, selectionIndex: 1,
            entry: nil, timeline: nil, selectedStoredChoice: newStoredChoice)
        #expect(session.resultLayers.map(\.id).sorted() == ["other-node", "slot-zero"],
            "Clearing the live override cannot reveal a cached raster with a different path or revision.")
        session.endPlanCompute(capture)
        session.selectNode(firstNode.id)
        session.selectedTimeline?.select(position: 1)
        try await waitUntil {
            session.selectedTimeline?.currentID == 1
                && session.resultLayers.contains { $0.id == "fresh-slot-one" }
        }
        #expect(session.resultLayers.map(\.id).sorted() == ["fresh-slot-one", "other-node", "slot-zero"],
            "A newly returned exact stored-choice frame restores that slot while preserving slot zero.")
        #expect(persistedProfiles.values.contains { $0.0 == firstNode.name && $0.1 == 1 },
            "Resuming source reads must also restore the active profile persistence callback.")

        let nextCapture = WorkspaceResultComputeCapture(projectSessionID: projectSessionID,
            editorID: capture.editorID, operationOwnerToken: "owner-slot-one-next",
            operationContextID: "context-slot-one-next", projectPath: map.projectPath,
            projectRevision: "project-revision", projectXmlFingerprint: map.projectXmlSHA,
            planPath: planPath, planRevision: "plan-revision-next")
        let nextLive = WorkspaceResultComputeEntry(runID: "6132A663-B8BA-45EC-A50B-4AE201C72349",
            projectSessionID: projectSessionID, editorID: nextCapture.editorID,
            operationOwnerToken: nextCapture.operationOwnerToken,
            operationContextID: nextCapture.operationContextID, projectPath: nextCapture.projectPath,
            projectRevision: nextCapture.projectRevision,
            projectXmlFingerprint: nextCapture.projectXmlFingerprint, planPath: nextCapture.planPath,
            planRevision: nextCapture.planRevision, resultPath: "/tmp/map-result-map/newer-live.hdf",
            resultName: "Newer live", resultRevision: nil, status: .running, fraction: 0.2,
            message: nil, taskName: "Solving", failureReason: nil)
        session.beginPlanCompute(nextCapture)
        session.updateLiveComputeSelection(nodeID: firstNode.id, selectionIndex: 1,
            entry: nextLive, timeline: nil)
        #expect(session.resultLayers.map(\.id).sorted() == ["other-node", "slot-zero"],
            "The prior slot-one frame is masked while its live replacement has no readable payload.")
        session.removeLiveComputeSelectionSlot(nodeID: firstNode.id, selectionIndex: 1)
        #expect(session.resultLayers.map(\.id).sorted() == ["other-node", "slot-zero"],
            "Removing the live slot must not reveal its stale raster; surviving slot owners remain visible.")
        session.endPlanCompute(nextCapture)

        let terminal = WorkspaceResultComputeEntry(runID: live.runID,
            projectSessionID: live.projectSessionID, editorID: live.editorID,
            operationOwnerToken: live.operationOwnerToken, operationContextID: live.operationContextID,
            projectPath: live.projectPath, projectRevision: live.projectRevision,
            projectXmlFingerprint: live.projectXmlFingerprint, planPath: live.planPath,
            planRevision: live.planRevision, resultPath: live.resultPath, resultName: live.resultName,
            resultRevision: "new-sha", status: .completed, fraction: 1, message: nil,
            taskName: nil, failureReason: nil)
        let promotedChoice = MapResultChartSourceChoice(resultPath: terminal.resultPath,
            revision: "new-sha", resultName: "New live", planName: "Plan Live", endTime: nil, isComputing: false)
        let promotedSlot = MapResultChartSelectionSlot(selectionIndex: 1, selectionMode: .explicit,
            selectedResult: promotedChoice, choices: [oldSlotZero, oldSlotOne, promotedChoice])
        let promotedNode = MapResultChartActiveNode(node: locator, nodeKind: "MultiResult", name: "Plan Live",
            selections: [slotZero, promotedSlot], selectedMapType: "WSE", profileIndex: 1)
        let promotedSnapshot = snapshot("exact-terminal-path-sha", nodes: [promotedNode, otherNode])
        session.configure(snapshot: promotedSnapshot, projectSessionID: projectSessionID,
            viewport: { viewport.extent }, isCurrent: { true })
        try await waitUntil { !session.isLoading && session.resultLayers.contains { $0.id == "slot-zero" } }
        #expect(session.nodes.first(where: { $0.name == "Plan Live" })?.layerCount == 2,
            "The promoted slot and the independently selected keyframe slot both render their exact sources.")
        #expect(session.resultLayers.map(\.id).sorted() == ["fresh-slot-one", "other-node", "slot-zero"])
        session.invalidate()
    }

    @Test @MainActor
    func removingLiveSlotReindexesOwnershipAndPreservesSharedRasterOwners() async throws {
        let projectSessionID = UUID(uuidString: "900534D2-711C-42AA-9C41-1CBE04B3C735")!
        let mapID = UUID(uuidString: "7D2448E5-84E9-4415-B984-1B311E610AE4")!
        let planPath = "/tmp/map-result-map/Plan Owners.p02"
        let map = MapResultChartMapRequest(projectPath: "/tmp/map-result-map/owners.ras",
            projectXml: "<Project><Map name=\"Owners\" /></Project>", projectXmlSHA: "owners-xml",
            mapID: mapID.uuidString, mapIndex: 0, mapName: "Owners", mapType: "Plan",
            expectedVisualizationRevision: "owners-vis")
        let locator = CatalogTreeNodeLocator(rootName: "Results", nodeType: "MultiResult",
            nodeName: "Plan Owners", nodePath: [0, 0], assetID: planPath, mapType: "WSE")
        let oldZero = MapResultChartSourceChoice(resultPath: "/tmp/map-result-map/owners-0.hdf",
            revision: "owner-zero", resultName: "Zero", planName: "Plan Owners", endTime: nil, isComputing: false)
        let removedChoice = MapResultChartSourceChoice(resultPath: "/tmp/map-result-map/owners-1.hdf",
            revision: "owner-one", resultName: "Removed", planName: "Plan Owners", endTime: nil, isComputing: false)
        let shiftedChoice = MapResultChartSourceChoice(resultPath: "/tmp/map-result-map/owners-2.hdf",
            revision: "owner-two", resultName: "Shifted", planName: "Plan Owners", endTime: nil, isComputing: false)
        let choices = [oldZero, removedChoice, shiftedChoice]
        let slots = choices.enumerated().map { index, choice in
            MapResultChartSelectionSlot(selectionIndex: index, selectionMode: .explicit,
                selectedResult: choice, choices: choices)
        }
        let node = MapResultChartActiveNode(node: locator, nodeKind: "MultiResult",
            name: "Plan Owners", selections: slots, selectedMapType: "WSE", profileIndex: 0)
        let sources = MapResultChartSources(projectPath: map.projectPath, projectRevision: "owners-project",
            mapID: map.mapID, mapIndex: map.mapIndex, mapName: map.mapName, mapType: map.mapType,
            projectXmlSHA: map.projectXmlSHA, visualizationRevision: map.expectedVisualizationRevision,
            contextToken: "owners-context", activeNodes: [node])
        let snapshot = MapResultSourcesSnapshot(map: map,
            identity: projectSessionID.uuidString + "|owners", sources: sources, selectionOverrides: [])
        let zeroLayer = try makeLayer(id: "owner-zero", mapID: mapID)
        let removedLayer = try makeLayer(id: "owner-removed", mapID: mapID)
        let sharedLayer = try makeLayer(id: "owner-shared", mapID: mapID)
        let shiftedLayer = try makeLayer(id: "owner-shifted", mapID: mapID)
        let initial = MapUpdate(vectors: nil,
            rasters: [zeroLayer, removedLayer, sharedLayer, shiftedLayer], preview: [],
            selectedLayerID: nil, selectedFeatureID: nil,
            rasterSelectionIndicesByLayerID: [zeroLayer.id: [0], removedLayer.id: [1],
                sharedLayer.id: [0, 1], shiftedLayer.id: [2]],
            rasterSourceIdentityByLayerID: [zeroLayer.id: MapRasterSourceIdentity(
                    resultPath: oldZero.resultPath, revision: oldZero.revision),
                removedLayer.id: MapRasterSourceIdentity(resultPath: removedChoice.resultPath,
                    revision: removedChoice.revision),
                sharedLayer.id: MapRasterSourceIdentity(resultPath: oldZero.resultPath,
                    revision: oldZero.revision),
                shiftedLayer.id: MapRasterSourceIdentity(resultPath: shiftedChoice.resultPath,
                    revision: shiftedChoice.revision)])
        let viewport = MapResultMapViewportBox()
        let session = MapResultMapSession(prepareNode: { request in
            MapResultMapSession.PreparedNode(presentation: .init(sourceID: node.id,
                steps: [.init(id: 0, label: "T0")], selectedID: 0),
                provider: FixedMapOwnershipProfileProvider(update: initial), initialUpdate: initial,
                initialLegends: [], initialUnavailableReason: nil, initialSourceStatuses: [],
                renderedViewport: request.viewport(),
                availability: { MapResultMapAvailability(reason: nil, sourceStatuses: []) })
        })
        session.configure(snapshot: snapshot, projectSessionID: projectSessionID,
            viewport: { viewport.extent }, isCurrent: { true })
        try await waitUntil { !session.isLoading && session.resultLayers.count == 4 }

        let capture = WorkspaceResultComputeCapture(projectSessionID: projectSessionID,
            editorID: UUID(uuidString: "13C3FEAF-57BD-47D1-B4F8-8B10D55232B0")!,
            operationOwnerToken: "owners-run", operationContextID: "owners-context",
            projectPath: map.projectPath, projectRevision: "owners-project",
            projectXmlFingerprint: map.projectXmlSHA, planPath: planPath, planRevision: "owners-plan")
        let live = WorkspaceResultComputeEntry(runID: "034D902C-7A8A-47C8-820C-6317DBE6155C",
            projectSessionID: projectSessionID, editorID: capture.editorID,
            operationOwnerToken: capture.operationOwnerToken, operationContextID: capture.operationContextID,
            projectPath: capture.projectPath, projectRevision: capture.projectRevision,
            projectXmlFingerprint: capture.projectXmlFingerprint, planPath: capture.planPath,
            planRevision: capture.planRevision, resultPath: "/tmp/map-result-map/owners-live.hdf",
            resultName: "Owners live", resultRevision: nil, status: .running, fraction: 0.4,
            message: nil, taskName: "Solving", failureReason: nil)
        session.beginPlanCompute(capture)
        session.updateLiveComputeSelection(nodeID: node.id, selectionIndex: 1, entry: live, timeline: nil)
        session.updateLiveComputeSelection(nodeID: node.id, selectionIndex: 2, entry: live, timeline: nil)
        #expect(session.resultLayers.map(\.id).sorted() == ["owner-shared", "owner-zero"],
            "A shared frame remains visible through slot zero; the live-owned frames are masked.")

        session.updateLiveComputeSelection(nodeID: node.id, selectionIndex: 2, entry: nil,
            timeline: nil, selectedStoredChoice: shiftedChoice)
        #expect(session.resultLayers.map(\.id).sorted() == ["owner-shared", "owner-shifted", "owner-zero"],
            "An exact cached frame remains visible after returning slot two to its stored source.")

        session.removeLiveComputeSelectionSlot(nodeID: node.id, selectionIndex: 1)
        #expect(session.resultLayers.map(\.id).sorted() == ["owner-shared", "owner-shifted", "owner-zero"],
            "Removing live slot one hides its only raster, retains the shared raster via slot zero, and reindexes slot two.")
        session.endPlanCompute(capture)
        session.invalidate()
    }

    @Test @MainActor
    func viewportRefreshPublishesEveryNodeTogetherAndKeepsTimelinesIndependent() async throws {
        let mapID = UUID(uuidString: "CA5DB39A-1D3C-4804-A1FA-5F85FD7AC9A1")!
        let snapshot = makeSnapshot(mapID: mapID)
        let nodeA = snapshot.sources.activeNodes[0]
        let nodeB = snapshot.sources.activeNodes[1]
        let firstExtent = extent(0)
        let secondExtent = extent(10)
        let thirdExtent = extent(20)
        let viewport = MapResultMapViewportBox()
        let providerA = DeferredMapProfileProvider(viewport: { viewport.extent })
        let providerB = DeferredMapProfileProvider(viewport: { viewport.extent })
        let providers = [nodeA.id: providerA, nodeB.id: providerB]
        var releaseSecondPreparation: CheckedContinuation<Void, Never>?
        let session = MapResultMapSession(prepareNode: { request in
            if request.node.id == nodeB.id {
                await withCheckedContinuation { continuation in
                    releaseSecondPreparation = continuation
                }
            }
            let provider = providers[request.node.id]!
            let initialLayer = try makeLayer(id: request.node.name + "-initial", mapID: request.mapID)
            let steps = [ProfileStep(id: 0, label: "T0"), ProfileStep(id: 1, label: "T1")]
            let presentation = MapProfilePresentation(sourceID: request.node.id, steps: steps, selectedID: 0)
            return MapResultMapSession.PreparedNode(
                presentation: presentation, provider: provider,
                initialUpdate: MapUpdate(vectors: nil, rasters: [initialLayer], preview: [],
                    selectedLayerID: nil, selectedFeatureID: nil),
                initialLegends: [legend(for: initialLayer.id)],
                initialUnavailableReason: nil, initialSourceStatuses: [],
                renderedViewport: request.viewport(),
                availability: { MapResultMapAvailability(reason: nil, sourceStatuses: []) })
        })
        var published: [[String]] = []
        session.didUpdate = { layers, _ in published.append(layers.map(\.id)) }

        session.configure(snapshot: snapshot, viewport: { viewport.extent }, isCurrent: { true })
        try await waitUntil { releaseSecondPreparation != nil }
        viewport.extent = firstExtent
        session.viewportChanged()
        releaseSecondPreparation?.resume()
        releaseSecondPreparation = nil
        try await waitUntil { providerA.requests.count == 1 }
        #expect(!session.isLoading)
        #expect(session.resultLayers.isEmpty,
            "Initial frames rendered against different viewport generations must not be mixed or published.")
        #expect(providerA.requests[0].viewport == firstExtent)
        providerA.finish(1, layer: try makeLayer(id: nodeA.name + "-first", mapID: mapID))
        try await waitUntil { providerB.requests.count == 1 }
        #expect(providerB.requests[0].viewport == firstExtent)
        providerB.finish(1, layer: try makeLayer(id: nodeB.name + "-first", mapID: mapID))
        try await waitUntil {
            !session.isReloading
                && session.resultLayers.map(\.id) == [nodeA.name + "-first", nodeB.name + "-first"]
        }
        let publishedCountBeforeLatestFrames = published.count

        viewport.extent = secondExtent
        session.viewportChanged()
        try await waitUntil { providerA.requests.count == 2 }
        #expect(providerA.requests[1].viewport == secondExtent)
        viewport.extent = thirdExtent
        session.viewportChanged()
        providerA.finish(2, layer: try makeLayer(id: nodeA.name + "-obsolete-viewport", mapID: mapID))
        try await waitUntil { providerA.requests.count == 3 }
        #expect(providerA.requests[2].viewport == thirdExtent)
        #expect(session.resultLayers.map(\.id) == [nodeA.name + "-first", nodeB.name + "-first"])
        #expect(published.count == publishedCountBeforeLatestFrames,
            "A partial node response must retain the last complete viewport frame.")

        providerA.finish(3, layer: try makeLayer(id: nodeA.name + "-latest", mapID: mapID))
        try await waitUntil { providerB.requests.count == 2 }
        #expect(providerB.requests[1].viewport == thirdExtent)
        providerB.finish(2, layer: try makeLayer(id: nodeB.name + "-latest", mapID: mapID))
        try await waitUntil { !session.isReloading && published.last == [nodeA.name + "-latest", nodeB.name + "-latest"] }
        #expect(published.count == publishedCountBeforeLatestFrames + 1)

        session.selectNode(nodeB.id)
        session.selectedTimeline?.select(position: 1)
        try await waitUntil { providerB.requests.count == 3 }
        #expect(providerB.requests[2].index == 1)
        providerB.finish(3, layer: try makeLayer(id: nodeB.name + "-profile-1", mapID: mapID))
        try await waitUntil { session.selectedTimeline?.currentID == 1 }
        #expect(session.selectedTimeline?.currentID == 1)
        #expect(session.nodes.first(where: { $0.id == nodeA.id })?.profileIndex == 0)
        #expect(session.resultLayers.map(\.id) == [nodeA.name + "-latest", nodeB.name + "-profile-1"])
    }

    @Test @MainActor
    func computeLeaseKeepsBothMultiResultSlotsAndUsesOnlyAnExactWriterKeyframeAnchor() async throws {
        @MainActor
        func exercise(writerIndex: Int) async throws {
            let projectSessionID = UUID(uuidString: "4B730DA8-1518-4A89-8BE2-37F13238F455")!
            let editorID = UUID(uuidString: "218DA7CD-5A31-42D5-9E96-95667A1F8DC0")!
            let mapID = UUID(uuidString: "7B6069FD-CA8D-4D4D-A20C-26A4BC70BCA3")!
            let projectPath = "/tmp/map-result-map/multislot-lease-project.ras"
            let projectXML = "<Project><Map name=\"Lease Map\" /></Project>"
            let projectXMLSHA = "multi-slot-project-xml-sha"
            let planPath = "/tmp/map-result-map/Multi Slot Plan.p02"
            let writerPath = "/tmp/map-result-map/Multi Slot Plan active.hdf"
            let map = MapResultChartMapRequest(projectPath: projectPath, projectXml: projectXML,
                projectXmlSHA: projectXMLSHA, mapID: mapID.uuidString, mapIndex: 0,
                mapName: "Lease Map", mapType: "Plan",
                expectedVisualizationRevision: "multi-slot-vis-sha")
            let locator = CatalogTreeNodeLocator(rootName: "Results", nodeType: "MultiResult",
                nodeName: "Multi Slot Plan", nodePath: [0, 1], assetID: planPath, mapType: "WSE")
            let oldChoices = [
                MapResultChartSourceChoice(resultPath: "/tmp/map-result-map/old-zero.h5",
                    revision: String(repeating: "a", count: 64), resultName: "Old Zero",
                    planName: "Multi Slot Plan", endTime: nil, isComputing: false),
                MapResultChartSourceChoice(resultPath: "/tmp/map-result-map/old-one.hdf",
                    revision: String(repeating: "b", count: 64), resultName: "Old One",
                    planName: "Multi Slot Plan", endTime: nil, isComputing: false)
            ]

            func makeNode(_ selectedChoices: [MapResultChartSourceChoice?],
                          contextChoices: [MapResultChartSourceChoice]) -> MapResultChartActiveNode {
                let slots = selectedChoices.enumerated().map { index, choice in
                    MapResultChartSelectionSlot(selectionIndex: index, selectionMode: .explicit,
                        selectedResult: choice, choices: contextChoices)
                }
                return MapResultChartActiveNode(node: locator, nodeKind: "MultiResult",
                    name: locator.nodeName, selections: slots,
                    selectedMapType: "WSE", profileIndex: 0)
            }

            func makeSnapshot(map: MapResultChartMapRequest, contextToken: String,
                              selectedChoices: [MapResultChartSourceChoice?],
                              contextChoices: [MapResultChartSourceChoice]) -> MapResultSourcesSnapshot {
                let sources = MapResultChartSources(projectPath: projectPath,
                    projectRevision: "multi-slot-project-revision", mapID: map.mapID,
                    mapIndex: map.mapIndex, mapName: map.mapName, mapType: map.mapType,
                    projectXmlSHA: projectXMLSHA,
                    visualizationRevision: map.expectedVisualizationRevision,
                    contextToken: contextToken,
                    activeNodes: [makeNode(selectedChoices, contextChoices: contextChoices)])
                return MapResultSourcesSnapshot(map: map,
                    identity: projectSessionID.uuidString + "|multi-slot-map",
                    sources: sources, selectionOverrides: [])
            }

            let initialSnapshot = makeSnapshot(map: map, contextToken: "before-multislot-lease",
                selectedChoices: [oldChoices[0], oldChoices[1]], contextChoices: oldChoices)
            let viewport = MapResultMapViewportBox()
            viewport.extent = extent(0)
            var preparationRequests: [MapResultMapSession.PreparationRequest] = []
            var preparationUpdates: [MapUpdate] = []
            var freshProviders: [Int: SlotOwnedMapProfileProvider] = [:]
            let session = MapResultMapSession(prepareNode: { request in
                preparationRequests.append(request)
                let visibleSelections = request.node.selections.filter {
                    !request.blockedSelectionIndices.contains($0.selectionIndex)
                }.compactMap { slot -> (Int, MapResultChartSourceChoice)? in
                    guard let choice = slot.selectedResult else { return nil }
                    return (slot.selectionIndex, choice)
                }
                var layers: [MapRasterLayer] = []
                var ownership: [String: [Int]] = [:]
                var sourceIdentities: [String: MapRasterSourceIdentity] = [:]
                let viewportOrigin = Int((request.viewport()?.minX ?? 0).rounded())
                for (index, choice) in visibleSelections {
                    let id = "prepared-slot-\(index)-\(choice.resultName)-x\(viewportOrigin)"
                    layers.append(try MapRasterLayer(id: id, name: id, width: 1, height: 1,
                        rgba: Data([10, 20, 30, 255]), lowerLeft: MapPoint(x: 0, y: 0),
                        upperRight: MapPoint(x: 1, y: 1), sourceMapID: request.mapID))
                    ownership[id] = [index]
                    sourceIdentities[id] = MapRasterSourceIdentity(resultPath: choice.resultPath,
                        revision: choice.revision)
                }

                let timeline = request.liveKeyframeTimeline
                let sourceID = timeline.map {
                    "\($0.runID)|\(SourceFilePaths.canonical(URL(fileURLWithPath: $0.resultPath)))|\($0.outputBlockName)"
                } ?? request.node.id
                let steps = timeline?.profiles.map {
                    ProfileStep(id: $0.index, label: $0.name, sourceTime: $0.time)
                } ?? [ProfileStep(id: 0, label: "Stable profile zero", sourceTime: "2025-01-01T00:00:00.0000000Z"),
                    ProfileStep(id: 1, label: "Stable profile one", sourceTime: "2025-01-01T01:00:00.0000000Z")]
                let selectedID = request.node.profileIndex.flatMap { profile in
                    steps.contains(where: { $0.id == profile }) ? profile : nil
                } ?? steps.first?.id
                let presentation = MapProfilePresentation(sourceID: sourceID,
                    steps: steps, selectedID: selectedID)
                let update = MapUpdate(vectors: nil, rasters: layers, preview: [],
                    selectedLayerID: nil, selectedFeatureID: nil,
                    rasterSelectionIndicesByLayerID: ownership,
                    rasterSourceIdentityByLayerID: sourceIdentities)
                preparationUpdates.append(update)
                let provider: any ProfileProvider
                if visibleSelections.count == 1, let safe = visibleSelections.first {
                    let idPrefix = "sampled-slot-\(safe.0)"
                    let ownerProvider = SlotOwnedMapProfileProvider(mapID: request.mapID,
                        choice: safe.1, selectionIndex: safe.0, idPrefix: idPrefix)
                    if timeline != nil { freshProviders[safe.0] = ownerProvider }
                    provider = ownerProvider
                } else {
                    provider = ImmediateMapProfileProvider(mapID: request.mapID)
                }
                return MapResultMapSession.PreparedNode(presentation: presentation,
                    provider: provider, initialUpdate: update, initialLegends: [],
                    initialUnavailableReason: nil, initialSourceStatuses: [],
                    renderedViewport: request.viewport(),
                    availability: { MapResultMapAvailability(reason: nil, sourceStatuses: []) })
            })
            session.configure(snapshot: initialSnapshot, projectSessionID: projectSessionID,
                viewport: { viewport.extent }, isCurrent: { true })
            try await waitUntil { !session.isLoading && session.resultLayers.count == 2 }
            let initialNodeID = initialSnapshot.sources.activeNodes[0].id
            session.selectNode(initialNodeID)

            let capture = WorkspaceResultComputeCapture(projectSessionID: projectSessionID,
                editorID: editorID, operationOwnerToken: "multi-slot-owner-\(writerIndex)",
                operationContextID: "multi-slot-context-\(writerIndex)",
                projectPath: projectPath, projectRevision: "multi-slot-project-revision",
                projectXmlFingerprint: projectXMLSHA, planPath: planPath,
                planRevision: "multi-slot-plan-revision")
            var liveEntry = WorkspaceResultComputeEntry(runID: writerIndex == 0
                ? "D7DCB50B-11C7-4605-852C-E5D4643FE389"
                : "EE8EA28A-D96D-40A8-9D4B-0AE1C93527BD",
                projectSessionID: projectSessionID, editorID: editorID,
                operationOwnerToken: capture.operationOwnerToken,
                operationContextID: capture.operationContextID,
                projectPath: capture.projectPath, projectRevision: capture.projectRevision,
                projectXmlFingerprint: capture.projectXmlFingerprint, planPath: capture.planPath,
                planRevision: capture.planRevision, resultPath: writerPath,
                resultName: "Multi Slot Plan active", resultRevision: nil, status: .running,
                fraction: 0.5, message: nil, taskName: "Solving", failureReason: nil)
            var metadata: LiveMapResultProfileTimeline?
            if writerIndex == 0 {
                var timeline = LiveMapResultProfileTimeline(identity: .init(entry: liveEntry))
                let appendedProfiles = timeline.append(BackendResultProfilesUpdate(outputBlockName: "BaseOutput",
                    startIndex: 0, profileCount: 2, profiles: [
                        .init(index: 0, name: "01Jan2025 00:00:00", time: "2025-01-01T00:00:00.0000000Z"),
                        .init(index: 1, name: "01Jan2025 01:00:00", time: "2025-01-01T01:00:00.0000000Z")
                    ]))
                #expect(appendedProfiles)
                liveEntry.profileTimeline = timeline
                metadata = timeline
            }

            let liveSelections: [MapResultChartSourceChoice?] = [oldChoices[0], oldChoices[1]]
            session.beginPlanCompute(capture)
            session.updateLiveComputeSelection(nodeID: initialNodeID,
                selectionIndex: writerIndex, selectionMode: .explicit,
                entry: liveEntry, timeline: metadata)
            let cachedSafeID = "prepared-slot-\(1 - writerIndex)-Old \(writerIndex == 0 ? "One" : "Zero")-x0"
            #expect(session.layers(for: locator).map(\.id) == [cachedSafeID],
                "Starting a live slot hides only that slot's old cached raster before the leased refresh.")
            if writerIndex == 0 {
                session.selectedTimeline?.select(position: 1)
                #expect(session.selectedTimeline?.currentID == 1)
            }

            let lease = MapResultComputeReadLease(projectSessionID: projectSessionID.uuidString,
                runID: liveEntry.runID, projectPath: projectPath,
                protectedSourcePaths: ["/tmp/map-result-map/Geometry.h5", writerPath],
                callbackResultPath: writerPath)
            var leasedMap = map
            leasedMap.computeReadLease = lease
            var selectedChoices: [MapResultChartSourceChoice?] = liveSelections
            selectedChoices[writerIndex] = nil
            let leasedSnapshot = makeSnapshot(map: leasedMap,
                contextToken: "writer-excluded-slot-\(writerIndex)",
                selectedChoices: selectedChoices, contextChoices: oldChoices)
            let accepted = await session.refreshHistoricalResultsDuringCompute(snapshot: leasedSnapshot,
                capture: capture, entry: liveEntry, lease: lease, isCurrent: { true })
            #expect(accepted)

            let request = try #require(preparationRequests.last)
            #expect(request.node.selections.map(\.selectionIndex) == [0, 1],
                "The writer slot remains at its original index instead of shifting the sibling.")
            #expect(request.blockedSelectionIndices == Set([writerIndex]))
            let writerSelection = try #require(request.node.selections.first {
                $0.selectionIndex == writerIndex
            })
            let safeSelection = try #require(request.node.selections.first {
                $0.selectionIndex == 1 - writerIndex
            })
            #expect(writerSelection.selectedResult == nil)
            #expect(safeSelection.selectedResult == oldChoices[1 - writerIndex])
            let safeIndex = 1 - writerIndex
            let safeChoice = oldChoices[safeIndex]
            let expectedFreshID = "prepared-slot-\(safeIndex)-\(safeChoice.resultName)-x0"
            #expect(preparationUpdates.last?.rasterSelectionIndicesByLayerID == [expectedFreshID: [safeIndex]])
            #expect(preparationUpdates.last?.rasterSourceIdentityByLayerID?[expectedFreshID]
                == MapRasterSourceIdentity(resultPath: safeChoice.resultPath, revision: safeChoice.revision))
            #expect(session.layers(for: locator).map(\.id) == [expectedFreshID],
                "The refreshed node contains only the exact safe sibling's fresh raster.")

            if writerIndex == 0 {
                let liveTimeline = try #require(request.liveKeyframeTimeline)
                #expect(request.node.profileIndex == 1)
                #expect(liveTimeline.runID == liveEntry.runID)
                #expect(SourceFilePaths.canonical(URL(fileURLWithPath: liveTimeline.resultPath))
                    == SourceFilePaths.canonical(URL(fileURLWithPath: writerPath)))
                #expect(liveTimeline.outputBlockName == "BaseOutput")
                #expect(liveTimeline.profiles.first(where: { $0.index == 1 })?.name == "01Jan2025 01:00:00")
                #expect(liveTimeline.profiles.first(where: { $0.index == 1 })?.time == "2025-01-01T01:00:00.0000000Z")
                #expect(session.selectedTimeline?.isMetadataOnly == true)
                #expect(session.selectedTimeline?.steps.map(\.id) == [0, 1])
                #expect(session.selectedTimeline?.hasProvider == true,
                    "The actual live metadata timeline remains selectable while only the stable sibling is rendered.")

                session.selectedTimeline?.select(position: 0)
                try await waitUntil {
                    freshProviders[1]?.requestedIndices.contains(0) == true
                        && session.resultLayers.map(\.id) == ["sampled-slot-1-profile-0"]
                }
                #expect(session.layers(for: locator).map(\.id) == ["sampled-slot-1-profile-0"])
                #expect(session.selectedTimeline?.currentID == 0)
            }

            let requestsBeforeViewport = preparationRequests.count
            viewport.extent = extent(10)
            session.viewportChanged()
            let refreshedViewportID = "prepared-slot-\(safeIndex)-\(safeChoice.resultName)-x10"
            try await waitUntil {
                preparationRequests.count > requestsBeforeViewport
                    && session.layers(for: locator).map(\.id) == [refreshedViewportID]
            }
            let viewportRequest = try #require(preparationRequests.last)
            #expect(viewportRequest.viewport() == extent(10))
            #expect(viewportRequest.node.selections.map(\.selectionIndex) == [0, 1])
            #expect(viewportRequest.blockedSelectionIndices == Set([writerIndex]))
            #expect(session.layers(for: locator).map(\.id) == [refreshedViewportID],
                "A new viewport samples the stable sibling again without opening the protected writer slot.")
            session.endPlanCompute(capture)
            session.invalidate()
        }

        try await exercise(writerIndex: 1)
        try await exercise(writerIndex: 0)
    }

    @Test @MainActor
    func computeLeaseRefreshesOnlyHistoricalNodesOutsideExactWriterPaths() async throws {
        let projectSessionID = UUID(uuidString: "B906C50A-2513-46F1-9B70-768CC8B932F0")!
        let editorID = UUID(uuidString: "0A5582B5-78B5-49A0-8B30-E0FC191617EF")!
        let mapID = UUID(uuidString: "CA5DB39A-1D3C-4804-A1FA-5F85FD7AC9A1")!
        let projectPath = "/tmp/map-result-map/lease-project.ras"
        let projectXML = "<Project><Map name=\"Lease Map\" /></Project>"
        let map = MapResultChartMapRequest(projectPath: projectPath, projectXml: projectXML,
            projectXmlSHA: "lease-project-xml-sha", mapID: mapID.uuidString,
            mapIndex: 0, mapName: "Lease Map", mapType: "Plan",
            expectedVisualizationRevision: "lease-vis-sha")
        let planPath = "/tmp/map-result-map/Lease Plan.p02"
        let safeChoice = MapResultChartSourceChoice(resultPath: "/tmp/map-result-map/old.h5",
            revision: "old-result-sha", resultName: "Old", planName: "Lease Plan",
            endTime: nil, isComputing: false)
        let writerPath = "/tmp/map-result-map/Lease Plan active.hdf"
        let writerChoice = MapResultChartSourceChoice(resultPath: writerPath,
            revision: "writer-temporary-revision", resultName: "Active", planName: "Lease Plan",
            endTime: nil, isComputing: true)
        let safeLocator = CatalogTreeNodeLocator(rootName: "Results", nodeType: "MultiResult",
            nodeName: "Safe Plan", nodePath: [0, 0], assetID: "/tmp/map-result-map/Safe.p02", mapType: "Depth")
        let writerLocator = CatalogTreeNodeLocator(rootName: "Results", nodeType: "MultiResult",
            nodeName: "Lease Plan", nodePath: [0, 1], assetID: planPath, mapType: "WSE")
        func makeNode(_ locator: CatalogTreeNodeLocator,
                      choice: MapResultChartSourceChoice) -> MapResultChartActiveNode {
            MapResultChartActiveNode(node: locator, nodeKind: "MultiResult", name: locator.nodeName,
                selections: [.init(selectionIndex: 0, selectionMode: .latest,
                    selectedResult: choice, choices: [choice, safeChoice])],
                selectedMapType: locator.mapType, profileIndex: 0)
        }
        let safeNode = makeNode(safeLocator, choice: safeChoice)
        let writerNode = makeNode(writerLocator, choice: writerChoice)
        func snapshot(map: MapResultChartMapRequest, token: String) -> MapResultSourcesSnapshot {
            let sources = MapResultChartSources(projectPath: map.projectPath,
                projectRevision: "lease-project-revision", mapID: map.mapID,
                mapIndex: map.mapIndex, mapName: map.mapName, mapType: map.mapType,
                projectXmlSHA: map.projectXmlSHA, visualizationRevision: map.expectedVisualizationRevision,
                contextToken: token, activeNodes: [safeNode, writerNode])
            return MapResultSourcesSnapshot(map: map, identity: projectSessionID.uuidString + "|lease-map",
                sources: sources, selectionOverrides: [])
        }
        let initialSnapshot = snapshot(map: map, token: "before-lease")
        let viewport = MapResultMapViewportBox()
        viewport.extent = extent(0)
        var preparedNodeIDs: [String] = []
        let safeStatus = MapResultRenderSourceStatus(resultPath: safeChoice.resultPath,
            revision: safeChoice.revision, resultName: safeChoice.resultName,
            selectionIndices: [0], terrainPath: nil, terrainRevision: nil,
            available: false, profileIndex: 0, unavailableReason: "Source Result has no map payload.")
        let session = MapResultMapSession(prepareNode: { request in
            preparedNodeIDs.append(request.node.id)
            let selected = request.node.selections.first?.selectedResult ?? safeChoice
            let layer = try makeLayer(id: "prepared-" + request.node.id + "-" + selected.resultName,
                mapID: request.mapID)
            let update = MapUpdate(vectors: nil, rasters: [layer], preview: [],
                selectedLayerID: nil, selectedFeatureID: nil,
                rasterSelectionIndicesByLayerID: [layer.id: [0]],
                rasterSourceIdentityByLayerID: [layer.id: MapRasterSourceIdentity(
                    resultPath: selected.resultPath, revision: selected.revision)])
            return MapResultMapSession.PreparedNode(
                presentation: .init(sourceID: request.node.id, steps: [.init(id: 0, label: "T0")], selectedID: 0),
                provider: ImmediateMapProfileProvider(mapID: request.mapID), initialUpdate: update,
                initialLegends: [], initialUnavailableReason: nil,
                initialSourceStatuses: request.node.id == safeNode.id ? [safeStatus] : [],
                renderedViewport: request.viewport(),
                availability: {
                    MapResultMapAvailability(reason: nil,
                        sourceStatuses: request.node.id == safeNode.id ? [safeStatus] : [])
                })
        })
        session.configure(snapshot: initialSnapshot, projectSessionID: projectSessionID,
            viewport: { viewport.extent }, isCurrent: { true })
        try await waitUntil { !session.isLoading && session.resultLayers.count == 2 }

        let capture = WorkspaceResultComputeCapture(projectSessionID: projectSessionID,
            editorID: editorID, operationOwnerToken: "lease-owner", operationContextID: "lease-context",
            projectPath: projectPath, projectRevision: "lease-project-revision",
            projectXmlFingerprint: map.projectXmlSHA, planPath: planPath, planRevision: "plan-sha")
        var entry = WorkspaceResultComputeEntry(runID: "9B688684-5A34-4424-8A51-4FC5128D440E",
            projectSessionID: projectSessionID, editorID: editorID,
            operationOwnerToken: capture.operationOwnerToken, operationContextID: capture.operationContextID,
            projectPath: capture.projectPath, projectRevision: capture.projectRevision,
            projectXmlFingerprint: capture.projectXmlFingerprint, planPath: capture.planPath,
            planRevision: capture.planRevision, resultPath: writerPath, resultName: "Active",
            resultRevision: nil, status: .running, fraction: 0.5, message: nil,
            taskName: "Solving", failureReason: nil)
        var profileTimeline = LiveMapResultProfileTimeline(identity: .init(entry: entry))
        let appendedProfile = profileTimeline.append(BackendResultProfilesUpdate(outputBlockName: "BaseOutput",
            startIndex: 0, profileCount: 1, profiles: [
                .init(index: 0, name: "01Jan2025 00:00:00", time: "2025-01-01T00:00:00.0000000Z")
            ]))
        #expect(appendedProfile)
        entry.profileTimeline = profileTimeline
        let lease = MapResultComputeReadLease(projectSessionID: projectSessionID.uuidString,
            runID: entry.runID, projectPath: projectPath,
            protectedSourcePaths: ["/tmp/map-result-map/Geometry.h5", writerPath],
            callbackResultPath: writerPath)
        session.beginPlanCompute(capture)
        session.updateLiveComputeSelection(nodeID: writerNode.id, selectionIndex: 0,
            entry: entry, timeline: profileTimeline)
        #expect(session.layers(for: writerLocator).isEmpty,
            "The existing cached raster for the writer-owned live slot is hidden before refresh.")
        let previousRequests = preparedNodeIDs.count

        var leasedMap = map
        leasedMap.computeReadLease = lease
        let leasedSnapshot = snapshot(map: leasedMap, token: "writer-excluded-snapshot")
        let accepted = await session.refreshHistoricalResultsDuringCompute(snapshot: leasedSnapshot,
            capture: capture, entry: entry, lease: lease, isCurrent: { true })
        #expect(accepted)
        #expect(Array(preparedNodeIDs.dropFirst(previousRequests)) == [safeNode.id],
            "Only the node whose exact Result paths are disjoint from the lease receives a historical prepare request.")
        #expect(session.layers(for: safeLocator).first?.name.contains("Old") == true,
            "A safe historical Result refresh installs its real prepared layer.")
        #expect(session.availability(for: safeLocator)?.sourceStatuses.first?.unavailableReason
            == "Source Result has no map payload.",
            "The property query returns status only for the exact active result row.")
        #expect(session.layers(for: writerLocator).isEmpty,
            "The protected writer's cached pixels remain hidden while its logical live slot stays selected.")
        #expect(session.liveMapRenderTargets(capture: capture, entry: entry)
            .contains(where: { $0.nodeID == writerNode.id && $0.selectionIndex == 0 }),
            "Refreshing a separate historical node preserves the active compute target identity.")
        session.endPlanCompute(capture)
        session.invalidate()
    }

    private func makeSnapshot(mapID: UUID) -> MapResultSourcesSnapshot {
        let projectXML = "<Project><Map name=\"Map\" /></Project>"
        let map = MapResultChartMapRequest(
            projectPath: "/tmp/map-result-map/model.ras", projectXml: projectXML,
            projectXmlSHA: "project-sha", mapID: mapID.uuidString,
            mapIndex: 0, mapName: "Map", mapType: "Plan",
            expectedVisualizationRevision: "vis-revision")
        let choice = MapResultChartSourceChoice(resultPath: "/tmp/map-result-map/run.hdf",
            revision: "result-revision", resultName: "Run", planName: "Plan",
            endTime: nil, isComputing: false)
        let nodes = ["Node A", "Node B"].enumerated().map { index, name in
            let locator = CatalogTreeNodeLocator(rootName: "Results", nodeType: "MultiResult",
                nodeName: name, nodePath: [index], assetID: "multi-\(index)", mapType: "Depth")
            return MapResultChartActiveNode(node: locator, nodeKind: "MultiResult", name: name,
                selections: [.init(selectionIndex: 0, selectionMode: .latest,
                    selectedResult: choice, choices: [choice])],
                selectedMapType: "Depth", profileIndex: 0)
        }
        let sources = MapResultChartSources(projectPath: map.projectPath,
            projectRevision: "project-revision", mapID: map.mapID, mapIndex: map.mapIndex,
            mapName: map.mapName, mapType: map.mapType, projectXmlSHA: map.projectXmlSHA,
            visualizationRevision: map.expectedVisualizationRevision,
            contextToken: "context-token", activeNodes: nodes)
        return MapResultSourcesSnapshot(map: map, identity: "project-session|map|sources",
            sources: sources, selectionOverrides: [])
    }

    private func extent(_ minX: Double) -> RasterMapViewExtent {
        RasterMapViewExtent(minX: minX, minY: 0, maxX: minX + 10, maxY: 10,
            pixelWidth: 320, pixelHeight: 240)
    }

    private func makeLayer(id: String, mapID: UUID) throws -> MapRasterLayer {
        try MapRasterLayer(id: id, name: id, width: 1, height: 1,
            rgba: Data([10, 20, 30, 255]), lowerLeft: MapPoint(x: 0, y: 0),
            upperRight: MapPoint(x: 1, y: 1), sourceMapID: mapID)
    }

    private func legend(for id: String) -> MapLegend {
        MapLegend(id: id, title: id, units: "m",
            stops: [.init(id: id, position: 1, color: "#000000FF", label: "0")])
    }

    @MainActor
    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        throw Timeout()
    }

    private struct Timeout: Error {}
}
