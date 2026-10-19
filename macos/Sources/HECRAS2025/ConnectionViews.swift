import RASWorkspaceCore
import SwiftUI

struct ExternalConnectionRenameRequest: Identifiable {
    let id = UUID()
    let connection: ProjectConnection
    let projectID: UUID
}

struct ExternalConnectionRemovalRequest: Identifiable {
    let id = UUID()
    let connection: ProjectConnection
    let projectID: UUID
}

struct ConnectionManagerView: View {
    @ObservedObject var store: WorkspaceStore
    @Environment(\.dismiss) private var dismiss
    @State private var selection: String?
    @State private var query = ""
    @State private var adding = false
    private var connections: [ProjectConnection] { store.document?.connections ?? [] }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("External Connections").font(.title2.bold())
                Spacer()
                Button { adding = true } label: { Label("Add Connection…", systemImage: "plus") }
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding()
            Divider()
            HSplitView {
                VStack(spacing: 8) {
                    TextField("Search connections", text: $query).textFieldStyle(.roundedBorder).padding([.horizontal, .top], 10)
                    List(connections.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.description.localizedCaseInsensitiveContains(query) }, selection: $selection) { connection in
                        VStack(alignment: .leading, spacing: 4) {
                            Label(connection.name, systemImage: connection.type == "Directory" ? "folder" : "link")
                            Text(connection.relativePath.isEmpty ? connection.absolutePath : connection.relativePath)
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }.tag(connection.id)
                    }
                    Text("\(connections.count) connections").font(.caption).foregroundStyle(.secondary).padding(.bottom, 10)
                }.frame(minWidth: 230, idealWidth: 270, maxWidth: 340)
                if let connection = connections.first(where: { $0.id == selection }) {
                    ConnectionDetailView(store: store, connection: connection).id(connection.id)
                        .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView("Select a connection", systemImage: "link", description: Text("Inspect connected files and folders without importing them."))
                        .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }.frame(minWidth: 820, idealWidth: 1000, minHeight: 560, idealHeight: 650)
            .onAppear { selection = store.selectedConnection?.id ?? connections.first?.id }
            .onChange(of: connections.map(\.id)) { _, ids in if let selection, !ids.contains(selection) { self.selection = nil } }
            .onChange(of: store.projectSessionID) { _, _ in dismiss() }
            .sheet(isPresented: $adding) { ConnectionEditorSheet(store: store) }
    }
}

