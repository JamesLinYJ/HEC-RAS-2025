import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

struct BackendMapDocumentWorkflowTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"] != nil)) @MainActor
    func sourceMapCreationRenameAndFoldersPersistWithoutPublishingProjectOrViewDrafts() async throws {
        let executable = try #require(ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"])
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("map-document-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let projectURL = folder.appendingPathComponent("Maps.ras")
        let visualURL = folder.appendingPathComponent("Maps.vis")
        let source = try ProjectDocument(name: "Maps", units: "SI")
        try source.save(to: projectURL)
        let originalProject = try Data(contentsOf: projectURL)
        let provider = BackendModelProvider(client: BackendProcessClient(executableURL: URL(fileURLWithPath: executable)))
        let store = WorkspaceStore(system: MapDocumentFixtureServices(), modelProvider: provider)
        store.requestOpen(projectURL)
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while store.isOpeningProject && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(!store.isOpeningProject)
        store.descriptionDraft = "Keep project draft 中文"
        store.activeMapState.currentExtent = .init(lowerLeft: .init(x: 1, y: 2), upperRight: .init(x: 10, y: 20))
        store.saveCurrentView()
        #expect(store.savedViews.count == 1)
        #expect(!FileManager.default.fileExists(atPath: visualURL.path))
        #expect(await store.createMapDocument(kind: .project))
        #expect(await store.createMapDocument(kind: .buildable))
        let map = try #require(store.mapDocuments.first { $0.kind == .buildable })
        #expect(await store.renameMapDocument(map.id, name: "Renamed 中文"))
        #expect(store.mapDocuments.first?.id == map.id)
        #expect(store.mapName(map.id) == "Renamed 中文")
        let treeProvider = try #require(store.layerTreeProvider)
        let tree = try await treeProvider.load(store.layerTreeContext)
        let root = try #require(tree.roots.first { $0.canCreateFolder })
        _ = try await treeProvider.perform(.newFolder(parentID: root.id, name: "Nested 中文"), context: store.layerTreeContext)
        let afterFolder = try await treeProvider.load(store.layerTreeContext)
        let createdFolder = try #require(afterFolder.roots.lazy.compactMap { findFolder($0, named: "Nested 中文") }.first)
        _ = try await treeProvider.perform(.rename(id: createdFolder.id, name: "Renamed folder"), context: store.layerTreeContext)
        let reopened = try VisualizationDocument(projectURL: projectURL)
        #expect(reopened.maps.count == 2)
        #expect(reopened.maps[1].name == "Renamed 中文" && reopened.maps[1].type == "Buildable")
        #expect(reopened.views.isEmpty)
        #expect(store.savedViews.count == 1 && store.descriptionDraft == "Keep project draft 中文")
        #expect(try Data(contentsOf: projectURL) == originalProject)
        let savedXML = try String(contentsOf: visualURL, encoding: .utf8)
        #expect(savedXML.contains("Renamed folder"))
        #expect(store.save())
        #expect(try VisualizationDocument(projectURL: projectURL).views.count == 1)
        #expect(try ProjectDocument(contentsOf: projectURL).description == "Keep project draft 中文")
        let external = Data("<Ras><Maps><Map Name='External' Type='Project'/></Maps><Unknown Keep='yes'/></Ras>".utf8)
        try external.write(to: visualURL)
        #expect(!(await store.renameMapDocument(map.id, name: "Must not overwrite")))
        #expect(try Data(contentsOf: visualURL) == external)
        #expect(store.mapName(map.id) == "Renamed 中文")
        #expect(!store.isRunningProjectTool)
    }

    private func findFolder(_ node: LayerTreeNode, named name: String) -> LayerTreeNode? {
        if node.name == name && node.canRename { return node }
        return node.children?.lazy.compactMap { findFolder($0, named: name) }.first
    }
}

@MainActor
private final class MapDocumentFixtureServices: WorkspaceSystemServices {
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
