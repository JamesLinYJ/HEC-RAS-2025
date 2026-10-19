import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

@MainActor
private final class IncompleteInputModelProvider: ModelEditorProvider {
    nonisolated static let numericField = "PlanComputeSettingsPage/ViewModel_SelectedPlan_MaxCourant"
    private(set) var saves = 0

    func load(_ asset: ProjectAsset, kind: ModelEditorKind) async throws -> EditorSnapshot {
        .init(fields: [Self.numericField: "0.25"], rows: [:], samples: [:], canEdit: true,
            images: [:], sourceRevision: "incomplete-input-source-revision")
    }

    func save(_ asset: ProjectAsset, changes: EditorEdits) async throws { saves += 1 }

    func perform(_ asset: ProjectAsset, action: EditorAction) async throws -> EditorSnapshot {
        throw CocoaError(.featureUnsupported)
    }
}

@MainActor
private final class IncompleteInputToolProvider: ToolProvider {
    var response = DataToolPresentation()
    private(set) var prepares = 0
    private(set) var performs = 0
    private(set) var executions = 0

    func execute(_ request: ToolRequest) async throws { executions += 1 }

    func prepare(_ request: ToolRequest) async throws -> DataToolPresentation {
        prepares += 1
        return response
    }

    func perform(_ request: ToolRequest) async throws -> DataToolPresentation {
        performs += 1
        return response
    }

    func searchProjections(_ query: String) async throws -> [ToolProjectionMatch] { [] }
}

struct IncompleteEditorInputWorkflowTests {
    private let fieldID = IncompleteInputModelProvider.numericField
    private let units = DisplayUnitData(sourceId: "source-unit", selectionId: "max-courant-units",
        choices: [.init(id: "source-unit", scale: 1, offset: 0)])

