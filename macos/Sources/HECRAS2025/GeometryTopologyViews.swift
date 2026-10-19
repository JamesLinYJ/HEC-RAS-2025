import Charts
import SwiftUI

/// GeometryEditor routes Topology Summary separately from its Arcs, Regions,
/// and Nodes pages. The parent router owns those routes; this view supplies
/// the source-backed summary and its native navigation affordances.
struct GeometryTopologySummaryWorkspacePage: View {
    @ObservedObject var session: ModelEditorSession
    @ObservedObject var topology: GeometryTopologySession
    @ObservedObject var store: WorkspaceStore
    let navigate: (String) -> Void
    @State private var activeTool: GeometryTopologyToolPanel?

    private var buildResult: TopologyBuildResultPresentation? { topology.buildResultPresentation }

    private var topologyFields: [SourceEditorField] {
        SourceEditorLibrary.shared.schema("TopologyProperties")?.fields ?? []
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Topology", systemImage: "point.3.connected.trianglepath.dotted").font(.headline)
                Spacer()
                if topology.isLoading || topology.isEditing {
                    ProgressView().controlSize(.small)
                }
                Button(L10n.text("Undo Topology Edit"), systemImage: "arrow.uturn.backward") {
                    Task { await topology.undo() }
                }
                .disabled(!topology.canUndo)
                Button(L10n.text("Redo Topology Edit"), systemImage: "arrow.uturn.forward") {
                    Task { await topology.redo() }
                }
                .disabled(!topology.canRedo)
                Button("Arcs") { navigate("Arcs") }
                Button("Regions") { navigate("Regions") }
                Button("Nodes") { navigate("Nodes") }
                GeometryTopologyToolsMenu(selection: $activeTool, availableTools: [.factor])
            }
            .padding(12)

            if let error = topology.error {
                Label(L10n.text(error), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
            }

            Divider()

            if session.loadingSelection {
                ProgressView("Loading properties…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if activeTool == .factor {
                            GeometryTopologyFactorToolView(session: topology)
                        }
                        Form {
                            Section("Topology Properties") {
                                ForEach(topologyFields) { field in
                                    if session.fields[field.storageID] != nil {
                                        SourceField(field: field, session: session, store: store)
                                    } else {
                                        LabeledContent(field.title) {
                                            Label("Not supplied by the source model", systemImage: "minus.circle")
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                        }
                        .formStyle(.grouped)
                        .frame(minHeight: 130)

                        TopologyBuildResultViewerWorkspaceView(result: buildResult, store: store,
                            onSelectedMessage: { topology.selectDiagnosticMessage($0) },
                            canOpenTarget: { topology.canOpenDiagnosticTarget($0) },
                            onOpenTarget: { target in
                                if let page = topology.openDiagnosticTarget(target) { navigate(page) }
                            })
                    }
                    .padding(16)
                }
            }
        }
        .onAppear(perform: routePendingToolRequest)
        .onChange(of: store.editorToolPresentationRequest?.id) { _, _ in routePendingToolRequest() }
        .onChange(of: topology.snapshot?.revision) { _, _ in routePendingToolRequest() }
    }

    private func routePendingToolRequest() {
        guard let request = store.editorToolPresentationRequest,
              store.primaryEditorSession(.geometry).id == session.id,
              request.projectSessionID == store.projectSessionID,
              request.assetID == session.modelAssetID,
              request.featureKind == nil,
              request.action == .topology,
              topology.snapshot != nil else { return }
        activeTool = .factor
        store.consumeEditorToolPresentationRequest(request.id)
    }
}

/// OperationResultControl presents a success/failure header and a severity
/// sorted message list. A missing adapter result keeps that same structure
/// visible, with an explicit state instead of invented messages.
struct TopologyBuildResultViewerWorkspaceView: View {
    let result: TopologyBuildResultPresentation?
    @ObservedObject var store: WorkspaceStore
    var onSelectedMessage: (String?) -> Void = { _ in }
    var canOpenTarget: (GeometryTopologyDiagnosticTarget) -> Bool = { _ in false }
    var onOpenTarget: (GeometryTopologyDiagnosticTarget) -> Void = { _ in }
    @State private var selectedMessageID: String?
    @State private var sortBySeverity = true
    @State private var useSeverityBackground = true

