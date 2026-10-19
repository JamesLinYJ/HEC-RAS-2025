import CryptoKit
import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

@MainActor
private final class PolylinePointEditingMemoryProvider: PolylineMapEditingProvider {
    private(set) var bytes: Data
    private let url: URL

    init(_ bytes: Data, url: URL) { self.bytes = bytes; self.url = url }

    func load(scope: PolylineMapEditingScope) async throws -> GeoJSONPolylineDocument {
        try GeoJSONPolylineDocument(data: bytes, sourceURL: url)
    }

    func revision(scope: PolylineMapEditingScope) async throws -> String { Self.digest(bytes) }

    func save(scope: PolylineMapEditingScope, expectedRevision: String, data: Data) async throws -> String {
        guard Self.digest(bytes) == expectedRevision else { throw PolylineMapEditingError.sourceChanged }
        bytes = data
        return Self.digest(data)
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02X", $0) }.joined()
    }
}

struct PolylinePointBatchEditingTests {
    @Test @MainActor
    func selectedPointSetMovesAsOneUndoableXYDeltaAndRestoresSelection() async throws {
        let source = Data(#"{"type":"FeatureCollection","foreign":{"keep":true},"features":[{"type":"Feature","id":"route","properties":{},"geometry":{"type":"LineString","coordinates":[[0,0,0,0],[5,0,10,100],[10,0,20,200],[15,0,30,300]]}}]}"#.utf8)
        let url = URL(fileURLWithPath: "/tmp/polyline-points-move.geojson")
        let provider = PolylinePointEditingMemoryProvider(source, url: url)
        let session = PolylineMapEditingSession(provider: provider)
        let scope = PolylineMapEditingScope(projectSessionID: UUID(), mapID: UUID(), layerID: url.path, canonicalPath: url.path)
        #expect(await session.ensureLoaded(scope: scope))
        let line = try #require(session.lines.first)
        session.selectLine(line.id)
        session.setTool(.editVertices)
        session.selectVertices(inRectangleFrom: MapPoint(x: 4, y: -1), to: MapPoint(x: 11, y: 1))
        #expect(session.selectedVertexIndices == Set([1, 2]))
        session.selectVertices(inRectangleFrom: MapPoint(x: 4, y: -1), to: MapPoint(x: 6, y: 1), toggle: true)
        #expect(session.selectedVertexIndices == Set([2]))
        session.selectVertices(inRectangleFrom: MapPoint(x: 4, y: -1), to: MapPoint(x: 6, y: 1), toggle: true)
        #expect(session.selectedVertexIndices == Set([1, 2]))

        #expect(await session.moveVertices(lineID: line.id, vertexIndices: [1, 2], by: MapPoint(x: 2, y: 3),
            duplicateTolerance: 0, interactionPoint: MapPoint(x: 7, y: 3)))
        #expect(session.lines.first?.points[1] == MapPoint(x: 7, y: 3))
        #expect(session.lines.first?.points[2] == MapPoint(x: 12, y: 3))
        #expect(session.selectedVertexIndices == Set([1, 2]))
        #expect(session.hasUnsavedChanges)
        #expect(provider.bytes == source)

