import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

@MainActor
private final class AssociatedMapLayerProviderFixture: AssociatedMapLayerProvider {
    private(set) var requests: [AssociatedMapLayersRequest] = []
    private(set) var captures: [[AssociatedMapLayerCapture]] = []
    private var pending: [Int: CheckedContinuation<AssociatedMapLayersSnapshot, any Error>] = [:]
    var suspendedRequestIDs: Set<Int> = []
    var sourceExtents: [CatalogTreeNodeLocator: MapGeometryViewport] = [:]
    var emptyLocators: Set<CatalogTreeNodeLocator> = []
    var sourceRevision = String(repeating: "D", count: 64)

    func load(_ request: AssociatedMapLayersRequest,
              captures: [AssociatedMapLayerCapture]) async throws -> AssociatedMapLayersSnapshot {
        requests.append(request)
        self.captures.append(captures)
        let requestID = requests.count
        if suspendedRequestIDs.contains(requestID) {
            return try await withCheckedThrowingContinuation { pending[requestID] = $0 }
        }
        return try snapshot(request, captures: captures)
    }

    func finish(_ requestID: Int) {
        guard let continuation = pending.removeValue(forKey: requestID),
              requests.indices.contains(requestID - 1), captures.indices.contains(requestID - 1) else { return }
        do {
            continuation.resume(returning: try snapshot(requests[requestID - 1],
                captures: captures[requestID - 1]))
        } catch {
            continuation.resume(throwing: error)
        }
    }

    private func snapshot(_ request: AssociatedMapLayersRequest,
                          captures: [AssociatedMapLayerCapture]) throws -> AssociatedMapLayersSnapshot {
        let layers = try captures.map { capture in
            let pixelCount = request.width * request.height
            let isEmpty = emptyLocators.contains(capture.associationNode)
            let isHidden = !capture.isChecked || !capture.effectiveVisible
            let payload = AssociatedMapLayerPayloadFixture(
                locator: capture.associationNode,
                geometryNodes: capture.geometryNodes,
                planNodes: capture.planNodes,
                resultOwners: capture.resultOwners,
                kind: AssociatedMapLayerCapture.supportedKind(capture.associationNode.associationKind)!,
                assetPath: capture.assetPath,
                revision: sourceRevision,
                dependencies: [AssociatedMapLayerDependencyFixture(path: capture.assetPath,
                    revision: sourceRevision, role: "source-hdf")],
                status: isHidden ? .hidden : isEmpty ? .empty : .available,
                diagnostic: nil,
                isChecked: capture.isChecked,
                effectiveVisible: capture.effectiveVisible,
                sourceExtent: sourceExtents[capture.associationNode],
                width: request.width,
                height: request.height,
                rgba: isHidden || isEmpty ? Data() : Data(repeating: 0x7F, count: pixelCount * 4),
                legend: [AssociatedMapLayerLegendFixture(value: "1", label: "Source class",
                    red: 127, green: 127, blue: 127, alpha: 255)])
            return try JSONDecoder().decode(AssociatedMapLayerPayload.self,
                from: JSONEncoder().encode(payload))
        }
        return AssociatedMapLayersSnapshot(mapID: request.map.mapID,
            mapIndex: request.map.mapIndex, mapName: request.map.mapName,
            mapType: request.map.mapType, projectCanonicalPath: request.map.projectPath,
            projectRevision: String(repeating: "A", count: 64),
            projectXmlSHA: request.map.projectXmlSHA,
            visualizationRevision: request.map.expectedVisualizationRevision,
            contextToken: "associated-layer-context",
            viewport: request.viewport, layers: layers)
    }
}

