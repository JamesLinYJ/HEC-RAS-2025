import Foundation
import RASWorkspaceCore
import SwiftUI

/// Shared right-click actions used by both catalog presentations and the
/// project tree. Tree adapters only route real asset identities here; they do
/// not call LayerTreeProvider.perform for model-file mutations.
struct CatalogModelActionMenuItems: View {
    @ObservedObject var store: WorkspaceStore
    let asset: ProjectAsset
    let kind: CatalogManagedModelKind
    let caller: CatalogModelActionCaller

    private var canStart: Bool {
        store.document?.url != nil
            && store.modelProvider is BackendModelProvider
            && store.assets.first(where: { $0.id == asset.id }) == asset
            && !store.isRunningProjectTool
            && !store.isSavingAll
            && !store.isClosingTab
            && !store.isOpeningProject
            && !store.hasBusyModelEditors
    }

    var body: some View {
        Button("Rename…", systemImage: "pencil") { present(.rename) }
            .disabled(!canStart)
        Button("Duplicate", systemImage: "plus.square.on.square") { present(.duplicate) }
            .disabled(!canStart)
        Button("Delete…", systemImage: "trash", role: .destructive) { present(.delete) }
            .disabled(!canStart)
    }

    private func present(_ intent: CatalogModelActionIntent) {
        guard let presentation = CatalogModelActionPresentation.make(asset: asset,
                kind: kind, intent: intent, caller: caller, store: store) else {
            store.errorMessage = L10n.text("The selected model changed. Refresh and try again.")
            return
        }
        store.catalogModelActionPresentation = presentation
    }
}

@MainActor
private struct CatalogModelActionPresentationSheetModifier: ViewModifier {
    @ObservedObject var store: WorkspaceStore

    func body(content: Content) -> some View {
        content.sheet(item: $store.catalogModelActionPresentation) { presentation in
            CatalogModelActionSheet(presentation: presentation, store: store)
                .id(presentation.id)
        }
    }
}

extension View {
    /// Apply once to the main workspace root. Every catalog/tree surface writes
    /// the same presentation value to WorkspaceStore.
    func catalogModelActionPresentationSheet(store: WorkspaceStore) -> some View {
        modifier(CatalogModelActionPresentationSheetModifier(store: store))
    }
}

@MainActor
private struct CatalogModelActionSheet: View {
    let presentation: CatalogModelActionPresentation
    @ObservedObject var store: WorkspaceStore
    @StateObject private var coordinator: CatalogModelActionCoordinator
    @State private var renameName = ""
    @State private var confirmsDelete = false

    init(presentation: CatalogModelActionPresentation, store: WorkspaceStore) {
        self.presentation = presentation
        self.store = store
        _coordinator = StateObject(wrappedValue: CatalogModelActionCoordinator(store: store))
    }

    private var intent: CatalogModelActionIntent? { presentation.intent }
    private var renameValidation: String? {
        guard intent == .rename, let inspection = coordinator.inspection,
              let asset = store.assets.first(where: { $0.id == presentation.assetID }) else { return nil }
        return CatalogModelNameValidation.message(renameName, originalName: inspection.name, asset: asset)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Manage Model", systemImage: "slider.horizontal.3").font(.title2)
                Spacer()
                if coordinator.isLoading || coordinator.isPerforming {
                    ProgressView().controlSize(.small)
                }
            }