    private var messages: [TopologyBuildMessagePresentation] {
        guard let sourceMessages = result?.messages else { return [] }
        guard sortBySeverity else { return sourceMessages }
        return sourceMessages.sorted {
            if $0.severity.rank == $1.severity.rank { return $0.id < $1.id }
            return $0.severity.rank > $1.severity.rank
        }
    }

    private var selectedMessage: TopologyBuildMessagePresentation? {
        messages.first { $0.id == selectedMessageID }
    }

    private var diagnosticText: String {
        messages.map { message in
            let header = "[\(message.sourceSeverity ?? message.severity.title)] \(message.code): \(message.text)"
            let regionSeverity = message.regionCompletionSeverity.map { ["RegionCompletionSeverity: \($0)"] } ?? []
            let context = message.context.map { value in
                "\(value.key) [\(value.valueType)]: \(value.value)\(value.integerValue.map { " (Int32: \($0))" } ?? "")"
            }
            let targets = message.targets.map { target in
                "Target \(target.featureKind) FID \(target.fid), row \(target.tableRowID), map \(target.mapFeatureIDs.joined(separator: ","))"
            }
            return ([header] + regionSeverity + context + targets).joined(separator: "\n")
        }.joined(separator: "\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                statusLabel
                Spacer()
                Label {
                    Text(messages.count.formatted()).monospacedDigit()
                } icon: {
                    Image(systemName: "text.bubble")
                }
                .accessibilityLabel(Text("Build messages"))
                .foregroundStyle(.secondary)
                Button("Copy Messages", systemImage: "doc.on.doc") {
                    store.system.copy(diagnosticText)
                }
                .disabled(messages.isEmpty)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            HStack(spacing: 16) {
                Toggle("Sort by severity", isOn: $sortBySeverity)
                Toggle("Severity backgrounds", isOn: $useSeverityBackground)
                Spacer()
                Text("Build messages")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .toggleStyle(.checkbox)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Table(messages, selection: $selectedMessageID) {
                TableColumn(L10n.text("Severity")) { message in
                    Label(L10n.text(message.sourceSeverity ?? message.severity.title), systemImage: message.severity.symbol)
                        .foregroundStyle(message.severity.color)
                        .padding(.vertical, 3)
                        .padding(.horizontal, 5)
                        .background(useSeverityBackground ? message.severity.color.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 5))
                }
                .width(min: 110, ideal: 140)
                TableColumn(L10n.text("Code")) { message in
                    Text(message.code.isEmpty ? "—" : message.code)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                }
                .width(min: 130, ideal: 180)
                TableColumn(L10n.text("Message")) { message in
                    Text(message.text).lineLimit(2).textSelection(.enabled)
                }
            }
            .frame(minHeight: 150, idealHeight: 210)
            .overlay {
                if messages.isEmpty {
                    VStack(spacing: 7) {
                        Image(systemName: result == nil ? "checkmark.circle.dashed" : "text.bubble")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                        Text(result == nil ? L10n.text("Topology completion result unavailable") : L10n.text("No build messages"))
                            .font(.headline)
                        Text(result == nil
                             ? L10n.text("The current geometry did not return a completion result.")
                             : L10n.text("The source result contains no messages."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(16)
                    .frame(maxWidth: 360)
                    .allowsHitTesting(false)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Message Details").font(.subheadline.weight(.semibold))
                    Spacer()
                    if let selectedMessage {
                        Text(selectedMessage.code).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                }
                if let selectedMessage {
                    Text(selectedMessage.text).textSelection(.enabled)
                    if let sourceSeverity = selectedMessage.sourceSeverity {
                        LabeledContent(L10n.text("Source Severity"), value: L10n.text(sourceSeverity))
                    }
                    if let regionSeverity = selectedMessage.regionCompletionSeverity {
                        LabeledContent(L10n.text("Region Completion Severity"), value: L10n.text(regionSeverity))
                    }
                    if !selectedMessage.context.isEmpty {
                        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
                            ForEach(Array(selectedMessage.context.enumerated()), id: \.offset) { entry in
                                GridRow {
                                    Text(entry.element.key).foregroundStyle(.secondary)
                                    Text(entry.element.value).textSelection(.enabled)
                                    Text(entry.element.valueType).foregroundStyle(.tertiary).textSelection(.enabled)
                                }
                            }
                        }
                        .font(.caption)
                    }
                    if !selectedMessage.targets.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(L10n.text("Affected Features")).font(.caption.weight(.semibold))
                            ForEach(Array(selectedMessage.targets.enumerated()), id: \.offset) { entry in
                                let target = entry.element
                                Button {
                                    onOpenTarget(target)
                                } label: {
                                    Label(L10n.format("Open %@ %d", L10n.text(target.typeLabel), target.fid),
                                          systemImage: "scope")
                                }
                                .buttonStyle(.link)
                                .disabled(!canOpenTarget(target))
                            }
                        }
                    }
                } else if result == nil {
                    Text("Select a build message when source results are available.")
                        .foregroundStyle(.secondary)
                } else {
                    Text("Select a message to view its details.")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: 72, alignment: .topLeading)
        }
        .background(.background, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary))
        .onChange(of: result?.draftIdentity) { _, _ in
            selectedMessageID = nil
            onSelectedMessage(nil)
        }
        .onChange(of: selectedMessageID) { _, id in onSelectedMessage(id) }
    }

    @ViewBuilder private var statusLabel: some View {
        if let result {
            Label(result.succeeded ? L10n.text("Topology build succeeded") : L10n.text("Topology build failed"),
                  systemImage: result.succeeded ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(result.succeeded ? .green : .red)
                .font(.headline)
        } else {
            Label(L10n.text("Topology completion result unavailable"), systemImage: "minus.circle")
                .foregroundStyle(.secondary)
                .font(.headline)
        }
    }
}

struct TopologyBuildResultPresentation: Sendable {
    let sourceRevision: String
    let draftIdentity: String
    let succeeded: Bool
    let messages: [TopologyBuildMessagePresentation]
}

struct TopologyBuildMessagePresentation: Identifiable, Sendable {
    let id: String
    let severity: TopologyMessageSeverity
    let code: String
    let text: String
    var timestamp: String? = nil
    var context: [TopologyBuildContextValue] = []
    var sourceSeverity: String? = nil
    var regionCompletionSeverity: String? = nil
    var targets: [GeometryTopologyDiagnosticTarget] = []
}

struct TopologyBuildContextValue: Identifiable, Sendable {
    let id: String
    let key: String
    let value: String
    var valueType: String
    var integerValue: Int?

    init(id: String? = nil, key: String, value: String, valueType: String = "", integerValue: Int? = nil) {
        self.id = id ?? key
        self.key = key
        self.value = value
        self.valueType = valueType
        self.integerValue = integerValue
    }
}

enum TopologyMessageSeverity: String, Sendable {
    case trace, debug, information, warning, error

    var rank: Int {
        switch self {
        case .trace: 0
        case .debug: 1
        case .information: 2
        case .warning: 3
        case .error: 4
        }
    }

    var title: String {
        switch self {
        case .trace: "Trace"
        case .debug: "Debug"
        case .information: "Information"
        case .warning: "Warning"
        case .error: "Error"
        }
    }

    var symbol: String {
        switch self {
        case .trace, .debug: "ellipsis.bubble"
        case .information: "info.circle"
        case .warning: "exclamationmark.triangle"
        case .error: "xmark.octagon"
        }
    }

    var color: Color {
        switch self {
        case .trace, .debug: .secondary
        case .information: .blue
        case .warning: .orange
        case .error: .red
        }
    }
}

/// DynamicProfilePlot follows the selected saved map and samples the actual
/// source lines of the current topology or culvert draft.
struct GeometryDynamicProfilePlotView: View {
    let samples: [ChartSample]
    let chartPresentation: SeriesChartPresentation?
    let selectedFeatureIDs: Set<String>
    var selectedFeatureLabel = "features"
    let mapTypeFieldID: String?
    @ObservedObject var session: ModelEditorSession
    @ObservedObject var store: WorkspaceStore
    var lineSourceKind: GeometryDynamicProfileKind = .arcs
    @State private var selectedMapID: UUID?

    private var mapID: UUID { selectedMapID ?? store.lastActiveMapID }
    private var lines: [MapDynamicProfileLine] {
        switch lineSourceKind {
        case .arcs:
            GeometryDynamicProfileLines.arcs(session.geometryTopology?.snapshot,
                selectedIDs: selectedFeatureIDs)
        case .barrels:
            GeometryDynamicProfileLines.barrels(session.geometryCulvert?.snapshot,
                selectedIDs: selectedFeatureIDs)
        }
    }
    private var linesToken: String {
        let revision: String
        switch lineSourceKind {
        case .arcs:
            revision = session.geometryTopologyIdentity + "|" + (session.geometryTopology?.snapshot?.draftState ?? "")
        case .barrels:
            revision = session.geometryCulvertIdentity + "|" + (session.geometryCulvert?.snapshot?.draftState ?? "")
        }
        return GeometryDynamicProfileLines.token(lines: lines, sourceIdentity: revision)
    }
    private var mapChoices: [GeometryDynamicProfileMapChoice] {
        store.catalogMapDocuments.compactMap { map in
            guard let id = UUID(uuidString: map.id), store.mapResultRequest(for: id) != nil else { return nil }
            return GeometryDynamicProfileMapChoice(id: id, name: map.name)
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker(L10n.text("Map"), selection: Binding(get: { mapID }, set: { selectedMapID = $0 })) {
                if !mapChoices.contains(where: { $0.id == mapID }) {
                    Text(L10n.text("Choose a saved map…")).tag(mapID)
                }
                ForEach(mapChoices, id: \.id) { map in Text(verbatim: map.name).tag(map.id) }
            }.pickerStyle(.menu).padding(.horizontal, 12).padding(.top, 8)
            if let client = store.runtimeInfoClient,
               mapChoices.contains(where: { $0.id == mapID }) {
                MapDynamicProfileWorkspace(store: store, mapState: store.mapState(for: mapID),
                    client: client, lines: lines, linesToken: linesToken)
                    .id(mapID)
            } else {
                ContentUnavailableView(L10n.text("Choose an active saved map to load its real profile sources."),
                    systemImage: "map")
            }
        }
        .onChange(of: store.projectSessionID) { _, _ in selectedMapID = nil }
    }
}

private struct GeometryDynamicProfileMapChoice: Identifiable {
    let id: UUID
    let name: String
}

private struct GeometryProfileChoice: Identifiable {
    let id: String
    let title: String
}

private struct GeometryProfilePlotEmptyCanvas: View {
    let xTitle: String
    let yTitle: String
    let note: String

    var body: some View {
        HStack(spacing: 8) {
            Text(yTitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(-90))
                .frame(width: 28)
            VStack(spacing: 6) {
                Canvas { context, size in
                    let plot = CGRect(x: 12, y: 8, width: max(0, size.width - 18), height: max(0, size.height - 18))
                    var grid = Path()
                    grid.move(to: CGPoint(x: plot.minX, y: plot.minY))
                    grid.addLine(to: CGPoint(x: plot.minX, y: plot.maxY))
                    grid.addLine(to: CGPoint(x: plot.maxX, y: plot.maxY))
                    for fraction in [0.25, 0.5, 0.75] {
                        let y = plot.minY + plot.height * fraction
                        grid.move(to: CGPoint(x: plot.minX, y: y))
                        grid.addLine(to: CGPoint(x: plot.maxX, y: y))
                    }
                    context.stroke(grid, with: .color(.secondary.opacity(0.28)), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
                }
                .overlay {
                    VStack(spacing: 7) {
                        Image(systemName: "chart.xyaxis.line").font(.title2).foregroundStyle(.secondary)
                        Text(note).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    .padding(12)
                    .frame(maxWidth: 340)
                }
                Text(xTitle).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }
}

private struct GeometryProfileLegendSwatch: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        return path
    }
}

/// GeometryTopologyArcsPage also shows the selected arcs' sampled profile
/// lines. The source adapter may provide profile values through the normal
/// chart sample contract; the view retains the axes and controls if it does not.
struct GeometryTopologyArcsWorkspacePage: View {
    @ObservedObject var session: ModelEditorSession
    @ObservedObject var store: WorkspaceStore
    @State private var detailTab = "Properties"
    @State private var quickEditPresented = false

    private let page = ModelEditorPage.table(
        "Arcs",
        "TopologyArcsEditor",
        "ConceptualMeshArcEditor",
        "ArcEditor",
        "TopologyArcQuickEditPicker"
    )

    private var selection: TableSelectionPresentation? {
        session.tablePresentations[page.id]?.selection
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Arcs", systemImage: "point.topleft.down.to.point.bottomright.curvepath").font(.headline)
                Spacer()
                if let count = session.rows[page.id]?.count {
                    Text(count.formatted()).foregroundStyle(.secondary).monospacedDigit()
                }
                Button("Quick Edit", systemImage: "slider.horizontal.3") {
                    quickEditPresented.toggle()
                }
                .disabled(selection?.rowIDs.isEmpty != false)
                .popover(isPresented: $quickEditPresented) {
                    GeometryTopologyQuickEditPopover(
                        schemaID: "TopologyArcQuickEditPicker",
                        objectLabel: "arcs",
                        featureIDs: selection?.rowIDs ?? [],
                        scope: selection?.detail?.scope ?? page.id,
                        session: session,
                        store: store
                    )
                }
                if let topology = session.geometryTopology {
                    ResultLayerErrorIndicatorView(messages: topology.diagnosticMessages(
                        featureKind: "arc", rowIDs: selection?.rowIDs ?? []), store: store)
                        .disabled(selection?.rowIDs.isEmpty != false)
                }
            }
            .padding(12)

            Divider()

            VSplitView {
                ModelTablePage(page: page, session: session, store: store, showsSelectionDetail: false)
                    .frame(minHeight: 180)

                TabView(selection: $detailTab) {
                    TableSelectionDetail(
                        page: page,
                        presentation: selection,
                        session: session,
                        store: store,
                        showsPatchSizing: false
                    )
                    .tabItem { Text("Properties") }
                    .tag("Properties")

                    GeometryDynamicProfilePlotView(
                        samples: session.samples[page.id] ?? [],
                        chartPresentation: session.seriesPresentations[page.id]?.chart,
                        selectedFeatureIDs: selection?.rowIDs ?? [],
                        selectedFeatureLabel: "arcs",
                        mapTypeFieldID: session.seriesPresentations[page.id]?.chart?.mapTypeFieldID,
                        session: session, store: store
                    )
                    .tabItem { Text("Sample Lines") }
                    .tag("Sample Lines")

                    GeometryFeatureMetadataWorkspaceView(
                        featureType: "Arcs",
                        featureIDs: selection?.rowIDs ?? [],
                        scope: selection?.detail?.scope,
                        session: session,
                        store: store
                    )
                    .tabItem { Text("Tags & Metadata") }
                    .tag("Tags & Metadata")
                }
                .frame(minHeight: 250)
            }
        }
        .onChange(of: session.modelAssetID) { _, _ in
            detailTab = "Properties"
            routePendingTagRequest()
        }
        .onAppear { routePendingTagRequest() }
        .onChange(of: store.editorToolPresentationRequest?.id) { _, _ in routePendingTagRequest() }
    }

    private func routePendingTagRequest() {
        guard store.primaryEditorSession(.geometry).id == session.id,
              let request = store.editorToolPresentationRequest,
              request.projectSessionID == store.projectSessionID,
              request.assetID == session.modelAssetID,
              request.featureKind == "arc",
              request.action == .tagCreate || request.action == .tagEdit else { return }
        detailTab = "Tags & Metadata"
    }
}

struct GeometryTopologyRegionsWorkspacePage: View {
    @ObservedObject var session: ModelEditorSession
    @ObservedObject var store: WorkspaceStore
    @State private var quickEditPresented = false

    private let page = ModelEditorPage.table("Regions", "TopologyRegionsEditor", "ConceptualMeshControlPointEditor", "TopologyRegionQuickEditPicker")
    private var selection: TableSelectionPresentation? { session.tablePresentations[page.id]?.selection }

    var body: some View {
        GeometryTopologyTableWorkspacePage(
            page: page,
            symbol: "square.3.layers.3d",
            selection: selection,
            quickEditPresented: $quickEditPresented,
            quickEditSchemaID: "TopologyRegionQuickEditPicker",
            session: session,
            store: store
        )
    }
}

struct GeometryTopologyNodesWorkspacePage: View {
    @ObservedObject var session: ModelEditorSession
    @ObservedObject var store: WorkspaceStore

    private let page = ModelEditorPage.table("Nodes", "TopologyNodesEditor")
    private var selection: TableSelectionPresentation? { session.tablePresentations[page.id]?.selection }

    var body: some View {
        GeometryTopologyTableWorkspacePage(
            page: page,
            symbol: "point.3.connected.trianglepath.dotted",
            selection: selection,
            quickEditPresented: .constant(false),
            quickEditSchemaID: nil,
            session: session,
            store: store
        )
    }
}

private struct GeometryTopologyTableWorkspacePage: View {
    let page: ModelEditorPage
    let symbol: String
    let selection: TableSelectionPresentation?
    @Binding var quickEditPresented: Bool
    let quickEditSchemaID: String?
    @ObservedObject var session: ModelEditorSession
    @ObservedObject var store: WorkspaceStore
    @State private var detailTab = "Properties"

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(LocalizedStringKey(page.title), systemImage: symbol).font(.headline)
                Spacer()
                if let count = session.rows[page.id]?.count {
                    Text(count.formatted()).foregroundStyle(.secondary).monospacedDigit()
                }
                if let quickEditSchemaID {
                    Button("Quick Edit", systemImage: "slider.horizontal.3") {
                        quickEditPresented.toggle()
                    }
                    .disabled(selection?.rowIDs.isEmpty != false)
                    .popover(isPresented: $quickEditPresented) {
                        GeometryTopologyQuickEditPopover(
                            schemaID: quickEditSchemaID,
                            objectLabel: "regions",
                            featureIDs: selection?.rowIDs ?? [],
                            scope: selection?.detail?.scope ?? page.id,
                            session: session,
                            store: store
                        )
                    }
                }
                if let topology = session.geometryTopology,
                   let diagnosticKind = (page.title == "Regions" ? "region" : page.title == "Nodes" ? "node" : nil) {
                    ResultLayerErrorIndicatorView(messages: topology.diagnosticMessages(
                        featureKind: diagnosticKind, rowIDs: selection?.rowIDs ?? []), store: store)
                        .disabled(selection?.rowIDs.isEmpty != false)
                }
            }
            .padding(12)
            Divider()
            VSplitView {
                ModelTablePage(page: page, session: session, store: store, showsSelectionDetail: false)
                    .frame(minHeight: 180)
                selectedDetail.frame(minHeight: 210)
            }
        }
        .onAppear { routePendingTagRequest() }
        .onChange(of: session.modelAssetID) { _, _ in routePendingTagRequest() }
        .onChange(of: store.editorToolPresentationRequest?.id) { _, _ in routePendingTagRequest() }
    }

