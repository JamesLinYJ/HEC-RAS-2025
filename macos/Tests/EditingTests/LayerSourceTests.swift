import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

@MainActor
private final class LayerSourceFixture: ModelEditorProvider {
    var actions: [EditorAction] = []
    let field = "TerrainLayersEditor/SelectedInputWithMap"
    func load(_ asset: ProjectAsset, kind: ModelEditorKind) async throws -> EditorSnapshot {
        EditorSnapshot(fields: [field: "source-A"], rows: [:], samples: [:], canEdit: true, images: [:],
            sourceCollections: [field: SourceCollection(items: [EditorChoice(id: "source-A", title: "A"), EditorChoice(id: "source-B", title: "B")], sourcePriorityReversed: false, canImport: true, canReorder: true, multipleImports: true)])
    }
    func save(_ asset: ProjectAsset, changes: EditorEdits) async throws {}
    func perform(_ asset: ProjectAsset, action: EditorAction) async throws -> EditorSnapshot {
        actions.append(action)
        var snapshot = try await load(asset, kind: .terrain)
        if case .selectSource(_, let id) = action { snapshot = EditorSnapshot(fields: [field: id ?? ""], rows: [:], samples: [:], canEdit: true, images: [:], sourceCollections: snapshot.sourceCollections) }
        return snapshot
    }
}

struct LayerSourceTests {
    @Test @MainActor
    func sourceSelectionAndOverviewUseOriginalScopedAction() async throws {
        let provider = LayerSourceFixture()
        let editor = ModelEditorSession(provider: provider)
        let asset = ProjectAsset(url: URL(fileURLWithPath: "/task-fixture/terrain.h5"), section: .terrains)
        await editor.load(asset, kind: .terrain)
        await editor.perform(.selectSource(field: provider.field, id: "source-B"))
        #expect(editor.fields[provider.field] == "source-B")
        await editor.perform(.selectSource(field: provider.field, id: nil))
        #expect(editor.fields[provider.field] == "")
        #expect(!editor.modified)
        #expect(provider.actions.count == 2)
    }
}
