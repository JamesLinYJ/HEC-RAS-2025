import SwiftUI

/// Routes a selected Catalog MultiResult to the exact node in a selected saved
/// map. All controls operate the same MapState.resultSources used by map
/// rendering and chart selection.
struct CatalogMultiResultMapContextView: View {
    let node: CatalogTreeNodeLocator?
    let ownerPlanPath: String?
    @ObservedObject var store: WorkspaceStore
    @State private var selectedMapKey: String
    @State private var chosenGroupID: String?

    init(node: CatalogTreeNodeLocator?, ownerPlanPath: String?, store: WorkspaceStore) {
        self.node = node
        self.ownerPlanPath = ownerPlanPath
        self.store = store
        _selectedMapKey = State(initialValue: store.lastActiveMapID.uuidString)
    }

    private var maps: [CatalogMapDocument] {
        store.catalogMapDocuments.filter { map in
            guard let id = UUID(uuidString: map.id) else { return false }
            return store.mapResultRequest(for: id) != nil
        }
    }

    private var selectedMapID: UUID? {
        guard maps.contains(where: { $0.id.caseInsensitiveCompare(selectedMapKey) == .orderedSame }) else {
            return nil
        }
        return UUID(uuidString: selectedMapKey)
    }

    private var mapState: MapState? {
        selectedMapID.map { store.mapState(for: $0) }
    }

    private var matchingGroups: [MapResultChartActiveNode] {
        guard let allNodes = mapState?.resultSources.sources?.activeNodes else { return [] }
        let multiResults = allNodes.filter { $0.nodeKind == "MultiResult" }
        if let node {
            return multiResults.filter { $0.node == node }
        }
        guard let ownerPlanPath else { return [] }
        return MultiResultContextRouteProjection.activeGroups(forPlanAssetID: ownerPlanPath,
            among: multiResults)
    }

    private var effectiveGroupID: String? {
        if let chosenGroupID, matchingGroups.contains(where: { $0.id == chosenGroupID }) {
            return chosenGroupID
        }
        return matchingGroups.count == 1 ? matchingGroups[0].id : nil
    }

    private var configurationIdentity: String {
        [store.projectSessionID.uuidString, selectedMapID?.uuidString ?? "",
            node?.sourceIdentity ?? "", ownerPlanPath ?? ""].joined(separator: "|")
    }

