import CryptoKit
import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

struct BackendGeometryBackupTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"] != nil
        && (ProcessInfo.processInfo.environment["HECRAS_MESH_PREPARE_ACCEPTANCE_DIRECTORY"] != nil
            || ProcessInfo.processInfo.environment["HECRAS_MESH_ACCEPTANCE_DIRECTORY"] != nil))) @MainActor
    func namedBackupUsesSourceNamingAndKeepsTheProjectAndGeometryUnchanged() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        let store = fixture.store
        store.descriptionDraft = "Keep this draft while creating a backup 中文"
        let projectDraftXML = try #require(store.document?.editorXML(overridingDescription: store.descriptionDraft))
        await loadCatalog(store)

        let backupDirectory = fixture.geometry.url.deletingLastPathComponent()
            .appendingPathComponent(fixture.geometry.name + " Backups", isDirectory: true)
        let filesBefore = try FileManager.default.contentsOfDirectory(at: backupDirectory,
            includingPropertiesForKeys: nil).map { canonical($0.path) }.sorted()
        let session = GeometryNamedBackupSession()
        let canceled = await session.createNamedBackup(name: "", geometry: fixture.geometry, store: store)
        #expect(canceled == nil)
        #expect(try FileManager.default.contentsOfDirectory(at: backupDirectory,
            includingPropertiesForKeys: nil).map { canonical($0.path) }.sorted() == filesBefore)

        let firstPathResult = await session.createNamedBackup(name: "Named backup", geometry: fixture.geometry, store: store)
        if firstPathResult == nil {
            Issue.record("Named Geometry backup returned nil: \(session.errorMessage ?? "<none>")")
        }
        let firstPath = try #require(firstPathResult)
        #expect(canonical(URL(fileURLWithPath: firstPath).deletingLastPathComponent().path) == canonical(backupDirectory.path))
        #expect(URL(fileURLWithPath: firstPath).lastPathComponent == "Named backup.h5")
        #expect(store.catalogTreeSession.error == nil)
        #expect(findBackup(store.catalogTreeSession.roots ?? [], path: URL(fileURLWithPath: firstPath)) != nil)
        #expect(!store.isRunningCatalogModelAction && !session.isBusy)

        let secondPathResult = await session.createNamedBackup(name: "Named backup", geometry: fixture.geometry, store: store)
        let secondPath = try #require(secondPathResult)
        #expect(URL(fileURLWithPath: secondPath).lastPathComponent == "Named backup (1).h5")
        #expect(try Data(contentsOf: fixture.projectURL) == fixture.projectBytes)
        #expect(try Data(contentsOf: fixture.geometry.url) == fixture.geometryBytes)
        #expect(try Data(contentsOf: fixture.backupURL) == fixture.backupBytes)
        #expect(store.descriptionDraft == "Keep this draft while creating a backup 中文")
        #expect(store.document?.editorXML(overridingDescription: store.descriptionDraft) == projectDraftXML)
        #expect(store.catalogTreeSession.error == nil)
        #expect(findBackup(store.catalogTreeSession.roots ?? [], path: URL(fileURLWithPath: secondPath)) != nil)
        #expect(!store.isRunningCatalogModelAction && !session.isBusy)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"] != nil
        && (ProcessInfo.processInfo.environment["HECRAS_MESH_PREPARE_ACCEPTANCE_DIRECTORY"] != nil
            || ProcessInfo.processInfo.environment["HECRAS_MESH_ACCEPTANCE_DIRECTORY"] != nil))) @MainActor
    func selectedBackupRestoresThroughWorkspaceProviderAndSelectsUniqueGeometryWithoutSavingDrafts() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        let store = fixture.store
        let document = try #require(store.document)
        store.descriptionDraft = "Keep the unsaved description 中文"

        let association = try #require(document.associationRows(group: "GeometryAssociations")
            .first { $0.name == fixture.geometry.name })
        let currentTerrain = association.fields["Terrain"] ?? ""
        let alternateTerrain = store.assets.first {
            $0.section == .terrains && $0.isModelFile && $0.name != currentTerrain
        }?.name
        let terrainDraft = alternateTerrain ?? (currentTerrain.isEmpty ? "Pending terrain association 中文" : "")
        store.setAssociation(association, field: "Terrain", value: terrainDraft)
        let associationDraft = try #require(document.associationRows(group: "GeometryAssociations")
            .first { $0.name == fixture.geometry.name })
        #expect(associationDraft.fields["Terrain"] == terrainDraft)
        let projectDraftXML = document.editorXML(overridingDescription: store.descriptionDraft)

        await loadCatalog(store)
        let backup = try #require(findBackup(store.catalogTreeSession.roots ?? [], path: fixture.backupURL))
        #expect(backup.backupSummary?.canSaveAsNewGeometry == true)
        #expect(backup.backupSummary?.revision == digest(fixture.backupBytes))

        let firstPathResult = await store.catalogTreeSession.saveBackupAsNewGeometry(backup.id)
        if firstPathResult == nil {
            let sessionError = store.catalogTreeSession.error ?? "<none>"
            let selectedNodeClass = store.catalogTreeSession.selectedNode?.sourceClass ?? "<none>"
            Issue.record("Geometry backup provider returned nil; sessionError=\(sessionError); treeBusy=\(store.catalogTreeSession.busy); mutationLease=\(store.isRunningCatalogModelAction); projectTool=\(store.isRunningProjectTool); selectedNode=\(selectedNodeClass)")
        }
        let firstPath = try #require(firstPathResult)
        #expect(store.catalogTreeSession.error == nil)
        #expect(store.catalogTreeSession.selectedNode?.sourceClass == "ObservableGeometry")
        #expect(!store.catalogTreeSession.busy && !store.isRunningCatalogModelAction && !store.isRunningProjectTool)
        let firstAsset = try refreshAndSelect(store, path: firstPath)
        #expect(store.selectedAssetID == firstAsset.id)
        #expect(try Data(contentsOf: firstAsset.url) == fixture.backupBytes)
        let modelProvider = try #require(store.modelProvider as? BackendModelProvider)
        let firstReadback = try await modelProvider.load(firstAsset, kind: .geometry)
        #expect(firstReadback.fields.values.contains(firstAsset.name))

        let nextBackup = try #require(findBackup(store.catalogTreeSession.roots ?? [], path: fixture.backupURL))
        let secondPath = try #require(await store.catalogTreeSession.saveBackupAsNewGeometry(nextBackup.id))
        #expect(store.catalogTreeSession.error == nil)
        #expect(!store.catalogTreeSession.busy && !store.isRunningCatalogModelAction && !store.isRunningProjectTool)
        let secondAsset = try refreshAndSelect(store, path: secondPath)
        #expect(SourceFilePaths.canonical(firstAsset.url) != SourceFilePaths.canonical(secondAsset.url))
        #expect(secondAsset.name == firstAsset.name + " (1)")
        #expect(store.selectedAssetID == secondAsset.id)
        #expect(store.catalogTreeSession.selectedNode?.assetID.map(canonical) == canonical(secondAsset.url.path))
        #expect(try Data(contentsOf: secondAsset.url) == fixture.backupBytes)
        let secondReadback = try await modelProvider.load(secondAsset, kind: .geometry)
        #expect(secondReadback.fields.values.contains(secondAsset.name))

        #expect(store.descriptionDraft == "Keep the unsaved description 中文")
        #expect(document.editorXML(overridingDescription: store.descriptionDraft) == projectDraftXML)
        #expect(document.associationRows(group: "GeometryAssociations")
            .first { $0.name == fixture.geometry.name }?.fields["Terrain"] == terrainDraft)
        #expect(try Data(contentsOf: fixture.projectURL) == fixture.projectBytes)
        #expect(try Data(contentsOf: fixture.geometry.url) == fixture.geometryBytes)
        #expect(try Data(contentsOf: fixture.backupURL) == fixture.backupBytes)
        #expect(try visState(fixture.visURL) == fixture.visBytes)
        let currentGeometryFiles = try directGeometryHDFDigests(fixture.geometry.url.deletingLastPathComponent())
        #expect(currentGeometryFiles.filter { fixture.originalGeometryFiles[$0.key] != nil }
            == fixture.originalGeometryFiles)
        #expect(Set(currentGeometryFiles.keys).subtracting(Set(fixture.originalGeometryFiles.keys))
            == Set([canonical(firstAsset.url.path), canonical(secondAsset.url.path)]))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"] != nil
        && (ProcessInfo.processInfo.environment["HECRAS_MESH_PREPARE_ACCEPTANCE_DIRECTORY"] != nil
            || ProcessInfo.processInfo.environment["HECRAS_MESH_ACCEPTANCE_DIRECTORY"] != nil))) @MainActor
    func catalogBackupRestoreRejectsSelectedBackupAndSavedProjectRevisionChanges() async throws {
        try await assertStaleBackupIsRejected()
        try await assertStaleProjectIsRejected()
    }
}

