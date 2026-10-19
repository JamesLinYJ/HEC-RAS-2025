import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

@MainActor
private final class PatchDraftProvider: ModelEditorProvider {
    static let scope = "region-one"
    static let target = "arc-one/ConceptualMeshArcEditor/ViewModel_ConstantSizeString"
    static let description = "GeometryCatalogSummary/Context_Description"
    static let dimension = PatchDimensionPresentation(id: "north-south", title: "North–South", scope: scope + "/north-south", canApply: true, canChangeMode: true, canResize: true)
    var calls: [PatchEditRequest] = []
    var saved: [EditorEdits] = []
    var replyOutsideScope = false
    var deferred = false
    var mixed = false
    var duplicateDimensions = false
    private var completion: CheckedContinuation<PatchEditResult, Never>?
    private var waiter: CheckedContinuation<Void, Never>?
    func load(_ asset: ProjectAsset, kind: ModelEditorKind) async throws -> EditorSnapshot {
        let d = Self.dimension
        let patch = PatchEditorPresentation(state: mixed ? .mixedTypes : .ready, kind: .quad, dimensions: duplicateDimensions ? [d, d] : [d], canResizeAll: true,
            editableFieldIDs: [Self.target], displayFieldIDs: [d.valueFieldID, d.modeFieldID, d.mismatchFieldID])
        return .init(fields: [Self.description: "baseline", Self.target: "5", d.valueFieldID: "5", d.modeFieldID: "Constant", d.mismatchFieldID: "false"], rows: ["Regions": [.init(id: "region-one", values: [:])]], samples: [:], canEdit: true, images: [:],
            tablePresentations: ["Regions": .init(columns: [], selection: .init(rowIDs: ["region-one"], detail: .init(scope: Self.scope, schemaIDs: ["ConceptualMeshControlPointEditor"], patch: patch)))])
    }
    func save(_ asset: ProjectAsset, changes: EditorEdits) async throws { saved.append(changes) }
    func perform(_ asset: ProjectAsset, action: EditorAction) async throws -> EditorSnapshot {
        var snapshot = try await load(asset, kind: .geometry)
        if case .selectTableRows(let table, let ids) = action, table == "Regions" {
            let detail = snapshot.tablePresentations[table]?.selection?.detail
            snapshot.tablePresentations[table]?.selection = .init(rowIDs: ids, detail: ids.isEmpty ? nil : detail)
        }
        return snapshot
    }
    func editPatch(_ asset: ProjectAsset, request: PatchEditRequest) async throws -> PatchEditResult {
        calls.append(request)
        if deferred { return await withCheckedContinuation { completion = $0; waiter?.resume(); waiter = nil } }
        return .init(changed: true, fields: [replyOutsideScope ? "different-object/value" : Self.target: "12.5"], displayFields: [Self.dimension.valueFieldID: "12.5"])
    }
    func waitUntilStarted() async { if completion == nil { await withCheckedContinuation { waiter = $0 } } }
    func finish() { completion?.resume(returning: .init(changed: true, fields: [Self.target: "99"])); completion = nil }
}

