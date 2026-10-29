import Foundation
import Testing
@testable import HECRAS2025

@MainActor
private final class HoverIdentifySourceIdentity {
    var value: String
    init(_ value: String) { self.value = value }
}

struct MapHoverIdentifySessionTests {
    @Test @MainActor
    func modelVectorReplyAcceptsItsOriginalRendererAndRejectsAnotherModelKind() async {
        for invalid in [false, true] {
            let provider = DeferredMapHoverIdentifyProvider()
            let session = MapHoverIdentifySession(provider: provider, debounceNanoseconds: 0)
            let base = makeFlight(requestID: "model-\(invalid)", sourceIdentity: "model-owner",
                worldX: 1, screenX: 10, localFID: "14")
            let node = CatalogTreeNodeLocator(rootName: "Geometries", nodeType: "CulvertBarrelLayer",
                nodeName: "Culverts", nodePath: [0, 2])
            let source = MapHoverModelVectorCapture(node: node, rendererKind: .culvertBarrel,
                sourcePath: "/tmp/hover-geometry.hdf", sourceRevision: String(repeating: "C", count: 64),
                ownerMode: .savedSource, geometryNode: nil, geometryContextToken: "geometry-context",
                planNodes: [], resultOwner: nil, model: nil, culvertDraftState: nil,
                culvertDraftSHA256: nil, boundarySourceState: nil, boundaryContextToken: nil,
                boundaryLines: nil)
            let old = base.request
            let request = MapHoverIdentifyRequest(map: old.map, contextToken: old.contextToken,
                selectionOverrides: old.selectionOverrides, requestID: old.requestID,
                point: old.point, probePoint: old.probePoint,
                worldUnitsPerScreenPoint: old.worldUnitsPerScreenPoint,
                profileSelections: [], layers: [MapHoverLayerCapture(node: node,
                    kind: "modelVector", modelVector: source)])
            let flight = MapHoverIdentifyFlight(request: request, sourceIdentity: base.sourceIdentity,
                screenX: base.screenX, screenY: base.screenY, localEntries: [])
            session.update(flight) { "model-owner" }
            await waitForRequest(request.requestID, from: provider)
            let reply = MapHoverIdentifyResult(requestID: request.requestID,
                projectPath: request.map.projectPath, projectRevision: "project-revision",
                projectXmlSHA: request.map.projectXmlSHA,
                visualizationRevision: request.map.expectedVisualizationRevision,
                mapID: request.map.mapID, mapIndex: request.map.mapIndex,
                mapName: request.map.mapName, mapType: request.map.mapType,
                contextToken: request.contextToken, point: request.point,
                entries: [MapHoverIdentifyEntry(node: node, kind: "modelVector", label: "Culvert A",
                    value: "7", valueType: invalid ? "boundaryConditionLine" : "culvertBarrel",
                    sourcePath: source.sourcePath, sourceRevision: source.sourceRevision,
                    mapType: nil, profileIndex: nil, meshIndex: nil, elementIndex: 7)])
            provider.complete(request.requestID, with: reply)
            for _ in 0..<100 where !provider.hasReturned(request.requestID) {
                try? await Task.sleep(nanoseconds: 1_000_000)
            }
            await Task.yield()
            #expect(provider.hasReturned(request.requestID))
            #expect((session.response != nil) == !invalid)
            #expect(session.entries.count == (invalid ? 0 : 1))
            session.cancel()
        }
    }

