import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

@MainActor
private final class DeferredModelProvider: ModelEditorProvider {
    var capturedEdits: [EditorEdits] = []
    var loadCount = 0
    var initialFields = ["OriginalField": "1"]
    var initialRows: [String: [EditorRow]] = [:]
    var initialSamples: [String: [ChartSample]] = [:]
    var editableSamplePages: Set<String> = []
    var tablePresentations: [String: EditorTablePresentation] = [:]
    var textSuggestions: [String: [String]] = [:]
    var performedActions = 0
    private var completion: CheckedContinuation<Void, any Error>?
    private var started: CheckedContinuation<Void, Never>?
    func load(_ asset: ProjectAsset, kind: ModelEditorKind) async throws -> EditorSnapshot {
        loadCount += 1
        return EditorSnapshot(fields: initialFields, rows: initialRows, samples: initialSamples, canEdit: true, images: [:], editableSamplePages: editableSamplePages, textSuggestions: textSuggestions, tablePresentations: tablePresentations)
    }
    func save(_ asset: ProjectAsset, changes: EditorEdits) async throws {
        capturedEdits.append(changes)
        try await withCheckedThrowingContinuation { continuation in
            completion = continuation; started?.resume(); started = nil
        }
    }
    func perform(_ asset: ProjectAsset, action: EditorAction) async throws -> EditorSnapshot {
        performedActions += 1
        return try await load(asset, kind: .plan)
    }
    func waitForSaveStart() async {
        if completion != nil { return }
        await withCheckedContinuation { started = $0 }
    }
    func finish(_ error: (any Error)? = nil) {
        let pending = completion; completion = nil
        if let error { pending?.resume(throwing: error) }
        else { pending?.resume() }
    }
}