    private func routePendingTagRequest() {
        guard page.title == "Regions",
              store.primaryEditorSession(.geometry).id == session.id,
              let request = store.editorToolPresentationRequest,
              request.projectSessionID == store.projectSessionID,
              request.assetID == session.modelAssetID,
              request.featureKind == "region",
              request.action == .tagCreate || request.action == .tagEdit else { return }
        detailTab = "Tags & Metadata"
    }

    @ViewBuilder private var selectedDetail: some View {
        if page.title == "Regions" {
            TabView(selection: $detailTab) {
                TableSelectionDetail(page: page, presentation: selection, session: session, store: store, showsPatchSizing: false)
                    .tabItem { Text("Properties") }
                    .tag("Properties")
                GeometryFeatureMetadataWorkspaceView(
                    featureType: "Regions",
                    featureIDs: selection?.rowIDs ?? [],
                    scope: selection?.detail?.scope,
                    session: session,
                    store: store
                )
                .tabItem { Text("Tags & Metadata") }
                .tag("Tags & Metadata")
            }
            .onChange(of: session.modelAssetID) { _, _ in detailTab = "Properties" }
        } else {
            TableSelectionDetail(page: page, presentation: selection, session: session, store: store, showsPatchSizing: false)
        }
    }
}

private struct GeometryTopologyQuickEditPopover: View {
    private struct ResetField: Identifiable {
        let propertyID: String
        let sourceField: SourceEditorField
        var id: String { propertyID }
    }

