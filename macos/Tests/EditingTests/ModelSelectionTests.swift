import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

@MainActor
private final class ModelSelectionProvider: ModelEditorProvider {
    let sourceField = "TerrainLayersEditor/SelectedInputWithMap"
    var canEdit = true
    var deferred = false
    var wrongSelection = false
    var saved: [EditorEdits] = []
    var selectionRequests = 0
    private var pending: [String: (CheckedContinuation<EditorSnapshot, any Error>, EditorSnapshot)] = [:]
    private var waiting: [String: CheckedContinuation<Void, Never>] = [:]
    static func size(_ scope: String) -> String { scope + "/ConceptualMeshControlPointEditor/ConstantSizeString" }
    static func expression(_ scope: String) -> String { scope + "/FunctionalTerrainInputProperties/Context_Expression" }
    func snapshot(source: String = "A", selectedRows: Set<String> = []) -> EditorSnapshot {
        var fields = [sourceField: source]
        let scopes = selectedRows.union(source.isEmpty ? [] : [source])
        for scope in scopes {
            fields[Self.size(scope)] = scope == "A" ? "25" : "125"
            fields[Self.expression(scope)] = scope == "A" ? "x + y" : "x - y"
        }
        let detailScope = selectedRows.count > 1 ? "mixed" : selectedRows.first
        if detailScope == "mixed" {
            fields[Self.size("mixed")] = "50"
            fields["mixed/ConceptualMeshControlPointEditor/IsMixed"] = "true"
        }
        return EditorSnapshot(fields: fields,
            rows: ["Regions": [
                .init(id: "A", values: ["Size": "25"], fieldBindings: ["Size": Self.size("A")]),
                .init(id: "B", values: ["Size": "125"], fieldBindings: ["Size": Self.size("B")])]],
            samples: ["curve": [.init(id: "s", x: 0, y: 1, series: "source")]], canEdit: canEdit, images: ["A/images": []], editableSamplePages: ["curve"],
            sourceCollections: [sourceField: .init(items: [.init(id: "A", title: "A"), .init(id: "B", title: "B")], sourcePriorityReversed: true, canImport: false, canReorder: false, multipleImports: false,
                itemDetails: ["A": .init(scope: "A", schemaIDs: ["FunctionalTerrainInputProperties"]), "B": .init(scope: "B", schemaIDs: ["FunctionalTerrainInputProperties"])])],
            tablePresentations: ["Regions": .init(columns: [.init(id: "Size", title: "Size", sourceType: "double")],
                selection: .init(rowIDs: selectedRows, detail: detailScope.map { .init(scope: $0, schemaIDs: ["ConceptualMeshControlPointEditor"]) }))])
    }
    func load(_ asset: ProjectAsset, kind: ModelEditorKind) async throws -> EditorSnapshot { snapshot() }
    func save(_ asset: ProjectAsset, changes: EditorEdits) async throws { saved.append(changes) }
    func perform(_ asset: ProjectAsset, action: EditorAction) async throws -> EditorSnapshot {
        selectionRequests += 1
        let key: String, response: EditorSnapshot
        switch action {
        case .selectSource(_, let id): key = id ?? "overview"; response = snapshot(source: wrongSelection ? "A" : id ?? "")
        case .selectTableRows(_, let ids): key = ids.sorted().joined(separator: ","); response = snapshot(selectedRows: ids)
        default: throw ProjectFileError.invalid("Unexpected fixture action")
        }
        if !deferred { return response }
        return try await withCheckedThrowingContinuation { continuation in
            pending[key] = (continuation, response)
            waiting.removeValue(forKey: key)?.resume()
        }
    }
    func waitFor(_ key: String) async {
        if pending[key] != nil { return }
        await withCheckedContinuation { waiting[key] = $0 }
    }
    func finish(_ key: String) {
        if let (continuation, response) = pending.removeValue(forKey: key) { continuation.resume(returning: response) }
    }
}

struct ModelSelectionTests {
    private static var asset: ProjectAsset { .init(url: URL(fileURLWithPath: "/task-fixture/selection.h5"), section: .geometries) }

    @Test @MainActor
    func tableAndPropertyEditorsShareScopedDraftsWithoutSavingOnSelection() async throws {
        let provider = ModelSelectionProvider()
        let editor = ModelEditorSession(provider: provider)
        await editor.load(Self.asset, kind: .geometry)
        #expect(await editor.perform(.selectTableRows(table: "Regions", ids: ["A"])))
        editor.set(ModelSelectionProvider.size("A"), "25.75")
        #expect(await editor.perform(.selectTableRows(table: "Regions", ids: ["A"])))
        #expect(provider.selectionRequests == 1)
        #expect(editor.rows["Regions"]?[0].values["Size"] == "25.75")
        editor.setCell(table: "Regions", rowID: "B", column: "Size", value: "135.75")
        #expect(await editor.perform(.selectTableRows(table: "Regions", ids: ["B"])))
        #expect(editor.tablePresentations["Regions"]?.selection?.detail?.scope == "B")
        #expect(editor.fields[ModelSelectionProvider.size("A")] == "25.75")
        #expect(editor.fields[ModelSelectionProvider.size("B")] == "135.75")
        #expect(editor.rows["Regions"]?[1].values["Size"] == "135.75")
        #expect(provider.saved.isEmpty)
        editor.discardEdits()
        #expect(editor.fields[ModelSelectionProvider.size("A")] == "25")
        #expect(editor.fields[ModelSelectionProvider.size("B")] == "125")
        #expect(editor.tablePresentations["Regions"]?.selection?.rowIDs == ["B"])
        #expect(!editor.modified)
    }

