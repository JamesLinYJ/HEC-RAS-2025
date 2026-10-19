import Foundation
import RASWorkspaceCore
import Testing

struct BackendProjectMigrationTests {
    private struct InspectRequest: Encodable, Sendable {
        let sourcePath: String
        let destinationParentPath: String
    }
    private struct Inspection: Decodable, Sendable {
        let canExecute: Bool
        let sourcePath: String
        let projectName: String?
        let destinationPath: String?
        let revision: String?
        let validationMessage: String?
    }
    private struct ExecuteRequest: Encodable, Sendable {
        let sourcePath: String
        let destinationPath: String
        let revision: String
    }
    private struct MigrationResult: Decodable, Sendable {
        let projectPath: String
        let projectName: String
        let messages: [String]?
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"] != nil))
    func bundledConverterProducesReadableProjectAndRejectsChangedSourceBeforeWriting() async throws {
        let executable = try #require(ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"])
        let client = BackendProcessClient(executableURL: URL(fileURLWithPath: executable))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("v6-migration-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceDirectory = root.appendingPathComponent("源工程", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        let source = sourceDirectory.appendingPathComponent("旧工程.prj")
        // A minimal real v6 project format, with no referenced geometry or flow
        // files. This exercises the retained converter, not hydraulic parity.
        let original = Data("Proj Title=迁移验证\nCurrent Plan=\n\nSI Units\n".utf8)
        try original.write(to: source)
        let request = InspectRequest(sourcePath: source.path, destinationParentPath: root.path)
        let first = try await client.request("projectMigration.inspect", parameters: request, as: Inspection.self)
        #expect(first.canExecute && first.projectName == "迁移验证")
        let firstOutput = try #require(first.destinationPath)
        let firstRevision = try #require(first.revision)
        #expect(!FileManager.default.fileExists(atPath: firstOutput))

        try (original + Data("; changed after inspection\n".utf8)).write(to: source)
        do {
            _ = try await client.request("projectMigration.execute",
                parameters: ExecuteRequest(sourcePath: source.path, destinationPath: firstOutput, revision: firstRevision),
                as: MigrationResult.self)
            Issue.record("The bundled converter accepted a stale source revision.")
        } catch let error as BackendServiceError {
            #expect(error.code == "sourceChanged")
        }
        #expect(!FileManager.default.fileExists(atPath: firstOutput))
        try original.write(to: source)

        let inspected = try await client.request("projectMigration.inspect", parameters: request, as: Inspection.self)
        let output = try #require(inspected.destinationPath)
        let revision = try #require(inspected.revision)
        let progress = MigrationProgressRecorder()
        let converted = try await client.request("projectMigration.execute",
            parameters: ExecuteRequest(sourcePath: source.path, destinationPath: output, revision: revision),
            as: MigrationResult.self,
            progress: { progress.receive($0) })
        #expect(converted.messages?.contains(where: { $0.hasPrefix("Saved ") }) == true)
        #expect(progress.updates.contains(where: { $0.message?.hasPrefix("Saved ") == true }))
        let resultURL = URL(fileURLWithPath: converted.projectPath)
        let opened = try ProjectDocument(contentsOf: resultURL)
        #expect(opened.name == converted.projectName && opened.name == "迁移验证")
        #expect(opened.description.contains("Converted from"))
        #expect(try Data(contentsOf: source) == original)
        let projects = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: output),
            includingPropertiesForKeys: nil).filter { $0.pathExtension == "ras" }
        #expect(projects.count == 1)
        #expect(projects.first?.resolvingSymlinksInPath() == resultURL.resolvingSymlinksInPath())
    }
}

private final class MigrationProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedUpdates: [BackendProgressUpdate] = []

    var updates: [BackendProgressUpdate] { lock.withLock { storedUpdates } }

    func receive(_ update: BackendProgressUpdate) {
        lock.withLock { storedUpdates.append(update) }
    }
}
