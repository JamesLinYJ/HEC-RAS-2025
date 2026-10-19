import AppKit
import RASWorkspaceCore
import SwiftUI

private struct WorkspaceGDALInformationActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
    var workspaceGDALInformationAction: (() -> Void)? {
        get { self[WorkspaceGDALInformationActionKey.self] }
        set { self[WorkspaceGDALInformationActionKey.self] = newValue }
    }
}

// RasMainWindow / RasContent: menu above a three-pane dock; map remains the
// main work surface. Native split views retain resizable pane interaction.
struct WorkspaceView: View {
    @ObservedObject var store: WorkspaceStore
    @StateObject private var updateSession: UpdateSession
    @State private var showGDALInformation = false
    @Environment(\.openWindow) private var openWindow

    init(store: WorkspaceStore) {
        self.store = store
        let session = UpdateSession(provider: store.updateProvider)
        session.channel = store.updateInitialChannel
        _updateSession = StateObject(wrappedValue: session)
    }

    var body: some View {
        VStack(spacing: 0) {
            if store.hasProject {
                if let projectURL = store.document?.url {
                    WorkspaceEnvironmentNotices(projectURL: projectURL)
                }
                NavigationSplitView(columnVisibility: Binding(
                    get: { store.showProjectTree ? .all : .detailOnly },
                    set: { store.showProjectTree = $0 != .detailOnly }
                )) {
                    WorkspaceSidebar(store: store)
                        .navigationSplitViewColumnWidth(min: 210, ideal: 250, max: 300)
                } detail: {
                    VSplitView {
                        WorkspaceDocumentView(store: store)
                            .id(store.projectSessionID)
                            .frame(minWidth: 380, maxWidth: .infinity, minHeight: 360, maxHeight: .infinity)
                        if store.showMessages { MessagesPane(store: store).frame(minHeight: 120, idealHeight: 170, maxHeight: 300) }
                    }
                    .inspector(isPresented: $store.showInspector) {
                        InspectorPane(store: store)
                            .inspectorColumnWidth(min: 260, ideal: 300, max: 360)
                    }
                }
                .navigationSplitViewStyle(.balanced)
            } else if store.isFirstLaunch { FirstLaunchView(store: store) }
            else { projectExplorer }
            Divider(); WorkspaceStatusBar(store: store)
        }
        .disabled(store.isSavingAll || store.isClosingTab || store.isOpeningProject)
        .overlay {
            if let project = store.openingProject { ProjectOpeningView(project: project, cancel: store.cancelProjectOpening) }
        }
        .focusedSceneValue(\.workspaceDocumentActions, WorkspaceDocumentActions(canCloseTab: store.canCloseActiveTab, closeTab: store.requestCloseActiveTab))
        .focusedSceneValue(\.workspaceGDALInformationAction, { showGDALInformation = true })
        .navigationTitle(store.document?.name ?? "HEC-RAS 2025")
        .toolbar { WorkspaceToolbar(store: store, showGDALInformation: $showGDALInformation) }
        .onAppear { store.showWorkspace = { openWindow(id: "workspace") } }
        .sheet(isPresented: $store.showNewProject) { NewProjectSheet(store: store) }
        .sheet(item: $store.surfaceCreation) { kind in
            if let projectPath = store.document?.url?.path, let backend = store.modelProvider as? BackendModelProvider {
                let projectID = store.projectSessionID
                SurfaceCreationDialog(kind: kind, projectSessionID: projectID,
                    projectPath: projectPath,
                    coreLayerContext: store.surfaceCreationCoreLayerContext,
                    projectXML: { store.document?.editorXML(overridingDescription: store.descriptionDraft) ?? "" },
                    currentProjectSessionID: { store.projectSessionID },
                    currentCoreLayerContext: { store.captureCoreLayerRequestContext() },
                    provider: BackendSurfaceCreationProvider(client: backend.client),
                    onRunningChanged: store.setSurfaceCreationRunning,
                    onCreated: { store.completeSurfaceCreation($0, kind: kind, projectID: projectID) })
            }
        }
        .sheet(item: $store.projectMigration, onDismiss: store.finishProjectMigrationPresentation) { presentation in
            ProjectMigrationDialog(defaultDestinationDirectory: store.projectDirectory,
                sourceURL: presentation.sourceURL,
                authorizedSourceDirectory: presentation.authorizedSourceDirectory,
                onProjectOpened: store.completeProjectMigration)
        }
        .sheet(isPresented: $store.showProjection) { ProjectionSheet(store: store) }
        .sheet(isPresented: $store.showSearch) { ActionSearchSheet(store: store) }
        .sheet(isPresented: $store.showConnectionManager) { ConnectionManagerView(store: store) }
        .sheet(isPresented: $store.showConnectionEditor) { ConnectionEditorSheet(store: store) }
        .sheet(isPresented: $store.showSavedViews) { SavedViewsSheet(store: store) }
        .sheet(isPresented: $store.showUpdates) { UpdateView(store: store, session: updateSession) }
        .sheet(isPresented: $showGDALInformation) { GdalInformationView(store: store) }
        .sheet(isPresented: $store.showDeveloperTools) { DeveloperToolsView(store: store) }
        .sheet(isPresented: $store.showZoomLocation) { ZoomLocationSheet(store: store) }
        .sheet(item: $store.activeTool) { kind in ToolRoute(store: store, kind: kind) }
        .catalogModelActionPresentationSheet(store: store)
        .sheet(isPresented: $store.showProjectLibrary, onDismiss: store.finishLibraryPresentation) {
            VStack {
                ProjectLibraryView(store: store)
                HStack { Spacer(); Button("Done") { store.showProjectLibrary = false }.keyboardShortcut(.cancelAction) }.padding(12)
            }.frame(width: 880, height: 600)
        }
        .alert("Save changes to this project?", isPresented: $store.showDiscardConfirmation) {
            Button("Save", action: store.saveAndContinue)
            Button("Discard", role: .destructive, action: store.discardAndContinue)
            Button("Cancel", role: .cancel, action: store.cancelReplacement)
        } message: { Text("Your unsaved edits will be lost if you continue without saving.") }
        .alert("Save changes to this model?", isPresented: $store.showCloseTabConfirmation) {
            if store.pendingCloseTabAllowsSave {
                Button("Save") { Task { await store.saveAndCloseTab() } }
            }
            Button("Discard", role: .destructive, action: store.discardAndCloseTab)
            Button("Cancel", role: .cancel, action: store.cancelCloseTab)
        } message: { Text("Your unsaved edits will be lost if you close without saving.") }
        .alert("HEC-RAS 2025", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("OK") { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
        .task(id: "\(store.hasProject)-\(store.isFirstLaunch)") {
            guard !store.hasProject, !store.isFirstLaunch, updateSession.state == .idle else { return }
            await updateSession.check()
        }
        .onChange(of: store.updateInitialChannel) { _, channel in
            guard updateSession.channel != channel else { return }
            updateSession.channel = channel
            Task { await updateSession.check() }
        }
    }

    private var projectExplorer: some View {
        VStack(spacing: 0) {
            if updateSession.state == .available,
               let release = updateSession.snapshot?.releases.first(where: { $0.isCompatible }) {
                AppShellUpdateAvailableBanner(release: release) {
                    store.updateInitialChannel = updateSession.channel
                    store.showUpdates = true
                }
                Divider()
            }
            ProjectExplorerView(store: store)
        }
    }
}

// These are real SwiftUI toolbar items. On macOS 26 and later the system
// supplies Liquid Glass, grouping, hover behavior, and accessibility.
struct WorkspaceToolbar: ToolbarContent {
    @ObservedObject var store: WorkspaceStore
    @Binding var showGDALInformation: Bool
    @Environment(\.openWindow) private var openWindow
    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Menu("File") {
                Button("New Project…", action: store.requestNewProject)
                Button("Open Project…", action: store.openPanel)
                Button("Example and Synthetic Projects…") { store.showProjectLibrary = true }
                Menu("Recent Projects") { ForEach(store.recentProjects, id: \.path) { url in Button(url.deletingPathExtension().lastPathComponent) { store.requestOpen(url) } } }
                Divider()
                Button("Save All") { Task { await store.saveAll() } }.disabled(!store.hasProject)
                Button("Save Project As…") { store.save(asCopy: true) }.disabled(true)
                Button("Reload Project", action: store.requestReload).disabled(!store.hasProject)
                Divider(); Button("Open Folder", action: store.revealProject).disabled(!store.hasProject)
                Button("Close Project", action: store.requestClose).disabled(!store.hasProject)
                Button("Close Tab", action: store.requestCloseActiveTab).disabled(!store.canCloseActiveTab)
            }
            Menu("View") {
                Button("Toggle Full Screen", action: store.system.toggleFullScreen).keyboardShortcut("f", modifiers: [.control, .command])
                Divider()
                Toggle("Project Tree", isOn: $store.showProjectTree)
                Toggle("Properties", isOn: $store.showInspector)
                Toggle("Messages", isOn: $store.showMessages)
                Divider()
                ForEach(WorkspacePage.allCases) { page in Button(L10n.text(page.rawValue)) { store.page = page }.disabled(!store.hasProject) }
                Divider()
                Button("Reset Layout") { store.showProjectTree = true; store.showInspector = true; store.showMessages = false }
            }
            Menu("Map") {
                WorkspaceNewMapFlyout(
                    createBlankMap: store.addBlankMapDocument,
                    createProjectMap: store.addProjectMapDocument
                ).disabled(!store.hasProject)
                GeometryMapCommandMenu(store: store)
                PlanMapCommandMenu(store: store)
                Button("Add Map Layer…", action: store.addMapLayer)
                    .disabled(!store.hasProject || store.activeMapState.kind == .unsupported)
                Button("Saved Views…") { store.showSavedViews = true }.disabled(!store.hasProject)
                Button("Save Current View", action: store.saveCurrentView).disabled(!store.hasProject || !store.canEditSavedViews || store.activeMapState.currentExtent == nil)
                Button("Zoom to Full Extent") { store.zoomToFullExtent() }.disabled(!store.hasProject)
                Button("Zoom to Location…") { store.showZoomLocation = true }.disabled(!store.hasProject)
                Toggle("Coordinate Grid", isOn: $store.showGrid)
                Toggle("Map Overview", isOn: $store.showMinimap)
                Toggle("Map Legend", isOn: $store.showLegend)
            }
            Menu("Tools") {
                Button("Chat") { store.chatIsOpen = true; store.activeTab = .chat }.disabled(!store.hasProject)
                Divider()
                ForEach(["Create", "Import", "Export", "Map Tools", "Analysis", "Tags", "Support"], id: \.self) { group in
                    Menu {
                        ForEach(ToolKind.generalMenuCases.filter { $0.group == group }) { tool in
                            Button { store.activeTool = tool } label: { Text(verbatim: tool.localizedTitle) }
                                .disabled(tool.requiresProject && !store.hasProject)
                        }
                    } label: {
                        Text(verbatim: L10n.text(group))
                    }
                }
                Divider()
                Menu("Model Editors") {
                    ForEach(ModelEditorKind.allCases) { kind in
                        Button(L10n.text(kind.rawValue)) { store.openEditor(kind) }.disabled(!store.hasProject)
                    }
                }
                Button("Project Associations") { store.page = .associations }.disabled(!store.hasProject)
                Button("Projection…") { store.showProjection = true }.disabled(!store.hasProject)
                Button("Refresh Project Files", action: store.refreshAssets).disabled(!store.hasProject)
                Divider()
                Button(L10n.text("GDAL Information…"), systemImage: "globe.americas") { showGDALInformation = true }
                Divider(); SettingsLink { Text("Options…") }
                Toggle("Developer Mode", isOn: $store.isDebugMode)
                if store.isDebugMode {
                    Menu("Developer Options") {
                        Button("Developer Tools…") { store.showDeveloperTools = true }
                        Divider()
                        Toggle("Enhanced Mesh Checks", isOn: $store.enhancedMeshChecks)
                        Toggle("Partial Mesh Recomplete", isOn: $store.partialMeshRecomplete)
                        Toggle("Force Internal Matrix Solver", isOn: $store.forceInternalMatrixSolver)
                    }
                }
                Menu("Language") {
                    Button("System") { store.setLanguage("System") }
                    Button("简体中文") { store.setLanguage("zh-Hans") }
                    Button("English") { store.setLanguage("en") }
                }
            }
            Menu("Help") { HelpMenuContents(store: store) }
        }
        ToolbarItem(placement: .principal) {
            Button { store.showSearch = true } label: { Label("Search actions", systemImage: "magnifyingglass") }
                .help("Search actions · ⇧⌘P")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if store.canCloseActiveTab {
                Button(action: store.requestCloseActiveTab) { Label("Close Tab", systemImage: "xmark") }
            }
            Button {
                let route: DetachedDocumentRoute
                if case .editor(let kind) = store.activeTab { route = DetachedDocumentRoute(projectSessionID: store.projectSessionID, editor: kind.rawValue, mapID: nil) }
                else if case .map(let id) = store.activeTab { route = DetachedDocumentRoute(projectSessionID: store.projectSessionID, editor: nil, mapID: id) }
                else if case .chatDisplay(let id) = store.activeTab { route = DetachedDocumentRoute(projectSessionID: store.projectSessionID, editor: nil, mapID: nil, chatDisplayID: id) }
                else { route = DetachedDocumentRoute(projectSessionID: store.projectSessionID, editor: nil, mapID: nil) }
                openWindow(value: route)
            } label: { Label("Open in New Window", systemImage: "macwindow.on.rectangle") }.disabled(!store.hasProject)
            Button { store.showJobs.toggle() } label: { Label("Jobs", systemImage: store.jobs.contains(where: { !$0.isComplete }) ? "hourglass" : "checklist") }
                .popover(isPresented: $store.showJobs) { JobsPopover(store: store) }
            if store.hasUnsavedChanges { Image(systemName: "circle.fill").font(.system(size: 6)).help("Unsaved changes") }
            if store.isSavingAll { ProgressView().controlSize(.small).help("Saving…") }
            Button { Task { await store.saveAll() } } label: { Label("Save All", systemImage: "square.and.arrow.down") }.disabled(!store.hasUnsavedChanges || store.isSavingAll)
            Menu {
                ForEach(["System", "Light", "Dark"], id: \.self) { theme in Button(L10n.text(theme)) { store.setTheme(theme) } }
            } label: { Label("Theme", systemImage: store.theme == "Dark" ? "moon" : "sun.max") }
            Button { store.showMessages.toggle() } label: { Label("Messages", systemImage: store.messages.contains(where: \.isError) ? "exclamationmark.bubble" : "bell") }
            Button { store.showInspector.toggle() } label: { Label("Properties", systemImage: "sidebar.right") }
                .disabled(!store.hasProject)
        }
    }
}