struct ConnectionCatalogSummary: View {
    @ObservedObject var store: WorkspaceStore
    let connection: ProjectConnection
    var body: some View {
        Label(connection.name, systemImage: connection.type == "Directory" ? "folder.badge.gearshape" : "link")
            .font(.headline).textSelection(.enabled)
        ConnectionMetadataView(connection: connection)
        Button("Manage Connections…") { store.selectConnection(connection); store.showConnectionManager = true }
        Button("Show in Finder") { store.revealConnection(connection) }
    }
}
private struct ConnectionMetadataView: View {
    let connection: ProjectConnection
    var body: some View {
        LabeledContent("Type", value: L10n.text(connection.type))
        if !connection.relativePath.isEmpty { LabeledContent("Relative Path", value: connection.relativePath).textSelection(.enabled) }
        if !connection.absolutePath.isEmpty { LabeledContent("Absolute Path", value: connection.absolutePath).textSelection(.enabled) }
        if connection.type == "Directory" {
            LabeledContent("Filename Pattern", value: connection.searchPattern.isEmpty ? "*" : connection.searchPattern)
            LabeledContent("Include Subfolders", value: L10n.text(connection.recurse ? "Yes" : "No"))
        }
        if !connection.description.isEmpty { LabeledContent("Description", value: connection.description).textSelection(.enabled) }
    }
}
struct ConnectionDetailView: View {
    @ObservedObject var store: WorkspaceStore
    let connection: ProjectConnection
    @StateObject private var session = ConnectionPreviewSession()
    @State private var refresh = UUID()
    @State private var editing = false
    @State private var query = ""
    @State private var fileSelection: String?
    @State private var renameRequest: ExternalConnectionRenameRequest?
    @State private var removalRequest: ExternalConnectionRemovalRequest?
    @State private var showingRemovalConfirmation = false
    @Environment(\.openWindow) private var openWindow
    @State private var tab = "Summary"
    @State private var recordSelection: String?
    private var request: ConnectionPreviewRequest? {
        guard let directory = store.document?.directory else { return nil }
        return .init(projectID: store.projectSessionID, connection: connection, directory: directory, mappings: store.pathMappings)
    }
    private var preview: ConnectionPreview? { request.flatMap { session.current($0) } }
    private var isDSS: Bool { connection.type != "Directory" && [connection.absolutePath, connection.relativePath].contains { $0.lowercased().hasSuffix(".dss") } }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(connection.name).font(.title2).textSelection(.enabled)
                Spacer()
                if session.busy { ProgressView().controlSize(.small) }
                Button { refresh = UUID() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                Menu {
                    Button("Edit Connection…") { editing = true }.disabled(!["File", "Directory", "FileSystem"].contains(connection.type))
                    Button("Rename…") {
                        renameRequest = ExternalConnectionRenameRequest(connection: connection, projectID: store.projectSessionID)
                    }
                    Button("Show in Finder") { store.revealConnection(connection) }
                    Button("Copy File Path") { store.system.copy(preview?.location.path ?? connection.absolutePath) }
                    Button("Remove Connection", role: .destructive) {
                        removalRequest = ExternalConnectionRemovalRequest(connection: connection, projectID: store.projectSessionID)
                        showingRemovalConfirmation = true
                    }.disabled(store.isSavingAll || store.isRunningProjectTool || store.isOpeningProject || store.isClosingTab)
                } label: { Image(systemName: "ellipsis.circle") }.accessibilityLabel("Connection Actions")
            }
            if let error = session.error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).textSelection(.enabled) }
            TabView(selection: $tab) {
                Form {
                    Section("Connection Details") { ConnectionMetadataView(connection: connection) }
                    if let preview {
                        Section("Resolved Location") {
                            Text(preview.location.path).textSelection(.enabled)
                            LabeledContent("Matching Files", value: preview.total.formatted())
                        }
                    }
                }.formStyle(.grouped).tabItem { Label("Summary", systemImage: "info.circle") }.tag("Summary")
                VStack(spacing: 10) {
                    TextField("Search files", text: $query).textFieldStyle(.roundedBorder)
                    Table((preview?.files ?? []).filter { query.isEmpty || $0.url.path.localizedCaseInsensitiveContains(query) }, selection: $fileSelection) {
                        TableColumn(L10n.text("File")) { Text($0.url.lastPathComponent).textSelection(.enabled) }
                        TableColumn(L10n.text("Location")) { Text($0.url.deletingLastPathComponent().path).lineLimit(1).truncationMode(.middle) }
                        TableColumn(L10n.text("Size")) { Text($0.size.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? L10n.text("Unknown")) }
                        TableColumn(L10n.text("Modified")) { Text($0.modified?.formatted() ?? L10n.text("Unknown")) }
                    }.contextMenu(forSelectionType: String.self) { ids in
                        if let id = ids.first, let file = preview?.files.first(where: { $0.id == id }) {
                            if file.url.pathExtension.lowercased() == "shp" {
                                Button("Open Attribute Table…") { openWindow(value: AttributeTableRoute(path: file.url.path)) }
                            }
                            Button("Show in Finder") { store.system.reveal(file.url) }
                            Button("Copy File Path") { store.system.copy(file.url.path) }
                        }
                    }
                    if let preview, preview.files.count < preview.total { Text("Showing the first 2000 matching files.").font(.caption).foregroundStyle(.secondary) }
                    if !session.busy, session.error == nil, preview?.total == 0 { Text("No matching files.").foregroundStyle(.secondary) }
                }.padding(.top, 10).tabItem { Label("Files", systemImage: "doc.on.doc") }.tag("Files")
                if isDSS {
                    ExternalRecordBrowser(store: store, connection: connection, selection: $recordSelection,
                                          showsVisualizationActions: true, refreshToken: refresh)
                        .tabItem { Label("DSS Records", systemImage: "tablecells") }.tag("Records")
                }
            }
        }.padding(16)
            .task(id: ConnectionLoadKey(request: request, refresh: refresh)) {
                if let request {
                    if let location = try? request.connection.resolve(relativeTo: request.directory, mappings: request.mappings) {
                        let folder = connection.type == "Directory" ? location : location.deletingLastPathComponent()
                        guard store.system.authorizeExternalFolders([folder]) else { session.accessCancelled(); return }
                    }
                    guard !Task.isCancelled else { return }
                    await session.load(request)
                } else { session.invalidate() }
            }
            .onDisappear { session.invalidate() }
            .sheet(isPresented: $editing) { ConnectionEditSheet(store: store, connection: connection) }
            .sheet(item: $renameRequest) { request in
                ExternalConnectionRenameSheet(store: store, request: request)
            }
            .confirmationDialog("Remove Connection", isPresented: $showingRemovalConfirmation, titleVisibility: .visible) {
                Button("Remove Connection", role: .destructive) { removeConfirmedConnection() }
                Button("Cancel", role: .cancel) { removalRequest = nil }
            } message: {
                Text(L10n.text("Deleting this external connection will disconnect it from any attached boundary condition lines, etc."))
            }
    }
    private func removeConfirmedConnection() {
        defer { removalRequest = nil }
        guard let removalRequest else { return }
        store.removeExternalConnectionAfterConfirmation(removalRequest.connection, projectID: removalRequest.projectID)
    }
}
private struct ConnectionLoadKey: Hashable { let request: ConnectionPreviewRequest?; let refresh: UUID }