@MainActor
private struct GeometryBackupHarness {
    let folder: URL
    let projectURL: URL
    let visURL: URL
    let geometry: ProjectAsset
    let backupURL: URL
    let store: WorkspaceStore
    let projectBytes: Data
    let geometryBytes: Data
    let backupBytes: Data
    let visBytes: Data?
    let originalGeometryFiles: [String: String]
}

@MainActor
private func makeFixture() async throws -> GeometryBackupHarness {
    let environment = ProcessInfo.processInfo.environment
    guard let sourcePath = environment["HECRAS_MESH_PREPARE_ACCEPTANCE_DIRECTORY"]
        ?? environment["HECRAS_MESH_ACCEPTANCE_DIRECTORY"],
          let executable = environment["HECRAS_BACKEND_TEST_EXECUTABLE"] else {
        throw CocoaError(.fileNoSuchFile)
    }
    let sourceFolder = URL(fileURLWithPath: sourcePath, isDirectory: true).standardizedFileURL
    let projectInSource = try #require(findFixtureProject(sourceFolder))
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("geometry-backup-workflow-" + UUID().uuidString, isDirectory: true)
    #expect(!FileManager.default.fileExists(atPath: folder.path))
    try FileManager.default.copyItem(at: sourceFolder, to: folder)
    let relativeProjectPath = String(projectInSource.path.dropFirst(sourceFolder.path.count + 1))
    let projectURL = folder.appendingPathComponent(relativeProjectPath)
    let copiedProject = try ProjectDocument(contentsOf: projectURL)
    let geometry = try #require(copiedProject.assets.first { $0.section == .geometries && $0.isModelFile })
    let backupDirectory = geometry.url.deletingLastPathComponent()
        .appendingPathComponent(geometry.name + " Backups", isDirectory: true)
    if !FileManager.default.fileExists(atPath: backupDirectory.path) {
        try FileManager.default.createDirectory(at: backupDirectory, withIntermediateDirectories: false)
    }
    let backupURL = backupDirectory.appendingPathComponent("Selected backup " + UUID().uuidString + ".h5")
    #expect(!FileManager.default.fileExists(atPath: backupURL.path))
    try FileManager.default.copyItem(at: geometry.url, to: backupURL)

    let provider = BackendModelProvider(client: BackendProcessClient(executableURL: URL(fileURLWithPath: executable)))
    let store = WorkspaceStore(system: GeometryBackupFixtureServices(), modelProvider: provider)
    store.requestOpen(projectURL)
    let deadline = ContinuousClock.now.advanced(by: .seconds(15))
    while store.isOpeningProject && ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(!store.isOpeningProject)
    #expect(store.document?.url?.standardizedFileURL == projectURL.standardizedFileURL)
    let openedGeometry = try #require(store.assets.first {
        $0.section == .geometries && canonical($0.url.path) == canonical(geometry.url.path)
    })
    let projectBytes = try Data(contentsOf: projectURL)
    let geometryBytes = try Data(contentsOf: openedGeometry.url)
    let backupBytes = try Data(contentsOf: backupURL)
    let visURL = projectURL.deletingPathExtension().appendingPathExtension("vis")
    let visBytes = try visState(visURL)
    let originalGeometryFiles = try directGeometryHDFDigests(openedGeometry.url.deletingLastPathComponent())
    #expect(originalGeometryFiles[canonical(openedGeometry.url.path)] == digest(geometryBytes))
    #expect(originalGeometryFiles[canonical(backupURL.path)] == nil)
    return GeometryBackupHarness(folder: folder, projectURL: projectURL, visURL: visURL,
        geometry: openedGeometry, backupURL: backupURL, store: store,
        projectBytes: projectBytes, geometryBytes: geometryBytes, backupBytes: backupBytes,
        visBytes: visBytes, originalGeometryFiles: originalGeometryFiles)
}

