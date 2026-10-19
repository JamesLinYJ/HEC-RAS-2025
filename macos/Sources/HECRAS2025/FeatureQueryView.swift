import RASWorkspaceCore
import SwiftUI

struct FeatureQueryView: View {
    @ObservedObject var store: WorkspaceStore
    let kind: FeatureQueryKind
    @StateObject private var session = FeatureQuerySession()
    @State private var extent: ViewportRequest?
    @State private var mapID: UUID
    @State private var initialExtent: ViewportRequest?
    init(store: WorkspaceStore, kind: FeatureQueryKind) {
        self.store = store; self.kind = kind
        _mapID = State(initialValue: store.lastActiveMapID)
        _initialExtent = State(initialValue: store.activeMapState.currentExtent)
    }
    private var context: FeatureQueryContext { .init(projectSessionID: store.projectSessionID, mapID: mapID, kind: kind) }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(LocalizedStringKey(kind.title), systemImage: "globe").font(.title2)
                Spacer()
                if session.querying { Button("Cancel Query") { session.cancelQuery() } }
                Button { session.query(extent: extent, provider: store.featureQueryProvider) } label: {
                    Label(session.querying ? "Querying..." : "Query Area", systemImage: "magnifyingglass").frame(minWidth: 150)
                }.buttonStyle(.glassProminent).disabled(!session.canQuery || store.featureQueryProvider == nil)
            }.padding(20)
            Divider()
            HSplitView {
                VStack(alignment: .leading, spacing: 0) {
                    if kind == .osm { queryOptions.padding(12).frame(maxHeight: .infinity) }
                    else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 18) { queryOptions }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    Text(L10n.text(session.info)).font(.callout).textSelection(.enabled).padding(.horizontal, 18).padding(.vertical, 8)
                    if session.querying { ProgressView(value: session.progress, total: 100).padding(.horizontal, 18) }
                    if let error = session.error { Text(L10n.text(error)).foregroundStyle(.red).textSelection(.enabled).padding(.horizontal, 18) }
                    Divider()
                    Picker("Output Format", selection: $session.formatID) {
                        ForEach(FeatureQueryOptions.source.exportFormats) { option in Text(option.name).tag(option.id) }
                    }.padding(18).disabled(session.busy)
                }.frame(minWidth: kind == .osm ? 340 : 260, idealWidth: kind == .osm ? 430 : 300, maxWidth: 560)
                FeatureQueryMap(store: store, mapID: mapID, layers: session.result?.layers ?? [], initialExtent: initialExtent, extent: $extent)
                    .frame(minWidth: 350, minHeight: 330)
                    .overlay { if session.querying { ProgressView().controlSize(.large) } }
            }
            Divider()
            HStack {
                Spacer()
                if session.saving { ProgressView().controlSize(.small) }
                Button("Cancel", role: .cancel) { session.cancel(); store.activeTool = nil }.keyboardShortcut(.cancelAction).disabled(session.saving)
                Button("Save to Disk") {
                    let origin = context
                    Task {
                        if let update = await session.save(provider: store.featureQueryProvider), store.projectSessionID == origin.projectSessionID {
                            store.installMapUpdate(update, mapID: origin.mapID); store.refreshAssets(); store.activeTool = nil
                        }
                    }
                }.buttonStyle(.glassProminent).keyboardShortcut(.defaultAction).disabled(!session.canSave || store.featureQueryProvider == nil)
            }.padding(16)
        }
        .frame(minWidth: kind == .osm ? 850 : 740, idealWidth: kind == .osm ? 1050 : 900, maxWidth: 1400, minHeight: 500, idealHeight: 700, maxHeight: 1000)
        .task(id: context) { await session.load(context: context, provider: store.featureQueryProvider) }
        .onDisappear { session.cancel() }
        .interactiveDismissDisabled(session.saving)
    }
    @ViewBuilder private var queryOptions: some View {
        Group {
            switch kind {
            case .nld:
                Text("USACE National Levee Database").font(.headline)
                Text("Query NLD features for the current map extent.").font(.callout).foregroundStyle(.secondary)
                Picker("Feature Type", selection: $session.nldLayerID) {
                    ForEach(FeatureQueryOptions.source.nldLayers) { option in Text(LocalizedStringKey(option.name)).tag(option.id) }
                }
            case .nsi:
                Picker("Query Method", selection: $session.useBoundaryPolygon) {
                    Text("Current Map Extent").tag(false); Text("Polygon").tag(true)
                }.pickerStyle(.radioGroup)
                if session.useBoundaryPolygon {
                    Picker("Polygon Source", selection: $session.polygonID) {
                        Text("Select a polygon source").tag(String?.none)
                        ForEach(session.polygons) { polygon in Text(polygon.name).tag(Optional(polygon.id)) }
                    }
                }
            case .nfhl:
                Text("FEMA National Flood Hazard Layer").font(.headline)
                Text("All flood hazard zones in the current map extent are imported.").font(.callout).foregroundStyle(.secondary)
            case .osm: OSMQueryBuilder(draft: $session.osm, provider: store.featureQueryProvider)
            }
        }.disabled(session.busy)
    }
}

