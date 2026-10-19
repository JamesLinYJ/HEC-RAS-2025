import AppKit
import RASWorkspaceCore
import SwiftUI

struct ProjectExplorerView: View {
    @ObservedObject var store: WorkspaceStore
    @Environment(\.openSettings) private var openSettings
    @State private var showingGISMode = false

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 16) {
                Label("HEC-RAS 2025", systemImage: "water.waves")
                    .font(.title2.weight(.semibold))
                Text("Project Explorer")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if store.projectDirectory.path.localizedCaseInsensitiveContains("OneDrive") {
                    WorkspaceDialogNotice(message: "Project folder is inside OneDrive. Cloud sync can cause issues with projects.")
                }
                WorkspaceEnvironmentNotices()
                Divider()
                GroupBox("Projects") {
                    VStack(alignment: .leading, spacing: 10) {
                        Button(action: store.requestNewProject) {
                            Label("New Project", systemImage: "doc.badge.plus")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.borderedProminent)
                        Button(action: store.openPanel) {
                            Label("Open Project", systemImage: "folder")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.bordered)
                        Button { store.showProjectLibrary = true } label: {
                            Label("Example and Synthetic Projects", systemImage: "books.vertical")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.borderless)
                        Button { showingGISMode = true } label: {
                            Label("GIS Mode…", systemImage: "globe.americas.fill")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding(.vertical, 4)
                }
                Spacer(minLength: 20)
                Divider()
                Button { store.requestReportIssue() } label: {
                    Label("File Bug…", systemImage: "ladybug")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderless)
                Button { openSettings() } label: {
                    Label("Settings…", systemImage: "gearshape")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderless)
            }
            .padding(20)
            .frame(minWidth: 230, idealWidth: 265, maxWidth: 320, maxHeight: .infinity, alignment: .topLeading)
            RecentProjectsView(store: store)
        }
        .sheet(isPresented: $showingGISMode) { WorkspaceGISModeSheet() }
    }
}

struct ProjectPropertiesView: View {
    @ObservedObject var store: WorkspaceStore
    var body: some View {
        if let document = store.document {
            Form {
                Section("Project Properties") {
                    LabeledContent("Name", value: document.name)
                    LabeledContent("Project File") {
                        Text(document.url?.path ?? "").textSelection(.enabled).lineLimit(2).truncationMode(.middle)
                        Button("Show in Finder", action: store.revealProject)
                    }
                    if let file = document.url, let values = try? file.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey]) {
                        if let date = values.creationDate { LabeledContent("Created", value: date.formatted()) }
                        if let date = values.contentModificationDate { LabeledContent("Modified", value: date.formatted()) }
                    }
                }
                Section("Coordinate System") {
                    LabeledContent("Projection") {
                        Text(L10n.text(document.projectionType) + " · " + document.projectionValue).textSelection(.enabled)
                        Button("Change…") { store.showProjection = true }
                    }
                }
                Section("Description") {
                    TextEditor(text: $store.descriptionDraft).font(.body).frame(minHeight: 160).accessibilityLabel("Project description")
                    HStack { Spacer(); Button("Save Project") { Task { await store.saveAll() } }.keyboardShortcut("s").disabled(!store.hasUnsavedChanges) }
                }
                Section("External Connections") {
                    LabeledContent("Connections", value: document.connections.count.formatted())
                    Button("Manage Connections…") { store.showConnectionManager = true }
                    Button { store.showConnectionEditor = true } label: { Label("Add Connection…", systemImage: "plus") }
                }
                if !document.attributes.isEmpty {
                    Section("Metadata") { ForEach(document.attributes.keys.sorted(), id: \.self) { key in LabeledContent(key, value: document.attributes[key] ?? "").textSelection(.enabled) } }
                }
            }.formStyle(.grouped)
        }
    }
}