/// The production payload has a validating custom decoder and intentionally
/// exposes no memberwise initializer. Encode this test fixture through the
/// same wire shape so new exact owner echoes stay covered.
private struct AssociatedMapLayerPayloadFixture: Encodable {
    let locator: CatalogTreeNodeLocator
    let geometryNodes: [CatalogTreeNodeLocator]
    let planNodes: [CatalogTreeNodeLocator]
    let resultOwners: [MapResultGeometryOwner]
    let kind: AssociatedMapLayerKind
    let assetPath: String
    let revision: String
    let dependencies: [AssociatedMapLayerDependencyFixture]
    let status: AssociatedMapLayerStatus
    let diagnostic: String?
    let isChecked: Bool
    let effectiveVisible: Bool
    let sourceExtent: MapGeometryViewport?
    let width: Int
    let height: Int
    let rgba: Data
    let legend: [AssociatedMapLayerLegendFixture]
}

private struct AssociatedMapLayerDependencyFixture: Encodable {
    let path: String
    let revision: String
    let role: String
}

private struct AssociatedMapLayerLegendFixture: Encodable {
    let value: String
    let label: String
    let red: Int
    let green: Int
    let blue: Int
    let alpha: Int
}

@Suite(.serialized)
struct AssociatedMapLayerSessionTests {
    @Test
    func sourceExtentRejectsOverflowingFiniteEndpoints() {
        let extent = MapGeometryViewport(minX: -Double.greatestFiniteMagnitude,
            minY: 0, maxX: Double.greatestFiniteMagnitude, maxY: 1)
        #expect(extent.isFiniteAndOrdered)
        #expect(!extent.hasFinitePositiveArea,
            "Finite endpoints can still produce an infinite span and must not become camera bounds.")
    }

    @Test @MainActor
    func captureRequiresExactLayerAssetAndGeometryLocators() throws {
        let fixture = makeFixture()
        let capture = try fixture.capture()
        let associationAssetID = try #require(capture.associationNode.associationAssetID)
        #expect(SourceFilePaths.canonical(URL(fileURLWithPath: associationAssetID)) == capture.assetPath)
        #expect(capture.geometryNodes == [fixture.geometryNode])

        let nameOnly = CatalogTreeNodeLocator(rootName: "Matching Layers", nodeType: "Terrain",
            nodeName: fixture.associationNode.nodeName, nodePath: [1],
            assetID: fixture.associationNode.assetID,
            associationAssetID: "/tmp/another-project/terrain.hdf", associationKind: "Terrain")
        #expect(throws: AssociatedMapLayerCaptureError.self) {
            try AssociatedMapLayerCapture(projectSessionID: fixture.projectSessionID,
                mapID: fixture.mapID, mapWorkflowIdentity: "map-owner-a", map: fixture.map,
                geometryNodes: [fixture.geometryNode], associationNode: nameOnly,
                assetPath: fixture.associationPath, isChecked: true, effectiveVisible: true)
        }

        #expect(throws: AssociatedMapLayerCaptureError.self) {
            try AssociatedMapLayerCapture(projectSessionID: fixture.projectSessionID,
                mapID: fixture.mapID, mapWorkflowIdentity: "map-owner-a", map: fixture.map,
                geometryNodes: [fixture.geometryNode, fixture.geometryNode],
                associationNode: fixture.associationNode, assetPath: fixture.associationPath,
                isChecked: true, effectiveVisible: true)
        }
    }

    @Test @MainActor
    func lateViewportReplyCannotReplaceCurrentAssociatedRaster() async throws {
        let fixture = makeFixture()
        let capture = try fixture.capture()
        let provider = AssociatedMapLayerProviderFixture()
        provider.suspendedRequestIDs = [1, 2]
        let session = AssociatedMapLayerSession()
        await session.configure(map: fixture.map, workflowIdentity: "map-owner-a",
            captures: [capture], provider: provider, isCurrent: { true })

        let firstViewport = fixture.viewport(minX: 0)
        let secondViewport = fixture.viewport(minX: 10)
        await session.updateViewport(firstViewport)
        try await waitUntil { provider.requests.count == 1 && session.isLoading }
        await session.updateViewport(secondViewport)
        try await waitUntil { provider.requests.count == 2 && session.isLoading }
        #expect(provider.requests[1].contextToken == nil,
            "A viewport change needs a fresh Host context token because the token includes bounds and pixel dimensions.")

        provider.finish(1)
        try await Task.sleep(for: .milliseconds(20))
        #expect(session.visibleLayers.isEmpty,
            "A canceled frame from the first camera must never be installed.")

        provider.finish(2)
        try await waitUntil { !session.isLoading && session.visibleLayers.count == 1 }
        let layer = try #require(session.visibleLayers.first)
        #expect(layer.lowerLeft.x == 10)
        #expect(layer.upperRight.x == 12)
        #expect(session.visiblePoints == [
            MapPoint(x: 10, y: 20), MapPoint(x: 12, y: 22)
        ])
    }

    @Test @MainActor
    func sourceExtentDrivesCameraAndSurvivesPanAndEmptyViewportPages() async throws {
        let fixture = makeFixture()
        let capture = try fixture.capture()
        let provider = AssociatedMapLayerProviderFixture()
        let sourceExtent = MapGeometryViewport(minX: -6, minY: -7, maxX: 34, maxY: 45)
        provider.sourceExtents[capture.associationNode] = sourceExtent
        let session = AssociatedMapLayerSession()
        await session.configure(map: fixture.map, workflowIdentity: "map-owner-a",
            captures: [capture], provider: provider, isCurrent: { true })

        let firstViewport = fixture.viewport(minX: 100)
        await session.updateViewport(firstViewport)
        try await waitUntil {
            !session.isLoading && session.entries.first?.status == .available
        }
        let expectedSourcePoints = [MapPoint(x: -6, y: -7), MapPoint(x: 34, y: 45)]
        #expect(session.sourceReferencePoints == expectedSourcePoints,
            "Camera bounds must use the retained source extent, not raster corners for the requested viewport.")
        #expect(session.visiblePoints == [MapPoint(x: 100, y: 20), MapPoint(x: 102, y: 22)])

        let firstSourceExtentRevision = session.sourceExtentRevision
        let hiddenCapture = try fixture.capture(isChecked: false, effectiveVisible: false)
        await session.configure(map: fixture.map, workflowIdentity: "map-owner-a",
            captures: [hiddenCapture], provider: provider, isCurrent: { true })
        try await waitUntil { !session.isLoading && session.entries.first?.status == .hidden }
        #expect(session.sourceReferencePoints.isEmpty)
        #expect(session.sourceExtentRevision > firstSourceExtentRevision,
            "Hiding a source changes the fit-point set even though its cached source extent remains valid.")

        let visibleCapture = try fixture.capture()
        await session.configure(map: fixture.map, workflowIdentity: "map-owner-a",
            captures: [visibleCapture], provider: provider, isCurrent: { true })
        try await waitUntil { !session.isLoading && session.entries.first?.status == .available }
        #expect(session.sourceReferencePoints == expectedSourcePoints)
        let stableSourceExtentRevision = session.sourceExtentRevision

        // A later viewport may contain no source samples. Its empty payload
        // must not erase the actual finite extent learned from the source.
        provider.sourceExtents.removeAll()
        provider.emptyLocators.insert(capture.associationNode)
        let emptyViewportRequestBaseline = provider.requests.count
        await session.updateViewport(fixture.viewport(minX: 300))
        try await waitUntil {
            provider.requests.count == emptyViewportRequestBaseline + 1 && !session.isLoading
                && session.entries.first?.status == .empty
        }
        #expect(session.visiblePoints.isEmpty)
        #expect(session.sourceReferencePoints == expectedSourcePoints)
        #expect(session.sourceExtentRevision == stableSourceExtentRevision,
            "Panning and an empty viewport page must not invalidate stable camera bounds.")

        provider.sourceRevision = String(repeating: "E", count: 64)
        let changedRevisionRequestBaseline = provider.requests.count
        await session.updateViewport(fixture.viewport(minX: 400))
        try await waitUntil {
            provider.requests.count == changedRevisionRequestBaseline + 1 && !session.isLoading
                && session.entries.first?.status == .empty
        }
        #expect(session.sourceReferencePoints.isEmpty,
            "A changed source revision with no finite extent must clear bounds cached for the old source.")
        #expect(session.sourceExtentRevision > stableSourceExtentRevision)
    }

    @Test @MainActor
    func bootstrapLoadsOnlySourceBoundsBeforeTheFirstRealViewport() async throws {
        let fixture = makeFixture()
        let capture = try fixture.capture()
        let provider = AssociatedMapLayerProviderFixture()
        let sourceExtent = MapGeometryViewport(minX: -45, minY: 12, maxX: 90, maxY: 160)
        provider.sourceExtents[capture.associationNode] = sourceExtent
        let session = AssociatedMapLayerSession()
        await session.configure(map: fixture.map, workflowIdentity: "map-owner-a",
            captures: [capture], provider: provider, isCurrent: { true })
        let revisionBeforeBootstrap = session.renderRevision

        await session.bootstrapSourceExtents()

        let seedRequest = try #require(provider.requests.first)
        #expect(seedRequest.width == 1 && seedRequest.height == 1)
        #expect(seedRequest.viewport == MapGeometryViewport(minX: 0, minY: 0, maxX: 1, maxY: 1))
        #expect(seedRequest.contextToken == nil)
        #expect(session.sourceReferencePoints == [
            MapPoint(x: -45, y: 12), MapPoint(x: 90, y: 160)
        ])
        #expect(session.sourceExtentRevision > 0)
        #expect(session.entries.first?.payload == nil,
            "The metadata bootstrap must not install its seed raster as a rendered frame.")
        #expect(session.visibleLayers.isEmpty && session.visiblePoints.isEmpty)
        #expect(session.renderRevision == revisionBeforeBootstrap,
            "Learning source bounds must not publish a viewport frame revision.")

        await session.bootstrapSourceExtents()
        #expect(provider.requests.count == 1,
            "A successful bootstrap is idempotent for the same source configuration.")

        await session.updateViewport(fixture.viewport(minX: 200))
        try await waitUntil {
            provider.requests.count == 2 && !session.isLoading
                && session.entries.first?.status == .available
        }
        #expect(provider.requests[1].contextToken == nil,
            "The discarded seed response token must not constrain the real viewport request.")
        #expect(provider.requests[1].viewport == MapGeometryViewport(
            minX: 200, minY: 20, maxX: 202, maxY: 22))
        #expect(session.sourceReferencePoints == [
            MapPoint(x: -45, y: 12), MapPoint(x: 90, y: 160)
        ])
        #expect(session.visiblePoints == [MapPoint(x: 200, y: 20), MapPoint(x: 202, y: 22)])
    }

    @Test @MainActor
    func visibleLayersMatchRetainedKindAndReverseTreePaintOrderWithoutReorderingEntries() async throws {
        let fixture = makeFixture()
        let sourceOrder: [(kind: String, name: String)] = [
            ("NValue", "NValue first"),
            ("Terrain", "Terrain first"),
            ("Classification", "Classification first"),
            ("Terrain", "Terrain second"),
            ("NValue", "NValue second"),
            ("Classification", "Classification second")
        ]
        let captures = try sourceOrder.enumerated().map { index, item in
            try fixture.capture(kind: item.kind, name: item.name, nodeIndex: index)
        }
        let provider = AssociatedMapLayerProviderFixture()
        let session = AssociatedMapLayerSession()
        await session.configure(map: fixture.map, workflowIdentity: "map-owner-a",
            captures: captures, provider: provider, isCurrent: { true })
        await session.updateViewport(fixture.viewport(minX: 0))
        try await waitUntil { !session.isLoading && session.visibleLayers.count == captures.count }

        #expect(session.entries.map(\.capture.associationNode.nodeName) == sourceOrder.map { $0.name },
            "Response/capture identity order must stay equal to the source tree order.")
        #expect(provider.captures.first == captures)
        let request = try #require(provider.requests.first)
        #expect(request.associationNodes == captures.map(\.associationNode))
        let paintIndices = [3, 1, 5, 2, 4, 0]
        #expect(session.visibleLayers.map(\.id) == paintIndices.map { captures[$0].identity },
            "Paint order must be Terrain, Classification, NValue, reversing tree order within each kind.")
    }

    @MainActor
    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for the associated layer operation.")
    }

    private func makeFixture() -> Fixture {
        let mapID = UUID()
        let projectSessionID = UUID()
        let projectPath = "/tmp/associated-map-project.prj"
        let geometryPath = "/tmp/associated-map-project/Geometry A.hdf"
        let associationPath = "/tmp/associated-map-project/Terrains/terrain.hdf"
        let geometry = CatalogTreeNodeLocator(rootName: "Focused Geometries",
            nodeType: "Geometry", nodeName: "Geometry A", nodePath: [0, 0],
            assetID: geometryPath)
        let association = CatalogTreeNodeLocator(rootName: "Matching Layers",
            nodeType: "Terrain", nodeName: "Terrain A", nodePath: [1, 0],
            assetID: associationPath, associationAssetID: associationPath,
            associationKind: "Terrain")
        let map = MapTreeMapIdentity(projectPath: projectPath, projectXml: "<Project />",
            projectXmlSHA: String(repeating: "B", count: 64), mapID: mapID.uuidString,
            mapIndex: 0, mapName: "Map A", mapType: "Geometry",
            expectedVisualizationRevision: String(repeating: "C", count: 64))
        return Fixture(mapID: mapID, projectSessionID: projectSessionID,
            map: map, geometryNode: geometry, associationNode: association,
            geometryPath: geometryPath, associationPath: associationPath)
    }

    private struct Fixture {
        let mapID: UUID
        let projectSessionID: UUID
        let map: MapTreeMapIdentity
        let geometryNode: CatalogTreeNodeLocator
        let associationNode: CatalogTreeNodeLocator
        let geometryPath: String
        let associationPath: String

        func capture() throws -> AssociatedMapLayerCapture {
            try capture(kind: "Terrain", name: "Terrain A", nodeIndex: 0)
        }

        func capture(isChecked: Bool, effectiveVisible: Bool) throws -> AssociatedMapLayerCapture {
            try capture(kind: "Terrain", name: "Terrain A", nodeIndex: 0,
                isChecked: isChecked, effectiveVisible: effectiveVisible)
        }

        func capture(kind: String, name: String, nodeIndex: Int,
                     workflowIdentity: String = "map-owner-a",
                     isChecked: Bool = true, effectiveVisible: Bool = true) throws -> AssociatedMapLayerCapture {
            let assetPath = "/tmp/associated-map-project/\(kind)/\(name).hdf"
            let association = CatalogTreeNodeLocator(rootName: "Matching Layers",
                nodeType: kind, nodeName: name, nodePath: [1, nodeIndex],
                assetID: assetPath, associationAssetID: assetPath, associationKind: kind)
            return try AssociatedMapLayerCapture(projectSessionID: projectSessionID,
                mapID: mapID, mapWorkflowIdentity: workflowIdentity, map: map,
                geometryNodes: [geometryNode], associationNode: association,
                assetPath: assetPath, isChecked: isChecked, effectiveVisible: effectiveVisible)
        }

        func viewport(minX: Double) -> RasterMapViewExtent {
            RasterMapViewExtent(minX: minX, minY: 20, maxX: minX + 2, maxY: 22,
                pixelWidth: 2, pixelHeight: 2)
        }
    }
}
