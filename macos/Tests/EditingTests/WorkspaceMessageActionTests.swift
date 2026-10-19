import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

@MainActor
private final class MessageActionSystem: WorkspaceSystemServices {
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

struct WorkspaceMessageActionTests {
    @Test @MainActor
    func actionsRequireRetainedMessageAndExactCurrentProjectAssetOrMap() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("message-actions-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let project = try ProjectDocument(name: "Identity", units: "SI")
        let url = folder.appendingPathComponent("Identity.ras")
        try project.save(to: url)
        try project.createDirectoryStructure()
        let geometryURL = folder.appendingPathComponent("Geometries/Same name.h5")
        try Data("identity-routing-only".utf8).write(to: geometryURL)
        let suiteName = "MessageActionTests-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = WorkspaceStore(system: MessageActionSystem(),
            recentHistoryStore: RecentProjectHistoryStore(defaults: defaults),
            globalVectorStylePreferences: GlobalVectorStylePreferences(defaults: defaults))
        try await open(url, in: store)
        let asset = try #require(store.assets.first { $0.section == .geometries })
        let initialSession = store.projectSessionID
        let message = WorkspaceMessage(operation: "Geometry", text: asset.name,
            severity: .warning, defaultAction: .openEditor(projectSessionID: initialSession,
                editorKind: ModelEditorKind.geometry.rawValue, assetID: asset.id))
        #expect(!store.performMessageDefaultAction(message))
        store.enqueueMessage(message)
        #expect(store.performMessageDefaultAction(message))
        #expect(store.activeTab == .editor(.geometry))
        let wrongKind = WorkspaceMessage(operation: "Geometry", text: asset.name,
            defaultAction: .openEditor(projectSessionID: initialSession,
                editorKind: ModelEditorKind.plan.rawValue, assetID: asset.id))
        store.enqueueMessage(wrongKind)
        #expect(!store.performMessageDefaultAction(wrongKind))
        store.requestClose()
        try await open(url, in: store)
        #expect(store.projectSessionID != initialSession)
        store.enqueueMessage(message)
        #expect(!store.performMessageDefaultAction(message), "Reopening even the same source must invalidate old action ownership.")
        let map = MapDocument(name: "Duplicate", kind: .buildable)
        store.mapDocuments = [map]
        let mapMessage = WorkspaceMessage(operation: "Map", text: map.name,
            defaultAction: .openMap(projectSessionID: store.projectSessionID, mapID: map.id))
        store.enqueueMessage(mapMessage)
        #expect(store.performMessageDefaultAction(mapMessage))
        #expect(store.activeTab == .map(map.id))
        store.mapDocuments = [MapDocument(name: map.name, kind: .buildable)]
        #expect(!store.performMessageDefaultAction(mapMessage), "A same-name map is not the original destination.")
        let history = WorkspaceMessage(operation: "Log", text: "Trace", severity: .trace, defaultAction: .showMessages)
        store.enqueueMessage(history)
        store.showMessages = false
        #expect(store.performMessageDefaultAction(history))
        #expect(store.showMessages)
        store.clearMessages()
        #expect(!store.performMessageDefaultAction(history))
    }

    @MainActor private func open(_ url: URL, in store: WorkspaceStore) async throws {
        store.requestOpen(url)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while (store.isOpeningProject || store.document?.url != url) && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(store.document?.url == url)
    }
}
