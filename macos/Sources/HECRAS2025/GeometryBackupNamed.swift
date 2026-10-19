import CryptoKit
import Foundation
import RASWorkspaceCore
import SwiftUI

struct GeometryNamedBackupRequest: Encodable, Sendable {
    let projectPath: String
    let projectXml: String
    let expectedProjectRevision: String
    let geometryPath: String
    let geometryCanonicalPath: String
    let expectedGeometryRevision: String
    let name: String
}

struct GeometryNamedBackupReceipt: Decodable, Sendable {
    let projectPath: String
    let projectRevision: String
    let projectXmlFingerprint: String
    let geometryPath: String
    let geometryRevision: String
    let backupPath: String
    let backupRevision: String
}

@MainActor
final class GeometryNamedBackupProvider {
    let client: BackendProcessClient

    init(client: BackendProcessClient) {
        self.client = client
    }

    func create(_ request: GeometryNamedBackupRequest) async throws -> GeometryNamedBackupReceipt {
        try await client.request("geometry.backup.createNamed", parameters: request,
            as: GeometryNamedBackupReceipt.self)
    }
}

@MainActor
final class GeometryNamedBackupSession: ObservableObject {
    @Published private(set) var isBusy = false
    @Published private(set) var errorMessage: String?

    func createNamedBackup(name: String, geometry: ProjectAsset, store: WorkspaceStore) async -> String? {
        errorMessage = nil
        // The source prompt returns an empty string when canceled. The sheet's
        // Cancel action never calls this method, and empty acceptance is a no-op.
        guard !name.isEmpty else { return nil }
        guard !isBusy, geometry.section == .geometries, geometry.isModelFile,
              store.assets.contains(where: { $0.id == geometry.id && $0.section == .geometries }),
              let project = store.document, let projectURL = project.url,
              let projectRevision = project.sourceRevision,
              let client = (store.modelProvider as? BackendModelProvider)?.client else {
            errorMessage = L10n.text("Open a saved project and select a saved Geometry before creating a backup.")
            return nil
        }

        let projectSessionID = store.projectSessionID
        let projectXML = project.editorXML(overridingDescription: store.descriptionDraft)
        guard store.beginCatalogModelAction(assetID: geometry.id, projectSessionID: projectSessionID) else {
            errorMessage = L10n.text(store.errorMessage ?? "Finish the current project operation before creating a Geometry backup.")
            return nil
        }

        isBusy = true
        defer {
            isBusy = false
            store.endCatalogModelAction(projectSessionID: projectSessionID)
        }

        do {
            let geometryCanonicalPath = SourceFilePaths.canonical(geometry.url)
            let expectedGeometryRevision = try await Task.detached(priority: .userInitiated) {
                try GeometryBackupDigest.file(at: geometry.url.path)
            }.value
            guard isCurrent(store: store, geometry: geometry, projectSessionID: projectSessionID,
                            projectURL: projectURL, projectRevision: projectRevision, projectXML: projectXML) else {
                throw BackendServiceError(code: "sourceChanged", message: "Refresh the Geometry before creating a backup.")
            }

            let request = GeometryNamedBackupRequest(
                projectPath: projectURL.path,
                projectXml: projectXML,
                expectedProjectRevision: projectRevision,
                geometryPath: geometry.url.path,
                geometryCanonicalPath: geometryCanonicalPath,
                expectedGeometryRevision: expectedGeometryRevision,
                name: name
            )
            let receipt = try await GeometryNamedBackupProvider(client: client).create(request)
            guard isCurrent(store: store, geometry: geometry, projectSessionID: projectSessionID,
                            projectURL: projectURL, projectRevision: projectRevision, projectXML: projectXML),
                  SourceFilePaths.canonical(URL(fileURLWithPath: receipt.projectPath)) == SourceFilePaths.canonical(projectURL),
                  receipt.projectRevision == projectRevision,
                  receipt.projectXmlFingerprint == Self.sha256(projectXML),
                  SourceFilePaths.canonical(URL(fileURLWithPath: receipt.geometryPath)) == geometryCanonicalPath,
                  receipt.geometryRevision == expectedGeometryRevision,
                  Self.isSHA256(receipt.backupRevision) else {
                throw BackendServiceError(code: "protocolFailure", message: "The named Geometry backup reply does not match the selected source.")
            }

            let expectedBackupDirectory = geometry.url.deletingLastPathComponent()
                .appendingPathComponent(geometry.name + " Backups", isDirectory: true)
            let backupURL = URL(fileURLWithPath: receipt.backupPath).standardizedFileURL
            guard SourceFilePaths.canonical(backupURL.deletingLastPathComponent()) ==
                    SourceFilePaths.canonical(expectedBackupDirectory),
                  backupURL.pathExtension.lowercased() == "h5" else {
                throw BackendServiceError(code: "protocolFailure", message: "The named Geometry backup was not created in its source backup folder.")
            }
            let backupRevision = try await Task.detached(priority: .utility) {
                try GeometryBackupDigest.file(at: backupURL.path)
            }.value
            let geometryRevisionAfter = try await Task.detached(priority: .utility) {
                try GeometryBackupDigest.file(at: geometry.url.path)
            }.value
            guard backupRevision == receipt.backupRevision,
                  geometryRevisionAfter == expectedGeometryRevision else {
                throw BackendServiceError(code: "sourceChanged", message: "The Geometry or its new backup changed during the operation.")
            }

            guard let treeProvider = store.catalogTreeProvider else {
                throw BackendServiceError(code: "protocolFailure", message: "The Geometry backup was created, but the catalog tree is unavailable.")
            }
            await store.catalogTreeSession.load(provider: treeProvider, context: store.catalogTreeContext)
            guard isCurrent(store: store, geometry: geometry, projectSessionID: projectSessionID,
                            projectURL: projectURL, projectRevision: projectRevision, projectXML: projectXML),
                  store.catalogTreeSession.error == nil,
                  store.catalogTreeSession.roots?.contains(where: {
                      Self.containsBackup($0, path: backupURL)
                  }) == true else {
                throw BackendServiceError(code: "protocolFailure", message: "The named Geometry backup was created but could not be found after refreshing the catalog.")
            }

            store.log("Geometry Backup", String(format: L10n.text("Backup created: %@"), backupURL.path))
            return backupURL.path
        } catch is CancellationError {
            return nil
        } catch {
            let message = L10n.text(error.localizedDescription)
            errorMessage = message
            if store.projectSessionID == projectSessionID {
                store.errorMessage = message
                store.log("Geometry Backup", message, severity: .error)
                store.showMessages = true
            }
            return nil
        }
    }

