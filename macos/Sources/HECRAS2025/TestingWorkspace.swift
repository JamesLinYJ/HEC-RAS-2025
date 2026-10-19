import RASWorkspaceCore
import SwiftUI

struct TestingObject: Identifiable, Sendable {
    enum Kind: String, CaseIterable, Sendable { case project, geometry }
    let id: String
    let name: String
    let folder: String
    let kind: Kind
    let version: String
    let publicationDate: Date?
    let description: String
    let poiCount: Int?
}
struct InterestPoint: Identifiable, Sendable {
    let id: UUID
    let serverID: Int?
    var name: String
    var x: Double
    var y: Double
}
struct TestingSnapshot: Sendable {
    let objects: [TestingObject]
    let commits: [EditorChoice]
    let points: [InterestPoint]
    let canEditPoints: Bool
    let vectors: [MapVectorLayer]
    let status: String
    let log: [String]
    var hintExtent: ViewportRequest? = nil
    var rasters: [MapRasterLayer] = []
    var pointOwnerID: String? = nil
}
enum TestingAction: Sendable {
    case details(id: String)
    case open(id: String)
    case edit(id: String)
    case rename(id: String, name: String)
    case move(id: String, folder: String)
    case description(id: String, text: String)
    case savePoints([InterestPoint])
    case reconcilePoints(id: String, points: [InterestPoint])
    case queueRun(id: String, commit: String, tag: String, iterations: Int)
}
struct TestingResult: Sendable { let snapshot: TestingSnapshot; let projectURL: URL? }

private struct TestingObjectTreeNode: Identifiable {
    let id: String
    let title: String
    let object: TestingObject?
    let children: [TestingObjectTreeNode]

    var expandableIDs: [String] {
        guard !children.isEmpty else { return [] }
        return [id] + children.flatMap(\.expandableIDs)
    }
    var leafCount: Int {
        if case .some = object { return 1 }
        return children.reduce(0) { $0 + $1.leafCount }
    }

    static func roots(from objects: [TestingObject]) -> [TestingObjectTreeNode] {
        TestingObject.Kind.allCases.compactMap { kind in
            let matching = objects.filter { $0.kind == kind }
            guard !matching.isEmpty else { return nil }
            let title = kind == .project ? "Projects" : "Geometries"
            return TestingObjectTreeNode(
                id: kind.rawValue,
                title: title,
                object: nil,
                children: children(from: matching, kind: kind, path: [])
            )
        }
    }

    private static func children(from objects: [TestingObject], kind: TestingObject.Kind, path: [String]) -> [TestingObjectTreeNode] {
        let foldersByKey = objects.compactMap { object -> String? in
            let components = folderComponents(object.folder)
            guard components.count > path.count, sameFolderPath(Array(components.prefix(path.count)), path) else { return nil }
            return components[path.count]
        }.reduce(into: [String: String]()) { names, folder in
            let key = folder.lowercased()
            if names[key] == nil { names[key] = folder }
        }
        let folders = foldersByKey.values.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }

        let folderNodes = folders.map { folder in
            let nextPath = path + [folder]
            return TestingObjectTreeNode(
                id: "\(kind.rawValue)/\(nextPath.joined(separator: "/"))",
                title: folder,
                object: nil,
                children: children(from: objects, kind: kind, path: nextPath)
            )
        }

        let leaves = objects
            .filter { sameFolderPath(folderComponents($0.folder), path) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map { object in
                TestingObjectTreeNode(id: "\(kind.rawValue)/object/\(object.id)", title: object.name, object: object, children: [])
            }

        return folderNodes + leaves
    }

    private static func folderComponents(_ folder: String) -> [String] {
        folder.split(separator: "/", omittingEmptySubsequences: true).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    private static func sameFolderPath(_ lhs: [String], _ rhs: [String]) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { pair in
            pair.0.localizedCaseInsensitiveCompare(pair.1) == .orderedSame
        }
    }
}

@MainActor
protocol TestingProvider {
    func load(projectURL: URL?) async throws -> TestingSnapshot
    func perform(_ action: TestingAction) async throws -> TestingResult
    func importPoints(_ shapefile: URL) async throws -> [InterestPoint]
}

