import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

struct TerrainUSGSImportCleanupTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"] != nil))
    @MainActor
    func rejectedOwnedCleanupRetainsFilesAndCanRetryThroughBundledBackend() async throws {
        let executable = try #require(ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"])
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("HECRAS-TerrainUSGSImports", isDirectory: true)
            .appendingPathComponent(token, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("owned-source.tmp")
        try Data("owned cleanup regression".utf8).write(to: source)
        let asset = folder.appendingPathComponent("terrain.hdf").path
        let project = folder.appendingPathComponent("project.ras").path
        let manifest = folder.appendingPathComponent("manifest.json")
        func writeManifest(assetPath: String) throws {
            let data = try JSONSerialization.data(withJSONObject: [
                "version": 1, "token": token, "assetPath": assetPath,
                "projectPath": project, "sourceRevision": String(repeating: "a", count: 64),
                "inputId": NSNull(), "files": []
            ])
            try data.write(to: manifest, options: .atomic)
        }
        try writeManifest(assetPath: folder.appendingPathComponent("other-terrain.hdf").path)
        let provider = BackendModelProvider(client: BackendProcessClient(
            executableURL: URL(fileURLWithPath: executable)))
        let editor = ModelEditorSession(provider: provider)
        let transfer = TerrainUSGSDownloadTransfer(cleanupToken: token, files: [],
            assetPath: asset, projectPath: project, sourceRevision: String(repeating: "a", count: 64),
            inputId: nil, extent: .init(minX: 0, maxX: 1, minY: 0, maxY: 1), stitchTiles: true)
        let cleanup = editor.terrainUSGSImportCleanup
        cleanup.enqueue(transfer, provider: provider, after: editor)
        try await waitUntil { cleanup.activeTokens.isEmpty }
        #expect(cleanup.warnings[token] != nil)
        #expect(FileManager.default.fileExists(atPath: source.path))
        try writeManifest(assetPath: asset)
        cleanup.retry(after: editor)
        try await waitUntil { cleanup.activeTokens.isEmpty }
        #expect(cleanup.warnings.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    @MainActor
    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(condition(), "The bundled cleanup operation must finish before the deadline.")
    }
}
