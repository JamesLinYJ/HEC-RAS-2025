import CryptoKit
import Combine
import Foundation
import RASWorkspaceCore
import SwiftUI

enum CatalogModelActionDigest {
    static func fileRevision(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        return SHA256.hash(data: data).map { String(format: "%02X", $0) }.joined()
    }

    static func textFingerprint(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02X", $0) }.joined()
    }

    static func canonical(_ url: URL) -> String {
        SourceFilePaths.canonical(url)
    }
}

private struct CatalogModelActionLoadIdentity: Hashable, Sendable {
    let assetID: String
    let kind: String
    let projectPath: String?
    let projectXML: String?
    let projectSessionID: UUID
    let assetsRevision: Int
    let coreLayerContext: CoreLayerRequestContext?
}

@MainActor
final class CatalogModelActionSession: ObservableObject {
    @Published private(set) var inspection: CatalogModelActionInspection?
    @Published private(set) var isLoading = false
    @Published private(set) var isPerforming = false
    @Published private(set) var error: String?
    private let provider: BackendCatalogModelActionProvider?
    private var requestRevision = 0
    private var requestIdentity: CatalogModelActionLoadIdentity?

    init(provider: BackendCatalogModelActionProvider?) { self.provider = provider }

    func inspect(asset: ProjectAsset, kind: String, projectPath: URL,
                 projectXML: String, projectSessionID: UUID, assetsRevision: Int,
                 coreLayerContext: CoreLayerRequestContext?) async {
        requestRevision += 1
        let generation = requestRevision
        let identity = CatalogModelActionLoadIdentity(assetID: asset.id, kind: kind,
            projectPath: CatalogModelActionDigest.canonical(projectPath), projectXML: projectXML,
            projectSessionID: projectSessionID, assetsRevision: assetsRevision,
            coreLayerContext: coreLayerContext)
        requestIdentity = identity
        inspection = nil; error = nil; isLoading = true
        defer { if generation == requestRevision { isLoading = false } }
        guard let provider else {
            error = L10n.text("Catalog model actions are unavailable.")
            return
        }
        do {
            let url = asset.url
            let revision = try await Task.detached(priority: .userInitiated) {
                try CatalogModelActionDigest.fileRevision(url)
            }.value
            let request = CatalogModelActionRequest(projectPath: projectPath.path,
                projectXml: projectXML, assetPath: asset.url.path, kind: kind,
                expectedAssetSHA: revision, action: "inspect", name: nil,
                coreLayerContext: coreLayerContext)
            let snapshot = try await provider.inspect(request)
            guard generation == requestRevision, !Task.isCancelled,
                  requestIdentity == identity else { return }
            guard snapshot.kind == kind, snapshot.revision == revision,
                  snapshot.canonicalAssetPath == CatalogModelActionDigest.canonical(asset.url) else {
                throw CatalogModelActionPresentationError.changed
            }
            inspection = snapshot
        } catch {
            guard generation == requestRevision, !Task.isCancelled,
                  requestIdentity == identity else { return }
            self.error = L10n.text(error.localizedDescription)
        }
    }

    func perform(asset: ProjectAsset, kind: String, projectPath: URL,
                 projectXML: String, projectSessionID: UUID, assetsRevision: Int,
                 coreLayerContext: CoreLayerRequestContext?,
                 action: String, name: String?) async throws -> CatalogModelActionReceipt {
        guard let provider else { throw CatalogModelActionPresentationError.unavailable }
        let identity = CatalogModelActionLoadIdentity(assetID: asset.id, kind: kind,
            projectPath: CatalogModelActionDigest.canonical(projectPath), projectXML: projectXML,
            projectSessionID: projectSessionID, assetsRevision: assetsRevision,
            coreLayerContext: coreLayerContext)
        guard requestIdentity == identity,
              let inspection,
              inspection.kind == kind,
              inspection.assetPath == asset.url.path,
              CatalogModelActionDigest.canonical(URL(fileURLWithPath: inspection.projectPath))
                == CatalogModelActionDigest.canonical(projectPath) else {
            throw CatalogModelActionPresentationError.changed
        }
        isPerforming = true
        defer { isPerforming = false }
        let url = asset.url
        let diskRevision = try await Task.detached(priority: .userInitiated) {
            try CatalogModelActionDigest.fileRevision(url)
        }.value
        guard diskRevision == inspection.revision else {
            throw CatalogModelActionPresentationError.changed
        }
        let request = CatalogModelActionRequest(projectPath: projectPath.path,
            projectXml: projectXML, assetPath: asset.url.path, kind: kind,
            expectedAssetSHA: inspection.revision, action: action, name: name,
            coreLayerContext: coreLayerContext)
        return try await provider.perform(request)
    }

    func cleanup(_ receipt: CatalogModelActionReceipt) async { await provider?.cleanup(receipt) }

    func clearError() { error = nil }

