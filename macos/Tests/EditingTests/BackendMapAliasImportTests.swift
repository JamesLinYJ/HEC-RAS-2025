import Foundation
import Testing
import RASWorkspaceCore
@testable import HECRAS2025

struct BackendMapAliasImportTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"] != nil))
    @MainActor
    func firstImportOfGeoJSONAliasToDataRendersAndKeepsItsExactStyleOwnerAcrossSaveAndReopen() async throws {
        let executable = try #require(ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"])
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("map-alias-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let projectDirectory = root.appendingPathComponent("Project", isDirectory: true)
        let externalDirectory = root.appendingPathComponent("External", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: externalDirectory, withIntermediateDirectories: true)

        let projectURL = projectDirectory.appendingPathComponent("Alias Import.ras")
        let sourceURL = externalDirectory.appendingPathComponent("Channel.geojson")
        let targetURL = externalDirectory.appendingPathComponent("Channel.data")
        let sourceBytes = Data(#"{"type":"FeatureCollection","features":[{"type":"Feature","properties":{"name":"Channel"},"geometry":{"type":"LineString","coordinates":[[0,0],[1,1]]}}]}"#.utf8)
        let project = try ProjectDocument(name: "Alias Import", units: "SI")
        try project.save(to: projectURL)
        let originalProjectBytes = try Data(contentsOf: projectURL)
        try sourceBytes.write(to: targetURL)
        try FileManager.default.createSymbolicLink(at: sourceURL, withDestinationURL: targetURL)

        let suiteName = "HECRAS2025.MapAliasImport.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = GlobalVectorStylePreferences(defaults: defaults)

        let store = makeStore(executable: executable,
            recoveryDirectory: root.appendingPathComponent("Recovery", isDirectory: true),
            preferences: preferences)
        store.requestOpen(projectURL)
        try await waitForProjectOpen(store)
        try await waitForMapLoad(store)

        #expect(await store.connectVectorSource(sourceURL, for: MapState.projectMapID))
        try await waitForMapLoad(store)
        let nodes = try await store.sourceMapLayerNodes(MapState.projectMapID)
        await store.refreshSourceMapVectors(nodes, mapID: MapState.projectMapID)

        let lineNode = try #require(nodes.first {
            $0.sourceLocator?.nodeType == "MapLayer" && $0.sourceLocator?.mapType == "PolylinesVector"
        })
        let presentationURL = try #require(store.sourceMapVectorURL(lineNode))
        #expect(presentationURL.pathExtension == "geojson")
        #expect(SourceFilePaths.canonical(presentationURL) == SourceFilePaths.canonical(targetURL))
        #expect(try Data(contentsOf: sourceURL) == sourceBytes)
        #expect(try Data(contentsOf: targetURL) == sourceBytes)

        let mapState = store.mapState(for: MapState.projectMapID)
        let renderedLayer = try #require(mapState.visibleVectors(store.mapLayers).first {
            SourceFilePaths.canonical($0.url) == SourceFilePaths.canonical(targetURL)
        })
        #expect(renderedLayer.url.pathExtension == "geojson")
        #expect(SourceFilePaths.canonical(renderedLayer.url) == SourceFilePaths.canonical(targetURL))
        #expect(renderedLayer.features.count == 1)
        #expect(renderedLayer.features.first?.kind == .line)

        let styleProvider = try #require(store.vectorSymbologyProvider as? WorkspaceVectorSymbologyProvider)
        let styleContext = try #require(store.vectorSymbologyContexts(mapID: MapState.projectMapID).first {
            $0.visualNode?.nodePath == lineNode.sourceLocator?.nodePath
                && $0.visualNode?.nodeType == "MapLayer"
                && $0.visualNode?.mapLayerType == "PolylinesVector"
        })
        #expect(styleContext.layerID == renderedLayer.id)
        #expect(styleContext.visualNode?.assetID == SourceFilePaths.canonical(targetURL))
        let snapshot = try #require(try await styleProvider.snapshot(styleContext))
        #expect(snapshot.canEdit)
        var options = snapshot.options
        let lineIndex = try #require(options.firstIndex { $0.id == "Polyline_Line_Symbology" })
        #expect(options[lineIndex].conditionCapabilityReason == nil)
        #expect(options[lineIndex].columns.contains { $0.name == "name" })
        options[lineIndex].style.penWidth = 7
        options[lineIndex].conditions[.penWidth] = [
            VectorStyleRule(column: "name", comparison: "equals", threshold: "Channel", resultValue: "9")
        ]
        let update = try await styleProvider.apply(options: options,
            additionalOptions: snapshot.additionalOptions, context: styleContext)
        store.installMapUpdate(update, mapID: MapState.projectMapID)
        let styledLayerID = try #require(styleContext.layerID)
        let appliedPresentation = try #require(mapState.vectorStyles[styledLayerID])
        #expect(appliedPresentation.base["Polyline_Line_Symbology"]?.penWidth == 7)
        #expect(appliedPresentation.perSourceFeatureOverrides.values.contains {
            $0["Polyline_Line_Symbology"]?.penWidth == 9
        })
        #expect(appliedPresentation.sourceFeatureOrdinalBindingVerified)

        #expect(store.save())
        let savedProject = try ProjectDocument(contentsOf: projectURL)
        #expect(savedProject.connections.count == 1)
        #expect(SourceFilePaths.canonical(try #require(savedProject.connections.first).resolve(
            relativeTo: try #require(savedProject.directory), mappings: [])) == SourceFilePaths.canonical(targetURL))
        #expect(try Data(contentsOf: projectURL) != originalProjectBytes)
        #expect(try Data(contentsOf: sourceURL) == sourceBytes)
        #expect(try Data(contentsOf: targetURL) == sourceBytes)

        let visualizationURL = projectURL.deletingPathExtension().appendingPathExtension("vis")
        let visualization = try VisualizationDocument(projectURL: projectURL)
        #expect(visualization.maps.count == 1)
        let serializedLayerPaths = try XMLDocument(data: Data(contentsOf: visualizationURL),
            options: [.nodeLoadExternalEntitiesNever]).nodes(forXPath: "//Node[@Type='MapLayer']/@Filename")
            .compactMap(\.stringValue)
        #expect(serializedLayerPaths == [sourceURL.standardizedFileURL.path])

        store.requestClose()
        if store.showDiscardConfirmation { store.discardAndContinue() }
        try #require(store.document == nil)

        let reopened = makeStore(executable: executable,
            recoveryDirectory: root.appendingPathComponent("Reopen Recovery", isDirectory: true),
            preferences: preferences)
        reopened.requestOpen(projectURL)
        try await waitForProjectOpen(reopened)
        try await waitForMapLoad(reopened)
        let reopenedNodes = try await reopened.sourceMapLayerNodes(MapState.projectMapID)
        await reopened.refreshSourceMapVectors(reopenedNodes, mapID: MapState.projectMapID)

        let reopenedState = reopened.mapState(for: MapState.projectMapID)
        let reopenedLayer = try #require(reopenedState.visibleVectors(reopened.mapLayers).first {
            SourceFilePaths.canonical($0.url) == SourceFilePaths.canonical(targetURL)
        })
        #expect(reopenedLayer.url.pathExtension == "geojson")
        #expect(SourceFilePaths.canonical(reopenedLayer.url) == SourceFilePaths.canonical(targetURL))
        #expect(reopenedLayer.features.count == 1)
        let reopenedProvider = try #require(reopened.vectorSymbologyProvider as? WorkspaceVectorSymbologyProvider)
        let reopenedContext = try #require(reopened.vectorSymbologyContexts(mapID: MapState.projectMapID).first {
            $0.visualNode?.nodeType == "MapLayer" && $0.visualNode?.mapLayerType == "PolylinesVector"
        })
        #expect(reopenedContext.layerID == reopenedLayer.id)
        let reopenedSnapshot = try #require(try await reopenedProvider.snapshot(reopenedContext))
        let reopenedLineStyle = try #require(reopenedSnapshot.options.first { $0.id == "Polyline_Line_Symbology" })
        #expect(reopenedLineStyle.style.penWidth == 7)
        #expect(reopenedLineStyle.conditionCapabilityReason == nil)
        let reopenedLayerID = try #require(reopenedContext.layerID)
        let reopenedPresentation = try #require(reopenedState.vectorStyles[reopenedLayerID])
        #expect(reopenedPresentation.sourceFeatureOrdinalBindingVerified)
        #expect(reopenedPresentation.perSourceFeatureOverrides.values.contains {
            $0["Polyline_Line_Symbology"]?.penWidth == 9
        })
        #expect(try Data(contentsOf: sourceURL) == sourceBytes)
        #expect(try Data(contentsOf: targetURL) == sourceBytes)
    }

    @MainActor
    private func makeStore(executable: String, recoveryDirectory: URL,
                          preferences: GlobalVectorStylePreferences) -> WorkspaceStore {
        WorkspaceStore(system: AliasMapImportFixtureServices(recoveryFolder: recoveryDirectory),
            modelProvider: BackendModelProvider(client: BackendProcessClient(
                executableURL: URL(fileURLWithPath: executable))),
            globalVectorStylePreferences: preferences)
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
    private func waitForMapLoad(_ store: WorkspaceStore) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while store.isMapLoading && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!store.isMapLoading)
    }
}

@MainActor
private final class AliasMapImportFixtureServices: WorkspaceSystemServices {
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