struct MeshEditingTests {
    private let asset = ProjectAsset(url: URL(fileURLWithPath: "/fixture/geometry.h5"), section: .geometries)
    @Test @MainActor func applyingPatchEditsRetainsDraftAndSavesOnlyRealSourceFields() async throws {
        let provider = PatchDraftProvider()
        let session = ModelEditorSession(provider: provider)
        await session.load(asset, kind: .geometry)
        session.set(PatchDraftProvider.description, "existing draft")
        #expect(await session.editPatch(scope: PatchDraftProvider.scope, operation: .applyDimension(id: PatchDraftProvider.dimension.id, value: "12.5")))
        #expect(provider.saved.isEmpty && session.modified)
        #expect(session.fields[PatchDraftProvider.target] == "12.5")
        #expect(session.fields[PatchDraftProvider.dimension.valueFieldID] == "12.5")
        #expect(provider.calls.first?.edits.fields[PatchDraftProvider.description] == "existing draft")
        #expect(await session.perform(.selectTableRows(table: "Regions", ids: [])))
        #expect(await session.perform(.selectTableRows(table: "Regions", ids: ["region-one"])))
        #expect(session.fields[PatchDraftProvider.dimension.valueFieldID] == "12.5" && provider.saved.isEmpty)
        #expect(await session.saveLoadedModel())
        let saved = try #require(provider.saved.first)
        #expect(saved.fields == [PatchDraftProvider.target: "12.5", PatchDraftProvider.description: "existing draft"])
        session.set(PatchDraftProvider.target, "20"); session.discardEdits()
        #expect(session.fields[PatchDraftProvider.target] == "12.5")
    }
    @Test @MainActor func sourceScopeMismatchCannotMutateAnotherObjectsDraft() async {
        let provider = PatchDraftProvider()
        let editor = ModelEditorSession(provider: provider)
        provider.replyOutsideScope = true
        await editor.load(asset, kind: .geometry)
        #expect(!(await editor.editPatch(scope: PatchDraftProvider.scope, operation: .applyDimension(id: PatchDraftProvider.dimension.id, value: "12.5"))))
        #expect(editor.fields[PatchDraftProvider.target] == "5" && editor.fields["different-object/value"] == nil)
        #expect(!editor.modified && editor.error != nil && provider.saved.isEmpty)
    }
    @Test @MainActor func latePatchReplyCannotReplaceAnotherModel() async {
        let provider = PatchDraftProvider()
        let session = ModelEditorSession(provider: provider)
        provider.deferred = true
        await session.load(asset, kind: .geometry)
        let applying = Task { await session.editPatch(scope: PatchDraftProvider.scope, operation: .applyDimension(id: PatchDraftProvider.dimension.id, value: "12.5")) }
        await provider.waitUntilStarted()
        let next = ProjectAsset(url: URL(fileURLWithPath: "/fixture/other.h5"), section: .geometries)
        await session.load(next, kind: .geometry)
        provider.finish()
        #expect(!(await applying.value))
        #expect(session.modelAssetID == next.id && session.fields[PatchDraftProvider.target] == "5" && !session.modified)
    }
    @Test @MainActor func mixedPatchTypesCannotSendEditsAndDuplicateDimensionScopesFailBeforeRendering() async {
        let provider = PatchDraftProvider(), editor = ModelEditorSession(provider: provider)
        provider.mixed = true; await editor.load(asset, kind: .geometry)
        #expect(!(await editor.editPatch(scope: PatchDraftProvider.scope, operation: .resizeAll(2))))
        #expect(provider.calls.isEmpty && !editor.modified)
        provider.mixed = false; provider.duplicateDimensions = true
        await editor.load(asset, kind: .geometry)
        #expect(!editor.loaded && editor.error != nil)
    }
    @Test @MainActor func meshErrorsUseActualCellBoundsAndRejectInvalidSourceLists() async throws {
        let issue = MeshNodeDegreeIssue(id: "mesh-1/node-10", nodeIndex: 10, faceCount: 8,
            cellsExtent: .init(lowerLeft: .init(x: 10, y: 20), upperRight: .init(x: 30, y: 40)), nodePoint: .init(x: 21, y: 31))
        let state = MapState()
        state.viewport = issue.viewport
        #expect(state.viewport?.lowerLeft.x == 0 && state.viewport?.upperRight.x == 40)
        #expect(state.viewport?.lowerLeft.y == 10 && state.viewport?.upperRight.y == 50)
        let summary = FlowAreaPresentation(cellCount: 20, degreeIssues: [issue, issue])
        #expect(throws: ProjectFileError.self) { try summary.validate() }
        try FlowAreaPresentation(cellCount: 20, degreeIssues: []).validate()
    }
}
