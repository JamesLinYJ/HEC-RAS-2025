import RASWorkspaceCore
import SwiftUI

enum CatalogGroup: String, CaseIterable, Identifiable {
    // RasCatalogTree.InitializeDefaultNodes model order, distinct from RasTreeV2.
    case terrains = "Terrains", geometries = "Geometries", nValues = "NValues"
    case boundaryConditions = "Boundary Conditions", plans = "Plans", results = "Results", classifications = "Classifications"
    case surfaceLayers = "Surface Layers"
    var id: String { rawValue }
    var kind: ModelEditorKind {
        switch self {
        case .terrains: .terrain
        case .geometries: .geometry
        case .nValues, .classifications, .surfaceLayers: .surface
        case .boundaryConditions: .boundaryCondition
        case .plans: .plan
        case .results: .result
        }
    }
}

struct WorkspaceSidebar: View {
    @ObservedObject var store: WorkspaceStore
    var body: some View {
        VStack(spacing: 0) {
            Picker("Sidebar", selection: $store.sidebarSection) {
                ForEach(WorkspaceSidebarKind.allCases) { Text(L10n.text($0.rawValue)).tag($0) }
            }
                .pickerStyle(.segmented).labelsHidden().padding(8)
            if store.sidebarSection == .catalog {
                if store.catalogTreeSession.roots != nil {
                    LayerCatalogPaneView(store: store, session: store.catalogTreeSession)
                } else { CatalogPane(store: store) }
            }
            else { ProjectTreePane(store: store) }
        }
        .task(id: store.catalogTreeContext) {
            await store.catalogTreeSession.load(provider: store.catalogTreeProvider, context: store.catalogTreeContext)
        }
        .overlay(alignment: .bottom) {
            if store.sidebarSection == .catalog, store.catalogTreeSession.busy, store.catalogTreeSession.roots == nil {
                ProgressView().controlSize(.small).padding(10).workspaceGlass()
            }
        }
        .alert("HEC-RAS 2025", isPresented: Binding(get: { store.catalogTreeSession.error != nil }, set: { if !$0 { store.catalogTreeSession.error = nil } })) {
            Button("OK") { store.catalogTreeSession.error = nil }
        } message: { Text(store.catalogTreeSession.error ?? "") }
    }
}