struct AssociationsView: View {
    @ObservedObject var store: WorkspaceStore
    @StateObject private var surfaces = SurfaceCatalogSession()
    private var catalogIdentity: String {
        store.projectSessionID.uuidString + "|" + String(store.assetsRevision) + "|"
            + store.assets.filter { $0.section == .surfaceLayers && $0.isModelFile }.map(\.id).sorted().joined(separator: "|")
    }
    var body: some View {
        if let document = store.document {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Project Associations").font(.title2.weight(.semibold))
                    if surfaces.busy { ProgressView("Loading N-value layers…").controlSize(.small) }
                    if let error = surfaces.error {
                        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                        Button("Retry") { Task { await surfaces.load(store.assets, provider: store.modelProvider) } }
                    }
                    ForEach(["PlanAssociations", "GeometryAssociations", "ResultAssociations"], id: \.self) { group in
                        GroupBox(L10n.text(group == "PlanAssociations" ? "Plans" : group == "GeometryAssociations" ? "Geometries" : "Results")) {
                            let rows = document.associationRows(group: group)
                            if rows.isEmpty { Text("No explicit associations stored in this project.").foregroundStyle(.secondary).padding(12).frame(maxWidth: .infinity, alignment: .leading) }
                            ForEach(rows) { row in
                                VStack(alignment: .leading, spacing: 10) {
                                    Text(row.name).font(.headline)
                                    ForEach(editableFields(row), id: \.self) { field in
                                        HStack {
                                            Text(L10n.text(field == "N_Values" ? "Manning’s n" : field == "BoundaryCondition" ? "Boundary Condition" : field == "OverrideTerrain" ? "Terrain Override" : field)).frame(width: 130, alignment: .leading)
                                            Picker(field, selection: Binding(get: { row.fields[field] ?? "" }, set: { store.setAssociation(row, field: field, value: $0) })) {
                                                Text("None").tag("")
                                                ForEach(choices(field), id: \.self) { Text($0).tag($0) }
                                                if let existing = row.fields[field], !existing.isEmpty, !choices(field).contains(existing) { Text(existing).tag(existing) }
                                            }.labelsHidden().frame(maxWidth: .infinity)
                                                .disabled(store.isRunningPlanCompute || store.isSavingAll || store.isClosingTab
                                                    || store.isOpeningProject || store.isRunningProjectTool || store.hasBusyModelEditors
                                                    || (field == "N_Values" && (surfaces.busy || surfaces.error != nil)))
                                        }
                                    }
                                }.padding(12)
                            }
                        }
                    }
                    HStack { Spacer(); Button("Save Associations") { Task { await store.saveAll() } }.disabled(!store.hasUnsavedChanges) }
                }.padding(24).frame(maxWidth: 850).frame(maxWidth: .infinity, alignment: .leading)
            }
            .task(id: catalogIdentity) { await surfaces.load(store.assets, provider: store.modelProvider) }
        }
    }
    private func editableFields(_ row: ProjectAssociation) -> [String] {
        switch row.group { case "PlanAssociations": ["Geometry", "BoundaryCondition"]; case "GeometryAssociations": ["Terrain", "N_Values"]; default: ["OverrideTerrain"] }
    }
    private func choices(_ field: String) -> [String] {
        let section: ProjectSection = field == "Geometry" ? .geometries : field == "BoundaryCondition" ? .boundaryConditions : field == "N_Values" ? .surfaceLayers : .terrains
        return store.assets.filter {
            $0.section == section && $0.isModelFile && (field != "N_Values"
                || (surfaces.entries[$0.id]?.category == "NValues" && surfaces.entries[$0.id]?.error == nil))
        }.map(\.name)
    }
}

enum NewProjectDescriptionLimit {
    static let maximumUTF16Length = 32_767

    /// RichDescription's source RichEditBox uses a 32767 UTF-16-unit limit.
    /// Keep whole Unicode scalars so an edit or pasted string cannot leave a
    /// dangling high surrogate at the boundary.
    static func bounded(_ value: String) -> String {
        var scalars = String.UnicodeScalarView()
        var units = 0
        for scalar in value.unicodeScalars {
            let scalarUnits = scalar.value > 0xFFFF ? 2 : 1
            guard units + scalarUnits <= maximumUTF16Length else { break }
            scalars.append(scalar)
            units += scalarUnits
        }
        return String(scalars)
    }
}

