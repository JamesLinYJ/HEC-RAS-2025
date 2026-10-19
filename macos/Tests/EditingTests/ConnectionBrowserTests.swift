import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

private actor DeferredConnectionPreviewProvider: ConnectionPreviewProvider {
    private var pending: [String: CheckedContinuation<ConnectionPreview, any Error>] = [:]
    func preview(_ request: ConnectionPreviewRequest) async throws -> ConnectionPreview {
        try await withCheckedThrowingContinuation { pending[request.connection.id] = $0 }
    }
    func started(_ id: String) -> Bool { pending[id] != nil }
    func finish(_ id: String) { pending.removeValue(forKey: id)?.resume(returning: .init(location: URL(filePath: "/" + id), files: [], total: 0)) }
}
@MainActor private final class DeferredExternalRecordProvider: ExternalRecordProvider {
    var pending: [String: CheckedContinuation<[ExternalRecord], any Error>] = [:]
    func records(connection: ProjectConnection, directory: URL, mappings: [PathMapping]) async throws -> [ExternalRecord] {
        try await withCheckedThrowingContinuation { pending[connection.id] = $0 }
    }
}
struct ConnectionBrowserTests {
    private func fixture() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
    private func request(_ id: String, directory: URL = URL(filePath: "/")) -> ConnectionPreviewRequest {
        .init(projectID: UUID(), connection: .init(id: id, name: id, type: "File", relativePath: "", absolutePath: "/" + id), directory: directory, mappings: [])
    }
    @Test func batchFileNamesUseSourceFilenameFallbackAndRejectDuplicates() {
        let first = ConnectionFileDraft(url: URL(filePath: "/one/data.csv"), name: " ")
        let second = ConnectionFileDraft(url: URL(filePath: "/two/data.csv"), name: "独立名称")
        #expect(first.effectiveName == "data.csv")
        #expect(ConnectionFileDraft.valid([first, second], existingNames: []))
        #expect(!ConnectionFileDraft.valid([first, .init(url: second.url, name: "data.csv")], existingNames: []))
        #expect(!ConnectionFileDraft.valid([first], existingNames: ["data.csv"]))
        #expect(!ConnectionFileDraft.valid([], existingNames: []))
    }
    @Test func connectionIdentitySurvivesRemovingEarlierXMLNodesAndRejectsStaleEditing() throws {
        let directory = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appendingPathComponent("第一.csv"), second = directory.appendingPathComponent("第二.csv")
        try Data("first".utf8).write(to: first); try Data("second".utf8).write(to: second)
        let project = directory.appendingPathComponent("工程.ras")
        try Data("<Project><Connections><Connection Name='A' Type='File'><RelativePath>第一.csv</RelativePath><Custom>keep</Custom></Connection><Connection Name='B' Type='File'><RelativePath>第二.csv</RelativePath><Description>旧说明</Description></Connection></Connections><Unknown>保留</Unknown></Project>".utf8).write(to: project)
        let document = try ProjectDocument(contentsOf: project), snapshots = document.connections
        #expect(document.connections.map(\.id) == snapshots.map(\.id))
        try document.removeConnection(id: snapshots[0].id)
        #expect(document.connections.first?.id == snapshots[1].id)
        try document.updateConnection(snapshots[1], target: second, description: "中文新说明", searchPattern: "*", recurse: false)
        #expect(throws: (any Error).self) { try document.updateConnection(snapshots[1], target: first, description: "stale", searchPattern: "*", recurse: false) }
        #expect(throws: (any Error).self) { try document.removeConnection(id: snapshots[0].id) }
        try document.save()
        #expect(try ProjectDocument(contentsOf: project).connections.first?.description == "中文新说明")
        #expect(try String(contentsOf: project, encoding: .utf8).contains("<Unknown>保留</Unknown>"))
        #expect(FileManager.default.fileExists(atPath: first.path) && FileManager.default.fileExists(atPath: second.path))
    }
    @Test func multipleFileAddValidatesWholeBatchBeforeChangingProject() throws {
        let directory = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("valid.csv"); try Data().write(to: file)
        let project = directory.appendingPathComponent("工程.ras"); try Data("<Project/>".utf8).write(to: project)
        let document = try ProjectDocument(contentsOf: project), baseline = document.editorXML
        #expect(throws: (any Error).self) { try document.connectFiles([("first", file), ("missing", directory.appendingPathComponent("missing.csv"))]) }
        #expect(document.editorXML == baseline)
        #expect(throws: (any Error).self) { try document.connectFiles([("same", file), ("same", file)]) }
        #expect(document.editorXML == baseline)
        try document.connectFiles([("中文文件名", file)])
        #expect(document.connections.map(\.name) == ["中文文件名"])
        #expect(document.connections.first?.relativePath == "valid.csv")
    }
    @Test func filesystemPreviewUsesPatternRecursionAndActualMetadata() async throws {
        let directory = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let nested = directory.appendingPathComponent("nested");try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("abc".utf8).write(to: directory.appendingPathComponent("first.csv"))
        try Data("longer".utf8).write(to: nested.appendingPathComponent("second.csv"))
        try Data().write(to: directory.appendingPathComponent("ignore.txt"))
        let connection = ProjectConnection(id: "dir", name: "目录", type: "Directory", relativePath: "", absolutePath: directory.path, searchPattern: "*.csv", recurse: true)
        let preview = try await FileSystemConnectionPreviewProvider().preview(.init(projectID: UUID(), connection: connection, directory: directory, mappings: []))
        #expect(preview.total == 2 && preview.files.count == 2)
        #expect(Set(preview.files.compactMap(\.size)) == [3, 6])
    }
    @Test @MainActor func lateConnectionPreviewCannotReplaceNewSelectionOrClosedDetails() async throws {
        let provider = DeferredConnectionPreviewProvider(), state = ConnectionPreviewSession()
        let first = request("first"), second = request("second")
        let a = Task { await state.load(first, provider: provider) }
        while !(await provider.started("first")) { await Task.yield() }
        let b = Task { await state.load(second, provider: provider) }
        while !(await provider.started("second")) { await Task.yield() }
        await provider.finish("first"); await a.value
        #expect(state.current(first) == nil && state.current(second) == nil)
        state.invalidate(); await provider.finish("second"); await b.value
        #expect(state.preview == nil && !state.busy && state.error == nil)
    }
    @Test @MainActor func recordCatalogRejectsLateRepliesAndInvalidPathIdentities() async {
        let provider = DeferredExternalRecordProvider(), state = ExternalRecordSession()
        let first = Task { await state.load(request("first"), provider: provider) }
        while provider.pending["first"] == nil { await Task.yield() }
        state.invalidate(); provider.pending.removeValue(forKey: "first")?.resume(returning: [.init(path: "/A/B/C/D/E/F/", dataType: "source", units: "m")]); await first.value
        #expect(state.records.isEmpty && state.error == nil)
        let second = Task { await state.load(request("second"), provider: provider) }
        while provider.pending["second"] == nil { await Task.yield() }
        let duplicate = ExternalRecord(path: "/A/B/C/D/E/F/", dataType: "source", units: "m")
        provider.pending.removeValue(forKey: "second")?.resume(returning: [duplicate, duplicate]); await second.value
        #expect(state.records.isEmpty && state.error != nil)
        await state.load(request("none"), provider: nil)
        #expect(state.records.isEmpty && state.error != nil && !state.loading)
    }
}
