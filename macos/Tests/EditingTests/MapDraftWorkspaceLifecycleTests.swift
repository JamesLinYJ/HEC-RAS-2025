import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

@MainActor
private final class MapLifecycleWorkspaceServices: WorkspaceSystemServices {
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

struct MapDraftWorkspaceLifecycleTests {
    @Test @MainActor
    func dirtyFirstMapBlocksEditsInSecondMapForSameGeoJSON() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (sourceURL, original) = try makeLineLayer(in: folder)
        let workspace = makeStore()
        defer { workspace.defaults.removePersistentDomain(forName: workspace.suiteName) }
        let store = workspace.store
        let firstID = UUID(), secondID = UUID()
        let first = store.mapState(for: firstID).polylineEditor
        let second = store.mapState(for: secondID).polylineEditor
        let firstScope = PolylineMapEditingScope(projectSessionID: store.projectSessionID,
            mapID: firstID, layerID: sourceURL.path, canonicalPath: sourceURL.path)
        let secondScope = PolylineMapEditingScope(projectSessionID: store.projectSessionID,
            mapID: secondID, layerID: sourceURL.path, canonicalPath: sourceURL.path)

        #expect(await first.ensureLoaded(scope: firstScope))
        #expect(await second.ensureLoaded(scope: secondScope))
        let firstLine = try #require(first.lines.first)
        let secondLine = try #require(second.lines.first)
        #expect(await first.moveVertex(lineID: firstLine.id, vertexIndex: 1, to: MapPoint(x: 8, y: 9)))
        #expect(first.hasUnsavedChanges)
        #expect(store.hasUnsavedMapEdits)

        #expect(!(await second.moveVertex(lineID: secondLine.id, vertexIndex: 1, to: MapPoint(x: 20, y: 30))))
        #expect(!second.hasUnsavedChanges)
        #expect(store.hasConflictingMapDraft(path: sourceURL.path, excluding: secondID))
        #expect(try Data(contentsOf: sourceURL) == original)
    }

    @Test @MainActor
    func unfinishedDrawPreviewIsWorkspaceUnsavedStateAndCannotBeSavedYet() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (sourceURL, original) = try makeLineLayer(in: folder)
        let workspace = makeStore()
        defer { workspace.defaults.removePersistentDomain(forName: workspace.suiteName) }
        let store = workspace.store
        let mapID = UUID()
        let editor = store.mapState(for: mapID).polylineEditor
        let scope = PolylineMapEditingScope(projectSessionID: store.projectSessionID,
            mapID: mapID, layerID: sourceURL.path, canonicalPath: sourceURL.path)

        #expect(await editor.ensureLoaded(scope: scope))
        editor.setTool(.drawLine)
        editor.appendDrawingPoint(MapPoint(x: 2, y: 3))
        editor.appendDrawingPoint(MapPoint(x: 4, y: 5))