@MainActor
private func loadCatalog(_ store: WorkspaceStore) async {
    guard let provider = store.catalogTreeProvider else {
        Issue.record("WorkspaceStore did not install its source catalog provider.")
        return
    }
    await store.catalogTreeSession.load(provider: provider, context: store.catalogTreeContext)
    #expect(store.catalogTreeSession.error == nil)
}

@MainActor
private func refreshAndSelect(_ store: WorkspaceStore, path: String) throws -> ProjectAsset {
    store.refreshAssets()
    let expected = canonical(path)
    let asset = try #require(store.assets.first {
        $0.section == .geometries && canonical($0.url.path) == expected
    })
    store.select(asset, clearTreeSelection: false)
    return asset
}

@MainActor
private func assertStaleBackupIsRejected() async throws {
    let fixture = try await makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.folder) }
    await loadCatalog(fixture.store)
    let backup = try #require(findBackup(fixture.store.catalogTreeSession.roots ?? [], path: fixture.backupURL))
    let directFilesBefore = try directGeometryHDFDigests(fixture.geometry.url.deletingLastPathComponent())
    do {
        var changed = fixture.backupBytes
        changed.append(contentsOf: [0x20])
        try changed.write(to: fixture.backupURL)
        let result = await fixture.store.catalogTreeSession.saveBackupAsNewGeometry(backup.id)
        #expect(result == nil)
        #expect(fixture.store.catalogTreeSession.error != nil)
        #expect(!fixture.store.catalogTreeSession.busy && !fixture.store.isRunningCatalogModelAction)
        #expect(try directGeometryHDFDigests(fixture.geometry.url.deletingLastPathComponent()) == directFilesBefore)
    }
    try fixture.backupBytes.write(to: fixture.backupURL)
}

