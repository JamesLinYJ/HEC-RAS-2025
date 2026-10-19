import RASWorkspaceCore
import SwiftUI

// ObservableUSGSItem and USGSTerrainImportControl presentation contracts.
// Catalog lookup, raster conversion and downloads remain in the data adapter.
struct TerrainTile: Identifiable, Sendable {
    enum State: Sendable { case available, downloading, importing }
    let id: String
    let title: String
    let publicationDate: Date?
    let sizeInBytes: Int64?
    let resolution: String
    let cellSize: String
    let metadataURL: URL?
    let boundary: [MapPoint]
    var state: State
    var progressPercent: Double?
}

private enum TerrainPublicationDateDirection: String, CaseIterable, Identifiable {
    case onOrAfter
    case onOrBefore

    var id: String { rawValue }
    var title: String {
        switch self {
        case .onOrAfter: return "On or After"
        case .onOrBefore: return "On or Before"
        }
    }
}

@MainActor
protocol TerrainDownloadProvider {
    func tiles(in extent: ViewportRequest?) async throws -> [TerrainTile]
    func download(_ id: String, progress: @escaping @MainActor (Double?) -> Void) async throws -> TerrainTile
    func hide(_ id: String) async throws -> TerrainTile
}

@MainActor
final class TerrainDownloadSession: ObservableObject {
    @Published private(set) var tiles: [TerrainTile] = []
    @Published private(set) var loading = false
    @Published var selected: Set<String> = []
    @Published var highlightedID: String?
    @Published var error: String?
    private var revision = 0
    private var tasks: [String: Task<Void, Never>] = [:]
    var isDownloading: Bool { !tasks.isEmpty }
    var importingIDs: Set<String> { Set(tiles.filter { $0.state == .importing }.map(\.id)) }

    func refresh(provider: (any TerrainDownloadProvider)?, extent: ViewportRequest?) async {
        guard let provider, !isDownloading, !loading else { return }
        revision += 1; let captured = revision
        loading = true; error = nil
        defer { if captured == revision { loading = false } }
        do {
            let result = try await provider.tiles(in: extent)
            guard captured == revision, !Task.isCancelled else { return }
            tiles = result; selected.formIntersection(Set(result.map(\.id)))
            if !result.contains(where: { $0.id == highlightedID }) { highlightedID = nil }
        } catch { if captured == revision, !Task.isCancelled { self.error = error.localizedDescription } }
    }

    @discardableResult
    func download(_ ids: Set<String>, provider: (any TerrainDownloadProvider)?) -> [Task<Void, Never>] {
        guard let provider else { return [] }
        var startedTasks: [Task<Void, Never>] = []
        for id in ids {
            guard tasks[id] == nil, let index = tiles.firstIndex(where: { $0.id == id }), tiles[index].state == .available else { continue }
            let captured = revision
            tiles[index].state = .downloading; tiles[index].progressPercent = nil
            tasks[id] = Task {
                defer { if captured == revision { tasks[id] = nil } }
                do {
                    let updated = try await provider.download(id) { [weak self = self] value in
                        guard let self, captured == self.revision,
                              let index = self.tiles.firstIndex(where: { $0.id == id }), self.tasks[id] != nil else { return }
                        self.tiles[index].progressPercent = value.flatMap { $0.isFinite ? min(max($0, 0), 100) : nil }
                    }
                    guard captured == revision, !Task.isCancelled else { return }
                    guard updated.id == id else { throw CocoaError(.coderInvalidValue) }
                    replace(updated)
                } catch {
                    guard captured == revision, !Task.isCancelled else { return }
                    if let index = tiles.firstIndex(where: { $0.id == id }) { tiles[index].state = .available; tiles[index].progressPercent = nil }
                    self.error = error.localizedDescription
                }
            }
            if let task = tasks[id] { startedTasks.append(task) }
        }
        return startedTasks
    }

    func hide(_ id: String, provider: (any TerrainDownloadProvider)?) async {
        guard let provider else { return }
        let captured = revision
        do {
            let updated = try await provider.hide(id)
            guard captured == revision, !Task.isCancelled, updated.id == id else { return }
            replace(updated)
        } catch { if captured == revision, !Task.isCancelled { self.error = error.localizedDescription } }
    }
    func cancel() {
        revision += 1; tasks.values.forEach { $0.cancel() }; tasks = [:]; loading = false
    }
    private func replace(_ tile: TerrainTile) {
        if let index = tiles.firstIndex(where: { $0.id == tile.id }) { tiles[index] = tile }
    }
}

