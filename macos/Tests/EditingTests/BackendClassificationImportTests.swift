import Foundation
import Testing
@testable import HECRAS2025
@testable import RASWorkspaceCore

struct BackendClassificationImportTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HECRAS_CLASSIFICATION_IMPORT_ACCEPTANCE_DIRECTORY"] != nil)) @MainActor
    func actualFilesPreviewImportAndConflictPreserveDraftsAndOriginalInputs() async throws {
        let executable = try #require(ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"])
        let fixture = try #require(ProcessInfo.processInfo.environment["HECRAS_CLASSIFICATION_IMPORT_ACCEPTANCE_DIRECTORY"])
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("classification-import-" + UUID().uuidString)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: fixture), to: folder)
        defer { try? FileManager.default.removeItem(at: folder) }
        let project = folder.appendingPathComponent("分类导入.ras"), document = try ProjectDocument(contentsOf: project)
        let provider = BackendModelProvider(client: .init(executableURL: URL(fileURLWithPath: executable))); provider.setProject(document)
        let asset = try #require(document.assets.first { $0.name == "分类导入层" })
        let editor = ModelEditorSession(provider: provider); await editor.load(asset, kind: .surface)
        let raster = folder.appendingPathComponent("来源栅格.tif"), shape = folder.appendingPathComponent("分类面.shp")
        let originalHDF = try Data(contentsOf: asset.url), originalXML = try Data(contentsOf: project), originalRaster = try Data(contentsOf: raster)
        editor.set("ClassificationCatalogSummary/Context_Description", "Swift 分类导入草稿")
        let inspection = try await editor.inspectClassification(files: [raster, shape], selections: [])
        let rasterItem = try #require(inspection.items.first { $0.selection.kind == "Raster" }), shapeItem = try #require(inspection.items.first { $0.selection.kind == "Polygon" })
        #expect(try rasterItem.preview().rasters.count == 1)
        #expect(try shapeItem.preview().vectors.first?.layer.features.count == 2)
        #expect(shapeItem.columns == ["Class"] && shapeItem.featureCount == 2)
        #expect(editor.modified && editor.fields["ClassificationCatalogSummary/Context_Description"] == "Swift 分类导入草稿")
        #expect(try Data(contentsOf: asset.url) == originalHDF)
        var rasterSelection = rasterItem.selection; rasterSelection.name = "Swift 中文栅格"
        let dbf = shape.deletingPathExtension().appendingPathExtension("dbf"), originalDBF = try Data(contentsOf: dbf)
        try (originalDBF + Data("changed".utf8)).write(to: dbf)
        #expect(await editor.importClassification([rasterSelection, shapeItem.selection]) == false)
        #expect(editor.modified && editor.error != nil && editor.fields["ClassificationCatalogSummary/Context_Description"] == "Swift 分类导入草稿")
        #expect(try Data(contentsOf: asset.url) == originalHDF)
        try originalDBF.write(to: dbf)
        #expect(await editor.importClassification([rasterSelection, shapeItem.selection]))
        #expect(!editor.modified && editor.error == nil)
        let read = try await provider.load(asset, kind: .surface), inputs = try #require(read.sourceCollections[ClassificationEditorContract.sourceField])
        #expect(inputs.canImport && inputs.multipleImports)
        #expect(inputs.items.contains { $0.title == "Swift 中文栅格" })
        #expect(read.fields["ClassificationCatalogSummary/Context_Description"] == "Swift 分类导入草稿")
        let polygon = try #require(inputs.itemDetails.values.first { $0.polygons != nil }?.polygons)
        #expect(polygon.items.count == 5 && polygon.items.contains { $0.classification == "中文草地" } && polygon.items.contains { $0.classification == "中文农田" })
        let imported = try #require(inputs.items.first { $0.title == "Swift 中文栅格" })
        let detail = try #require(inputs.itemDetails[imported.id])
        let mapping = try #require(read.rows[detail.scope + "/RasterClassificationInputProperties/RasterClassificationInput_Classification"])
        #expect(mapping.contains { $0.values["Key"] == "11" && $0.values["Value"] == "Open Water" })
        #expect(mapping.contains { $0.values["Key"] == "-9999" && $0.values["Value"] == "NoData" })
        #expect(try Data(contentsOf: project) == originalXML)
        #expect(try Data(contentsOf: raster) == originalRaster)
        #expect(try Data(contentsOf: dbf) == originalDBF)
    }
}
