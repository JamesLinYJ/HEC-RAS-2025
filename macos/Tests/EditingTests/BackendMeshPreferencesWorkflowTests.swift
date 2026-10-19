import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

struct BackendMeshPreferencesWorkflowTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HECRAS_MESH_ACCEPTANCE_DIRECTORY"] != nil)) @MainActor
    func closingGeometrySavesVisualPreferencesWithoutSavingHDFProjectOrPendingViews() async throws {
        let fixture = try #require(ProcessInfo.processInfo.environment["HECRAS_MESH_ACCEPTANCE_DIRECTORY"])
        let executable = try #require(ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"])
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mesh-preferences-" + UUID().uuidString)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: fixture), to: folder)
        defer { try? FileManager.default.removeItem(at: folder) }
        let projectURL = folder.appendingPathComponent("Mesh editor.ras")
        let originalProject = try Data(contentsOf: projectURL)
        let services = SourceWorkflowFixtureServices(recoveryFolder: folder.appendingPathComponent("Recovery"))
        let provider = BackendModelProvider(client: BackendProcessClient(executableURL: URL(fileURLWithPath: executable)))
        let store = WorkspaceStore(system: services, modelProvider: provider)
        store.requestOpen(projectURL)
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while store.isOpeningProject && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(!store.isOpeningProject)
        let asset = try #require(store.assets.first { $0.section == .geometries })
        let originalGeometry = try Data(contentsOf: asset.url)
        let parent = store.primaryEditorSession(.geometry)
        store.openEditor(.geometry, assetID: asset.id)
        await parent.load(asset, kind: .geometry)
        await parent.ensureGeometryMeshLoaded()
        store.installMeshDiagnosticsPreferences(for: parent)
        let mesh = try #require(parent.geometryMesh)
        #expect(mesh.diagnosticsPreferencesScope?.assetID == asset.id)
        await mesh.setMaxFacesPerNodeEntry(9.5)
        #expect(mesh.diagnosticsPreferences.maxFacesPerNode == 10)
        #expect(mesh.hasUnsavedDiagnosticsPreferences && !parent.modified && parent.hasUnsavedEditorChanges)
        store.descriptionDraft = "Keep unsaved project description"
        store.activeMapState.currentExtent = .init(lowerLeft: .init(x: 0, y: 0), upperRight: .init(x: 10, y: 10))
        store.saveCurrentView()
        #expect(store.savedViews.count == 1)
        store.requestCloseTab(.editor(.geometry))
        #expect(store.showCloseTabConfirmation)
        #expect(await store.saveAndCloseTab())
        #expect(!mesh.hasUnsavedDiagnosticsPreferences && !parent.hasUnsavedEditorChanges)
        #expect(!store.openEditors.contains(.geometry))
        #expect(store.descriptionDraft == "Keep unsaved project description" && store.savedViews.count == 1)
        #expect(try Data(contentsOf: projectURL) == originalProject)
        #expect(try Data(contentsOf: asset.url) == originalGeometry)
        let saved = try VisualizationDocument(projectURL: projectURL)
        #expect(try saved.meshDiagnosticsSettings(mapIndex: 0, geometryName: asset.name).maxFacesPerNode == 10)
        #expect(saved.views.isEmpty)
    }
}