@Suite(.serialized)
struct EditingTests {
    @Test @MainActor
    func catalogMetadataCannotBecomeAnEditableDraft() async throws {
        let schema = try #require(SourceEditorLibrary.shared.schema("ResultCatalogSummary"))
        let created = try #require(schema.fields.first { $0.sourceSetter.hasSuffix("_DateCreated") })
        let name = try #require(schema.fields.first { $0.kind == "catalogTitle" })
        let provider = DeferredModelProvider()
        provider.initialFields = [created.storageID: "original source date", name.storageID: "原始结果名"]
        let session = ModelEditorSession(provider: provider)
        await session.load(ProjectAsset(url: URL(fileURLWithPath: "/task-fixture/result.h5"), section: .results), kind: .result)
        session.set(created.storageID, "changed date")
        session.set(name.storageID, "changed name")
        #expect(session.fields[created.storageID] == "original source date")
        #expect(session.fields[name.storageID] == "原始结果名")
        #expect(!session.modified)
        #expect(provider.capturedEdits.isEmpty)
    }
    @Test @MainActor
    func sourceTableMetadataAndReadonlyIdentitySurviveSaveAndDiscard() async throws {
        let provider = DeferredModelProvider()
        provider.initialRows = ["SourceTable": [.init(id: "stable-row", values: ["Fid": "7", "UserValue": "original"])]]
        provider.textSuggestions = ["OriginalField": ["source suggestion"]]
        provider.tablePresentations = ["SourceTable": .init(columns: [
            .init(id: "Fid", title: "Identifier", sourceType: "int", readOnly: true, sortable: false),
            .init(id: "UserValue", title: "用户属性 (m)", sourceType: "string", width: 180, autoSuggestions: ["source choice"], titleIsUserData: true)
        ])]
        let session = ModelEditorSession(provider: provider)
        let asset = ProjectAsset(url: URL(fileURLWithPath: "/task-fixture/table.h5"), section: .geometries)
        await session.load(asset, kind: .geometry)
        session.setCell(table: "SourceTable", rowID: "stable-row", column: "Fid", value: "99")
        session.setCell(table: "SourceTable", rowID: "stable-row", column: "unknown-column", value: "ignored")
        #expect(!session.modified)
        await session.perform(.addRow(table: "SourceTable"))
        await session.perform(.removeRows(table: "SourceTable", ids: ["stable-row"]))
        #expect(provider.performedActions == 0)
        session.setCell(table: "SourceTable", rowID: "stable-row", column: "UserValue", value: "中文修改")
        let saving = Task { await session.save(asset) }
        await provider.waitForSaveStart(); provider.finish()
        #expect(await saving.value)
        session.setCell(table: "SourceTable", rowID: "stable-row", column: "UserValue", value: "second draft")
        session.discardEdits()
        #expect(session.rows["SourceTable"]?.first?.values["Fid"] == "7")
        #expect(session.rows["SourceTable"]?.first?.values["UserValue"] == "中文修改")
        #expect(session.tablePresentations["SourceTable"]?.columns.map(\.id) == ["Fid", "UserValue"])
        #expect(session.tablePresentations["SourceTable"]?.columns.last?.title == "用户属性 (m)")
        #expect(session.tablePresentations["SourceTable"]?.columns.last?.autoSuggestions == ["source choice"])
        #expect(session.textSuggestions["OriginalField"] == ["source suggestion"])
    }
    @Test @MainActor
    func classificationNameReachesSaveWithoutChangingImmutableSourceKey() async throws {
        let field = try #require(SourceEditorLibrary.shared.schema("RasterClassificationInputProperties")?.fields.first { $0.kind == "classificationMapping" })
        let provider = DeferredModelProvider()
        provider.initialRows = [field.storageID: [.init(id: "41", values: ["Key": "41", "Value": "原始名称"])]]
        let editing = ModelEditorSession(provider: provider)
        let asset = ProjectAsset(url: URL(fileURLWithPath: "/task-fixture/classification.h5"), section: .surfaceLayers)
        await editing.load(asset, kind: .surface)
        editing.setCell(table: field.storageID, rowID: "41", column: "Key", value: "99")
        #expect(!editing.modified)
        editing.setCell(table: field.storageID, rowID: "41", column: "Value", value: "河道分类")
        let saving = Task { await editing.save(asset) }
        await provider.waitForSaveStart()
        #expect(provider.capturedEdits.first?.rows[field.storageID]?.first?.values == ["Key": "41", "Value": "河道分类"])
        provider.finish(); #expect(await saving.value)
    }
    @Test @MainActor
    func tabReentryRetainsDraftAndCancelKeepsEditor() async throws {
        let provider = DeferredModelProvider()
        let workspace = WorkspaceStore(modelProvider: provider)
        let session = workspace.primaryEditorSession(.plan)
        workspace.openEditor(.plan)
        let asset = ProjectAsset(url: URL(fileURLWithPath: "/task-fixture/model.h5"), section: .plans)
        await session.ensureLoaded(asset, kind: .plan); session.set("OriginalField", "2")
        #expect(workspace.primaryEditorSession(.plan) === session)
        await session.ensureLoaded(asset, kind: .plan)
        #expect(provider.loadCount == 1)
        #expect(session.fields["OriginalField"] == "2")
        workspace.requestCloseActiveTab()
        #expect(workspace.showCloseTabConfirmation)
        workspace.cancelCloseTab()
        #expect(workspace.openEditors == [.plan])
        #expect(session.modified)
    }
    @Test @MainActor
    func failedTabSaveKeepsEditorAndDraft() async throws {
        let provider = DeferredModelProvider(), workspace = WorkspaceStore(modelProvider: nil)
        let session = ModelEditorSession(provider: provider)
        workspace.registerEditor(session, primaryKind: .plan); workspace.openEditor(.plan)
        let asset = ProjectAsset(url: URL(fileURLWithPath: "/task-fixture/model.h5"), section: .plans)
        await session.load(asset, kind: .plan); session.set("OriginalField", "2")
        workspace.requestCloseActiveTab()
        let closing = Task { await workspace.saveAndCloseTab() }
        await provider.waitForSaveStart(); provider.finish(CocoaError(.fileWriteNoPermission))
        #expect(await closing.value == false)
        #expect(workspace.openEditors == [.plan])
        #expect(session.modified)
        #expect(workspace.hasUnsavedChanges)
        #expect(!workspace.isClosingTab)
    }
    @Test @MainActor
    func savedTabCloseDoesNotDiscardDetachedEditorDraft() async throws {
        let provider = DeferredModelProvider(), workspace = WorkspaceStore(modelProvider: nil)
        let primary = ModelEditorSession(provider: provider), detached = ModelEditorSession(provider: provider)
        workspace.registerEditor(primary, primaryKind: .plan); workspace.registerEditor(detached); workspace.openEditor(.plan)
        let asset = ProjectAsset(url: URL(fileURLWithPath: "/task-fixture/model.h5"), section: .plans)
        await primary.load(asset, kind: .plan); await detached.load(asset, kind: .plan)
        primary.set("OriginalField", "2"); detached.set("OriginalField", "3")
        workspace.requestCloseActiveTab()
        let closing = Task { await workspace.saveAndCloseTab() }
        await provider.waitForSaveStart(); provider.finish()
        #expect(await closing.value)
        #expect(workspace.openEditors.isEmpty)
        #expect(detached.modified)
        #expect(detached.fields["OriginalField"] == "3")
        #expect(workspace.hasUnsavedChanges)
    }
    @Test @MainActor
    func discardTabCloseRemovesOnlyItsDraft() async throws {
        let provider = DeferredModelProvider(), workspace = WorkspaceStore(modelProvider: nil)
        let first = ModelEditorSession(provider: provider), second = ModelEditorSession(provider: provider)
        workspace.registerEditor(first, primaryKind: .plan); workspace.registerEditor(second); workspace.openEditor(.plan)
        let asset = ProjectAsset(url: URL(fileURLWithPath: "/task-fixture/model.h5"), section: .plans)
        await first.load(asset, kind: .plan); await second.load(asset, kind: .plan)
        first.set("OriginalField", "2"); second.set("OriginalField", "3")
        workspace.requestCloseActiveTab(); workspace.discardAndCloseTab()
        #expect(workspace.openEditors.isEmpty)
        #expect(first.fields["OriginalField"] == "1")
        #expect(second.modified)
        #expect(workspace.hasUnsavedChanges)
    }
    @Test @MainActor
    func editableTimeSeriesReachesSaveWithoutChangingReadOnlyResultSeries() async throws {
        let provider = DeferredModelProvider()
        provider.initialSamples = ["Time Series": [ChartSample(id: "point", x: 1, y: 2, series: "Flow")], "Results": [ChartSample(id: "point", x: 3, y: 4, series: "Depth")]]
        provider.editableSamplePages = ["Time Series"]
        let editor = ModelEditorSession(provider: provider)
        let asset = ProjectAsset(url: URL(fileURLWithPath: "/task-fixture/model.h5"), section: .boundaryConditions)
        await editor.load(asset, kind: .boundaryCondition)
        editor.setSample(page: "Time Series", id: "point", y: 7)
        editor.setSample(page: "Results", id: "point", y: 99)
        #expect(editor.samples["Results"]?.first?.y == 4)
        let saving = Task { await editor.saveLoadedModel() }
        await provider.waitForSaveStart(); provider.finish()
        #expect(await saving.value)
        #expect(provider.capturedEdits.first?.samples["Time Series"]?.first?.y == 7)
        #expect(provider.capturedEdits.first?.samples["Results"] == nil)
        #expect(!editor.modified)
    }
    @Test @MainActor
    func sameOriginalPropertyInDifferentEditorsCannotOverwriteOtherDraft() async throws {
        let first = try #require(SourceEditorLibrary.shared.schema("DepthShapeExporter")?.fields.first { $0.id == "CellSize" })
        let second = try #require(SourceEditorLibrary.shared.schema("RgbTiffExporterControl")?.fields.first { $0.id == "CellSize" })
        #expect(first.id == second.id)
        let provider = DeferredModelProvider()
        provider.initialFields = [first.storageID: "1", second.storageID: "2"]
        let session = ModelEditorSession(provider: provider)
        let asset = ProjectAsset(url: URL(fileURLWithPath: "/task-fixture/model.h5"), section: .plans)
        await session.load(asset, kind: .plan)
        session.set(first.storageID, "5")
        #expect(session.fields[second.storageID] == "2")
        let saving = Task { await session.saveLoadedModel() }
        await provider.waitForSaveStart()
        provider.finish()
        #expect(await saving.value)
        #expect(provider.capturedEdits.first?.fields == [first.storageID: "5"])
        #expect(session.fields[second.storageID] == "2")
    }
    @Test @MainActor
    func invalidScopedRecipeCannotReachModelSave() async throws {
        let field = try #require(SourceEditorLibrary.shared.schema("ConceptualMeshControlPointEditor")?.fields.first { $0.kind == "recipe" })
        let provider = DeferredModelProvider()
        let editor = ModelEditorSession(provider: provider)
        let asset = ProjectAsset(url: URL(fileURLWithPath: "/task-fixture/model.h5"), section: .geometries)
        await editor.load(asset, kind: .geometry)
        editor.set(field.storageID, "InventedMeshOperation()")
        #expect(await editor.saveLoadedModel() == false)
        #expect(provider.capturedEdits.isEmpty)
        #expect(editor.modified)
        #expect(editor.error != nil)
    }
    @Test @MainActor
    func discardRestoresOnlyThisModelBaseline() async throws {
        let provider = DeferredModelProvider()
        let first = ModelEditorSession(provider: provider)
        let second = ModelEditorSession(provider: provider)
        let store = WorkspaceStore(modelProvider: provider)
        let asset = ProjectAsset(url: URL(fileURLWithPath: "/task-fixture/model.h5"), section: .plans)
        await first.load(asset, kind: .plan); await second.load(asset, kind: .plan)
        store.registerEditor(first); store.registerEditor(second)
        first.set("OriginalField", "2"); second.set("OriginalField", "3")
        first.discardEdits()
        #expect(first.fields["OriginalField"] == "1")
        #expect(!first.modified)
        #expect(second.fields["OriginalField"] == "3")
        #expect(second.modified)
        #expect(store.hasUnsavedChanges)
    }
    @Test @MainActor
    func saveAllIncludesRegisteredModelDrafts() async throws {
        let provider = DeferredModelProvider()
        let session = ModelEditorSession(provider: provider)
        let store = WorkspaceStore(modelProvider: provider)
        let asset = ProjectAsset(url: URL(fileURLWithPath: "/task-fixture/model.h5"), section: .plans)
        await session.load(asset, kind: .plan); store.registerEditor(session)
        session.set("OriginalField", "2")
        #expect(store.hasUnsavedChanges)
        let saving = Task { await store.saveAll() }
        await provider.waitForSaveStart()
        #expect(store.isSavingAll)
        #expect(session.isSaving)
        #expect(provider.capturedEdits.first?.fields == ["OriginalField": "2"])
        provider.finish()
        #expect(await saving.value)
        #expect(!store.hasUnsavedChanges)
        #expect(!store.isSavingAll)
    }