    private func isCurrent(store: WorkspaceStore, geometry: ProjectAsset, projectSessionID: UUID,
        projectURL: URL, projectRevision: String, projectXML: String) -> Bool {
        store.projectSessionID == projectSessionID &&
            store.document?.url == projectURL && store.document?.sourceRevision == projectRevision &&
            store.document?.editorXML(overridingDescription: store.descriptionDraft) == projectXML &&
            store.assets.contains(where: { $0.id == geometry.id && $0.section == .geometries })
    }

    private static func containsBackup(_ node: LayerTreeNode, path: URL) -> Bool {
        if node.sourceClass == "BackupNodeVM", let summary = node.backupSummary,
           SourceFilePaths.canonical(URL(fileURLWithPath: summary.filename)) == SourceFilePaths.canonical(path) {
            return true
        }
        return node.children?.contains(where: { containsBackup($0, path: path) }) == true
    }

    private static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02X", $0) }.joined()
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy(\.isHexDigit)
    }
}

private enum GeometryBackupDigest {
    static func file(at path: String) throws -> String {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 128 * 1024), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02X", $0) }.joined()
    }
}

/// Native single-string ContentDialog equivalent used by the retained
/// SingleStringPrompt-style actions. Callers own validation and execution.
struct SingleStringPromptSheet: View {
    let title: String
    let subtitle: String?
    let prompt: String
    let actionTitle: String
    @Binding var value: String
    var isWorking = false
    var errorMessage: String?
    var actionEnabled = true
    let onCancel: () -> Void
    let onAction: (String) -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            WorkspaceDialogHeader(title: title, subtitle: subtitle, symbol: "text.cursor")
                .padding(20)
            Divider()
            Form {
                Section {
                    TextField(LocalizedStringKey(prompt), text: $value)
                        .focused($isFocused)
                        .onSubmit(submit)
                    if isWorking { ProgressView().controlSize(.small) }
                    if let errorMessage { WorkspaceDialogNotice(message: errorMessage, isError: true) }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .disabled(isWorking)
                Button(LocalizedStringKey(actionTitle), action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!actionEnabled || isWorking)
                    .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(minWidth: 420, idealWidth: 500, maxWidth: 560, minHeight: 220, idealHeight: 270, maxHeight: 360)
        .onAppear { isFocused = true }
    }

    private func submit() {
        guard actionEnabled, !isWorking else { return }
        onAction(value)
    }
}

struct GeometryNamedBackupSheet: View {
    @ObservedObject var store: WorkspaceStore
    let geometry: ProjectAsset
    var onCreated: @MainActor (String) -> Void = { _ in }
    @Environment(\.dismiss) private var dismiss
    @StateObject private var session = GeometryNamedBackupSession()
    @State private var name = ""

    var body: some View {
        SingleStringPromptSheet(
            title: "Create Named Geometry Backup",
            subtitle: "Save a named copy of the selected Geometry.",
            prompt: "Name?",
            actionTitle: "Create Backup",
            value: $name,
            isWorking: session.isBusy,
            errorMessage: session.errorMessage,
            actionEnabled: !name.isEmpty,
            onCancel: { dismiss() },
            onAction: create
        )
    }

    private func create(_ value: String) {
        Task { @MainActor in
            guard let backupPath = await session.createNamedBackup(name: value, geometry: geometry, store: store) else { return }
            onCreated(backupPath)
            dismiss()
        }
    }
}