    @Test @MainActor
    func activeBackendRasterRemainsBeforeLocalVectorHitsAfterAsyncMerge() async {
        let provider = DeferredMapHoverIdentifyProvider()
        let session = MapHoverIdentifySession(provider: provider, debounceNanoseconds: 0)
        var flight = makeFlight(requestID: "active-raster", sourceIdentity: "same-owner",
            worldX: 1, screenX: 10, localFID: "14")
        flight.preferredNodeIdentities = [flight.request.layers[0].node.sourceIdentity]
        session.update(flight) { "same-owner" }
        await waitForRequest("active-raster", from: provider)
        #expect(session.entries.map(\.value) == ["14"])

        provider.complete("active-raster", with: makeResponse(for: flight.request, value: "107"))
        for _ in 0..<100 where session.response == nil {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        #expect(session.response?.requestID == "active-raster")
        #expect(session.entries.map(\.value) == ["107", "14"])
        #expect(session.entries.first?.kind == "raster")
        session.cancel()
    }

    @Test @MainActor
    func lateSourceReplyCannotReplaceTheCurrentCursorIdentify() async {
        let provider = DeferredMapHoverIdentifyProvider()
        let session = MapHoverIdentifySession(provider: provider, debounceNanoseconds: 0)
        let currentIdentity = HoverIdentifySourceIdentity("source-first")
        let first = makeFlight(requestID: "first", sourceIdentity: currentIdentity.value,
            worldX: 1, screenX: 10, localFID: "14")
        let second = makeFlight(requestID: "second", sourceIdentity: "source-second",
            worldX: 2, screenX: 20, localFID: "28")

        session.update(first) { currentIdentity.value }
        await waitForRequest("first", from: provider)
        currentIdentity.value = "source-second"
        session.update(second) { currentIdentity.value }
        await waitForRequest("second", from: provider)
        #expect(session.entries.first?.value == "28")

        provider.complete("first", with: makeResponse(for: first.request, value: "stale"))
        try? await Task.sleep(nanoseconds: 5_000_000)
        #expect(session.response?.requestID == nil)
        #expect(session.entries.first?.value == "28")
        #expect(session.screenPoint == CGPoint(x: 20, y: 30))

        provider.complete("second", with: makeResponse(for: second.request, value: "current"))
        try? await Task.sleep(nanoseconds: 5_000_000)
        #expect(session.response?.requestID == "second")
        #expect(session.response?.entries.first?.value == "current")
        #expect(session.entries.map(\.value) == ["28", "current"])
        #expect(session.screenPoint == CGPoint(x: 20, y: 30))
        session.cancel()
    }

    @MainActor
    private func waitForRequest(_ id: String,
                               from provider: DeferredMapHoverIdentifyProvider) async {
        for _ in 0..<100 where !provider.hasRequest(id) {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        #expect(provider.hasRequest(id))
    }

    private func makeFlight(requestID: String, sourceIdentity: String,
                            worldX: Double, screenX: Double,
                            localFID: String) -> MapHoverIdentifyFlight {
        let mapID = "00000000-0000-0000-0000-000000000009"
        let node = CatalogTreeNodeLocator(rootName: "Map", nodeType: "MapLayer",
            nodeName: "Depth", nodePath: [0], mapType: "SingleBandRasterMapLayer")
        let vectorNode = CatalogTreeNodeLocator(rootName: "Map", nodeType: "MapLayer",
            nodeName: "Channel", nodePath: [1], mapType: "PolylineMapLayer")
        let map = MapResultChartMapRequest(projectPath: "/tmp/hover.ras",
            projectXml: "<Project />", projectXmlSHA: String(repeating: "A", count: 64),
            mapID: mapID, mapIndex: 0, mapName: "Map", mapType: "Project",
            expectedVisualizationRevision: String(repeating: "B", count: 64))
        let request = MapHoverIdentifyRequest(map: map, contextToken: "context",
            selectionOverrides: [], requestID: requestID,
            point: MapHoverCoordinate(x: worldX, y: 3),
            probePoint: MapHoverCoordinate(x: worldX + 0.01, y: 3),
            worldUnitsPerScreenPoint: 0.01, profileSelections: [],
            layers: [MapHoverLayerCapture(node: node, kind: "raster",
                sourcePath: "/tmp/hover.tif", sourceRevision: String(repeating: "C", count: 64),
                mapType: "SingleBandRasterMapLayer")])
        return MapHoverIdentifyFlight(request: request, sourceIdentity: sourceIdentity,
            screenX: screenX, screenY: 30,
            localEntries: [MapHoverIdentifyEntry(node: vectorNode, kind: "vector",
                label: "Channel · FID: \(localFID)", value: localFID, valueType: "feature-id",
                sourcePath: "/tmp/channel.geojson", sourceRevision: String(repeating: "D", count: 64),
                mapType: "PolylineMapLayer", profileIndex: nil, meshIndex: nil, elementIndex: nil)])
    }

    private func makeResponse(for request: MapHoverIdentifyRequest,
                              value: String) -> MapHoverIdentifyResult {
        let capture = request.layers[0]
        return MapHoverIdentifyResult(requestID: request.requestID,
            projectPath: request.map.projectPath, projectRevision: "project-revision",
            projectXmlSHA: request.map.projectXmlSHA,
            visualizationRevision: request.map.expectedVisualizationRevision,
            mapID: request.map.mapID, mapIndex: request.map.mapIndex,
            mapName: request.map.mapName, mapType: request.map.mapType,
            contextToken: request.contextToken, point: request.point,
            entries: [MapHoverIdentifyEntry(node: capture.node, kind: "raster",
                label: "Depth: \(value)", value: value, valueType: "number",
                sourcePath: capture.sourcePath, sourceRevision: capture.sourceRevision,
                mapType: capture.mapType, profileIndex: nil, meshIndex: nil, elementIndex: nil)])
    }
}

@MainActor
private final class DeferredMapHoverIdentifyProvider: MapHoverIdentifyProviding {
    private var continuations: [String: CheckedContinuation<MapHoverIdentifyResult, Error>] = [:]
    private var returned: Set<String> = []

    func identify(_ request: MapHoverIdentifyRequest) async throws -> MapHoverIdentifyResult {
        let result: MapHoverIdentifyResult = try await withCheckedThrowingContinuation { continuation in
            continuations[request.requestID] = continuation
        }
        returned.insert(request.requestID)
        return result
    }

    func hasRequest(_ id: String) -> Bool { continuations[id] != nil }
    func hasReturned(_ id: String) -> Bool { returned.contains(id) }

    func complete(_ id: String, with response: MapHoverIdentifyResult) {
        continuations.removeValue(forKey: id)?.resume(returning: response)
    }
}
