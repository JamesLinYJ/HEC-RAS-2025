import RASWorkspaceCore
import SwiftUI

@MainActor
@discardableResult
func runPlanFocusInNewView(assetID: String, store: WorkspaceStore) async -> Bool {
    let projectID = store.projectSessionID
    let previousError = store.errorMessage
    let succeeded = await store.focusPlanInNewMap(assetID: assetID)
    guard projectID == store.projectSessionID, !Task.isCancelled else { return false }
    if !succeeded, store.errorMessage == previousError {
        store.errorMessage = L10n.text("The Plan could not be opened in a new map.")
    }
    return succeeded
}

/// Saved Plan map commands. A fresh map can be empty, while Focus in New View
/// creates the source Plan map and focuses one exact project Plan atomically.
/// Reopening uses the saved .vis map catalog rather than transient open tabs.
struct PlanMapCommandMenu: View {
    @ObservedObject var store: WorkspaceStore
    @State private var working = false
    @State private var operationID: UUID?

    private var plans: [ProjectAsset] {
        store.assets.filter { $0.section == .plans && $0.isModelFile }
    }

    private var savedPlanMaps: [CatalogMapDocument] {
        store.catalogMapDocuments.filter { $0.kind == "Plan" }
    }

    private var isBusy: Bool {
        !store.hasProject || store.isRunningProjectTool || store.isSavingAll
            || store.isOpeningProject || store.isClosingTab || working
    }

    var body: some View {
        Menu {
            Button("New Plan Map", systemImage: "play.rectangle") {
                createMap()
            }
            .disabled(isBusy)

            Menu("Focus in New View") {
                if plans.isEmpty {
                    Text("No Plan assets are available.").disabled(true)
                } else {
                    ForEach(plans) { plan in
                        Button { focus(plan) } label: { Text(verbatim: plan.name) }
                    }
                }
            }
            .disabled(isBusy)

            if !savedPlanMaps.isEmpty { Divider() }
            Menu("Open Saved Plan Map") {
                if savedPlanMaps.isEmpty {
                    Text("No saved Plan maps are available.").disabled(true)
                } else {
                    ForEach(savedPlanMaps, id: \.id) { source in
                        Button { open(source) } label: { Text(verbatim: source.name) }
                    }
                }
            }
            .disabled(isBusy)
        } label: {
            Label("Plan Map", systemImage: "play.rectangle")
        }
        .disabled(isBusy)
    }

    private func createMap() {
        guard !isBusy else { return }
        let projectID = store.projectSessionID
        let previousError = store.errorMessage
        let operation = UUID()
        operationID = operation
        working = true
        Task { @MainActor in
            defer {
                if operationID == operation {
                    operationID = nil
                    working = false
                }
            }
            guard projectID == store.projectSessionID, store.hasProject,
                  !store.isRunningProjectTool, !store.isSavingAll,
                  !store.isOpeningProject, !store.isClosingTab else { return }
            let succeeded = await store.createPlanMap()
            guard operationID == operation, projectID == store.projectSessionID,
                  !Task.isCancelled else { return }
            if !succeeded, store.errorMessage == previousError {
                store.errorMessage = L10n.text("The Plan map could not be created.")
            }
        }
    }

    private func focus(_ plan: ProjectAsset) {
        guard !isBusy else { return }
        let projectID = store.projectSessionID
        let operation = UUID()
        operationID = operation
        working = true
        Task { @MainActor in
            defer {
                if operationID == operation {
                    operationID = nil
                    working = false
                }
            }
            guard projectID == store.projectSessionID, store.hasProject,
                  !store.isRunningProjectTool, !store.isSavingAll,
                  !store.isOpeningProject, !store.isClosingTab,
                  plans.contains(where: { $0.id == plan.id }) else { return }
            _ = await runPlanFocusInNewView(assetID: plan.id, store: store)
        }
    }

    private func open(_ source: CatalogMapDocument) {
        guard !isBusy, let id = UUID(uuidString: source.id),
              let map = store.mapDocument(for: id), map.kind == .plan else { return }
        store.openMapDocument(map)
    }
}

