import AppKit
import SwiftUI

@main
struct HECRAS2025App: App {
    @StateObject private var store: WorkspaceStore
    @NSApplicationDelegateAdaptor(WorkspaceApplicationDelegate.self) private var applicationDelegate
    @State private var didHandleLaunchArguments = false
    private let launchConfiguration: WorkspaceLaunchConfiguration

    init() {
        let launchConfiguration = WorkspaceLaunchConfiguration.currentProcess
        self.launchConfiguration = launchConfiguration
        _store = StateObject(wrappedValue: WorkspaceStore(
            modelProvider: BackendModelProvider(),
            toolProvider: BackendToolProvider(),
            projectionProvider: BackendProjectionProvider(),
            reprojectionProvider: BackendReprojectionProvider(),
            wilcockProvider: BackendWilcockProvider(),
            initialConditionsProvider: BackendBoundaryInitialConditionsProvider(),
            attributeTableProvider: BackendAttributeTableProvider(),
            externalRecordProvider: BackendDSSRecordProvider(),
            launchConfiguration: launchConfiguration))
    }
    var body: some Scene {
        Window("HEC-RAS 2025", id: "workspace") {
            AppShellWindowContent(store: store, launchConfiguration: launchConfiguration)
                .background(WindowLifecycleGuard(store: store).frame(width: 0, height: 0))
                .onAppear {
                    applicationDelegate.store = store
                    guard !didHandleLaunchArguments else { return }
                    didHandleLaunchArguments = true
                    try? WorkspaceApplicationLog.append("Application", "HEC-RAS 2025 started.")
                    if let pipe = launchConfiguration.streamPipeName {
                        store.streamMode.start(pipeName: pipe)
                    } else if let projectURL = launchConfiguration.initialProjectURL {
                        store.requestOpen(projectURL)
                    }
                }
                .onChange(of: store.projectSessionID) { old, _ in
                    ClassicCrossSectionWindows.shared.closeProject(old)
                }
                .frame(minWidth: 1024, minHeight: 680)
                .preferredColorScheme(store.theme == "Dark" ? .dark : store.theme == "Light" ? .light : nil)
                .environment(\.locale, store.interfaceLocale)
                .onOpenURL { store.requestOpen($0) }
        }
        .defaultSize(width: 1360, height: 850)
        .commands { WorkspaceCommands(store: store) }
        WindowGroup("HEC-RAS 2025", for: DetachedDocumentRoute.self) { route in
            DetachedDocumentView(store: store, route: route.wrappedValue)
        }.defaultSize(width: 1000, height: 720)
        WindowGroup(L10n.text("Attribute Table"), for: AttributeTableRoute.self) { route in
            AttributeTableWindow(store: store, route: route.wrappedValue)
        }.defaultSize(width: 1100, height: 720)
        WindowGroup(L10n.text("Cross Section"), for: ClassicCrossSectionWindowRoute.self) { route in
            ClassicCrossSectionWindow(store: store, route: route.wrappedValue)
        }
        .defaultSize(width: 800, height: 560)
        .restorationBehavior(.disabled)
        WindowGroup(L10n.text("Layer Reflection"), for: MapSourceReflectionRoute.self) { route in
            MapSourceReflectionWindow(store: store, route: route.wrappedValue)
                .environment(\.locale, store.interfaceLocale)
                .preferredColorScheme(store.theme == "Dark" ? .dark : store.theme == "Light" ? .light : nil)
        }
        .defaultSize(width: 720, height: 620)
        .restorationBehavior(.disabled)
        WindowGroup(L10n.text("Plan Comparison"), for: PlanDiffWindowRoute.self) { route in
            if let client = store.runtimeInfoClient {
                PlanDiffWindow(store: store, client: client, route: route.wrappedValue)
                    .environment(\.locale, store.interfaceLocale)
                    .preferredColorScheme(store.theme == "Dark" ? .dark : store.theme == "Light" ? .light : nil)
            } else {
                ContentUnavailableView(L10n.text("Backend is unavailable"), systemImage: "exclamationmark.triangle")
            }
        }
        .defaultSize(width: 1100, height: 760)
        .restorationBehavior(.disabled)
        WindowGroup(L10n.text("Ready-to-Run Matrix"), for: ReadyToRunMatrixWindowRoute.self) { route in
            if let client = store.runtimeInfoClient {
                ReadyToRunMatrixWindow(store: store, client: client, route: route.wrappedValue)
                    .environment(\.locale, store.interfaceLocale)
                    .preferredColorScheme(store.theme == "Dark" ? .dark : store.theme == "Light" ? .light : nil)
            } else {
                ContentUnavailableView(L10n.text("Backend is unavailable"), systemImage: "exclamationmark.triangle")
            }
        }
        .defaultSize(width: 1100, height: 760)
        .restorationBehavior(.disabled)
        WindowGroup(L10n.text("Boundary Condition Line Chart"), for: BoundaryLineTimeSeriesWindowRoute.self) { route in
            if let route = route.wrappedValue {
                BoundaryLineTimeSeriesWindow(store: store, route: route)
                    .environment(\.locale, store.interfaceLocale)
                    .preferredColorScheme(store.theme == "Dark" ? .dark : store.theme == "Light" ? .light : nil)
            }
        }
        .defaultSize(width: 1000, height: 700)
        .restorationBehavior(.disabled)
        Window(L10n.text("Animation Testing"), id: "animation-testing") {
            WorkspaceAnimationTestingView()
                .environment(\.locale, store.interfaceLocale)
                .preferredColorScheme(store.theme == "Dark" ? .dark : store.theme == "Light" ? .light : nil)
        }
        .defaultSize(width: 720, height: 680)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        Window(L10n.text("Developer Tools"), id: "workspace-debug-tools") {
            WorkspaceDebugToolsView(store: store)
                .environment(\.locale, store.interfaceLocale)
                .preferredColorScheme(store.theme == "Dark" ? .dark : store.theme == "Light" ? .light : nil)
        }
        .defaultSize(width: 920, height: 680)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        Window(L10n.text("Stable Channel"), id: "stable-channel-debug") {
            let capturedProjectSessionID = store.projectSessionID
            let capturedProjectPath = store.document?.url?.path
            let capturedCoreLayerContext = store.captureCoreLayerRequestContext()
            StableChannelDebugWindow(session: store.stableChannelDebug)
                .environment(\.locale, store.interfaceLocale)
                .preferredColorScheme(store.theme == "Dark" ? .dark : store.theme == "Light" ? .light : nil)
                .task(id: capturedProjectSessionID) {
                    guard store.launchDebugEnabled else { return }
                    await store.stableChannelDebug.load(projectPath: capturedProjectPath,
                        projectSessionID: capturedProjectSessionID,
                        coreLayerContext: capturedCoreLayerContext)
                }
        }
        .defaultSize(width: 860, height: 740)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        Settings { WorkspaceSettings(store: store).environment(\.locale, store.interfaceLocale) }
    }
}

