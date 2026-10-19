import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

struct BackendSpatialGridTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HECRAS_SPATIAL_GRID_ACCEPTANCE_DIRECTORY"] != nil)) @MainActor
    func actualGridFramesPreserveStationDraftAndItsDiscardBaseline() async throws {
        let (folder, document, provider) = try setup(); defer { try? FileManager.default.removeItem(at: folder) }
        let asset = try #require(document.assets.first { $0.section == .boundaryConditions }), editor = ModelEditorSession(provider: provider)
        await editor.load(asset, kind: .boundaryCondition)
        #expect(editor.loaded && editor.error == nil)
        let original = try Data(contentsOf: asset.url)
        #expect(await editor.perform(.editSpatial(layerID: "precipitation", operation: "addStation", itemID: nil)))
        let station = try #require(editor.spatialPresentations["precipitation"]?.pointData?.stations.first)
        editor.set(station.scope + "/Name", "切帧保留的站点草稿")
        let field = "BoundaryConditionsSummary/BoundaryCondition_Description", baseline = editor.fields[field]
        editor.set(field, "切帧不能保存或吞掉草稿")
        let step = try #require(editor.spatialPresentations["wind"]?.timeSteps.last)
        #expect(await editor.perform(.selectSpatialTime(layerID: "wind", stepID: step.id)))
        #expect(editor.spatialPresentations["wind"]?.preview.rasters.count == 1)
        #expect(editor.fields[station.scope + "/Name"] == "切帧保留的站点草稿" && editor.fields[field] == "切帧不能保存或吞掉草稿")
        #expect(editor.modified && editor.spatialPresentations["wind"]?.pointData?.stations.first?.id == station.id)
        #expect(try Data(contentsOf: asset.url) == original)
        editor.discardEdits()
        #expect(!editor.modified && editor.fields[field] == baseline)
        #expect(editor.spatialPresentations["wind"]?.pointData?.stations.isEmpty == true)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HECRAS_SPATIAL_GRID_ACCEPTANCE_DIRECTORY"] != nil)) @MainActor
    func realRasterInspectionAndImportSaveCapturedDraftsAndRejectChangedFiles() async throws {
        let (folder, document, provider) = try setup(); defer { try? FileManager.default.removeItem(at: folder) }
        let asset = try #require(document.assets.first { $0.section == .boundaryConditions }), editor = ModelEditorSession(provider: provider)
        await editor.load(asset, kind: .boundaryCondition)
        let original = try Data(contentsOf: asset.url), xml = try Data(contentsOf: try #require(document.url))
        let input = folder.appendingPathComponent("气压.vrt")
        let inspect = try await editor.inspectGrid(layerID: "airPressure", files: [input], subdataset: nil, bands: [], previewID: nil)
        #expect(inspect.bands.count == 2 && inspect.preview?.minimum == 100000)
        #expect(try Data(contentsOf: asset.url) == original && !editor.modified)
        editor.set("BoundaryConditionsSummary/BoundaryCondition_Description", "Swift 格网与模型草稿一起保存")
        #expect(await editor.perform(.editSpatial(layerID: "precipitation", operation: "addStation", itemID: nil)))
        let station = try #require(editor.spatialPresentations["precipitation"]?.pointData?.stations.first)
        editor.set(station.scope + "/Name", "随格网保存的共享站点")
        let selection = SpatialGridSelection(layerId: "airPressure", bands: inspect.bands, units: "Pa", dataType: "inst-val")
        #expect(await editor.importGrid(selection))
        #expect(!editor.modified && editor.error == nil)
        let fresh = try await provider.load(asset, kind: .boundaryCondition)
        #expect(fresh.fields["BoundaryConditionsSummary/BoundaryCondition_Description"] == "Swift 格网与模型草稿一起保存")
        #expect(fresh.spatialPresentations["wind"]?.pointData?.stations.first?.name == "随格网保存的共享站点")
        let step = try #require(editor.spatialPresentations["airPressure"]?.timeSteps.first)
        #expect(await editor.perform(.selectSpatialTime(layerID: "airPressure", stepID: step.id)))
        #expect(editor.spatialPresentations["airPressure"]?.gridData?.preview?.minimum == 1000)
        let saved = try Data(contentsOf: asset.url)
        let handle = try FileHandle(forWritingTo: folder.appendingPathComponent("气压.tif")); try handle.seekToEnd(); try handle.write(contentsOf: Data("changed raster".utf8)); try handle.close()
        editor.set("BoundaryConditionsSummary/BoundaryCondition_Description", "失败时保留的草稿")
        #expect(await editor.importGrid(selection) == false)
        #expect(editor.modified && editor.error != nil && editor.fields["BoundaryConditionsSummary/BoundaryCondition_Description"] == "失败时保留的草稿")
        #expect(try Data(contentsOf: asset.url) == saved && Data(contentsOf: try #require(document.url)) == xml)
    }

    @Test func malformedPixelBuffersCannotReachNativeRasterRendering() throws {
        let input = Data(#"{"width":2,"height":2,"rgba":"AAAA","minX":0,"minY":0,"maxX":1,"maxY":1,"minimum":0,"maximum":1}"#.utf8)
        let preview = try JSONDecoder().decode(SpatialGridPreview.self, from: input)
        #expect(throws: Error.self) { try preview.validate() }
    }
    @MainActor private func setup() throws -> (URL, ProjectDocument, BackendModelProvider) {
        let executable = try #require(ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"])
        let fixture = try #require(ProcessInfo.processInfo.environment["HECRAS_SPATIAL_GRID_ACCEPTANCE_DIRECTORY"])
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("spatial-grid-" + UUID().uuidString)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: fixture), to: folder)
        let document = try ProjectDocument(contentsOf: folder.appendingPathComponent("格网集成.ras"))
        let provider = BackendModelProvider(client: .init(executableURL: URL(fileURLWithPath: executable))); provider.setProject(document)
        return (folder, document, provider)
    }
}
