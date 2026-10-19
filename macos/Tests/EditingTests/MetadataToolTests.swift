import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

@MainActor
private final class MetadataSourceProvider: ToolProvider {
    var presentation = DataToolPresentation()
    var actionResult = DataToolPresentation()
    var fail = false
    var actions: [ToolRequest] = []
    func prepare(_ request: ToolRequest) async throws -> DataToolPresentation { presentation }
    func execute(_ request: ToolRequest) async throws { throw DataToolError.unavailable }
    func perform(_ request: ToolRequest) async throws -> DataToolPresentation {
        actions.append(request)
        if fail { throw DataToolError.unavailable }
        return actionResult
    }
}

struct MetadataToolTests {
    @Test @MainActor
    func failedAssignmentKeepsChineseDraftAndSuccessfulSourceResetClearsOnlyAssignmentFields() async throws {
        let editor = ModelEditorSession(), state = DataToolSession(), provider = MetadataSourceProvider()
        let key = "SetTagValueControl/ViewModel_Value", selected = "SetTagValueControl/ViewModel_SelectedTagDefinition"
        let unrelated = "CreateTagControl/ViewModel_NewTagName"
        editor.startDraft(); editor.set(key, "未提交的中文标记值"); editor.set(selected, "source-definition"); editor.set(unrelated, "保留的新标记草稿")
        provider.presentation.canExecute = true
        provider.presentation.editor = .init(fields: [key: "original", selected: "source-definition"], rows: [:], samples: [:], canEdit: true, images: [:])
        let origin = DataToolContext(projectSessionID: UUID(), mapID: UUID(), assetID: "source-layer", extent: nil)
        func request() -> ToolRequest { state.request(kind: .tagEdit, editor: editor, context: origin) }
        await state.prepare(request(), editor: editor, provider: provider, currentRequest: request)?.value
        var action = request(); action.operation = .assignTag
        provider.fail = true
        await state.perform(action, editor: editor, provider: provider, currentRequest: request, sourceWins: [key, selected])?.value
        #expect(state.error != nil)
        #expect(editor.fields[key] == "未提交的中文标记值")
        #expect(editor.fields[selected] == "source-definition")
        provider.fail = false
        provider.actionResult.editor = .init(fields: [key: "", selected: ""], rows: [:], samples: [:], canEdit: true, images: [:])
        await state.perform(action, editor: editor, provider: provider, currentRequest: request, sourceWins: [key, selected])?.value
        #expect(state.error == nil)
        #expect(editor.fields[key] == "")
        #expect(editor.fields[selected] == "")
        #expect(editor.fields[unrelated] == "保留的新标记草稿")
    }

    @Test @MainActor
    func recentTagCanBeAssignedWithoutAChosenTagButUnknownRecentIDsCannotExecute() async throws {
        let state = DataToolSession(), editor = ModelEditorSession(), provider = MetadataSourceProvider()
        editor.startDraft()
        provider.presentation.metadata = .init(recentTags: [.init(id: "recent-source-object", definitionID: "source-definition", key: "河段名称", value: "中文值")])
        let origin = DataToolContext(projectSessionID: UUID(), mapID: UUID(), assetID: "source-layer", extent: nil)
        func request() -> ToolRequest { state.request(kind: .tagEdit, editor: editor, context: origin) }
        await state.prepare(request(), editor: editor, provider: provider, currentRequest: request)?.value
        #expect(!state.canExecute(request()))
        var action = request(); action.operation = .assignRecentTag; action.sourceItemID = "not-in-source"
        #expect(state.perform(action, editor: editor, provider: provider, currentRequest: request) == nil)
        #expect(provider.actions.isEmpty)
        action.sourceItemID = "recent-source-object"
        await state.perform(action, editor: editor, provider: provider, currentRequest: request)?.value
        #expect(provider.actions.count == 1)
        #expect(provider.actions.first?.sourceItemID == "recent-source-object")
    }

    @Test @MainActor
    func attributeCommandsRetainTableAndColumnIdentityAndClosingClearsTheContext() {
        let store = WorkspaceStore()
        let table = AttributeToolContext(modelAssetID: "model-A", tableID: "source-table", columnID: "source-column")
        store.activeAttributeToolContext = table; store.activeTool = .renameAttribute
        #expect(store.activeAttributeToolContext?.modelAssetID == "model-A")
        #expect(store.activeAttributeToolContext?.tableID == "source-table")
        #expect(store.activeAttributeToolContext?.columnID == "source-column")
        store.activeTool = nil
        #expect(store.activeAttributeToolContext == nil)
    }
}