struct WorkspaceDocumentView: View {
    @ObservedObject var store: WorkspaceStore
    var body: some View {
        TabView(selection: $store.activeTab) {
            ProjectMapView(store: store).tabItem { Label("Map", systemImage: "map") }.tag(WorkspaceTab.page(.map))
            AssociationsView(store: store).tabItem { Label("Associations", systemImage: "point.3.connected.trianglepath.dotted") }.tag(WorkspaceTab.page(.associations))
            ProjectPropertiesView(store: store).tabItem { Label("Project", systemImage: "doc.text") }.tag(WorkspaceTab.page(.project))
            ForEach(store.openEditors) { kind in
                ModelEditorWorkspace(store: store, kind: kind)
                    .tabItem { Label(LocalizedStringKey(kind.rawValue), systemImage: kind.symbol) }
                    .tag(WorkspaceTab.editor(kind))
            }
            ForEach(store.mapDocuments) { map in
                ProjectMapView(store: store, mapID: map.id)
                    .tabItem {
                        Label {
                            Text(verbatim: map.name)
                        } icon: {
                            Image(systemName: map.kind == .geometry
                                ? "point.3.connected.trianglepath.dotted"
                                : map.kind == .plan ? "play.rectangle" : "map")
                        }
                    }.tag(WorkspaceTab.map(map.id))
            }
            if store.chatIsOpen {
                ChatView(store: store).tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right") }.tag(WorkspaceTab.chat)
            }
            ForEach(store.chatDisplayDocuments) { document in
                ChatDisplayView(payload: document.payload, objects: document.objects, store: store, fillsDocument: true)
                    .padding(20).tabItem { Label(document.payload.displayTitle, systemImage: document.payload.symbol) }
                    .tag(WorkspaceTab.chatDisplay(document.id))
            }
        }
    }
}

