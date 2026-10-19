import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

struct BackendClassificationTests {
    private let source = ClassificationEditorContract.sourceField
    private let description = "ClassificationCatalogSummary/Context_Description"
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HECRAS_CLASSIFICATION_ACCEPTANCE_DIRECTORY"] != nil)) @MainActor
    func selectionReorderAndRemovalRetainIndependentDraftAndDiscardBaseline() async throws {
        let (folder, document, provider, asset) = try setup(); defer { try? FileManager.default.removeItem(at: folder) }
        let editor = ModelEditorSession(provider: provider); await editor.load(asset, kind: .surface)
        #expect(editor.error == nil)
        let collection = try #require(editor.sourceCollections[source]), raster = try #require(collection.items.first { $0.title == "重命名分类输入" })
        let detail = try #require(collection.itemDetails[raster.id]), table = detail.scope + "/RasterClassificationInputProperties/RasterClassificationInput_Classification"
        let row = try #require(editor.rows[table]?.first { $0.values["Key"] == "7" })
        let original = try Data(contentsOf: asset.url), xml = try Data(contentsOf: try #require(document.url)), originalDescription = editor.fields[description]
        #expect(await editor.perform(.selectSource(field: source, id: raster.id)))
        #expect(!editor.modified)
        editor.setCell(table: table, rowID: row.id, column: "Value", value: "切换后保留的中文映射")
        editor.setCell(table: table, rowID: row.id, column: "Key", value: "999")
        #expect(editor.rows[table]?.first { $0.id == row.id }?.values["Key"] == "7")
        editor.set(description, "排序与删除草稿")
        let polygons = try #require(collection.itemDetails.first { $0.value.polygons != nil })
        #expect(await editor.perform(.selectSource(field: source, id: polygons.key)))
        #expect(editor.rows[table]?.first { $0.id == row.id }?.values["Value"] == "切换后保留的中文映射")
        let move = try #require(collection.sourceMove(fromDisplay: 0, toDisplay: 1))
        #expect(move.from == 2 && move.to == 1)
        #expect(await editor.perform(.reorderSource(field: source, from: move.from, to: move.to)))
        #expect(editor.fields[description] == "排序与删除草稿")
        #expect(await editor.perform(.removeSource(field: source, id: raster.id)))
        #expect(editor.sourceCollections[source]?.items.count == 2 && editor.modified)
        #expect(try Data(contentsOf: asset.url) == original)
        editor.discardEdits()
        #expect(!editor.modified && editor.sourceCollections[source]?.items.count == 3 && editor.fields[description] == originalDescription)
        #expect(editor.rows[table]?.first { $0.id == row.id }?.values["Value"] == "新中文草地")
        #expect(try Data(contentsOf: asset.url) == original && Data(contentsOf: try #require(document.url)) == xml)
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HECRAS_CLASSIFICATION_ACCEPTANCE_DIRECTORY"] != nil)) @MainActor
    func editedSourceInputsSaveMappingNamesPolygonClassesAndSelection() async throws {
        let (folder, document, provider, asset) = try setup(); defer { try? FileManager.default.removeItem(at: folder) }
        let editor = ModelEditorSession(provider: provider); await editor.load(asset, kind: .surface)
        let collection = try #require(editor.sourceCollections[source]), raster = try #require(collection.items.first { $0.title == "重命名分类输入" }), detail = try #require(collection.itemDetails[raster.id])
        #expect(await editor.perform(.selectSource(field: source, id: raster.id)))
        editor.set(try #require(detail.nameFieldID), "本机重命名栅格输入")
        let table = detail.scope + "/RasterClassificationInputProperties/RasterClassificationInput_Classification", row = try #require(editor.rows[table]?.first { $0.values["Key"] == "8" })
        editor.setCell(table: table, rowID: row.id, column: "Value", value: "本机中文农田")
        let polygon = try #require(collection.itemDetails.values.compactMap(\.polygons).first?.items.first)
        editor.set(polygon.fieldID, "本机面分类")
        let constant = try #require(collection.itemDetails.values.compactMap(\.classificationInfo).first { $0.valueFieldID != nil })
        editor.set(try #require(constant.valueFieldID), "本机常数分类")
        #expect(await editor.saveLoadedModel())
        let read = try await provider.load(asset, kind: .surface)
        let readRaster = try #require(read.sourceCollections[source]?.items.first { $0.title == "本机重命名栅格输入" }), readDetail = try #require(read.sourceCollections[source]?.itemDetails[readRaster.id])
        let readTable = readDetail.scope + "/RasterClassificationInputProperties/RasterClassificationInput_Classification"
        #expect(read.rows[readTable]?.first { $0.values["Key"] == "8" }?.values["Value"] == "本机中文农田")
        #expect(read.sourceCollections[source]?.itemDetails.values.compactMap(\.polygons).first?.items.first?.classification == "本机面分类")
        #expect(editor.fields[source] == readRaster.id && !editor.modified)
        #expect(document.assets.contains { $0.id == asset.id })
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HECRAS_CLASSIFICATION_ACCEPTANCE_DIRECTORY"] != nil)) @MainActor
    func inputDeletionPersistsAndRasterConflictRetainsCurrentDraft() async throws {
        let (folder, _, provider, asset) = try setup(); defer { try? FileManager.default.removeItem(at: folder) }
        let editor = ModelEditorSession(provider: provider); await editor.load(asset, kind: .surface)
        let collection = try #require(editor.sourceCollections[source]), raster = try #require(collection.items.first { $0.title == "重命名分类输入" })
        let polygons = try #require(collection.itemDetails.first { $0.value.polygons != nil })
        #expect(await editor.perform(.removeSource(field: source, id: polygons.key)) == false)
        let original = try Data(contentsOf: asset.url), file = folder.appendingPathComponent("分类栅格.tif"), originalRaster = try Data(contentsOf: file)
        let handle = try FileHandle(forWritingTo: file); try handle.seekToEnd(); try handle.write(contentsOf: Data("changed raster".utf8)); try handle.close()
        editor.set(description, "冲突时保留")
        #expect(await editor.saveLoadedModel() == false)
        #expect(editor.modified && editor.error != nil && editor.fields[description] == "冲突时保留")
        #expect(try Data(contentsOf: asset.url) == original)
        try originalRaster.write(to: file)
        #expect(await editor.perform(.removeSource(field: source, id: raster.id)))
        #expect(await editor.saveLoadedModel())
        let read = try await provider.load(asset, kind: .surface)
        #expect(read.sourceCollections[source]?.items.count == 2 && read.sourceCollections[source]?.items.contains { $0.title == raster.title } == false)
        #expect(try Data(contentsOf: file) == originalRaster)
    }
    @MainActor private func setup() throws -> (URL, ProjectDocument, BackendModelProvider, ProjectAsset) {
        let executable = try #require(ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"]), fixture = try #require(ProcessInfo.processInfo.environment["HECRAS_CLASSIFICATION_ACCEPTANCE_DIRECTORY"])
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("classification-" + UUID().uuidString)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: fixture), to: folder)
        let document = try ProjectDocument(contentsOf: folder.appendingPathComponent("分类集成.ras"))
        let provider = BackendModelProvider(client: .init(executableURL: URL(fileURLWithPath: executable))); provider.setProject(document)
        let asset = try #require(document.assets.first { $0.section == .surfaceLayers && $0.name == "土地分类" })
        return (folder, document, provider, asset)
    }
}
