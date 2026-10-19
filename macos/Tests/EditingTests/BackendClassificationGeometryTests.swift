import Foundation
import Testing
@testable import HECRAS2025
@testable import RASWorkspaceCore

struct BackendClassificationGeometryTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HECRAS_CLASSIFICATION_GEOMETRY_ACCEPTANCE_DIRECTORY"] != nil)) @MainActor
    func copiedClassificationFeaturesPasteAsOneUndoableSourceDraftAndPersist() async throws {
        let (folder, provider, asset, editor) = try await setup()
        defer { try? FileManager.default.removeItem(at: folder) }
        let bytes = try Data(contentsOf: asset.url), sourceField = ClassificationEditorContract.sourceField
        let collection = try #require(editor.sourceCollections[sourceField])
        let input = try #require(collection.items.first { collection.itemDetails[$0.id]?.polygons != nil })
        let old = try #require(collection.itemDetails[input.id]?.polygons?.items)
        let copied = ClassificationFeatureClipboard(features: old.prefix(2).map {
            .init(vertices: $0.vertices, hasZ: $0.hasZ, hasM: $0.hasM, classification: $0.classification)
        })
        let encoded = try JSONEncoder().encode(copied)
        let decoded = try JSONDecoder().decode(ClassificationFeatureClipboard.self, from: encoded)
        try decoded.validate()
        #expect(decoded.features == copied.features)
        #expect(await editor.perform(.selectSource(field: sourceField, id: input.id)))
        #expect(await editor.perform(.editClassificationGeometry(.init(operation: "paste", inputId: input.id, features: decoded.features))))
        let pasted = try #require(editor.sourceCollections[sourceField]?.itemDetails[input.id]?.polygons)
        #expect(pasted.items.count == old.count + copied.features.count)
        let pastedIDs = pasted.items.map(\.id)
        #expect(pasted.selectedIDs == Set(pasted.items.suffix(copied.features.count).map(\.id)))
        #expect(Array(pasted.items.suffix(copied.features.count).map(\.vertices)) == copied.features.map(\.vertices))
        #expect(editor.sourceCollections[sourceField]?.items.map(\.id) == collection.items.map(\.id))
        #expect(try Data(contentsOf: asset.url) == bytes)
        #expect(await editor.perform(.editClassificationGeometry(.init(operation: "undo"))))
        #expect(editor.sourceCollections[sourceField]?.itemDetails[input.id]?.polygons?.items.map(\.id) == old.map(\.id))
        #expect(await editor.perform(.editClassificationGeometry(.init(operation: "redo"))))
        #expect(editor.sourceCollections[sourceField]?.itemDetails[input.id]?.polygons?.items.map(\.id) == pastedIDs)
        #expect(await editor.saveLoadedModel())
        let reopened = try await provider.load(asset, kind: .surface)
        let saved = try #require(reopened.sourceCollections[sourceField]?.itemDetails.values.first { $0.polygons != nil }?.polygons)
        #expect(saved.items.count == old.count + copied.features.count)
        #expect(Array(saved.items.suffix(copied.features.count).map(\.classification)) == copied.features.map(\.classification))
        #expect(Array(saved.items.suffix(copied.features.count).map(\.vertices)) == copied.features.map(\.vertices))
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HECRAS_CLASSIFICATION_GEOMETRY_ACCEPTANCE_DIRECTORY"] != nil)) @MainActor
    func sourceGeometrySelectionBatchUndoMapAndXYZMPersistence() async throws {
        let (folder, provider, asset, editor) = try await setup(); defer { try? FileManager.default.removeItem(at: folder) }
        let original = try Data(contentsOf: asset.url)
        let source = ClassificationEditorContract.sourceField
        let input = try #require(editor.sourceCollections[source]?.items.first { editor.sourceCollections[source]?.itemDetails[$0.id]?.polygons != nil })
        let detail = try #require(editor.sourceCollections[source]?.itemDetails[input.id]), polygons = try #require(detail.polygons)
        #expect(polygons.items.count == 3 && polygons.items[0].hasM && !polygons.items[0].hasZ)
        let first = polygons.items[0], last = polygons.items[2]
        #expect(await editor.perform(.selectSource(field: source, id: input.id)))
        #expect(await editor.perform(.selectPolygonClassifications(field: source, scope: detail.scope, ids: [first.id])))
        #expect(!editor.modified && editor.sourceCollections[source]?.itemDetails[input.id]?.polygons?.selectedIDs == [first.id])
        editor.set("ClassificationCatalogSummary/Context_Description", "Swift 地图草稿")
        editor.set(first.fieldID, "Swift 保留分类")
        #expect(await editor.perform(.editClassificationGeometry(.init(operation: "delete", inputId: input.id, polygonIds: Array(polygons.items.prefix(2).map(\.id))))))
        #expect(editor.sourceCollections[source]?.itemDetails[input.id]?.polygons?.items.map(\.id) == [last.id])
        #expect(await editor.perform(.editClassificationGeometry(.init(operation: "undo"))))
        #expect(editor.fields[first.fieldID] == "Swift 保留分类")
        #expect(await editor.perform(.editClassificationGeometry(.init(operation: "redo"))))
        #expect(await editor.perform(.editClassificationGeometry(.init(operation: "undo"))))
        let createdVertices: [ClassificationVertex] = [.init(x: 1, y: 12), .init(x: 4, y: 12), .init(x: 1, y: 16)]
        #expect(await editor.perform(.editClassificationGeometry(.init(operation: "create", inputId: input.id, vertices: createdVertices, classification: "Swift 新绘制面"))))
        let map = try await editor.classificationMap()
        #expect(map.raster?.rgba.count == 256 * 256 * 4 && map.legend.contains { $0.name == "Swift 新绘制面" })
        #expect(map.selectedInputId == input.id)
        let overlay = try #require(map.selectedRaster)
        let full = try #require(map.raster)
        #expect(overlay.width == full.width && overlay.height == full.height)
        #expect(overlay.minX == full.minX && overlay.minY == full.minY
                && overlay.maxX == full.maxX && overlay.maxY == full.maxY)
        #expect(stride(from: 3, to: overlay.rgba.count, by: 4).contains { overlay.rgba[$0] > 0 })
        #expect(stride(from: 3, to: overlay.rgba.count, by: 4).contains { overlay.rgba[$0] == 0 && full.rgba[$0] > 0 })
        let presentation = try map.presentation()
        #expect(presentation.rasters.count == 2 && presentation.rasters.last?.id == input.id)
        let selectedIdentity = editor.classificationMapIdentity
        #expect(await editor.perform(.selectSource(field: source, id: nil)))
        #expect(editor.classificationMapIdentity != selectedIdentity)
        let clearedMap = try await editor.classificationMap()
        #expect(clearedMap.selectedInputId == nil && clearedMap.selectedRaster == nil)
        #expect(try clearedMap.presentation().rasters.count == 1)
        #expect(clearedMap.raster?.rgba != full.rgba)
        #expect(await editor.perform(.selectSource(field: source, id: input.id)))
        #expect(editor.fields["ClassificationCatalogSummary/Context_Description"] == "Swift 地图草稿")
        #expect(try Data(contentsOf: asset.url) == original)
        #expect(await editor.saveLoadedModel())
        let savedSelection = try #require(editor.sourceCollections[source]?.itemDetails.values.first { $0.polygons != nil }?.polygons)
        #expect(savedSelection.selectedIDs == [try #require(savedSelection.items.last).id])
        let read = try await provider.load(asset, kind: .surface)
        let saved = try #require(read.sourceCollections[source]?.itemDetails.values.first { $0.polygons != nil }?.polygons)
        #expect(saved.items.count == 4 && saved.items[0].classification == "Swift 保留分类")
        #expect(saved.items[0].hasM && !saved.items[0].hasZ && saved.items[0].vertices[2].m == "NaN")
        #expect(saved.items.last?.vertices == createdVertices)
        #expect(read.sourceCollections[source]?.classificationTools?.canUndo == false)
        #expect(read.fields["ClassificationCatalogSummary/Context_Description"] == "Swift 地图草稿")
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HECRAS_CLASSIFICATION_GEOMETRY_ACCEPTANCE_DIRECTORY"] != nil)) @MainActor
    func invalidGeometryRetainsDraftAndDiscardRestoresOriginalCoordinates() async throws {
        let (folder, _, asset, editor) = try await setup(); defer { try? FileManager.default.removeItem(at: folder) }
        let original = try Data(contentsOf: asset.url), source = ClassificationEditorContract.sourceField
        let input = try #require(editor.sourceCollections[source]?.items.first { editor.sourceCollections[source]?.itemDetails[$0.id]?.polygons != nil })
        let polygon = try #require(editor.sourceCollections[source]?.itemDetails[input.id]?.polygons?.items[0])
        #expect(await editor.perform(.selectPolygonClassifications(field: source, scope: try #require(editor.sourceCollections[source]?.itemDetails[input.id]?.scope), ids: [polygon.id])))
        editor.set("ClassificationCatalogSummary/Context_Description", "失败保留")
        let invalid: [ClassificationVertex] = [.init(x: 0, y: 0), .init(x: 1, y: 1), .init(x: 2, y: 2)]
        #expect(await editor.perform(.editClassificationGeometry(.init(operation: "replace", inputId: input.id, polygonIds: [polygon.id], vertices: invalid))) == false)
        #expect(editor.modified && editor.error != nil && editor.fields["ClassificationCatalogSummary/Context_Description"] == "失败保留")
        var vertices = polygon.vertices; vertices[0].x -= 1
        #expect(await editor.perform(.editClassificationGeometry(.init(operation: "replace", inputId: input.id, polygonIds: [polygon.id], vertices: vertices, hasZ: polygon.hasZ, hasM: polygon.hasM))))
        #expect(editor.sourceCollections[source]?.itemDetails[input.id]?.polygons?.items[0].vertices == vertices)
        #expect(editor.sourceCollections[source]?.itemDetails[input.id]?.polygons?.selectedIDs == [polygon.id])
        editor.discardEdits()
        #expect(!editor.modified && editor.error == nil)
        #expect(editor.sourceCollections[source]?.itemDetails[input.id]?.polygons?.items[0].vertices == polygon.vertices)
        #expect(try Data(contentsOf: asset.url) == original)
    }
    @MainActor private func setup() async throws -> (URL, BackendModelProvider, ProjectAsset, ModelEditorSession) {
        let executable = try #require(ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"])
        let fixture = try #require(ProcessInfo.processInfo.environment["HECRAS_CLASSIFICATION_GEOMETRY_ACCEPTANCE_DIRECTORY"])
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("classification-geometry-" + UUID().uuidString)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: fixture), to: folder)
        let document = try ProjectDocument(contentsOf: folder.appendingPathComponent("分类地图.ras"))
        let provider = BackendModelProvider(client: .init(executableURL: URL(fileURLWithPath: executable))); provider.setProject(document)
        let asset = try #require(document.assets.first { $0.name == "地图分类" }), editor = ModelEditorSession(provider: provider)
        await editor.load(asset, kind: .surface)
        return (folder, provider, asset, editor)
    }
}