struct ProjectTreePane: View {
    @ObservedObject var store: WorkspaceStore
    @State private var expanded = Set(ProjectSection.allCases)
    var body: some View {
        VStack(spacing: 0) {
            PaneHeading(title: "Project", symbol: "folder") {
                Button(action: store.refreshAssets) { Image(systemName: "arrow.clockwise") }.help("Refresh project files")
            }
            Picker("Tree mode", selection: $store.treeMode) { ForEach(TreeMode.allCases) { Text(L10n.text($0.rawValue)).tag($0) } }
                .pickerStyle(.segmented).labelsHidden().controlSize(.small).padding(8)
            TextField("Filter project", text: $store.filter).textFieldStyle(.roundedBorder).padding(.horizontal, 8).padding(.bottom, 8)
            if store.layerTreeSession.roots != nil {
                LayerTreeView(store: store, session: store.layerTreeSession)
            } else { List(selection: $store.selectedAssetID) {
                Button {
                    store.selectedAssetID = nil; store.selectedSection = nil
                } label: {
                    Label(store.document?.name ?? "Project", systemImage: "folder.fill").fontWeight(.semibold).lineLimit(1)
                }.buttonStyle(.plain)
                if store.treeMode != .project {
                    Section(LocalizedStringKey(store.treeMode == .geometry ? "Focused Geometries" : "Focused Plans")) {
                        ForEach(store.focusedAssets) { FocusedAssetRow(store: store, asset: $0) }
                    }
                    if !store.matchingAssets.isEmpty {
                        Section("Matching Layers") { ForEach(store.matchingAssets) { FocusedAssetRow(store: store, asset: $0) } }
                    }
                    Section("Layers") {
                        ForEach(store.assets.filter { asset in store.mapLayers.contains(where: { layer in layer.id == asset.id }) }) { FocusedAssetRow(store: store, asset: $0) }
                    }
                } else {
                ForEach(store.visibleSections) { section in
                    let items = store.assets.filter { $0.section == section && (store.filter.isEmpty || $0.name.localizedCaseInsensitiveContains(store.filter)) }
                    if store.filter.isEmpty || !items.isEmpty {
                        DisclosureGroup(isExpanded: Binding(get: { expanded.contains(section) }, set: { if $0 { expanded.insert(section) } else { expanded.remove(section) } })) {
                            ForEach(items) { asset in
                                HStack {
                                        Image(systemName: section.symbol).foregroundStyle(.secondary)
                                        Text(asset.name).lineLimit(1)
                                        Spacer(minLength: 0)
                                        if store.mapLayers.contains(where: { $0.id == asset.id }) {
                                            Toggle("Visible", isOn: Binding(get: { !store.hiddenMapLayers.contains(asset.id) }, set: { if $0 { store.hiddenMapLayers.remove(asset.id) } else { store.hiddenMapLayers.insert(asset.id) } }))
                                                .labelsHidden().toggleStyle(.checkbox).help("Layer visibility")
                                        }
                                    }
                                .tag(asset.id)
                                .draggable(asset.id)
                                .onTapGesture(count: 2) { store.edit(asset) }
                                .contextMenu {
                                    Button("Edit") { store.edit(asset) }
                                    Button("Properties") { store.select(asset); store.showInspector = true }
                                    Button("Show in Finder") { store.system.reveal(asset.url) }
                                    Button("Copy File Path") { store.system.copy(asset.url.path) }
                                }
                                .help(asset.url.path)
                            }
                        } label: {
                            HStack {
                                Label(L10n.text(section.rawValue), systemImage: section.symbol)
                                Spacer(); if !items.isEmpty { Text(items.count.formatted()).font(.caption).foregroundStyle(.tertiary) }
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { store.selectedSection = section; store.selectedAssetID = nil }
                        }
                    }
                }
                }
            }
            .listStyle(.sidebar)
            .onChange(of: store.selectedAssetID) { _, id in
                if let asset = store.assets.first(where: { $0.id == id }) { store.select(asset) }
            }
            }
            Divider()
            HStack {
                Text(L10n.format("%d files", store.assets.count)).font(.caption).foregroundStyle(.secondary)
                Spacer(); Button(action: store.revealProject) { Image(systemName: "folder") }.buttonStyle(.borderless).help("Open project folder")
            }.padding(9)
        }
        .task(id: store.layerTreeContext) { await store.layerTreeSession.load(provider: store.layerTreeProvider, context: store.layerTreeContext) }
        .alert("HEC-RAS 2025", isPresented: Binding(get: { store.layerTreeSession.error != nil }, set: { if !$0 { store.layerTreeSession.error = nil } })) {
            Button("OK") { store.layerTreeSession.error = nil }
        } message: { Text(L10n.text(store.layerTreeSession.error ?? "")) }
    }
}

struct FocusedAssetRow: View {
    @ObservedObject var store: WorkspaceStore
    let asset: ProjectAsset
    var body: some View {
        Label { Text(verbatim: asset.name) } icon: { Image(systemName: asset.section.symbol) }
            .tag(asset.id)
            .draggable(asset.id)
            .onTapGesture(count: 2) { store.edit(asset) }
            .contextMenu {
                Button("Edit") { store.edit(asset) }
                Button("Properties") { store.select(asset); store.showInspector = true }
                if asset.section == .geometries && asset.isModelFile {
                    Button("Focus in New View", systemImage: "arrow.up.right.square") {
                        let projectID = store.projectSessionID
                        Task { @MainActor in
                            guard projectID == store.projectSessionID else { return }
                            _ = await runGeometryFocusInNewView(assetID: asset.id, store: store)
                        }
                    }
                    .disabled(store.isRunningProjectTool || store.isSavingAll
                        || store.isOpeningProject || store.isClosingTab)
                }
                if asset.section == .plans && asset.isModelFile {
                    Button("Focus in New View", systemImage: "arrow.up.right.square") {
                        let projectID = store.projectSessionID
                        Task { @MainActor in
                            guard projectID == store.projectSessionID else { return }
                            _ = await runPlanFocusInNewView(assetID: asset.id, store: store)
                        }
                    }
                    .disabled(store.isRunningProjectTool || store.isSavingAll
                        || store.isOpeningProject || store.isClosingTab)
                }
                Button("Remove Focus") { store.focusedGeometryIDs.remove(asset.id); store.focusedPlanIDs.remove(asset.id) }
            }
    }
}

struct InspectorPane: View {
    @ObservedObject var store: WorkspaceStore
    var body: some View {
        VStack(spacing: 0) {
            PaneHeading(title: store.inspectorMode.rawValue, symbol: "slider.horizontal.3") {
                Button { store.showInspector = false } label: { Image(systemName: "xmark") }.help("Hide properties pane")
            }
            Picker("Inspector", selection: $store.inspectorMode) { ForEach(InspectorMode.allCases) { Text(L10n.text($0.rawValue)).tag($0) } }
                .pickerStyle(.segmented).labelsHidden().controlSize(.small).padding(8)
            Form {
                    if store.inspectorMode == .components {
                        MapContextComponentsPane(store: store, mapState: store.activeMapState)
                    } else if let node = store.inspectorTreeSession.selectedNode {
                        CatalogNodeDetailsView(node: node, store: store, session: store.inspectorTreeSession)
                    } else if let connection = store.selectedConnection {
                        ConnectionCatalogSummary(store: store, connection: connection)
                    } else if let asset = store.selectedAsset {
                        CatalogAssetInspectorSummaryView(asset: asset,
                            node: LayerTreeNode(id: asset.id, sourceClass: "ProjectAsset",
                                name: asset.name, assetID: asset.id), store: store)
                        PropertyValue("Type", value: L10n.text(asset.section.rawValue))
                        PropertyValue("Location", value: asset.url.deletingLastPathComponent().path)
                        if let layer = store.mapLayers.first(where: { $0.id == asset.id }) {
                            PropertyValue("Features", value: layer.features.count.formatted())
                            PropertyValue("Coordinates", value: layer.points.count.formatted())
                            Toggle("Visible", isOn: Binding(get: { !store.hiddenMapLayers.contains(layer.id) }, set: { if $0 { store.hiddenMapLayers.remove(layer.id) } else { store.hiddenMapLayers.insert(layer.id) } }))
                        }
                        if let values = try? asset.url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) {
                            if let size = values.fileSize { PropertyValue("Size", value: ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)) }
                            if let date = values.contentModificationDate { PropertyValue("Modified", value: date.formatted()) }
                        }
                        Button("Edit") { store.edit(asset) }
                        Button("Show in Finder", action: store.revealSelected)
                    } else if let document = store.document {
                        ProjectDocumentCatalogSummaryHeaderView(name: document.name)
                        if let url = document.url { CatalogFilePath(title: "Filename", path: url.path, store: store) }
                        PropertyValue("Location", value: document.directory?.path ?? "Unsaved project")
                        PropertyValue("Projection", value: L10n.text(document.projectionType.isEmpty ? "Not specified" : document.projectionType))
                        PropertyValue("Definition", value: document.projectionValue)
                        Button("Edit Projection…") { store.showProjection = true }
                        Divider()
                        Text("Description").font(.subheadline.weight(.medium))
                        TextEditor(text: $store.descriptionDraft).font(.body)
                            .frame(minHeight: 120).border(Color(nsColor: .separatorColor))
                            .accessibilityLabel("Project description")
                        HStack { Spacer(); Button("Save") { Task { await store.saveAll() } }.disabled(!store.hasUnsavedChanges) }
                        Divider()
                        Text("Default Terrain").font(.subheadline.weight(.medium))
                        Picker("Terrain", selection: Binding(get: { document.defaultTerrain }, set: { store.setDefaultTerrain($0) })) {
                            Text("None").tag("")
                            ForEach(store.assets.filter { $0.section == .terrains && $0.isModelFile }) { Text($0.name).tag($0.name) }
                            if !document.defaultTerrain.isEmpty, !store.assets.contains(where: { $0.section == .terrains && $0.isModelFile && $0.name == document.defaultTerrain }) { Text(document.defaultTerrain).tag(document.defaultTerrain) }
                        }.labelsHidden()
                    }
            }.formStyle(.grouped)
        }
    }
}