    @Test @MainActor
    func invalidNumericDraftChangesToolSignatureAndBlocksEveryProviderEntryPoint() async throws {
        let original = "0.25"
        let editor = ModelEditorSession()
        editor.startDraft(.init(fields: [fieldID: original], rows: [:], samples: [:], canEdit: true, images: [:]))
        let state = DataToolSession()
        let provider = IncompleteInputToolProvider()
        provider.response.canExecute = true
        provider.response.editor = .init(fields: [fieldID: original], rows: [:], samples: [:], canEdit: true, images: [:])
        let context = DataToolContext(projectSessionID: UUID(), mapID: UUID(), assetID: nil, extent: nil)
        func currentRequest() -> ToolRequest { state.request(kind: .newPlan, editor: editor, context: context) }

        let validRequest = currentRequest()
        await state.prepare(validRequest, editor: editor, provider: provider,
            currentRequest: currentRequest)?.value
        #expect(state.canExecute(currentRequest()))
        #expect(provider.prepares == 1)
        let preparedSignature = state.signature(currentRequest())

        let owner = OriginalUnitNumberInputOwner.field(fieldID)
        #expect(editor.updateUnitNumberInput(rawText: "-", owner: owner, units: units,
            locale: Locale(identifier: "en_US")) != nil)
        let draft = try #require(editor.unitNumberInputDraft(for: owner))
        let invalidRequest = currentRequest()

        #expect(draft.rawDisplayText == "-")
        #expect(editor.fields[fieldID] == original)
        #expect(invalidRequest.fields[fieldID] == original)
        #expect(invalidRequest.inputIssue == editor.incompleteEditorInputIssue)
        #expect(state.signature(invalidRequest) != preparedSignature)
        #expect(!state.canExecute(invalidRequest))
        #expect(state.prepare(invalidRequest, editor: editor, provider: provider,
            currentRequest: currentRequest) == nil)
        #expect(state.perform(invalidRequest, editor: editor, provider: provider,
            currentRequest: currentRequest) == nil)
        #expect(state.execute(invalidRequest, provider: provider, completion: {}) == nil)
        #expect(provider.prepares == 1 && provider.performs == 0 && provider.executions == 0)
        #expect(editor.unitNumberInputDraft(for: owner)?.rawDisplayText == "-")
    }

    @Test @MainActor
    func toolSignatureTracksDateAndNumericIssuesWithoutChangingSourceFields() throws {
        let dateField = "PlanSettingsPage/ViewModel_SelectedPlan_ComputeStartTime"
        let dateSource = "2026-10-16T10:00:00Z"
        let numericSource = "0.25"
        let editor = ModelEditorSession()
        editor.startDraft(.init(fields: [dateField: dateSource, fieldID: numericSource],
            rows: [:], samples: [:], canEdit: true, images: [:]))
        let state = DataToolSession()
        let context = DataToolContext(projectSessionID: UUID(), mapID: UUID(), assetID: nil, extent: nil)
        func request() -> ToolRequest { state.request(kind: .newPlan, editor: editor, context: context) }
        let cleanSignature = state.signature(request())

        editor.setDateTimeInputDraft(.init(sourceValue: dateSource, dateText: "2026-10-",
            timeText: "10:00:00", dateTouched: true, timeTouched: false,
            issueKey: "Improperly formatted date."), for: dateField)
        let dateIssueRequest = request()
        let dateSignature = state.signature(dateIssueRequest)
        #expect(dateIssueRequest.inputIssue == editor.incompleteEditorInputIssue)
        #expect(dateSignature != cleanSignature)

        let owner = OriginalUnitNumberInputOwner.field(fieldID)
        #expect(editor.updateUnitNumberInput(rawText: "1e", owner: owner, units: units,
            locale: Locale(identifier: "en_US")) != nil)
        // Date-time issues have stable priority while both drafts are pending.
        #expect(request().inputIssue == dateIssueRequest.inputIssue)
        #expect(state.signature(request()) == dateSignature)

        editor.clearDateTimeInputDraft(for: dateField)
        let numericIssueRequest = request()
        #expect(numericIssueRequest.inputIssue == editor.incompleteEditorInputIssue)
        #expect(numericIssueRequest.inputIssue != dateIssueRequest.inputIssue)
        #expect(state.signature(numericIssueRequest) != dateSignature)
        #expect(numericIssueRequest.fields[dateField] == dateSource)
        #expect(numericIssueRequest.fields[fieldID] == numericSource)
        editor.clearUnitNumberInputDraft(for: owner)
        #expect(state.signature(request()) == cleanSignature)
    }

    @Test @MainActor
    func saveAllPreflightsEveryEditorBeforeWritingAndComputeLeaseRejectsInvalidRawInput() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("incomplete-input-preflight-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let modelProvider = IncompleteInputModelProvider()
        let store = WorkspaceStore(
            system: SourceWorkflowFixtureServices(recoveryFolder: temporary.appendingPathComponent("Trash")),
            modelProvider: modelProvider)
        let asset = ProjectAsset(url: temporary.appendingPathComponent("Plans/Plan.h5"), section: .plans)
        let first = ModelEditorSession(provider: modelProvider)
        let second = ModelEditorSession(provider: modelProvider)
        await first.load(asset, kind: .plan)
        await second.load(asset, kind: .plan)
        store.registerEditor(first)
        store.registerEditor(second)

        // Put the ordinary dirty editor before the invalid one in Save All's
        // deterministic ordering. A sequential save would write this draft.
        let ordered = [first, second].sorted { $0.id.uuidString < $1.id.uuidString }
        let earlier = try #require(ordered.first)
        let invalid = try #require(ordered.last)
        earlier.set(fieldID, "0.5")
        let owner = OriginalUnitNumberInputOwner.field(fieldID)
        #expect(invalid.updateUnitNumberInput(rawText: "-", owner: owner, units: units,
            locale: Locale(identifier: "en_US")) != nil)

        #expect(earlier.modified)
        #expect(invalid.hasIncompleteEditorInput)
        #expect(invalid.hasUnsavedEditorChanges)
        #expect(store.hasUnsavedModelEdits)
        #expect(!(await store.saveModelEditsOnly()))
        #expect(!(await store.saveAll()))
        #expect(modelProvider.saves == 0)
        #expect(earlier.fields[fieldID] == "0.5")
        #expect(invalid.fields[fieldID] == "0.25")
        #expect(invalid.unitNumberInputDraft(for: owner)?.rawDisplayText == "-")
        #expect(store.errorMessage == invalid.incompleteEditorInputIssue)

        #expect(invalid.currentPlanComputeContext() == nil)
        // Invalid raw input must fail before any project/capture preflight.
        let capture = WorkspaceResultComputeCapture(projectSessionID: store.projectSessionID,
            editorID: invalid.id, operationOwnerToken: "invalid-input", operationContextID: "invalid-input",
            projectPath: temporary.appendingPathComponent("Unopened.ras").path,
            projectRevision: "not-used", projectXmlFingerprint: "not-used", planPath: asset.id,
            planRevision: try #require(invalid.sourceFileRevision))
        #expect(!store.beginPlanCompute(editorID: invalid.id, assetID: asset.id,
            dependencyPaths: [asset.id], writePaths: [], projectSessionID: store.projectSessionID, capture: capture))
        #expect(!store.isRunningPlanCompute)
        #expect(store.errorMessage == invalid.incompleteEditorInputIssue)
        #expect(invalid.unitNumberInputDraft(for: owner)?.rawDisplayText == "-")
    }
}
