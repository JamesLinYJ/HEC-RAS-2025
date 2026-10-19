import CryptoKit
import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

struct MapSourceVectorLoadingTests {
    @Test
    func captureDeduplicatesOnePhysicalFileAcrossExactMapNodes() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("map-vector-source-capture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let source = folder.appendingPathComponent("shared.geojson")
        let bytes = Data(#"{"type":"FeatureCollection","features":[{"type":"Feature","id":"a","properties":{},"geometry":{"type":"LineString","coordinates":[[0,0],[2,3]]}}]}"#.utf8)
        try bytes.write(to: source)
        let path = SourceFilePaths.canonical(source)
        let revision = sha256(bytes)
        let first = node(id: "line-a", path: path, revision: revision, name: "First line")
        let second = node(id: "line-b", path: path, revision: revision.lowercased(), name: "Second line")

        let captured = MapVectorSourceLoader.capture(nodes: [first, second], mapID: UUID()) { _ in source }

        #expect(captured.issues.isEmpty)
        #expect(captured.files.count == 1)
        #expect(captured.files.first?.canonicalPath == path)
        #expect(captured.files.first?.sourceRevision == revision)
        #expect(captured.files.first?.nodeIDs == ["line-a", "line-b"])
    }

    @Test
    func loadRejectsSourceThatChangedAfterTheCatalogCapturedItsRevision() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("map-vector-source-revision-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let source = folder.appendingPathComponent("line.geojson")
        let capturedBytes = Data(#"{"type":"FeatureCollection","features":[{"type":"Feature","id":"captured","properties":{},"geometry":{"type":"LineString","coordinates":[[0,0],[1,1]]}}]}"#.utf8)
        let laterBytes = Data(#"{"type":"FeatureCollection","features":[{"type":"Feature","id":"changed","properties":{},"geometry":{"type":"LineString","coordinates":[[0,0],[5,5]]}}]}"#.utf8)
        try capturedBytes.write(to: source)
        let request = MapVectorSourceReadRequest(mapID: UUID(), url: source,
            sourceIdentity: SourceFilePaths.canonical(source), sourceRevision: sha256(capturedBytes),
            nodeIDs: ["line"], displayName: "line.geojson")
        try laterBytes.write(to: source)

        let loaded = try MapVectorSourceLoader.load([request])

        #expect(loaded.layers.isEmpty)
        #expect(loaded.issues.count == 1)
        #expect(loaded.issues.first?.contains("changed after the map tree captured it") == true)
    }

    private func node(id: String, path: String, revision: String, name: String) -> LayerTreeNode {
        LayerTreeNode(id: id, sourceClass: "PolylineMapLayerVisualContext", name: name,
            assetID: path, diagnosticStatus: "loaded", diagnosticSourceIdentity: path,
            diagnosticSourceRevision: revision,
            sourceLocator: .init(rootName: "Map Layers", nodeType: "MapLayer", nodeName: name,
                mapType: "PolylinesVector", filename: URL(fileURLWithPath: path).lastPathComponent))
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02X", $0) }.joined()
    }
}