    let schemaID: String
    let objectLabel: String
    let featureIDs: Set<String>
    let scope: String
    @ObservedObject var session: ModelEditorSession
    @ObservedObject var store: WorkspaceStore

    private var sourceFields: [SourceEditorField] {
        SourceEditorLibrary.shared.schema(schemaID)?.fields ?? []
    }
    private var fieldsWithValues: [SourceEditorField] {
        sourceFields.map { $0.inScope(scope) }.filter { session.fields[$0.storageID] != nil }
    }
    private var resetFields: [ResetField] {
        guard !isArcPicker,
              let sourceFields = SourceEditorLibrary.shared.schema("ConceptualMeshControlPointEditor")?.fields else { return [] }
        let sourceIDs: [(property: String, field: String)] = [
            ("ConstantSize", "ConstantSizeString"),
            ("SecondaryConstantSize", "SecondaryConstantSizeString"),
            ("RotationDegrees", "RotationDegreesString"),
            ("BiasInternal", "BiasInternalString"),
            ("TinResolution", "TinResolutionString"),
            ("SizeTolerance", "SizeToleranceString")
        ]
        return sourceIDs.compactMap { item in
            guard let field = sourceFields.first(where: { $0.id == item.field }) else { return nil }
            return ResetField(propertyID: item.property, sourceField: field)
        }
    }
    private var isArcPicker: Bool { schemaID == "TopologyArcQuickEditPicker" }
    private var featureKind: String { isArcPicker ? "arc" : "region" }
    private var featureType: String { isArcPicker ? "Arcs" : "Regions" }
    private var topology: GeometryTopologySession? { session.geometryTopology }

