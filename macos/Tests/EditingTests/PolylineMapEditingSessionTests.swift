import CryptoKit
import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

@MainActor
private final class MemoryPolylineMapEditingProvider: PolylineMapEditingProvider {
    private(set) var bytes: Data
    private let url: URL
    var onRevision: (() -> Void)?

    init(bytes: Data, url: URL) { self.bytes = bytes; self.url = url }

    func load(scope: PolylineMapEditingScope) async throws -> GeoJSONPolylineDocument {
        try GeoJSONPolylineDocument(data: bytes, sourceURL: url)
    }

    func revision(scope: PolylineMapEditingScope) async throws -> String {
        onRevision?()
        return Self.digest(bytes)
    }

    func save(scope: PolylineMapEditingScope, expectedRevision: String, data: Data) async throws -> String {
        guard Self.digest(bytes) == expectedRevision else { throw PolylineMapEditingError.sourceChanged }
        bytes = data; return Self.digest(data)
    }

    func externalWrite(_ data: Data) { bytes = data }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02X", $0) }.joined()
    }
}

struct PolylineMapEditingSessionTests {
    @Test @MainActor
    func sourceBackedEditSavePreservesLayerGeometryAndStableDraftIdentity() async throws {
        let original = Data(#"{"type":"FeatureCollection","foreign":{"keep":true},"features":[{"type":"Feature","id":"main","properties":{"name":"Main","rank":3.500},"geometry":{"type":"LineString","coordinates":[[0,0,7],[10,0,9]]}},{"type":"Feature","id":"marker","properties":{"name":"Marker"},"geometry":{"type":"Point","coordinates":[2,4]}}]}"#.utf8)
        let url = URL(fileURLWithPath: "/tmp/polyline-session.geojson")
        let provider = MemoryPolylineMapEditingProvider(bytes: original, url: url)
        let session = PolylineMapEditingSession(provider: provider)
        let scope = PolylineMapEditingScope(projectSessionID: UUID(), mapID: UUID(), layerID: url.path, canonicalPath: url.path)
        #expect(await session.ensureLoaded(scope: scope))
        let sourceLine = try #require(session.lines.first)
        let originalLayer = try #require(session.currentMapLayer)
        #expect(originalLayer.features.count == 2)
        #expect(originalLayer.sourceMapID == scope.mapID)
        let originalGeneration = session.draftGeneration

        session.selectLine(sourceLine.id)
        #expect(session.draftGeneration != originalGeneration)
        #expect(await session.moveVertex(lineID: sourceLine.id, vertexIndex: 1, to: MapPoint(x: 12, y: 2)))
        #expect(session.hasUnsavedChanges)
        #expect(provider.bytes == original)
        let draftLayer = try #require(session.currentMapLayer)
        #expect(draftLayer.features.count == 2)
        #expect(draftLayer.sourceRevision == session.currentSourceRevision)
        #expect(draftLayer.features.first?.stableIdentity == sourceLine.sourceFeatureIdentity + "|geometry")
        #expect(draftLayer.features.first?.pathStableIdentities.first == sourceLine.id)
        #expect(draftLayer.features.first?.paths.first?.last == MapPoint(x: 12, y: 2))

        #expect(await session.save())
        #expect(!session.hasUnsavedChanges)
        let saved = String(decoding: provider.bytes, as: UTF8.self)
        #expect(saved.contains("\"foreign\":{\"keep\":true}"))
        #expect(saved.contains("\"rank\":3.500"))
        #expect(saved.contains("[12,2,9]"))
    }

    @Test @MainActor
    func clipboardPastePreservesZMandUsesNormalUndoRedoAndSaveDraft() async throws {
        let original = Data(#"{"type":"FeatureCollection","features":[{"type":"Feature","id":"base","properties":{"name":"Base"},"geometry":{"type":"LineString","coordinates":[[0,0],[1,1]]}}]}"#.utf8)
        let url = URL(fileURLWithPath: "/tmp/polyline-clipboard-session.geojson")
        let provider = MemoryPolylineMapEditingProvider(bytes: original, url: url)
        let session = PolylineMapEditingSession(provider: provider)
        let scope = PolylineMapEditingScope(projectSessionID: UUID(), mapID: UUID(), layerID: url.path, canonicalPath: url.path)
        #expect(await session.ensureLoaded(scope: scope))
        let sourceID = try #require(session.lines.first?.id)
        let payload = GeoprocessingPolylineClipboard(lines: [
            GeoprocessingClipboardPolyline(hasZ: true, hasM: true, vertices: [
                GeoprocessingClipboardVertex(x: 10, y: 20, z: "30.5", m: "40.25"),
                GeoprocessingClipboardVertex(x: 11, y: 21, z: "31.5", m: "41.25")
            ])
        ], coordinateProjectionWKT: nil)

        #expect(await session.pasteClipboardLines(payload, destinationProjectionWKT: nil))
        let pastedID = try #require(session.selectedLineID)
        #expect(pastedID != sourceID)
        #expect(session.selectedLineIDs == Set([pastedID]))
        #expect(session.hasUnsavedChanges)
        #expect(provider.bytes == original)
        let stagedLayer = try #require(session.currentMapLayer)
        #expect(stagedLayer.sourceRevision == session.currentSourceRevision)

        #expect(await session.undo())
        #expect(session.lines.count == 1)
        #expect(await session.redo())
        #expect(session.lines.count == 2)
        #expect(await session.save())
        let saved = String(decoding: provider.bytes, as: UTF8.self)
        #expect(saved.contains("[10,20,30.5,40.25]"))
        #expect(saved.contains("[11,21,31.5,41.25]"))
    }

    @Test @MainActor
    func selectedMapFeaturesDeleteAsOneUndoableSaveDraftAndKeepUnselectedGeometry() async throws {
        let original = Data(#"{"type":"FeatureCollection","foreign":{"keep":true},"features":[{"type":"Feature","id":"banks","properties":{"name":"Banks"},"geometry":{"type":"MultiLineString","coordinates":[[[0,0,1,10],[1,1,2,20]],[[2,2,3,30],[3,3,4,40]]]}},{"type":"Feature","id":"levee","properties":{"name":"Levee"},"geometry":{"type":"LineString","coordinates":[[4,4],[5,5]]}},{"type":"Feature","id":"marker","properties":{"name":"Keep"},"geometry":{"type":"Point","coordinates":[8,9]}}]}"#.utf8)
        let url = URL(fileURLWithPath: "/tmp/polyline-map-feature-delete.geojson")
        let provider = MemoryPolylineMapEditingProvider(bytes: original, url: url)
        let session = PolylineMapEditingSession(provider: provider)
        let scope = PolylineMapEditingScope(projectSessionID: UUID(), mapID: UUID(),
            layerID: url.path, canonicalPath: url.path)
        #expect(await session.ensureLoaded(scope: scope))

        let layer = try #require(session.currentMapLayer)
        let selected = layer.features.filter { $0.kind == .line }
        let featureIDs = Set(selected.map(\.stableIdentity))
        #expect(featureIDs.count == 2)
        #expect(session.selectMapFeatures(featureIDs, in: layer))
        #expect(session.selectedLineIDs.count == 3)
        #expect(session.canDeleteMapFeatures(featureIDs, in: layer))

        #expect(await session.deleteMapFeatures(featureIDs, in: layer))
        #expect(session.lines.isEmpty)
        #expect(session.hasUnsavedChanges)
        #expect(provider.bytes == original)
        #expect(session.currentMapLayer?.features.map(\.stableIdentity).count == 1)
        #expect(session.currentMapLayer?.features.first?.kind == .point)

        #expect(await session.undo())
        #expect(session.lines.count == 3)
        #expect(session.currentMapLayer?.features.filter { $0.kind == .line }.map(\.stableIdentity).sorted()
            == featureIDs.sorted())
        let restoredLayer = try #require(session.currentMapLayer)
        #expect(session.selectMapFeatures(featureIDs, in: restoredLayer))
        #expect(await session.deleteMapFeatures(featureIDs, in: restoredLayer))
        #expect(await session.save())
        #expect(!session.hasUnsavedChanges)

        let saved = try #require(JSONSerialization.jsonObject(with: provider.bytes) as? [String: Any])
        #expect((saved["foreign"] as? [String: Bool])?["keep"] == true)
        let savedFeatures = try #require(saved["features"] as? [[String: Any]])
        #expect(savedFeatures.compactMap { $0["id"] as? String } == ["marker"])
        #expect((savedFeatures.first?["geometry"] as? [String: Any])?["type"] as? String == "Point")
    }

    @Test @MainActor
    func clipboardPasteRejectsProjectionMismatchAndMOnlyWithoutDraftMutation() async throws {
        let original = Data(#"{"type":"FeatureCollection","features":[]}"#.utf8)
        let url = URL(fileURLWithPath: "/tmp/polyline-clipboard-reject.geojson")
        let provider = MemoryPolylineMapEditingProvider(bytes: original, url: url)
        let session = PolylineMapEditingSession(provider: provider)
        let scope = PolylineMapEditingScope(projectSessionID: UUID(), mapID: UUID(), layerID: url.path, canonicalPath: url.path)
        #expect(await session.ensureLoaded(scope: scope))
        let vertices = [
            GeoprocessingClipboardVertex(x: 0, y: 0, z: nil, m: nil),
            GeoprocessingClipboardVertex(x: 1, y: 1, z: nil, m: nil)
        ]
        let mismatched = GeoprocessingPolylineClipboard(lines: [
            GeoprocessingClipboardPolyline(hasZ: false, hasM: false, vertices: vertices)
        ], coordinateProjectionWKT: "EPSG:4326")
        #expect(!(await session.pasteClipboardLines(mismatched, destinationProjectionWKT: nil)))
        #expect(!session.hasUnsavedChanges)
        #expect(provider.bytes == original)

        let mOnly = GeoprocessingPolylineClipboard(lines: [
            GeoprocessingClipboardPolyline(hasZ: false, hasM: true, vertices: [
                GeoprocessingClipboardVertex(x: 0, y: 0, z: nil, m: "2"),
                GeoprocessingClipboardVertex(x: 1, y: 1, z: nil, m: "3")
            ])
        ], coordinateProjectionWKT: nil)
        #expect(!(await session.pasteClipboardLines(mOnly, destinationProjectionWKT: nil)))
        #expect(!session.hasUnsavedChanges)
        #expect(provider.bytes == original)
    }

    @Test @MainActor
    func dirtyScopeCannotBeReplacedUntilExplicitDiscardAndInvalidationRefusesDraft() async throws {
        let source = Data(#"{"type":"FeatureCollection","features":[{"type":"Feature","id":"a","properties":{},"geometry":{"type":"LineString","coordinates":[[0,0],[1,1]]}}]}"#.utf8)
        let url = URL(fileURLWithPath: "/tmp/polyline-guard.geojson")
        let provider = MemoryPolylineMapEditingProvider(bytes: source, url: url)
        let session = PolylineMapEditingSession(provider: provider)
        let scope = PolylineMapEditingScope(projectSessionID: UUID(), mapID: UUID(), layerID: url.path, canonicalPath: url.path)
        let otherScope = PolylineMapEditingScope(projectSessionID: scope.projectSessionID, mapID: UUID(), layerID: "/tmp/other.geojson", canonicalPath: "/tmp/other.geojson")
        #expect(await session.ensureLoaded(scope: scope))
        let line = try #require(session.lines.first)
        #expect(await session.moveVertex(lineID: line.id, vertexIndex: 0, to: MapPoint(x: 4, y: 5)))
        #expect(!(await session.ensureLoaded(scope: otherScope)))
        #expect(!session.invalidate())
        #expect(session.currentScope == scope)
        #expect(session.hasUnsavedChanges)
        #expect(session.discardForProjectReplacement())
        #expect(!session.hasUnsavedChanges)
        #expect(session.currentScope == nil)
    }

    @Test @MainActor
    func sourceShaChangeStopsEditAndKeepsDraftForExplicitRecovery() async throws {
        let source = Data(#"{"type":"FeatureCollection","features":[{"type":"Feature","id":"a","properties":{},"geometry":{"type":"LineString","coordinates":[[0,0],[1,1]]}}]}"#.utf8)
        let external = Data(#"{"type":"FeatureCollection","features":[],"foreign":true}"#.utf8)
        let url = URL(fileURLWithPath: "/tmp/polyline-sha.geojson")
        let provider = MemoryPolylineMapEditingProvider(bytes: source, url: url)
        let session = PolylineMapEditingSession(provider: provider)
        let scope = PolylineMapEditingScope(projectSessionID: UUID(), mapID: UUID(), layerID: url.path, canonicalPath: url.path)
        #expect(await session.ensureLoaded(scope: scope))
        let line = try #require(session.lines.first)
        #expect(await session.moveVertex(lineID: line.id, vertexIndex: 1, to: MapPoint(x: 2, y: 2)))
        provider.externalWrite(external)
        #expect(!(await session.save()))
        #expect(session.isSourceStale)
        #expect(session.hasUnsavedChanges)
        #expect(session.currentScope == scope)
        #expect(await session.discard())
        #expect(!session.hasUnsavedChanges)
        #expect(session.lines.isEmpty)
    }

    @Test @MainActor
    func mutationRechecksSharedEditGateAfterSourceRevisionAwait() async throws {
        let source = Data(#"{"type":"FeatureCollection","features":[{"type":"Feature","id":"a","properties":{},"geometry":{"type":"LineString","coordinates":[[0,0],[1,1]]}}]}"#.utf8)
        let url = URL(fileURLWithPath: "/tmp/polyline-gate.geojson")
        let provider = MemoryPolylineMapEditingProvider(bytes: source, url: url)
        let session = PolylineMapEditingSession(provider: provider)
        let scope = PolylineMapEditingScope(projectSessionID: UUID(), mapID: UUID(), layerID: url.path, canonicalPath: url.path)
        var sharedEditGateOpen = true
        session.canEdit = { sharedEditGateOpen }
        #expect(await session.ensureLoaded(scope: scope))
        let line = try #require(session.lines.first)
        provider.onRevision = { sharedEditGateOpen = false }

        #expect(!(await session.moveVertex(lineID: line.id, vertexIndex: 1, to: MapPoint(x: 4, y: 5))))
        #expect(!session.hasUnsavedChanges)
        #expect(session.lines.first?.points.last == MapPoint(x: 1, y: 1))
        #expect(provider.bytes == source)
    }

    @Test @MainActor
    func overlayUsesSourceStructureAndPreservesLayerAliasForDuplicateCoordinates() async throws {
        let source = Data(#"{"type":"FeatureCollection","features":[{"type":"Feature","id":"first","properties":{"name":"First"},"geometry":{"type":"LineString","coordinates":[[0,0],[1,1]]}},{"type":"Feature","id":"second","properties":{"name":"Second"},"geometry":{"type":"LineString","coordinates":[[0,0],[1,1]]}}]}"#.utf8)
        let canonicalURL = URL(fileURLWithPath: "/tmp/polyline-canonical.geojson")
        let layerAlias = "/tmp/polyline-layer-alias.geojson"
        let provider = MemoryPolylineMapEditingProvider(bytes: source, url: canonicalURL)
        let session = PolylineMapEditingSession(provider: provider)
        let scope = PolylineMapEditingScope(projectSessionID: UUID(), mapID: UUID(),
            layerID: layerAlias, canonicalPath: canonicalURL.path)

        #expect(await session.ensureLoaded(scope: scope))
        let sourceLines = session.lines
        let sourceLayer = try #require(session.currentMapLayer)
        #expect(sourceLayer.id == URL(fileURLWithPath: layerAlias).standardizedFileURL.path)
        #expect(sourceLayer.features.map(\.pathStableIdentities).flatMap { $0 } == sourceLines.map(\.id))

        #expect(await session.moveVertex(lineID: sourceLines[1].id, vertexIndex: 1, to: MapPoint(x: 3, y: 4)))
        let editedLayer = try #require(session.currentMapLayer)
        #expect(editedLayer.features[0].pathStableIdentities == [sourceLines[0].id])
        #expect(editedLayer.features[1].pathStableIdentities == [sourceLines[1].id])
        #expect(editedLayer.features[0].paths[0].last == MapPoint(x: 1, y: 1))
        #expect(editedLayer.features[1].paths[0].last == MapPoint(x: 3, y: 4))
    }

    @Test @MainActor
    func rectanglePathAndLassoSelectionSupportReplaceAndModifierToggle() async throws {
        let source = Data(#"{"type":"FeatureCollection","features":[{"type":"Feature","id":"banks","properties":{},"geometry":{"type":"MultiLineString","coordinates":[[[0,0],[10,0]],[[10,0],[20,0]],[[40,40],[50,50]]]}}]}"#.utf8)
        let url = URL(fileURLWithPath: "/tmp/polyline-selection.geojson")
        let session = PolylineMapEditingSession(provider: MemoryPolylineMapEditingProvider(bytes: source, url: url))
        let scope = PolylineMapEditingScope(projectSessionID: UUID(), mapID: UUID(), layerID: url.path, canonicalPath: url.path)
        #expect(await session.ensureLoaded(scope: scope))
        let lines = session.lines

        session.selectRectangle(from: MapPoint(x: 8, y: -1), to: MapPoint(x: 12, y: 1))
        #expect(session.selectedLineIDs == Set([lines[0].id, lines[1].id]))
        session.selectByPath([MapPoint(x: 5, y: -2), MapPoint(x: 5, y: 2)])
        #expect(session.selectedLineIDs == Set([lines[0].id]))

        let lasso = [MapPoint(x: -1, y: -1), MapPoint(x: 21, y: -1), MapPoint(x: 21, y: 1), MapPoint(x: -1, y: 1)]
        session.setLassoMatchMode(.contained)
        session.selectByLasso(lasso)
        #expect(session.selectedLineIDs == Set([lines[0].id, lines[1].id]))
        session.selectLine(lines[2].id, additive: true)
        #expect(session.selectedLineIDs == Set([lines[0].id, lines[1].id, lines[2].id]))
        session.selectLine(lines[0].id, additive: true)
        #expect(session.selectedLineIDs == Set([lines[1].id, lines[2].id]))
    }

    @Test @MainActor
    func splitActionKeepsStableComponentSelectionAcrossUndoAndRedo() async throws {
        let source = Data(#"{"type":"FeatureCollection","features":[{"type":"Feature","id":"bank","properties":{"name":"Bank"},"geometry":{"type":"MultiLineString","coordinates":[[[0,0,1,10],[10,0,3,30]],[[30,0,5,50],[31,0,6,60]]]}}]}"#.utf8)
        let url = URL(fileURLWithPath: "/tmp/polyline-split-session.geojson")
        let provider = MemoryPolylineMapEditingProvider(bytes: source, url: url)
        let session = PolylineMapEditingSession(provider: provider)
        let scope = PolylineMapEditingScope(projectSessionID: UUID(), mapID: UUID(), layerID: url.path, canonicalPath: url.path)
        #expect(await session.ensureLoaded(scope: scope))
        let original = session.lines
        session.setTool(.splitLine)

        #expect(await session.splitNearestLine(near: MapPoint(x: 5, y: 0), maximumDistance: 0.1))
        #expect(session.lines.count == 3)
        #expect(session.selectedLineIDs.count == 2)
        #expect(session.lines.last?.id == original[1].id)
        #expect(session.hasUnsavedChanges)
        #expect(provider.bytes == source)

        #expect(await session.undo())
        #expect(session.lines.map(\.id) == original.map(\.id))
        #expect(await session.redo())
        #expect(session.lines.count == 3)
        #expect(session.lines.last?.id == original[1].id)
    }

    @Test @MainActor
    func atVertexSplitChoosesClosestEligibleInteriorVertexInsteadOfClosestSegment() async throws {
        let source = Data(#"{"type":"FeatureCollection","features":[{"type":"Feature","id":"routes","properties":{},"geometry":{"type":"MultiLineString","coordinates":[[[0,0],[10,0]],[[4,1],[5,0.1],[6,1]]]}}]}"#.utf8)
        let url = URL(fileURLWithPath: "/tmp/polyline-at-vertex-split.geojson")
        let session = PolylineMapEditingSession(provider: MemoryPolylineMapEditingProvider(bytes: source, url: url))
        let scope = PolylineMapEditingScope(projectSessionID: UUID(), mapID: UUID(), layerID: url.path, canonicalPath: url.path)
        #expect(await session.ensureLoaded(scope: scope))
        let original = session.lines
        session.setTool(.splitLine)
        session.setSplitMode(.atVertex)

        #expect(await session.splitNearestLine(near: MapPoint(x: 5, y: 0), maximumDistance: 0.2))
        #expect(session.lines.count == 3)
        #expect(session.selectedLineIDs.contains(original[1].id))
        #expect(!session.selectedLineIDs.contains(original[0].id))
    }

    @Test @MainActor
    func endpointDragPreviewIsDirtyUntilAppliedAndUndoable() async throws {
        let source = Data(#"{"type":"FeatureCollection","features":[{"type":"Feature","id":"bank","properties":{},"geometry":{"type":"LineString","coordinates":[[0,0,7,70],[10,0,9,90]]}}]}"#.utf8)
        let url = URL(fileURLWithPath: "/tmp/polyline-attach-preview.geojson")
        let provider = MemoryPolylineMapEditingProvider(bytes: source, url: url)
        let session = PolylineMapEditingSession(provider: provider)
        let scope = PolylineMapEditingScope(projectSessionID: UUID(), mapID: UUID(), layerID: url.path, canonicalPath: url.path)
        #expect(await session.ensureLoaded(scope: scope))
        let line = try #require(session.lines.first)
        session.setTool(.attachEndpoint)
        session.beginEndpointAttach(lineID: line.id, anchor: MapPoint(x: 10, y: 0))
        session.updateEndpointAttach(to: MapPoint(x: 13, y: 4))

        #expect(session.hasUnsavedChanges)
        #expect(!session.canCommitDraft)
        #expect(session.endpointAttachDraft?.point == MapPoint(x: 13, y: 4))
        #expect(provider.bytes == source)
        session.setTool(.select)
        #expect(session.endpointAttachDraft != nil)

        #expect(await session.finishEndpointAttach(maximumDistance: 0))
        #expect(session.endpointAttachDraft == nil)
        #expect(session.lines.first?.points.count == 3)
        #expect(await session.undo())
        #expect(session.lines.first?.points.count == 2)
        #expect(await session.redo())
        #expect(session.lines.first?.points.count == 3)
        #expect(provider.bytes == source)
        #expect(await session.save())
        #expect(String(decoding: provider.bytes, as: UTF8.self).contains("[13,4,9,90]"))
    }

    @Test @MainActor
    func endpointDragKeepsSourceSnapToleranceAndRejectsAnOutOfRangeStart() async throws {
        let source = Data(#"{"type":"FeatureCollection","features":[{"type":"Feature","id":"bank","properties":{},"geometry":{"type":"LineString","coordinates":[[0,0],[10,0]]}}]}"#.utf8)
        let url = URL(fileURLWithPath: "/tmp/polyline-attach-tolerance.geojson")
        let provider = MemoryPolylineMapEditingProvider(bytes: source, url: url)
        let session = PolylineMapEditingSession(provider: provider)
        let scope = PolylineMapEditingScope(projectSessionID: UUID(), mapID: UUID(), layerID: url.path, canonicalPath: url.path)
        #expect(await session.ensureLoaded(scope: scope))
        let line = try #require(session.lines.first)
        session.setTool(.attachEndpoint)
        session.beginEndpointAttach(lineID: line.id, anchor: MapPoint(x: 10.5, y: 0), maximumDistance: 0.1)
        session.updateEndpointAttach(to: MapPoint(x: 11, y: 1))

        let applied = await session.finishEndpointAttach()
        #expect(!applied)
        #expect(session.endpointAttachDraft != nil)
        #expect(session.hasUnsavedChanges)
        #expect(session.lines.first?.points.count == 2)
        #expect(provider.bytes == source)
    }
}