    var body: some View {
        GroupBox(L10n.text("MultiResult Map Context")) {
            VStack(alignment: .leading, spacing: 10) {
                mapPicker
                if maps.isEmpty {
                    ContentUnavailableView(L10n.text("No saved maps support Result sources."),
                        systemImage: "map")
                        .frame(minHeight: 120)
                } else if let mapState, mapState.resultSources.sources == nil {
                    MapResultSourcePanel(session: mapState.resultSources, store: store,
                        onlyNodeIdentity: node?.sourceIdentity, autoLoadSources: false)
                } else if let mapState, let nodeID = effectiveGroupID {
                    VStack(alignment: .leading, spacing: 10) {
                        if matchingGroups.count > 1 { groupPicker }
                        MapResultSourcePanel(session: mapState.resultSources, store: store,
                            onlyNodeIdentity: nodeID, autoLoadSources: false,
                            missingNodeMessage: "This MultiResult is not active on the selected map. Enable it in the map tree to edit its selections.")
                        MultiResultMapRenderContextControls(store: store, mapState: mapState,
                            requestedNodeID: nodeID)
                    }
                } else if matchingGroups.count > 1 {
                    groupPicker
                    ContentUnavailableView(L10n.text(groupChoiceMessage),
                        systemImage: "square.stack.3d.up")
                        .frame(minHeight: 130)
                } else {
                    ContentUnavailableView(L10n.text(groupChoiceMessage),
                        systemImage: "eye.slash")
                        .frame(minHeight: 130)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: configurationIdentity) {
            guard let selectedMapID else { return }
            store.activateMap(selectedMapID)
            await store.configureMapResultSources(selectedMapID)
        }
        .onChange(of: selectedMapKey) { _, value in
            chosenGroupID = nil
            guard let id = UUID(uuidString: value), maps.contains(where: {
                $0.id.caseInsensitiveCompare(value) == .orderedSame
            }) else { return }
            store.activateMap(id)
        }
        .onChange(of: store.projectSessionID) { _, _ in
            chosenGroupID = nil
            selectedMapKey = store.lastActiveMapID.uuidString
        }
        .onAppear(perform: normalizeMapSelection)
        .onChange(of: maps.map(\.id)) { _, _ in normalizeMapSelection() }
    }

    private var mapPicker: some View {
        Picker(L10n.text("Map"), selection: $selectedMapKey) {
            Text(L10n.text("Choose a saved map")).tag("")
            ForEach(maps, id: \.id) { map in
                Text(mapTitle(map)).tag(map.id)
            }
        }
        .disabled(maps.isEmpty)
    }

    private func normalizeMapSelection() {
        guard !maps.contains(where: { $0.id.caseInsensitiveCompare(selectedMapKey) == .orderedSame }) else { return }
        selectedMapKey = maps.first(where: {
            $0.id.caseInsensitiveCompare(store.lastActiveMapID.uuidString) == .orderedSame
        })?.id ?? maps.first?.id ?? ""
    }

    private func mapTitle(_ map: CatalogMapDocument) -> String {
        let ordinal = map.sourceIndex.map { "#\($0 + 1)" } ?? map.id
        return "\(map.name) — \(L10n.text(map.kind)) \(ordinal)"
    }

    private var groupPicker: some View {
        Picker(L10n.text("MultiResult group"), selection: Binding(
            get: { effectiveGroupID ?? "" },
            set: { chosenGroupID = $0.isEmpty ? nil : $0 })) {
            Text(L10n.text("Choose an active MultiResult group")).tag("")
            ForEach(matchingGroups) { group in Text(groupTitle(group)).tag(group.id) }
        }
    }

    private func groupTitle(_ group: MapResultChartActiveNode) -> String {
        let owner = WorkspaceStore.exactPlanOwnerForResultGroup(group.node).map {
            URL(fileURLWithPath: $0.assetID).lastPathComponent
        } ?? L10n.text("Unknown Plan")
        let path = (group.node.nodePath ?? []).map(String.init).joined(separator: ".")
        return "\(group.name) — \(owner) [\(path)]"
    }

    private var groupChoiceMessage: String {
        if node != nil {
            return "This MultiResult is not active on the selected map. Enable it in the map tree to edit its selections."
        }
        return "This Plan has no active MultiResult group on the selected map. Enable or add its source in the map tree."
    }
}

/// The Result editor has no standalone ResultSelections collection in the
/// source model. It exposes the active map's actual MultiResult groups and lets
/// the user choose one when the selected Result is not uniquely selected there.
struct ResultMultiResultMapContextView: View {
    @ObservedObject var store: WorkspaceStore
    let resultPath: String?
    @State private var selectedMapKey: String
    @State private var chosenGroupID: String?

    init(store: WorkspaceStore, resultPath: String?) {
        self.store = store
        self.resultPath = resultPath
        _selectedMapKey = State(initialValue: store.lastActiveMapID.uuidString)
    }

    private var maps: [CatalogMapDocument] {
        store.catalogMapDocuments.filter { map in
            guard let id = UUID(uuidString: map.id) else { return false }
            return store.mapResultRequest(for: id) != nil
        }
    }

    private var selectedMapID: UUID? {
        guard maps.contains(where: { $0.id.caseInsensitiveCompare(selectedMapKey) == .orderedSame }) else {
            return nil
        }
        return UUID(uuidString: selectedMapKey)
    }

    private var mapState: MapState? {
        selectedMapID.map { store.mapState(for: $0) }
    }

    private var groups: [MapResultChartActiveNode] {
        mapState?.resultSources.sources?.activeNodes.filter { $0.nodeKind == "MultiResult" } ?? []
    }

    private var matchingGroupID: String? {
        guard let resultPath else { return nil }
        return MultiResultContextRouteProjection.uniquelySelectedGroupID(for: resultPath, among: groups)
    }

    private var effectiveGroupID: String? {
        if let chosenGroupID, groups.contains(where: { $0.id == chosenGroupID }) { return chosenGroupID }
        return matchingGroupID
    }

    private var configurationIdentity: String {
        [store.projectSessionID.uuidString, selectedMapID?.uuidString ?? "", resultPath ?? ""].joined(separator: "|")
    }

    var body: some View {
        GroupBox(L10n.text("MultiResult Map Context")) {
            VStack(alignment: .leading, spacing: 10) {
                mapPicker
                if maps.isEmpty {
                    ContentUnavailableView(L10n.text("No saved maps support Result sources."),
                        systemImage: "map")
                        .frame(minHeight: 120)
                } else if let mapState, mapState.resultSources.sources == nil {
                    MapResultSourcePanel(session: mapState.resultSources, store: store,
                        autoLoadSources: false)
                } else if groups.isEmpty {
                    ContentUnavailableView(L10n.text("This saved map has no active MultiResult groups. Enable a MultiResult source in its map tree."),
                        systemImage: "eye.slash")
                        .frame(minHeight: 130)
                } else {
                    groupPicker
                    if let mapState, let effectiveGroupID {
                        VStack(alignment: .leading, spacing: 10) {
                            MapResultSourcePanel(session: mapState.resultSources, store: store,
                                onlyNodeIdentity: effectiveGroupID, autoLoadSources: false,
                                missingNodeMessage: "The selected MultiResult is no longer active on this map. Refresh the map source list.")
                            MultiResultMapRenderContextControls(store: store, mapState: mapState,
                                requestedNodeID: effectiveGroupID)
                        }
                    } else {
                        ContentUnavailableView(L10n.text(groupChoiceMessage), systemImage: "square.stack.3d.up")
                            .frame(minHeight: 130)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: configurationIdentity) {
            guard let selectedMapID else { return }
            store.activateMap(selectedMapID)
            await store.configureMapResultSources(selectedMapID)
        }
        .onChange(of: selectedMapKey) { _, value in
            chosenGroupID = nil
            guard let id = UUID(uuidString: value), maps.contains(where: {
                $0.id.caseInsensitiveCompare(value) == .orderedSame
            }) else { return }
            store.activateMap(id)
        }
        .onChange(of: store.projectSessionID) { _, _ in
            chosenGroupID = nil
            selectedMapKey = store.lastActiveMapID.uuidString
        }
        .onAppear(perform: normalizeMapSelection)
        .onChange(of: maps.map(\.id)) { _, _ in normalizeMapSelection() }
    }

    private var mapPicker: some View {
        Picker(L10n.text("Map"), selection: $selectedMapKey) {
            Text(L10n.text("Choose a saved map")).tag("")
            ForEach(maps, id: \.id) { map in
                Text(mapTitle(map)).tag(map.id)
            }
        }
        .disabled(maps.isEmpty)
    }

    private var groupPicker: some View {
        Picker(L10n.text("MultiResult group"), selection: Binding(
            get: { effectiveGroupID ?? "" },
            set: { chosenGroupID = $0.isEmpty ? nil : $0 })) {
            Text(L10n.text("Choose an active MultiResult group")).tag("")
            ForEach(groups) { group in
                Text(groupTitle(group)).tag(group.id)
            }
        }
    }

    private var groupChoiceMessage: String {
        guard let resultPath else {
            return "Choose an active MultiResult group to edit its map selections."
        }
        let matches = groups.filter { group in
            group.selections.contains { slot in
                slot.selectionIndex == 0 && slot.selectedResult.map {
                    MultiResultContextRouteProjection.canonicalPath($0.resultPath)
                        == MultiResultContextRouteProjection.canonicalPath(resultPath)
                } == true
            }
        }
        return matches.count > 1
            ? "This Result is selected by more than one active MultiResult group. Choose the exact map group to edit."
            : "The selected Result is not currently selected by an active MultiResult. Choose an active map group to edit its map selections."
    }

    private func mapTitle(_ map: CatalogMapDocument) -> String {
        let ordinal = map.sourceIndex.map { "#\($0 + 1)" } ?? map.id
        return "\(map.name) — \(L10n.text(map.kind)) \(ordinal)"
    }

    private func normalizeMapSelection() {
        guard !maps.contains(where: { $0.id.caseInsensitiveCompare(selectedMapKey) == .orderedSame }) else { return }
        selectedMapKey = maps.first(where: {
            $0.id.caseInsensitiveCompare(store.lastActiveMapID.uuidString) == .orderedSame
        })?.id ?? maps.first?.id ?? ""
    }

    private func groupTitle(_ group: MapResultChartActiveNode) -> String {
        let owner: String
        if let exactOwner = WorkspaceStore.exactPlanOwnerForResultGroup(group.node) {
            owner = URL(fileURLWithPath: exactOwner.assetID).lastPathComponent
        } else {
            owner = L10n.text("Unknown Plan")
        }
        let path = (group.node.nodePath ?? []).map(String.init).joined(separator: ".")
        return "\(group.name) — \(owner) [\(path)]"
    }
}

/// Keeps keyframe and render controls bound to the same MapState and exact
/// MultiResult selected in the detail route. Selecting a different source in
/// the native map control remains an explicit change to that map's context.
private struct MultiResultMapRenderContextControls: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var mapState: MapState
    let requestedNodeID: String

    var body: some View {
        GroupBox(L10n.text("Current Map Result Rendering")) {
            VStack(alignment: .leading, spacing: 8) {
                MultiResultMapTypePicker(store: store, mapState: mapState,
                    requestedNodeID: requestedNodeID)
                VStack(alignment: .leading, spacing: 8) {
                    MapResultMapControls(session: mapState.resultMap)
                    if let timeline = mapState.resultMap.selectedTimeline {
                        ProfileTimeline(mapState: mapState, session: timeline)
                    } else {
                        Text(L10n.text("No keyframe timeline is available for the selected map node."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .onAppear(perform: selectRequestedNode)
        .onChange(of: requestedNodeID) { _, _ in selectRequestedNode() }
        .onChange(of: mapState.resultMap.nodes.map(\.id)) { _, _ in selectRequestedNode() }
    }

    private func selectRequestedNode() {
        guard mapState.resultMap.nodes.contains(where: { $0.id == requestedNodeID }) else { return }
        mapState.resultMap.selectNode(requestedNodeID)
    }
}

/// This calls the same map-scoped type mutation used by the existing map
/// Result popover; the picker never edits a catalog-only draft.
private struct MultiResultMapTypePicker: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var mapState: MapState
    let requestedNodeID: String
    @State private var isUpdating = false

    private let types = ["WaterSurfaceElevation", "Depth", "Velocity", "DepthTimesVelocity"]

    private var currentType: String {
        let raw = mapState.resultSources.sources?.activeNodes.first(where: {
            $0.id == requestedNodeID
        })?.selectedMapType ?? "Depth"
        switch raw {
        case "Water Surface": return "WaterSurfaceElevation"
        case "D*V": return "DepthTimesVelocity"
        default: return raw
        }
    }

    var body: some View {
        Picker(L10n.text("Selected MultiResult Map Type"), selection: Binding(get: { currentType }, set: update)) {
            ForEach(types, id: \.self) { type in
                Text(L10n.text(title(for: type))).tag(type)
            }
        }
        .pickerStyle(.menu)
        .disabled(isUpdating || store.isRunningProjectTool || store.isSavingAll
            || store.isOpeningProject || store.isClosingTab
            || activeNode == nil)
    }

    private func update(_ value: String) {
        guard types.contains(value), !isUpdating, let activeNode else { return }
        isUpdating = true
        Task {
            _ = await store.persistSourceResultViewState(node: activeNode.node,
                mapID: mapState.id, selectedMapType: value,
                profileIndex: activeNode.profileIndex, expectedWorkflowIdentity: nil)
            isUpdating = false
        }
    }

    private var activeNode: MapResultChartActiveNode? {
        mapState.resultSources.sources?.activeNodes.first(where: {
            $0.id == requestedNodeID && $0.nodeKind == "MultiResult"
        })
    }

    private func title(for type: String) -> String {
        switch type {
        case "WaterSurfaceElevation": "Water Surface"
        case "DepthTimesVelocity": "D*V"
        default: type
        }
    }
}