        #expect(editor.previewPoints == [MapPoint(x: 2, y: 3), MapPoint(x: 4, y: 5)])
        #expect(editor.hasUnsavedChanges)
        #expect(store.hasUnsavedMapEdits)
        #expect(store.hasUnsavedChanges)
        #expect(!(await editor.save()))
        #expect(try Data(contentsOf: sourceURL) == original)
    }

    @Test @MainActor
    func saveAllWritesMapLineDraftToGeoJSONAndClearsWorkspaceDirtyState() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (sourceURL, original) = try makeLineLayer(in: folder)
        let workspace = makeStore()
        defer { workspace.defaults.removePersistentDomain(forName: workspace.suiteName) }
        let store = workspace.store
        let mapID = UUID()
        let editor = store.mapState(for: mapID).polylineEditor
        let scope = PolylineMapEditingScope(projectSessionID: store.projectSessionID,
            mapID: mapID, layerID: sourceURL.path, canonicalPath: sourceURL.path)

        #expect(await editor.ensureLoaded(scope: scope))
        let line = try #require(editor.lines.first)
        #expect(await editor.moveVertex(lineID: line.id, vertexIndex: 1, to: MapPoint(x: 3, y: 4)))
        #expect(store.hasUnsavedChanges)
        #expect(try Data(contentsOf: sourceURL) == original)

        #expect(await store.saveAll())

        let saved = try Data(contentsOf: sourceURL)
        let parsed = try GeoJSONPolylineDocument(data: saved, sourceURL: sourceURL)
        #expect(saved != original)
        #expect(parsed.lines.first?.points.last == MapPoint(x: 3, y: 4))
        #expect(!editor.hasUnsavedChanges)
        #expect(!store.hasUnsavedMapEdits)
        #expect(!store.hasUnsavedChanges)
    }

    @Test @MainActor
    func closingDirtyMapPromptsAndSaveClosesAfterPersistingTheLineDraft() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (sourceURL, original) = try makeLineLayer(in: folder)
        let workspace = makeStore()
        defer { workspace.defaults.removePersistentDomain(forName: workspace.suiteName) }
        let store = workspace.store
        let mapID = UUID()
        store.mapDocuments = [MapDocument(id: mapID, name: "Line map", kind: .project)]
        store.activeTab = .map(mapID)
        let registeredMapState = store.mapState(for: mapID)
        let editor = registeredMapState.polylineEditor
        let scope = PolylineMapEditingScope(projectSessionID: store.projectSessionID,
            mapID: mapID, layerID: sourceURL.path, canonicalPath: sourceURL.path)

        #expect(await editor.ensureLoaded(scope: scope))
        let line = try #require(editor.lines.first)
        #expect(await editor.moveVertex(lineID: line.id, vertexIndex: 1, to: MapPoint(x: 6, y: 7)))
        store.requestCloseTab(.map(mapID))
        #expect(store.showCloseTabConfirmation)
        #expect(store.mapDocuments.contains(where: { $0.id == mapID }))
        #expect(editor.hasUnsavedChanges)

        #expect(await store.saveAndCloseTab())

        let saved = try Data(contentsOf: sourceURL)
        let parsed = try GeoJSONPolylineDocument(data: saved, sourceURL: sourceURL)
        #expect(saved != original)
        #expect(parsed.lines.first?.points.last == MapPoint(x: 6, y: 7))
        #expect(!editor.hasUnsavedChanges)
        #expect(!store.mapDocuments.contains(where: { $0.id == mapID }))
        #expect(store.activeTab == .page(.map))
        #expect(store.mapState(for: mapID) === registeredMapState)
    }

    @Test @MainActor
    func openingAnotherProjectKeepsMapLineDraftUntilExplicitDiscard() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let firstProject = try makeProject(in: folder, name: "Map Draft First")
        let secondProject = try makeProject(in: folder, name: "Map Draft Second")
        let (sourceURL, original) = try makeLineLayer(in: folder)
        let workspace = makeStore()
        defer { workspace.defaults.removePersistentDomain(forName: workspace.suiteName) }
        let store = workspace.store
        await openProject(firstProject, in: store)
        let originalProjectSessionID = store.projectSessionID

        let mapID = UUID()
        let mapState = store.mapState(for: mapID)
        let editor = mapState.polylineEditor
        let scope = PolylineMapEditingScope(projectSessionID: store.projectSessionID,
            mapID: mapID, layerID: sourceURL.path, canonicalPath: sourceURL.path)
        #expect(await editor.ensureLoaded(scope: scope))
        let line = try #require(editor.lines.first)
        #expect(await editor.moveVertex(lineID: line.id, vertexIndex: 1, to: MapPoint(x: 11, y: 12)))
        #expect(store.hasUnsavedMapEdits)
        #expect(try Data(contentsOf: sourceURL) == original)

        store.requestOpen(secondProject)
        await waitForProjectOpening(store)
        #expect(store.showDiscardConfirmation)
        #expect(store.document?.url == firstProject)
        #expect(store.projectSessionID == originalProjectSessionID)
        #expect(editor.currentScope == scope)
        #expect(editor.hasUnsavedChanges)
        #expect(store.hasUnsavedMapEdits)

        store.cancelReplacement()
        #expect(store.document?.url == firstProject)
        #expect(editor.currentScope == scope && editor.hasUnsavedChanges)

        store.requestOpen(secondProject)
        await waitForProjectOpening(store)
        #expect(store.showDiscardConfirmation)
        store.discardAndContinue()
        await waitForProjectOpening(store)

        #expect(store.document?.url == secondProject)
        #expect(store.projectSessionID != originalProjectSessionID)
        #expect(editor.currentScope == nil)
        #expect(!editor.hasUnsavedChanges)
        #expect(!store.hasUnsavedMapEdits)
        #expect(try Data(contentsOf: sourceURL) == original)
    }

    @MainActor
    private func makeStore() -> (store: WorkspaceStore, defaults: UserDefaults, suiteName: String) {
        let suiteName = "MapDraftWorkspaceLifecycleTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let store = WorkspaceStore(system: MapLifecycleWorkspaceServices(),
            recentHistoryStore: RecentProjectHistoryStore(defaults: defaults))
        return (store, defaults, suiteName)
    }

    @MainActor
    private func openProject(_ url: URL, in store: WorkspaceStore) async {
        store.requestOpen(url)
        await waitForProjectOpening(store)
        #expect(store.document?.url == url)
    }

    @MainActor
    private func waitForProjectOpening(_ store: WorkspaceStore) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while store.isOpeningProject && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(!store.isOpeningProject)
    }

    private func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("map-draft-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func makeProject(in folder: URL, name: String) throws -> URL {
        let url = folder.appendingPathComponent(name + ".ras")
        try Data("<Project><Description>\(name)</Description></Project>".utf8).write(to: url)
        return url
    }

    private func makeLineLayer(in folder: URL) throws -> (url: URL, bytes: Data) {
        let url = folder.appendingPathComponent("shared-lines.geojson")
        let bytes = Data(#"{"type":"FeatureCollection","features":[{"type":"Feature","id":"main","properties":{"name":"Main"},"geometry":{"type":"LineString","coordinates":[[0,0],[1,1]]}}]}"#.utf8)
        try bytes.write(to: url)
        return (url, bytes)
    }
}