    func invalidate() {
        requestRevision += 1
        requestIdentity = nil
        inspection = nil
        error = nil
        isLoading = false
        isPerforming = false
    }
}

private enum CatalogModelActionPresentationError: LocalizedError {
    case changed
    case unavailable
    var errorDescription: String? {
        switch self {
        case .changed: "The selected model changed. Refresh and try again."
        case .unavailable: "Catalog model actions are unavailable."
        }
    }
}

/// Action menu for a real, selected source model. The workspace owns the
/// atomic publication, XML-draft merge, and reversible Trash transaction.
struct CatalogModelActionBar: View {
    @ObservedObject var store: WorkspaceStore
    let asset: ProjectAsset
    let kind: String
    @StateObject private var session: CatalogModelActionSession
    @State private var actionError: String?

    init(asset: ProjectAsset, kind: String, store: WorkspaceStore) {
        self.asset = asset
        self.kind = kind
        self.store = store
        let provider = (store.modelProvider as? BackendModelProvider).map {
            BackendCatalogModelActionProvider(client: $0.client)
        }
        _session = StateObject(wrappedValue: CatalogModelActionSession(provider: provider))
    }

    private var projectURL: URL? { store.document?.url }
    private var projectXML: String? { store.document?.editorXML }
    private var actionLoadIdentity: CatalogModelActionLoadIdentity {
        CatalogModelActionLoadIdentity(assetID: asset.id, kind: kind,
            projectPath: projectURL.map(CatalogModelActionDigest.canonical),
            projectXML: projectXML, projectSessionID: store.projectSessionID,
            assetsRevision: store.assetsRevision,
            coreLayerContext: store.captureCoreLayerRequestContext())
    }
    private var availableActions: Set<String> { Set(session.inspection?.availableActions ?? []) }
    private var canManage: Bool {
        projectURL != nil && projectXML != nil && store.modelProvider is BackendModelProvider
            && !session.isLoading && !session.isPerforming && !store.isRunningProjectTool
            && !store.isSavingAll && !store.isClosingTab && !store.isOpeningProject
    }

    var body: some View {
        HStack(spacing: 8) {
            if session.isLoading || session.isPerforming {
                ProgressView().controlSize(.small)
                Text(session.isPerforming ? L10n.text("Applying model action…") : L10n.text("Checking model actions…"))
                    .font(.caption).foregroundStyle(.secondary)
            } else if canManage, session.inspection != nil, !availableActions.isEmpty {
                Menu {
                    if availableActions.contains("rename") {
                        Button("Rename…", systemImage: "pencil") {
                            present(.rename)
                        }
                    }
                    if availableActions.contains("clone") {
                        Button("Duplicate", systemImage: "plus.square.on.square") {
                            present(.clone)
                        }
                    }
                    if availableActions.contains("delete") {
                        Button("Delete…", systemImage: "trash", role: .destructive) {
                            present(.delete)
                        }
                    }
                } label: {
                    Label("Manage Model", systemImage: "ellipsis.circle")
                }
                .disabled(!canManage)
                Button {
                    Task { await refreshInspection() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help(L10n.text("Refresh model actions"))
                .disabled(session.isLoading || session.isPerforming)
            } else if canManage {
                Text(L10n.text("Catalog model actions are unavailable."))
                    .font(.caption).foregroundStyle(.secondary)
                Button {
                    Task { await refreshInspection() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help(L10n.text("Refresh model actions"))
                .disabled(session.isLoading || session.isPerforming)
            }
        }
        .task(id: actionLoadIdentity) {
            guard let projectURL, let projectXML else {
                session.invalidate()
                return
            }
            await session.inspect(asset: asset, kind: kind, projectPath: projectURL,
                projectXML: projectXML, projectSessionID: store.projectSessionID,
                assetsRevision: store.assetsRevision,
                coreLayerContext: store.captureCoreLayerRequestContext())
        }
        .alert("Catalog Action", isPresented: Binding(
            get: { actionError != nil || session.error != nil },
            set: { if !$0 { actionError = nil; session.clearError() } }
        )) {
            Button("OK") { actionError = nil; session.clearError() }
        } message: {
            Text(actionError ?? session.error ?? "")
        }
    }

    private func refreshInspection() async {
        guard let projectURL, let projectXML else {
            session.invalidate()
            return
        }
        await session.inspect(asset: asset, kind: kind, projectPath: projectURL,
            projectXML: projectXML, projectSessionID: store.projectSessionID,
            assetsRevision: store.assetsRevision,
            coreLayerContext: store.captureCoreLayerRequestContext())
    }

    private func present(_ intent: CatalogModelActionIntent) {
        guard let kind = CatalogManagedModelKind(rawValue: kind),
              let presentation = CatalogModelActionPresentation.make(asset: asset, kind: kind,
                    intent: intent, caller: .inspector, store: store) else {
            actionError = L10n.text("The selected model changed. Refresh and try again.")
            return
        }
        store.catalogModelActionPresentation = presentation
    }
}