struct WorkspaceCommands: Commands {
    @ObservedObject var store: WorkspaceStore
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.workspaceDocumentActions) private var documentActions
    @FocusedValue(\.workspaceGDALInformationAction) private var showGDALInformation
    @FocusedValue(\.workspaceSpreadsheetAction) private var showSpreadsheet
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(L10n.text("New Project…")) { openWindow(id: "workspace"); store.requestNewProject() }.keyboardShortcut("n")
            Button(L10n.text(documentActions?.openDocument == nil ? "Open Project…" : "Open Shapefile…")) {
                if let open = documentActions?.openDocument { open() }
                else { openWindow(id: "workspace"); store.openPanel() }
            }.keyboardShortcut("o")
            Button(L10n.text("Open Attribute Table…")) { openWindow(value: AttributeTableRoute()) }
            Menu(L10n.text("Recent Projects")) {
                ForEach(store.recentProjects, id: \.path) { url in
                    Button(url.deletingPathExtension().lastPathComponent) { openWindow(id: "workspace"); store.requestOpen(url) }
                }
                Divider(); Button(L10n.text("Clear Recent Projects"), action: store.clearRecentProjects)
            }
        }
        CommandGroup(after: .newItem) {
            Divider()
            Button(L10n.text(documentActions?.documentSaveTitle ?? "Save Project")) {
                if let save = documentActions?.saveDocument { save() }
                else { Task { await store.saveAll() } }
            }.keyboardShortcut("s").disabled(documentActions?.saveDocument != nil ? documentActions?.canSaveDocument != true : !store.hasProject)
            if documentActions?.saveDocument == nil {
                // Renamed RasMenuBar.SaveCurrentProjectAsAction has CanExecute=false.
                Button(L10n.text("Save Project As…")) { store.save(asCopy: true) }.keyboardShortcut("s", modifiers: [.command, .shift]).disabled(true)
                Button(L10n.text("Reload Project"), action: store.requestReload).disabled(store.document?.url == nil)
            }
            if documentActions?.canCloseTab == true {
                Divider()
                Button(L10n.text("Close Tab")) { documentActions?.closeTab() }.keyboardShortcut("w").disabled(store.isSavingAll || store.isClosingTab)
                Button(L10n.text("Close Window")) { NSApp.keyWindow?.performClose(nil) }.keyboardShortcut("w", modifiers: [.command, .shift])
            }
        }
        CommandMenu(L10n.text("Project")) {
            Button(L10n.text("Project Properties")) { store.page = .project }.disabled(!store.hasProject)
            Button(L10n.text("Associations")) { store.page = .associations }.disabled(!store.hasProject)
            Button(L10n.text("Manage Connections…")) { store.showConnectionManager = true }.disabled(!store.hasProject)
            Button(L10n.text("Projection…")) { store.showProjection = true }.disabled(!store.hasProject)
            Divider()
            Button(L10n.text("Open Folder"), action: store.revealProject).keyboardShortcut("e").disabled(store.document?.url == nil)
            Button(L10n.text("Refresh Project Files"), action: store.refreshAssets).disabled(!store.hasProject)
            Button(L10n.text("Close Project"), action: store.requestClose).disabled(!store.hasProject)
        }
        CommandMenu(L10n.text("Model Editors")) {
            ForEach(ModelEditorKind.allCases) { kind in
                Button(L10n.text(kind.rawValue)) { store.openEditor(kind) }.disabled(!store.hasProject)
            }
        }
        CommandMenu(L10n.text("Map")) {
            WorkspaceNewMapFlyout(createBlankMap: store.addBlankMapDocument, createProjectMap: store.addProjectMapDocument).disabled(!store.hasProject)
            Button(L10n.text("Add Map Layer…"), action: store.addMapLayer).disabled(!store.hasProject)
            Button(L10n.text("Zoom to Full Extent")) { store.zoomToFullExtent() }.disabled(!store.hasProject)
            Button(L10n.text("Zoom to Location…")) { store.showZoomLocation = true }.disabled(!store.hasProject)
            Button(L10n.text("Vector Render Scaling…")) { WorkspaceRenderScalingPrompt.present() }
            Divider()
            Toggle(L10n.text("Coordinate Grid"), isOn: $store.showGrid)
            Toggle(L10n.text("Map Overview"), isOn: $store.showMinimap)
            Toggle(L10n.text("Map Legend"), isOn: $store.showLegend)
        }
        CommandMenu(L10n.text("Tools")) {
            Button(L10n.text("Chat")) { store.chatIsOpen = true; store.activeTab = .chat }.disabled(!store.hasProject)
            Button(L10n.text("GDAL Information…")) { showGDALInformation?() }.disabled(showGDALInformation == nil)
            Button(L10n.text("Open Spreadsheet")) { showSpreadsheet?() }.disabled(showSpreadsheet == nil)
            Button(L10n.text("Open Command Prompt…")) { WorkspaceCommandPrompt.open(projectURL: store.document?.url) }
            if store.launchDebugEnabled {
                Button(L10n.text("Developer Tools…")) { openWindow(id: "workspace-debug-tools") }
                Button(L10n.text("Stable Channel…")) {
                    let capturedProjectPath = store.document?.url?.path
                    let capturedProjectSessionID = store.projectSessionID
                    let capturedCoreLayerContext = store.captureCoreLayerRequestContext()
                    openWindow(id: "stable-channel-debug")
                    Task { await store.stableChannelDebug.load(projectPath: capturedProjectPath,
                        projectSessionID: capturedProjectSessionID,
                        coreLayerContext: capturedCoreLayerContext) }
                }.disabled(store.isOpeningProject || store.isSavingAll || store.isRunningProjectTool)
            }
            Divider()
            ForEach(["Create", "Import", "Export", "Map Tools", "Analysis", "Tags", "Support"] + (store.launchDebugEnabled ? ["Testing"] : []), id: \.self) { group in
                Menu(L10n.text(group)) {
                    ForEach(ToolKind.generalMenuCases.filter { $0.group == group }) { kind in
                        Button(L10n.text(kind.rawValue)) { openWindow(id: "workspace"); store.activeTool = kind }.disabled(kind.requiresProject && !store.hasProject)
                    }
                }
            }
        }
        CommandMenu(L10n.text("Saved Views")) {
            Button(L10n.text("Save Current View"), action: store.saveCurrentView).keyboardShortcut("v", modifiers: [.command, .shift]).disabled(!store.canEditSavedViews || store.activeMapState.currentExtent == nil)
            Button(L10n.text("Saved Views…")) { store.showSavedViews = true }.disabled(!store.hasProject)
            Divider()
            ForEach(store.savedViews) { view in
                Button(view.name) { store.jumpToView(view) }.keyboardShortcut(ViewShortcut.decode(view.shortcut)?.keyboardShortcut)
            }
        }
        CommandGroup(after: .toolbar) {
            Toggle(L10n.text("Project Tree"), isOn: $store.showProjectTree)
            Toggle(L10n.text("Properties and Components"), isOn: $store.showInspector)
            Toggle(L10n.text("Messages"), isOn: $store.showMessages)
            Toggle(L10n.text("Map Grid"), isOn: $store.showGrid)
            Divider(); Button(L10n.text("Zoom to Full Extent")) { store.zoomToFullExtent() }.keyboardShortcut("0")
        }
        CommandGroup(after: .textEditing) {
            Button(L10n.text("Search Actions…")) { store.showSearch = true }.keyboardShortcut("p", modifiers: [.command, .shift])
        }
        CommandGroup(before: .windowArrangement) {
            Button(L10n.text("Show Workspace")) { openWindow(id: "workspace") }
        }
        CommandGroup(after: .appInfo) {
            Button(L10n.text("Check for Updates…")) { openWindow(id: "workspace"); store.showUpdates = true }
        }
        CommandGroup(replacing: .help) { HelpMenuContents(store: store) }
    }
}
