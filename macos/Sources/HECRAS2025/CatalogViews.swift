import RASWorkspaceCore
import SwiftUI

// RasCatalog's left-panel header and section actions.
struct CatalogPaneHeader: View {
    @ObservedObject var store: WorkspaceStore
    var includesCreateMenu = true

    var body: some View {
        PaneHeading(title: "Project", symbol: "list.bullet.rectangle") {
            if includesCreateMenu { CatalogActionMenu(store: store) }
            Button(action: store.revealProject) {
                Image(systemName: "folder")
            }
            .disabled(store.document?.url == nil)
            .help("Open project folder")
        }
    }
}

struct CatalogActionMenu: View {
    @ObservedObject var store: WorkspaceStore

    var body: some View {
        Menu {
            Section("Model") {
                Button("Geometry", systemImage: "cube") { store.activeTool = .newGeometry }
                    .disabled(!store.hasProject)
                Button("New Terrain…", systemImage: "mountain.2") { store.presentSurfaceCreation(.terrain) }
                    .disabled(!store.hasProject)
                Button("Import Terrain…", systemImage: "square.and.arrow.down") { store.activeTool = .terrainImport }
                    .disabled(!store.hasProject)
                Button("Plan", systemImage: "play.rectangle") { store.activeTool = .newPlan }
                    .disabled(!store.hasProject)
                Button("New N-Value Layer…", systemImage: "square.3.layers.3d") { store.presentSurfaceCreation(.nValue) }
                    .disabled(!store.hasProject)
                Button("New Classification Layer…", systemImage: "paintpalette") { store.presentSurfaceCreation(.classification) }
                    .disabled(!store.hasProject)
                Button("Import Classification…", systemImage: "square.and.arrow.down") { store.activeTool = .classificationImport }
                    .disabled(!store.hasProject)
                Button("Boundary Condition", systemImage: "waveform.path") { store.activeTool = .newBoundary }
                    .disabled(!store.hasProject)
            }
            Section("External Connections") {
                Button("Add Connection…", systemImage: "link.badge.plus") {
                    store.showConnectionEditor = true
                }
                .disabled(!store.hasProject)
            }
            Section("Maps") {
                WorkspaceNewMapFlyout(
                    createBlankMap: store.addBlankMapDocument,
                    createProjectMap: store.addProjectMapDocument
                )
                    .disabled(!store.hasProject)
            }
        } label: {
            Label("New", systemImage: "plus")
        }
        .help("New")
    }
}

// The source RasCatalogInfoPane rebuilds a map preview for selected geometry,
// terrain, surface, backup, and result nodes. This detail view renders the
// authoritative tree snapshot and opens previews through the existing
// source-backed providers where the selected node has a supported renderer.
struct CatalogNodeDetailsView: View {
    let node: LayerTreeNode
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var session: LayerTreeSession

    private var asset: ProjectAsset? {
        guard let assetID = node.assetID else { return nil }
        return store.assets.first { $0.id == assetID }
    }
    private var connection: ProjectConnection? {
        CatalogConnectionNodeRoute.connection(for: node, in: store.document?.connections ?? [])
    }
    private var mapDocument: MapDocument? {
        guard node.sourceClass == "MapDocumentNode",
              let rawID = node.id.split(separator: ":", maxSplits: 1).last,
              let id = UUID(uuidString: String(rawID)) else { return nil }
        return store.mapDocument(for: id)
    }

