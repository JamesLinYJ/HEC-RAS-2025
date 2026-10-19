import Foundation
import RASWorkspaceCore
import SwiftUI

/// Actions available for an inspected, current-project Result. The destructive
/// action revalidates the source HDF immediately before moving that exact file
/// to the macOS Trash; the workspace owns post-Trash map/tree/session cleanup.
struct ResultInspectorActions: View {
    let asset: ProjectAsset
    @ObservedObject var inspector: ResultInspectorSession
    @ObservedObject var store: WorkspaceStore

    @State private var showingTrashConfirmation = false
    @State private var isWorking = false
    @State private var actionError: String?

    private var snapshot: ResultInspectorSnapshot? { inspector.snapshot }
    private var projectXML: String? {
        guard let document = store.document else { return nil }
        return document.editorXML(overridingDescription: store.descriptionDraft)
    }
    private var canMoveToTrash: Bool {
        guard asset.section == .results, let snapshot,
              let projectPath = store.document?.url, projectXML != nil else { return false }
        return snapshot.resultPath == Self.canonical(asset.url)
            && !isWorking && !store.isSavingAll && !store.isClosingTab && !store.isRunningProjectTool
            && projectPath.isFileURL
    }

    var body: some View {
        HStack(spacing: 10) {
            Button {
                store.locateResult(asset: asset)
            } label: {
                Label(L10n.text("Locate in Catalog"), systemImage: "scope")
            }
            .disabled(asset.section != .results || !store.assets.contains(asset)
                || store.isOpeningProject || store.isClosingTab)

            Spacer(minLength: 0)

            Button(role: .destructive) {
                showingTrashConfirmation = true
            } label: {
                Label(L10n.text("Move to Trash…"), systemImage: "trash")
            }
            .disabled(!canMoveToTrash)
        }
        .confirmationDialog(L10n.text("Move Result to Trash?"), isPresented: $showingTrashConfirmation,
                            titleVisibility: .visible) {
            Button(L10n.text("Move to Trash"), role: .destructive) {
                Task { await moveCurrentResultToTrash() }
            }
            Button(L10n.text("Cancel"), role: .cancel) {}
        } message: {
            if let snapshot {
                Text(L10n.format("Move “%@” to the macOS Trash? Referenced terrain and model files are kept.", snapshot.name))
            }
        }
        .alert(L10n.text("Result Action Failed"), isPresented: Binding(
            get: { actionError != nil }, set: { if !$0 { actionError = nil } }
        )) {
            Button(L10n.text("OK"), role: .cancel) { actionError = nil }
        } message: {
            Text(L10n.text(actionError ?? ""))
        }
    }

    @MainActor private func moveCurrentResultToTrash() async {
        guard canMoveToTrash else { return }
        let projectSessionID = store.projectSessionID
        guard store.beginResultDeletion(assetID: asset.id, projectSessionID: projectSessionID) else {
            actionError = L10n.text("The result cannot be moved to Trash while project changes or editing are in progress.")
            return
        }
        isWorking = true
        defer {
            store.endResultDeletion(projectSessionID: projectSessionID)
            isWorking = false
        }

        do {
            guard store.projectSessionID == projectSessionID,
                  let liveAsset = store.assets.first(where: { $0.id == asset.id && $0.section == .results }),
                  Self.canonical(liveAsset.url) == Self.canonical(asset.url),
                  let projectPath = store.document?.url,
                  let projectXML = store.document?.editorXML(overridingDescription: store.descriptionDraft)
            else {
                throw BackendServiceError(code: "sourceChanged", message: "The selected result changed before it could be moved to Trash.")
            }

            let preparation = try await inspector.prepareDelete(asset: liveAsset,
                projectPath: projectPath, projectXML: projectXML)
            guard store.projectSessionID == projectSessionID,
                  preparation.matches(projectPath: projectPath, resultPath: liveAsset.url,
                                      revision: snapshot?.revision ?? ""),
                  preparation.name == snapshot?.name else {
                throw BackendServiceError(code: "sourceChanged", message: "The selected result changed before it could be moved to Trash.")
            }

            // Trash the selected filesystem entry. If it is a symbolic link,
            // keep the validated target in its original location.
            try store.system.trash(liveAsset.url)
            try store.completeResultDeletion(assetID: asset.id, sourceName: preparation.name,
                                               projectSessionID: projectSessionID)
        } catch {
            actionError = error.localizedDescription
        }
    }

    private static func canonical(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }
}

private struct ResultCatalogActionIdentity: Hashable {
    let projectSessionID: UUID
    let assetsRevision: Int
    let assetID: String
    let projectPath: String?
    let projectXML: String?
}

/// Catalog-card action surface with its own read-only inspector. It does not
/// borrow the active editor session, so changing the selected catalog asset
/// cannot replace an open Result editor's source identity.
@MainActor
struct ResultCatalogActionsPanel: View {
    let asset: ProjectAsset
    @ObservedObject var store: WorkspaceStore
    @StateObject private var inspector: ResultInspectorSession

    init(asset: ProjectAsset, store: WorkspaceStore, provider: BackendResultInspectorProvider) {
        self.asset = asset
        self.store = store
        _inspector = StateObject(wrappedValue: ResultInspectorSession(provider: provider))
    }

    private var projectXML: String? {
        guard let document = store.document else { return nil }
        return document.editorXML(overridingDescription: store.descriptionDraft)
    }

    private var requestIdentity: ResultCatalogActionIdentity {
        ResultCatalogActionIdentity(
            projectSessionID: store.projectSessionID,
            assetsRevision: store.assetsRevision,
            assetID: asset.id,
            projectPath: store.document?.url?.standardizedFileURL.path,
            projectXML: projectXML
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L10n.text("Result Actions")).font(.subheadline.weight(.medium))
                Spacer()
                Button { refresh() } label: {
                    Label(L10n.text("Refresh"), systemImage: "arrow.clockwise")
                }
                .disabled(inspector.isLoading || projectXML == nil)
            }
            if inspector.isLoading {
                ProgressView(L10n.text("Reading result source…")).controlSize(.small)
            } else if let error = inspector.error {
                Label(L10n.text(error), systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.red)
            }
            if let snapshot = inspector.snapshot, !snapshot.layerErrors.isEmpty {
                ResultLayerErrorIndicatorView(messages: snapshot.layerErrorPresentations, store: store)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ResultInspectorActions(asset: asset, inspector: inspector, store: store)
        }
        .task(id: requestIdentity) {
            await inspector.ensureLoaded(asset: asset, projectPath: store.document?.url,
                projectXML: projectXML,
                sourceContextRevision: "\(store.projectSessionID):\(store.assetsRevision)")
        }
    }

    private func refresh() {
        inspector.invalidate()
        Task {
            await inspector.ensureLoaded(asset: asset, projectPath: store.document?.url,
                projectXML: projectXML,
                sourceContextRevision: "\(store.projectSessionID):\(store.assetsRevision)")
        }
    }
}
