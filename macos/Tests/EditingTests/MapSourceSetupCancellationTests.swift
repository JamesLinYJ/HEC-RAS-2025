import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

struct MapSourceSetupCancellationTests {
    @Test @MainActor
    func cancelledTreeSetupRetainsInstalledVectorsAndAllowsTheNextSetup() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("map-setup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let projectURL = folder.appendingPathComponent("Review.ras")
        try ProjectDocument(name: "Review", units: "SI").save(to: projectURL)
        try Data("<Ras><Maps><Map Name=\"Review\" Type=\"Project\"><Tree><Nodes/></Tree></Map></Maps></Ras>".utf8)
            .write(to: projectURL.deletingPathExtension().appendingPathExtension("vis"))
        let backendPath = try #require(ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"])
        let client = BackendProcessClient(executableURL: URL(fileURLWithPath: backendPath))
        let store = WorkspaceStore(system: MapSetupServices(), modelProvider: BackendModelProvider(client: client))
        store.requestOpen(projectURL)
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while store.isOpeningProject && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(store.document?.url == projectURL)
        // Use the production provider's invalidated-context cancellation path.
        // It must return before invoking its child process.
        store.layerTreeProvider = BackendMapTreeProvider(projectXML: { nil }, mapDocuments: { [] },
            isContextCurrent: { _ in false }, visualizationRevision: { nil })
        let state = store.mapState(for: MapState.projectMapID)
        let binding = MapVectorInstanceBinding(id: "existing-node", sourcePath: folder.appendingPathComponent("line.geojson").path,
            name: "Existing line", kind: .line, isVisible: true)
        state.sourceVectorBindings = [binding]
        state.sourceVectorPaths = [binding.sourcePath]
        await store.configureMapResultSources(state.id)
        #expect(state.resultSources.snapshot != nil,
            "The real source load must finish before the intentional tree-context cancellation is tested.")
        #expect(state.resultSources.errorMessage == nil)
        #expect(store.errorMessage == nil)
        #expect(state.sourceVectorBindings == [binding])
        #expect(state.sourceVectorPaths == [binding.sourcePath])
        #expect(state.resultSourceIdentity == nil)
        let previousAttempt = state.resultSourceSetupGeneration
        await store.configureMapResultSources(state.id)
        #expect(state.resultSourceSetupGeneration > previousAttempt)
        #expect(state.sourceVectorBindings == [binding])
        #expect(store.errorMessage == nil)
    }
}

@MainActor private final class MapSetupServices: WorkspaceSystemServices {
    func chooseProject() -> URL? { nil }
    func chooseProjectDestination(name: String) -> URL? { nil }
    func chooseFolder(title: String) -> URL? { nil }
    func chooseVectorLayer() -> URL? { nil }
    func chooseConnectionFile() -> URL? { nil }
    func chooseInputFiles() -> [URL] { [] }
    func chooseImageFiles() -> [URL] { [] }
    func chooseProjectionFile() -> URL? { nil }
    func reveal(_ url: URL) {}
    func copy(_ text: String) {}
    func openWebsite(_ url: URL) {}
}