    private var selectedTopologyRows: [GeometryTopologyFeatureRow] {
        guard let topology else { return [] }
        let table = topology.table(for: featureKind)
        let directRows = table.rows.filter { featureIDs.contains($0.id) }
        if directRows.count == featureIDs.count { return directRows }

        let modelRows = session.rows[featureType] ?? []
        let fids = Set(featureIDs.compactMap { selectedID -> Int? in
            guard let modelRow = modelRows.first(where: { $0.id == selectedID }),
                  let rawFID = modelRow.values["FID"] else { return nil }
            return Int(rawFID.trimmingCharacters(in: .whitespacesAndNewlines))
        })
        guard fids.count == featureIDs.count else { return [] }
        return table.rows.filter { fids.contains($0.fid) }
    }

    private var canResizeSelection: Bool {
        session.loaded && !session.isBusy && topology?.canMutateTopology == true
            && selectedTopologyRows.count == 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Quick Edit", systemImage: "slider.horizontal.3").font(.headline)
                Spacer()
                Text(objectLabel.localizedCapitalized).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)

            TabView {
                Form {
                    Section("Selection Properties") {
                        ForEach(sourceFields) { field in
                            let scoped = field.inScope(scope)
                            if session.fields[scoped.storageID] != nil {
                                SourceField(field: scoped, session: session, store: store)
                            } else {
                                LabeledContent(field.title) {
                                    Text("Not supplied by the source model").foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    regionResetSection
                    quickSizeSection
                }
                .tabItem { Text("Quick Edit") }

                GeometryFeatureMetadataWorkspaceView(
                    featureType: featureType,
                    featureIDs: featureIDs,
                    scope: scope,
                    session: session,
                    store: store
                )
                .tabItem { Text("Tags & Metadata") }
            }
            .frame(width: 430, height: 470)

            if fieldsWithValues.isEmpty {
                Text("The source adapter has not supplied quick-edit values for this selection.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
            }
            if let error = topology?.error {
                Label(L10n.text(error), systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
            }
        }
    }

    @ViewBuilder private var regionResetSection: some View {
        if !isArcPicker, selectedTopologyRows.count > 1 {
            Section("Properties") {
                ForEach(resetFields) { resetField in
                    let values = selectedTopologyRows.compactMap { $0.values[resetField.propertyID] }
                    if values.count == selectedTopologyRows.count {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(LocalizedStringKey(resetField.sourceField.title))
                                Text(resetValueSummary(values))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if sourceValuesDiffer(values) {
                                Button {
                                    Task {
                                        await topology?.resetRegionField(
                                            controlPointFIDs: selectedTopologyRows.map(\.fid),
                                            fieldID: resetField.propertyID
                                        )
                                    }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                }
                                .buttonStyle(.plain)
                                .help(L10n.text("Clear"))
                                .accessibilityLabel(Text(L10n.text("Clear")))
                                .disabled(topology?.canMutateTopology != true
                                    || selectedTopologyRows.count != featureIDs.count)
                            }
                        }
                    }
                }
            }
        }
    }

    private func sourceValuesDiffer(_ values: [String]) -> Bool {
        guard let firstText = values.first, let first = Float(firstText) else { return false }
        return values.dropFirst().contains { text in
            guard let value = Float(text) else { return true }
            return first != value && !(first.isNaN && value.isNaN)
        }
    }

    private func resetValueSummary(_ values: [String]) -> String {
        guard let first = values.first else { return "—" }
        if sourceValuesDiffer(values) { return L10n.text("(varies)") }
        if Float(first)?.isNaN == true { return "—" }
        return first
    }

    @ViewBuilder private var quickSizeSection: some View {
        Section("Cell Size") {
            if topology?.snapshot == nil {
                Label("Load the topology to resize the selected feature.", systemImage: "square.dashed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if selectedTopologyRows.count != 1 {
                Label("Select exactly one source feature to resize it.", systemImage: "cursorarrow.click")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let row = selectedTopologyRows.first, isArcPicker {
                let sizeFunction = row.values["SizeFunction"] ?? "Unset"
                HStack {
                    resizeButton("Half size", row: row, half: true)
                    resizeButton("Double size", row: row, half: false)
                }
                .disabled(!canResizeSelection || sizeFunction == "Unset")
                Text(sizeFunction == "Constant"
                    ? "Scales the selected arc's Constant Size."
                    : sizeFunction == "CountWithBias"
                        ? "Scales Point Count using the source integer ratio rule."
                        : "The source size function is Unset; its quick resize action has no effect.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let row = selectedTopologyRows.first {
                let patchType = row.values["PatchType"] ?? ""
                if patchType == "Quad" {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("North / South arcs")
                            Spacer()
                            resizeButton("Half", row: row, half: true, axis: "NorthSouth")
                            resizeButton("Double", row: row, half: false, axis: "NorthSouth")
                        }
                        HStack {
                            Text("East / West arcs")
                            Spacer()
                            resizeButton("Half", row: row, half: true, axis: "EastWest")
                            resizeButton("Double", row: row, half: false, axis: "EastWest")
                        }
                    }
                    .disabled(!canResizeSelection)
                    Text("Resizes the selected side's boundary arcs, following their Constant or Count size function.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if ["TrianglePaver", "Cartesian"].contains(patchType) {
                    HStack {
                        resizeButton("Half size", row: row, half: true)
                        resizeButton("Double size", row: row, half: false)
                    }
                    .disabled(!canResizeSelection)
                    Text("Scales both Constant Size and Secondary Constant Size.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("The source editor does not define a scalar quick-size action for this patch type.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func resizeButton(_ title: String, row: GeometryTopologyFeatureRow,
                              half: Bool, axis: String? = nil) -> some View {
        Button(title) {
            guard let topology else { return }
            Task { await topology.adjustSize(featureKind: featureKind, fid: row.fid, half: half, axis: axis) }
        }
    }
}