struct TerrainDownloadsView: View {
    @ObservedObject var store: WorkspaceStore
    @StateObject private var session = TerrainDownloadSession()
    @Binding var importingIDs: Set<String>
    @State private var search = ""
    @State private var criteria = "All"
    @State private var selectedResolutions: Set<String> = []
    @State private var filterPublicationDate = false
    @State private var publicationDate = Date()
    @State private var dateDirection = TerrainPublicationDateDirection.onOrAfter
    @State private var mapHoverLocation: CGPoint?
    @State private var overlapChoices: [String] = []
    @State private var mapScale: CGFloat = 1
    @State private var mapOffset = CGSize.zero
    @GestureState private var mapDrag = CGSize.zero
    private var resolutions: [String] { Array(Set(session.tiles.map(\.resolution))).filter { !$0.isEmpty }.sorted() }
    private var displayed: [TerrainTile] {
        session.tiles.filter {
            (search.isEmpty || [$0.title, $0.resolution, $0.cellSize].contains { $0.localizedCaseInsensitiveContains(search) }) &&
            (criteria == "All" || criteria == "Selected" && session.selected.contains($0.id) || criteria == "Importing" && $0.state == .importing) &&
            (selectedResolutions.isEmpty || selectedResolutions.contains($0.resolution)) &&
            (!filterPublicationDate || $0.publicationDate.map {
                dateDirection == .onOrAfter ? $0 >= publicationDate : $0 <= publicationDate
            } == true)
        }
    }
    private var highlighted: TerrainTile? { displayed.first { $0.id == session.highlightedID } }
    private var selectedBytes: Int64 { session.tiles.filter { session.selected.contains($0.id) }.compactMap(\.sizeInBytes).reduce(0, +) }
    private var resolutionFilterTitle: String {
        if selectedResolutions.isEmpty || selectedResolutions.count == resolutions.count { return L10n.text("All Resolutions") }
        if selectedResolutions.count == 1 { return selectedResolutions.first ?? L10n.text("All Resolutions") }
        return L10n.format("%d Resolutions", selectedResolutions.count)
    }
    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                HStack {
                    TextField("Search terrain tiles", text: $search).textFieldStyle(.roundedBorder)
                    Picker("Selection Criteria", selection: $criteria) {
                        Text("All Tiles").tag("All"); Text("Selected Tiles").tag("Selected"); Text("Tiles To Import").tag("Importing")
                    }.frame(width: 180)
                    Button { Task { await refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                        .disabled(store.terrainDownloadProvider == nil || session.loading || session.isDownloading)
                }
                HStack(spacing: 12) {
                    Menu {
                        ForEach(resolutions, id: \.self) { value in
                            Toggle(value, isOn: Binding(
                                get: { selectedResolutions.contains(value) },
                                set: { selected in
                                    if selected { selectedResolutions.insert(value) }
                                    else { selectedResolutions.remove(value) }
                                }
                            ))
                        }
                        if !selectedResolutions.isEmpty {
                            Divider()
                            Button("Clear Resolutions") { selectedResolutions = [] }
                        }
                    } label: {
                        Label {
                            Text(verbatim: resolutionFilterTitle)
                        } icon: {
                            Image(systemName: "slider.horizontal.3")
                        }
                    }
                    .disabled(resolutions.isEmpty)
                    Toggle("Date", isOn: $filterPublicationDate)
                        .toggleStyle(.checkbox)
                    Picker("Date Direction", selection: $dateDirection) {
                        ForEach(TerrainPublicationDateDirection.allCases) { direction in
                            Text(LocalizedStringKey(direction.title)).tag(direction)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 180)
                    DatePicker("Date", selection: $publicationDate, displayedComponents: [.date])
                        .labelsHidden()
                        .disabled(!filterPublicationDate)
                    Spacer(minLength: 0)
                    Button("Reset") {
                        search = ""; criteria = "All"; selectedResolutions = []; filterPublicationDate = false
                        dateDirection = .onOrAfter; publicationDate = Date()
                        session.selected = []
                    }
                }
            }.padding(12)
            HSplitView {
                List(selection: $session.selected) {
                    ForEach(displayed) { tile in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack { Text(tile.title).lineLimit(2); Spacer(); downloadButton(tile) }
                            HStack { Text(tile.resolution); Spacer(); Text(tile.cellSize) }.font(.caption).foregroundStyle(.secondary)
                            HStack {
                                Text(tile.publicationDate?.formatted(date: .numeric, time: .omitted) ?? "—")
                                Spacer()
                                Text(tile.sizeInBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "—")
                            }.font(.caption2).foregroundStyle(.tertiary)
                            if tile.state == .downloading {
                                ProgressView(value: tile.progressPercent, total: 100).controlSize(.small)
                            }
                        }.padding(.vertical, 4).tag(tile.id)
                            .onHover { if $0 { session.highlightedID = tile.id } }
                            .contextMenu {
                                Button("Download") { session.download([tile.id], provider: store.terrainDownloadProvider) }.disabled(tile.state != .available)
                                Button("Hide Tile") { Task { await session.hide(tile.id, provider: store.terrainDownloadProvider) } }.disabled(tile.state != .importing)
                                if let url = tile.metadataURL { Button("Metadata") { store.system.openWebsite(url) } }
                            }
                    }
                }.frame(minWidth: 240, idealWidth: 280)
                GeometryReader { proxy in
                    let dragOffset = CGSize(width: mapOffset.width + mapDrag.width, height: mapOffset.height + mapDrag.height)
                    let transform = MapTransform(points: displayed.flatMap(\.boundary), size: proxy.size, scale: mapScale, offset: dragOffset)
                    Canvas { context, size in
                        for tile in displayed {
                            let path = boundaryPath(tile, transform: transform)
                            let color: Color = tile.state == .importing ? .green : session.selected.contains(tile.id) ? .accentColor : .secondary
                            context.fill(path, with: .color(color.opacity(0.15)))
                            context.stroke(path, with: .color(tile.id == session.highlightedID ? .accentColor : color), lineWidth: tile.id == session.highlightedID ? 3 : 1)
                        }
                    }.background(Color(nsColor: .textBackgroundColor))
                        .contentShape(Rectangle())
                        .onTapGesture { location in
                            let matches = displayed.reversed().filter { boundaryPath($0, transform: transform).contains(location) }
                            guard !matches.isEmpty else { return }
                            session.highlightedID = matches[0].id
                            if matches.count > 1 { overlapChoices = matches.map(\.id) }
                            else { toggleSelection(matches[0].id) }
                        }
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let location):
                                mapHoverLocation = location
                                session.highlightedID = displayed.reversed().first {
                                    boundaryPath($0, transform: transform).contains(location)
                                }?.id
                            case .ended:
                                mapHoverLocation = nil
                            }
                        }
                        .simultaneousGesture(DragGesture(minimumDistance: 4)
                            .updating($mapDrag) { value, state, _ in state = value.translation }
                            .onEnded { value in
                                mapOffset.width += value.translation.width
                                mapOffset.height += value.translation.height
                            })
                        .simultaneousGesture(MagnifyGesture().onEnded { value in
                            mapScale = min(1_000_000, max(0.000001, mapScale * value.magnification))
                        })
                        .overlay(alignment: .topTrailing) {
                            if mapHoverLocation == nil, let highlighted {
                                tileInformation(highlighted).padding(12).workspaceGlass().padding(12)
                            }
                        }
                        .overlay(alignment: .topLeading) {
                            if let location = mapHoverLocation, let highlighted {
                                tileHoverAnnotation(highlighted)
                                    .frame(width: 230)
                                    .position(
                                        x: min(max(location.x + 125, 125), max(125, proxy.size.width - 125)),
                                        y: min(max(location.y - 58, 58), max(58, proxy.size.height - 58))
                                    )
                                    .allowsHitTesting(false)
                            }
                        }
                        .overlay {
                            if session.loading { ProgressView() }
                            else if store.terrainDownloadProvider == nil {
                                ContentUnavailableView("The original model adapter for this tool is unavailable.", systemImage: "externaldrive.badge.questionmark")
                            }
                            else if session.tiles.isEmpty { ContentUnavailableView("No Terrain Tiles", systemImage: "mountain.2") }
                        }
                        .overlay(alignment: .bottomTrailing) {
                            HStack(spacing: 12) {
                                Button { mapScale = min(1_000_000, mapScale * 1.3) } label: {
                                    Image(systemName: "plus.magnifyingglass")
                                }.help("Zoom In")
                                Button { mapScale = max(0.000001, mapScale / 1.3) } label: {
                                    Image(systemName: "minus.magnifyingglass")
                                }.help("Zoom Out")
                                Button { mapScale = 1; mapOffset = .zero } label: {
                                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                                }.help("Zoom to Full Extent")
                            }
                            .buttonStyle(.borderless)
                            .padding(10)
                            .workspaceGlass()
                            .padding(12)
                        }
                        .popover(isPresented: Binding(
                            get: { !overlapChoices.isEmpty },
                            set: { if !$0 { overlapChoices = [] } }
                        ), arrowEdge: .trailing) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Overlapping Tiles").font(.headline)
                                Text(L10n.format("%d tiles overlap here. Choose one to select.", overlapChoices.count))
                                    .font(.caption).foregroundStyle(.secondary)
                                ForEach(overlapChoices, id: \.self) { id in
                                    if let tile = session.tiles.first(where: { $0.id == id }) {
                                        Button {
                                            session.highlightedID = id
                                            toggleSelection(id)
                                            overlapChoices = []
                                        } label: {
                                            VStack(alignment: .leading, spacing: 3) {
                                                Text(tile.title).lineLimit(2)
                                                Text("\(tile.resolution) · \(tile.cellSize)")
                                                    .font(.caption).foregroundStyle(.secondary)
                                            }
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                            .padding(14)
                            .frame(minWidth: 250, idealWidth: 300)
                        }
                }.frame(minWidth: 260)
            }
            Divider()
            HStack {
                Text(L10n.format("%d tiles", displayed.count)).foregroundStyle(.secondary)
                Text(L10n.format("%d tiles", session.selected.count)).foregroundStyle(.secondary)
                Text(ByteCountFormatter.string(fromByteCount: selectedBytes, countStyle: .file)).foregroundStyle(.secondary)
                Spacer()
                Button("Deselect All") { session.selected = [] }.disabled(session.selected.isEmpty)
                Button("Download Selected") { session.download(session.selected, provider: store.terrainDownloadProvider) }
                    .disabled(store.terrainDownloadProvider == nil || !session.tiles.contains { session.selected.contains($0.id) && $0.state == .available })
            }.padding(12)
        }
        .task { await refresh() }
        .onDisappear { session.cancel() }
        .onChange(of: displayed.map(\.id)) { _, visibleIDs in
            let visible = Set(visibleIDs)
            if let highlightedID = session.highlightedID, !visible.contains(highlightedID) {
                session.highlightedID = nil
            }
            overlapChoices.removeAll { !visible.contains($0) }
        }
        .onChange(of: resolutions) { _, available in selectedResolutions.formIntersection(Set(available)) }
        .onChange(of: session.importingIDs) { _, value in importingIDs = value }
        .alert("HEC-RAS 2025", isPresented: Binding(get: { session.error != nil }, set: { if !$0 { session.error = nil } })) {
            Button("OK") { session.error = nil }
        } message: { Text(session.error ?? "") }
    }
    private func refresh() async { await session.refresh(provider: store.terrainDownloadProvider, extent: store.activeMapState.currentExtent) }
    private func boundaryPath(_ tile: TerrainTile, transform: MapTransform) -> Path {
        var path = Path()
        guard let first = tile.boundary.first else { return path }
        path.move(to: transform.screen(first)); tile.boundary.dropFirst().forEach { path.addLine(to: transform.screen($0)) }; path.closeSubpath()
        return path
    }
    @ViewBuilder private func downloadButton(_ tile: TerrainTile) -> some View {
        if tile.state == .importing {
            Button { Task { await session.hide(tile.id, provider: store.terrainDownloadProvider) } } label: { Label("Hide Tile", systemImage: "eye.slash") }.labelStyle(.iconOnly).buttonStyle(.borderless)
        } else {
            Button { session.download([tile.id], provider: store.terrainDownloadProvider) } label: { Label("Download", systemImage: "arrow.down.circle") }
                .labelStyle(.iconOnly).buttonStyle(.borderless).disabled(tile.state == .downloading || store.terrainDownloadProvider == nil)
        }
    }
    private func tileInformation(_ tile: TerrainTile) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(tile.title).font(.headline).lineLimit(3)
            LabeledContent("Resolution", value: tile.resolution)
            LabeledContent("Cell Size", value: tile.cellSize)
            LabeledContent("Publication Date", value: tile.publicationDate?.formatted(date: .numeric, time: .omitted) ?? "—")
            LabeledContent("File Size", value: tile.sizeInBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "—")
            if let url = tile.metadataURL { Button("Metadata") { store.system.openWebsite(url) }.buttonStyle(.link) }
        }.font(.caption).frame(maxWidth: 230)
    }

    private func tileHoverAnnotation(_ tile: TerrainTile) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(tile.title).font(.headline).lineLimit(2)
            Text("\(tile.resolution) · \(tile.cellSize)").font(.caption)
            HStack {
                Text(tile.publicationDate?.formatted(date: .numeric, time: .omitted) ?? "—")
                Spacer(minLength: 4)
                Text(tile.sizeInBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "—")
            }.font(.caption2).foregroundStyle(.secondary)
        }
        .padding(10)
        .workspaceGlass()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Terrain tile details")
    }

    private func toggleSelection(_ id: String) {
        if session.selected.contains(id) { session.selected.remove(id) }
        else { session.selected.insert(id) }
    }
}