struct NewProjectSheet: View {
    @ObservedObject var store: WorkspaceStore
    @StateObject private var projection = ProjectProjectionSession()
    @State private var name = ""
    @State private var description = ""
    @State private var definition = ProjectionDefinitionDraft()
    @State private var localUnits = "USC"
    @State private var directory: URL?
    @State private var parentFolderInspection: WorkspaceDirectoryInspection?
    private var title: String { name }
    private var boundedDescription: Binding<String> {
        Binding(get: { description }, set: { description = NewProjectDescriptionLimit.bounded($0) })
    }
    private var projectFolder: URL { (directory ?? store.projectDirectory).appendingPathComponent(title, isDirectory: true) }
    private var projectFile: URL { projectFolder.appendingPathComponent(title + ".ras") }
    private var destinationIssue: String? {
        guard !title.isEmpty else { return nil }
        do { try ProjectCreationDestination.validate(projectFolder); return nil }
        catch { return error.localizedDescription }
    }
    private var validTitle: Bool {
        title.utf16.count >= 3 && title != "." && title != ".." && !hasInvalidFilenameCharacter
    }
    private var hasInvalidFilenameCharacter: Bool {
        title.unicodeScalars.contains { scalar in
            scalar.value < 32 || "<>:\"/\\|?*".unicodeScalars.contains(scalar)
        }
    }
    private var titleIssue: String? {
        guard !title.isEmpty else { return nil }
        if title.utf16.count < 3 { return "Project Title must have at least 3 characters." }
        if title == "." || title == ".." || hasInvalidFilenameCharacter {
            return "Project Title contains invalid filename characters."
        }
        if let destinationIssue { return destinationIssue }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            WorkspaceDialogHeader(
                title: "New Project",
                subtitle: "Choose a project name, storage folder, coordinate system, and description.",
                symbol: "doc.badge.plus"
            )
            .padding(20)
            Divider()
            Form {
                Section("Project") {
                    TextField("Project Name", text: $name)
                    LabeledContent("Project Folder") {
                        Text((directory ?? store.projectDirectory).path).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                        Button("Choose Folder…") { if let folder = store.system.chooseFolder(title: L10n.text("Project Folder")) { directory = folder } }
                    }
                    WorkspaceDirectoryPreflightView(
                        directory: directory ?? store.projectDirectory,
                        successMessage: "Project parent folder is writable.",
                        inspection: $parentFolderInspection
                    )
                    if (directory ?? store.projectDirectory).path.localizedCaseInsensitiveContains("OneDrive") {
                        WorkspaceDialogNotice(message: "Project folder is inside OneDrive. Cloud sync can cause issues with projects.")
                    }
                    if !title.isEmpty {
                        LabeledContent("Project File", value: projectFile.path)
                            .font(.caption)
                            .textSelection(.enabled)
                    }
                    if let titleIssue { WorkspaceDialogNotice(message: titleIssue, isError: true) }
                }
                Section("Coordinate System") {
                    ProjectProjectionFields(definition: $definition, session: projection, store: store)
                        .onChange(of: definition.type) { _, type in
                            if type == "Local" { definition.value = localUnits }
                        }
                        .onChange(of: definition.value) { _, value in
                            if definition.type == "Local", ["SI", "USC"].contains(value) { localUnits = value }
                        }
                }
                Section("Description") { TextEditor(text: boundedDescription).frame(minHeight: 85).accessibilityLabel("New project description") }
            }.formStyle(.grouped)
            Divider()
            WorkspaceDialogActionBar(
                cancelTitle: "Cancel",
                actionTitle: "Create",
                actionEnabled: validTitle && destinationIssue == nil && projection.accepted(definition) != nil && parentFolderInspection?.isReady == true,
                onCancel: { store.showNewProject = false },
                onAction: create
            )
        }
        .frame(width: 700, height: 730)
    }
    private func create() {
        let parentFolder = directory ?? store.projectDirectory
        let inspection = WorkspaceDirectoryInspection.inspect(parentFolder)
        parentFolderInspection = inspection
        guard inspection.isReady else { return }
        guard validTitle, destinationIssue == nil,
              let result = projection.accepted(definition), let units = result.units else { return }
        let accepted = result.normalizedDefinition
        store.createProject(name: title, units: units, description: NewProjectDescriptionLimit.bounded(description), directory: parentFolder, projectionType: accepted.type, projectionValue: accepted.value)
    }
}

struct ProjectionSheet: View {
    @ObservedObject var store: WorkspaceStore
    @StateObject private var projection = ProjectProjectionSession()
    @State private var definition = ProjectionDefinitionDraft(type: "Local", value: "SI")
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Coordinate System").font(.title2.weight(.semibold))
            Form { Section { ProjectProjectionFields(definition: $definition, session: projection, store: store) } }.formStyle(.grouped)
            Text("Changing a definition updates the project coordinate system. Existing geometry coordinates are preserved.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { store.showProjection = false }.keyboardShortcut(.cancelAction)
                Button("OK") {
                    guard let result = projection.accepted(definition) else { return }
                    let accepted = result.normalizedDefinition
                    _ = store.setProjection(type: accepted.type, value: accepted.value)
                }.keyboardShortcut(.defaultAction).disabled(projection.accepted(definition) == nil)
            }
        }.padding(24).frame(width: 640, height: 600)
        .onAppear {
            if let document = store.document, !document.projectionType.isEmpty {
                let type = ProjectionDefinitionDraft.canonicalType(document.projectionType)
                definition = .init(type: type, value: type == "Local" ? document.projectionValue.uppercased() : document.projectionValue)
            }
        }
    }
}

