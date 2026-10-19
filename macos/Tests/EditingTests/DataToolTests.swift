import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

@MainActor
private final class DataToolPresentationProvider: ToolProvider {
    var response = DataToolPresentation()
    var fail = false
    var afterRequest: (() -> Void)?
    var executions: [ToolRequest] = []
    func prepare(_ request: ToolRequest) async throws -> DataToolPresentation {
        afterRequest?()
        if fail { throw DataToolError.unavailable }
        return response
    }
    func execute(_ request: ToolRequest) async throws { executions.append(request) }
}

struct DataToolTests {
    @MainActor private func context() -> DataToolContext {
        .init(projectSessionID: UUID(), mapID: UUID(), assetID: "original-source-model", extent: nil)
    }

    @Test @MainActor
    func metadataRefreshKeepsDraftsAndOriginalReadonlyValuesOutOfExecution() async throws {
        let state = DataToolSession(), editor = ModelEditorSession(), provider = DataToolPresentationProvider()
        editor.startDraft()
        editor.set("RgbTiffExporterControl/CellSize", "2.75")
        let output = URL(fileURLWithPath: "/tmp/中文输出.tif")
        provider.response.editor = .init(fields: ["RgbTiffExporterControl/CellSize": "1",
            "RgbTiffExporterControl/OutputPath": output.path,
            "RgbTiffExporterControl/DimensionsText": "100 × 200",
            "RgbTiffExporterControl/EstimatedSizeText": "source estimate"], rows: [:], samples: [:], canEdit: true, images: [:])
        provider.response.canExecute = true
        let origin = context()
        func request() -> ToolRequest { state.request(kind: .rasterExport, editor: editor, context: origin) }
        await state.prepare(request(), editor: editor, provider: provider, currentRequest: request)?.value
        #expect(editor.fields["RgbTiffExporterControl/CellSize"] == "2.75")
        #expect(editor.fields["RgbTiffExporterControl/DimensionsText"] == "100 × 200")
        #expect(request().fields["RgbTiffExporterControl/DimensionsText"] == nil)
        #expect(request().fields["RgbTiffExporterControl/EstimatedSizeText"] == nil)
        #expect(request().destination == output)
        #expect(state.canExecute(request()))
        editor.set("RgbTiffExporterControl/CellSize", "3")
        #expect(!state.canExecute(request()))
    }

    @Test @MainActor
    func changedInputsRejectOldReadinessAndPreparationFailuresRetainDrafts() async throws {
        let state = DataToolSession(), editor = ModelEditorSession(), provider = DataToolPresentationProvider()
        editor.startDraft(); editor.set("TerrainImporter/AutoStitch", "true")
        state.inputFiles = [URL(fileURLWithPath: "/tmp/first.tif")]
        provider.response.canExecute = true
        provider.response.editor = .init(fields: ["TerrainImporter/AutoStitch": "false"], rows: [:], samples: [:], canEdit: true, images: [:])
        provider.afterRequest = { state.inputFiles = [URL(fileURLWithPath: "/tmp/second.tif")] }
        let origin = context()
        func request() -> ToolRequest { state.request(kind: .terrainImport, editor: editor, context: origin) }
        await state.prepare(request(), editor: editor, provider: provider, currentRequest: request)?.value
        #expect(!state.canExecute(request()))
        #expect(editor.fields["TerrainImporter/AutoStitch"] == "true")
        provider.afterRequest = nil
        await state.prepare(request(), editor: editor, provider: provider, currentRequest: request)?.value
        #expect(state.canExecute(request()))
        provider.fail = true
        await state.prepare(request(), editor: editor, provider: provider, currentRequest: request)?.value
        #expect(!state.canExecute(request()))
        #expect(state.error != nil)
        #expect(editor.fields["TerrainImporter/AutoStitch"] == "true")
    }

    @Test @MainActor
    func sourceBandUpdatesPreserveOnlyEditedCellsAndExplicitSelectionsCanReplaceThem() async throws {
        let editor = ModelEditorSession(), table = "SpatialBoundaryConditionRasterImporter"
        let columns = [SourceTableColumn(id: "UseBand", title: "Use", sourceType: "bool"),
            SourceTableColumn(id: "TimeGenerated", title: "Issue Time", sourceType: "string", readOnly: true)]
        let first = EditorSnapshot(fields: [:], rows: [table: [.init(id: "band", values: ["UseBand": "true", "TimeGenerated": "source 1"])]],
            samples: [:], canEdit: true, images: [:], tablePresentations: [table: .init(columns: columns)])
        editor.startDraft(first)
        editor.setCell(table: table, rowID: "band", column: "UseBand", value: "false")
        let refresh = EditorSnapshot(fields: [:], rows: [table: [.init(id: "band", values: ["UseBand": "true", "TimeGenerated": "source 2"])]],
            samples: [:], canEdit: true, images: [:], tablePresentations: first.tablePresentations)
        editor.mergeToolPresentation(refresh)
        #expect(editor.rows[table]?.first?.values["UseBand"] == "false")
        #expect(editor.rows[table]?.first?.values["TimeGenerated"] == "source 2")
        editor.mergeToolPresentation(refresh, overwriteRows: true)
        #expect(editor.rows[table]?.first?.values["UseBand"] == "true")
    }

    @Test @MainActor
    func coreCopyAndReferenceRemainDifferentSourceOperationsAndDirectoryExportCannotUpload() async throws {
        let state = DataToolSession(), editor = ModelEditorSession(), provider = DataToolPresentationProvider()
        editor.startDraft(); state.inputFiles = [URL(fileURLWithPath: "/tmp/source.h5")]
        provider.response.canExecute = true
        let origin = context()
        func request() -> ToolRequest { state.request(kind: .coreImport, editor: editor, context: origin) }
        await state.prepare(request(), editor: editor, provider: provider, currentRequest: request)?.value
        var reference = request(); reference.operation = .addReference
        await state.execute(reference, provider: provider, completion: {})?.value
        var copy = request(); copy.operation = .copyFile
        await state.execute(copy, provider: provider, completion: {})?.value
        #expect(provider.executions.map(\.operation) == [.addReference, .copyFile])
        editor.set("PlanExporterControl/ExportTypeIndex", "1"); editor.set("PlanExporterControl/EnableUpload", "true")
        let plan = state.request(kind: .planExport, editor: editor, context: origin)
        #expect(plan.fields["PlanExporterControl/EnableUpload"] == "false")
    }
}