    var body: some View {
        if let summary = node.backupSummary, node.sourceClass == "BackupNodeVM" {
            VStack(alignment: .leading, spacing: 12) {
                BackupCatalogSummary(node: node, summary: summary, store: store, session: session)
                if let backend = store.modelProvider as? BackendModelProvider,
                   let projectURL = store.document?.url {
                    CatalogBackupGeometryMeshPreviewView(
                        backupPath: summary.filename,
                        projectURL: projectURL,
                        requestIdentity: [store.projectSessionID.uuidString, node.id,
                            summary.filename, summary.revision ?? "",
                            summary.parentGeometryRevision ?? "", summary.projectRevision ?? ""]
                            .joined(separator: "\n"),
                        client: backend.client
                    )
                } else {
                    CatalogSummaryUnavailableNotice(
                        title: "Backup geometry preview unavailable",
                        detail: "The source preview provider is unavailable for this backup."
                    )
                }
            }
        } else if CatalogConnectionNodeRoute.isConnection(node) {
            CatalogConnectionCatalogSummaryView(node: node, connection: connection, store: store)
        } else if let mapDocument {
            VStack(alignment: .leading, spacing: 10) {
                Label(mapDocument.name, systemImage: "map").font(.headline).textSelection(.enabled)
                LabeledContent("Type", value: L10n.text(mapDocument.sourceType ?? (mapDocument.kind == .project ? "Project Map" : "Buildable Map")))
                Button("Open Map") { store.openMapDocument(mapDocument) }
            }
        } else {
            if let asset, store.modelProvider != nil {
                CatalogAssetInspectorSummaryView(asset: asset, node: node, store: store)
            } else if let kind = node.catalogSummaryKind {
                CatalogSummaryRouter(kind: kind, node: node, store: store, assetPath: asset?.url.path)
            } else {
                Label(node.localizeName ? L10n.text(node.name) : node.name, systemImage: node.symbol)
                    .font(.headline)
                    .textSelection(.enabled)
            }

            if ["MultiResultNodeVM", "MultiResultNode"].contains(node.sourceClass) {
                CatalogMultiResultMapContextView(
                    node: node.sourceLocator?.nodeType == "MultiResult" ? node.sourceLocator : nil,
                    ownerPlanPath: node.assetID,
                    store: store)
            }

            if node.catalogSummaryKind == nil,
               CatalogLayerDiagnosticsProjection.applies(to: node.sourceClass) {
                CatalogLayerDiagnosticsSummary(node: node, store: store)
            }

            if let asset {
                Section {
                    Button("Edit") { store.edit(asset, fromTree: true) }
                    Button("Show in Finder") { store.system.reveal(asset.url) }
                    Button("Copy File Path") { store.system.copy(asset.url.path) }
                }
                if node.catalogSummaryKind == nil && store.modelProvider == nil {
                    CatalogFilePath(title: "Filename", path: asset.url.path, store: store)
                }
            }

            if node.catalogSummaryKind == nil, !CatalogConnectionNodeRoute.isConnection(node), !node.properties.isEmpty {
                Section("Summary") {
                    SharedVisualMetadataPropertiesRepeater(properties: node.properties.map {
                        .init(id: $0.id, key: L10n.text($0.label), value: $0.value)
                    })
                }
            }

            if let children = node.children, !children.isEmpty {
                Section("Components") {
                    ForEach(children) { child in
                        Button(child.localizeName ? L10n.text(child.name) : child.name) {
                            Task { await session.select(child.id) }
                        }
                        .buttonStyle(.link)
                    }
                }
            }
        }
    }
}

struct LayerCatalogPaneView: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var session: LayerTreeSession

    var body: some View {
        VStack(spacing: 0) {
            CatalogPaneHeader(store: store)
            TextField("Search catalog", text: $store.catalogFilter)
                .textFieldStyle(.roundedBorder)
                .padding(8)
            LayerCatalogTreeView(store: store, session: session, filter: store.catalogFilter)
        }
    }
}

struct LayerCatalogTreeView: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var session: LayerTreeSession
    var filter: String? = nil

    var body: some View {
        List(selection: Binding(get: { session.selectedID }, set: { id in
            Task { await session.select(id) }
        })) {
            ForEach((session.roots ?? []).compactMap { $0.filtered(filter ?? store.filter) }) { node in
                LayerCatalogOutlineNode(node: node, session: session, store: store)
            }
        }
        .listStyle(.sidebar)
        .disabled(session.busy)
        .accessibilityIdentifier("catalog-tree")
        .onKeyPress("c", phases: .down) { press in
            guard press.modifiers.intersection([.command, .control, .option, .shift]) == .command,
                  !store.system.isTextInputActive, session.canCopyWholeLayer else { return .ignored }
            Task { await session.copyWholeLayer(system: store.system) }
            return .handled
        }
        .onKeyPress("v", phases: .down) { press in
            guard press.modifiers.intersection([.command, .control, .option, .shift]) == .command,
                  !store.system.isTextInputActive, session.canPasteLayer else { return .ignored }
            Task { await session.pasteLayer(system: store.system) }
            return .handled
        }
        .overlay(alignment: .bottom) {
            if session.busy { ProgressView().controlSize(.small).padding(10).workspaceGlass() }
        }
        .onChange(of: session.selectedID) { _, _ in
            if let id = session.selectedNode?.assetID,
               let asset = store.assets.first(where: { $0.id == id }) {
                store.select(asset, clearTreeSelection: false)
            }
        }
    }
}

