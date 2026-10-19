import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

@MainActor
private final class ProjectGeometryMapProviderFixture: ProjectGeometryMapProvider {
    private(set) var requests: [MapGeometryRequest] = []
    private var pending: [Int: CheckedContinuation<MapGeometrySnapshot, any Error>] = [:]
    var suspendedRequestIDs: Set<Int> = []

    func load(_ request: MapGeometryRequest,
              capture: ProjectGeometryMapCapture) async throws -> MapGeometrySnapshot {
        requests.append(request)
        let requestID = requests.count
        if suspendedRequestIDs.contains(requestID) {
            return try await withCheckedThrowingContinuation { pending[requestID] = $0 }
        }
        return Self.snapshot(request, capture: capture)
    }

    func finish(_ requestID: Int, capture: ProjectGeometryMapCapture) {
        guard let continuation = pending.removeValue(forKey: requestID),
              requests.indices.contains(requestID - 1) else { return }
        continuation.resume(returning: Self.snapshot(requests[requestID - 1], capture: capture))
    }

    private static func snapshot(_ request: MapGeometryRequest,
                                 capture: ProjectGeometryMapCapture) -> MapGeometrySnapshot {
        let extent = GeometryTopologyExtent(minX: 0, minY: 0, maxX: 4, maxY: 4)
        let areaID = "flow-area-0"
        let area = MapGeometryFlowAreaSource(id: areaID, rowIndex: 0, name: "Source area",
            targetedCellSpacing: 1, hasMesh: true, cellCount: 3, faceCount: 4,
            nodeCount: 4, extent: GeometryMeshExtent(minX: 0, minY: 0, maxX: 4, maxY: 4),
            hasMeshErrors: false, hasPropertyTables: true, propertyTablesPinned: true, metadata: [])
        let pageIndex: Int
        if let cursor = request.cellCursor, let last = cursor.last, let value = last.wholeNumberValue {
            pageIndex = value
        } else {
            pageIndex = 0
        }
        let cell = GeometryMeshMapCell(id: "flow-area-0:cell:\(pageIndex)",
            flowAreaID: areaID, flowAreaName: area.name, meshIndex: 0, cellIndex: pageIndex,
            coordinates: [
                .init(x: Double(pageIndex), y: 0), .init(x: Double(pageIndex + 1), y: 0),
                .init(x: Double(pageIndex + 1), y: 1), .init(x: Double(pageIndex), y: 1)
            ])
        let nextIndex = pageIndex + 1
        let nextCursor = nextIndex < 3 ? "cell-\(nextIndex)" : nil
        let topology = MapGeometryLayerState(nodeID: "topology-node", locator: childLocator(
            parent: capture.geometryNode, type: "ConceptualMesh", name: "ConceptualMesh"),
            isChecked: true, effectiveVisible: false, status: .empty, diagnostic: nil)
        let flowAreas = MapGeometryLayerState(nodeID: "flow-area-node", locator: childLocator(
            parent: capture.geometryNode, type: "FlowAreaLayer", name: "FlowAreaLayer"),
            isChecked: true, effectiveVisible: true, status: .available, diagnostic: nil)
        let culverts = MapGeometryLayerState(nodeID: nil, locator: nil, isChecked: false,
            effectiveVisible: false, status: .unavailable, diagnostic: "No source child.")
        return MapGeometrySnapshot(mapID: request.map.mapID, mapIndex: request.map.mapIndex,
            mapName: request.map.mapName, mapType: request.map.mapType,
            projectCanonicalPath: request.map.projectPath, projectRevision: "project-revision",
            projectXmlSHA: request.map.projectXmlSHA,
            visualizationRevision: request.map.expectedVisualizationRevision,
            contextToken: "fixture-context-token", geometryNode: capture.geometryNode,
            geometryName: capture.geometryName, geometryCanonicalPath: capture.geometryCanonicalPath,
            geometryRevision: String(repeating: "A", count: 64), geometryChecked: true,
            geometryEffectiveVisible: true, extent: extent, planNodes: request.planNodes,
            topologyState: topology,
            flowAreasState: flowAreas, culvertsState: culverts,
            topology: request.skipTopologyPage ? nil : MapGeometryTopologyPage(
                sourceExtent: extent, sourceFeatureCount: 0, scannedFeatureCount: 0,
                returnedFeatureCount: 0, invalidFeatureCount: 0, omittedSourceFeatureCount: 0,
                features: [], complete: true, nextCursor: nil),
            flowAreas: request.skipFlowAreasPage ? nil : MapGeometryFlowAreasPage(
                sourceExtent: extent, areas: [area], sourceCellCount: 3,
                scannedSourceCellCount: 1, returnedCellCount: 1, invalidCellCount: 0,
                cells: [cell], complete: nextCursor == nil, nextCursor: nextCursor),
            culverts: request.skipCulvertsPage ? nil : MapGeometryCulvertsPage(
                sourceExtent: nil, sourceBarrelCount: 0, scannedSourceBarrelCount: 0,
                returnedBarrelCount: 0, invalidFeatureCount: 0, features: [],
                complete: true, nextCursor: nil))
    }

