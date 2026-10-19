import CryptoKit
import Foundation
import RASWorkspaceCore

struct WorkspaceArchiveImportRequest: Encodable, Sendable {
    let sourcePath: String
    let destinationDirectory: String
    let sourceRevision: String
}

struct WorkspaceCoreHDFImportRequest: Encodable, Sendable {
    let sourcePath: String
    let destinationDirectory: String
    let sourceRevision: String
}

private struct WorkspaceFileImportControl: Encodable, Sendable {
    let type = "cancel"
}

struct WorkspacePreparedProject: Decodable, Sendable {
    let sourcePath: String
    let sourceRevision: String
    let destinationDirectory: String
    let projectPath: String
    let projectName: String
    let importKind: String
    let importedAssetPath: String?
    let importedAssetRevision: String?

    var projectURL: URL { URL(fileURLWithPath: projectPath).standardizedFileURL }
}

/// Captures the selected input bytes before dispatch and asks the retained
/// backend to prepare a fresh project beside the destination the user chose.
struct WorkspaceFileImportProvider: Sendable {
    let client: BackendProcessClient

    func prepare(sourceURL: URL, destinationDirectory: URL) async throws -> WorkspacePreparedProject {
        guard sourceURL.isFileURL, destinationDirectory.isFileURL else {
            throw WorkspaceFileImportError.localFilesRequired
        }
        let source = sourceURL.standardizedFileURL
        let destination = destinationDirectory.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw WorkspaceFileImportError.destinationUnavailable
        }
        guard FileManager.default.isReadableFile(atPath: source.path) else {
            throw WorkspaceFileImportError.sourceUnavailable
        }

        let revision = try await Self.revision(of: source)
        try Task.checkCancellation()
        let operation: BackendDuplexOperation<WorkspaceFileImportControl,
            BackendProgressUpdate, WorkspacePreparedProject>
        switch source.pathExtension.lowercased() {
        case "zip":
            operation = try client.startDuplex("workspace.import.archive",
                parameters: WorkspaceArchiveImportRequest(sourcePath: source.path,
                    destinationDirectory: destination.path, sourceRevision: revision),
                control: WorkspaceFileImportControl.self, event: BackendProgressUpdate.self,
                as: WorkspacePreparedProject.self)
        case "h5":
            operation = try client.startDuplex("workspace.import.coreHdf",
                parameters: WorkspaceCoreHDFImportRequest(sourcePath: source.path,
                    destinationDirectory: destination.path, sourceRevision: revision),
                control: WorkspaceFileImportControl.self, event: BackendProgressUpdate.self,
                as: WorkspacePreparedProject.self)
        default:
            throw WorkspaceFileImportError.unsupportedExtension
        }
        let cancelSender = WorkspaceFileImportCancelSender(operation: operation)
        let validationCancellation = WorkspaceImportCancellationFlag()
        let importTask = Task.detached(priority: .userInitiated) {
            var eventError: (any Error)?
            do {
                for try await _ in operation.events { }
            } catch {
                eventError = error
            }
            let receipt = try await operation.value()
            if let eventError { throw eventError }
            do {
                try await Self.validate(receipt: receipt, sourceURL: source,
                    destinationDirectory: destination, sourceRevision: revision,
                    cancellation: validationCancellation)
            } catch let error as WorkspaceFileImportError where error == .sourceChanged {
                // The receipt has already passed path and copied-byte checks;
                // discard this request's isolated output if its input changed.
                Self.removePreparedDirectory(receipt, destinationDirectory: destination)
                throw error
            } catch is CancellationError {
                // Validation checks the receipt's contained paths before doing
                // cancellable byte verification, so this removes only a
                // structurally verified output created by this request.
                Self.removePreparedDirectory(receipt, destinationDirectory: destination)
                throw CancellationError()
            }
            return receipt
        }

