import CryptoKit
import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

@Suite struct WorkspaceFileImportProviderTests {
    @Test func acceptsOnlyAContainedCoreHDFReceiptWithMatchingCopiedBytes() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("workspace-import-provider-\(UUID().uuidString)", isDirectory: true)
        let destination = root.appendingPathComponent("imports", isDirectory: true)
        let projectDirectory = destination.appendingPathComponent("Reach_91a5f2c3", isDirectory: true)
        let geometryDirectory = projectDirectory.appendingPathComponent("Geometries", isDirectory: true)
        try FileManager.default.createDirectory(at: geometryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let source = root.appendingPathComponent("Reach Geometry.h5")
        let project = projectDirectory.appendingPathComponent("Reach.ras")
        let asset = geometryDirectory.appendingPathComponent("Reach Geometry.h5")
        let bytes = Data("source-backed HDF bytes".utf8)
        try bytes.write(to: source)
        try bytes.write(to: asset)
        try Data("<Project />".utf8).write(to: project)
        let revision = Self.revision(bytes)
        let receipt = WorkspacePreparedProject(
            sourcePath: source.path,
            sourceRevision: revision,
            destinationDirectory: projectDirectory.path,
            projectPath: project.path,
            projectName: "Reach",
            importKind: "geometry",
            importedAssetPath: asset.path,
            importedAssetRevision: revision)

        try await WorkspaceFileImportProvider.validate(receipt: receipt, sourceURL: source,
            destinationDirectory: destination, sourceRevision: revision)
    }

    @Test func refusesReceiptOutsideChosenDestinationAndChangedSelectedSource() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("workspace-import-provider-\(UUID().uuidString)", isDirectory: true)
        let destination = root.appendingPathComponent("imports", isDirectory: true)
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        let outsideGeometry = outside.appendingPathComponent("Geometries", isDirectory: true)
        try FileManager.default.createDirectory(at: outsideGeometry, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let source = root.appendingPathComponent("Geometry.h5")
        let project = outside.appendingPathComponent("Geometry.ras")
        let asset = outsideGeometry.appendingPathComponent("Geometry.h5")
        let original = Data("original HDF".utf8)
        try original.write(to: source)
        try original.write(to: asset)
        try Data("<Project />".utf8).write(to: project)
        let revision = Self.revision(original)
        let escapedReceipt = WorkspacePreparedProject(
            sourcePath: source.path,
            sourceRevision: revision,
            destinationDirectory: outside.path,
            projectPath: project.path,
            projectName: "Geometry",
            importKind: "geometry",
            importedAssetPath: asset.path,
            importedAssetRevision: revision)

        do {
            try await WorkspaceFileImportProvider.validate(receipt: escapedReceipt, sourceURL: source,
                destinationDirectory: destination, sourceRevision: revision)
            Issue.record("A receipt outside the user-selected destination was accepted.")
        } catch {
            #expect(error as? WorkspaceFileImportError == .invalidReceipt)
        }

        try Data("changed HDF".utf8).write(to: source)
        do {
            try await WorkspaceFileImportProvider.validate(receipt: escapedReceipt, sourceURL: source,
                destinationDirectory: root, sourceRevision: revision)
            Issue.record("A selected source that changed during preparation was accepted.")
        } catch {
            #expect(error as? WorkspaceFileImportError == .sourceChanged)
        }
    }

    @Test func rejectsNonSourceHDFExtensionBeforeReceiptValidation() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("workspace-import-provider-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let source = root.appendingPathComponent("Geometry.hdf")
        try Data("HDF bytes".utf8).write(to: source)
        let provider = WorkspaceFileImportProvider(client: BackendProcessClient(executableURL: root.appendingPathComponent("missing")))

        do {
            _ = try await provider.prepare(sourceURL: source, destinationDirectory: root)
            Issue.record("A .hdf file outside the retained .h5 quick-open contract was accepted.")
        } catch {
            #expect(error as? WorkspaceFileImportError == .unsupportedExtension)
        }
    }

    @Test func cancelledPreparationCleanupRemovesOnlyItsContainedProjectFolder() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("workspace-import-cleanup-\(UUID().uuidString)", isDirectory: true)
        let destination = root.appendingPathComponent("imports", isDirectory: true)
        let imported = destination.appendingPathComponent("Reach_91a5f2c3", isDirectory: true)
        let project = imported.appendingPathComponent("Reach.ras")
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        let outsideProject = outside.appendingPathComponent("Outside.ras")
        try FileManager.default.createDirectory(at: imported, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("<Project />".utf8).write(to: project)
        try Data("<Project />".utf8).write(to: outsideProject)
        defer { try? FileManager.default.removeItem(at: root) }

        let receipt = WorkspacePreparedProject(sourcePath: "/source.zip", sourceRevision: String(repeating: "a", count: 64),
            destinationDirectory: imported.path, projectPath: project.path, projectName: "Reach",
            importKind: "archive", importedAssetPath: nil, importedAssetRevision: nil)
        WorkspaceFileImportProvider.removePreparedDirectory(receipt, destinationDirectory: destination)
        #expect(!FileManager.default.fileExists(atPath: imported.path))

        let escapedReceipt = WorkspacePreparedProject(sourcePath: "/source.zip", sourceRevision: String(repeating: "a", count: 64),
            destinationDirectory: outside.path, projectPath: outsideProject.path, projectName: "Outside",
            importKind: "archive", importedAssetPath: nil, importedAssetRevision: nil)
        WorkspaceFileImportProvider.removePreparedDirectory(escapedReceipt, destinationDirectory: destination)
        #expect(FileManager.default.fileExists(atPath: outside.path))
        #expect(FileManager.default.fileExists(atPath: outsideProject.path))
    }

    private static func revision(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02X", $0) }.joined()
    }
}
