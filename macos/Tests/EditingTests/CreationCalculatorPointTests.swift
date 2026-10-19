import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

@MainActor
private final class CreationCalculatorPointProvider: ToolProvider {
    var result = DataToolPresentation()
    var fail = false
    var execution: ToolRequest?
    func prepare(_ request: ToolRequest) async throws -> DataToolPresentation {
        if fail { throw DataToolError.unavailable }; return result
    }
    func execute(_ request: ToolRequest) async throws { execution = request; throw DataToolError.unavailable }
}

struct CreationCalculatorPointTests {
    @Test @MainActor
    func identicalFieldsInAnotherProjectMapOrTableCannotReusePreparedReadiness() async throws {
        let state = DataToolSession(), editor = ModelEditorSession(), provider = CreationCalculatorPointProvider()
        editor.startDraft(); provider.result.canExecute = true
        let project = UUID(), map = UUID()
        let original = DataToolContext(projectSessionID: project, mapID: map, assetID: "source-model", extent: nil,
            attributeTable: .init(modelAssetID: "source-model", tableID: "source-table", columnID: "column-1"))
        func request(_ context: DataToolContext) -> ToolRequest { state.request(kind: .renameAttribute, editor: editor, context: context) }
        await state.prepare(request(original), editor: editor, provider: provider, currentRequest: { request(original) })?.value
        #expect(state.canExecute(request(original)))
        #expect(!state.canExecute(request(.init(projectSessionID: UUID(), mapID: map, assetID: "source-model", extent: nil, attributeTable: original.attributeTable))))
        #expect(!state.canExecute(request(.init(projectSessionID: project, mapID: UUID(), assetID: "source-model", extent: nil, attributeTable: original.attributeTable))))
        #expect(!state.canExecute(request(.init(projectSessionID: project, mapID: map, assetID: "source-model", extent: nil,
            attributeTable: .init(modelAssetID: "source-model", tableID: "source-table", columnID: "column-2")))))
        state.stopPreparation()
        #expect(!state.canExecute(request(original)))
    }
    @Test @MainActor
    func calculatorReplyReplacesTheOppositeSideAndFailureKeepsCurrentInput() async throws {
        let state = DataToolSession(), editor = ModelEditorSession(), provider = CreationCalculatorPointProvider()
        let from = "UnitCalculator/FromInput", to = "UnitCalculator/ToOutput"
        editor.startDraft(); editor.set(from, "12.5"); editor.set(to, "older input")
        state.triggeringField = from
        provider.result.editor = .init(fields: [from: "ignored default", to: "source forward reply"], rows: [:], samples: [:], canEdit: true, images: [:])
        let context = DataToolContext(projectSessionID: UUID(), mapID: UUID(), assetID: nil, extent: nil)
        func request() -> ToolRequest { state.request(kind: .unitCalculator, editor: editor, context: context) }
        await state.prepare(request(), editor: editor, provider: provider, currentRequest: request)?.value
        #expect(editor.fields[from] == "12.5")
        #expect(editor.fields[to] == "source forward reply")
        editor.set(to, "24.75"); state.triggeringField = to
        provider.result.editor = .init(fields: [from: "source reverse reply", to: "ignored default"], rows: [:], samples: [:], canEdit: true, images: [:])
        await state.prepare(request(), editor: editor, provider: provider, currentRequest: request)?.value
        #expect(editor.fields[from] == "source reverse reply")
        #expect(editor.fields[to] == "24.75")
        provider.fail = true; editor.set(to, "125.75")
        await state.prepare(request(), editor: editor, provider: provider, currentRequest: request)?.value
        #expect(state.error != nil)
        #expect(editor.fields[to] == "125.75")
    }

    @Test @MainActor
    func computedGrainSizeColumnsCanReplaceFormerInputDraftsAndNeverReturnAsEditableResults() {
        let state = DataToolSession(), editor = ModelEditorSession()
        let table = "WilcockBTMControl/GrainSize"
        var input = EditorSnapshot(fields: [:], rows: [table: [.init(id: "source-fraction", values: ["SurfaceCdf": "10", "TransportCdf": "20"])]], samples: [:], canEdit: true, images: [:], tablePresentations: [table: .init(columns: [
            .init(id: "SurfaceCdf", title: "Surface", sourceType: "double"), .init(id: "TransportCdf", title: "Transport", sourceType: "double", readOnly: true)])])
        editor.startDraft(input); editor.setCell(table: table, rowID: "source-fraction", column: "SurfaceCdf", value: "25")
        input.tablePresentations[table] = .init(columns: [
            .init(id: "SurfaceCdf", title: "Surface", sourceType: "double", readOnly: true), .init(id: "TransportCdf", title: "Transport", sourceType: "double")])
        editor.mergeToolPresentation(input)
        #expect(editor.rows[table]?.first?.values["SurfaceCdf"] == "10")
        let request = state.request(kind: .wilcock, editor: editor, context: .init(projectSessionID: UUID(), mapID: UUID(), assetID: nil, extent: nil))
        #expect(request.rows[table]?.first?.values["SurfaceCdf"] == nil)
        #expect(request.rows[table]?.first?.values["TransportCdf"] == "20")
    }

    @Test @MainActor
    func pointDraftSurvivesMetadataRefreshAndFailedAcceptWithoutLosingSourceIDs() async throws {
        let state = DataToolSession(), editor = ModelEditorSession(), provider = CreationCalculatorPointProvider()
        editor.startDraft()
        let point = InterestPoint(id: UUID(), serverID: 42, name: "源点", x: 123.5, y: 456.75)
        provider.result.pointImport = .init(points: [point], canEdit: true); provider.result.canExecute = true
        let context = DataToolContext(projectSessionID: UUID(), mapID: UUID(), assetID: "source-map", extent: nil)
        func request() -> ToolRequest { state.request(kind: .poiImport, editor: editor, context: context) }
        await state.prepare(request(), editor: editor, provider: provider, currentRequest: request)?.value
        state.editPoint(point.id, name: "保留的中文点名", location: .init(x: 125, y: 460))
        state.addPoint(.init(x: 126, y: 461))
        await state.prepare(request(), editor: editor, provider: provider, currentRequest: request)?.value
        #expect(state.interestPoints.count == 2)
        #expect(state.interestPoints.first?.id == point.id)
        #expect(state.interestPoints.first?.serverID == 42)
        #expect(state.interestPoints.first?.name == "保留的中文点名")
        await state.execute(request(), provider: provider, completion: {})?.value
        #expect(state.error != nil)
        #expect(state.interestPoints.first?.name == "保留的中文点名")
        #expect(provider.execution?.interestPoints.count == 2)
        #expect(provider.execution?.interestPoints.first?.x == 125)
    }
}
