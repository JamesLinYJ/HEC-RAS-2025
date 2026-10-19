import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

@MainActor
private final class SupportToolSource: ToolProvider {
    var presentation = DataToolPresentation()
    var result = DataToolPresentation()
    var fail = false
    var actions: [ToolRequest] = []
    var executions = 0
    func prepare(_ request: ToolRequest) async throws -> DataToolPresentation { presentation }
    func perform(_ request: ToolRequest) async throws -> DataToolPresentation {
        actions.append(request)
        if fail { throw DataToolError.unavailable }; return result
    }
    func execute(_ request: ToolRequest) async throws { executions += 1 }
}

struct SupportToolTests {
    @Test @MainActor
    func failedLoginRetainsDraftAndClearOnlyAcceptsTheSourcesCredentialReset() async throws {
        let state = DataToolSession(), editor = ModelEditorSession(), source = SupportToolSource()
        let key = "CredentialsPage/Key", secret = "CredentialsPage/Secret"
        let token = "CredentialsPage/Ras_Interface_WinUI_AppData_RasApplicationData_Instance_DevAppData_GpuHubToken"
        editor.startDraft(); editor.set(key, "fixture-user"); editor.set(secret, "fixture-not-a-real-secret"); editor.set(token, "fixture-token-draft")
        source.presentation.support = .init(canLogin: true, canClearCredentials: true)
        let context = DataToolContext(projectSessionID: UUID(), mapID: UUID(), assetID: nil, extent: nil)
        func request() -> ToolRequest { state.request(kind: .credentials, editor: editor, context: context) }
        await state.prepare(request(), editor: editor, provider: source, currentRequest: request)?.value
        let signature = state.signature(request())
        #expect(!signature.contains("fixture-user"))
        #expect(!signature.contains("fixture-not-a-real-secret"))
        var login = request(); login.operation = .login; source.fail = true
        await state.perform(login, editor: editor, provider: source, currentRequest: request)?.value
        #expect(state.error != nil)
        #expect(editor.fields[secret] == "fixture-not-a-real-secret")
        #expect(state.executingOperation == nil)
        source.fail = false
        source.result.editor = .init(fields: [key: "", secret: ""], rows: [:], samples: [:], canEdit: true, images: [:])
        var clear = request(); clear.operation = .clearCredentials
        await state.perform(clear, editor: editor, provider: source, currentRequest: request, sourceWins: [key, secret])?.value
        #expect(editor.fields[key] == "")
        #expect(editor.fields[secret] == "")
        #expect(editor.fields[token] == "fixture-token-draft")
    }

    @Test @MainActor
    func unimplementedOriginalModelUploadCannotReportACompletedSubmission() async throws {
        let state = DataToolSession(), editor = ModelEditorSession(), source = SupportToolSource()
        editor.startDraft(); source.presentation.canExecute = true; source.presentation.support = .init(showsModelForm: true)
        let context = DataToolContext(projectSessionID: UUID(), mapID: UUID(), assetID: "fixture-model", extent: nil)
        func request() -> ToolRequest { state.request(kind: .reportIssue, editor: editor, context: context) }
        await state.prepare(request(), editor: editor, provider: source, currentRequest: request)?.value
        var completed = false
        #expect(state.execute(request(), provider: source, completion: { completed = true }) == nil)
        #expect(source.executions == 0)
        #expect(!completed)
    }

    @Test
    func reportLengthsFollowOriginalUtf16LimitsForMultibyteText() {
        let description = "复现步骤"
        let original = ["JiraBugReportForm/Report_Summary": String(repeating: "🌊", count: 50), "JiraBugReportForm/Report_Description": description]
        #expect(BugReportLimits.valid(fields: original))
        var over = original; over["JiraBugReportForm/Report_Summary"] = String(repeating: "🌊", count: 51)
        #expect(!BugReportLimits.valid(fields: over))
        over = original; over["JiraBugReportForm/Report_Description"] = ""
        #expect(!BugReportLimits.valid(fields: over))
    }
}
