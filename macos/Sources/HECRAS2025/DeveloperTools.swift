import SwiftUI

struct DeveloperModel: Identifiable, Sendable {
    let key: String
    let name: String
    let isFolder: Bool
    let size: Int64?
    let uploader: String
    let fileCount: Int
    var children: [DeveloperModel]? = nil
    var id: String { key }
    func find(_ key: String) -> Self? {
        if self.key == key { return self }
        return children?.lazy.compactMap { $0.find(key) }.first
    }
    func filtered(_ query: String) -> Self? {
        if query.isEmpty || key.localizedCaseInsensitiveContains(query) { return self }
        let matches = children?.compactMap { $0.filtered(query) } ?? []
        guard !matches.isEmpty else { return nil }
        var copy = self; copy.children = matches; return copy
    }
}
struct DeveloperSnapshot: Sendable {
    let authenticated: Bool
    let models: [DeveloperModel]
}
enum DeveloperOperation: Sendable {
    case generateUploadURL(key: String)
    case uploadProject(key: String, projectURL: URL, includeResults: Bool)
    case openModel(key: String)
    case rename(key: String, newKey: String)
    case delete(key: String, isFolder: Bool, expectedCount: Int)
    case copyPrefix(oldPrefix: String, newPrefix: String)
}
struct DeveloperResult: Sendable {
    let snapshot: DeveloperSnapshot?
    let projectURL: URL?
    let clipboardText: String?
    let message: String?
}
@MainActor
protocol DeveloperProvider {
    func load() async throws -> DeveloperSnapshot
    func authenticate(key: String, secret: String) async throws -> DeveloperSnapshot
    func perform(_ operation: DeveloperOperation,
                 progress: @escaping @MainActor @Sendable (Double?, String) -> Void) async throws -> DeveloperResult
}

@MainActor
final class DeveloperSession: ObservableObject {
    @Published private(set) var snapshot: DeveloperSnapshot?
    @Published private(set) var busy = false
    @Published private(set) var isCheckingAuthentication = false
    @Published private(set) var progress: Double?
    @Published private(set) var message = ""
    @Published var error: String?
    private let provider: (any DeveloperProvider)?
    private var revision = 0
    init(provider: (any DeveloperProvider)?) { self.provider = provider }
    var available: Bool { provider != nil }
    func load() async {
        guard let provider, !busy else { return }
        revision += 1; let captured = revision
        busy = true; isCheckingAuthentication = true; error = nil
        defer { if captured == revision { busy = false; isCheckingAuthentication = false } }
        do {
            let snapshot = try await provider.load()
            guard captured == revision, !Task.isCancelled else { return }
            self.snapshot = snapshot
        } catch { if captured == revision, !Task.isCancelled { self.error = L10n.text(error.localizedDescription) } }
    }
    func authenticate(key: String, secret: String) async {
        guard let provider, !busy else { return }
        revision += 1; let captured = revision
        busy = true; isCheckingAuthentication = true; error = nil
        defer { if captured == revision { busy = false; isCheckingAuthentication = false } }
        do {
            let snapshot = try await provider.authenticate(key: key, secret: secret)
            guard captured == revision, !Task.isCancelled else { return }
            self.snapshot = snapshot
        } catch { if captured == revision, !Task.isCancelled { self.error = L10n.text(error.localizedDescription) } }
    }
    func perform(_ operation: DeveloperOperation) async -> DeveloperResult? {
        guard let provider, !busy, snapshot?.authenticated == true else { return nil }
        revision += 1; let captured = revision
        busy = true; error = nil; progress = nil; message = ""
        defer { if captured == revision { busy = false; progress = nil } }
        do {
            let result = try await provider.perform(operation) { [weak self = self] value, message in
                guard let self, captured == self.revision else { return }
                self.progress = value.flatMap { $0.isFinite ? min(max($0, 0), 100) : nil }
                self.message = L10n.text(message)
            }
            guard captured == revision, !Task.isCancelled else { return nil }
            if let snapshot = result.snapshot { self.snapshot = snapshot }
            if let message = result.message { self.message = L10n.text(message) }
            return result
        } catch { if captured == revision, !Task.isCancelled { self.error = L10n.text(error.localizedDescription) }; return nil }
    }
    func invalidate() { revision += 1; busy = false; isCheckingAuthentication = false; progress = nil }
}