struct CatalogPane: View {
    @ObservedObject var store: WorkspaceStore
    @State private var selection: String?
    @State private var query = ""
    @State private var expanded = Set(CatalogGroup.allCases)
    @State private var renameMapID: UUID?
    @State private var mapName = ""
    @State private var showRenameMap = false
    @State private var connectionRenameRequest: ExternalConnectionRenameRequest?
    @State private var connectionRemovalRequest: ExternalConnectionRemovalRequest?
    @State private var showingConnectionRemovalConfirmation = false
    @StateObject private var surfaces = SurfaceCatalogSession()
    var body: some View {
        VStack(spacing: 0) {
            CatalogPaneHeader(store: store)
            TextField("Search catalog", text: $query).textFieldStyle(.roundedBorder).padding(.horizontal, 8).padding(.bottom, 8)
            List(selection: $selection) {
                Section("Project") {
                    ForEach(CatalogGroup.allCases) { group in
                        if group != .surfaceLayers || !items(group).isEmpty {
                        DisclosureGroup(isExpanded: Binding(get: { expanded.contains(group) }, set: {
                            if $0 { expanded.insert(group) } else { expanded.remove(group) }
                        })) {
                            ForEach(items(group)) { asset in
                                let modelTarget = CatalogModelActionTarget.resolve(asset: asset, group: group)
                                Label(asset.name, systemImage: group.kind.symbol).tag(asset.id)
                                    .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                                    .help(surfaces.entries[asset.id]?.error.map(L10n.text) ?? asset.url.path)
                                    .draggable(asset.id)
                                    .onTapGesture(count: 2) { store.edit(asset) }
                                    .contextMenu {
                                        if let modelTarget {
                                            CatalogModelActionMenuItems(store: store, asset: modelTarget.asset,
                                                kind: modelTarget.kind, caller: .catalog)
                                            if modelTarget.kind == .terrain {
                                                Button("Open Editor", systemImage: "pencil") {
                                                    store.openEditor(.terrain, assetID: modelTarget.asset.id)
                                                }
                                                .disabled(store.isRunningProjectTool || store.isSavingAll
                                                    || store.isClosingTab || store.isOpeningProject)
                                            }
                                            if modelTarget.kind == .classification {
                                                Button("Open Editor", systemImage: "pencil") {
                                                    store.openEditor(.surface, assetID: modelTarget.asset.id)
                                                }
                                                .disabled(store.isRunningProjectTool || store.isSavingAll
                                                    || store.isClosingTab || store.isOpeningProject)
                                            }
                                            if modelTarget.kind == .terrain {
                                                Button("Set as Default Terrain", systemImage: "checkmark.circle") {
                                                    store.setDefaultTerrain(asset.name)
                                                }
                                                .disabled(store.isRunningProjectTool || store.isSavingAll
                                                    || store.document?.defaultTerrain == asset.name)
                                            }
                                            if modelTarget.kind == .plan {
                                                Button("Export Plan…", systemImage: "square.and.arrow.up") {
                                                    store.select(asset, clearTreeSelection: false)
                                                    store.activeTool = .planExport
                                                }
                                                .disabled(store.isRunningProjectTool || store.isSavingAll
                                                    || store.isClosingTab || store.isOpeningProject)
                                            }
                                            Divider()
                                        }
                                        Button("Edit") { store.edit(asset) }
                                        if group == .geometries || group == .plans { Button("Focus") { store.focus(asset) } }
                                        Button("Properties") { store.select(asset); store.showInspector = true }
                                        Button("Show in Finder") { store.system.reveal(asset.url) }
                                        Button("Copy File Path") { store.system.copy(asset.url.path) }
                                    }
                            }
                        } label: {
                            Label(LocalizedStringKey(group.rawValue), systemImage: group.kind.symbol)
                                .contextMenu { Button("Open Editor") { store.openEditor(group.kind) } }
                        }
                        }
                    }
                }
                Section("External Connections") {
                    Button("Manage Connections…") { store.showConnectionManager = true }.buttonStyle(.borderless)
                    ForEach(store.document?.connections ?? []) { connection in
                        Label(connection.name, systemImage: connection.type == "Directory" ? "folder.badge.gearshape" : "link").tag("connection/" + connection.id)
                            .help(connection.relativePath.isEmpty ? connection.absolutePath : connection.relativePath)
                            .contextMenu {
                                Button("Properties") { store.selectConnection(connection); store.showInspector = true }
                                Button("Manage Connections…") { store.selectConnection(connection); store.showConnectionManager = true }
                                Button("Show in Finder") { store.revealConnection(connection) }
                                Button("Copy File Path") { store.system.copy(connection.relativePath.isEmpty ? connection.absolutePath : connection.relativePath) }
                                Button("Rename…") {
                                    connectionRenameRequest = ExternalConnectionRenameRequest(connection: connection, projectID: store.projectSessionID)
                                }
                                Button("Remove Connection", role: .destructive) {
                                    connectionRemovalRequest = ExternalConnectionRemovalRequest(connection: connection, projectID: store.projectSessionID)
                                    showingConnectionRemovalConfirmation = true
                                }.disabled(store.isSavingAll || store.isRunningProjectTool || store.isOpeningProject || store.isClosingTab)
                            }
                    }
                }
                Section("Maps") {
                    Label("Project Map", systemImage: "map").tag("project-map")
                        .onTapGesture { store.page = .map }
                    ForEach(store.mapDocuments) { map in
                        Label(map.name, systemImage: "map").tag("map/" + map.id.uuidString)
                            .onTapGesture { store.activeTab = .map(map.id) }
                            .contextMenu {
                                Button("Rename…") { renameMapID = map.id; mapName = map.name; showRenameMap = true }
                                Button("Close Tab") { store.requestCloseTab(.map(map.id)) }
                            }
                    }
                }
            }.listStyle(.sidebar)
            .onChange(of: selection) { _, selected in
                if let asset = store.assets.first(where: { $0.id == selected }) { store.select(asset) }
                else if let connection = store.document?.connections.first(where: { "connection/" + $0.id == selected }) { store.selectConnection(connection) }
            }
            .onChange(of: store.projectSessionID) { _, _ in selection = nil }
            if surfaces.busy { ProgressView().controlSize(.small) }
            if let error = surfaces.error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled).padding(8) }
        }
        .task(id: SurfaceCatalogKey(projectID: store.projectSessionID, revision: store.assetsRevision)) {
            await surfaces.load(store.assets.filter { $0.section == .surfaceLayers }, provider: store.modelProvider)
        }
        .onDisappear { surfaces.invalidate() }
        .sheet(item: $connectionRenameRequest) { request in
            ExternalConnectionRenameSheet(store: store, request: request)
        }
        .confirmationDialog("Remove Connection", isPresented: $showingConnectionRemovalConfirmation, titleVisibility: .visible) {
            Button("Remove Connection", role: .destructive) { removeConfirmedConnection() }
            Button("Cancel", role: .cancel) { connectionRemovalRequest = nil }
        } message: {
            Text(L10n.text("Deleting this external connection will disconnect it from any attached boundary condition lines, etc."))
        }
        .alert("Rename Map", isPresented: $showRenameMap) {
            TextField("Map Name", text: $mapName)
            Button("Rename") { if let id = renameMapID { store.renameMap(id, name: mapName) } }.disabled(mapName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) {}
        }
    }
    private func removeConfirmedConnection() {
        defer { connectionRemovalRequest = nil }
        guard let connectionRemovalRequest else { return }
        store.removeExternalConnectionAfterConfirmation(connectionRemovalRequest.connection, projectID: connectionRemovalRequest.projectID)
    }
    private func items(_ group: CatalogGroup) -> [ProjectAsset] {
        if [.nValues, .classifications, .surfaceLayers].contains(group) {
            return store.assets.filter { asset in
                guard asset.section == .surfaceLayers, asset.url.pathExtension.lowercased() == "h5", query.isEmpty || asset.name.localizedCaseInsensitiveContains(query) else { return false }
                let category = surfaces.entries[asset.id]?.category
                return group == .surfaceLayers ? ![CatalogGroup.nValues.rawValue, CatalogGroup.classifications.rawValue].contains(category ?? "") : category == group.rawValue
            }
        }
        return store.assets.filter { $0.section == group.kind.section
            && (group == .terrains ? ["h5", "s3"].contains($0.url.pathExtension.lowercased()) : $0.url.pathExtension.lowercased() == "h5")
            && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)) }
    }
}

private struct SurfaceCatalogKey: Hashable { let projectID: UUID; let revision: Int }