private struct OSMQueryBuilder: View {
    @Binding var draft: OSMQueryDraft
    let provider: (any FeatureQueryProvider)?
    @State private var page = "Preset"
    var body: some View {
        TabView(selection: $page) {
            presetPage.tabItem { Text("Preset") }.tag("Preset")
            ScrollView { builderPage.padding(8) }.tabItem { Text("Builder") }.tag("Builder")
            rawPage.tabItem { Text("Raw QL") }.tag("Raw QL")
        }.frame(minHeight: 260)
    }
    private var presetPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Preset", selection: Binding(get: { draft.selectedPresetID }, set: { id in
                if id == nil { draft.selectedPresetID = nil }
                if let preset = FeatureQueryOptions.source.osmPresets.first(where: { $0.id == id }) { draft.load(preset) }
            })) {
                Text("Custom").tag(String?.none)
                ForEach(FeatureQueryOptions.source.osmPresets) { preset in Text(LocalizedStringKey(preset.name)).tag(Optional(preset.id)) }
            }
            if let preset = FeatureQueryOptions.source.osmPresets.first(where: { $0.id == draft.selectedPresetID }) {
                Text(LocalizedStringKey(preset.description)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }.padding(8)
    }
    private var builderPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(draft.clauses) { clause in
                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            ForEach(["Node", "Way", "Relation"], id: \.self) { kind in
                                Toggle(LocalizedStringKey(kind), isOn: Binding(get: { clause.kinds.contains(kind) }, set: { selected in
                                    changeClause(clause.id) { value in
                                        value.kinds.removeAll { $0 == kind }; if selected { value.kinds.append(kind) }
                                    }
                                })).toggleStyle(.checkbox)
                            }
                            Spacer()
                            Button { draft.editBuilder { $0.clauses.removeAll { $0.id == clause.id } } } label: { Image(systemName: "trash") }.help("Remove Clause")
                        }
                        ForEach(clause.filters) { filter in
                            VStack(spacing: 7) {
                                HStack {
                                    OsmSuggestedField(title: "Tag Key", text: filterText(clause.id, filter.id, key: true), key: filter.key, isKey: true, provider: provider)
                                    Button { changeClause(clause.id) { $0.filters.removeAll { $0.id == filter.id } } } label: { Image(systemName: "minus.circle") }.help("Remove Filter")
                                }
                                HStack {
                                    Picker("Comparison", selection: Binding(get: { filter.comparison }, set: { newValue in
                                        changeFilter(clause.id, filter.id) { $0.comparison = newValue }
                                    })) {
                                        ForEach(OsmOperator.allCases, id: \.self) { option in Text(LocalizedStringKey(option.title)).tag(option) }
                                    }.labelsHidden().frame(width: 145)
                                    if filter.comparison.requiresValue {
                                        OsmSuggestedField(title: "Tag Value", text: filterText(clause.id, filter.id, key: false), key: filter.key, isKey: false, provider: provider)
                                    }
                                }
                            }
                        }
                        Button { changeClause(clause.id) { $0.filters.append(.init()) } } label: { Label("Add Filter", systemImage: "plus") }
                    }.padding(3)
                }
            }
            Button { draft.editBuilder { $0.clauses.append(.init()) } } label: { Label("Add Clause", systemImage: "plus") }
        }
    }
    private var rawPage: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextEditor(text: Binding(get: { draft.rawQL }, set: { draft.editQL($0) }))
                .font(.system(.body, design: .monospaced)).frame(minHeight: 160).border(.separator)
                .autocorrectionDisabled()
                .accessibilityLabel("Paste or write Overpass QL")
            Text("{{bbox}} is replaced with the current map extent. Every query has to be bounded - include it, or an explicit (south,west,north,east) filter.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(8)
    }
    private func changeClause(_ id: UUID, _ edit: (inout OsmClause) -> Void) {
        draft.editBuilder { value in if let index = value.clauses.firstIndex(where: { $0.id == id }) { edit(&value.clauses[index]) } }
    }
    private func changeFilter(_ clauseID: UUID, _ filterID: UUID, _ edit: (inout OsmFilter) -> Void) {
        changeClause(clauseID) { value in if let index = value.filters.firstIndex(where: { $0.id == filterID }) { edit(&value.filters[index]) } }
    }
    private func filterText(_ clauseID: UUID, _ filterID: UUID, key: Bool) -> Binding<String> {
        Binding(get: {
            guard let filter = draft.clauses.first(where: { $0.id == clauseID })?.filters.first(where: { $0.id == filterID }) else { return "" }
            return key ? filter.key : filter.value
        }, set: { text in changeFilter(clauseID, filterID) { if key { $0.key = text } else { $0.value = text } } })
    }
}