struct ActionSearchSheet: View {
    @ObservedObject var store: WorkspaceStore
    var body: some View { ActionSearch(store: store) }
}

struct ActionSearch: View {
    @ObservedObject var store: WorkspaceStore
    @State private var query = ""
    private enum Operation { case workspace(String), editor(ModelEditorKind), tool(ToolKind) }
    private struct Item: Identifiable {
        let id: String
        let title: String
        let group: String
        let symbol: String
        let operation: Operation
    }
    private let workspaceActions = ["New Project", "Open Project", "Save All", "Reload Project", "Open Folder", "Project Properties", "Project Associations", "Projection", "Zoom to Full Extent", "Toggle Project Tree", "Toggle Properties", "Toggle Messages", "Refresh Project Files"]
    private var searchRevision: String { "\(store.hasProject)-\(store.isDebugMode)" }
    private var searchEngines: [SharedVisualSearchEngine] {
        [
            SharedVisualSearchEngine(id: "workspace", title: "Actions") { searchQuery in
                searchResults(for: "workspace", query: searchQuery)
            },
            SharedVisualSearchEngine(id: "editor", title: "Model Editors") { searchQuery in
                searchResults(for: "editor", query: searchQuery)
            },
            SharedVisualSearchEngine(id: "tool", title: "Tools") { searchQuery in
                searchResults(for: "tool", query: searchQuery)
            }
        ]
    }
    private func items(matching query: String) -> [Item] {
        let availableWithoutProject = ["New Project", "Open Project", "Toggle Project Tree", "Toggle Properties", "Toggle Messages"]
        var items = workspaceActions.filter { store.hasProject || availableWithoutProject.contains($0) }.map {
            Item(id: "workspace/" + $0, title: $0, group: "Actions", symbol: "command", operation: .workspace($0))
        }
        if store.hasProject {
            items += ModelEditorKind.allCases.map { Item(id: "editor/" + $0.id, title: $0.rawValue, group: "Model Editors", symbol: $0.symbol, operation: .editor($0)) }
        }
        items += ToolKind.generalMenuCases.filter { (!$0.requiresProject || store.hasProject) && ($0.group != "Testing" || store.isDebugMode) }.map {
            Item(id: "tool/" + $0.id, title: $0.rawValue, group: $0.group, symbol: "slider.horizontal.3", operation: .tool($0))
        }
        return items.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || L10n.text($0.title).localizedCaseInsensitiveContains(query) || L10n.text($0.group).localizedCaseInsensitiveContains(query) }
    }
    private func searchResults(for engineID: String, query: String) -> [SharedVisualSearchResult] {
        let matches = items(matching: query).filter { $0.id.hasPrefix(engineID + "/") }
        return matches.enumerated().map { index, item in
            SharedVisualSearchResult(
                id: item.id,
                title: item.title,
                symbol: item.symbol,
                category: item.group,
                score: Double(matches.count - index)
            )
        }
    }
    var body: some View {
        VStack(spacing: 12) {
            SharedVisualSearchBarWithResultsPopup(
                searchText: $query,
                engines: searchEngines,
                placeholder: "Search actions",
                inlineResults: true,
                searchWhenEmpty: true,
                focusOnAppear: true,
                searchRevision: searchRevision,
                onSelect: perform
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            HStack { Spacer(); Button("Close", role: .cancel) { store.showSearch = false }.keyboardShortcut(.cancelAction) }
        }.padding(20).frame(width: 500, height: 480)
    }
    private func perform(_ result: SharedVisualSearchResult) {
        let resultPrefix = result.engineID + "/"
        guard result.id.hasPrefix(resultPrefix) else { return }
        let originalID = String(result.id.dropFirst(resultPrefix.count))
        guard let item = items(matching: query).first(where: { $0.id == originalID }) else { return }
        store.showSearch = false
        switch item.operation {
        case .tool(let kind): store.activeTool = kind
        case .editor(let kind): store.openEditor(kind)
        case .workspace(let action): performWorkspace(action)
        }
    }
    private func performWorkspace(_ action: String) {
        switch action {
        case "New Project": store.requestNewProject()
        case "Open Project": store.openPanel()
        case "Save All": Task { await store.saveAll() }
        case "Reload Project": store.requestReload()
        case "Open Folder": store.revealProject()
        case "Project Properties": store.page = .project
        case "Project Associations": store.page = .associations
        case "Projection": store.showProjection = true
        case "Zoom to Full Extent": store.zoomToFullExtent()
        case "Toggle Project Tree": store.showProjectTree.toggle()
        case "Toggle Properties": store.showInspector.toggle()
        case "Toggle Messages": store.showMessages.toggle()
        case "Refresh Project Files": store.refreshAssets()
        default: break
        }
    }
}

