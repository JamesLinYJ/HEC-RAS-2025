import Charts
import SwiftUI
import RASWorkspaceCore

// Native ResultCatalogSummary / DetailedResultHeader presentation. Model values
// remain in the editor draft and follow the workspace's existing Save boundary.
struct ResultSummaryPage: View {
    @ObservedObject var session: ModelEditorSession
    @ObservedObject var store: WorkspaceStore
    @StateObject private var resultPlanContext: ResultPlanContextSession
    @StateObject private var planAssociations: PlanResultAssociationSession
    @State private var linkedResultSelection: LinkedResultSelection?
    let onLinkedResultSelection: (@MainActor (LinkedResultSelection) -> Void)?

    init(session: ModelEditorSession, store: WorkspaceStore,
         onLinkedResultSelection: (@MainActor (LinkedResultSelection) -> Void)? = nil) {
        self.session = session
        self.store = store
        self.onLinkedResultSelection = onLinkedResultSelection
        let backend = session.provider as? BackendModelProvider
        _resultPlanContext = StateObject(wrappedValue: ResultPlanContextSession(
            provider: BackendResultPlanContextProvider(client: backend?.client)))
        _planAssociations = StateObject(wrappedValue: PlanResultAssociationSession(
            provider: BackendPlanResultAssociationProvider(client: backend?.client)))
    }

    private var page: ModelEditorPage {
        .form("Summary", "ResultCatalogSummary", "DetailedResultHeader")
    }
    private var asset: ProjectAsset? {
        store.assets.first { $0.id == session.modelAssetID }
    }
    private var projectXML: String? {
        guard let document = store.document else { return nil }
        return document.editorXML(overridingDescription: store.descriptionDraft)
    }
    private var sourceContextRevision: String {
        "\(store.projectSessionID):\(store.assetsRevision)"
    }
    private var inspectionIdentity: String {
        [asset?.url.standardizedFileURL.path ?? "", store.document?.url?.standardizedFileURL.path ?? "",
                sourceContextRevision, projectXML ?? ""].joined(separator: "\n")
    }

    var body: some View {
        VStack(spacing: 0) {
            if let asset {
                HStack(spacing: 10) {
                    Image(systemName: "chart.xyaxis.line").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(asset.name).font(.headline).textSelection(.enabled)
                        Text(asset.url.lastPathComponent).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Spacer()
                    if session.modified { Label("Unsaved changes", systemImage: "pencil.circle").font(.caption).foregroundStyle(.orange) }
                    if session.resultInspector?.snapshot?.needsMigration == true {
                        Label(L10n.text("Result needs migration to V1 format"), systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }.padding(16)
                if let inspector = session.resultInspector {
                    ResultInspectorActions(asset: asset, inspector: inspector, store: store)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 12)
                }
                Divider()
            }
            ScrollView {
                VStack(spacing: 12) {
                    SourceForm(page: page, session: session, store: store)
                        .frame(minHeight: 170, idealHeight: 230)
                    if let inspector = session.resultInspector {
                        ResultInspectorDetails(inspector: inspector, asset: asset, store: store,
                            planAssociations: planAssociations)
                            .padding(.horizontal, 12)
                    }
                    ResultPlanAssociationPanel(session: resultPlanContext,
                        onLinkedResultSelection: { selection in
                            linkedResultSelection = selection
                            onLinkedResultSelection?(selection)
                        })
                        .padding(.horizontal, 12)
                }
                .padding(.bottom, 12)
            }
        }
        .task(id: inspectionIdentity) {
            await session.resultInspector?.ensureLoaded(asset: asset,
                projectPath: store.document?.url, projectXML: projectXML,
                sourceContextRevision: sourceContextRevision)
            await planAssociations.ensureLoaded(asset: asset, projectPath: store.document?.url,
                projectXml: projectXML, inspectorSnapshot: session.resultInspector?.snapshot,
                projectRevision: store.document?.sourceRevision,
                sourceContextRevision: sourceContextRevision)
            await resultPlanContext.ensureLoaded(asset: asset, projectPath: store.document?.url,
                projectXml: projectXML, inspectorSnapshot: session.resultInspector?.snapshot,
                sourceContextRevision: sourceContextRevision)
        }
        .onChange(of: inspectionIdentity) { _, _ in
            linkedResultSelection = nil
            planAssociations.invalidate()
        }
        .sheet(isPresented: Binding(
            get: { linkedResultSelection != nil },
            set: { if !$0 { linkedResultSelection = nil } }
        )) {
            if let linkedResultSelection, let projectXML,
               let backend = store.modelProvider as? BackendModelProvider {
                LinkedResultProfilesWorkspace(selection: linkedResultSelection,
                    projectXML: projectXML, projectContextID: sourceContextRevision,
                    client: backend.client)
            } else {
                VStack(spacing: 12) {
                    Label(L10n.text("Linked Result profiles are unavailable."), systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.secondary)
                    Button(L10n.text("Close")) { linkedResultSelection = nil }
                        .keyboardShortcut(.cancelAction)
                }
                .padding(24)
                .frame(minWidth: 340, minHeight: 150)
            }
        }
        .overlay(alignment: .bottom) {
            if let error = session.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.red).padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.regularMaterial)
            }
        }
    }
}