struct ExternalConnectionRenameSheet: View {
    @ObservedObject var store: WorkspaceStore
    let request: ExternalConnectionRenameRequest
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var error: String?
    private var currentConnection: ProjectConnection? {
        guard request.projectID == store.projectSessionID else { return nil }
        return store.document?.connections.first { $0.id == request.connection.id }
    }
    private var isAvailable: Bool {
        guard let currentConnection, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return name == currentConnection.name || store.document?.connections.contains(where: { $0.id != currentConnection.id && $0.name == name }) == false
    }
    private var canRename: Bool {
        isAvailable && !store.isSavingAll && !store.isRunningProjectTool && !store.isOpeningProject && !store.isClosingTab
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename Connection").font(.title2.bold())
            TextField("Rename to:", text: $name).textFieldStyle(.roundedBorder)
                .onChange(of: name) { _, _ in error = nil }
            if !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isAvailable {
                Text(L10n.text("A connection with this name already exists.")).foregroundStyle(.red)
            } else if !name.isEmpty && name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(L10n.text("The connection name cannot be blank.")).foregroundStyle(.red)
            }
            if let error { Text(L10n.text(error)).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Rename", action: rename).keyboardShortcut(.defaultAction).disabled(!canRename)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear { name = request.connection.name }
        .onChange(of: store.projectSessionID) { _, _ in dismiss() }
        .onChange(of: currentConnection) { _, current in if current == nil { dismiss() } }
    }
    private func rename() {
        do {
            try store.renameExternalConnection(request.connection, to: name, projectID: request.projectID)
            dismiss()
        } catch let failure {
            error = failure.localizedDescription
        }
    }
}