private struct OsmSuggestedField: View {
    let title: String
    @Binding var text: String
    let key: String
    let isKey: Bool
    let provider: (any FeatureQueryProvider)?
    @State private var suggestions: [String] = []
    private var taskKey: String { (isKey ? "key" : "value") + "\n" + key + "\n" + text }
    var body: some View {
        TextField(LocalizedStringKey(title), text: $text).textFieldStyle(.roundedBorder)
            .textInputSuggestions {
                ForEach(suggestions, id: \.self) { suggestion in Text(suggestion).textInputCompletion(suggestion) }
            }
            .task(id: taskKey) {
            suggestions = []
            guard let provider, isKey || !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            let queryKey = taskKey
            do {
                try await Task.sleep(for: .milliseconds(300))
                let values = try await provider.suggest(key: key, value: text, isKey: isKey)
                guard !Task.isCancelled, taskKey == queryKey else { return }
                var seen = Set<String>(); suggestions = values.filter { seen.insert($0).inserted }
            } catch { /* Suggestions do not interrupt editing or change the query. */ }
        }
    }
}

private struct FeatureQueryMap: View {
    @ObservedObject var store: WorkspaceStore
    let mapID: UUID
    let layers: [QueryPreviewLayer]
    let initialExtent: ViewportRequest?
    @Binding var extent: ViewportRequest?
    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @GestureState private var drag: CGSize = .zero
    private var backgroundVectors: [MapVectorLayer] { store.mapLayers.filter { !store.mapState(for: mapID).hiddenLayers.contains($0.id) } }
    private var backgroundRasters: [MapRasterLayer] { store.rasterLayers.filter { !store.mapState(for: mapID).hiddenLayers.contains($0.id) } }
    private var points: [MapPoint] {
        if let initialExtent { return [initialExtent.lowerLeft, initialExtent.upperRight] }
        return backgroundVectors.flatMap(\.points) + backgroundRasters.flatMap(\.points) + layers.flatMap { $0.layer.points }
    }
    var body: some View {
        GeometryReader { proxy in
            let currentOffset = CGSize(width: offset.width + drag.width, height: offset.height + drag.height)
            let transform = MapTransform(points: points, size: proxy.size, scale: scale, offset: currentOffset)
            ZStack {
                Color(nsColor: .textBackgroundColor)
                RasterCanvas(layers: backgroundRasters, points: points, scale: scale, offset: currentOffset, revision: store.rasterRevision)
                Canvas { drawing, _ in
                    for (index, layer) in backgroundVectors.enumerated() {
                        for feature in layer.features { drawing.stroke(transform.path(feature), with: .color(VectorStyle.color(index).opacity(0.4)), lineWidth: 1) }
                    }
                    for layer in layers {
                        for feature in layer.layer.features {
                            let path = transform.path(feature)
                            if feature.kind == .polygon || feature.kind == .point { drawing.fill(path, with: .color(EditorColor.decode(layer.fillColor)), style: FillStyle(eoFill: true)) }
                            drawing.stroke(path, with: .color(EditorColor.decode(layer.lineColor)), lineWidth: layer.lineWidth)
                        }
                    }
                }
            }.contentShape(Rectangle())
                .gesture(DragGesture().updating($drag) { value, state, _ in state = value.translation }.onEnded { value in
                    offset.width += value.translation.width; offset.height += value.translation.height
                })
                .simultaneousGesture(MagnifyGesture().onEnded { value in scale = min(1e6, max(1e-6, scale * value.magnification)) })
                .overlay(alignment: .topTrailing) {
                    HStack(spacing: 12) {
                        Button { scale = min(1e6, scale * 1.3) } label: { Image(systemName: "plus.magnifyingglass") }.help("Zoom In")
                        Button { scale = max(1e-6, scale / 1.3) } label: { Image(systemName: "minus.magnifyingglass") }.help("Zoom Out")
                        Button { scale = 1; offset = .zero } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }.help("Zoom to Full Extent")
                    }.buttonStyle(.borderless).padding(10).workspaceGlass().padding(12)
                }
                .onAppear { updateExtent(transform) }
                .onChange(of: scale) { _, _ in updateExtent(transform) }
                .onChange(of: offset) { _, _ in updateExtent(transform) }
                .onChange(of: proxy.size) { _, _ in updateExtent(transform) }
                .onChange(of: points) { _, _ in updateExtent(transform) }
        }
    }
    private func updateExtent(_ transform: MapTransform) {
        guard !points.isEmpty else { extent = nil; return }
        extent = .init(lowerLeft: transform.world(.init(x: 0, y: transform.size.height)), upperRight: transform.world(.init(x: transform.size.width, y: 0)))
    }
}
