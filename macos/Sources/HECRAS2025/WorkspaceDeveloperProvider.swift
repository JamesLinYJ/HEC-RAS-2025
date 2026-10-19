import CryptoKit
import Foundation
import RASWorkspaceCore

struct DeveloperProjectArchiveRequest: Encodable, Sendable {
    let projectPath: String
    let includeResults: Bool
    let expectedProjectSHA256: String
}

struct DeveloperProjectArchiveControl: Encodable, Sendable {
    let type: String
    static let cancel = Self(type: "cancel")
}

struct DeveloperProjectArchiveArtifact: Decodable, Sendable {
    let state: String?
    let cleanupToken: String
    let archivePath: String
    let projectPath: String
    let sourceProjectSHA256: String
    let projectSHA256: String
    let inventorySHA256: String
    let entryCount: Int
    let includeResults: Bool
}

struct DeveloperProjectArchiveCleanupRequest: Encodable, Sendable {
    let cleanupToken: String
}

private struct DeveloperProjectArchiveCleanupResponse: Decodable, Sendable {
    let cleaned: Bool
}

private final class DeveloperJobCancellationHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var action: (@Sendable () -> Bool)?

    func install(_ action: @escaping @Sendable () -> Bool) {
        lock.withLock { self.action = action }
    }

    func cancel() -> Bool { lock.withLock { action }?() ?? false }
}

@MainActor
final class WorkspaceDeveloperProvider: DeveloperProvider {
    private let credentials: any WorkspaceS3CredentialStoring
    private let jobs: WorkspaceJobRegistry
    private let backend: BackendProcessClient
    private var storage: DeveloperS3Storage?
    private let logger = WorkspaceDeveloperLogCenter.shared

