import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

@MainActor private final class RevisionProvider: ModelEditorProvider {
    static let field = "PlanSettingsPage/ViewModel_SelectedPlan_Description"
    var lastSavedRevision: String?
    var deferSave = true
    private var completion: CheckedContinuation<EditorSaveResult, Never>?
    private var waiter: CheckedContinuation<Void, Never>?
    func load(_ asset: ProjectAsset, kind: ModelEditorKind) async throws -> EditorSnapshot {
        .init(fields: [Self.field: "on disk"], rows: [:], samples: [:], canEdit: true, images: [:], sourceRevision: "revision-1")
    }
    func save(_ asset: ProjectAsset, changes: EditorEdits) async throws { _ = try await saveModel(asset, changes: changes) }
    func saveModel(_ asset: ProjectAsset, changes: EditorEdits) async throws -> EditorSaveResult {
        lastSavedRevision = changes.sourceRevision
        guard deferSave else { return EditorSaveResult(sourceRevision: "revision-3") }
        return await withCheckedContinuation { continuation in
            completion = continuation; waiter?.resume(); waiter = nil
        }
    }
    func waitUntilSaving() async { if completion == nil { await withCheckedContinuation { waiter = $0 } } }
    func finish() { completion?.resume(returning: EditorSaveResult(sourceRevision: "revision-2")); completion = nil; deferSave = false }
    func perform(_ asset: ProjectAsset, action: EditorAction) async throws -> EditorSnapshot { throw CancellationError() }
}

struct EditorRevisionTests {
    @Test @MainActor func laterEditsRemainDirtyAndDiscardReturnsToTheActuallySavedVersion() async {
        let provider = RevisionProvider()
        let editor = ModelEditorSession(provider: provider)
        let asset = ProjectAsset(url: URL(fileURLWithPath: "/fixture/plan.h5"), section: .plans)
        await editor.load(asset, kind: .plan)
        editor.set(RevisionProvider.field, "captured save")
        let saving = Task { await editor.saveLoadedModel() }
        await provider.waitUntilSaving()
        editor.set(RevisionProvider.field, "typed while saving")
        provider.finish()
        #expect(!(await saving.value))
        #expect(editor.modified && editor.fields[RevisionProvider.field] == "typed while saving")
        editor.discardEdits()
        #expect(!editor.modified && editor.fields[RevisionProvider.field] == "captured save")
        editor.set(RevisionProvider.field, "next edit")
        #expect(await editor.saveLoadedModel())
        #expect(provider.lastSavedRevision == "revision-2")
    }
}
