import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

@MainActor
private final class RasterRoutingProvider: ToolProvider {
    let tableID = "RasterCalculatorEditor/Inputs"
    var operations: [DataToolOperation] = []
    var editingExisting = false
    var inputs: [EditorRow] = []
    private var presentation: DataToolPresentation {
        var value = DataToolPresentation()
        value.canExecute = true
        value.editor = .init(fields: ["RasterCalculatorEditor/Expression": "z", "RasterCalculatorEditor/IsEditingExisting": String(editingExisting)],
            rows: [tableID: inputs], samples: [:], canEdit: true, images: [:],
            tablePresentations: [tableID: .init(columns: [.init(id: "VariableName", title: "Variable", sourceType: "string")], canAddRows: true, canDeleteRows: true)])
        return value
    }
    func execute(_ request: ToolRequest) async throws { throw CocoaError(.featureUnsupported) }
    func prepare(_ request: ToolRequest) async throws -> DataToolPresentation { presentation }
    func perform(_ request: ToolRequest) async throws -> DataToolPresentation {
        operations.append(request.operation)
        if request.operation == .addInput { inputs = [.init(id: "input-1", values: ["VariableName": "z"])] }
        if request.operation == .removeInput { inputs = [] }
        return presentation
    }
}

struct RasterCalculatorRoutingTests {
    @Test @MainActor func sourceCalculatorCommandsReachProviderAndRejectUnknownRows() async {
        let state = DataToolSession(), editor = ModelEditorSession(), provider = RasterRoutingProvider()
        let context = DataToolContext(projectSessionID: UUID(), mapID: UUID(), assetID: "result", extent: nil)
        editor.startDraft()
        func request() -> ToolRequest { state.request(kind: .rasterCalculator, editor: editor, context: context) }
        await state.prepare(request(), editor: editor, provider: provider, currentRequest: request)?.value
        var add = request(); add.operation = .addInput
        await state.perform(add, editor: editor, provider: provider, currentRequest: request)?.value
        #expect(provider.operations == [.addInput])
        #expect(editor.rows[provider.tableID]?.first?.id == "input-1")
        var invalid = request(); invalid.operation = .removeInput; invalid.sourceItemID = "not-a-source-row"
        #expect(state.perform(invalid, editor: editor, provider: provider, currentRequest: request) == nil)
        #expect(provider.operations.count == 1)
        var remove = request(); remove.operation = .removeInput; remove.sourceItemID = "input-1"
        await state.perform(remove, editor: editor, provider: provider, currentRequest: request)?.value
        #expect(provider.operations == [.addInput, .removeInput])
        var map = request(); map.operation = .addToMap
        await state.perform(map, editor: editor, provider: provider, currentRequest: request)?.value
        #expect(provider.operations.last == .addToMap)
        var save = request(); save.operation = .saveExisting
        #expect(state.perform(save, editor: editor, provider: provider, currentRequest: request) == nil)
    }
    @Test @MainActor func changingSpatialImportDestinationInvalidatesPreparedRequest() {
        let state = DataToolSession(), editor = ModelEditorSession()
        let projectID = UUID(), mapID = UUID()
        let precipitation = DataToolContext(projectSessionID: projectID, mapID: mapID, assetID: "boundary", extent: nil, spatialLayerID: "precipitation")
        let wind = DataToolContext(projectSessionID: projectID, mapID: mapID, assetID: "boundary", extent: nil, spatialLayerID: "wind")
        let first = state.request(kind: .spatialImport, editor: editor, context: precipitation)
        let second = state.request(kind: .spatialImport, editor: editor, context: wind)
        #expect(state.signature(first) != state.signature(second))
    }
}