@MainActor
final class TestingSession: ObservableObject {
    @Published private(set) var snapshot: TestingSnapshot?
    @Published private(set) var busy = false
    @Published var points: [InterestPoint] = []
    @Published private(set) var pointsModified = false
    @Published private(set) var snapshotRevision = 0
    @Published var error: String?
    private let provider: (any TestingProvider)?
    private var revision = 0
    private var pointRevision = 0
    init(provider: (any TestingProvider)?) { self.provider = provider }
    var available: Bool { provider != nil }
    func load(projectURL: URL?) async {
        guard let provider, !busy, !pointsModified else { return }
        revision += 1; let captured = revision
        busy = true; error = nil
        defer { if captured == revision { busy = false } }
        do {
            let value = try await provider.load(projectURL: projectURL)
            guard captured == revision, !Task.isCancelled else { return }
            install(value)
        } catch { if captured == revision, !Task.isCancelled { self.error = error.localizedDescription } }
    }
    func editPoint(_ id: UUID, name: String? = nil, x: Double? = nil, y: Double? = nil) {
        guard snapshot?.canEditPoints == true, !busy, x?.isFinite != false, y?.isFinite != false,
              let index = points.firstIndex(where: { $0.id == id }) else { return }
        if let name { points[index].name = name }; if let x { points[index].x = x }; if let y { points[index].y = y }
        pointRevision += 1; pointsModified = true
    }
    func addPoint(_ point: MapPoint) {
        guard snapshot?.canEditPoints == true, !busy, point.x.isFinite, point.y.isFinite else { return }
        points.append(InterestPoint(id: UUID(), serverID: nil, name: "POI", x: point.x, y: point.y)); pointRevision += 1; pointsModified = true
    }
    func removePoints(_ ids: Set<UUID>) {
        guard snapshot?.canEditPoints == true, !busy, points.contains(where: { ids.contains($0.id) }) else { return }
        points.removeAll { ids.contains($0.id) }; pointRevision += 1; pointsModified = true
    }
    func discardPoints() { guard !busy else { return }; points = snapshot?.points ?? []; pointRevision += 1; pointsModified = false }
    func importPoints(_ file: URL) async {
        guard let provider, snapshot?.canEditPoints == true, !busy else { return }
        revision += 1; let captured = revision
        busy = true; error = nil
        defer { if captured == revision { busy = false } }
        do {
            let imported = try await provider.importPoints(file)
            guard captured == revision, !Task.isCancelled else { return }
            points.append(contentsOf: imported); pointRevision += 1; pointsModified = true
        } catch { if captured == revision, !Task.isCancelled { self.error = error.localizedDescription } }
    }
    func perform(_ action: TestingAction) async -> TestingResult? {
        guard let provider, !busy else { return nil }
        if pointsModified {
            if case .savePoints = action {} else { error = L10n.text("Save or discard point changes before continuing."); return nil }
        }
        revision += 1; let captured = revision, capturedPoints = pointRevision
        busy = true; error = nil
        defer { if captured == revision { busy = false } }
        do {
            let providerAction: TestingAction
            if case .savePoints(let editedPoints) = action, let ownerID = snapshot?.pointOwnerID {
                providerAction = .reconcilePoints(id: ownerID, points: editedPoints)
            } else {
                providerAction = action
            }
            let result = try await provider.perform(providerAction)
            guard captured == revision, !Task.isCancelled else { return nil }
            if capturedPoints == pointRevision { install(result.snapshot) }
            else { snapshot = result.snapshot; snapshotRevision += 1 }
            return result
        } catch { if captured == revision, !Task.isCancelled { self.error = error.localizedDescription }; return nil }
    }
    func invalidate() { revision += 1; busy = false }
    private func install(_ value: TestingSnapshot) { snapshot = value; points = value.points; pointsModified = false; snapshotRevision += 1 }
}