    @Test @MainActor
    func failedSaveRetainsDraftAndPreventsContinue() async throws {
        let provider = DeferredModelProvider()
        let session = ModelEditorSession(provider: provider)
        let store = WorkspaceStore(modelProvider: provider)
        let asset = ProjectAsset(url: URL(fileURLWithPath: "/task-fixture/model.h5"), section: .plans)
        await session.load(asset, kind: .plan); store.registerEditor(session)
        session.set("OriginalField", "unsaved Chinese draft: 中文草稿")
        let saving = Task { await store.saveAll() }
        await provider.waitForSaveStart()
        provider.finish(CocoaError(.fileWriteNoPermission))
        #expect(await saving.value == false)
        #expect(session.modified)
        #expect(session.fields["OriginalField"] == "unsaved Chinese draft: 中文草稿")
        #expect(store.hasUnsavedChanges)
        #expect(store.errorMessage != nil)
        #expect(!store.isSavingAll)
    }

    @Test @MainActor
    func laterEditsAreNotAcknowledgedByEarlierSave() async throws {
        let provider = DeferredModelProvider()
        let session = ModelEditorSession(provider: provider)
        let asset = ProjectAsset(url: URL(fileURLWithPath: "/task-fixture/model.h5"), section: .plans)
        await session.load(asset, kind: .plan)
        session.set("OriginalField", "2")
        let saving = Task { await session.saveLoadedModel() }
        await provider.waitForSaveStart()
        session.set("OriginalField", "3")
        provider.finish()
        #expect(await saving.value == false)
        #expect(provider.capturedEdits.first?.fields["OriginalField"] == "2")
        #expect(session.fields["OriginalField"] == "3")
        #expect(session.modified)
    }
}