    init(credentials: any WorkspaceS3CredentialStoring = WorkspaceS3KeychainStore.shared,
         jobs: WorkspaceJobRegistry = .shared,
         backend: BackendProcessClient? = nil) {
        self.credentials = credentials
        self.jobs = jobs
        self.backend = backend ?? BackendProcessClient(executableURL: Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/Backend/HECRASBackend"))
    }

    func load() async throws -> DeveloperSnapshot {
        guard let saved = credentials.load(), !saved.accessKey.isEmpty, !saved.secretKey.isEmpty else {
            storage = nil
            return DeveloperSnapshot(authenticated: false, models: [])
        }
        let candidate = DeveloperS3Storage(credentials: saved)
        guard await candidate.isAuthenticated() else {
            storage = nil
            return DeveloperSnapshot(authenticated: false, models: [])
        }
        storage = candidate
        return DeveloperSnapshot(authenticated: true, models: await models(using: candidate))
    }

    func authenticate(key: String, secret: String) async throws -> DeveloperSnapshot {
        let accessKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !accessKey.isEmpty, !secret.isEmpty else {
            throw WorkspaceDeveloperServiceError.missingCredentials
        }
        let candidate = DeveloperS3Storage(credentials: WorkspaceS3Credentials(accessKey: accessKey, secretKey: secret))
        guard await candidate.isAuthenticated() else { throw WorkspaceDeveloperServiceError.authenticationFailed }
        try credentials.save(WorkspaceS3Credentials(accessKey: accessKey, secretKey: secret))
        storage = candidate
        logger.log("S3 credentials authenticated.", severity: .information, operation: "Authentication")
        return DeveloperSnapshot(authenticated: true, models: await models(using: candidate))
    }

    func perform(_ operation: DeveloperOperation,
                 progress: @escaping @MainActor @Sendable (Double?, String) -> Void) async throws -> DeveloperResult {
        let client = try await activeStorage()
        do {
            switch operation {
            case .generateUploadURL(let rawKey):
                let key = sanitizeS3Key(rawKey)
                guard !key.isEmpty else { throw WorkspaceDeveloperServiceError.invalidKey }
                let exists = try await client.objectExists(key)
                guard !exists else { throw WorkspaceDeveloperServiceError.keyExists }
                let url = try await client.presignedUploadURL(for: key)
                logger.log("Generated upload URL for model ID \(key).", severity: .information)
                return DeveloperResult(snapshot: nil, projectURL: nil,
                    clipboardText: url.absoluteString,
                    message: L10n.format("Upload URL generated for %@.", key))

            case .uploadProject(let rawKey, let projectURL, let includeResults):
                return try await uploadProject(key: sanitizeS3Key(rawKey), projectURL: projectURL,
                    includeResults: includeResults, storage: client, progress: progress)

            case .openModel(let key):
                return try await downloadModel(key: key, storage: client, progress: progress)

            case .rename(let key, let newKey):
                let destination = newKey.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !key.isEmpty, !destination.isEmpty else { throw WorkspaceDeveloperServiceError.invalidKey }
                try await client.move(key, to: destination)
                return DeveloperResult(snapshot: await refreshedSnapshot(client), projectURL: nil,
                    clipboardText: nil, message: L10n.format("Renamed %@ to %@.", key, destination))

            case .delete(let key, let isFolder, _):
                let keys: [String]
                if isFolder {
                    let prefix = key.hasSuffix("/") ? key : key + "/"
                    keys = try await client.listObjects(prefix: prefix).map(\.key)
                } else { keys = [key] }
                guard !keys.isEmpty else {
                    return DeveloperResult(snapshot: await refreshedSnapshot(client), projectURL: nil,
                        clipboardText: nil, message: L10n.format("No objects were found under %@.", key))
                }
                for (index, objectKey) in keys.enumerated() {
                    try await client.delete(objectKey)
                    progress(Double(index + 1) / Double(keys.count) * 100,
                        L10n.format("Deleting object %d of %d", index + 1, keys.count))
                }
                return DeveloperResult(snapshot: await refreshedSnapshot(client), projectURL: nil,
                    clipboardText: nil, message: L10n.format("Deleted %d object(s).", keys.count))

            case .copyPrefix(let oldPrefix, let newPrefix):
                let source = oldPrefix.hasSuffix("/") ? oldPrefix : oldPrefix + "/"
                let destination = newPrefix.hasSuffix("/") ? newPrefix : newPrefix + "/"
                guard !oldPrefix.isEmpty, !newPrefix.isEmpty,
                      !source.hasPrefix(destination), !destination.hasPrefix(source) else {
                    throw WorkspaceDeveloperServiceError.invalidKey
                }
                let objects = try await client.listObjects(prefix: source)
                for (index, object) in objects.enumerated() {
                    let suffix = String(object.key.dropFirst(source.count))
                    try await client.copy(object.key, to: destination + suffix)
                    progress(Double(index + 1) / Double(max(1, objects.count)) * 100,
                        L10n.format("Copying object %d of %d", index + 1, objects.count))
                }
                return DeveloperResult(snapshot: await refreshedSnapshot(client), projectURL: nil,
                    clipboardText: nil, message: L10n.format("Copied %d object(s).", objects.count))
            }
        } catch {
            if !(error is CancellationError), !(error is BackendServiceError) {
                logger.log(error.localizedDescription, severity: .error, operation: "Developer Storage")
            }
            throw error
        }
    }

    private func activeStorage() async throws -> DeveloperS3Storage {
        if let storage, await storage.isAuthenticated() { return storage }
        guard let saved = credentials.load(), !saved.accessKey.isEmpty, !saved.secretKey.isEmpty else {
            throw WorkspaceDeveloperServiceError.missingCredentials
        }
        let candidate = DeveloperS3Storage(credentials: saved)
        guard await candidate.isAuthenticated() else { throw WorkspaceDeveloperServiceError.authenticationFailed }
        storage = candidate
        return candidate
    }

    private func models(using client: DeveloperS3Storage) async -> [DeveloperModel] {
        do {
            let objects: [S3ObjectRecord]
            do { objects = try await client.listObjects() }
            catch { objects = try await client.listObjects(prefix: "class/") }
            return DeveloperModelTree.build(objects)
        } catch {
            logger.log(error.localizedDescription, severity: .error, operation: "Model Library")
            return []
        }
    }

    private func refreshedSnapshot(_ client: DeveloperS3Storage) async -> DeveloperSnapshot {
        DeveloperSnapshot(authenticated: true, models: await models(using: client))
    }

    private func uploadProject(key: String, projectURL: URL, includeResults: Bool,
                               storage: DeveloperS3Storage,
                               progress: @escaping @MainActor @Sendable (Double?, String) -> Void) async throws -> DeveloperResult {
        guard !key.isEmpty else { throw WorkspaceDeveloperServiceError.invalidKey }
        guard projectURL.isFileURL, projectURL.pathExtension.lowercased() == "ras",
              FileManager.default.isReadableFile(atPath: projectURL.path) else {
            throw WorkspaceDeveloperServiceError.archiveUnavailable
        }
        let canonicalProject = projectURL.standardizedFileURL.resolvingSymlinksInPath()
        let expectedSHA = try Self.sha256(of: canonicalProject)
        let cancellation = DeveloperJobCancellationHandle()
        let jobID = jobs.beginSourceJob(name: L10n.format("Uploading model ID %@", key),
            cancel: { cancellation.cancel() })
        var artifact: DeveloperProjectArchiveArtifact?
        do {
            let request = DeveloperProjectArchiveRequest(projectPath: canonicalProject.path,
                includeResults: includeResults, expectedProjectSHA256: expectedSHA)
            let archiveOperation = try backend.startDuplex("developer.projectArchive.prepare",
                parameters: request, control: DeveloperProjectArchiveControl.self,
                event: BackendProgressUpdate.self, as: DeveloperProjectArchiveArtifact.self,
                reportsJob: false)
            cancellation.install { archiveOperation.requestSourceCancellation() }
            for try await update in archiveOperation.events {
                if let fraction = update.fraction {
                    let percentage = min(max(fraction, 0), 1) * 25
                    jobs.updateSourceJob(jobID, fraction: percentage / 100,
                        message: update.message.map(L10n.text) ?? update.taskName.map(L10n.text))
                    progress(percentage, update.message ?? update.taskName ?? "Preparing project archive…")
                }
            }
            let prepared = try await archiveOperation.value()
            // Keep the opaque capability as soon as it arrives so every
            // validation failure after this point can still ask the host to
            // clean up its own artifact. The native side never deletes the
            // returned path directly.
            artifact = prepared
            if prepared.state?.lowercased() == "cancelled" {
                await cleanup(prepared)
                artifact = nil
                throw CancellationError()
            }
            guard prepared.projectPath == canonicalProject.path,
                  prepared.sourceProjectSHA256.caseInsensitiveCompare(expectedSHA) == .orderedSame,
                  Self.isSHA256(prepared.projectSHA256),
                  prepared.includeResults == includeResults,
                  prepared.entryCount >= 1,
                  Self.isSHA256(prepared.inventorySHA256),
                  UUID(uuidString: prepared.cleanupToken) != nil else {
                throw WorkspaceDeveloperServiceError.archiveMismatch
            }
            let archiveURL = try Self.validatedArchiveURL(path: prepared.archivePath,
                cleanupToken: prepared.cleanupToken)
            let archiveValues = try archiveURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard archiveURL.isFileURL, archiveValues.isRegularFile == true,
                  archiveValues.isSymbolicLink != true, (archiveValues.fileSize ?? 0) > 0,
                  FileManager.default.isReadableFile(atPath: archiveURL.path) else {
                throw WorkspaceDeveloperServiceError.archiveUnavailable
            }

            let uploadTask = Task {
                try await storage.upload(archiveURL, to: key, owner: "anonymous",
                    progress: { fraction, message in
                        Task { @MainActor in
                            let bounded = fraction.map { min(max($0, 0), 1) }
                            let overall = bounded.map { 25 + ($0 * 75) }
                            self.jobs.updateSourceJob(jobID, fraction: overall.map { $0 / 100 },
                                message: message)
                            progress(overall, message)
                        }
                    })
            }
            cancellation.install { uploadTask.cancel(); return true }
            try await uploadTask.value
            jobs.finishSourceJob(jobID, succeeded: true, message: L10n.text("Upload completed."))
            progress(100, "Upload completed.")
            logger.log("Uploaded project with ID \(key).", severity: .information)
            await cleanup(prepared)
            return DeveloperResult(snapshot: nil, projectURL: nil, clipboardText: key,
                message: L10n.format("Uploaded project with ID %@.", key))
        } catch {
            let cancelled = error is CancellationError || Task.isCancelled
            jobs.finishSourceJob(jobID, succeeded: false, cancelled: cancelled,
                message: L10n.text(error.localizedDescription))
            if !(error is BackendServiceError), !cancelled {
                logger.log(L10n.text(error.localizedDescription), severity: .error,
                    operation: "Project Upload")
            }
            if let artifact { await cleanup(artifact) }
            throw error
        }
    }

    private func downloadModel(key: String, storage: DeveloperS3Storage,
                               progress: @escaping @MainActor @Sendable (Double?, String) -> Void) async throws -> DeveloperResult {
        guard !key.isEmpty else { throw WorkspaceDeveloperServiceError.invalidKey }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "HECRAS2025-DeveloperDownloads", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(UUID().uuidString + ".zip")
        let cancellation = DeveloperJobCancellationHandle()
        let jobID = jobs.beginSourceJob(name: L10n.format("Downloading model ID %@", key),
            cancel: { cancellation.cancel() })
        let transfer = Task {
            try await storage.download(key, to: destination, progress: { fraction, message in
                Task { @MainActor in progress(fraction.map { $0 * 100 }, message) }
            })
        }
        cancellation.install { transfer.cancel(); return true }
        do {
            try await transfer.value
            let values = try destination.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true, (values.fileSize ?? 0) > 0 else {
                throw WorkspaceDeveloperServiceError.modelNotFound
            }
            jobs.finishSourceJob(jobID, succeeded: true, message: L10n.text("Download completed."))
            logger.log("Downloaded model with ID \(key).", severity: .information)
            return DeveloperResult(snapshot: nil, projectURL: destination, clipboardText: nil,
                message: L10n.format("Downloaded model with ID %@.", key))
        } catch {
            let cancelled = error is CancellationError || Task.isCancelled
            jobs.finishSourceJob(jobID, succeeded: false, cancelled: cancelled,
                message: L10n.text(error.localizedDescription))
            if !cancelled {
                logger.log(L10n.text(error.localizedDescription), severity: .error,
                    operation: "Model Download")
            }
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    private func cleanup(_ artifact: DeveloperProjectArchiveArtifact) async {
        do {
            let _: DeveloperProjectArchiveCleanupResponse = try await backend.request(
                "developer.projectArchive.cleanup",
                parameters: DeveloperProjectArchiveCleanupRequest(cleanupToken: artifact.cleanupToken))
        } catch {
            logger.log(error.localizedDescription, severity: .warning, operation: "Project Archive Cleanup")
        }
    }

    private func sanitizeS3Key(_ key: String) -> String {
        key.replacingOccurrences(of: " ", with: "-").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func sha256(of fileURL: URL) throws -> String {
        let stream = InputStream(url: fileURL)
        guard let stream else { throw WorkspaceDeveloperServiceError.archiveUnavailable }
        stream.open()
        defer { stream.close() }
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 256 * 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 { throw stream.streamError ?? WorkspaceDeveloperServiceError.archiveUnavailable }
            if count == 0 { break }
            hasher.update(data: Data(buffer.prefix(count)))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isHexDigit }
    }

    private static func validatedArchiveURL(path: String, cleanupToken: String) throws -> URL {
        guard let token = UUID(uuidString: cleanupToken) else {
            throw WorkspaceDeveloperServiceError.archiveMismatch
        }
        let archive = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        let archiveRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("HECRAS2025-DeveloperArchives", isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        let expectedName = token.uuidString.lowercased() + ".zip"
        guard archive.isFileURL,
              archive.deletingLastPathComponent().path == archiveRoot.path,
              archive.lastPathComponent.lowercased() == expectedName else {
            throw WorkspaceDeveloperServiceError.archiveMismatch
        }
        return archive
    }
}

private enum DeveloperModelTree {
    private final class Node {
        let key: String
        let name: String
        var isFolder: Bool
        var size: Int64?
        var owner: String
        var children: [String: Node] = [:]

        init(key: String, name: String, isFolder: Bool, size: Int64? = nil, owner: String = "") {
            self.key = key; self.name = name; self.isFolder = isFolder; self.size = size; self.owner = owner
        }
    }

    static func build(_ objects: [S3ObjectRecord]) -> [DeveloperModel] {
        var roots: [String: Node] = [:]
        for object in objects where !object.key.isEmpty {
            let parts = object.key.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            guard !parts.isEmpty else { continue }
            var pathParts: [String] = []
            var parent: Node?
            for (index, part) in parts.enumerated() {
                pathParts.append(part)
                let key = pathParts.joined(separator: "/")
                let isLeaf = index == parts.count - 1
                    && !object.key.hasSuffix("/")
                let dictionaryKey = part.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                let node: Node
                let existing = parent?.children[dictionaryKey] ?? (parent == nil ? roots[dictionaryKey] : nil)
                if let existing {
                    node = existing
                    if isLeaf {
                        node.isFolder = false; node.size = object.size; node.owner = object.owner
                    }
                } else {
                    node = Node(key: key, name: part, isFolder: !isLeaf,
                        size: isLeaf ? object.size : nil, owner: isLeaf ? object.owner : "")
                    if let parent { parent.children[dictionaryKey] = node }
                    else { roots[dictionaryKey] = node }
                }
                parent = node
            }
        }
        return roots.values.map(model).sorted(by: order)
    }

    private static func model(_ node: Node) -> DeveloperModel {
        let children = node.children.values.map(model).sorted(by: order)
        let fileCount = node.isFolder ? children.reduce(0) { $0 + $1.fileCount } : 1
        return DeveloperModel(key: node.key, name: node.name, isFolder: node.isFolder,
            size: node.isFolder ? nil : node.size, uploader: node.owner,
            fileCount: fileCount, children: node.isFolder ? children : nil)
    }

    private static func order(_ left: DeveloperModel, _ right: DeveloperModel) -> Bool {
        if left.isFolder != right.isFolder { return left.isFolder }
        let compared = left.name.localizedStandardCompare(right.name)
        if compared != .orderedSame { return compared == .orderedAscending }
        return left.key < right.key
    }
}