/// Adds a Plan to a saved Plan map's Focused Plans root. This persists only
/// the map's sparse focused membership; it does not create or change the Plan.
struct PlanMapMembershipPickerView: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var mapState: MapState
    let nodes: [LayerTreeNode]
    let isPopoverBusy: Bool
    let refresh: () async -> Void

    @State private var selectedAssetID: String?
    @State private var working = false
    @State private var operationID: UUID?
    @State private var failure: String?

    private var plans: [ProjectAsset] {
        store.assets.filter { $0.section == .plans && $0.isModelFile }
    }

    private var availablePlans: [ProjectAsset] {
        plans.filter { !isAlreadyFocused($0) }
    }

    private var canFocus: Bool {
        mapState.kind == .plan && store.hasProject
            && !store.isRunningProjectTool && !store.isSavingAll
            && !store.isOpeningProject && !store.isClosingTab
            && !isPopoverBusy && !working
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Plan Membership", systemImage: "play.rectangle")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if working { ProgressView().controlSize(.small) }
            }

            if availablePlans.isEmpty {
                Text(plans.isEmpty ? L10n.text("No Plan assets are available.")
                                   : L10n.text("All Plan assets are already on this map."))
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 8) {
                    Picker("Plan to Focus", selection: $selectedAssetID) {
                        Text("Select a Plan").tag(nil as String?)
                        ForEach(availablePlans) { plan in
                            Text(verbatim: plan.name).tag(Optional(plan.id))
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                    .disabled(working || isPopoverBusy)

                    Button("Add to Focused Plans", systemImage: "plus") { focusSelectedPlan() }
                        .disabled(!canFocus || selectedAssetID == nil)
                }
            }

            if let failure {
                Text(failure).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
        }
        .padding(.vertical, 6)
        .task(id: store.mapWorkflowIdentity(mapState.id)) { reconcileSelection() }
        .onChange(of: plans.map(\.id)) { _, _ in reconcileSelection() }
        .onChange(of: nodes.map(\.id)) { _, _ in reconcileSelection() }
    }

    private func focusSelectedPlan() {
        guard canFocus, let selectedAssetID,
              availablePlans.contains(where: { $0.id == selectedAssetID }) else { return }
        let projectID = store.projectSessionID
        let mapID = mapState.id
        let previousError = store.errorMessage
        let operation = UUID()
        operationID = operation
        working = true
        failure = nil
        Task { @MainActor in
            defer {
                if operationID == operation {
                    operationID = nil
                    working = false
                }
            }
            let succeeded = await store.focusPlanInMap(assetID: selectedAssetID, mapID: mapID)
            guard operationID == operation else { return }
            guard projectID == store.projectSessionID,
                  store.mapDocument(for: mapID) != nil, !Task.isCancelled else { return }
            guard succeeded else {
                if store.errorMessage == previousError {
                    failure = L10n.text("The Plan could not be added to this map.")
                }
                return
            }
            await refresh()
            guard operationID == operation else { return }
            guard projectID == store.projectSessionID,
                  store.mapDocument(for: mapID) != nil, !Task.isCancelled else { return }
            reconcileSelection()
        }
    }

    private func reconcileSelection() {
        if let selectedAssetID, availablePlans.contains(where: { $0.id == selectedAssetID }) { return }
        selectedAssetID = availablePlans.first?.id
        failure = nil
    }

    private func isAlreadyFocused(_ plan: ProjectAsset) -> Bool {
        let target = SourceFilePaths.canonical(plan.url)
        return nodes.contains { node in
            guard node.sourceLocator?.rootName == "Focused Plans",
                  node.sourceLocator?.nodeType == "Plan",
                  node.sourceLocator?.nodePath?.count == 2,
                  let sourcePath = node.sourceLocator?.assetID ?? node.assetID,
                  !sourcePath.isEmpty else { return false }
            let sourceURL: URL
            if let directory = store.document?.directory,
               let resolved = try? PlatformPaths.resolve(sourcePath, relativeTo: directory,
                                                          mappings: store.pathMappings) {
                sourceURL = resolved
            } else {
                sourceURL = URL(fileURLWithPath: sourcePath)
            }
            return SourceFilePaths.canonical(sourceURL) == target
        }
    }
}