        do {
            return try await withTaskCancellationHandler {
                let receipt = try await importTask.value
                guard !Task.isCancelled else {
                    Self.removePreparedDirectory(receipt, destinationDirectory: destination)
                    throw CancellationError()
                }
                return receipt
            } onCancel: {
                validationCancellation.cancel()
                cancelSender.cancel()
            }
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }

    static func validate(receipt: WorkspacePreparedProject, sourceURL: URL,
                         destinationDirectory: URL, sourceRevision: String,
                         cancellation: WorkspaceImportCancellationFlag? = nil) async throws {
        let source = sourceURL.standardizedFileURL
        let destination = destinationDirectory.standardizedFileURL
        let receiptSource = URL(fileURLWithPath: receipt.sourcePath).standardizedFileURL
        let returnedDestination = URL(fileURLWithPath: receipt.destinationDirectory).standardizedFileURL
        let returnedProject = receipt.projectURL

        guard source.isFileURL, destination.isFileURL,
              receiptSource.path == source.path,
              receipt.sourceRevision.caseInsensitiveCompare(sourceRevision) == .orderedSame,
              returnedProject.pathExtension.lowercased() == "ras",
              receipt.projectName == returnedProject.deletingPathExtension().lastPathComponent,
              !receipt.projectName.isEmpty else {
            throw WorkspaceFileImportError.invalidReceipt
        }

        let fileManager = FileManager.default
        let authorizedRoot = destination.resolvingSymlinksInPath().standardizedFileURL
        let importedDirectory = returnedDestination.resolvingSymlinksInPath().standardizedFileURL
        let projectPath = returnedProject.resolvingSymlinksInPath().standardizedFileURL.path
        let importedDirectoryValues = try? returnedDestination.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        let projectValues = try? returnedProject.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard importedDirectoryValues?.isDirectory == true,
              importedDirectoryValues?.isSymbolicLink != true,
              importedDirectory.deletingLastPathComponent().path == authorizedRoot.path,
              importedDirectory.path != authorizedRoot.path,
              projectPath.hasPrefix(importedDirectory.path + "/"),
              projectValues?.isRegularFile == true,
              projectValues?.isSymbolicLink != true,
              fileManager.isReadableFile(atPath: projectPath) else {
            throw WorkspaceFileImportError.invalidReceipt
        }

        switch (source.pathExtension.lowercased(), receipt.importKind) {
        case ("zip", "archive"):
            guard receipt.importedAssetPath == nil, receipt.importedAssetRevision == nil else {
                throw WorkspaceFileImportError.invalidReceipt
            }
        case ("h5", "result"), ("h5", "geometry"), ("h5", "boundaryCondition"):
            guard let assetPath = receipt.importedAssetPath,
                  let assetRevision = receipt.importedAssetRevision,
                  assetRevision.caseInsensitiveCompare(sourceRevision) == .orderedSame else {
                throw WorkspaceFileImportError.invalidReceipt
            }
            let asset = URL(fileURLWithPath: assetPath).standardizedFileURL
                .resolvingSymlinksInPath().standardizedFileURL
            let assetValues = try? asset.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            let expectedFolder: String
            switch receipt.importKind {
            case "result": expectedFolder = "Results"
            case "geometry": expectedFolder = "Geometries"
            default: expectedFolder = "Boundary Conditions"
            }
            guard asset.deletingLastPathComponent().lastPathComponent == expectedFolder,
                  asset.deletingLastPathComponent().deletingLastPathComponent().path == importedDirectory.path,
                  asset.path.hasPrefix(importedDirectory.path + "/"),
                  assetValues?.isRegularFile == true,
                  assetValues?.isSymbolicLink != true,
                  fileManager.isReadableFile(atPath: asset.path) else {
                throw WorkspaceFileImportError.invalidReceipt
            }
            let copiedRevision = try await Self.revision(of: asset, cancellation: cancellation)
            guard copiedRevision.caseInsensitiveCompare(sourceRevision) == .orderedSame else {
                throw WorkspaceFileImportError.invalidReceipt
            }
        default:
            throw WorkspaceFileImportError.invalidReceipt
        }

        // The selected input may have changed while the backend prepared a
        // new project. Verify it again before the Store installs the receipt.
        let currentSourceRevision = try await Self.revision(of: source, cancellation: cancellation)
        guard currentSourceRevision.caseInsensitiveCompare(sourceRevision) == .orderedSame else {
            throw WorkspaceFileImportError.sourceChanged
        }
        try cancellation?.throwIfCancelled()
        try Task.checkCancellation()
    }