        #expect(await session.undo())
        #expect(session.lines.first?.points[1] == MapPoint(x: 5, y: 0))
        #expect(session.selectedVertexIndices == Set([1, 2]))
        #expect(await session.redo())
        #expect(session.lines.first?.points[2] == MapPoint(x: 12, y: 3))
        #expect(session.selectedVertexIndices == Set([1, 2]))
        #expect(provider.bytes == source)
    }

    @Test @MainActor
    func pointDeleteSelectsSourceNextPointAndAllPointDeleteRemovesLine() async throws {
        let source = Data(#"{"type":"FeatureCollection","features":[{"type":"Feature","id":"route","properties":{},"geometry":{"type":"MultiLineString","coordinates":[[[0,0],[1,1],[2,2],[3,3],[4,4]],[[10,10],[11,11]]]}}]}"#.utf8)
        let url = URL(fileURLWithPath: "/tmp/polyline-points-delete.geojson")
        let provider = PolylinePointEditingMemoryProvider(source, url: url)
        let session = PolylineMapEditingSession(provider: provider)
        let scope = PolylineMapEditingScope(projectSessionID: UUID(), mapID: UUID(), layerID: url.path, canonicalPath: url.path)
        #expect(await session.ensureLoaded(scope: scope))
        let original = session.lines
        session.selectLine(original[0].id)
        session.setTool(.editVertices)
        session.selectVertex(1)
        session.selectVertex(3, toggle: true)

        #expect(await session.deleteSelectedVertices())
        #expect(session.lines.first(where: { $0.id == original[0].id })?.points == [MapPoint(x: 0, y: 0), MapPoint(x: 2, y: 2), MapPoint(x: 4, y: 4)])
        #expect(session.selectedVertexIndices == Set([1]))
        #expect(await session.undo())
        #expect(session.selectedVertexIndices == Set([1, 3]))
        #expect(await session.redo())
        #expect(session.selectedVertexIndices == Set([1]))

        session.selectLine(original[1].id)
        session.selectVertex(0)
        session.selectVertex(1, toggle: true)
        #expect(await session.deleteSelectedVertices())
        #expect(!session.lines.contains(where: { $0.id == original[1].id }))
        #expect(provider.bytes == source)
    }

    @Test @MainActor
    func deletingFinalMultiLineComponentRemovesParentFeatureAndUndoRestoresItsIdentity() async throws {
        let source = Data(#"{"type":"FeatureCollection","foreignCollection":{"keep":true},"features":[{"type":"Feature","id":"route","properties":{"name":"Route","foreignProperty":"keep"},"foreignFeature":{"keep":42},"geometry":{"type":"MultiLineString","coordinates":[[[0,0],[1,1]]] }},{"type":"Feature","id":"marker","properties":{"keep":"unrelated"},"geometry":{"type":"Point","coordinates":[20,30]}}]}"#.utf8)
        let url = URL(fileURLWithPath: "/tmp/polyline-final-component-delete.geojson")
        let provider = PolylinePointEditingMemoryProvider(source, url: url)
        let session = PolylineMapEditingSession(provider: provider)
        let scope = PolylineMapEditingScope(projectSessionID: UUID(), mapID: UUID(), layerID: url.path, canonicalPath: url.path)
        #expect(await session.ensureLoaded(scope: scope))
        let originalLine = try #require(session.lines.first)
        session.selectLine(originalLine.id)
        session.setTool(.editVertices)
        session.selectVertex(0)
        session.selectVertex(1, toggle: true)

        #expect(await session.deleteSelectedVertices())
        #expect(session.lines.isEmpty)
        #expect(session.selectedLineID == nil)
        #expect(session.hasUnsavedChanges)
        #expect(provider.bytes == source)

        #expect(await session.undo())
        #expect(session.lines.map(\.id) == [originalLine.id])
        #expect(session.selectedLineID == originalLine.id)
        #expect(session.selectedVertexIndices == Set([0, 1]))
        #expect(await session.redo())
        #expect(session.lines.isEmpty)
        #expect(session.selectedLineID == nil)
        #expect(session.hasUnsavedChanges)
        #expect(provider.bytes == source, "Edits remain an undoable in-memory draft until Save")
    }

    @Test @MainActor
    func insertingOnSegmentSelectsTheInsertedPointAndUndoRestoresPriorSelection() async throws {
        let source = Data(#"{"type":"FeatureCollection","features":[{"type":"Feature","id":"route","properties":{},"geometry":{"type":"LineString","coordinates":[[0,0,7,70],[10,0,9,90]]}}]}"#.utf8)
        let url = URL(fileURLWithPath: "/tmp/polyline-point-insert.geojson")
        let session = PolylineMapEditingSession(provider: PolylinePointEditingMemoryProvider(source, url: url))
        let scope = PolylineMapEditingScope(projectSessionID: UUID(), mapID: UUID(), layerID: url.path, canonicalPath: url.path)
        #expect(await session.ensureLoaded(scope: scope))
        let line = try #require(session.lines.first)
        session.selectLine(line.id)
        session.setTool(.editVertices)
        session.selectVertex(0)

        #expect(await session.insertVertex(lineID: line.id, after: 0, at: MapPoint(x: 5, y: 0)))
        #expect(session.selectedVertexIndices == Set([1]))
        #expect(session.lines.first?.points == [MapPoint(x: 0, y: 0), MapPoint(x: 5, y: 0), MapPoint(x: 10, y: 0)])
        #expect(await session.undo())
        #expect(session.selectedVertexIndices == Set([0]))
        #expect(await session.redo())
        #expect(session.selectedVertexIndices == Set([1]))
        #expect(session.lines.first?.points.count == 3)
    }

    @Test @MainActor
    func splitAndMergeHeldKeysAreCanvasScopedAndRestoreThePriorToolOnKeyUp() async throws {
        let source = Data(#"{"type":"FeatureCollection","features":[{"type":"Feature","id":"route","properties":{},"geometry":{"type":"LineString","coordinates":[[0,0],[10,0]]}}]}"#.utf8)
        let url = URL(fileURLWithPath: "/tmp/polyline-held-tools.geojson")
        let session = PolylineMapEditingSession(provider: PolylinePointEditingMemoryProvider(source, url: url))
        let scope = PolylineMapEditingScope(projectSessionID: UUID(), mapID: UUID(), layerID: url.path, canonicalPath: url.path)
        #expect(await session.ensureLoaded(scope: scope))
        session.setTool(.editVertices)

        #expect(!session.handleTemporaryToolKey("s", isDown: true, canvasFocused: false))
        #expect(session.tool == .editVertices)
        #expect(!session.handleTemporaryToolKey("s", isDown: true, canvasFocused: true, modifiers: [.command]))
        #expect(session.tool == .editVertices)
        #expect(session.handleTemporaryToolKey("s", isDown: true, canvasFocused: true))
        #expect(session.tool == .splitLine)
        #expect(session.handleTemporaryToolKey("s", isDown: false, canvasFocused: true))
        #expect(session.tool == .editVertices)

        #expect(session.handleTemporaryToolKey("m", isDown: true, canvasFocused: true))
        #expect(session.tool == .mergeLines)
        session.releaseTemporaryTool()
        #expect(session.tool == .editVertices)
        #expect(!session.handleTemporaryToolKey("m", isDown: true, canvasFocused: true, modifiers: [.shift]))
        #expect(session.tool == .editVertices)
    }

    @Test @MainActor
    func optionClickUsesAtVertexSplitModeWithoutChangingTheSavedDefault() async throws {
        let source = Data(#"{"type":"FeatureCollection","features":[{"type":"Feature","id":"route","properties":{},"geometry":{"type":"LineString","coordinates":[[0,0],[10,0]]}}]}"#.utf8)
        let url = URL(fileURLWithPath: "/tmp/polyline-alt-split.geojson")
        let session = PolylineMapEditingSession(provider: PolylinePointEditingMemoryProvider(source, url: url))
        let scope = PolylineMapEditingScope(projectSessionID: UUID(), mapID: UUID(), layerID: url.path, canonicalPath: url.path)
        #expect(await session.ensureLoaded(scope: scope))
        session.setTool(.splitLine)

        #expect(!(await session.splitNearestLine(near: MapPoint(x: 5, y: 0), maximumDistance: 0.1, optionToggledMode: true)))
        #expect(session.splitMode == .anywhere)
        #expect(session.lines.first?.points.count == 2)
        #expect(await session.splitNearestLine(near: MapPoint(x: 5, y: 0), maximumDistance: 0.1))
        #expect(session.lines.count == 2)
        #expect(session.splitMode == .anywhere)
    }
}