// DevButtonWithRequiredID's Default -> IdEntry -> Execute/Back flow.
struct RequiredIDAction: View {
    let title: String
    let description: String
    let mainIcon: String
    let generateIcon: String
    var generateButtonText = "Generate"
    var placeholderText = "unique-memorable-id"
    let enabled: Bool
    let action: (String) -> Void
    @State private var enteringID = false
    @State private var key = ""
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if enteringID {
                HStack {
                    Button { enteringID = false } label: { Label("Back", systemImage: "chevron.left") }
            TextField(LocalizedStringKey(placeholderText), text: $key).focused($focused).onAppear { focused = true }.onSubmit(execute)
                    Button(action: execute) { Label(LocalizedStringKey(generateButtonText), systemImage: generateIcon) }
                        .disabled(!enabled || key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } else {
                Button { enteringID = true; focused = true } label: {
                    Label(LocalizedStringKey(title), systemImage: mainIcon)
                }.disabled(!enabled)
            }
            Text(LocalizedStringKey(description)).font(.caption).foregroundStyle(.secondary)
        }
    }
    private func execute() {
        let value = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard enabled, !value.isEmpty else { return }
        enteringID = false; action(value)
    }
}

struct DeveloperToolsView: View {
    @ObservedObject var store: WorkspaceStore
    @Environment(\.openWindow) private var openWindow
    @StateObject private var session: DeveloperSession
    @State private var page = "Credentials"
    @State private var key = ""
    @State private var secret = ""
    @State private var query = ""
    @State private var selectedID: String?
    @State private var includeResults = true
    @State private var editedKey = ""
    @State private var editMode = "Rename"
    @State private var showEditKey = false
    @State private var pendingNode: DeveloperModel?
    @State private var showDelete = false
    init(store: WorkspaceStore) {
        self.store = store; _session = StateObject(wrappedValue: DeveloperSession(provider: store.developerProvider))
    }
    private var enabled: Bool { session.available && session.snapshot?.authenticated == true && !session.busy }
    private var projectURL: URL? { store.document?.url ?? store.recentProjects.first }
    private var selected: DeveloperModel? { selectedID.flatMap { id in session.snapshot?.models.lazy.compactMap { $0.find(id) }.first } }
    var body: some View {
        VStack(spacing: 0) {
            DeveloperToolsStatusHeader(
                store: store,
                providerAvailable: session.available,
                isCheckingAuthentication: session.isCheckingAuthentication,
                authenticated: session.snapshot?.authenticated
            )
            Divider()
            NavigationSplitView {
                List(selection: $page) {
                    Label("Home", systemImage: "house").tag("Home")
                    Label("Model Library", systemImage: "books.vertical").tag("Model Library")
                    Label("Staging Updates", systemImage: "arrow.down.circle").tag("Staging Updates")
                    Label("Testing Utility", systemImage: "checkmark.seal").tag("Testing Utility")
                    Label("Folder Explorer", systemImage: "folder").tag("Folder Explorer")
                    Label("Credentials", systemImage: "key").tag("Credentials")
                }.listStyle(.sidebar).navigationSplitViewColumnWidth(min: 180, ideal: 210)
            } detail: {
                switch page {
                case "Home": home
                case "Model Library": library
                case "Staging Updates":
                    VStack(spacing: 16) {
                        Text("Staging Updates").font(.title2)
                        Button("Check for Updates…") { store.updateInitialChannel = "Staging"; store.showDeveloperTools = false; store.showUpdates = true }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                case "Testing Utility": testingTools
                case "Folder Explorer": FolderExplorer(store: store, startingPath: store.projectDirectory)
                default: credentials
                }
            }
            Divider()
            HStack {
                if session.busy { ProgressView(value: session.progress, total: 100).frame(width: 140) }
                Text(session.message).font(.caption).lineLimit(2)
                Spacer()
                Button("Done") { store.showDeveloperTools = false }.keyboardShortcut(.cancelAction).disabled(session.busy)
            }.padding(12)
        }.frame(width: 940, height: 680)
            .task { await session.load(); if session.snapshot?.authenticated == true { page = "Home" } }
            .onDisappear { session.invalidate() }
            .alert("HEC-RAS 2025", isPresented: Binding(get: { session.error != nil }, set: { if !$0 { session.error = nil } })) {
                Button("OK") { session.error = nil }
            } message: { Text(session.error ?? "") }
            .alert(LocalizedStringKey(editMode), isPresented: $showEditKey) {
                TextField("Key / Prefix", text: $editedKey)
                Button(LocalizedStringKey(editMode)) {
                    guard let node = pendingNode else { return }
                    Task { await perform(editMode == "Rename" ? .rename(key: node.key, newKey: editedKey) : .copyPrefix(oldPrefix: node.key, newPrefix: editedKey)) }
                }.disabled(editedKey.isEmpty)
                Button("Cancel", role: .cancel) {}
            }
            .alert("Delete Model Objects?", isPresented: $showDelete) {
                Button("Delete", role: .destructive) {
                    if let node = pendingNode { Task { await perform(.delete(key: node.key, isFolder: node.isFolder, expectedCount: node.fileCount)) } }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                if let node = pendingNode { Text(L10n.format("Delete %d file(s) under %@? This action cannot be undone.", node.fileCount, node.key)) }
            }
    }
    private var credentials: some View {
        Form {
            Section("Credentials") {
                TextField("Key", text: $key)
                SecureField("Secret", text: $secret)
                Button("Authenticate") { Task { await session.authenticate(key: key, secret: secret); secret = ""; if session.snapshot?.authenticated == true { page = "Home" } } }.disabled(!session.available || session.busy)
            }
            Section {
                Button("Other Developer Credentials…") { store.showDeveloperTools = false; store.activeTool = .credentials }
            }
        }.formStyle(.grouped)
    }
    private var home: some View {
        Form {
            Section("Model Sharing") {
                RequiredIDAction(title: "Generate Model Upload URL", description: "Generate an upload URL for a model ID and copy it to the clipboard.", mainIcon: "link", generateIcon: "doc.on.doc", enabled: enabled) { id in Task { await perform(.generateUploadURL(key: id)) } }
                RequiredIDAction(title: "Upload Current Project", description: "Upload the currently or recently opened project with the specified model ID.", mainIcon: "square.and.arrow.up", generateIcon: "arrow.up.doc", enabled: enabled && projectURL != nil) { id in
                    if let projectURL { Task { if await store.saveAll() { await perform(.uploadProject(key: id, projectURL: projectURL, includeResults: includeResults)) } } }
                }
                Toggle("Upload Results", isOn: $includeResults)
                RequiredIDAction(title: "Download Model", description: "Download and open a project by its original model ID.", mainIcon: "square.and.arrow.down", generateIcon: "arrow.down.doc", enabled: enabled) { id in Task { await perform(.openModel(key: id)) } }
            }
        }.formStyle(.grouped)
    }
    private var library: some View {
        HSplitView {
            VStack {
                HStack {
                    TextField("Search models", text: $query).textFieldStyle(.roundedBorder)
                    Button { Task { await session.load() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }.disabled(!session.available || session.busy)
                }.padding(12)
                List(selection: $selectedID) {
                    OutlineGroup((session.snapshot?.models ?? []).compactMap { $0.filtered(query) }, children: \.children) { node in
                        Label(node.name, systemImage: node.isFolder ? "folder" : "doc.zipper").tag(node.id)
                            .onTapGesture(count: 2) { if !node.isFolder { Task { await perform(.openModel(key: node.key)) } } }
                            .contextMenu {
                                Button("Copy Key") { store.system.copy(node.key) }
                                if node.isFolder { Button("Copy with New Prefix…") { beginEdit(node, mode: "Copy Prefix") }.disabled(!enabled) }
                                else {
                                    Button("Open Project") { Task { await perform(.openModel(key: node.key)) } }.disabled(!enabled)
                                    Button("Rename…") { beginEdit(node, mode: "Rename") }.disabled(!enabled)
                                }
                                Button("Delete…", role: .destructive) { pendingNode = node; showDelete = true }.disabled(!enabled)
                            }
                    }
                }.disabled(session.busy)
            }.frame(minWidth: 280, idealWidth: 350)
            if let selected {
                Form {
                    Section {
                        Text(selected.name).font(.title2)
                        LabeledContent("Key", value: selected.key).textSelection(.enabled)
                        LabeledContent("Uploader", value: selected.uploader)
                        if let size = selected.size { LabeledContent("Size", value: ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) }
                        if selected.isFolder { LabeledContent("Files", value: selected.fileCount.formatted()) }
                    }
                }.formStyle(.grouped)
            } else { ContentUnavailableView("Select a Model", systemImage: "doc.zipper") }
        }
    }
    private var testingTools: some View {
        Form {
            Section("Testing Utility") {
                Button("Animation Testing…") { openWindow(id: "animation-testing") }
                ForEach([ToolKind.testingViewer, .testingProjectUpload, .testingGeometryUpload, .testingPOI, .testingRunner]) { kind in
                    Button { store.showDeveloperTools = false; store.activeTool = kind } label: { Text(verbatim: kind.localizedTitle) }
                }
            }
            WorkspaceDeveloperLogTestActions()
        }.formStyle(.grouped)
    }
    private func beginEdit(_ node: DeveloperModel, mode: String) { pendingNode = node; editedKey = node.key; editMode = mode; showEditKey = true }
    private func perform(_ operation: DeveloperOperation) async {
        guard let result = await session.perform(operation) else { return }
        if let text = result.clipboardText { store.system.copy(text) }
        if let url = result.projectURL { store.showDeveloperTools = false; store.requestOpen(url) }
    }
}

/// Shows authentication and operational previews from the current providers
/// and workspace state. No sample jobs or messages are created here.
private struct DeveloperToolsStatusHeader: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var logCenter: WorkspaceDeveloperLogCenter = .shared
    let providerAvailable: Bool
    let isCheckingAuthentication: Bool
    let authenticated: Bool?

    @State private var showJobs = false
    @State private var showMessages = false

    private var statusTitle: String {
        guard providerAvailable else { return "Authentication unavailable" }
        if isCheckingAuthentication { return "Checking authentication" }
        guard let authenticated else { return "Authentication status unknown" }
        return authenticated ? "Authenticated" : "Not authenticated"
    }

    private var statusSymbol: String {
        guard providerAvailable else { return "exclamationmark.circle" }
        if isCheckingAuthentication { return "hourglass" }
        guard let authenticated else { return "questionmark.circle" }
        return authenticated ? "checkmark.seal.fill" : "xmark.seal"
    }

    private var statusColor: Color {
        guard providerAvailable else { return .secondary }
        if isCheckingAuthentication || authenticated == nil { return .secondary }
        return authenticated == true ? .green : .orange
    }

    var body: some View {
        HStack(spacing: 14) {
            Label("Developer Tools", systemImage: "wrench.and.screwdriver")
                .font(.headline)

            Spacer(minLength: 12)

            Label(statusTitle, systemImage: statusSymbol)
                .font(.caption)
                .foregroundStyle(statusColor)
                .accessibilityElement(children: .combine)

            Button { showJobs = true } label: {
                Label(L10n.format("%d jobs", store.jobs.count), systemImage: "arrow.trianglehead.2.clockwise")
            }
            .popover(isPresented: $showJobs) { JobsPopover(store: store) }

            Button { showMessages = true } label: {
                Label(L10n.format("%d messages", logCenter.entries.count), systemImage: "text.alignleft")
            }
            .popover(isPresented: $showMessages) {
                WorkspaceDeveloperLogPreviewList(entries: logCenter.entries)
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

