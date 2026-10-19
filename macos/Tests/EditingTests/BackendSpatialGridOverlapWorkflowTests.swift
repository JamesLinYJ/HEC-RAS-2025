import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

struct BackendSpatialGridOverlapWorkflowTests {
    @Test @MainActor
    func selectedOverlappingSourceBandPreviewsAndImportsWithTheCapturedBoundaryDraft() async throws {
        let environment = ProcessInfo.processInfo.environment
        let fixturePath = try #require(environment["HECRAS_SPATIAL_GRID_ACCEPTANCE_DIRECTORY"])
        let executable = try #require(environment["HECRAS_BACKEND_TEST_EXECUTABLE"])
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("spatial-grid-overlap-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: fixturePath), to: folder)
        defer { try? FileManager.default.removeItem(at: folder) }

        let document = try ProjectDocument(contentsOf: folder.appendingPathComponent("格网集成.ras"))
        let asset = try #require(document.assets.first { $0.section == .boundaryConditions })
        let provider = BackendModelProvider(client: BackendProcessClient(executableURL: URL(fileURLWithPath: executable)))
        provider.setProject(document)
        let editor = ModelEditorSession(provider: provider)
        await editor.load(asset, kind: .boundaryCondition)
        #expect(editor.loaded && editor.error == nil)

        let original = try Data(contentsOf: asset.url)
        let firstSource = folder.appendingPathComponent("气压.vrt")
        let overlappingSource = folder.appendingPathComponent("气压-重叠.vrt")
        let originalVRT = try String(contentsOf: firstSource, encoding: .utf8)
        #expect(originalVRT.components(separatedBy: "<SourceBand>").count - 1 == 2)
        let overlappingVRT = originalVRT
            .replacingOccurrences(of: "<SourceBand>1</SourceBand>", with: "<SourceBand>swap</SourceBand>")
            .replacingOccurrences(of: "<SourceBand>2</SourceBand>", with: "<SourceBand>1</SourceBand>")
            .replacingOccurrences(of: "<SourceBand>swap</SourceBand>", with: "<SourceBand>2</SourceBand>")
        try overlappingVRT.write(to: overlappingSource, atomically: true, encoding: .utf8)
        let inspection = try await editor.inspectGrid(layerID: "airPressure", files: [firstSource, overlappingSource],
            subdataset: nil, bands: [], previewID: nil)
        #expect(inspection.bands.count == 4)
        #expect(try Data(contentsOf: asset.url) == original)

        let normalized = SpatialGridOverlapSelection.normalized(inspection.bands, preserving: [])
        let timestep = try #require(SpatialGridOverlapSelection.groups(in: normalized).first { $0.component == "Value" })
        #expect(timestep.bands.count == 2)
        let alternateSourceBand = try #require(timestep.bands.first { $0.file == overlappingSource.path })
        let selectedBands = try #require(SpatialGridOverlapSelection.selecting(alternateSourceBand.id, in: timestep.id, from: normalized))
        let selectedGroup = try #require(SpatialGridOverlapSelection.groups(in: selectedBands).first { $0.id == timestep.id })
        #expect(selectedGroup.selectedBandIDs == [alternateSourceBand.id])

        let preview = try await editor.inspectGrid(layerID: "airPressure", files: [firstSource, overlappingSource],
            subdataset: nil, bands: selectedBands, previewID: alternateSourceBand.id)
        #expect(preview.preview?.minimum == 101000)
        editor.set("BoundaryConditionsSummary/BoundaryCondition_Description", "按时间点选择重叠源并保存草稿")
        let selection = SpatialGridSelection(layerId: "airPressure", bands: selectedBands, units: "Pa", dataType: "inst-val")
        #expect(await editor.importGrid(selection))
        #expect(!editor.modified && editor.error == nil)
        #expect(editor.fields["BoundaryConditionsSummary/BoundaryCondition_Description"] == "按时间点选择重叠源并保存草稿")
        #expect(editor.spatialPresentations["airPressure"]?.gridData?.times.count == 2)

        let importedTime = timestep.time
        let frameStep = try #require(editor.spatialPresentations["airPressure"]?.timeSteps.first { $0.date == importedTime })
        #expect(await editor.perform(.selectSpatialTime(layerID: "airPressure", stepID: frameStep.id)))
        #expect(editor.spatialPresentations["airPressure"]?.gridData?.preview?.minimum == 1010)
    }
}