struct ConnectionEditorSheet: View {
    @ObservedObject var store: WorkspaceStore
    @Environment(\.dismiss) private var dismiss
    @State private var projectID: UUID?
    @State private var selectedType = "File"
    @State private var step = 0
    @State private var entries: [ConnectionFileDraft] = []
    @State private var name = ""
    @State private var target: URL?
    @State private var pattern = "*"
    @State private var recurse = false
    @State private var resultID: String?
    private var results: [ProjectAsset] { store.assets.filter { $0.section == .results } }
    private var resolvedTarget: URL? { selectedType == "Result" ? results.first { $0.id == resultID }?.url : target }
    private var valid: Bool {
        guard projectID == store.projectSessionID else { return false }
        let names = Set((store.document?.connections ?? []).map(\.name))
        if selectedType == "File" { return ConnectionFileDraft.valid(entries, existingNames: names) }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard resolvedTarget != nil, !trimmedName.isEmpty, !names.contains(trimmedName) else { return false }
        return selectedType != "Directory" || (!pattern.contains("/") && !pattern.contains("\\"))
    }

    private var title: String {
        if step == 0 { return "New Connection" }
        return switch selectedType {
        case "Result": "New Result Connection"
        case "Directory": "Directory Connection"
        default: "New File Connection"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            WorkspaceDialogHeader(
                title: title,
                subtitle: step == 0 ? "Connect a local file, project result, or folder to this project." : "Set the connection name and source details.",
                symbol: step == 0 ? "link.badge.plus" : selectedType == "Result" ? "water.waves" : "doc.badge.plus"
            )
            .padding(20)
            Divider()
            if step == 0 { connectionTypeChooser }
            else { connectionDetails }
            Divider()
            HStack {
                if step > 0 {
                    Button("Back") { step = 0 }.keyboardShortcut(.leftArrow, modifiers: [.command])
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(step == 0 ? "Continue" : "Add Connection") {
                    if step == 0 { step = 1 }
                    else { addConnection() }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(step > 0 && !valid)
            }
            .padding(16)
        }
        .frame(width: 820, height: 570)
            .onAppear { projectID = store.projectSessionID }
            .onChange(of: selectedType) { _, _ in target = nil; resultID = nil; name = "" }
            .onChange(of: resultID) { _, id in name = results.first { $0.id == id }?.name ?? "" }
            .onChange(of: store.projectSessionID) { _, _ in dismiss() }
    }

    private var connectionTypeChooser: some View {
        VStack(alignment: .leading, spacing: 12) {
            WorkspaceDialogChoiceCard(
                title: "File",
                subtitle: "Local files like .dss, .grib, .h5, and other project inputs.",
                symbol: "doc",
                selected: selectedType == "File"
            ) { selectedType = "File" }
            WorkspaceDialogChoiceCard(
                title: "RAS Result",
                subtitle: "Existing results from this project.",
                symbol: "water.waves",
                selected: selectedType == "Result"
            ) { selectedType = "Result" }
            WorkspaceDialogChoiceCard(
                title: "Folder",
                subtitle: "Browse matching files in a folder, including optional subfolders.",
                symbol: "folder",
                selected: selectedType == "Directory"
            ) { selectedType = "Directory" }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder private var connectionDetails: some View {
        if selectedType == "File" {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Button("Choose Files…") { append(store.system.chooseConnectionFiles()) }
                    Spacer()
                    Text("Drop files here to add connections.").font(.caption).foregroundStyle(.secondary)
                }
                if entries.isEmpty {
                    ContentUnavailableView("No Files Selected", systemImage: "doc.badge.plus", description: Text("Choose files or drop them here to connect them to the project."))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Table($entries) {
                        TableColumn(L10n.text("Name")) { $entry in TextField("Connection Name", text: $entry.name).help(entry.effectiveName) }
                        TableColumn(L10n.text("File")) { $entry in Text(entry.url.lastPathComponent).textSelection(.enabled) }
                        TableColumn(L10n.text("Location")) { $entry in Text(entry.url.deletingLastPathComponent().path).lineLimit(1).truncationMode(.middle) }
                        TableColumn("") { $entry in Button { entries.removeAll { $0.id == entry.id } } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless).accessibilityLabel("Remove from selection") }.width(32)
                    }
                }
                if !entries.isEmpty, !valid { WorkspaceDialogNotice(message: "Connection names must be unique.", isError: true) }
                Text("Blank names use the complete filename.").font(.caption).foregroundStyle(.secondary)
            }
            .padding(16)
            .dropDestination(for: URL.self) { urls, _ in append(urls) }
        } else {
            Form {
                if selectedType == "Result" {
                    Picker("Result", selection: $resultID) {
                        Text("None").tag(nil as String?)
                        ForEach(results) { Text($0.name).tag(Optional($0.id)) }
                    }
                    TextField("Connection name", text: $name)
                    if results.isEmpty {
                        WorkspaceDialogNotice(message: "No project results are available to connect.", isError: false)
                    }
                    if let resolvedTarget { LabeledContent("Result File", value: resolvedTarget.path).textSelection(.enabled) }
                } else {
                    TextField("Name", text: $name)
                    LabeledContent("Location") {
                        Text(target?.path ?? L10n.text("None")).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                        Button("Choose…") {
                            if let chosen = store.system.chooseFolder(title: L10n.text("Directory Connection")) {
                                target = chosen
                                if name.isEmpty { name = chosen.lastPathComponent }
                            }
                        }
                    }
                    TextField("Filename Pattern", text: $pattern)
                    Toggle("Include Subfolders", isOn: $recurse)
                }
                if !name.isEmpty, !valid { WorkspaceDialogNotice(message: "Check the connection name, location and filename pattern.", isError: true) }
            }
            .formStyle(.grouped)
            .padding(12)
        }
    }

    private func addConnection() {
        guard let projectID, projectID == store.projectSessionID else { return }
        if selectedType == "File" {
            if store.addExternalFiles(entries, projectID: projectID) { dismiss() }
        } else if let path = resolvedTarget,
                  store.addExternalConnection(type: selectedType, name: name, target: path, searchPattern: pattern, recurse: recurse) {
            dismiss()
        }
    }

    private func append(_ urls: [URL]) {
        for url in urls where url.isFileURL && (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            if !entries.contains(where: { $0.id == url.standardizedFileURL.path }) { entries.append(.init(url: url, name: url.lastPathComponent)) }
        }
    }
}

struct ConnectionEditSheet: View {
    @ObservedObject var store: WorkspaceStore
    let connection: ProjectConnection
    @Environment(\.dismiss) private var dismiss
    @State private var projectID: UUID?
    @State private var target: URL?
    @State private var description = ""
    @State private var pattern = "*"
    @State private var recurse = false
    @State private var error: String?
    var body: some View {
        VStack(spacing: 0) {
            Text("Edit Connection").font(.title2.bold()).padding()
            Form {
                LabeledContent("Name", value: connection.name)
                LabeledContent("Type", value: L10n.text(connection.type))
                LabeledContent("Location") {
                    Text(target?.path ?? connection.absolutePath).lineLimit(3).textSelection(.enabled)
                    Button("Choose…") {
                        let chosen = connection.type == "Directory" ? store.system.chooseFolder(title: L10n.text("Directory Connection")) : store.system.chooseConnectionFile()
                        if let chosen { target = chosen }
                    }
                }
                if connection.type == "Directory" { TextField("Filename Pattern", text: $pattern); Toggle("Include Subfolders", isOn: $recurse) }
                Section("Description") { TextEditor(text: $description).frame(minHeight: 90).accessibilityLabel("Connection description") }
                if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            }.formStyle(.grouped)
            HStack {
                Spacer(); Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Apply") {
                    guard let projectID, let target else { return }
                    do { try store.updateExternalConnection(connection, target: target, description: description, pattern: pattern, recurse: recurse, projectID: projectID); dismiss() }
                    catch { self.error = L10n.text(error.localizedDescription) }
                }.keyboardShortcut(.defaultAction).disabled(target == nil || pattern.contains("/") || pattern.contains("\\"))
            }.padding()
        }.frame(width: 640, height: 500)
            .onAppear {
                projectID = store.projectSessionID; description = connection.description; pattern = connection.searchPattern; recurse = connection.recurse
                if let directory = store.document?.directory { target = try? connection.resolve(relativeTo: directory, mappings: store.pathMappings) }
            }
            .onChange(of: store.projectSessionID) { _, _ in dismiss() }
    }
}
