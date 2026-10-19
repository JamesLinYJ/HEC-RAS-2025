import RASWorkspaceCore
import SwiftUI

struct MapSourceLayersPopover: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var mapState: MapState
    @Environment(\.openWindow) private var openWindow
    @State private var presented = false
    @State private var nodes: [LayerTreeNode] = []
    @State private var busy = false
    @State private var refreshGeneration: UInt64 = 0
    @State private var failure: String?
    @State private var removing: PendingMapSourceRemoval?
    @State private var styleSession: AssociatedRasterStyleSession?
    @State private var showingStyleEditor = false
    @State private var boundaryStyleSession: BoundaryMapStyleSession?
    @State private var showingBoundaryStyleEditor = false
    @State private var styleLoading = false
    @State private var styleLoadOperation: UUID?
    @State private var showBoundaryLines = false
    @State private var boundaryRefreshOperation: UUID?
    private var groups: [MapSourceLayerGroup] {
        var result: [MapSourceLayerGroup] = []
        var indexByRoot: [String: Int] = [:]
        for node in nodes {
            let root = node.sourceLocator?.rootName ?? "Layers"
            if let index = indexByRoot[root] { result[index].nodes.append(node) }
            else {
                indexByRoot[root] = result.count
                result.append(MapSourceLayerGroup(rootName: root, nodes: [node]))
            }
        }
        return result
    }
    var body: some View {
        Button { presented.toggle() } label: { Label("Map Layers", systemImage: "square.3.layers.3d") }
            .disabled(!store.hasProject || mapState.kind == .unsupported)
            .popover(isPresented: $presented) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Map Layers").font(.headline)
                        Spacer()
                        Button { Task { await refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                            .disabled(busy || boundaryRefreshOperation != nil)
                        if busy { ProgressView().controlSize(.small) }
                    }
                    HStack {
                        if mapState.kind != .unsupported {
                            Button("Add Map Layer…") { store.addMapLayer(for: mapState.id) }
                                .disabled(busy)
                        }
                        if mapState.kind == .buildable {
                            Menu("Add Result") {
                                ForEach(store.assets.filter { $0.section == .results }) { asset in
                                    Button(asset.name) { Task { await store.addAssetsToMap([asset], mapID: mapState.id); await refresh() } }
                                }
                            }
                            .disabled(busy)
                        }
                        if styleLoading { ProgressView().controlSize(.small) }
                    }
                    if mapState.kind == .buildable || mapState.kind == .geometry {
                        GeometryMapMembershipPickerView(store: store, mapState: mapState,
                            nodes: nodes, isPopoverBusy: busy, refresh: refresh)
                        Divider()
                    }
                    if mapState.kind == .plan {
                        PlanMapMembershipPickerView(store: store, mapState: mapState,
                            nodes: nodes, isPopoverBusy: busy, refresh: refresh)
                        Divider()
                    }
                    if let failure { Text(failure).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                    if nodes.isEmpty && !busy {
                        Text("No source map layers are available.").foregroundStyle(.secondary)
                    }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(groups) { group in
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(L10n.text(group.rootName)).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                    ForEach(group.nodes) { node in layerRow(node) }
                                }
                            }
                            MapResultCulvertTimeSeriesEntry(store: store, mapState: mapState,
                                session: mapState.storedCulvertProfile)
                            if let acceptedSources = mapState.resultSources.snapshot,
                               let selectedNodeID = mapState.resultMap.selectedNodeID,
                               let resultNode = acceptedSources.sources.activeNodes.first(where: {
                                   $0.id == selectedNodeID
                               }),
                               (resultNode.nodeKind == "Result" || resultNode.nodeKind == "MultiResult") {
                                Divider()
                                MapResultMeshTimeSeriesEntry(store: store, mapState: mapState,
                                    snapshot: acceptedSources, node: resultNode)
                            }
                            if nodes.contains(where: { $0.sourceLocator?.nodeType == "BoundaryCondition" })
                                || !mapState.boundaryMap.entries.isEmpty || mapState.boundaryMap.isLoading {
                                boundaryLinesSection
                            }
                        }
                    }.frame(maxHeight: 380)
                }.padding(16).frame(width: 440)
                    .task(id: store.mapSourceWorkflowIdentity(mapState.id)) { await refresh() }
                    .confirmationDialog(removalPrompt, isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
                        Button(removalActionTitle, role: .destructive) {
                            guard let removal = removing else { return }; removing = nil
                            Task { await remove(removal) }
                        }
                        Button("Cancel", role: .cancel) { removing = nil }
                    }
            }
            .sheet(isPresented: $showingStyleEditor, onDismiss: { styleSession = nil }) {
                if let styleSession {
                    AssociatedRasterStyleEditor(session: styleSession)
                }
            }
            .sheet(isPresented: $showingBoundaryStyleEditor, onDismiss: { boundaryStyleSession = nil }) {
                if let boundaryStyleSession {
                    BoundaryMapStyleEditor(session: boundaryStyleSession)
                }
            }
            .onChange(of: store.mapWorkflowIdentity(mapState.id)) { _, _ in
                removing = nil
            }
            .onChange(of: store.isDebugMode) { _, debugMode in
                guard !debugMode else { return }
                for node in nodes where node.sourceClass == "LeveeModTerrainInputVC" {
                    Task { await mapState.terrainInputMap.setShowsTin(false, nodeID: node.id, debugMode: false) }
                }
            }
    }
    private func isChecked(_ node: LayerTreeNode) -> Bool {
        if isRenderableTerrainInput(node) { return mapState.terrainInputMap.isChecked(node.id) }
        return FlowAreaMapGenerationVisibility.hasLocalVisibilityOverride(node: node,
            mapID: mapState.id, projectSessionID: store.projectSessionID, store: store)
            || node.checked == .checked
    }
    private func isRenderableTerrainInput(_ node: LayerTreeNode) -> Bool {
        ["ChannelModTerrainInputParentVC", "LeveeModTerrainInputVC",
         "PolygonRasterModTerrainInputVisualContext"].contains(node.sourceClass)
    }
    @ViewBuilder private func layerRow(_ node: LayerTreeNode) -> some View {
        let meshGeneration = FlowAreaMapGenerationVisibility.activeSession(node: node,
            mapID: mapState.id, projectSessionID: store.projectSessionID, store: store)
        let hasGenerationVisibilityOverride = FlowAreaMapGenerationVisibility.hasLocalVisibilityOverride(
            node: node, mapID: mapState.id, projectSessionID: store.projectSessionID, store: store)
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                if meshGeneration != nil {
                    Toggle(isOn: .constant(false)) {
                        Label { Text(verbatim: node.name) } icon: { Image(systemName: node.symbol) }
                    }
                    .toggleStyle(.checkbox)
                    .disabled(true)
                    .accessibilityValue(L10n.text(meshGeneration?.isCancellingMeshGeneration == true
                        ? "Cancelling mesh generation" : "Generating mesh"))
                } else if case .mixed? = node.checked, !hasGenerationVisibilityOverride {
                    Button { setVisibility(node, checked: true) } label: {
                        Image(systemName: "minus.square")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(L10n.text("Partially visible"))
                    .accessibilityLabel(L10n.text("Partially visible"))
                    Label { Text(verbatim: node.name) } icon: { Image(systemName: node.symbol) }
                } else if node.checked != nil {
                    Toggle(isOn: Binding(get: { isChecked(node) }, set: { checked in
                        setVisibility(node, checked: checked)
                    })) { Label { Text(verbatim: node.name) } icon: { Image(systemName: node.symbol) } }
                        .toggleStyle(.checkbox)
                } else {
                    Label { Text(verbatim: node.name) } icon: { Image(systemName: node.symbol) }
                }
                Spacer()
                if canEditRasterStyle(node) {
                    Button { presentRasterStyle(node) } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                    .buttonStyle(.borderless)
                    .help(L10n.text("Raster Style…"))
                    .accessibilityLabel(L10n.text("Raster Style…"))
                    .disabled(styleLoading)
                }
                if canRemove(node) {
                    Button(role: .destructive) {
                        removing = PendingMapSourceRemoval(
                            node: node,
                            projectSessionID: store.projectSessionID,
                            mapID: mapState.id,
                            workflowIdentity: store.mapWorkflowIdentity(mapState.id))
                    } label: {
                        Label(node.sourceLocator?.nodeType == "Plan" ? "Remove Plan from Map" : "Remove from Map",
                              systemImage: "minus.circle")
                    }
                    .labelStyle(.iconOnly)
                    .help(L10n.text("Remove this source from the map"))
                }
            }
            if isLeveeInput(node), mapState.terrainInputMap.isChecked(node.id) {
                VStack(alignment: .leading, spacing: 3) {
                    Toggle("Show Profile Stations", isOn: Binding(
                        get: { mapState.terrainInputMap.showsProfileStations(node.id) },
                        set: { enabled in
                            Task { await mapState.terrainInputMap.setShowsProfileStations(enabled, nodeID: node.id) }
                        }))
                        .toggleStyle(.checkbox)
                        .disabled(busy || mapState.terrainInputMap.loadingNodeIDs.contains(node.id)
                            || !mapState.terrainInputMap.hasRenderViewport)
                    if store.isDebugMode {
                        Toggle("Add TIN to Map Layers (DEBUG)", isOn: Binding(
                            get: { mapState.terrainInputMap.showsTin(node.id) },
                            set: { enabled in
                                Task { await mapState.terrainInputMap.setShowsTin(enabled,
                                    nodeID: node.id, debugMode: store.isDebugMode) }
                            }))
                            .toggleStyle(.checkbox)
                            .help(L10n.text("Adds the simple cut/fill surfaces as an in-memory TIN map layer. Not saved with the project."))
                            .disabled(busy || mapState.terrainInputMap.loadingNodeIDs.contains(node.id)
                                || !mapState.terrainInputMap.hasRenderViewport)
                        tinRenderOptions(node.id)
                    }
                    if mapState.terrainInputMap.loadingNodeIDs.contains(node.id) {
                        ProgressView("Rendering Levee map layer…").controlSize(.small)
                    }
                    if let warning = mapState.terrainInputMap.leveeRendererWarning(node.id) {
                        Text(L10n.text(warning)).font(.caption2).foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    if let error = mapState.terrainInputMap.error(for: node.id) {
                        Text(verbatim: error).font(.caption2).foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                }
                .padding(.leading, 24)
            }
        }
        .padding(.leading, CGFloat(max(0, (node.sourceLocator?.nodePath?.count ?? 2) - 2)) * 12)
        .disabled(busy || meshGeneration != nil)
    }

    private func isLeveeInput(_ node: LayerTreeNode) -> Bool {
        node.sourceClass == "LeveeModTerrainInputVC"
    }

    @ViewBuilder
    private func tinRenderOptions(_ nodeID: String) -> some View {
        let current = mapState.terrainInputMap.tinOptions(nodeID)
        VStack(alignment: .leading, spacing: 3) {
            Picker(L10n.text("TIN Surface Fill"), selection: Binding(
                get: { mapState.terrainInputMap.tinOptions(nodeID).surfaceFillMode },
                set: { value in updateTinOptions(nodeID) { $0.surfaceFillMode = value } }
            )) {
                ForEach(TerrainInputMapTinSurfaceFillMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            Toggle(L10n.text("Render TIN Edges"), isOn: Binding(
                get: { mapState.terrainInputMap.tinOptions(nodeID).renderEdges },
                set: { value in updateTinOptions(nodeID) { $0.renderEdges = value } }))
            Toggle(L10n.text("Render Points"), isOn: Binding(
                get: { mapState.terrainInputMap.tinOptions(nodeID).renderPoints },
                set: { value in updateTinOptions(nodeID) { $0.renderPoints = value } }))
            Toggle(L10n.text("Render Deleted Triangles"), isOn: Binding(
                get: { mapState.terrainInputMap.tinOptions(nodeID).renderDeletedTriangles },
                set: { value in updateTinOptions(nodeID) { $0.renderDeletedTriangles = value } }))
            Toggle(L10n.text("Label Triangles"), isOn: Binding(
                get: { mapState.terrainInputMap.tinOptions(nodeID).labelTriangles },
                set: { value in updateTinOptions(nodeID) { $0.labelTriangles = value } }))
            Toggle(L10n.text("Label Edges"), isOn: .constant(false))
                .disabled(true)
                .help(L10n.text("The retained MultiTin renderer does not implement this label drawing option."))
            Toggle(L10n.text("Label Points"), isOn: .constant(false))
                .disabled(true)
                .help(L10n.text("The retained MultiTin renderer does not implement this label drawing option."))
        }
        .font(.caption)
        .padding(.leading, 16)
        .accessibilityElement(children: .contain)
        .accessibilityValue(current.surfaceFillMode.title)
    }

    private func updateTinOptions(_ nodeID: String,
                                 update: (inout TerrainInputMapTinRenderOptions) -> Void) {
        var next = mapState.terrainInputMap.tinOptions(nodeID)
        update(&next)
        Task { await mapState.terrainInputMap.setTinOptions(next, nodeID: nodeID) }
    }

    private var boundaryLinesSection: some View {
        DisclosureGroup("Boundary Condition Lines", isExpanded: $showBoundaryLines) {
            if mapState.boundaryMap.isLoading {
                HStack {
                    ProgressView("Loading Boundary Condition lines…").controlSize(.small)
                    Spacer()
                    Button("Cancel") { mapState.boundaryMap.cancel() }
                }
            }
            if let error = mapState.boundaryMap.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            ForEach(mapState.boundaryMap.entries, id: \.capture.identity) { entry in
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(verbatim: entry.capture.boundaryNode.nodeName).font(.caption.weight(.semibold))
                        Spacer()
                        if entry.status == .loading { ProgressView().controlSize(.mini) }
                        if !entry.capture.isChecked || !entry.capture.effectiveVisible || entry.status == .hidden {
                            Text("Hidden by map visibility").font(.caption2).foregroundStyle(.secondary)
                        }
                        Button { presentBoundaryStyle(entry.capture) } label: {
                            Image(systemName: "slider.horizontal.3")
                        }
                        .buttonStyle(.borderless)
                        .help(L10n.text("Boundary Line Style"))
                        .accessibilityLabel(L10n.text("Boundary Line Style"))
                        .disabled(styleLoading || busy || mapState.boundaryMap.isLoading)
                    }
                    Toggle("Show Vertices", isOn: Binding(
                        get: { mapState.boundaryMap.showsStrokeVertices(for: entry.capture.sourceIdentity) },
                        set: { mapState.boundaryMap.setShowsStrokeVertices($0,
                            sourceIdentity: entry.capture.sourceIdentity) }))
                        .toggleStyle(.checkbox)
                        .disabled(mapState.boundaryMap.isLoading)
                    if let diagnostic = entry.diagnostic {
                        Text(verbatim: diagnostic).font(.caption2).foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    if entry.visibleLines.isEmpty {
                        if entry.status == .empty && entry.lines.isEmpty {
                            Text("No Boundary Condition lines are available.")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    } else {
                        ForEach(entry.visibleLines.map {
                            BoundaryMapLinePresentation(sourceIdentity: entry.capture.sourceIdentity, line: $0)
                        }) { item in
                            Button {
                                mapState.boundaryMap.selectLine(item.id,
                                    mode: .list(modifiers: MapInput.currentModifiers()))
                            } label: {
                                HStack {
                                    Image(systemName: mapState.boundaryMap.selectedLineIDs.contains(item.id)
                                        ? "point.topleft.down.to.point.bottomright.curvepath" : "line.diagonal")
                                    Text(verbatim: item.line.name.isEmpty
                                        ? L10n.format("BCL: %d", item.line.sourceOrdinal) : item.line.name)
                                        .lineLimit(1)
                                    Spacer()
                                }
                            }
                            .buttonStyle(.plain)
                            .help(L10n.text("Select a Boundary Condition line on the map."))
                            .contextMenu {
                                if entry.capture.resultOwner != nil {
                                    Button("Flow Time Series", systemImage: "chart.xyaxis.line") {
                                        presentBoundaryLineTimeSeries(entry, contextLineID: item.id, variable: "Flow")
                                    }
                                    Button("Stage Time Series", systemImage: "chart.xyaxis.line") {
                                        presentBoundaryLineTimeSeries(entry, contextLineID: item.id, variable: "Stage")
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            if mapState.boundaryMap.entries.isEmpty && !mapState.boundaryMap.isLoading
                && mapState.boundaryMap.errorMessage == nil {
                Text("No Boundary Condition lines are available.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            HStack {
                if boundaryRefreshOperation != nil { ProgressView().controlSize(.small) }
                Button("Refresh Boundary Map", systemImage: "arrow.clockwise") {
                    refreshBoundaryMap()
                }
                .disabled(mapState.boundaryMap.isLoading || busy || boundaryRefreshOperation != nil)
            }
        }
    }

    private func refreshBoundaryMap() {
        guard !busy, !mapState.boundaryMap.isLoading, boundaryRefreshOperation == nil else { return }
        let operation = UUID()
        boundaryRefreshOperation = operation
        let mapID = mapState.id
        let projectID = store.projectSessionID
        Task { @MainActor in
            defer { if boundaryRefreshOperation == operation { boundaryRefreshOperation = nil } }
            await store.refreshBoundaryMap(mapID)
            guard projectID == store.projectSessionID, mapState.id == mapID,
                  boundaryRefreshOperation == operation, !Task.isCancelled else { return }
        }
    }

    private func presentBoundaryLineTimeSeries(_ originalEntry: BoundaryMapSourceState,
                                               contextLineID: String, variable: String) {
        let mapID = mapState.id
        guard let activeEntry = mapState.boundaryMap.entries.first(where: {
                  $0.capture.identity == originalEntry.capture.identity
              }),
              activeEntry.status == .available,
              mapState.boundaryMap.visibleLines.contains(where: {
                  $0.sourceIdentity == activeEntry.capture.sourceIdentity && $0.id == contextLineID
              }),
              let resultOwner = activeEntry.capture.resultOwner,
              resultOwner.isValid,
              let boundarySourceState = activeEntry.boundarySourceState,
              !boundarySourceState.isEmpty,
              let boundaryContextToken = activeEntry.contextToken,
              let mapRequest = store.mapResultRequest(for: mapID),
              mapRequest.mapID == activeEntry.capture.map.mapID,
              mapRequest.mapIndex == activeEntry.capture.map.mapIndex,
              mapRequest.mapName == activeEntry.capture.map.mapName,
              mapRequest.mapType == activeEntry.capture.map.mapType,
              SourceFilePaths.canonical(URL(fileURLWithPath: mapRequest.projectPath))
                == SourceFilePaths.canonical(URL(fileURLWithPath: activeEntry.capture.map.projectPath)),
              mapRequest.projectXmlSHA.caseInsensitiveCompare(activeEntry.capture.map.projectXmlSHA) == .orderedSame,
              mapRequest.expectedVisualizationRevision.caseInsensitiveCompare(
                activeEntry.capture.map.expectedVisualizationRevision) == .orderedSame else {
            failure = L10n.text("The saved map or Boundary Condition source changed before the chart opened.")
            return
        }

        // A context action on a selected row preserves that source SelectedSet;
        // an unselected row starts a one-row selection before charting.
        mapState.boundaryMap.selectLineForContextMenu(contextLineID)
        let selectedIDs = mapState.boundaryMap.selectedLineIDs
        let sourceIdentity = activeEntry.capture.sourceIdentity
        let selectedLines = mapState.boundaryMap.visibleLines
            .filter { $0.sourceIdentity == sourceIdentity && selectedIDs.contains($0.id) }
            .sorted(by: { (lhs: BoundaryMapLinePresentation, rhs: BoundaryMapLinePresentation) in
                lhs.line.sourceOrdinal < rhs.line.sourceOrdinal
            })
        guard !selectedLines.isEmpty,
              selectedLines.allSatisfy({ $0.id.hasPrefix(activeEntry.capture.sourceIdentity + "|") }) else {
            failure = L10n.text("Select at least one Boundary Condition line to plot.")
            return
        }

        do {
            let request = MapBoundaryLineTimeSeriesRequest(map: mapRequest,
                boundaryNode: activeEntry.capture.boundaryNode,
                expectedBoundaryRevision: activeEntry.capture.sourceRevision,
                boundarySourceState: boundarySourceState,
                expectedBoundaryContextToken: boundaryContextToken,
                resultOwner: resultOwner,
                lineIDs: selectedLines.map { $0.line.id }, variable: variable)
            let route = try BoundaryLineTimeSeriesWindowRoute(request: request,
                expectedLines: selectedLines.map {
                    BoundaryLineTimeSeriesLineIdentity(id: $0.line.id,
                        sourceOrdinal: $0.line.sourceOrdinal, name: $0.line.name)
                },
                projectSessionID: store.projectSessionID,
                mapWorkflowIdentity: store.mapWorkflowIdentity(mapID),
                mapSourceWorkflowIdentity: store.mapSourceWorkflowIdentity(mapID),
                boundaryCaptureIdentity: activeEntry.capture.identity)
            guard activeEntry.capture.mapWorkflowIdentity == route.mapSourceWorkflowIdentity else {
                failure = L10n.text("The selected Result context changed before the chart opened.")
                return
            }
            failure = nil
            openWindow(value: route)
        } catch {
            failure = L10n.text(error.localizedDescription)
        }
    }

    private func presentBoundaryStyle(_ capture: BoundaryMapCapture) {
        guard !busy, !styleLoading, !mapState.boundaryMap.isLoading else { return }
        let projectSession = store.projectSessionID
        let mapID = mapState.id
        let workflowIdentity = store.mapSourceWorkflowIdentity(mapID)
        let operation = UUID()
        styleLoadOperation = operation
        styleLoading = true
        Task { @MainActor in
            defer {
                if styleLoadOperation == operation {
                    styleLoadOperation = nil
                    styleLoading = false
                }
            }
            do {
                let session = try await store.makeBoundaryMapStyleSession(capture: capture, mapID: mapID)
                guard styleLoadOperation == operation,
                      store.isCurrentMapState(mapState, mapID: mapID, projectSessionID: projectSession),
                      store.mapSourceWorkflowIdentity(mapID) == workflowIdentity,
                      !Task.isCancelled else { return }
                boundaryStyleSession = session
                showingBoundaryStyleEditor = true
            } catch {
                guard styleLoadOperation == operation,
                      store.isCurrentMapState(mapState, mapID: mapID, projectSessionID: projectSession),
                      store.mapSourceWorkflowIdentity(mapID) == workflowIdentity,
                      !Task.isCancelled else { return }
                failure = (error as? MapSourceLayerError)?.presentationDescription ?? L10n.text(error.localizedDescription)
            }
        }
    }

    private func canEditRasterStyle(_ node: LayerTreeNode) -> Bool {
        guard let locator = node.sourceLocator else { return false }
        let kind = locator.associationKind ?? locator.nodeType
        return ["Terrain", "NValue"].contains(kind)
            && locator.nodeType == kind
            && (locator.associationAssetID != nil || locator.assetID != nil)
    }

    private func presentRasterStyle(_ node: LayerTreeNode) {
        guard !busy, !styleLoading, canEditRasterStyle(node) else { return }
        let projectSession = store.projectSessionID
        let mapID = mapState.id
        let workflowIdentity = store.mapWorkflowIdentity(mapID)
        let operation = UUID()
        styleLoadOperation = operation
        styleLoading = true
        Task { @MainActor in
            defer {
                if styleLoadOperation == operation {
                    styleLoadOperation = nil
                    styleLoading = false
                }
            }
            do {
                let session = try await store.makeAssociatedRasterStyleSession(node: node, mapID: mapID)
                guard styleLoadOperation == operation,
                      projectSession == store.projectSessionID,
                      store.mapWorkflowIdentity(mapID) == workflowIdentity,
                      !Task.isCancelled else { return }
                styleSession = session
                showingStyleEditor = true
            } catch {
                guard styleLoadOperation == operation,
                      projectSession == store.projectSessionID,
                      store.mapWorkflowIdentity(mapID) == workflowIdentity,
                      !Task.isCancelled else { return }
                failure = (error as? MapSourceLayerError)?.presentationDescription ?? L10n.text(error.localizedDescription)
            }
        }
    }
    private func setVisibility(_ node: LayerTreeNode, checked: Bool) {
        guard !busy else { return }
        _ = FlowAreaMapGenerationVisibility.clearLocalVisibilityOverride(node: node,
            mapID: mapState.id, projectSessionID: store.projectSessionID, store: store)
        busy = true
        Task { @MainActor in
            _ = await store.setSourceMapVisibility(node, checked: checked, mapID: mapState.id)
            await refresh()
        }
    }
    private func canRemove(_ node: LayerTreeNode) -> Bool {
        if node.sourceLocator?.nodeType == "MapLayer" {
            return store.sourceMapVectorURL(node) != nil
                || (["SingleBandRasterMapLayer", "ImageRasterMapLayer", "DiscreteRasterMapLayer"]
                    .contains(node.sourceLocator?.mapType ?? "")
                    && CatalogSourceContextRoutes.mapLayerFilePath(for: node) != nil)
        }
        if node.sourceLocator?.nodeType == "Plan" {
            return mapState.kind == .plan
                && node.sourceLocator?.rootName == "Focused Plans"
                && node.sourceLocator?.nodePath?.count == 2
        }
        if node.sourceLocator?.nodeType == "Geometry" {
            return mapState.kind == .buildable || mapState.kind == .geometry
        }
        return mapState.kind == .buildable && ["Result", "MultiResult"].contains(node.sourceLocator?.nodeType ?? "")
    }
    private func remove(_ removal: PendingMapSourceRemoval) async {
        let node = removal.node
        guard !busy,
              removal.projectSessionID == store.projectSessionID,
              removal.mapID == mapState.id,
              removal.workflowIdentity == store.mapWorkflowIdentity(removal.mapID),
              nodes.contains(where: { $0.id == node.id && $0.sourceLocator == node.sourceLocator }) else { return }
        busy = true
        let priorError = store.errorMessage
        let removed: Bool
        if node.sourceLocator?.nodeType == "Plan" {
            removed = await store.removePlanFromMap(nodeID: node.id, mapID: removal.mapID)
        } else if node.sourceLocator?.nodeType == "Geometry" {
            removed = await store.removeGeometryFromMap(nodeID: node.id, mapID: removal.mapID)
        } else {
            removed = await store.removeMapSourceNode(node, mapID: removal.mapID)
        }
        guard removed else {
            busy = false
            if store.errorMessage == priorError {
                failure = L10n.text("The selected source could not be removed from this map.")
            }
            return
        }
        await refresh()
    }
    private func refresh() async {
        refreshGeneration &+= 1
        let generation = refreshGeneration
        busy = true
        defer { if refreshGeneration == generation { busy = false } }
        let identity = store.mapSourceWorkflowIdentity(mapState.id)
        do {
            let loaded = try await store.sourceMapLayerNodes(mapState.id)
            guard refreshGeneration == generation,
                  store.mapSourceWorkflowIdentity(mapState.id) == identity, !Task.isCancelled else { return }
            nodes = loaded; failure = nil
        } catch {
            guard refreshGeneration == generation,
                  store.mapSourceWorkflowIdentity(mapState.id) == identity,
                  !Task.isCancelled, !(error is CancellationError) else { return }
            failure = (error as? MapSourceLayerError)?.presentationDescription ?? L10n.text(error.localizedDescription)
        }
    }

    private var removalPrompt: String {
        removing?.node.sourceLocator?.nodeType == "Plan"
            ? L10n.text("Remove this Plan from the map?")
            : L10n.text("Remove this source from the map?")
    }

    private var removalActionTitle: String {
        removing?.node.sourceLocator?.nodeType == "Plan"
            ? L10n.text("Remove Plan from Map")
            : L10n.text("Remove from Map")
    }
}

private struct PendingMapSourceRemoval {
    let node: LayerTreeNode
    let projectSessionID: UUID
    let mapID: UUID
    let workflowIdentity: String
}

private struct MapSourceLayerGroup: Identifiable {
    let rootName: String
    var nodes: [LayerTreeNode]
    var id: String { rootName }
}
