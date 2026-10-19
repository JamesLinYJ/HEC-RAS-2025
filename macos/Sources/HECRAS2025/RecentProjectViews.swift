import AppKit
import RASWorkspaceCore
import SwiftUI

struct RecentProjectsView: View {
    @ObservedObject var store: WorkspaceStore
    @StateObject private var session = RecentProjectsSession()
    @State private var search = ""
    @State private var refresh = UUID()
    private struct Request: Hashable { let records: [RecentProjectRecord]; let refresh: UUID }
    private var visible: [RecentProjectRecord] {
        store.recentProjectHistory.filter { record in
            search.isEmpty || record.name.localizedCaseInsensitiveContains(search) || record.url.path.localizedCaseInsensitiveContains(search)
                || session.previews[record.id]?.description.localizedCaseInsensitiveContains(search) == true
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Recent Projects").font(.title2.weight(.semibold))
                Spacer()
                TextField("Search recent projects", text: $search).textFieldStyle(.roundedBorder).frame(maxWidth: 280)
                Button { refresh = UUID() } label: { Label("Refresh", systemImage: "arrow.clockwise") }.labelStyle(.iconOnly)
            }.padding(24)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    if let first = visible.first {
                        RecentProjectCard(record: first, preview: session.previews[first.id], error: session.errors[first.id], loading: session.loading.contains(first.id), featured: true, store: store)
                        ForEach(RecentProjectGroup.allCases) { group in
                            let records = visible.dropFirst().filter { RecentProjectGroup.group($0, now: .now, calendar: .current) == group }
                            if !records.isEmpty {
                                Text(LocalizedStringKey(group.rawValue)).font(.headline)
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), alignment: .topLeading)], alignment: .leading, spacing: 16) {
                                    ForEach(records) { record in
                                        RecentProjectCard(record: record, preview: session.previews[record.id], error: session.errors[record.id], loading: session.loading.contains(record.id), featured: false, store: store)
                                    }
                                }
                            }
                        }
                    } else {
                        ContentUnavailableView(store.recentProjectHistory.isEmpty ? "No Recent Projects" : "No matching projects", systemImage: "folder",
                            description: Text("Create a project or open an existing .ras project.")).frame(maxWidth: .infinity, minHeight: 300)
                    }
                }.padding(24)
            }
        }
        .task(id: Request(records: store.recentProjectHistory, refresh: refresh)) { await session.load(store.recentProjectHistory) }
        .onDisappear { session.invalidate() }
    }
}

private struct RecentProjectCard: View {
    let record: RecentProjectRecord
    let preview: RecentProjectPreview?
    let error: String?
    let loading: Bool
    let featured: Bool
    @ObservedObject var store: WorkspaceStore
    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                Button { store.requestOpen(record.url) } label: {
                    VStack(alignment: .leading, spacing: 12) {
                        if let image = preview?.thumbnail.flatMap(NSImage.init(data:)) {
                            Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: featured ? 240 : 150).accessibilityLabel(record.name)
                        }
                        Label(record.name, systemImage: "folder").font(featured ? .title2.weight(.semibold) : .headline)
                        Text(record.url.path).font(.caption).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
                    }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel(L10n.format("Open %@", record.name))
                if let date = record.lastOpened {
                    LabeledContent("Last Opened") { Text(date, format: .dateTime.year().month().day().hour().minute()).monospacedDigit() }.font(.caption)
                } else { Text("Open time unavailable").font(.caption).foregroundStyle(.secondary) }
                if let preview {
                    if !preview.description.isEmpty { Text(preview.description).lineLimit(featured ? 4 : 2).textSelection(.enabled) }
                    if featured, let definition = preview.projection {
                        LabeledContent("Coordinate System", value: L10n.text(ProjectionDefinitionDraft.canonicalType(definition.type)) + " · " + definition.value).font(.caption).lineLimit(3).textSelection(.enabled)
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), alignment: .leading)], alignment: .leading) {
                        ForEach(preview.counts) { statistic in
                            Label { Text(L10n.text(statistic.section.rawValue) + ": " + (statistic.count?.formatted() ?? "—")) } icon: { Image(systemName: statistic.section.symbol) }
                                .font(.caption).help(statistic.error ?? L10n.text(statistic.section.rawValue))
                        }
                    }
                    if let warning = preview.warning { Label(L10n.text(warning), systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.secondary) }
                }
                if loading { ProgressView("Loading project preview…").controlSize(.small) }
                if let error { Label(L10n.text(error), systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                HStack {
                    Button("Open Project") { store.requestOpen(record.url) }.buttonStyle(.glassProminent)
                    Spacer()
                    Menu {
                        Button("Show in Finder") { store.system.reveal(record.url) }
                        Button("Copy File Path") { store.system.copy(record.url.path) }
                        Button("Remove from Recent Projects") { store.removeRecentProject(record.url) }
                    } label: { Label("Project Actions", systemImage: "ellipsis.circle") }.labelStyle(.iconOnly).accessibilityLabel(Text("Project Actions"))
                }
            }.padding(8)
        }
        .contextMenu {
            Button("Open Project") { store.requestOpen(record.url) }
            Button("Show in Finder") { store.system.reveal(record.url) }
            Button("Copy File Path") { store.system.copy(record.url.path) }
            Button("Remove from Recent Projects") { store.removeRecentProject(record.url) }
        }
    }
}
