import AppKit
import Foundation
import RASWorkspaceCore

private struct WorkspaceUpdateCredentialsWire: Encodable, Sendable {
    let accessKey: String
    let secretKey: String
    init(_ credentials: WorkspaceS3Credentials) {
        accessKey = credentials.accessKey
        secretKey = credentials.secretKey
    }
}

private struct WorkspaceUpdateCatalogRequest: Encodable, Sendable {
    let channel: String
    let branch: String
    let installedVersion: String
    let debugMode: Bool
    let credentials: WorkspaceUpdateCredentialsWire?
}

private struct WorkspaceUpdateChoice: Decodable, Sendable {
    let id: String
    let title: String
    let debugOnly: Bool?
}

private struct WorkspaceUpdateReleaseWire: Decodable, Sendable {
    let id: String
    let version: String
    let publicationDate: String?
    let notes: String
    let notesUrl: URL?
    let platform: String
    let architecture: String
    let packageFilename: String?
    let packageSha256: String?
    let packageLength: Int64?
    let packageManifestKey: String?
    let packageStatus: String

    func release(channel: String, branch: String) -> AppRelease {
        AppRelease(id: id, version: version, publicationDate: Self.parseDate(publicationDate),
            notes: notes, notesURL: notesUrl, platform: platform, architecture: architecture,
            packageFilename: packageFilename, packageSHA256: packageSha256,
            packageLength: packageLength, packageManifestKey: packageManifestKey,
            packageStatus: packageStatus, channel: channel, branch: branch)
    }

    private static func parseDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return standard.date(from: value)
    }
}

private struct WorkspaceUpdateCatalogResponse: Decodable, Sendable {
    let channels: [WorkspaceUpdateChoice]
    let branches: [String]
    let selectedChannel: String
    let selectedBranch: String
    let canChangeChannel: Bool
    let hasDeveloperCredentials: Bool
    let credentialStatus: String
    let releases: [WorkspaceUpdateReleaseWire]
    let isUpToDate: Bool?
}

private struct WorkspaceUpdatePackagePrepareRequest: Encodable, Sendable {
    let channel: String
    let branch: String
    let debugMode: Bool
    let releaseId: String
    let packageManifestKey: String
    let packageFilename: String
    let packageSha256: String
    let credentials: WorkspaceUpdateCredentialsWire?
}

private struct WorkspaceUpdatePackageReceipt: Decodable, Sendable {
    let path: String
    let filename: String
    let sha256: String
    let length: Int64
    let platform: String
    let architecture: String
}

private enum BackendUpdateProviderError: LocalizedError {
    case requestAlreadyRunning
    case packageChanged
    case packageUnavailable

    var errorDescription: String? {
        switch self {
        case .requestAlreadyRunning: "An update package request is already running."
        case .packageChanged: "The prepared installer package no longer matches the selected release."
        case .packageUnavailable: "The installer package could not be opened."
        }
    }
}

@MainActor
private final class UpdateProgressRelay {
    let receive: @MainActor @Sendable (Double) -> Void
    init(receive: @escaping @MainActor @Sendable (Double) -> Void) { self.receive = receive }
    func deliver(_ update: BackendProgressUpdate) {
        guard let value = update.fraction, value.isFinite else { return }
        receive(min(max(value, 0), 1))
    }
}

/// Reads the retained updater's release manifests and downloads only an
/// explicitly identified macOS artifact. Opening the downloaded package does
/// not imply that Installer completed the update.
@MainActor
final class BackendUpdateProvider: UpdateProvider {
    private struct ActiveRequest {
        let id: UUID
        let task: Task<WorkspaceUpdatePackageReceipt, any Error>
    }

    private let client: BackendProcessClient
    private let debugMode: Bool
    private let credentials: @MainActor () -> WorkspaceS3Credentials?
    private let clearCredentialStorage: @MainActor () throws -> Void
    private let openFile: @MainActor (URL) -> Void
    private var activeRequest: ActiveRequest?

