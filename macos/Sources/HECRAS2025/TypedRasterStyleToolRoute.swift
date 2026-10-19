import SwiftUI

/// Routes global Contours/Hillshade commands to the existing row-scoped raster
/// style editor, preserving the current saved map and complete tree locator.
@MainActor
struct TypedRasterStyleToolRoute: View {
    @ObservedObject var store: WorkspaceStore
    let action: ToolKind
    let mapID: UUID

    @Environment(\.dismiss) private var dismiss
    @State private var capturedProjectSessionID: UUID
    @State private var capturedMapState: MapState?
    @State private var capturedMapWorkflowIdentity: String
    @State private var capturedSourceWorkflowIdentity: String
    @State private var capturedMapName: String?
    @State private var routeIsStale = false
    @State private var hasPresentedStyleEditor = false
    @State private var isLoading = false
    @State private var isOpeningStyle = false
    @State private var loadOperation: UUID?
    @State private var openOperation: UUID?
    @State private var nodes: [LayerTreeNode] = []
    @State private var selectedLocatorIdentity: String?
    @State private var styleSession: AssociatedRasterStyleSession?
    @State private var showingStyleEditor = false
    @State private var failure: String?

    init(store: WorkspaceStore, action: ToolKind, mapID: UUID) {
        self.store = store
        self.action = action
        self.mapID = mapID
        _capturedProjectSessionID = State(initialValue: store.projectSessionID)
        _capturedMapState = State(initialValue: store.existingMapState(for: mapID))
        _capturedMapWorkflowIdentity = State(initialValue: store.mapWorkflowIdentity(mapID))
        _capturedSourceWorkflowIdentity = State(initialValue: store.mapSourceWorkflowIdentity(mapID))
        _capturedMapName = State(initialValue: store.mapIdentityRequest(for: mapID)?.mapName)
    }

    private var actionIsSupported: Bool { action == .contours || action == .hillshade }

    private var styleNodes: [LayerTreeNode] {
        nodes.filter(Self.canEditRasterStyle)
    }

    private var groupedStyleNodes: [String: [LayerTreeNode]] {
        Dictionary(grouping: styleNodes) { $0.sourceLocator?.sourceIdentity ?? $0.id }
    }

    private var ambiguousNodeCount: Int {
        groupedStyleNodes.values.filter { $0.count > 1 }.count
    }

    private var choices: [RasterStyleToolChoice] {
        groupedStyleNodes.compactMap { identity, matching in
            guard matching.count == 1, let node = matching.first,
                  let locator = node.sourceLocator else { return nil }
            return RasterStyleToolChoice(identity: identity, node: node, locator: locator)
        }
        .sorted {
            let left = Self.displaySortKey($0.locator)
            let right = Self.displaySortKey($1.locator)
            return left.localizedStandardCompare(right) == .orderedAscending
        }
    }

    private var selectedChoice: RasterStyleToolChoice? {
        guard let selectedLocatorIdentity else { return nil }
        let matching = choices.filter { $0.identity == selectedLocatorIdentity }
        return matching.count == 1 ? matching[0] : nil
    }

    private var mapDocumentExists: Bool {
        guard let identity = store.mapIdentityRequest(for: mapID) else { return false }
        return ["Project", "Buildable", "Plan", "Geometry"].contains(identity.mapType)
    }

    private var captureIsCurrent: Bool {
        guard !routeIsStale,
              actionIsSupported,
              store.projectSessionID == capturedProjectSessionID,
              store.lastActiveMapID == mapID,
              let capturedMapState,
              store.existingMapState(for: mapID) === capturedMapState,
              mapDocumentExists,
              store.mapWorkflowIdentity(mapID) == capturedMapWorkflowIdentity,
              store.mapSourceWorkflowIdentity(mapID) == capturedSourceWorkflowIdentity else { return false }
        return true
    }