private struct LayerCatalogOutlineNode: View {
    let node: LayerTreeNode
    @ObservedObject var session: LayerTreeSession
    @ObservedObject var store: WorkspaceStore

    var body: some View {
        if let children = node.children {
            DisclosureGroup(isExpanded: Binding(
                get: { session.expandedNodeIDs.contains(node.id) },
                set: { session.setExpanded(node.id, expanded: $0) }
            )) {
                ForEach(children) { child in
                    LayerCatalogOutlineNode(node: child, session: session, store: store)
                }
            } label: {
                LayerCatalogTreeRow(node: node, session: session, store: store)
            }
            .tag(node.id)
        } else {
            LayerCatalogTreeRow(node: node, session: session, store: store).tag(node.id)
        }
    }
}

private enum CatalogLayerRowSheetPresentation: Identifiable {
    case geometryBackup(ProjectAsset)
    case terrainRaster(ProjectAsset, LayerTreeNode)

    var id: String {
        switch self {
        case .geometryBackup(let asset): "geometry-backup:" + asset.id
        case .terrainRaster(_, let node): "terrain-raster:" + node.id
        }
    }
}

private struct LayerCatalogTreeRow: View {
    let node: LayerTreeNode
    @ObservedObject var session: LayerTreeSession
    @ObservedObject var store: WorkspaceStore
    @State private var rowHovered = false
    @State private var renaming = false
    @State private var name = ""
    @State private var showNewFolder = false
    @State private var folderName = ""
    @State private var pendingMenu: ContextMenuEntry?
    @State private var commandValue = ""
    @State private var pendingValue: ContextMenuValue?
    @State private var rowSheetPresentation: CatalogLayerRowSheetPresentation?
    @FocusState private var editingName: Bool

    private var title: String { node.localizeName ? L10n.text(node.name) : node.name }
    private var fileConnectionIconPath: String? {
        guard node.sourceClass == "ExternalFileConnectionCatalogNode" else { return nil }
        return connection?.absolutePath
            ?? node.properties.first(where: { $0.id == "AbsolutePath" })?.value
    }
    private var modelTarget: CatalogModelActionTarget? {
        CatalogModelActionTarget.resolve(node: node, assets: store.assets)
    }

