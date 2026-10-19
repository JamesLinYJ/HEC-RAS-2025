import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

struct BackendFirstMapImportTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"] != nil))
    @MainActor
    func firstImportCreatesRealProjectMapAndKeepsProjectAndViewDraftsUntilSave() async throws {
        let executable = try #require(ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"])
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("first-map-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let projectDirectory = root.appendingPathComponent("Project", isDirectory: true)
        let externalDirectory = root.appendingPathComponent("External Data", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: externalDirectory, withIntermediateDirectories: true)
        let vectorURL = externalDirectory.appendingPathComponent("Channel.geojson")
        try validLineGeoJSON.write(to: vectorURL)

        let store = makeStore(executable: executable, recoveryDirectory: root.appendingPathComponent("Recovery"))
        store.createProject(name: "First Import", units: "SI", description: "Saved description",
            directory: projectDirectory, projectionType: "Local", projectionValue: "")
        let projectURL = projectDirectory.appendingPathComponent("First Import", isDirectory: true)
            .appendingPathComponent("First Import.ras")
        #expect(store.document?.url == projectURL)
        let originalProjectBytes = try Data(contentsOf: projectURL)
        let visualizationURL = projectURL.deletingPathExtension().appendingPathExtension("vis")
        #expect(!FileManager.default.fileExists(atPath: visualizationURL.path))

        store.descriptionDraft = "Unpublished description draft"
        store.activeMapState.currentExtent = .init(
            lowerLeft: .init(x: 1, y: 2), upperRight: .init(x: 10, y: 20))
        store.saveCurrentView()
        #expect(store.savedViews.count == 1)
        #expect(store.document?.connections.isEmpty == true)
        #expect(!FileManager.default.fileExists(atPath: visualizationURL.path))

        #expect(await store.connectVectorSource(vectorURL, for: MapState.projectMapID))
        #expect(store.document?.connections.count == 1)
        #expect(store.document?.description == "Saved description")
        #expect(store.descriptionDraft == "Unpublished description draft")
        #expect(store.savedViews.count == 1)
        #expect(try Data(contentsOf: projectURL) == originalProjectBytes)

        let importedConnection = try #require(store.document?.connections.first)
        #expect(SourceFilePaths.canonical(try importedConnection.resolve(
            relativeTo: try #require(store.document?.directory), mappings: [])) == SourceFilePaths.canonical(vectorURL))

        try await waitForVectorLayer(vectorURL, in: store)
        let nodes = try await store.sourceMapLayerNodes(MapState.projectMapID)
        let sourceNode = try #require(nodes.first {
            $0.sourceLocator?.nodeType == "MapLayer" && $0.sourceLocator?.mapType == "PolylinesVector"
                && $0.assetID.map { SourceFilePaths.canonical(URL(fileURLWithPath: $0)) } == SourceFilePaths.canonical(vectorURL)
        })
        let state = store.mapState(for: MapState.projectMapID)
        await store.refreshSourceMapVectors(nodes, mapID: MapState.projectMapID)
        let binding = try #require(state.sourceVectorBindings?.first {
            $0.sourcePath == SourceFilePaths.canonical(vectorURL)
        })
        #expect(binding.name == sourceNode.name)
        #expect(binding.kind == .line)
        #expect(binding.isVisible)
        let renderedSource = try #require(state.vectors(store.mapLayers).first { $0.id == binding.id })
        #expect(renderedSource.features.count == 1)
        #expect(renderedSource.features.first?.kind == .line)
        #expect(renderedSource.features.first?.sourceFeatureIndex == 0)
        let importedVisualization = try VisualizationDocument(projectURL: projectURL)
        #expect(importedVisualization.maps.count == 1)
        #expect(importedVisualization.maps.first?.type == "Project")
        #expect(importedVisualization.views.isEmpty)

        let firstVisualizationBytes = try Data(contentsOf: visualizationURL)
        let firstProjectXML = try #require(store.document?.editorXML)
        let firstConnectionCount = try #require(store.document?.connections.count)
        #expect(!(await store.connectVectorSource(vectorURL, for: MapState.projectMapID)))
        #expect(store.document?.editorXML == firstProjectXML)
        #expect(store.document?.connections.count == firstConnectionCount)
        #expect(store.descriptionDraft == "Unpublished description draft")
        #expect(store.savedViews.count == 1)
        #expect(try Data(contentsOf: visualizationURL) == firstVisualizationBytes)
        #expect(try Data(contentsOf: projectURL) == originalProjectBytes)

        #expect(store.save())
        let savedProject = try ProjectDocument(contentsOf: projectURL)
        #expect(savedProject.description == "Unpublished description draft")
        #expect(savedProject.connections.count == 1)
        #expect(SourceFilePaths.canonical(try #require(savedProject.connections.first).resolve(
            relativeTo: try #require(savedProject.directory), mappings: [])) == SourceFilePaths.canonical(vectorURL))
        let savedVisualization = try VisualizationDocument(projectURL: projectURL)
        #expect(savedVisualization.maps.count == 1)
        #expect(savedVisualization.maps.first?.type == "Project")
        #expect(savedVisualization.views.count == 1)

        store.requestClose()
        if store.showDiscardConfirmation { store.discardAndContinue() }
        try #require(store.document == nil)

        let reopened = makeStore(executable: executable, recoveryDirectory: root.appendingPathComponent("Reopen Recovery"))
        reopened.requestOpen(projectURL)
        try await waitForProjectOpen(reopened)
        let reopenedConnection = try #require(reopened.document?.connections.first)
        #expect(reopened.document?.connections.count == 1)
        #expect(SourceFilePaths.canonical(try reopenedConnection.resolve(
            relativeTo: try #require(reopened.document?.directory), mappings: [])) == SourceFilePaths.canonical(vectorURL))
        #expect(reopened.savedViews.count == 1)
        let reopenedNodes = try await reopened.sourceMapLayerNodes(MapState.projectMapID)
        #expect(reopenedNodes.contains {
            $0.sourceLocator?.nodeType == "MapLayer" && $0.sourceLocator?.mapType == "PolylinesVector"
                && $0.assetID.map { SourceFilePaths.canonical(URL(fileURLWithPath: $0)) } == SourceFilePaths.canonical(vectorURL)
        })
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"] != nil))
    @MainActor
    func sourceRejectedEmptyCollectionDoesNotCreateVisualizationConnectionOrDraft() async throws {
        let executable = try #require(ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"])
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("empty-map-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let projectURL = root.appendingPathComponent("Empty.ras")
        let project = try ProjectDocument(name: "Empty", units: "SI")
        try project.save(to: projectURL)
        let originalProjectBytes = try Data(contentsOf: projectURL)
        let vectorURL = root.appendingPathComponent("Empty.geojson")
        try Data(#"{"type":"FeatureCollection","features":[]}"#.utf8).write(to: vectorURL)
        #expect(try MapVectorLayer(contentsOf: vectorURL).features.isEmpty)

        let store = makeStore(executable: executable, recoveryDirectory: root.appendingPathComponent("Recovery"))
        store.requestOpen(projectURL)
        try await waitForProjectOpen(store)
        let visualizationURL = projectURL.deletingPathExtension().appendingPathExtension("vis")
        #expect(!FileManager.default.fileExists(atPath: visualizationURL.path))
        #expect(!(await store.connectVectorSource(vectorURL, for: MapState.projectMapID)))
        #expect(store.document?.connections.isEmpty == true)
        #expect(!store.hasUnsavedChanges)
        #expect(try Data(contentsOf: projectURL) == originalProjectBytes)
        #expect(!FileManager.default.fileExists(atPath: visualizationURL.path))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"] != nil))
    @MainActor
    func firstMixedGeometryImportCreatesThreeRealBucketsWithoutPublishingDrafts() async throws {
        let executable = try #require(ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"])
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mixed-first-map-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let projectDirectory = root.appendingPathComponent("Project", isDirectory: true)
        let externalDirectory = root.appendingPathComponent("External", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: externalDirectory, withIntermediateDirectories: true)
        let vectorURL = externalDirectory.appendingPathComponent("Mixed.geojson")
        let sourceBytes = Data(#"{"type":"FeatureCollection","features":[{"type":"Feature","id":"point-1","properties":{"kind":"point"},"geometry":{"type":"Point","coordinates":[0,0]}},{"type":"Feature","id":"line-1","properties":{"kind":"line"},"geometry":{"type":"LineString","coordinates":[[1,1],[2,2]]}},{"type":"Feature","id":"polygon-1","properties":{"kind":"polygon"},"geometry":{"type":"Polygon","coordinates":[[[3,3],[5,3],[5,5],[3,5],[3,3]]]}}]}"#.utf8)
        try sourceBytes.write(to: vectorURL)

        let store = makeStore(executable: executable, recoveryDirectory: root.appendingPathComponent("Recovery"))
        store.createProject(name: "Mixed Import", units: "SI", description: "Base",
            directory: projectDirectory, projectionType: "Local", projectionValue: "")
        let projectURL = projectDirectory.appendingPathComponent("Mixed Import", isDirectory: true)
            .appendingPathComponent("Mixed Import.ras")
        let originalProjectBytes = try Data(contentsOf: projectURL)
        let visualizationURL = projectURL.deletingPathExtension().appendingPathExtension("vis")
        #expect(!FileManager.default.fileExists(atPath: visualizationURL.path))

        store.activeMapState.currentExtent = .init(
            lowerLeft: .init(x: 0, y: 0), upperRight: .init(x: 10, y: 10))
        store.saveCurrentView()
        #expect(store.savedViews.count == 1)
        #expect(await store.connectVectorSource(vectorURL, for: MapState.projectMapID))
        #expect(store.document?.connections.count == 1)
        #expect(try Data(contentsOf: projectURL) == originalProjectBytes)
        #expect(try Data(contentsOf: vectorURL) == sourceBytes)

        try await waitForVectorLayer(vectorURL, in: store)
        let nodes = try await store.sourceMapLayerNodes(MapState.projectMapID)
        let expectedMapTypes: Set<String> = ["PointsVector", "PolylinesVector", "PolygonsVector"]
        let vectorNodes = nodes.filter { $0.sourceLocator?.nodeType == "MapLayer" }
        #expect(Set(vectorNodes.compactMap { $0.sourceLocator?.mapType }) == expectedMapTypes)
        #expect(vectorNodes.count == 3)
        #expect(vectorNodes.allSatisfy { $0.assetID.map {
            SourceFilePaths.canonical(URL(fileURLWithPath: $0)) == SourceFilePaths.canonical(vectorURL)
        } == true })

        let state = store.mapState(for: MapState.projectMapID)
        await store.refreshSourceMapVectors(nodes, mapID: MapState.projectMapID)
        let bindings = try #require(state.sourceVectorBindings)
        #expect(bindings.count == 3)
        #expect(Set(bindings.map(\.kind)) == [.point, .line, .polygon])
        let expectedOrdinals: [MapFeature.Kind: Int] = [.point: 0, .line: 1, .polygon: 2]
        let instances = state.vectors(store.mapLayers)
        for binding in bindings {
            let instance = try #require(instances.first { $0.id == binding.id })
            #expect(instance.isSourceVisible)
            #expect(instance.features.count == 1)
            #expect(instance.features.first?.kind == binding.kind)
            #expect(instance.features.first?.sourceFeatureIndex == expectedOrdinals[binding.kind])
        }

        let visualization = try VisualizationDocument(projectURL: projectURL)
        #expect(visualization.maps.count == 1)
        #expect(visualization.maps.first?.type == "Project")
        #expect(visualization.views.isEmpty)
        #expect(store.savedViews.count == 1)
        #expect(try Data(contentsOf: projectURL) == originalProjectBytes)
        #expect(try Data(contentsOf: vectorURL) == sourceBytes)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"] != nil))
    @MainActor
    func staleVisualizationRejectsImportWithoutChangingLocalConnectionOrExternalBytes() async throws {
        let executable = try #require(ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"])
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("stale-first-map-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let projectURL = root.appendingPathComponent("Stale.ras")
        let project = try ProjectDocument(name: "Stale", units: "SI")
        try project.save(to: projectURL)
        let originalProjectBytes = try Data(contentsOf: projectURL)
        let vectorURL = root.appendingPathComponent("Channel.geojson")
        try validLineGeoJSON.write(to: vectorURL)

        let store = makeStore(executable: executable, recoveryDirectory: root.appendingPathComponent("Recovery"))
        store.requestOpen(projectURL)
        try await waitForProjectOpen(store)
        #expect(await store.createMapDocument(kind: .project))
        let visualizationURL = projectURL.deletingPathExtension().appendingPathExtension("vis")
        let localProjectXML = try #require(store.document?.editorXML)
        let persistedVisualizationBytes = try Data(contentsOf: visualizationURL)
        let externalVisualizationBytes = Data((String(decoding: persistedVisualizationBytes, as: UTF8.self)
            + "\n<!-- external revision -->\n").utf8)
        try externalVisualizationBytes.write(to: visualizationURL)

        #expect(!(await store.connectVectorSource(vectorURL, for: MapState.projectMapID)))
        #expect(store.document?.editorXML == localProjectXML)
        #expect(store.document?.connections.isEmpty == true)
        #expect(try Data(contentsOf: projectURL) == originalProjectBytes)
        #expect(try Data(contentsOf: visualizationURL) == externalVisualizationBytes)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"] != nil))
    @MainActor
    func staleProjectRevisionRejectsFirstImportWithoutPublishingConnectionOrVisualization() async throws {
        let executable = try #require(ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"])
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("stale-first-project-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let projectURL = root.appendingPathComponent("Stale Project.ras")
        let project = try ProjectDocument(name: "Stale Project", units: "SI")
        try project.save(to: projectURL)
        let vectorURL = root.appendingPathComponent("Channel.geojson")
        try validLineGeoJSON.write(to: vectorURL)
        let visualizationURL = projectURL.deletingPathExtension().appendingPathExtension("vis")

        let store = makeStore(executable: executable, recoveryDirectory: root.appendingPathComponent("Recovery"))
        store.requestOpen(projectURL)
        try await waitForProjectOpen(store)
        #expect(!FileManager.default.fileExists(atPath: visualizationURL.path))
        let localProjectXML = try #require(store.document?.editorXML)
        store.descriptionDraft = "Unpublished local description"

        let externalProject = try ProjectDocument(contentsOf: projectURL)
        externalProject.description = "External project revision"
        try externalProject.save()
        let externalProjectBytes = try Data(contentsOf: projectURL)
        #expect(try ProjectDocument(contentsOf: projectURL).description == "External project revision")

        #expect(!(await store.connectVectorSource(vectorURL, for: MapState.projectMapID)))
        #expect(store.document?.editorXML == localProjectXML)
        #expect(store.descriptionDraft == "Unpublished local description")
        #expect(store.document?.connections.isEmpty == true)
        #expect(!store.isModified)
        #expect(!FileManager.default.fileExists(atPath: visualizationURL.path))
        #expect(try Data(contentsOf: projectURL) == externalProjectBytes)
    }

    @MainActor
    private func makeStore(executable: String, recoveryDirectory: URL) -> WorkspaceStore {
        WorkspaceStore(system: FirstMapImportFixtureServices(recoveryFolder: recoveryDirectory),
            modelProvider: BackendModelProvider(client: BackendProcessClient(
                executableURL: URL(fileURLWithPath: executable))))
    }

    @MainActor
    private func waitForProjectOpen(_ store: WorkspaceStore) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while (store.document == nil || store.isOpeningProject || store.isMapLoading)
            && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!store.isOpeningProject)
        #expect(store.document != nil)
    }

    @MainActor
    private func waitForVectorLayer(_ url: URL, in store: WorkspaceStore) async throws {
        let expectedPath = SourceFilePaths.canonical(url)
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !store.mapLayers.contains(where: { SourceFilePaths.canonical($0.url) == expectedPath })
            && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(store.mapLayers.contains { SourceFilePaths.canonical($0.url) == expectedPath })
    }

    private var validLineGeoJSON: Data {
        Data(#"{"type":"FeatureCollection","features":[{"type":"Feature","properties":{"name":"Channel"},"geometry":{"type":"LineString","coordinates":[[0,0],[1,1]]}}]}"#.utf8)
    }
}

@MainActor
private final class FirstMapImportFixtureServices: WorkspaceSystemServices {
    let recoveryFolder: URL
    init(recoveryFolder: URL) { self.recoveryFolder = recoveryFolder }
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