    init(client: BackendProcessClient? = nil, debugMode: Bool = false,
         credentials: @escaping @MainActor () -> WorkspaceS3Credentials? = { WorkspaceS3KeychainStore.shared.load() },
         clearCredentials: @escaping @MainActor () throws -> Void = { try WorkspaceS3KeychainStore.shared.delete() },
         openFile: @escaping @MainActor (URL) -> Void = { _ = NSWorkspace.shared.open($0) }) {
        self.client = client ?? BackendProcessClient(executableURL: Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/Backend/HECRASBackend"))
        self.debugMode = debugMode
        self.credentials = credentials
        self.clearCredentialStorage = clearCredentials
        self.openFile = openFile
    }

    func check(channel: String, branch: String) async throws -> UpdateSnapshot {
        let request = WorkspaceUpdateCatalogRequest(channel: channel, branch: branch,
            installedVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            debugMode: debugMode, credentials: credentials().map(WorkspaceUpdateCredentialsWire.init))
        let response = try await client.request("workspace.update.catalog", parameters: request,
            as: WorkspaceUpdateCatalogResponse.self)
        let credentialStatus: UpdateCredentialStatus
        switch response.credentialStatus {
        case "authenticated":
            let accessKey = credentials()?.accessKey ?? ""
            credentialStatus = .authenticated(account: "••••" + String(accessKey.suffix(4)))
        case "invalid": credentialStatus = .invalid
        case "notConfigured": credentialStatus = .notConfigured
        default: credentialStatus = .unknown
        }
        return UpdateSnapshot(channels: response.channels.map {
                EditorChoice(id: $0.id, title: $0.title, debugOnly: $0.debugOnly)
            }, branches: response.branches, selectedChannel: response.selectedChannel,
            selectedBranch: response.selectedBranch, canChangeChannel: response.canChangeChannel,
            hasDeveloperCredentials: response.hasDeveloperCredentials,
            releases: response.releases.map { $0.release(channel: response.selectedChannel, branch: response.selectedBranch) },
            isUpToDate: response.isUpToDate,
            credentialStatus: credentialStatus)
    }

    func install(_ release: AppRelease, progress: @escaping @MainActor @Sendable (Double) -> Void) async throws {
        guard activeRequest == nil else { throw BackendUpdateProviderError.requestAlreadyRunning }
        guard release.isCompatible, let packageManifestKey = release.packageManifestKey,
              let packageFilename = release.packageFilename, let packageSHA256 = release.packageSHA256,
              release.packageLength != nil else { throw BackendUpdateProviderError.packageUnavailable }
        let request = WorkspaceUpdatePackagePrepareRequest(channel: release.channel,
            branch: release.branch, debugMode: debugMode, releaseId: release.id,
            packageManifestKey: packageManifestKey, packageFilename: packageFilename,
            packageSha256: packageSHA256,
            credentials: credentials().map(WorkspaceUpdateCredentialsWire.init))
        let relay = UpdateProgressRelay(receive: progress)
        let operationID = UUID()
        let task = Task {
            try await client.request("workspace.update.package.prepare", parameters: request,
                as: WorkspaceUpdatePackageReceipt.self, reportsJob: true) { update in
                    Task { @MainActor in relay.deliver(update) }
                }
        }
        activeRequest = ActiveRequest(id: operationID, task: task)
        defer {
            if activeRequest?.id == operationID { activeRequest = nil }
        }

        let receipt = try await task.value
        try Task.checkCancellation()
        let preparedURL = URL(fileURLWithPath: receipt.path).standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        let attributes = try? FileManager.default.attributesOfItem(atPath: preparedURL.path)
        guard preparedURL.isFileURL, FileManager.default.fileExists(atPath: preparedURL.path, isDirectory: &isDirectory),
              !isDirectory.boolValue, (attributes?[.size] as? NSNumber)?.int64Value == receipt.length,
              receipt.sha256.caseInsensitiveCompare(packageSHA256) == .orderedSame,
              receipt.filename == URL(fileURLWithPath: packageFilename).lastPathComponent,
              receipt.platform == "macOS", receipt.architecture == release.architecture,
              receipt.length == release.packageLength,
              ["pkg", "dmg"].contains(preparedURL.pathExtension.lowercased()) else {
            throw BackendUpdateProviderError.packageChanged
        }
        try Task.checkCancellation()
        openFile(preparedURL)
        progress(1)
    }

    func cancel() async throws {
        guard let activeRequest else { return }
        activeRequest.task.cancel()
        do { _ = try await activeRequest.task.value }
        catch is CancellationError { return }
    }

    func clearCredentials() async throws {
        try clearCredentialStorage()
    }
}