private struct ResultInspectorDetails: View {
    @ObservedObject var inspector: ResultInspectorSession
    let asset: ProjectAsset?
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var planAssociations: PlanResultAssociationSession

    private var snapshot: ResultInspectorSnapshot? { inspector.snapshot }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L10n.text("Result Source Details")).font(.headline)
                Spacer()
                Button { refresh() } label: { Label(L10n.text("Refresh"), systemImage: "arrow.clockwise") }
                    .disabled(inspector.isLoading || asset == nil)
            }
            if inspector.isLoading { ProgressView(L10n.text("Reading result source…")).controlSize(.small) }
            if let error = inspector.error {
                Label(L10n.text(error), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red).font(.caption)
            }
            if let snapshot {
                Form {
                    computeSummary(snapshot.computeSummary)
                    layerErrors(snapshot)
                    ResultPlanAssociationSection(session: planAssociations)
                    embeddedModels(snapshot)
                    outputBlocks(snapshot)
                }
                .formStyle(.grouped)
                .frame(minHeight: 180, idealHeight: 360)
            } else if !inspector.isLoading && inspector.error == nil {
                Text(L10n.text("No result source metadata is available."))
                    .foregroundStyle(.secondary).font(.caption)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func layerErrors(_ snapshot: ResultInspectorSnapshot) -> some View {
        if !snapshot.layerErrors.isEmpty {
            Section(L10n.text("Layer Errors")) {
                ResultLayerErrorIndicatorView(messages: snapshot.layerErrorPresentations, store: store)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder private func computeSummary(_ summary: ResultInspectorComputeSummary?) -> some View {
        Section(L10n.text("Compute Summary")) {
            if let summary {
                Label(L10n.text(summary.success ? "Completed Successfully" : "Failed"),
                      systemImage: summary.success ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    .foregroundStyle(summary.success ? .green : .red)
                metadata("Start Time", summary.startTime)
                metadata("End Time", summary.endTime)
                metadata("Total Duration", summary.totalDuration)
                metadata("Solver Initialization Duration", summary.solverInitDuration)
                metadata("Output Duration", summary.outputDuration)
                if !summary.success, let reason = summary.failureReason {
                    metadata("Failure Reason", reason)
                }
                if let solver = summary.solver { metadata("Solver", solver) }
                if let version = summary.softwareVersion { metadata("Software Version", version) }
                if let log = summary.computeLog, !log.isEmpty {
                    DisclosureGroup(L10n.text("Compute Log")) {
                        Text(log).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            } else {
                Text(L10n.text("No compute summary is stored in this result."))
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private func embeddedModels(_ snapshot: ResultInspectorSnapshot) -> some View {
        Section(L10n.text("Embedded Model Snapshots")) {
            if let plan = snapshot.plan {
                metadata("Plan", plan.name)
                if let description = plan.description { metadata("Description", description) }
                if let id = plan.shortID { metadata("Plan ID", id) }
                if let created = plan.dateCreated { metadata("Date Created", created) }
                if let modified = plan.dateLastModified { metadata("Date Last Modified", modified) }
            } else {
                metadata("Plan", "Unavailable")
            }
            if let geometry = snapshot.geometry {
                metadata("Geometry", geometry.name)
                if let description = geometry.description { metadata("Description", description) }
            }
            if let boundary = snapshot.boundaryCondition {
                metadata("Boundary Condition", boundary.name)
                if let description = boundary.description { metadata("Description", description) }
            }
            metadata("Embedded In Result", L10n.text("Yes"))
        }
    }

    @ViewBuilder private func outputBlocks(_ snapshot: ResultInspectorSnapshot) -> some View {
        Section(L10n.text("Output Blocks")) {
            if snapshot.outputBlocks.isEmpty {
                Text(L10n.text("No output blocks are available in this result."))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(snapshot.outputBlocks) { block in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(block.name).font(.body.weight(.medium))
                            Spacer()
                            Text(L10n.format("%d profiles", block.profileCount))
                                .foregroundStyle(.secondary)
                        }
                        if let first = block.times.first, let last = block.times.last {
                            Text(first == last ? first : L10n.format("%@ – %@", first, last))
                                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                    .padding(.vertical, 3)
                }
            }
        }
    }

    private func metadata(_ title: String, _ value: String) -> some View {
        LabeledContent(L10n.text(title), value: value).textSelection(.enabled)
    }

    private func refresh() {
        inspector.invalidate()
        planAssociations.invalidate()
        Task {
            guard let asset else { return }
            let xml = store.document?.editorXML(overridingDescription: store.descriptionDraft)
            let sourceRevision = "\(store.projectSessionID):\(store.assetsRevision)"
            await inspector.ensureLoaded(asset: asset, projectPath: store.document?.url, projectXML: xml,
                sourceContextRevision: sourceRevision)
            await planAssociations.ensureLoaded(asset: asset, projectPath: store.document?.url,
                projectXml: xml, inspectorSnapshot: inspector.snapshot,
                projectRevision: store.document?.sourceRevision,
                sourceContextRevision: sourceRevision)
        }
    }
}

/// Native selection row for the source ResultPicker control. Results and
/// identity values must come from the connected result collection; an empty
/// collection leaves the picker present and disabled.
struct ResultPickerControl: View {
    let results: [EditorChoice]
    @Binding var selection: String
    var isEnabled = true

    var body: some View {
        Picker(L10n.text("Result"), selection: $selection) {
            if results.isEmpty {
                Text(L10n.text("No Results Available")).tag("")
            }
            ForEach(results) { result in
                Text(result.titleIsUserData == true ? result.title : L10n.text(result.title))
                    .tag(result.id)
            }
            if !selection.isEmpty && !results.contains(where: { $0.id == selection }) {
                Text(L10n.text("Current Result Unavailable")).tag(selection)
            }
        }
        .disabled(!isEnabled || results.isEmpty)
    }
}

// ResultNodeDetails and MultiResultNodeDetails expose distinct source contexts.
// The tabs preserve that separation and use SourceForm so source-provided
// visibility, choices, read-only flags, and field enablement stay authoritative.
struct ResultMapEditorPage: View {
    @ObservedObject var session: ModelEditorSession
    @ObservedObject var store: WorkspaceStore
    @State private var selection = "single"

    private let singleResult = ModelEditorPage.form(
        "Result Map", "ResultNodeDetails", "RasMapResultPicker")

    var body: some View {
        VStack(spacing: 0) {
            Picker("Result Map Context", selection: $selection) {
                Text("Single Result").tag("single")
                Text("Multiple Results").tag("multiple")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(12)

            Divider()
            if selection == "single" {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        SourceForm(page: singleResult, session: session, store: store)
                            .frame(minHeight: 150, idealHeight: 230)
                        ResultTerrainAssociationEditor(session: session, store: store)
                    }
                    .padding(12)
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ResultMultiResultMapContextView(store: store, resultPath: session.modelAssetID)
                    }.padding(12)
                }
            }

            if let node = resultNode {
                Divider()
                ResultComputeStatusDetails(node: node, store: store, assetPath: node.assetID)
                ResultLayerPropertiesView(node: node).frame(maxHeight: 180)
            }
        }
    }

    private var resultNode: LayerTreeNode? {
        guard let node = store.layerTreeSession.selectedNode,
              ["ResultNodeVM", "MultiResultNodeVM", "ResultNode", "MultiResultNode", "ObservableResult"].contains(node.sourceClass)
        else { return nil }
        return node
    }
}

/// ResultTerrainAssociation's one source editable field is a project XML
/// override. The picker writes only WorkspaceStore's association draft; it never
/// mutates the embedded Result HDF or substitutes a current project model.
private struct ResultTerrainAssociationEditor: View {
    @ObservedObject var session: ModelEditorSession
    @ObservedObject var store: WorkspaceStore

    private let group = "ResultAssociations"
    private let field = "OverrideTerrain"

    private var asset: ProjectAsset? { store.assets.first { $0.id == session.modelAssetID } }
    private var row: ProjectAssociation? {
        guard let asset else { return nil }
        return store.document?.associationRows(group: group).first { $0.name == asset.name }
    }
    private var selection: String { row?.fields[field] ?? "" }
    private var currentInspection: ResultInspectorSnapshot? { session.resultInspector?.snapshot }
    private var terrainChoices: [String] { currentInspection?.terrainChoices ?? [] }

    var body: some View {
        GroupBox(L10n.text("Result Terrain Association")) {
            VStack(alignment: .leading, spacing: 10) {
                Picker(L10n.text("Override Terrain"), selection: Binding(get: { selection }, set: setTerrain)) {
                    Text(L10n.text("(No Association)")).tag("")
                    ForEach(terrainChoices, id: \.self) { terrain in Text(terrain).tag(terrain) }
                    if !selection.isEmpty && !terrainChoices.contains(selection) {
                        Text(selection).tag(selection)
                    }
                }
                .disabled(row == nil || (terrainChoices.isEmpty && selection.isEmpty)
                    || store.isSavingAll || store.isClosingTab)

                if selection.isEmpty {
                    if let associated = currentInspection?.associatedTerrainName,
                       currentInspection?.showAutoDetectedTerrain == true {
                        LabeledContent(L10n.text("Auto Detected Terrain"), value: associated)
                    } else if currentInspection?.showAutoDetectedTerrain == true {
                        LabeledContent(L10n.text("Auto Detected Terrain"), value: L10n.text("(none)"))
                    }
                    if let exact = currentInspection?.exactTerrainName {
                        LabeledContent(L10n.text("Exact Terrain Match"), value: exact)
                    }
                }
                if store.hasUnsavedChanges {
                    Label(L10n.text("Terrain override is an unsaved project association."), systemImage: "pencil.circle")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func setTerrain(_ value: String) {
        guard let row, !store.isSavingAll, !store.isClosingTab else { return }
        store.setAssociation(row, field: field, value: value)
    }
}

// ResultsSectionLayerProperties is populated by the original tree provider.
// Show only those returned properties; this view never infers raster values or
// claims that a map was computed.
struct ResultLayerPropertiesView: View {
    let node: LayerTreeNode

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: node.symbol).foregroundStyle(.secondary)
                    Text(node.localizeName ? L10n.text(node.name) : node.name).font(.headline).textSelection(.enabled)
                    Spacer()
                    Text(node.sourceClass).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if node.properties.isEmpty {
                    Text("No result properties are available from the source context.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                        ForEach(node.properties) { property in
                            GridRow {
                                Text(LocalizedStringKey(property.label)).foregroundStyle(.secondary)
                                Text(property.value).textSelection(.enabled)
                            }
                        }
                    }
                }
            }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// DynamicTimeSeriesProfilePlot and DynamicProfilePlot consume actual samples
// supplied by the model adapter. When samples are absent, keep the source chart
// frame, axes, legend, selection controls, and source-bound options visible.
struct ResultSeriesPage: View {
    let page: ModelEditorPage
    @ObservedObject var session: ModelEditorSession
    @ObservedObject var store: WorkspaceStore

    var body: some View {
        VStack(spacing: 0) {
            // The source slider stays in the map workspace and becomes
            // inactive when the active context has no profile provider. Keep
            // the same live timeline available from a result profile page;
            // ProfileTimeline disables selection and explains an empty source.
            if page.title == "Profiles" {
                ProfileTimeline(mapState: store.activeMapState)
            }
            if hasUsableSamples {
                TimeSeriesPage(page: page, session: session, store: store)
            } else {
                ResultSeriesEmptyPage(page: page, session: session, store: store)
            }
        }
    }

    private var hasUsableSamples: Bool {
        session.samples[page.id]?.contains { $0.x.isFinite && $0.y.isFinite } == true
    }
}

/// Loads source Result identity itself so the profile route works without first
/// opening Summary. Profile values remain read-only samples from Result HDF.
struct ResultProfileEditorPage: View {
    @ObservedObject var session: ModelEditorSession
    @ObservedObject var store: WorkspaceStore
    @StateObject private var profileSession: ResultProfileSession
    @StateObject private var resultPlanContext: ResultPlanContextSession
    @State private var linkedResultSelection: LinkedResultSelection?
    let onLinkedResultSelection: (@MainActor (LinkedResultSelection) -> Void)?

    init(session: ModelEditorSession, store: WorkspaceStore,
         onLinkedResultSelection: (@MainActor (LinkedResultSelection) -> Void)? = nil) {
        self.session = session
        self.store = store
        self.onLinkedResultSelection = onLinkedResultSelection
        let provider: any ResultProfileProvider
        if let backend = session.provider as? BackendModelProvider {
            provider = BackendResultProfileProvider(client: backend.client)
        } else {
            provider = BackendResultProfileProvider()
        }
        _profileSession = StateObject(wrappedValue: ResultProfileSession(provider: provider))
        let backend = session.provider as? BackendModelProvider
        _resultPlanContext = StateObject(wrappedValue: ResultPlanContextSession(
            provider: BackendResultPlanContextProvider(client: backend?.client)))
    }

    private var asset: ProjectAsset? {
        store.assets.first { $0.id == session.modelAssetID }
    }
    private var projectXML: String? {
        guard let document = store.document else { return nil }
        return document.editorXML(overridingDescription: store.descriptionDraft)
    }
    private var sourceContextRevision: String {
        "\(store.projectSessionID):\(store.assetsRevision)"
    }
    private var inspectorIdentity: String {
        [asset?.url.standardizedFileURL.path ?? "", store.document?.url?.standardizedFileURL.path ?? "",
         sourceContextRevision, projectXML ?? ""].joined(separator: "\n")
    }
    private var profileIdentity: ResultProfileIdentity? {
        session.resultInspector?.snapshot.map {
            ResultProfileIdentity(resultPath: $0.resultPath, revision: $0.revision)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ResultPlanAssociationPanel(session: resultPlanContext,
                onLinkedResultSelection: { selection in
                    linkedResultSelection = selection
                    onLinkedResultSelection?(selection)
                }, isCompact: true)
            Divider()
            ResultProfilePanel(identity: profileIdentity,
                projectPath: store.document?.url?.standardizedFileURL.path,
                projectXML: projectXML, projectContextID: sourceContextRevision, session: profileSession)
        }
            .task(id: inspectorIdentity) {
                await session.resultInspector?.ensureLoaded(asset: asset,
                    projectPath: store.document?.url, projectXML: projectXML,
                    sourceContextRevision: sourceContextRevision)
                await resultPlanContext.ensureLoaded(asset: asset, projectPath: store.document?.url,
                    projectXml: projectXML, inspectorSnapshot: session.resultInspector?.snapshot,
                    sourceContextRevision: sourceContextRevision)
            }
            .onChange(of: inspectorIdentity) { _, _ in linkedResultSelection = nil }
            .overlay(alignment: .top) {
                if let inspector = session.resultInspector, inspector.isLoading {
                    ProgressView(L10n.text("Reading result source…"))
                        .controlSize(.small).padding(8).background(.regularMaterial, in: Capsule())
                        .padding(.top, 6)
                } else if let error = session.resultInspector?.error {
                    Label(L10n.text(error), systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.red).padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading).background(.regularMaterial)
                }
            }
            .sheet(isPresented: Binding(
                get: { linkedResultSelection != nil },
                set: { if !$0 { linkedResultSelection = nil } }
            )) {
                if let linkedResultSelection, let projectXML,
                   let backend = store.modelProvider as? BackendModelProvider {
                    LinkedResultProfilesWorkspace(selection: linkedResultSelection,
                        projectXML: projectXML, projectContextID: sourceContextRevision,
                        client: backend.client)
                } else {
                    VStack(spacing: 12) {
                        Label(L10n.text("Linked Result profiles are unavailable."), systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.secondary)
                        Button(L10n.text("Close")) { linkedResultSelection = nil }
                            .keyboardShortcut(.cancelAction)
                    }
                    .padding(24)
                    .frame(minWidth: 340, minHeight: 150)
                }
            }
    }
}

private struct ResultSeriesEmptyPage: View {
    let page: ModelEditorPage
    @ObservedObject var session: ModelEditorSession
    @ObservedObject var store: WorkspaceStore
    @State private var mode = "Chart"
    @State private var datasetID = ""
    @State private var showLegend = true
    @State private var showXAxis = true
    @State private var showYAxis = true
    @State private var showAxisTitles = true
    @State private var showProperties = true

    private var presentation: SeriesEditorPresentation { session.seriesPresentations[page.id] ?? .init() }
    private var chart: SeriesChartPresentation? { presentation.chart }
    private var hasProperties: Bool { page.schemaIDs.contains { SourceEditorLibrary.shared.schema($0) != nil } }
    private var xAxis: PlotAxisPresentation? { chart?.axes.first { $0.direction == .x } }
    private var yAxis: PlotAxisPresentation? { chart?.axes.first { $0.direction == .y } }
    private var xTitle: String {
        if let xAxis { return xAxis.displayTitle }
        if page.title == "Time Series" { return L10n.text("Time") }
        return L10n.text("X Axis")
    }
    private var yTitle: String {
        if let yAxis { return yAxis.displayTitle }
        return L10n.text("Y Axis")
    }
    private var datasetChoices: [PlotDatasetPresentation] { chart?.datasets ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            controls
            if let chart {
                ResultChartActions(pageID: page.id, presentation: chart, session: session, store: store)
            }
            if mode == "Chart" { chartCanvas }
            else { emptyTable }
            if hasProperties {
                Divider()
                DisclosureGroup("Series Properties", isExpanded: $showProperties) {
                    SourceForm(page: page, session: session, store: store)
                        .frame(minHeight: 100, idealHeight: 160, maxHeight: 230)
                }.padding(12)
            }
        }
        .onAppear {
            showLegend = chart?.showLegend ?? true
            showXAxis = chart?.showXAxis ?? true
            showYAxis = chart?.showYAxis ?? true
            showAxisTitles = chart?.showTitles ?? true
        }
        .onChange(of: datasetChoices.map(\.id)) { _, ids in
            if !ids.contains(datasetID) { datasetID = "" }
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Picker("View", selection: $mode) {
                Text("Chart").tag("Chart")
                Text("Table").tag("Table")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 170)

            Picker("Dataset", selection: $datasetID) {
                Text("All Series").tag("")
                ForEach(datasetChoices) { dataset in
                    Text(dataset.displayName).tag(dataset.id)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 230)
            .disabled(datasetChoices.isEmpty)

            if mode == "Chart" {
                Menu {
                    Toggle("Legend", isOn: $showLegend)
                    Toggle("X Axis", isOn: $showXAxis)
                    Toggle("Y Axis", isOn: $showYAxis)
                    Toggle("Axis Titles", isOn: $showAxisTitles)
                } label: {
                    Label("Chart Options", systemImage: "slider.horizontal.3")
                }
            }
            Spacer(minLength: 0)
            Text("No Result Samples Available")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
    }

    private var chartCanvas: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showLegend {
                HStack(spacing: 12) {
                    if datasetChoices.isEmpty {
                        Label("Legend", systemImage: "line.3.horizontal")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(datasetChoices.filter { datasetID.isEmpty || $0.id == datasetID }) { dataset in
                            HStack(spacing: 5) {
                                Circle().fill(dataset.colorRGBA.map(EditorColor.decode) ?? .secondary).frame(width: 8, height: 8)
                                Text(dataset.displayName).lineLimit(1)
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
                .font(.caption)
            }

            Chart {
                ForEach([ChartSample]()) { sample in
                    LineMark(
                        x: .value(xTitle, sample.x),
                        y: .value(yTitle, sample.y),
                        series: .value(L10n.text("Series"), sample.series)
                    )
                    .foregroundStyle(by: .value(L10n.text("Series"), sample.series))
                }
            }
                .chartXAxis(showXAxis ? .visible : .hidden)
                .chartYAxis(showYAxis ? .visible : .hidden)
                .chartXAxisLabel(showAxisTitles ? xTitle : "")
                .chartYAxisLabel(showAxisTitles ? yTitle : "")
                .overlay {
                    Label("The model adapter has not supplied result samples for this page.", systemImage: "chart.xyaxis.line")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding()
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                }
                .frame(minHeight: 260)
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var emptyTable: some View {
        Table(session.samples[page.id] ?? []) {
            TableColumn(xTitle) { sample in
                Text(sample.x.isFinite ? sample.x.formatted() : "—")
            }
            TableColumn(yTitle) { sample in
                Text(sample.y.isFinite ? sample.y.formatted() : "—")
            }
            TableColumn(L10n.text("Series"), value: \.series)
        }
        .overlay {
            if session.samples[page.id]?.isEmpty != false {
                Text("No result rows are available.").foregroundStyle(.secondary)
            }
        }
    }
}

// Single result, multiple-result, chart, and profile pages share one entry
// point for the parent editor router to install after the source snapshot loads.
struct ResultEditorPageContent: View {
    let page: ModelEditorPage
    @ObservedObject var session: ModelEditorSession
    @ObservedObject var store: WorkspaceStore

    var body: some View {
        switch page.title {
        case "Summary": ResultSummaryPage(session: session, store: store)
        case "Result Maps": ResultMapEditorPage(session: session, store: store)
        case "Time Series", "Profiles": ResultProfileEditorPage(session: session, store: store)
        case "Raster Calculator": RasterCalculatorEntry(store: store)
        default: SourceForm(page: page, session: session, store: store)
        }
    }
}