            if coordinator.isLoading {
                ProgressView("Checking model and project files…")
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if let inspection = coordinator.inspection {
                inspectedContent(inspection)
            } else if coordinator.error == nil {
                Label("The source model could not be inspected.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            }

            if let error = coordinator.error {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Action could not be completed", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout.weight(.medium)).foregroundStyle(.red)
                    Text(verbatim: error).font(.callout).textSelection(.enabled)
                }
            }

            Spacer(minLength: 0)
            Divider()
            HStack {
                Button("Cancel", role: .cancel, action: cancel)
                    .keyboardShortcut(.cancelAction)
                    .disabled(coordinator.isPerforming)
                Spacer()
                actionButton
            }
        }
        .padding(20)
        .frame(minWidth: 460, idealWidth: 520, minHeight: 360, idealHeight: 540)
        .task(id: presentation.id) {
            await coordinator.inspect(presentation)
            if intent == .rename { renameName = coordinator.inspection?.name ?? "" }
        }
        .onDisappear { coordinator.invalidate(presentation.id) }
        .interactiveDismissDisabled(coordinator.isPerforming)
        .confirmationDialog("Move Model to Trash?", isPresented: $confirmsDelete,
            titleVisibility: .visible) {
            Button("Move to Trash", role: .destructive) {
                Task { _ = await coordinator.perform(presentation) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(verbatim: coordinator.deleteConfirmationText)
        }
    }

    @ViewBuilder
    private func inspectedContent(_ inspection: CatalogModelActionInspection) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                LabeledContent("Type") { Text(verbatim: L10n.text(inspection.kind)) }
                LabeledContent("Model Name") { Text(verbatim: inspection.name).textSelection(.enabled) }

                if !coordinator.isRequestedActionAvailable(presentation) {
                    Label("This action is unavailable for the selected model.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                } else if intent == .rename {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("New Name")
                            .font(.caption).foregroundStyle(.secondary)
                        TextField("New Name", text: $renameName)
                            .textFieldStyle(.roundedBorder)
                        if let renameValidation {
                            Text(verbatim: L10n.text(renameValidation))
                                .font(.caption).foregroundStyle(.red)
                        }
                    }
                } else if intent == .duplicate || intent == .clone {
                    Text("Create a copy of this model:")
                        .font(.callout).foregroundStyle(.secondary)
                    Text(verbatim: inspection.name).textSelection(.enabled)
                } else if intent == .delete {
                    deleteDetails(inspection)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 380)
    }

    @ViewBuilder
    private func deleteDetails(_ inspection: CatalogModelActionInspection) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Files moved to Trash").font(.subheadline.weight(.medium))
            if inspection.trashPaths.isEmpty {
                Text("No source files are listed for Trash.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(inspection.trashPaths) { item in
                    Label {
                        Text(verbatim: item.path).textSelection(.enabled)
                    } icon: {
                        Image(systemName: item.originalAsset ? "doc" : "doc.badge.gearshape")
                    }
                    .font(.caption)
                }
            }

            Text("Related project items").font(.subheadline.weight(.medium))
                .padding(.top, 4)
            if inspection.deleteDependencies.isEmpty {
                Text("No related project items.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(inspection.deleteDependencies) { dependency in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: "\(dependency.kind): \(dependency.name)")
                            .font(.callout.weight(.medium)).textSelection(.enabled)
                        Text(verbatim: dependency.reason).font(.caption).foregroundStyle(.secondary)
                        if let path = dependency.assetPath {
                            Text(verbatim: path).font(.caption).textSelection(.enabled)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        switch intent {
        case .rename:
            Button("Rename") { Task { _ = await coordinator.perform(presentation, name: renameName) } }
                .keyboardShortcut(.defaultAction)
                .disabled(!coordinator.isRequestedActionAvailable(presentation) || renameValidation != nil || coordinator.isLoading || coordinator.isPerforming)
        case .duplicate, .clone:
            Button("Duplicate") { Task { _ = await coordinator.perform(presentation) } }
                .keyboardShortcut(.defaultAction)
                .disabled(!coordinator.isRequestedActionAvailable(presentation) || coordinator.isLoading || coordinator.isPerforming)
        case .delete:
            Button("Move to Trash", role: .destructive) { confirmsDelete = true }
                .disabled(!coordinator.isRequestedActionAvailable(presentation) || coordinator.isLoading || coordinator.isPerforming)
        case nil:
            Button("Unavailable") {}
                .disabled(true)
        }
    }

    private func cancel() {
        guard store.catalogModelActionPresentation?.id == presentation.id else { return }
        store.catalogModelActionPresentation = nil
    }
}

enum CatalogModelNameValidation {
    static func message(_ input: String, originalName: String, asset: ProjectAsset) -> String? {
        // CoreLayerBase.IsLegalName checks the original string (including
        // whitespace) and permits the current name as a successful no-op.
        let name = input
        guard !name.isEmpty else { return "Name cannot be blank." }
        guard name.utf16.count <= 64 else { return "Name cannot be longer than 64 characters." }
        let invalid = Set("<>:\"/\\|?*".unicodeScalars.map(\.value))
        guard !name.unicodeScalars.contains(where: { $0.value < 32 || invalid.contains($0.value) }) else {
            return "The name contains characters that cannot be used in a model filename."
        }
        var destination = asset.url.deletingLastPathComponent().appendingPathComponent(name)
        if !asset.url.pathExtension.isEmpty { destination.appendPathExtension(asset.url.pathExtension) }
        if name != originalName && FileManager.default.fileExists(atPath: destination.path) {
            return "A model file already exists with that name."
        }
        return nil
    }
}
