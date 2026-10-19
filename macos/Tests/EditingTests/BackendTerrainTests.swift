import Foundation
import Testing
@testable import HECRAS2025
@testable import RASWorkspaceCore

struct BackendTerrainTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HECRAS_TERRAIN_ACCEPTANCE_DIRECTORY"] != nil)) @MainActor
    func actualTerrainDraftsNavigateReorderPreviewSaveAndRebaseSelection() async throws {
        let (folder, provider, asset, editor) = try await setup(); defer { try? FileManager.default.removeItem(at: folder) }
        let source = TerrainEditorContract.sourceField, original = try Data(contentsOf: asset.url)
        let collection = try #require(editor.sourceCollections[source])
        #expect(collection.terrainConnected && collection.items.count == 3 && collection.sourcePriorityReversed)
        let functional = try #require(collection.items.first { collection.itemDetails[$0.id]?.terrainInfo?.type == "Functional" })
        let detail = try #require(collection.itemDetails[functional.id]); let prefix = detail.scope + "/FunctionalTerrainInputProperties/Context_"
        #expect(await editor.perform(.selectSource(field: source, id: functional.id)))
        #expect(!editor.modified)
        editor.set("TerrainCatalogSummary/Context_Description", "Swift 中文地形说明")
        editor.set(detail.scope + "/Name", "Swift 函数地形")
        editor.set(prefix + "Expression", "3*x+y")
        #expect(editor.useMapExtent(.init(lowerLeft: .init(x: 1, y: 2), upperRight: .init(x: 11, y: 12)), terrainInputScope: detail.scope))
        let map = try await editor.terrainMap(inputID: functional.id)
        let full = try #require(map.raster), selectedRaster = try #require(map.selectedRaster)
        #expect(full.minX == 0 && full.maxX == 20)
        #expect(selectedRaster.minX == 1 && selectedRaster.maxX == 11 && selectedRaster.minY == 2 && selectedRaster.maxY == 12)
        #expect(selectedRaster.minX >= full.minX && selectedRaster.maxX <= full.maxX
            && selectedRaster.minY >= full.minY && selectedRaster.maxY <= full.maxY)
        #expect((selectedRaster.maximum ?? 0) > 44)
        #expect(stride(from: 3, to: selectedRaster.rgba.count, by: 4).contains { selectedRaster.rgba[$0] > 0 })
        #expect(await editor.perform(.reorderSource(field: source, from: 0, to: 2)))
        #expect(editor.fields[source] == functional.id && editor.fields[prefix + "Expression"] == "3*x+y")
        #expect(editor.fields["TerrainCatalogSummary/Context_Description"] == "Swift 中文地形说明")
        #expect(try Data(contentsOf: asset.url) == original)
        #expect(await editor.saveLoadedModel())
        let saved = try #require(editor.sourceCollections[source]), selected = try #require(editor.fields[source])
        #expect(saved.items.first?.id == selected && saved.items.first?.title == "Swift 函数地形")
        let independent = try await provider.load(asset, kind: .terrain)
        let savedDetail = try #require(independent.sourceCollections[source]?.itemDetails[selected])
        #expect(independent.fields[savedDetail.scope + "/FunctionalTerrainInputProperties/Context_Expression"] == "3*x+y")
        #expect(independent.fields["TerrainCatalogSummary/Context_Description"] == "Swift 中文地形说明")
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HECRAS_TERRAIN_ACCEPTANCE_DIRECTORY"] != nil)) @MainActor
    func invalidTerrainKeepsDraftAndRemovalDiscardRestoresAllInputs() async throws {
        let (folder, _, asset, editor) = try await setup(); defer { try? FileManager.default.removeItem(at: folder) }
        let source = TerrainEditorContract.sourceField, original = try Data(contentsOf: asset.url)
        let collection = try #require(editor.sourceCollections[source])
        let constant = try #require(collection.items.first { collection.itemDetails[$0.id]?.terrainInfo?.type == "Constant" })
        let detail = try #require(collection.itemDetails[constant.id]); let value = detail.scope + "/ConstantTerrainInput/Context_Value"
        editor.set(value, "NaN"); editor.set("TerrainCatalogSummary/Context_Description", "错误保留")
        #expect(await editor.saveLoadedModel() == false)
        #expect(editor.modified && editor.error != nil && editor.fields[value] == "NaN")
        #expect(try Data(contentsOf: asset.url) == original)
        editor.set(value, "15.75")
        let raster = try #require(collection.items.first { collection.itemDetails[$0.id]?.terrainInfo?.type == "Raster" })
        #expect(await editor.perform(.removeSource(field: source, id: raster.id)))
        #expect(editor.sourceCollections[source]?.items.count == 2 && editor.fields[value] == "15.75")
        #expect(await editor.perform(.selectSource(field: source, id: constant.id)))
        editor.discardEdits()
        #expect(!editor.modified && editor.error == nil && editor.sourceCollections[source]?.items.count == 3)
        #expect(editor.fields[value] == "12.5" && editor.fields[source] == constant.id)
        #expect(try Data(contentsOf: asset.url) == original)
    }
    @MainActor private func setup() async throws -> (URL, BackendModelProvider, ProjectAsset, ModelEditorSession) {
        let executable = try #require(ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"])
        let fixture = try #require(ProcessInfo.processInfo.environment["HECRAS_TERRAIN_ACCEPTANCE_DIRECTORY"])
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("terrain-editor-" + UUID().uuidString)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: fixture), to: folder)
        let document = try ProjectDocument(contentsOf: folder.appendingPathComponent("地形输入.ras"))
        let provider = BackendModelProvider(client: .init(executableURL: URL(fileURLWithPath: executable))); provider.setProject(document)
        let asset = try #require(document.assets.first { $0.name == "地形编辑" }), editor = ModelEditorSession(provider: provider)
        await editor.load(asset, kind: .terrain)
        return (folder, provider, asset, editor)
    }
}
