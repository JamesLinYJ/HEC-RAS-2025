import CryptoKit
import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

@MainActor
private final class PolylineGeoprocessMemoryProvider: PolylineMapEditingProvider {
    private(set) var bytes: Data
    private let url: URL
    var onRevision: (() -> Void)?

    init(_ bytes: Data, url: URL) { self.bytes = bytes; self.url = url }

    func load(scope: PolylineMapEditingScope) async throws -> GeoJSONPolylineDocument {
        try GeoJSONPolylineDocument(data: bytes, sourceURL: url)
    }
    func revision(scope: PolylineMapEditingScope) async throws -> String {
        onRevision?()
        return Self.digest(bytes)
    }
    func save(scope: PolylineMapEditingScope, expectedRevision: String, data: Data) async throws -> String {
        guard Self.digest(bytes) == expectedRevision else { throw PolylineMapEditingError.sourceChanged }
        bytes = data
        return Self.digest(data)
    }
    func externalWrite(_ data: Data) { bytes = data }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02X", $0) }.joined()
    }
}

@MainActor
private final class PolylineGeoprocessStub: PolylineGeoprocessProvider {
    var result: PolylineGeoprocessResult
    var onTransform: (() -> Void)?
    private(set) var requests: [PolylineGeoprocessRequest] = []

    init(result: PolylineGeoprocessResult) { self.result = result }

    func transform(_ request: PolylineGeoprocessRequest) async throws -> PolylineGeoprocessResult {
        requests.append(request)
        await Task.yield()
        onTransform?()
        return result
    }
}