    @Test @MainActor
    func sourceSelectionPreservesOtherObjectImagesSamplesAndPendingValues() async throws {
        let provider = ModelSelectionProvider()
        let session = ModelEditorSession(provider: provider)
        await session.load(Self.asset, kind: .terrain)
        session.set(ModelSelectionProvider.expression("A"), "x * 2 + y")
        #expect(await session.perform(.selectSource(field: provider.sourceField, id: "A")))
        #expect(provider.selectionRequests == 0)
        session.addImage("A/images", image: .init(id: "attachment", name: "draft.png", data: Data([1, 2, 3])))
        session.setSample(page: "curve", id: "s", y: 25.75)
        #expect(await session.perform(.selectSource(field: provider.sourceField, id: "B")))
        session.set(ModelSelectionProvider.expression("B"), "x * 3 - y")
        #expect(await session.perform(.selectSource(field: provider.sourceField, id: nil)))
        #expect(session.fields[ModelSelectionProvider.expression("A")] == "x * 2 + y")
        #expect(session.images["A/images"]?.first?.id == "attachment")
        #expect(session.samples["curve"]?.first?.y == 25.75)
        #expect(provider.saved.isEmpty)
        #expect(await session.saveLoadedModel())
        let saved = try #require(provider.saved.last)
        #expect(saved.fields[ModelSelectionProvider.expression("B")] == "x * 3 - y")
        #expect(saved.fields[provider.sourceField] == nil)
        #expect(saved.images["A/images"]?.first?.id == "attachment")
        #expect(saved.samples["curve"]?.first?.y == 25.75)
    }

    @Test @MainActor
    func multiSelectionKeepsMixedStateClearedAndSavesOnlyActualBindings() async throws {
        let provider = ModelSelectionProvider()
        let session = ModelEditorSession(provider: provider)
        await session.load(Self.asset, kind: .geometry)
        #expect(await session.perform(.selectTableRows(table: "Regions", ids: ["A", "B"])))
        let mixedFlag = "mixed/ConceptualMeshControlPointEditor/IsMixed"
        session.set(ModelSelectionProvider.size("mixed"), "75")
        session.clearMixedFlag(mixedFlag)
        #expect(await session.perform(.selectTableRows(table: "Regions", ids: ["A"])))
        #expect(await session.perform(.selectTableRows(table: "Regions", ids: ["A", "B"])))
        #expect(session.fields[ModelSelectionProvider.size("mixed")] == "75")
        #expect(session.fields[mixedFlag] == "false")
        #expect(await session.saveLoadedModel())
        #expect(provider.saved.last?.fields.count == 1)
        #expect(provider.saved.last?.fields[mixedFlag] == nil)
    }

    @Test @MainActor
    func lateSelectionAndPreviousModelRepliesCannotReplaceTheCurrentDetail() async throws {
        let provider = ModelSelectionProvider()
        let session = ModelEditorSession(provider: provider)
        await session.load(Self.asset, kind: .terrain)
        provider.deferred = true
        let older = Task { await session.perform(.selectSource(field: provider.sourceField, id: "B")) }
        await provider.waitFor("B")
        let newer = Task { await session.perform(.selectSource(field: provider.sourceField, id: "A")) }
        await provider.waitFor("A")
        provider.finish("A"); #expect(await newer.value)
        provider.finish("B"); #expect(!(await older.value))
        #expect(session.fields[provider.sourceField] == "A")
        #expect(!session.loadingSelection)
        let previousModel = Task { await session.perform(.selectSource(field: provider.sourceField, id: "B")) }
        await provider.waitFor("B")
        await session.load(.init(url: URL(fileURLWithPath: "/task-fixture/other.h5"), section: .terrains), kind: .terrain)
        provider.finish("B"); #expect(!(await previousModel.value))
        #expect(session.fields[provider.sourceField] == "A")
        #expect(provider.saved.isEmpty)
    }

    @Test @MainActor
    func unreadableSelectionRestoresThePreviousObjectAndReadonlyModelsCanNavigate() async throws {
        let provider = ModelSelectionProvider()
        let editor = ModelEditorSession(provider: provider)
        await editor.load(Self.asset, kind: .terrain)
        editor.set(ModelSelectionProvider.expression("A"), "retained draft")
        provider.wrongSelection = true
        #expect(!(await editor.perform(.selectSource(field: provider.sourceField, id: "B"))))
        #expect(editor.fields[provider.sourceField] == "A")
        #expect(editor.fields[ModelSelectionProvider.expression("A")] == "retained draft")
        #expect(editor.error != nil)
        #expect(provider.saved.isEmpty)
        provider.wrongSelection = false; provider.canEdit = false
        await editor.load(Self.asset, kind: .terrain)
        #expect(await editor.perform(.selectSource(field: provider.sourceField, id: "B")))
        #expect(!editor.canEdit && !editor.modified)
    }

    @Test @MainActor
    func functionalExtentEditsTheSelectedInputAndRejectsInvalidMapBounds() {
        let session = ModelEditorSession(); session.startDraft()
        let invalid = ViewportRequest(lowerLeft: .init(x: .nan, y: 0), upperRight: .init(x: 1, y: 1))
        #expect(!session.useMapExtent(invalid, terrainInputScope: "input-A"))
        #expect(!session.modified)
        let valid = ViewportRequest(lowerLeft: .init(x: -20, y: 10), upperRight: .init(x: 30, y: 40))
        #expect(session.useMapExtent(valid, terrainInputScope: "input-A"))
        #expect(session.fields["input-A/FunctionalTerrainInputProperties/Context_MinX"] == "-20.0")
        #expect(session.fields["input-A/FunctionalTerrainInputProperties/Context_MaxY"] == "40.0")
        #expect(session.fields.keys.allSatisfy { $0.hasPrefix("input-A/") })
    }
}