    static func removePreparedDirectory(_ receipt: WorkspacePreparedProject,
                                        destinationDirectory: URL) {
        let root = destinationDirectory.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
        let directory = URL(fileURLWithPath: receipt.destinationDirectory).standardizedFileURL
            .resolvingSymlinksInPath().standardizedFileURL
        let directoryValues = try? directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        let project = receipt.projectURL.resolvingSymlinksInPath().standardizedFileURL
        let projectValues = try? project.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard directory != root,
              directory.deletingLastPathComponent().path == root.path,
              directoryValues?.isDirectory == true,
              directoryValues?.isSymbolicLink != true,
              project.path.hasPrefix(directory.path + "/"),
              projectValues?.isRegularFile == true,
              projectValues?.isSymbolicLink != true,
              receipt.projectName == project.deletingPathExtension().lastPathComponent else { return }
        try? FileManager.default.removeItem(at: directory)
    }

    private static func revision(of url: URL,
                                 cancellation suppliedCancellation: WorkspaceImportCancellationFlag? = nil) async throws -> String {
        let cancellation = suppliedCancellation ?? WorkspaceImportCancellationFlag()
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .utility) {
                try Self.revisionSynchronously(of: url, cancellation: cancellation)
            }.value
        } onCancel: {
            cancellation.cancel()
        }
    }

    private static func revisionSynchronously(of url: URL,
                                             cancellation: WorkspaceImportCancellationFlag) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            try Task.checkCancellation()
            try cancellation.throwIfCancelled()
            guard let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty else { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02X", $0) }.joined()
    }
}

private final class WorkspaceFileImportCancelSender: @unchecked Sendable {
    private let lock = NSLock()
    private let operation: BackendDuplexOperation<WorkspaceFileImportControl,
        BackendProgressUpdate, WorkspacePreparedProject>
    private var sequence: UInt64 = 0
    private var sent = false

    init(operation: BackendDuplexOperation<WorkspaceFileImportControl,
         BackendProgressUpdate, WorkspacePreparedProject>) {
        self.operation = operation
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        guard !sent else { return }
        sent = true
        sequence &+= 1
        try? operation.sendControl(WorkspaceFileImportControl(), sequence: sequence)
    }
}

final class WorkspaceImportCancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func throwIfCancelled() throws {
        if isCancelled { throw CancellationError() }
    }

    func cancel() {
        lock.lock()
        value = true
        lock.unlock()
    }
}

enum WorkspaceFileImportError: LocalizedError, Equatable {
    case localFilesRequired
    case destinationUnavailable
    case sourceUnavailable
    case sourceChanged
    case unsupportedExtension
    case invalidReceipt

    nonisolated var errorDescription: String? {
        messageKey
    }

    @MainActor var localizedMessage: String {
        L10n.text(messageKey)
    }

    nonisolated private var messageKey: String {
        switch self {
        case .localFilesRequired: "Choose a local source file and destination folder."
        case .destinationUnavailable: "The selected import destination is not an available folder."
        case .sourceUnavailable: "The selected import file cannot be read."
        case .sourceChanged: "The selected import file changed while it was being prepared."
        case .unsupportedExtension: "Choose a ZIP archive or HDF5 file."
        case .invalidReceipt: "The prepared project could not be verified."
        }
    }
}