struct TestingWorkspace: View {
    @ObservedObject var store: WorkspaceStore
    let initialPage: ToolKind
    @StateObject private var session: TestingSession
    @State private var page = "Projects"
    @State private var query = ""
    @State private var selectedID: String?
    @State private var skipNextSelectionDetailsID: String?
    @State private var selectedPoints: Set<UUID> = []
    @State private var pointTool = "Edit POIs"
    @State private var mapScale: CGFloat = 1
    @State private var mapOffset = CGSize.zero
    @State private var panStart: CGSize?
    @State private var draggingPoint: InterestPoint?
    @State private var tag = ""
    @State private var commit = ""
    @State private var iterations = 1
    @State private var promptMode = "Rename"
    @State private var prompt = ""
    @State private var showPrompt = false
    @State private var showDiscard = false
    @State private var expandedTreeNodes: Set<String>?
    private let onClose: (() -> Void)?
    private let title: String?
    init(store: WorkspaceStore, initialPage: ToolKind, session: TestingSession? = nil, title: String? = nil, onClose: (() -> Void)? = nil) {
        self.store = store; self.initialPage = initialPage
        self.onClose = onClose
        self.title = title
        _session = StateObject(wrappedValue: session ?? TestingSession(provider: store.testingProvider))
    }
    private var selected: TestingObject? { session.snapshot?.objects.first { $0.id == selectedID } }
    private var enabled: Bool { session.available && !session.busy }
    private var treeRoots: [TestingObjectTreeNode] {
        let objects = session.snapshot?.objects ?? []
        let visibleObjects = objects.filter {
            query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.folder.localizedCaseInsensitiveContains(query)
        }
        return TestingObjectTreeNode.roots(from: visibleObjects)
    }
    private var expandableTreeNodeIDs: Set<String> { Set(treeRoots.flatMap(\.expandableIDs)) }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(title ?? L10n.text("Testing Utility"), systemImage: "checkmark.seal").font(.title2)
                Spacer()
                Picker("Page", selection: $page) {
                    Text("Projects").tag("Projects"); Text("Points of Interest").tag("Points of Interest"); Text("Run").tag("Run")
                }.pickerStyle(.segmented).frame(width: 380)
            }.padding(16)
            Divider()
            switch page { case "Points of Interest": pointEditor; case "Run": runner; default: objectBrowser }
            Divider()
            HStack {
                if session.busy { ProgressView().controlSize(.small) }
                Text(session.snapshot?.status ?? "").font(.caption).lineLimit(2)
                Spacer()
                if page == "Points of Interest" {
                    Button("Discard Changes") { session.discardPoints() }.disabled(!session.pointsModified || session.busy)
                    Button("Save Points") { Task { _ = await session.perform(.savePoints(session.points)) } }.disabled(!enabled || !session.pointsModified)
                }
                Button("Done") { if session.pointsModified { showDiscard = true } else { close() } }.keyboardShortcut(.cancelAction).disabled(session.busy)
            }.padding(12)
        }.frame(width: 1020, height: 720)
            .task {
                page = initialPage == .testingPOI ? "Points of Interest" : initialPage == .testingRunner ? "Run" : "Projects"
                await session.load(projectURL: store.document?.url)
                if commit.isEmpty { commit = session.snapshot?.commits.first?.id ?? "" }
            }
            .onDisappear { session.invalidate() }
            .onChange(of: selectedID) { _, id in
                guard let id else { return }
                if skipNextSelectionDetailsID == id {
                    skipNextSelectionDetailsID = nil
                    return
                }
                guard enabled else { return }
                Task { _ = await session.perform(.details(id: id)) }
            }
            .onChange(of: session.snapshotRevision) { _, _ in expandedTreeNodes = nil }
            .alert("HEC-RAS 2025", isPresented: Binding(get: { session.error != nil }, set: { if !$0 { session.error = nil } })) {
                Button("OK") { session.error = nil }
            } message: { Text(session.error ?? "") }
            .alert(LocalizedStringKey(promptMode), isPresented: $showPrompt) {
                TextField(LocalizedStringKey(promptMode), text: $prompt)
                Button("Apply") {
                    guard let selected else { return }
                    Task { await perform(promptMode == "Rename" ? .rename(id: selected.id, name: prompt) : promptMode == "Move to Folder" ? .move(id: selected.id, folder: prompt) : .description(id: selected.id, text: prompt)) }
                }
                Button("Cancel", role: .cancel) {}
            }
            .alert("Discard point changes?", isPresented: $showDiscard) {
                Button("Save") { Task { if await session.perform(.savePoints(session.points)) != nil { close() } } }
                Button("Discard", role: .destructive) { close() }
                Button("Cancel", role: .cancel) {}
            }
    }
    private var objectBrowser: some View {
        HSplitView {
            VStack(spacing: 0) {
                HStack {
                    TextField("Search testing projects", text: $query).textFieldStyle(.roundedBorder)
                    Button { Task { await session.load(projectURL: store.document?.url) } } label: { Label("Refresh", systemImage: "arrow.clockwise") }.disabled(!enabled || session.pointsModified)
                }.padding(12)
                HStack(spacing: 14) {
                    Button { setAllTreeNodesExpanded(true) } label: { Label("Expand All", systemImage: "chevron.down.square") }
                        .labelStyle(.iconOnly).help("Expand All").accessibilityLabel("Expand All").disabled(expandableTreeNodeIDs.isEmpty)
                    Button { setAllTreeNodesExpanded(false) } label: { Label("Collapse All", systemImage: "chevron.up.square") }
                        .labelStyle(.iconOnly).help("Collapse All").accessibilityLabel("Collapse All").disabled(expandableTreeNodeIDs.isEmpty)
                    Button { store.activeTool = .testingProjectUpload } label: { Label("Upload Testing Project", systemImage: "square.and.arrow.up") }
                        .labelStyle(.iconOnly).help("Upload Testing Project").accessibilityLabel("Upload Testing Project")
                    Button { openTestingClient() } label: { Label("Go to Client", systemImage: "safari") }
                        .labelStyle(.iconOnly).help("Go to Client").accessibilityLabel("Go to Client")
                    Spacer()
                }.padding(.horizontal, 14).padding(.bottom, 8)
                List(selection: $selectedID) {
                    ForEach(treeRoots) { root in treeEntry(root) }
                }.listStyle(.sidebar)
            }.frame(minWidth: 280, idealWidth: 330)
            if let selected {
                Form {
                    Section {
                        Text(selected.name).font(.title2)
                        LabeledContent("Type", value: L10n.text(selected.kind == .project ? "Project" : "Geometry"))
                        LabeledContent("Folder", value: selected.folder)
                        LabeledContent("Version", value: selected.version)
                        if let date = selected.publicationDate { LabeledContent("Publish Date", value: date.formatted(date: .numeric, time: .shortened)) }
                        if let count = selected.poiCount { LabeledContent("Points of Interest", value: count.formatted()) }
                        Text(selected.description).textSelection(.enabled)
                    }
                    Section { Button("Run on Server") { page = "Run" } }
                }.formStyle(.grouped)
            } else { ContentUnavailableView("Select a Project or Geometry", systemImage: "folder") }
        }
    }
    private var pointEditor: some View {
        VSplitView {
            GeometryReader { geometry in
                let background = session.snapshot?.vectors ?? []
                let transform = MapTransform(points: mapBounds, size: geometry.size, scale: mapScale, offset: mapOffset)
                ZStack {
                Color(nsColor: .textBackgroundColor)
                RasterCanvas(layers: session.snapshot?.rasters ?? [], points: mapBounds, scale: mapScale, offset: mapOffset, revision: session.snapshotRevision)
                Canvas { context, _ in
                    for (index, layer) in background.enumerated() {
                        for feature in layer.features { context.stroke(transform.path(feature), with: .color(VectorStyle.color(index)), lineWidth: 1) }
                    }
                    for point in session.points {
                        let location = transform.screen(MapPoint(x: point.x, y: point.y))
                        context.fill(Path(ellipseIn: CGRect(x: location.x - 5, y: location.y - 5, width: 10, height: 10)), with: .color(selectedPoints.contains(point.id) ? .orange : .accentColor))
                        context.draw(Text(point.name).font(.caption), at: CGPoint(x: location.x + 8, y: location.y - 8), anchor: .leading)
                    }
                }
                }.contentShape(Rectangle())
                    .simultaneousGesture(SpatialTapGesture().onEnded { value in
                        guard pointTool == "Edit POIs" else { return }
                        if let nearest = session.points.min(by: { distance($0, value.location, transform) < distance($1, value.location, transform) }), distance(nearest, value.location, transform) < 14 { selectedPoints = [nearest.id] }
                        else { session.addPoint(transform.world(value.location)) }
                    })
                    .gesture(DragGesture().onChanged { value in
                        if pointTool == "Pan" {
                            if panStart == nil { panStart = mapOffset }
                            mapOffset = CGSize(width: (panStart?.width ?? 0) + value.translation.width, height: (panStart?.height ?? 0) + value.translation.height)
                        } else {
                            if draggingPoint == nil {
                                if let nearest = session.points.min(by: { distance($0, value.startLocation, transform) < distance($1, value.startLocation, transform) }), distance(nearest, value.startLocation, transform) < 14 { draggingPoint = nearest; selectedPoints = [nearest.id] }
                            }
                            if let point = draggingPoint {
                                let start = transform.screen(MapPoint(x: point.x, y: point.y))
                                let world = transform.world(CGPoint(x: start.x + value.translation.width, y: start.y + value.translation.height))
                                session.editPoint(point.id, x: world.x, y: world.y)
                            }
                        }
                    }.onEnded { _ in panStart = nil; draggingPoint = nil })
                    .simultaneousGesture(MagnifyGesture().onEnded { mapScale = min(max(mapScale * $0.magnification, 0.125), 256) })
                    .focusable().onDeleteCommand { session.removePoints(selectedPoints); selectedPoints = [] }
                    .overlay(alignment: .topLeading) {
                        HStack {
                            Picker("Map Tool", selection: $pointTool) { Text("Edit POIs").tag("Edit POIs"); Text("Pan").tag("Pan") }.pickerStyle(.segmented).frame(width: 160)
                            Button("Remove") { session.removePoints(selectedPoints); selectedPoints = [] }.disabled(selectedPoints.isEmpty || session.snapshot?.canEditPoints != true)
                            Button("Import Shapefile…") { if let file = store.system.choosePointShapefile() { Task { await session.importPoints(file) } } }.disabled(!enabled || session.snapshot?.canEditPoints != true)
                            Button { mapScale = 1; mapOffset = .zero } label: { Label("Zoom to Full Extent", systemImage: "arrow.up.left.and.arrow.down.right") }
                        }.padding(10).workspaceGlass().padding(12)
                    }
            }.frame(minHeight: 260)
            Table(session.points, selection: $selectedPoints) {
                TableColumn("Name") { point in TextField("Name", text: Binding(get: { session.points.first { $0.id == point.id }?.name ?? point.name }, set: { session.editPoint(point.id, name: $0) })).textFieldStyle(.plain) }
                TableColumn("X") { point in pointCoordinate(point, axis: "X") }
                TableColumn("Y") { point in pointCoordinate(point, axis: "Y") }
                TableColumn("Server ID") { Text($0.serverID.map(String.init) ?? "—") }
            }.disabled(session.snapshot?.canEditPoints != true || session.busy).frame(minHeight: 160)
                .onDeleteCommand { session.removePoints(selectedPoints); selectedPoints = [] }
        }
    }
    private var runner: some View {
        VSplitView {
            Form {
                Section("Run on Server") {
                    Picker("Object", selection: $selectedID) {
                        Text("None").tag(nil as String?)
                        ForEach(session.snapshot?.objects ?? []) { Text($0.name).tag(Optional($0.id)) }
                    }
                    TextField("Run Tag", text: $tag)
                    HStack {
                        TextField("Commit", text: $commit, prompt: Text("Paste a commit hash"))
                        Menu("Recent Commits") { ForEach(session.snapshot?.commits ?? []) { choice in Button(choice.title) { commit = choice.id } } }
                    }
                    Stepper(value: $iterations, in: 1...20) { LabeledContent("Iterations", value: iterations.formatted()) }
                    if selected?.poiCount == 0 { Label("This project has no points of interest.", systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                    Button("Queue Run") {
                        if let selectedID, let hash = commit.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ").first { Task { await perform(.queueRun(id: selectedID, commit: String(hash), tag: tag, iterations: iterations)) } }
                    }.disabled(!enabled || selectedID == nil || commit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }.formStyle(.grouped).frame(minHeight: 260)
            ScrollView { Text((session.snapshot?.log ?? []).joined(separator: "\n")).font(.system(.body, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(12) }.frame(minHeight: 140)
        }
    }
    private func pointCoordinate(_ point: InterestPoint, axis: String) -> some View {
        TextField(axis, value: Binding(get: {
            let current = session.points.first { $0.id == point.id } ?? point
            return axis == "X" ? current.x : current.y
        }, set: { session.editPoint(point.id, x: axis == "X" ? $0 : nil, y: axis == "Y" ? $0 : nil) }), format: .number).textFieldStyle(.plain)
    }
    private func treeEntry(_ node: TestingObjectTreeNode) -> AnyView {
        if let item = node.object {
            return AnyView(
                Label(item.name, systemImage: item.kind == .project ? "folder" : "point.3.connected.trianglepath.dotted")
                    .tag(item.id)
                    .onTapGesture(count: 2) {
                        guard item.kind == .project, enabled else { return }
                        openProject(item)
                    }
                    .contextMenu {
                        if item.kind == .project {
                            Button("Download & Open") { openProject(item) }.disabled(!enabled)
                            Button("Edit Content…") { editPoints(for: item) }.disabled(!enabled)
                        }
                        Button("Rename…") { promptForObject(item, mode: "Rename") }.disabled(!enabled)
                        Button("Move to Folder…") { promptForObject(item, mode: "Move to Folder") }.disabled(!enabled)
                        Button("Description…") { promptForObject(item, mode: "Description") }.disabled(!enabled)
                        Button("Run on Server") { openRunPage(item) }
                    }
            )
        }
        return AnyView(
            DisclosureGroup(isExpanded: treeExpansionBinding(for: node.id)) {
                ForEach(node.children) { child in treeEntry(child) }
            } label: {
                HStack {
                    if node.id == TestingObject.Kind.project.rawValue {
                        Label("Projects", systemImage: "folder")
                    } else if node.id == TestingObject.Kind.geometry.rawValue {
                        Label("Geometries", systemImage: "cube")
                    } else {
                        Label(node.title, systemImage: "folder")
                    }
                    Spacer(minLength: 12)
                    Text(node.leafCount.formatted()).font(.caption).foregroundStyle(.secondary)
                }
            }
        )
    }
    private func treeExpansionBinding(for id: String) -> Binding<Bool> {
        Binding(
            get: { expandedTreeNodes?.contains(id) ?? true },
            set: { value in
                var nodes = expandedTreeNodes ?? expandableTreeNodeIDs
                if value { nodes.insert(id) } else { nodes.remove(id) }
                expandedTreeNodes = nodes
            }
        )
    }
    private func setAllTreeNodesExpanded(_ expanded: Bool) {
        expandedTreeNodes = expanded ? expandableTreeNodeIDs : []
    }
    private func openTestingClient() {
        guard let url = URL(string: "https://ras-benchmarks.hecdev.net") else { return }
        store.system.openWebsite(url)
    }
    private var mapBounds: [MapPoint] {
        if let extent = session.snapshot?.hintExtent { return [extent.lowerLeft, extent.upperRight] }
        return (session.snapshot?.vectors ?? []).flatMap(\.points) + (session.snapshot?.rasters ?? []).flatMap(\.points) + (session.snapshot?.points ?? []).map { MapPoint(x: $0.x, y: $0.y) }
    }
    private func distance(_ point: InterestPoint, _ location: CGPoint, _ transform: MapTransform) -> CGFloat {
        let pixel = transform.screen(MapPoint(x: point.x, y: point.y)); return hypot(pixel.x - location.x, pixel.y - location.y)
    }
    private func beginPrompt(_ mode: String, _ value: String) { promptMode = mode; prompt = value; showPrompt = true }
    private func selectForAction(_ object: TestingObject) {
        if selectedID != object.id {
            skipNextSelectionDetailsID = object.id
            selectedID = object.id
        }
    }
    private func openProject(_ object: TestingObject) {
        guard enabled else { return }
        selectForAction(object)
        Task { await perform(.open(id: object.id)) }
    }
    private func promptForObject(_ object: TestingObject, mode: String) {
        guard enabled else { return }
        selectForAction(object)
        Task {
            guard let result = await session.perform(.details(id: object.id)),
                  let detail = result.snapshot.objects.first(where: { $0.id == object.id }) else { return }
            let value = switch mode {
            case "Rename": detail.name
            case "Move to Folder": detail.folder
            default: detail.description
            }
            beginPrompt(mode, value)
        }
    }
    private func openRunPage(_ object: TestingObject) {
        selectForAction(object)
        page = "Run"
        Task { _ = await session.perform(.details(id: object.id)) }
    }
    private func editPoints(for object: TestingObject) {
        selectForAction(object)
        Task {
            if await session.perform(.edit(id: object.id)) != nil { page = "Points of Interest" }
        }
    }
    private func perform(_ action: TestingAction) async {
        if let result = await session.perform(action), let url = result.projectURL { store.activeTool = nil; store.requestOpen(url) }
    }
    private func close() { if let onClose { onClose() } else { store.activeTool = nil } }
}
