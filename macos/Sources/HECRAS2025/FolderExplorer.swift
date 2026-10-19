import Foundation
import SwiftUI

// FolderExplorer.cs: path history, breadcrumbs, folder/file descriptions,
// modification dates and opening an item. Enumeration stays off the UI thread.
struct FolderExplorer: View {
    @ObservedObject var store: WorkspaceStore
    @State private var current: URL
    @State private var pathDraft: String
    @State private var back: [URL] = []
    @State private var forward: [URL] = []
    @State private var entries: [Entry] = []
    @State private var selectedID: String?
    @State private var selectedPresentation: SharedVisualTablePresentation = .table
    @State private var editingPath = false
    @State private var loading = false
    @State private var error: String?
    @State private var reloadID = UUID()
    private struct Entry: Identifiable, Sendable {
        let url: URL
        let isFolder: Bool
        let size: Int64?
        let modified: Date?
        let counts: (folders: Int, files: Int)?
        var id: String { url.path }
        var name: String { url.lastPathComponent }
        @MainActor var description: String {
            if !isFolder { return size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "—" }
            guard let counts else { return L10n.text("Unknown contents") }
            return counts.folders + counts.files == 0 ? L10n.text("Empty") : L10n.format("%d folders, %d files", counts.folders, counts.files)
        }
    }
    init(store: WorkspaceStore, startingPath: URL) {
        self.store = store
        _current = State(initialValue: startingPath.standardizedFileURL)
        _pathDraft = State(initialValue: startingPath.standardizedFileURL.path)
    }
    private var ancestors: [URL] {
        var path = current, urls = [path]
        while path.path != "/" { path.deleteLastPathComponent(); urls.insert(path, at: 0) }
        return urls
    }
    private var selectedEntry: Entry? { entries.first { $0.id == selectedID } }
    private var selectionActions: [SharedVisualContextAction] {
        [
            SharedVisualContextAction(id: "open", title: "Open", systemImage: "arrow.up.right.square", isEnabled: selectedEntry != nil) { value in
                guard let url = value as? URL, let entry = entries.first(where: { $0.url == url }) else { return }
                open(entry)
            },
            SharedVisualContextAction(id: "reveal", title: "Show in Finder", systemImage: "folder", isEnabled: selectedEntry != nil) { value in
                guard let url = value as? URL else { return }
                store.system.reveal(url)
            },
            SharedVisualContextAction(id: "copy", title: "Copy File Path", systemImage: "doc.on.doc", isEnabled: selectedEntry != nil) { value in
                guard let url = value as? URL else { return }
                store.system.copy(url.path)
            }
        ]
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                ControlGroup {
                    SharedVisualFrameBackButton(isEnabled: !back.isEmpty, onBack: goBack)
                    Button { goForward() } label: { Label("Forward", systemImage: "chevron.right") }.disabled(forward.isEmpty)
                    Button { navigate(current.deletingLastPathComponent()) } label: { Label("Up", systemImage: "arrow.up") }.disabled(current.path == "/")
                    Button { reloadID = UUID() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                }.labelStyle(.iconOnly)
                SharedVisualContextActionGrid(actions: selectionActions, context: selectedEntry?.url)
                if editingPath {
                    TextField("Folder Path", text: $pathDraft)
                        .textFieldStyle(.roundedBorder).onSubmit { enterPath() }
                        .onExitCommand { pathDraft = current.path; editingPath = false }
                } else {
                    ScrollView(.horizontal) {
                        HStack(spacing: 6) {
                            ForEach(ancestors, id: \.path) { url in
                                Button(url.path == "/" ? "/" : url.lastPathComponent) { navigate(url) }.buttonStyle(.borderless)
                                if url != current { Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary) }
                            }
                        }
                    }.scrollIndicators(.hidden)
                    Button { pathDraft = current.path; editingPath = true } label: { Label("Edit Path", systemImage: "pencil") }.labelStyle(.iconOnly)
                }
                Button { if let url = store.system.chooseFolder(title: L10n.text("Folder Explorer")) { navigate(url) } } label: { Label("Choose Folder…", systemImage: "folder") }.labelStyle(.iconOnly)
                if loading { ProgressView().controlSize(.small) }
            }.padding(12)
            Divider()
            if let error {
                ContentUnavailableView("Error accessing folder", systemImage: "folder.badge.questionmark", description: Text(error))
            } else {
                SharedVisualListDetailTableControl(
                    selectedPresentation: $selectedPresentation,
                    hasDetail: selectedEntry != nil,
                    onBack: { selectedID = nil },
                    listContent: { folderList },
                    detailContent: { selectedDetail },
                    tableContent: { folderTable }
                )
                .overlay {
                    if entries.isEmpty && !loading {
                        ContentUnavailableView("Empty folder", systemImage: "folder")
                    }
                }
            }
            Divider()
            HStack {
                SharedVisualOpenFolderButton(
                    path: current.path,
                    description: L10n.format("%d items", entries.count),
                    iconSize: 14,
                    title: "Open Folder"
                ) { store.system.reveal(current) }
                Spacer()
                Text(L10n.format("%d items", entries.count))
            }.font(.caption).foregroundStyle(.secondary).padding(10)
        }
        .task(id: current.path + reloadID.uuidString) { await load() }
    }
    private func navigate(_ url: URL) {
        let url = url.standardizedFileURL
        guard url != current else { return }
        back.append(current); forward.removeAll(); setPath(url)
    }
    private func setPath(_ url: URL) { current = url; pathDraft = url.path; editingPath = false; selectedID = nil }
    private func goBack() { guard let url = back.popLast() else { return }; forward.append(current); setPath(url) }
    private func goForward() { guard let url = forward.popLast() else { return }; back.append(current); setPath(url) }
    private func enterPath() {
        let path = (pathDraft.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
        guard path.hasPrefix("/") else { return }
        navigate(URL(fileURLWithPath: path, isDirectory: true))
    }
    private func open(_ entry: Entry) {
        if entry.isFolder { navigate(entry.url) }
        else if entry.url.pathExtension.lowercased() == "ras" { store.requestOpen(entry.url); store.showDeveloperTools = false }
        else { store.system.openFile(entry.url) }
    }

    private var folderTable: some View {
        Table(entries, selection: $selectedID) {
            TableColumn(L10n.text("Name")) { entry in
                Button { open(entry) } label: { Label(entry.name, systemImage: entry.isFolder ? "folder" : "doc") }.buttonStyle(.plain)
            }.width(min: 160, ideal: 250)
            TableColumn(L10n.text("Description")) { entry in Text(entry.description).foregroundStyle(.secondary) }
            TableColumn(L10n.text("Modified")) { entry in Text(entry.modified?.formatted(date: .abbreviated, time: .shortened) ?? "—").foregroundStyle(.secondary) }
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if let entry = entries.first(where: { ids.contains($0.id) }) {
                Button("Open") { open(entry) }
                Button("Show in Finder") { store.system.reveal(entry.url) }
                Button("Copy File Path") { store.system.copy(entry.url.path) }
            }
        } primaryAction: { ids in
            if let entry = entries.first(where: { ids.contains($0.id) }) { open(entry) }
        }
        .frame(minHeight: 120)
    }

    private var folderList: some View {
        List(entries, selection: $selectedID) { entry in
            Button { open(entry) } label: {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: entry.isFolder ? "folder" : "doc")
                        .foregroundStyle(entry.isFolder ? Color.accentColor : Color.secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(entry.name).lineLimit(1)
                        Text(entry.description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .tag(entry.id)
        }
        .frame(minHeight: 120)
    }

    @ViewBuilder private var selectedDetail: some View {
        if let entry = selectedEntry {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Label(entry.name, systemImage: entry.isFolder ? "folder" : "doc")
                        .font(.title3.weight(.semibold))
                    Text(verbatim: entry.url.path)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    SharedVisualMetadataGroup(sections: [
                        SharedVisualMetadataSection(id: "file", title: "Details", properties: [
                            SharedVisualMetadataProperty(key: "Kind", value: entry.isFolder ? L10n.text("Folder") : L10n.text("File")),
                            SharedVisualMetadataProperty(key: "Size", value: entry.isFolder ? entry.description : (entry.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "—")),
                            SharedVisualMetadataProperty(key: "Modified", value: entry.modified?.formatted(date: .long, time: .shortened) ?? "—")
                        ])
                    ])
                    HStack {
                        Button("Open") { open(entry) }.buttonStyle(.borderedProminent)
                        Button("Show in Finder") { store.system.reveal(entry.url) }
                        Button("Copy File Path") { store.system.copy(entry.url.path) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
            }
        } else {
            SharedVisualEmptySelectionOverlay(isEmpty: true, text: "Select a file or folder to view its details", symbol: "doc.text.magnifyingglass") {
                Color.clear.frame(minHeight: 260, maxHeight: .infinity)
            }
        }
    }
    private func load() async {
        let url = current, revision = reloadID
        loading = true; error = nil; entries = []
        let worker = Task.detached(priority: .userInitiated) { () throws -> [Entry] in
            let manager = FileManager.default
            let urls = try manager.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
            return try urls.map { child in
                try Task.checkCancellation()
                let metadata = try child.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
                let isFolder = metadata.isDirectory == true
                var counts: (folders: Int, files: Int)?
                if isFolder, let children = try? manager.contentsOfDirectory(at: child, includingPropertiesForKeys: [.isDirectoryKey]) {
                    let folders = children.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }.count
                    counts = (folders, children.count - folders)
                }
                return Entry(url: child, isFolder: isFolder, size: metadata.fileSize.map(Int64.init), modified: metadata.contentModificationDate, counts: counts)
            }.sorted { $0.isFolder != $1.isFolder ? $0.isFolder : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        defer { worker.cancel(); if url == current && revision == reloadID { loading = false } }
        do {
            let loaded = try await worker.value
            guard !Task.isCancelled, url == current, revision == reloadID else { return }
            entries = loaded
        } catch {
            guard !Task.isCancelled, url == current, revision == reloadID else { return }
            self.error = error.localizedDescription
        }
    }
}