@MainActor
private func assertStaleProjectIsRejected() async throws {
    let fixture = try await makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.folder) }
    await loadCatalog(fixture.store)
    let backup = try #require(findBackup(fixture.store.catalogTreeSession.roots ?? [], path: fixture.backupURL))
    let directFilesBefore = try directGeometryHDFDigests(fixture.geometry.url.deletingLastPathComponent())
    do {
        var changed = fixture.projectBytes
        changed.append(contentsOf: [0x20])
        try changed.write(to: fixture.projectURL)
        let result = await fixture.store.catalogTreeSession.saveBackupAsNewGeometry(backup.id)
        #expect(result == nil)
        #expect(fixture.store.catalogTreeSession.error != nil)
        #expect(!fixture.store.catalogTreeSession.busy && !fixture.store.isRunningCatalogModelAction)
        #expect(try directGeometryHDFDigests(fixture.geometry.url.deletingLastPathComponent()) == directFilesBefore)
    }
    try fixture.projectBytes.write(to: fixture.projectURL)
}

private func findFixtureProject(_ folder: URL) -> URL? {
    let preferred = ["Prepared geometry.ras", "Mesh editor.ras"]
    let files = (FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
        .filter { $0.pathExtension.lowercased() == "ras" }
    for name in preferred {
        if let match = files.first(where: { $0.lastPathComponent == name }) { return match }
    }
    return files.sorted { $0.path < $1.path }.first
}

private func findBackup(_ nodes: [LayerTreeNode], path: URL) -> LayerTreeNode? {
    let expected = canonical(path.path)
    for node in nodes {
        if node.sourceClass == "BackupNodeVM",
           node.assetID.map(canonical) == expected,
           node.backupSummary?.canSaveAsNewGeometry == true {
            return node
        }
        if let match = findBackup(node.children ?? [], path: path) { return match }
    }
    return nil
}

private func directGeometryHDFDigests(_ directory: URL) throws -> [String: String] {
    let files = try FileManager.default.contentsOfDirectory(at: directory,
        includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
    return try Dictionary(uniqueKeysWithValues: files.filter { $0.pathExtension.lowercased() == "h5" }
        .map { (canonical($0.path), digest(try Data(contentsOf: $0))) })
}

private func visState(_ url: URL) throws -> Data? {
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    return try Data(contentsOf: url)
}

private func canonical(_ path: String) -> String {
    SourceFilePaths.canonical(URL(fileURLWithPath: path))
}

private func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02X", $0) }.joined()
}

@MainActor
private final class GeometryBackupFixtureServices: WorkspaceSystemServices {
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