    var body: some View {
        HStack(spacing: 6) {
            CatalogNodeIconView(symbol: node.symbol, filePath: fileConnectionIconPath)
            if renaming {
                TextField("Name", text: $name)
                    .textFieldStyle(.plain)
                    .focused($editingName)
                    .onSubmit { rename() }
                    .onExitCommand { renaming = false }
            } else {
                Text(title).lineLimit(1)
            }
            CatalogLayerDiagnosticsRow(node: node, store: store)
            if ResultComputePresentationPath.applies(to: node.sourceClass) {
                ResultComputeStatusIndicator(node: node, store: store)
            }
            Spacer(minLength: 0)
            if node.canPin {
                Button {
                    Task { await session.perform(.pin(id: node.id, pinned: !node.isPinned)) }
                } label: {
                    Image(systemName: node.isPinned ? "pin.fill" : "pin")
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .opacity(rowHovered || node.isPinned ? 1 : 0)
                .allowsHitTesting(rowHovered || node.isPinned)
                .accessibilityHidden(!rowHovered && !node.isPinned)
                .help(L10n.text(node.isPinned ? "Unpin" : "Pin"))
            }
            visibilityControl
        }
        .contentShape(Rectangle())
        .onHover { rowHovered = $0 }
        .onTapGesture(count: 2) {
            openNode()
        }
        .contextMenu {
            ContextMenuContents(entries: node.contextMenu, invoke: invoke)
            if !node.contextMenu.isEmpty { Divider() }
            if let modelTarget {
                CatalogModelActionMenuItems(store: store, asset: modelTarget.asset,
                    kind: modelTarget.kind, caller: .catalog)
                if modelTarget.kind == .geometry || modelTarget.kind == .plan {
                    Button("Focus", systemImage: "scope") { store.focus(modelTarget.asset) }
                        .disabled(store.isRunningProjectTool || store.isSavingAll)
                }
                if modelTarget.kind == .geometry, node.sourceClass == "ObservableGeometry" {
                    Button("Create Named Geometry Backup", systemImage: "plus.square.on.square") {
                        rowSheetPresentation = .geometryBackup(modelTarget.asset)
                    }
                    .disabled(store.isRunningProjectTool || store.isSavingAll || store.isClosingTab || store.isOpeningProject)
                }
                if modelTarget.kind == .terrain {
                    Button("Open Editor", systemImage: "pencil") {
                        store.openEditor(.terrain, assetID: modelTarget.asset.id)
                    }
                    .disabled(store.isRunningProjectTool || store.isSavingAll || store.isClosingTab || store.isOpeningProject)
                    if node.sourceClass == "ObservableTerrain" {
                        Button("Export Raster", systemImage: "square.and.arrow.up.on.square") {
                            rowSheetPresentation = .terrainRaster(modelTarget.asset, node)
                        }
                        .disabled(store.isRunningProjectTool || store.isSavingAll
                            || store.isClosingTab || store.isOpeningProject)
                    }
                }
                if modelTarget.kind == .classification {
                    Button("Open Editor", systemImage: "pencil") {
                        store.openEditor(.surface, assetID: modelTarget.asset.id)
                    }
                    .disabled(store.isRunningProjectTool || store.isSavingAll || store.isClosingTab || store.isOpeningProject)
                }
                if modelTarget.kind == .terrain {
                    Button("Set as Default Terrain", systemImage: "checkmark.circle") {
                        store.setDefaultTerrain(modelTarget.asset.name)
                    }
                    .disabled(store.isRunningProjectTool || store.isSavingAll
                        || store.document?.defaultTerrain == modelTarget.asset.name)
                }
                if modelTarget.kind == .plan {
                    Button("Export Plan…", systemImage: "square.and.arrow.up") {
                        store.select(modelTarget.asset, clearTreeSelection: false)
                        store.activeTool = .planExport
                    }
                    .disabled(store.isRunningProjectTool || store.isSavingAll
                        || store.isClosingTab || store.isOpeningProject)
                }
                Divider()
            }
            if let map = mapDocument {
                Button("Open Map") { openMap(map) }
            }
            if let connection = connection {
                Button("Manage Connections…") { store.selectConnection(connection); store.showConnectionManager = true }
                Button("Show in Finder") { store.revealConnection(connection) }
            }
            if let id = node.assetID, let asset = store.assets.first(where: { $0.id == id }) {
                Button("Edit") { store.edit(asset, fromTree: true) }
                Button("Show in Finder") { store.system.reveal(asset.url) }
                Button("Copy File Path") { store.system.copy(asset.url.path) }
            }
            Button("Properties") { Task { await session.select(node.id) }; store.showInspector = true }
            if session.selectedID == node.id {
                if session.canCopyWholeLayer {
                    Button("Copy Layer") { Task { await session.copyWholeLayer(system: store.system) } }
                }
                if session.canPasteLayer {
                    Button("Paste") { Task { await session.pasteLayer(system: store.system) } }
                }
            }
            if node.canRename { Button("Rename…") { beginRename() } }
            if node.canCreateFolder {
                Button("New Folder…") { folderName = ""; showNewFolder = true }
            }
            if node.canPin {
                Button(node.isPinned ? "Unpin" : "Pin") {
                    Task { await session.perform(.pin(id: node.id, pinned: !node.isPinned)) }
                }
            }
        }
        .modifier(LayerCatalogDrag(id: node.id, enabled: node.canMove))
        .dropDestination(for: String.self) { ids, _ in
            guard session.canMove(ids, to: node.id) else { return false }
            Task { await session.perform(.move(ids: ids, parentID: node.id)) }
            return true
        }
        .alert("New Folder", isPresented: $showNewFolder) {
            TextField("Folder Name", text: $folderName)
            Button("Create") {
                Task { await session.perform(.newFolder(parentID: node.id, name: folderName)) }
            }
            .disabled(folderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) {}
        }
        .alert(
            pendingMenu?.prompt.map { L10n.text($0.title) } ?? pendingMenu?.displayTitle ?? "",
            isPresented: Binding(get: { pendingMenu != nil }, set: { if !$0 { pendingMenu = nil } })
        ) {
            if let prompt = pendingMenu?.prompt { TextField(L10n.text(prompt.label), text: $commandValue) }
            Button("OK", role: pendingMenu?.destructive == true ? .destructive : nil) {
                guard let item = pendingMenu else { return }
                let value: ContextMenuValue? = item.prompt != nil ? .text(commandValue) : pendingValue
                pendingMenu = nil
                execute(item, value)
            }
            .disabled(pendingMenu?.prompt?.allowsEmpty == false && commandValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) { pendingMenu = nil }
        } message: {
            Text(pendingMenu?.prompt.map { L10n.text($0.message) } ?? pendingMenu?.confirmation.map(L10n.text) ?? "")
        }
        .sheet(item: $rowSheetPresentation) { presentation in
            switch presentation {
            case .geometryBackup(let geometry):
                GeometryNamedBackupSheet(store: store, geometry: geometry)
            case .terrainRaster(let asset, let node):
                TerrainRasterExportSheet(store: store, asset: asset, catalogNode: node)
                    // The export's own lease disables workspace writes, but Cancel
                    // must remain available so the duplex source operation can stop.
                    .environment(\.isEnabled, true)
            }
        }
    }

    private func checkBindings(_ state: LayerTreeNode.CheckState) -> [Binding<Bool>] {
        (state == .mixed ? [true, false] : [state == .checked]).map { value in
            Binding(get: { value }, set: { checked in
                Task { await session.perform(.visibility(id: node.id, checked: checked)) }
            })
        }
    }
    @ViewBuilder private var visibilityControl: some View {
        if isTransientTerrainInput {
            if let context = session.activeContext,
               context.projectSessionID == store.projectSessionID,
               let mapState = store.existingMapState(for: context.mapID) {
                let workflowIdentity = store.mapSourceWorkflowIdentity(context.mapID)
                TerrainInputVisibilityToggle(node: node, mapID: context.mapID,
                    projectSessionID: context.projectSessionID,
                    mapSession: mapState.terrainInputMap,
                    isCurrent: {
                        session.activeContext == context
                            && store.projectSessionID == context.projectSessionID
                            && store.existingMapState(for: context.mapID) === mapState
                            && store.mapSourceWorkflowIdentity(context.mapID) == workflowIdentity
                    },
                    setVisibility: { checked in
                        Task { _ = await store.setSourceMapVisibility(node, checked: checked, mapID: context.mapID) }
                    })
            } else {
                Toggle("Visible", isOn: .constant(false)).toggleStyle(.checkbox).labelsHidden().disabled(true)
            }
        } else if let checked = node.checked {
            Toggle("Visible", sources: checkBindings(checked), isOn: \.self)
                .toggleStyle(.checkbox)
                .labelsHidden()
        }
    }
    private var isTransientTerrainInput: Bool {
        node.id.hasPrefix("terrain-input:") && [
            "ChannelModTerrainInputParentVC", "LeveeModTerrainInputVC",
            "PolygonRasterModTerrainInputVisualContext"
        ].contains(node.sourceClass)
    }

    private func beginRename() {
        name = node.name
        renaming = true
        editingName = true
    }

    private var connection: ProjectConnection? {
        CatalogConnectionNodeRoute.connection(for: node, in: store.document?.connections ?? [])
    }

    private var mapDocument: MapDocument? {
        guard node.sourceClass == "MapDocumentNode",
              let rawID = node.id.split(separator: ":", maxSplits: 1).last,
              let id = UUID(uuidString: String(rawID)) else { return nil }
        return store.mapDocument(for: id)
    }

    private func openNode() {
        if node.sourceClass == "FolderNode", node.canRename { beginRename(); return }
        if let map = mapDocument { openMap(map); return }
        if let connection {
            store.selectConnection(connection)
            store.showConnectionManager = true
            return
        }
        if let id = node.assetID, let asset = store.assets.first(where: { $0.id == id }) {
            store.edit(asset, fromTree: true)
        }
    }

    private func openMap(_ map: MapDocument) {
        store.openMapDocument(map)
    }

    private func invoke(_ item: ContextMenuEntry, _ value: ContextMenuValue?) {
        guard item.enabled else { return }
        if item.prompt != nil || item.confirmation != nil {
            commandValue = item.prompt?.initialValue ?? ""
            pendingValue = value
            pendingMenu = item
        } else {
            execute(item, value)
        }
    }

    private func execute(_ item: ContextMenuEntry, _ value: ContextMenuValue?) {
        Task { await session.perform(.contextCommand(nodeID: node.id, commandID: item.id, value: value)) }
    }

    private func rename() {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        renaming = false
        if name != node.name { Task { await session.perform(.rename(id: node.id, name: name)) } }
    }
}

private struct LayerCatalogDrag: ViewModifier {
    let id: String
    let enabled: Bool
    func body(content: Content) -> some View {
        if enabled { content.draggable(id) } else { content }
    }
}