struct WorkspaceSettings: View {
    @ObservedObject var store: WorkspaceStore
    @Environment(\.dismiss) private var dismiss
    @State private var sourceRoot = ""
    @State private var finishing = false
    @State private var selectedPage = "Symbology"
    @State private var showingCredentials = false
    @State private var projectFolderInspection: WorkspaceDirectoryInspection?
    var body: some View {
        TabView(selection: $selectedPage) {
            GlobalSymbologyPage(store: store, session: store.globalSymbologySession)
                .tabItem { Label("Symbology", systemImage: "paintpalette") }.tag("Symbology")
            Form {
                Picker("Language", selection: Binding(get: { store.interfaceLanguage }, set: { store.setLanguage($0) })) {
                    Text("System").tag("System"); Text("简体中文").tag("zh-Hans"); Text("English").tag("en")
                }
                Picker("Theme", selection: Binding(get: { store.theme }, set: { store.setTheme($0) })) { ForEach(["System", "Light", "Dark"], id: \.self) { Text(L10n.text($0)).tag($0) } }
                LabeledContent("Project Folder") {
                    Text(store.projectDirectory.path).textSelection(.enabled)
                    Button("Choose…", action: store.chooseProjectDirectory)
                }
                WorkspaceDirectoryPreflightView(
                    directory: store.projectDirectory,
                    successMessage: "Default project folder is ready.",
                    inspection: $projectFolderInspection
                )
                LabeledContent("Temporary Folder") {
                    Text(store.temporaryDirectory.path).textSelection(.enabled)
                    Button("Choose…", action: store.chooseTemporaryDirectory)
                }
                Button("Restore Default Folders", action: store.resetDirectories)
                Section("Project Explorer") {
                    Button("Clear Recent Projects", action: store.clearRecentProjects)
                    Button("Credentials…", systemImage: "person.crop.circle") { showingCredentials = true }
                }
            }.formStyle(.grouped).tabItem { Label("General", systemImage: "gearshape") }.tag("General")
            VStack(alignment: .leading, spacing: 12) {
                WorkspaceDialogHeader(
                    title: "File Locations",
                    subtitle: "Map a Windows drive or network folder to a local folder on this Mac.",
                    symbol: "folder.badge.gearshape"
                )
                HStack {
                    TextField("Source root, e.g. C:\\RAS Projects", text: $sourceRoot)
                        .textFieldStyle(.roundedBorder)
                    Button("Choose Folder…") {
                        let source = sourceRoot.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !source.isEmpty else { return }
                        store.addMapping(source: source)
                    }
                    .disabled(sourceRoot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                List {
                    ForEach(store.pathMappings, id: \.sourceRoot) { mapping in VStack(alignment: .leading) { Text(mapping.sourceRoot); Text(mapping.destination.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) } }
                        .onDelete(perform: store.removeMappings)
                }
            }.padding(24).tabItem { Label("File Locations", systemImage: "folder") }.tag("File Locations")
        }.frame(minWidth: 660, idealWidth: 980, maxWidth: 1300, minHeight: 440, idealHeight: 680, maxHeight: 1000)
            .safeAreaInset(edge: .bottom) {
                HStack {
                    if finishing { ProgressView().controlSize(.small) }
                    if selectedPage != "Symbology", let error = store.globalSymbologySession.error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                    Spacer()
                    Button("Done") {
                        finishing = true
                        Task { if await store.globalSymbologySession.flushGlobalChanges() { dismiss() }; finishing = false }
                    }.keyboardShortcut(.cancelAction).disabled(finishing)
                }.padding(12)
            }
            .background(WindowLifecycleGuard(store: store, beforeClose: { await store.globalSymbologySession.flushGlobalChanges() }, guardsProjectChanges: false).frame(width: 0, height: 0))
            .sheet(isPresented: $showingCredentials) {
                CredentialsSettingsView(store: store)
                    .environment(\.locale, store.interfaceLocale)
            }
    }
}
