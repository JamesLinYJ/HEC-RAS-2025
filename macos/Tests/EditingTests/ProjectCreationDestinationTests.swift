import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

@MainActor
struct ProjectCreationDestinationTests {
    @Test func existingEmptyDirectoryCanCreateAndReloadARealProject() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("空目录工程")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let store = WorkspaceStore()
        store.createProject(name: "空目录工程", units: "SI", description: "中文说明", directory: root,
            projectionType: "Local", projectionValue: "SI")
        let file = try #require(store.document?.url)
        #expect(file.path == folder.appendingPathComponent("空目录工程.ras").path)
        #expect(try ProjectDocument(contentsOf: file).description == "中文说明")
    }

    @Test func hiddenContentAndFileDestinationsAreRejectedWithoutChanges() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Occupied")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let marker = folder.appendingPathComponent(".keep")
        let bytes = Data("existing content".utf8)
        try bytes.write(to: marker)
        let store = WorkspaceStore()
        store.createProject(name: "Occupied", units: "SI", description: "", directory: root,
            projectionType: "Local", projectionValue: "SI")
        #expect(store.document == nil)
        #expect(try Data(contentsOf: marker) == bytes)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == [".keep"])
        let file = root.appendingPathComponent("A file")
        try bytes.write(to: file)
        #expect(throws: (any Error).self) { try ProjectCreationDestination.validate(file) }
        #expect(try Data(contentsOf: file) == bytes)
    }
}