struct PaneHeading<Actions: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder let actions: () -> Actions
    var body: some View {
        HStack {
            Label(LocalizedStringKey(title), systemImage: symbol).font(.callout.weight(.semibold)); Spacer()
            actions().buttonStyle(.borderless).controlSize(.mini)
        }.padding(.horizontal, 10).frame(height: 32).background(.quaternary.opacity(0.25))
    }
}
struct PropertyValue: View {
    let title: String
    let value: String
    init(_ title: String, value: String) { self.title = title; self.value = value }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(LocalizedStringKey(title)).font(.caption).foregroundStyle(.secondary)
            Text(value.isEmpty ? "—" : value).textSelection(.enabled).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct MessagesPane: View {
    @ObservedObject var store: WorkspaceStore
    @State private var showTimestamps = true
    var body: some View {
        VStack(spacing: 0) {
            PaneHeading(title: "Messages", symbol: "text.bubble") {
                Button("Clear", action: store.clearMessages)
                Button { store.showMessages = false } label: { Image(systemName: "xmark") }
            }
            SharedVisualLiveMessageList(messages: store.messages.map(\.sharedVisualLiveMessage), showTimestamps: $showTimestamps,
                copyToClipboard: store.system.copy)
        }
    }
}
struct WorkspaceStatusBar: View {
    @ObservedObject var store: WorkspaceStore
    var body: some View {
        HStack(spacing: 10) {
            Text(store.statusText)
            Spacer()
            if let document = store.document { Text(L10n.text(document.projectionType) + (document.projectionValue.isEmpty ? "" : " · " + document.projectionValue)).lineLimit(1).frame(maxWidth: 260, alignment: .trailing) }
            Text("HEC-RAS 2025")
        }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12).frame(height: 25)
    }
}
