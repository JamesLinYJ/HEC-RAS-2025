import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

/// These tests exercise the Store handoff boundary, rather than pretending
/// that choosing a model proves its importer or the native sheet works.
struct EditorToolHandoffTests {
    @Test @MainActor
    func topologyShortcutsKeepTheLoadedGeometryDraftAndRequireExactFeatureScope() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = fixture.store
        let geometry = try #require(store.assets.first { $0.section == .geometries })
        let terrain = try #require(store.assets.first { $0.section == .terrains })
        let primary = store.primaryEditorSession(.geometry)
        await primary.load(geometry, kind: .geometry)
        primary.set(HandoffModelProvider.field, "unsaved geometry value")
        for action in [ToolKind.topology, .topologyRecipe, .arcPoints, .tagFilter] {
            let featureKind: String? = action == .arcPoints ? "arc" : nil
            #expect(!store.requestEditorToolPresentation(action: action, assetID: terrain.id,
                featureKind: featureKind))
            #expect(!store.requestEditorToolPresentation(action: action, assetID: geometry.id,
                spatialLayerID: "unrelated-map-layer", featureKind: featureKind))
            #expect(!store.requestEditorToolPresentation(action: action, assetID: geometry.id,
                featureKind: "node"))
            #expect(store.requestEditorToolPresentation(action: action, assetID: geometry.id,
                featureKind: featureKind))
            let request = try #require(store.editorToolPresentationRequest)
            #expect(request.assetID == geometry.id && request.projectSessionID == store.projectSessionID)
            #expect(request.featureKind == featureKind)
            #expect(store.activeTab == .editor(.geometry))
            #expect(store.primaryEditorSession(.geometry) === primary)
        }
        #expect(primary.modified && primary.fields[HandoffModelProvider.field] == "unsaved geometry value")
        #expect(fixture.provider.loads == [geometry.id] && fixture.provider.saves == 0)
        #expect(try Data(contentsOf: geometry.url) == fixture.modelBytes)
    }

    @Test @MainActor
    func wrongKindNeverRedirectsACommandAndExactTargetsPreserveThePrimaryDraft() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = fixture.store
        let geometry = try #require(store.assets.first { $0.section == .geometries })
        let terrains = store.assets.filter { $0.section == .terrains }.sorted { $0.id < $1.id }
        #expect(terrains.count == 2)
        let first = try #require(terrains.first)
        let second = try #require(terrains.last)
        store.select(geometry)
        let primary = store.primaryEditorSession(.terrain)
        await primary.load(first, kind: .terrain)
        primary.set(HandoffModelProvider.field, "unsaved terrain value")
        #expect(primary.modified)

        #expect(!store.requestEditorToolPresentation(action: .terrainImport, assetID: geometry.id))
        #expect(store.editorToolPresentationRequest == nil)
        #expect(store.requestEditorToolPresentation(action: .terrainImport, assetID: second.id))
        let request = try #require(store.editorToolPresentationRequest)
        #expect(request.assetID == second.id && request.projectSessionID == store.projectSessionID)
        #expect(store.editorAssetRequests[.terrain] == second.id)
        #expect(store.activeTab == .editor(.terrain))
        #expect(store.primaryEditorSession(.terrain) === primary)
        // Switching/loading belongs to the editor's Save/Discard/Cancel route.
        #expect(primary.modelAssetID == first.id)
        #expect(primary.fields[HandoffModelProvider.field] == "unsaved terrain value")
        #expect(primary.modified && fixture.provider.saves == 0)
        #expect(fixture.provider.loads == [first.id])
        #expect(try Data(contentsOf: first.url) == fixture.modelBytes)
        #expect(try Data(contentsOf: second.url) == fixture.modelBytes)
    }

    @Test @MainActor
    func lateCancellationCannotConsumeANewerRequestAndProjectResetClearsTheHandoff() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = fixture.store
        let geometry = try #require(store.assets.first { $0.section == .geometries })
        let boundary = try #require(store.assets.first { $0.section == .boundaryConditions })
        #expect(!store.requestEditorToolPresentation(action: .tagCreate, assetID: geometry.id,
            featureKind: "node"))
        #expect(!store.requestEditorToolPresentation(action: .tagEdit, assetID: boundary.id,
            featureKind: "arc"))
        #expect(store.requestEditorToolPresentation(action: .tagCreate, assetID: geometry.id,
            featureKind: "arc"))
        let oldRequest = try #require(store.editorToolPresentationRequest)
        #expect(store.requestEditorToolPresentation(action: .griddedImport, assetID: boundary.id))
        let currentRequest = try #require(store.editorToolPresentationRequest)
        #expect(currentRequest.spatialLayerID == nil)
        store.consumeEditorToolPresentationRequest(oldRequest.id)
        #expect(store.editorToolPresentationRequest == currentRequest)
        store.consumeEditorToolPresentationRequest(currentRequest.id)
        #expect(store.editorToolPresentationRequest == nil)
        #expect(store.requestEditorToolPresentation(action: .tagEdit, assetID: geometry.id,
            featureKind: "region"))
        store.requestClose()
        #expect(store.document == nil)
        #expect(store.editorToolPresentationRequest == nil)
        #expect(store.projectSessionID != currentRequest.projectSessionID)
        #expect(fixture.provider.loads.isEmpty && fixture.provider.saves == 0)
    }

    @MainActor
    private func makeFixture() async throws -> (root: URL, store: WorkspaceStore,
        provider: HandoffModelProvider, modelBytes: Data) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("editor-tool-handoff-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let bytes = Data("routing identity only; no HDF parser is involved".utf8)
        for path in ["Geometries/同名.h5", "Terrains/一.h5", "Terrains/二.h5", "Boundary Conditions/同名.h5"] {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: url)
        }
        let projectURL = root.appendingPathComponent("Handoff.ras")
        try Data("<Project><Description>Handoff ownership</Description></Project>".utf8).write(to: projectURL)
        let provider = HandoffModelProvider()
        let store = WorkspaceStore(system: SourceWorkflowFixtureServices(
            recoveryFolder: root.appendingPathComponent("Trash")), modelProvider: provider)
        store.requestOpen(projectURL)
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while store.isOpeningProject && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(store.document?.url == projectURL && !store.isOpeningProject)
        return (root, store, provider, bytes)
    }
}

@MainActor
private final class HandoffModelProvider: ModelEditorProvider {
    nonisolated static let field = "TerrainProperties/Description"
    private(set) var loads: [String] = []
    private(set) var saves = 0
    func load(_ asset: ProjectAsset, kind: ModelEditorKind) async throws -> EditorSnapshot {
        loads.append(asset.id)
        return .init(fields: [Self.field: "baseline"], rows: [:], samples: [:],
            canEdit: true, images: [:], sourceRevision: "handoff-model-revision")
    }
    func save(_ asset: ProjectAsset, changes: EditorEdits) async throws { saves += 1 }
    func perform(_ asset: ProjectAsset, action: EditorAction) async throws -> EditorSnapshot {
        throw CocoaError(.featureUnsupported)
    }
}
