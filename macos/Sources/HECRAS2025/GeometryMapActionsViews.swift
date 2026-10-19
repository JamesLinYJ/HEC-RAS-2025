import RASWorkspaceCore
import SwiftUI

@MainActor
@discardableResult
func runGeometryFocusInNewView(assetID: String, store: WorkspaceStore) async -> Bool {
    let priorError = store.errorMessage
    let succeeded = await store.focusGeometryInNewMap(assetID: assetID)
    if !succeeded, store.errorMessage == priorError {
        store.errorMessage = L10n.text("The Geometry could not be opened in a new map.")
    }
    return succeeded
}

/// The original Geometry context menu's Focus In New View action, exposed from
/// the native workspace Map menu. The asset list comes from the current
/// project catalog; the Store performs the identity-checked source operation.
struct GeometryMapCommandMenu: View {
    @ObservedObject var store: WorkspaceStore

    private var geometries: [ProjectAsset] {
        store.assets.filter { $0.section == .geometries && $0.isModelFile }
    }

    var body: some View {
        Menu {
            Button("New Geometry Map", systemImage: "point.3.connected.trianglepath.dotted") {
                store.addGeometryMapDocument()
            }
            Divider()
            Menu("Focus in New View") {
                if geometries.isEmpty {
                    Text("No Geometry assets are available.").disabled(true)
                } else {
                    ForEach(geometries) { asset in
                        Button { focus(asset) } label: { Text(verbatim: asset.name) }
                    }
                }
            }
        } label: {
            Label("Geometry Map", systemImage: "point.3.connected.trianglepath.dotted")
        }
        .disabled(!store.hasProject || store.isRunningProjectTool || store.isSavingAll
            || store.isOpeningProject || store.isClosingTab)
    }

    private func focus(_ asset: ProjectAsset) {
        let projectID = store.projectSessionID
        Task { @MainActor in
            guard projectID == store.projectSessionID else { return }
            _ = await runGeometryFocusInNewView(assetID: asset.id, store: store)
        }
    }
}

/// Add an existing source Geometry to a Buildable map or to a Geometry map's
/// focused list. This is an HDF-reference operation; it never copies or edits
/// the source Geometry file.
struct GeometryMapMembershipPickerView: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var mapState: MapState
    let nodes: [LayerTreeNode]
    let isPopoverBusy: Bool
    let refresh: () async -> Void

    @State private var selectedAssetID: String?
    @State private var working = false
    @State private var failure: String?

    private var geometries: [ProjectAsset] {
        store.assets.filter { $0.section == .geometries && $0.isModelFile }
    }
    private var eligibleGeometries: [ProjectAsset] {
        geometries.filter { !isAlreadyOnMap($0) }
    }
    private var actionTitle: String {
        mapState.kind == .geometry ? L10n.text("Add to Focused Geometries") : L10n.text("Add Geometry")
    }
    private var fieldTitle: String {
        mapState.kind == .geometry ? L10n.text("Geometry to Focus") : L10n.text("Geometry to Add")
    }
    private var canEdit: Bool {
        store.hasProject && !store.isRunningProjectTool && !store.isSavingAll
            && !store.isOpeningProject && !store.isClosingTab && !isPopoverBusy && !working
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Geometry Membership", systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if working { ProgressView().controlSize(.small) }
            }

            if eligibleGeometries.isEmpty {
                Text(geometries.isEmpty ? L10n.text("No Geometry assets are available.")
                                        : L10n.text("All Geometry assets are already on this map."))
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 8) {
                    Picker(fieldTitle, selection: $selectedAssetID) {
                        Text("Select a Geometry").tag(nil as String?)
                        ForEach(eligibleGeometries) { asset in
                            Text(verbatim: asset.name).tag(Optional(asset.id))
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity)

                    Button(actionTitle, systemImage: "plus") { addSelectedGeometry() }
                        .disabled(!canEdit || selectedAssetID == nil)
                }
            }

            if let failure {
                Text(failure).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
        }
        .padding(.vertical, 6)
        .task(id: store.mapWorkflowIdentity(mapState.id)) {
            failure = nil
            reconcileSelection()
        }
        .onChange(of: geometries.map(\.id)) { _, _ in reconcileSelection() }
        .onChange(of: nodes.map(\.id)) { _, _ in reconcileSelection() }
    }

    private func addSelectedGeometry() {
        guard canEdit, let selectedAssetID,
              eligibleGeometries.contains(where: { $0.id == selectedAssetID }) else { return }
        let projectID = store.projectSessionID
        let mapID = mapState.id
        let priorError = store.errorMessage
        working = true
        failure = nil
        Task { @MainActor in
            let succeeded = await store.addGeometryToMap(assetID: selectedAssetID, mapID: mapID)
            working = false
            guard store.projectSessionID == projectID,
                  store.mapDocument(for: mapID) != nil,
                  !Task.isCancelled else { return }
            guard succeeded else {
                if store.errorMessage == priorError {
                    failure = L10n.text("The Geometry could not be added to this map.")
                }
                return
            }
            await refresh()
            reconcileSelection()
        }
    }

    private func reconcileSelection() {
        if let selectedAssetID, eligibleGeometries.contains(where: { $0.id == selectedAssetID }) { return }
        selectedAssetID = eligibleGeometries.first?.id
        failure = nil
    }

    private func isAlreadyOnMap(_ asset: ProjectAsset) -> Bool {
        let target = SourceFilePaths.canonical(asset.url)
        return nodes.contains { node in
            guard node.sourceLocator?.nodeType == "Geometry",
                  let path = node.sourceLocator?.assetID ?? node.assetID,
                  !path.isEmpty else { return false }
            let sourceURL: URL
            if let directory = store.document?.directory,
               let resolved = try? PlatformPaths.resolve(path, relativeTo: directory, mappings: store.pathMappings) {
                sourceURL = resolved
            } else {
                sourceURL = URL(fileURLWithPath: path)
            }
            return SourceFilePaths.canonical(sourceURL) == target
        }
    }
}