    private var canOpenStyle: Bool {
        captureIsCurrent && !isLoading && !isOpeningStyle && selectedChoice != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "slider.horizontal.3")
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: action.localizedTitle).font(.title2.weight(.semibold))
                    if let capturedMapName {
                        Text(verbatim: capturedMapName).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if isLoading { ProgressView().controlSize(.small) }
                Button {
                    Task { await loadRows() }
                } label: {
                    Label(L10n.text("Refresh"), systemImage: "arrow.clockwise")
                }
                .disabled(isLoading || isOpeningStyle || routeIsStale || showingStyleEditor)
            }
            .padding(18)
            Divider()

            if !actionIsSupported {
                ContentUnavailableView(L10n.text("This action does not have a typed raster-style route."),
                    systemImage: "questionmark.folder")
            } else if routeIsStale {
                ContentUnavailableView(L10n.text("The active project or map changed."),
                    systemImage: "arrow.triangle.2.circlepath",
                    description: Text(L10n.text("Close this chooser and start the action again for the current saved map.")))
            } else if !mapDocumentExists || capturedMapState == nil {
                ContentUnavailableView(L10n.text("Open a saved map before choosing a raster layer."),
                    systemImage: "map",
                    description: Text(L10n.text("Contours and Hillshade are stored on an exact Terrain or N-Value layer.")))
            } else {
                Form {
                    Section(L10n.text("Supported raster layers")) {
                        Text(L10n.text("Choose the exact Terrain or N-Value row whose saved style will be edited."))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        if ambiguousNodeCount > 0 {
                            Label(L10n.format("%d duplicate source rows were withheld because their locators are ambiguous.", ambiguousNodeCount),
                                systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if choices.isEmpty && !isLoading {
                            ContentUnavailableView(L10n.text("No supported Terrain or N-Value rows are available."),
                                systemImage: "square.3.layers.3d",
                                description: Text(L10n.text("Refresh the current map tree and choose a supported source row.")))
                                .frame(minHeight: 150)
                        } else {
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 8) {
                                    ForEach(choices) { choice in
                                        choiceRow(choice)
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                            .frame(minHeight: 180, idealHeight: 290)
                        }
                    }
                    if let failure {
                        Section {
                            Label(failure, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.red)
                                .textSelection(.enabled)
                        }
                    }
                }
                .formStyle(.grouped)
                .padding(.horizontal, 12)
            }

            Divider()
            HStack {
                Button(L10n.text("Cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if isOpeningStyle { ProgressView().controlSize(.small) }
                Button(L10n.text("Open Raster Style Editor"), action: openStyleEditor)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canOpenStyle)
            }
            .padding(16)
        }
        .frame(minWidth: 720, idealWidth: 880, minHeight: 480, idealHeight: 620)
        .task { await loadRows() }
        .onChange(of: store.projectSessionID) { _, _ in invalidateRoute() }
        .onChange(of: store.lastActiveMapID) { _, newValue in
            if newValue != mapID { invalidateRoute() }
        }
        .onChange(of: store.mapWorkflowIdentity(mapID)) { _, newValue in
            if !showingStyleEditor && !hasPresentedStyleEditor
                && newValue != capturedMapWorkflowIdentity { invalidateRoute() }
        }
        .onChange(of: store.mapSourceWorkflowIdentity(mapID)) { _, newValue in
            if !showingStyleEditor && !hasPresentedStyleEditor
                && newValue != capturedSourceWorkflowIdentity { invalidateRoute() }
        }
        .sheet(isPresented: $showingStyleEditor, onDismiss: styleEditorDidDismiss) {
            if let styleSession {
                AssociatedRasterStyleEditor(session: styleSession)
            }
        }
    }

    private func choiceRow(_ choice: RasterStyleToolChoice) -> some View {
        let isSelected = selectedLocatorIdentity == choice.identity
        return Button {
            guard captureIsCurrent else { invalidateRoute(); return }
            selectedLocatorIdentity = choice.identity
            failure = nil
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Text(verbatim: choice.locator.nodeName)
                        Text("·").foregroundStyle(.secondary)
                        Text(L10n.text(choice.locator.nodeType))
                    }
                    .font(.body.weight(.medium))
                    Text(verbatim: Self.locatorDescription(choice.locator))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Text(verbatim: Self.sourcePath(choice.locator))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(isSelected ? Color.accentColor.opacity(0.12) : Color.clear,
                in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func loadRows() async {
        guard !isLoading, !showingStyleEditor else { return }
        guard captureIsCurrent else {
            invalidateRoute()
            if capturedMapState == nil || !mapDocumentExists {
                routeIsStale = false
                failure = L10n.text("No current saved map is available for this action.")
            }
            return
        }
        let operation = UUID()
        loadOperation = operation
        isLoading = true
        failure = nil
        defer {
            if loadOperation == operation {
                loadOperation = nil
                isLoading = false
            }
        }

        do {
            let loaded = try await store.sourceMapLayerNodes(mapID)
            guard loadOperation == operation, !Task.isCancelled, captureIsCurrent else {
                if loadOperation == operation { invalidateRoute() }
                return
            }
            nodes = loaded
            if let selectedLocatorIdentity,
               !choices.contains(where: { $0.identity == selectedLocatorIdentity }) {
                self.selectedLocatorIdentity = nil
            }
        } catch is CancellationError {
            return
        } catch {
            guard loadOperation == operation, !Task.isCancelled, captureIsCurrent else { return }
            failure = L10n.text(error.localizedDescription)
        }
    }

    private func openStyleEditor() {
        guard canOpenStyle,
              let capturedMapState,
              let choice = selectedChoice,
              store.existingMapState(for: mapID) === capturedMapState else {
            invalidateRoute()
            return
        }
        let exactRows = nodes.filter { $0.sourceLocator == choice.locator }
        guard exactRows.count == 1, let node = exactRows.first,
              Self.canEditRasterStyle(node) else {
            failure = L10n.text("The selected source row is no longer unique in the current map tree.")
            selectedLocatorIdentity = nil
            return
        }

        let operation = UUID()
        openOperation = operation
        isOpeningStyle = true
        failure = nil
        let expectedProjectSessionID = capturedProjectSessionID
        let expectedWorkflowIdentity = capturedMapWorkflowIdentity
        let expectedSourceWorkflowIdentity = capturedSourceWorkflowIdentity

        Task { @MainActor in
            defer {
                if openOperation == operation {
                    openOperation = nil
                    isOpeningStyle = false
                }
            }
            do {
                let session = try await store.makeAssociatedRasterStyleSession(node: node, mapID: mapID)
                guard openOperation == operation, !Task.isCancelled,
                      store.projectSessionID == expectedProjectSessionID,
                      store.lastActiveMapID == mapID,
                      store.existingMapState(for: mapID) === capturedMapState,
                      store.mapWorkflowIdentity(mapID) == expectedWorkflowIdentity,
                      store.mapSourceWorkflowIdentity(mapID) == expectedSourceWorkflowIdentity,
                      mapDocumentExists,
                      nodes.contains(where: { $0.sourceLocator == choice.locator }) else {
                    invalidateRoute()
                    return
                }
                styleSession = session
                hasPresentedStyleEditor = true
                showingStyleEditor = true
            } catch is CancellationError {
                return
            } catch {
                guard openOperation == operation,
                      store.projectSessionID == expectedProjectSessionID,
                      store.lastActiveMapID == mapID,
                      store.existingMapState(for: mapID) === capturedMapState,
                      store.mapWorkflowIdentity(mapID) == expectedWorkflowIdentity,
                      store.mapSourceWorkflowIdentity(mapID) == expectedSourceWorkflowIdentity else {
                    invalidateRoute()
                    return
                }
                failure = L10n.text(error.localizedDescription)
            }
        }
    }

    private func styleEditorDidDismiss() {
        styleSession = nil
        guard !routeIsStale,
              store.projectSessionID == capturedProjectSessionID,
              store.lastActiveMapID == mapID,
              let capturedMapState,
              store.existingMapState(for: mapID) === capturedMapState,
              mapDocumentExists else {
            invalidateRoute()
            return
        }
        // Applying a style is expected to advance the .vis and result-context
        // revisions. Re-capture only after the existing editor closes, then
        // reload the exact tree rows before another edit can be selected.
        capturedMapWorkflowIdentity = store.mapWorkflowIdentity(mapID)
        capturedSourceWorkflowIdentity = store.mapSourceWorkflowIdentity(mapID)
        Task { @MainActor in
            await loadRows()
            if captureIsCurrent { hasPresentedStyleEditor = false }
        }
    }

    private func invalidateRoute() {
        guard !routeIsStale else { return }
        routeIsStale = true
        loadOperation = nil
        openOperation = nil
        isLoading = false
        isOpeningStyle = false
        selectedLocatorIdentity = nil
        nodes = []
        failure = nil
        styleSession?.invalidate()
    }

    private static func canEditRasterStyle(_ node: LayerTreeNode) -> Bool {
        guard let locator = node.sourceLocator else { return false }
        let kind = locator.associationKind ?? locator.nodeType
        return ["Terrain", "NValue"].contains(kind)
            && locator.nodeType == kind
            && (locator.associationAssetID != nil || locator.assetID != nil)
    }

    private static func displaySortKey(_ locator: CatalogTreeNodeLocator) -> String {
        [locator.rootName, locator.nodeName, locator.nodeType,
         (locator.nodePath ?? []).map(String.init).joined(separator: "."),
         sourcePath(locator)].joined(separator: "|")
    }

    private static func locatorDescription(_ locator: CatalogTreeNodeLocator) -> String {
        let nodePath = (locator.nodePath ?? []).map(String.init).joined(separator: ".")
        var parts = [L10n.format("Root: %@", locator.rootName),
                     L10n.format("Path: [%@]", nodePath)]
        if let parent = locator.parentGeometryAssetID {
            let path = (locator.parentGeometryNodePath ?? []).map(String.init).joined(separator: ".")
            parts.append(L10n.format("Parent Geometry: %@ [%@]", parent, path))
        }
        if let parent = locator.parentPlanAssetID {
            let path = (locator.parentPlanNodePath ?? []).map(String.init).joined(separator: ".")
            parts.append(L10n.format("Parent Plan: %@ [%@]", parent, path))
        }
        if let parent = locator.parentResultAssetID {
            let path = (locator.parentResultNodePath ?? []).map(String.init).joined(separator: ".")
            parts.append(L10n.format("Parent Result: %@ [%@]", parent, path))
        }
        return parts.joined(separator: " · ")
    }

    private static func sourcePath(_ locator: CatalogTreeNodeLocator) -> String {
        locator.associationAssetID ?? locator.assetID ?? locator.filename ?? "—"
    }
}

private struct RasterStyleToolChoice: Identifiable {
    let identity: String
    let node: LayerTreeNode
    let locator: CatalogTreeNodeLocator
    var id: String { identity }
}