    private static func childLocator(parent: CatalogTreeNodeLocator, type: String,
                                     name: String) -> CatalogTreeNodeLocator {
        let path = parent.nodePath ?? []
        return CatalogTreeNodeLocator(rootName: parent.rootName, nodeType: type, nodeName: name,
            nodePath: path + [0], assetID: parent.assetID,
            parentGeometryAssetID: parent.assetID, parentGeometryNodePath: path,
            parentGeometryNodeName: parent.nodeName)
    }
}

@Suite(.serialized)
struct ProjectGeometryMapSessionTests {
    @Test @MainActor
    func automaticPagingDrainsEveryCellAndKeepsCameraExtentStableAcrossPages() async throws {
        let fixture = try makeFixture()
        let provider = ProjectGeometryMapProviderFixture()
        provider.suspendedRequestIDs = [2]
        let session = ProjectGeometryMapSession()

        await session.configure(map: fixture.map, workflowIdentity: "workflow-a",
            captures: [fixture.capture], provider: provider, isCurrent: { true })
        try await waitUntil { provider.requests.count == 2 && session.sources.first?.cells.count == 1 }
        let firstPageCameraRevision = session.cameraExtentRevision
        #expect(session.sources[0].cells.map(\.cellIndex) == [0])

        provider.finish(2, capture: fixture.capture)
        try await waitUntil { !session.isLoading && session.sources.first?.cellsProgress.complete == true }

        #expect(provider.requests.count == 3)
        #expect(provider.requests.map(\.cellCursor) == [nil, "cell-1", "cell-2"])
        #expect(session.sources[0].cells.map(\.cellIndex) == [0, 1, 2])
        #expect(session.sources[0].cellsProgress.sourceCount == 3)
        #expect(session.sources[0].cellsProgress.returnedCount == 3)
        #expect(session.visibleGeometryFeatureCount == 3)
        #expect(session.visiblePoints == [MapPoint(x: 0, y: 0), MapPoint(x: 4, y: 4)])
        #expect(session.cameraExtentRevision == firstPageCameraRevision,
            "Installing later pages with the same source extent must not move the map camera.")
    }

    @Test @MainActor
    func pauseStopsAfterCurrentPageAndResumeContinuesFromItsCursor() async throws {
        let fixture = try makeFixture()
        let provider = ProjectGeometryMapProviderFixture()
        provider.suspendedRequestIDs = [2]
        let session = ProjectGeometryMapSession()

        await session.configure(map: fixture.map, workflowIdentity: "workflow-a",
            captures: [fixture.capture], provider: provider, isCurrent: { true })
        try await waitUntil { provider.requests.count == 2 }
        session.pausePaging()
        provider.finish(2, capture: fixture.capture)
        try await waitUntil { !session.isLoading && session.isPaused }

        #expect(provider.requests.count == 2)
        #expect(session.sources[0].cells.map(\.cellIndex) == [0, 1])
        #expect(session.sources[0].cellsProgress.nextCursor == "cell-2")
        #expect(session.canContinuePaging)

        session.resumePaging()
        try await waitUntil { !session.isLoading && session.sources.first?.cellsProgress.complete == true }
        #expect(provider.requests.count == 3)
        #expect(provider.requests[2].cellCursor == "cell-2")
        #expect(session.sources[0].cells.map(\.cellIndex) == [0, 1, 2])
        #expect(!session.isPaused)
    }

    @Test @MainActor
    func pausedViewportChangeCancelsOldPageAndWaitsForExplicitContinue() async throws {
        let fixture = try makeFixture()
        let provider = ProjectGeometryMapProviderFixture()
        provider.suspendedRequestIDs = [2, 3]
        let session = ProjectGeometryMapSession()

        await session.configure(map: fixture.map, workflowIdentity: "workflow-a",
            captures: [fixture.capture], provider: provider, isCurrent: { true })
        try await waitUntil { provider.requests.count == 2 && session.sources.first?.cells.count == 1 }

        session.pausePaging()
        let nextViewport = ViewportRequest(
            lowerLeft: MapPoint(x: 1, y: 1), upperRight: MapPoint(x: 3, y: 3),
            animated: false, padding: 0)
        let nextViewportIdentity = try #require(MapGeometryViewport(extent: nextViewport)?.identity)
        await session.updateViewport(nextViewport)

        try await waitUntil {
            session.sources.first?.viewportIdentity == nextViewportIdentity
                && session.isPaused && !session.isLoading
        }
        #expect(provider.requests.count == 2,
            "Panning while paused must cancel the old request without starting the new viewport.")
        #expect(session.sources[0].cells.isEmpty,
            "Features from the previous viewport must be cleared while paused.")

        // The old request ignores cancellation until released. Its late reply
        // must not install into the newly selected viewport.
        provider.finish(2, capture: fixture.capture)
        try await Task.sleep(for: .milliseconds(20))
        #expect(session.sources[0].cells.isEmpty)
        #expect(session.isPaused)

        session.resumePaging()
        try await waitUntil { provider.requests.count == 3 && session.isLoading }
        #expect(provider.requests[2].viewport?.identity == nextViewportIdentity)
        #expect(provider.requests[2].cellCursor == nil,
            "The new viewport must begin from its first source page.")
        #expect(!session.isPaused)

        provider.finish(3, capture: fixture.capture)
        try await waitUntil { !session.isLoading && session.sources.first?.cellsProgress.complete == true }
        #expect(session.sources[0].cells.map(\.cellIndex) == [0, 1, 2])
        #expect(provider.requests[3...].allSatisfy { $0.viewport?.identity == nextViewportIdentity })
    }

    @Test @MainActor
    func latePageCannotInstallAfterCancelAndSameWorkflowReentryResumes() async throws {
        let fixture = try makeFixture()
        let provider = ProjectGeometryMapProviderFixture()
        provider.suspendedRequestIDs = [1, 2]
        let session = ProjectGeometryMapSession()

        await session.configure(map: fixture.map, workflowIdentity: "workflow-a",
            captures: [fixture.capture], provider: provider, isCurrent: { true })
        try await waitUntil { provider.requests.count == 1 }
        session.cancel()

        // Re-entering the same map session starts a fresh generation from the
        // retained incomplete source. A response from the canceled request is
        // deliberately released only after the new request is already active.
        await session.configure(map: fixture.map, workflowIdentity: "workflow-a",
            captures: [fixture.capture], provider: provider, isCurrent: { true })
        try await waitUntil { provider.requests.count == 2 }
        provider.finish(1, capture: fixture.capture)
        try await Task.sleep(for: .milliseconds(20))
        #expect(session.sources[0].snapshot == nil)

        provider.finish(2, capture: fixture.capture)
        try await waitUntil { !session.isLoading && session.sources.first?.cellsProgress.complete == true }
        #expect(session.sources[0].cells.map(\.cellIndex) == [0, 1, 2])
    }

    private func makeFixture() throws -> (map: MapTreeMapIdentity,
                                          capture: ProjectGeometryMapCapture) {
        let mapID = UUID()
        let projectPath = URL(fileURLWithPath: "/tmp/project-geometry-map-session/Model.ras")
        let map = MapTreeMapIdentity(projectPath: projectPath.path,
            projectXml: "<Project />", projectXmlSHA: String(repeating: "B", count: 64),
            mapID: mapID.uuidString, mapIndex: 0, mapName: "Map A", mapType: "Project",
            expectedVisualizationRevision: String(repeating: "C", count: 64))
        let geometry = CatalogTreeNodeLocator(rootName: "Geometries", nodeType: "Geometry",
            nodeName: "Geometry A", nodePath: [0, 0], assetID: "/tmp/geometry-a.hdf")
        let capture = try ProjectGeometryMapCapture(projectSessionID: UUID(), mapID: mapID,
            mapWorkflowIdentity: "workflow-a", map: map, geometryNode: geometry,
            geometryAssetPath: "/tmp/geometry-a.hdf", geometryName: "Geometry A")
        return (map, capture)
    }

    @MainActor
    private func waitUntil(timeout: Duration = .seconds(5),
                           _ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw ProjectGeometryMapSessionTestError.timedOut
    }
}

private enum ProjectGeometryMapSessionTestError: Error {
    case timedOut
}