struct PolylineGeoprocessTests {
    @Test @MainActor
    func filterUsesRetainedProviderAndKeepsAstIdentityAcrossUndoRedoSave() async throws {
        let original = Data(#"{"type":"FeatureCollection","foreign":{"keep":true},"features":[{"type":"Feature","id":"river","foreignFeature":{"label":"keep"},"properties":{"name":"River","rank":3.500},"geometry":{"type":"LineString","foreignGeometry":9,"coordinates":[[0,0],[1,0.1],[2,0],[3,4]]}}]}"#.utf8)
        let url = URL(fileURLWithPath: "/tmp/polyline-filter-session.geojson")
        let source = PolylineGeoprocessMemoryProvider(original, url: url)
        let transform = PolylineGeoprocessStub(result: PolylineGeoprocessResult(coordinates: [[0, 0], [2, 0], [3, 4]]))
        let session = PolylineMapEditingSession(provider: source, geoprocessProvider: transform)
        let scope = PolylineMapEditingScope(projectSessionID: UUID(), mapID: UUID(), layerID: url.path, canonicalPath: url.path)
        #expect(await session.ensureLoaded(scope: scope))
        let line = try #require(session.lines.first)
        session.selectLine(line.id)
        #expect(session.selectedLineSupportsXYGeoprocessing)
        #expect(await session.filterSelectedLine(epsilon: 0.2))
        #expect(transform.requests.count == 1)
        #expect(transform.requests[0].operation == "filter")
        #expect(transform.requests[0].epsilon == 0.2)
        #expect(transform.requests[0].coordinates == [[0, 0], [1, 0.1], [2, 0], [3, 4]])
        #expect(session.lines.first?.id == line.id)
        #expect(session.lines.first?.points == [MapPoint(x: 0, y: 0), MapPoint(x: 2, y: 0), MapPoint(x: 3, y: 4)])
        #expect(session.hasUnsavedChanges)
        #expect(source.bytes == original)

        #expect(await session.undo())
        #expect(session.lines.first?.points == line.points)
        #expect(await session.redo())
        #expect(session.lines.first?.points.count == 3)
        #expect(await session.save())
        let saved = String(decoding: source.bytes, as: UTF8.self)
        #expect(saved.contains("\"id\":\"river\""))
        #expect(saved.contains("\"foreign\":{\"keep\":true}"))
        #expect(saved.contains("\"foreignFeature\":{\"label\":\"keep\"}"))
        #expect(saved.contains("\"rank\":3.500"))
        #expect(saved.contains("\"foreignGeometry\":9"))
        #expect(saved.contains("[[0,0],[2,0],[3,4]]"))
    }

    @Test @MainActor
    func smoothUsesRetainedWindowAndPassSettings() async throws {
        let original = Data(#"{"type":"FeatureCollection","features":[{"type":"Feature","id":"line","properties":{},"geometry":{"type":"LineString","coordinates":[[0,0],[1,0],[2,2],[3,0],[4,0]]}}]}"#.utf8)
        let url = URL(fileURLWithPath: "/tmp/polyline-smooth-session.geojson")
        let source = PolylineGeoprocessMemoryProvider(original, url: url)
        let result: [[Double]] = [[0, 0], [1, 2.0 / 3.0], [2, 2.0 / 3.0], [3, 2.0 / 3.0], [4, 0]]
        let transform = PolylineGeoprocessStub(result: PolylineGeoprocessResult(coordinates: result))
        let session = PolylineMapEditingSession(provider: source, geoprocessProvider: transform)
        let scope = PolylineMapEditingScope(projectSessionID: UUID(), mapID: UUID(), layerID: url.path, canonicalPath: url.path)
        #expect(await session.ensureLoaded(scope: scope))
        session.selectLine(session.lines.first?.id)

        #expect(await session.smoothSelectedLine(windowSize: 3, iterations: 1))
        #expect(transform.requests.first?.operation == "smooth")
        #expect(transform.requests.first?.windowSize == 3)
        #expect(transform.requests.first?.iterations == 1)
        #expect(session.lines.first?.points == result.map { MapPoint(x: $0[0], y: $0[1]) })
        #expect(source.bytes == original)
    }

    @Test @MainActor
    func threeDimensionalCoordinatesArePreservedAndNeverSentToXYAlgorithms() async throws {
        let sourceBytes = Data(#"{"type":"FeatureCollection","features":[{"type":"Feature","id":"zm","properties":{},"geometry":{"type":"LineString","coordinates":[[0,0,1,10],[1,1,2,20]]}}]}"#.utf8)
        let url = URL(fileURLWithPath: "/tmp/polyline-geoprocess-zm.geojson")
        let source = PolylineGeoprocessMemoryProvider(sourceBytes, url: url)
        let transform = PolylineGeoprocessStub(result: PolylineGeoprocessResult(coordinates: [[0, 0], [1, 1]]))
        let session = PolylineMapEditingSession(provider: source, geoprocessProvider: transform)
        let scope = PolylineMapEditingScope(projectSessionID: UUID(), mapID: UUID(), layerID: url.path, canonicalPath: url.path)
        #expect(await session.ensureLoaded(scope: scope))
        let line = try #require(session.lines.first)
        session.selectLine(line.id)

        #expect(!session.selectedLineSupportsXYGeoprocessing)
        #expect(!(await session.filterSelectedLine(epsilon: 1)))
        #expect(transform.requests.isEmpty)
        #expect(!session.hasUnsavedChanges)
        #expect(source.bytes == sourceBytes)
        #expect(session.errorMessage?.contains("two-dimensional") == true)
    }

    @Test @MainActor
    func lineSelectionChangeWhileBackendIsRunningRejectsLateCoordinates() async throws {
        let sourceBytes = Data(#"{"type":"FeatureCollection","features":[{"type":"Feature","id":"a","properties":{},"geometry":{"type":"LineString","coordinates":[[0,0],[1,0],[2,0]]}},{"type":"Feature","id":"b","properties":{},"geometry":{"type":"LineString","coordinates":[[10,0],[11,0]]}}]}"#.utf8)
        let url = URL(fileURLWithPath: "/tmp/polyline-geoprocess-selection-race.geojson")
        let source = PolylineGeoprocessMemoryProvider(sourceBytes, url: url)
        let transform = PolylineGeoprocessStub(result: PolylineGeoprocessResult(coordinates: [[0, 0], [2, 0]]))
        let session = PolylineMapEditingSession(provider: source, geoprocessProvider: transform)
        let scope = PolylineMapEditingScope(projectSessionID: UUID(), mapID: UUID(), layerID: url.path, canonicalPath: url.path)
        #expect(await session.ensureLoaded(scope: scope))
        let originalLines = session.lines
        session.selectLine(originalLines[0].id)
        transform.onTransform = { session.selectLine(originalLines[1].id) }

        #expect(!(await session.filterSelectedLine(epsilon: 0.5)))
        #expect(session.selectedLineID == originalLines[1].id)
        #expect(session.lines == originalLines)
        #expect(!session.hasUnsavedChanges)
        #expect(source.bytes == sourceBytes)
    }

    @Test @MainActor
    func externalSourceChangeDuringBackendCallKeepsDraftReadOnlyAndRejectsReply() async throws {
        let sourceBytes = Data(#"{"type":"FeatureCollection","features":[{"type":"Feature","id":"a","properties":{},"geometry":{"type":"LineString","coordinates":[[0,0],[1,0],[2,0]]}}]}"#.utf8)
        let externalBytes = Data(#"{"type":"FeatureCollection","foreign":true,"features":[]}"#.utf8)
        let url = URL(fileURLWithPath: "/tmp/polyline-geoprocess-source-race.geojson")
        let source = PolylineGeoprocessMemoryProvider(sourceBytes, url: url)
        let transform = PolylineGeoprocessStub(result: PolylineGeoprocessResult(coordinates: [[0, 0], [2, 0]]))
        let session = PolylineMapEditingSession(provider: source, geoprocessProvider: transform)
        let scope = PolylineMapEditingScope(projectSessionID: UUID(), mapID: UUID(), layerID: url.path, canonicalPath: url.path)
        #expect(await session.ensureLoaded(scope: scope))
        let line = try #require(session.lines.first)
        session.selectLine(line.id)
        transform.onTransform = { source.externalWrite(externalBytes) }

        #expect(!(await session.filterSelectedLine(epsilon: 0.5)))
        #expect(session.isSourceStale)
        #expect(session.lines.first?.id == line.id)
        #expect(session.lines.first?.points == line.points)
        #expect(!session.hasUnsavedChanges)
        #expect(source.bytes == externalBytes)
    }
}
