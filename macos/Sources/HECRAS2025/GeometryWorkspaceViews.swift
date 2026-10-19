import Charts
import SwiftUI
import RASWorkspaceCore

/// GeometrySummaryPage and GeometryEditor share the selected geometry. The
/// page keeps its catalog, description/images, layer associations and prepare
/// summary visible together; the host owns the editor route.
struct GeometrySummaryWorkspacePage: View {
    @ObservedObject var session: ModelEditorSession
    @ObservedObject var store: WorkspaceStore
    let navigate: (String) -> Void
    let geometryChoices: [ProjectAsset]
    let selectGeometry: (String?) -> Void
    @State private var diagnosticsPresented = false

    private var catalogFields: [SourceEditorField] {
        // The catalog summary and GeometrySummaryPage both expose Description
        // for the same source Geometry object. Keep the editor-page binding as
        // the single editable control and retain the catalog metadata fields.
        SourceEditorLibrary.shared.schema("GeometryCatalogSummary")?.fields
            .filter { $0.id != "Context_Description" } ?? []
    }
    private var summaryFields: [SourceEditorField] {
        SourceEditorLibrary.shared.schema("GeometrySummaryPage")?.fields ?? []
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Label("Geometry", systemImage: "water.waves").font(.headline)
                if !geometryChoices.isEmpty {
                    GeometryPickerWorkspaceView(session: session, choices: geometryChoices,
                                                selectGeometry: selectGeometry)
                        .frame(maxWidth: 380)
                }
                if let selectedGeometry = geometryChoices.first(where: { $0.id == session.modelAssetID }) {
                    Button("Focus in New View", systemImage: "arrow.up.right.square") {
                        let projectID = store.projectSessionID
                        Task { @MainActor in
                            guard projectID == store.projectSessionID else { return }
                            _ = await runGeometryFocusInNewView(assetID: selectedGeometry.id, store: store)
                        }
                    }
                    .disabled(store.isRunningProjectTool || store.isSavingAll
                        || store.isOpeningProject || store.isClosingTab || session.isBusy)
                }
                Spacer()
                Button("Topology") { navigate("Topology") }
                Button("Mesh") { navigate("Mesh") }
                Menu("More") {
                    Button("Culverts") { navigate("Culverts") }
                    Button("Mesh Diagnostics") { diagnosticsPresented = true }
                }
            }
            .padding(12)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Form {
                        Section("Geometry") {
                            ForEach(catalogFields) { field in
                                SourceField(field: field, session: session, store: store)
                            }
                        }
                        Section("Description and Images") {
                            ForEach(summaryFields) { field in
                                SourceField(field: field, session: session, store: store)
                            }
                        }
                        Section("Associations") {
                            GeometryAssociationsPickerWorkspaceView(session: session, store: store)
                        }
                    }
                    .formStyle(.grouped)
                    GeometryPrepareSummaryWorkspaceView(session: session, store: store)
                }
                .padding(16)
                .frame(maxWidth: 980)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .sheet(isPresented: $diagnosticsPresented) {
            ModelDiagnosticsView(session: session, store: store)
                .frame(minWidth: 760, minHeight: 500)
        }
        .task(id: session.geometryMeshIdentity) {
            await session.ensureGeometryMeshLoaded()
        }
    }
}

/// GeometryPicker has source-owned choices and selection. It deliberately
/// uses the parent editor's guarded model replacement route.
struct GeometryPickerWorkspaceView: View {
    @ObservedObject var session: ModelEditorSession
    let choices: [ProjectAsset]
    let selectGeometry: (String?) -> Void
    private var selection: String? { session.modelAssetID }

    var body: some View {
        HStack(spacing: 8) {
            Text(L10n.text("Select a Geometry")).foregroundStyle(.secondary)
            Picker(L10n.text("Select a Geometry"), selection: Binding(get: { selection }, set: select)) {
                Text("None").tag(nil as String?)
                ForEach(choices) { asset in Text(asset.name).tag(Optional(asset.id)) }
                if let selection, !choices.contains(where: { $0.id == selection }) {
                    Text(session.modelName ?? selection).tag(Optional(selection))
                }
            }
            .labelsHidden()
            .disabled(session.isBusy || session.loadingSelection)
            .accessibilityLabel(L10n.text("Select a Geometry"))
        }
        .onAppear(perform: autoSelectSingleGeometry)
        .onChange(of: choices.map(\.id)) { _, _ in autoSelectSingleGeometry() }
    }

    private func select(_ id: String?) {
        guard !session.isBusy, !session.loadingSelection,
              id == nil || id.flatMap({ selected in choices.first { $0.id == selected } }) != nil else { return }
        selectGeometry(id)
    }

    private func autoSelectSingleGeometry() {
        guard selection == nil, choices.count == 1, !session.isBusy, !session.loadingSelection else { return }
        selectGeometry(choices[0].id)
    }
}

/// Geometry associations live in the owning project document, not the
/// geometry HDF. These selectors edit that existing project draft and leave
/// persistence to the workspace's normal project save path.
struct GeometryAssociationsPickerWorkspaceView: View {
    private struct SurfaceCategoryRequestIdentity: Hashable {
        let projectSessionID: UUID
        let surfaceLayerPaths: [String]
    }

    @ObservedObject var session: ModelEditorSession
    @ObservedObject var store: WorkspaceStore
    @State private var surfaceCategories: [String: SurfaceCatalogEntry] = [:]
    @State private var didLoadSurfaceCategories = false
    @State private var isLoadingSurfaceCategories = false
    @State private var surfaceCategoryError: String?
    @State private var surfaceCategoryDetails: String?
    @State private var surfaceCategoriesUnavailable = false

    private var association: ProjectAssociation? {
        guard let name = session.modelName else { return nil }
        return store.document?.associationRows(group: "GeometryAssociations").first { $0.name == name }
    }
    // Project.Terrains loads Terrain HDF models from *.h5. Raw TIFF raster
    // inputs can also appear under the Terrains folder/catalogue, but are not
    // valid GeometryAssociation targets.
    private var terrainChoices: [ProjectAsset] {
        store.assets.filter { $0.section == .terrains && $0.url.pathExtension.lowercased() == "h5" }
    }
    private var surfaceCategoryRequestIdentity: SurfaceCategoryRequestIdentity {
        .init(projectSessionID: store.projectSessionID,
              surfaceLayerPaths: store.assets.filter { $0.section == .surfaceLayers }
                .map { SourceFilePaths.canonical($0.url) }.sorted())
    }
    private var nValueChoices: [ProjectAsset] {
        store.assets.filter { asset in
            guard asset.section == .surfaceLayers,
                  let entry = surfaceCategories[SourceFilePaths.canonical(asset.url)] else { return false }
            return entry.category == "NValues" && entry.error == nil
        }
    }
    private var isDisabled: Bool {
        !session.canEdit || session.isBusy || session.loadingSelection || store.isSavingAll
            || store.isClosingTab || store.isOpeningProject || store.isRunningProjectTool
            || store.hasBusyModelEditors
    }

    var body: some View {
        if association == nil {
            ContentUnavailableView("Geometry associations unavailable", systemImage: "point.3.connected.trianglepath.dotted",
                description: Text("The selected geometry has no project association row.").foregroundStyle(.secondary))
        } else {
            VStack(alignment: .leading, spacing: 12) {
                associationPicker("Associated Terrain", field: "Terrain", choices: terrainChoices)
                associationPicker("Associated N Value Layer", field: "N_Values", choices: nValueChoices)
                if isLoadingSurfaceCategories {
                    ProgressView("Loading N-value layers…").controlSize(.small)
                } else if let surfaceCategoryError {
                    Label(L10n.text(surfaceCategoryError), systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.red).textSelection(.enabled)
                    if let surfaceCategoryDetails {
                        Text(surfaceCategoryDetails).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                } else if didLoadSurfaceCategories && !surfaceCategoriesUnavailable
                    && surfaceCategoryError == nil && nValueChoices.isEmpty {
                    Text("No N-value layers are available in this project.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .task(id: surfaceCategoryRequestIdentity) {
                await loadSurfaceCategories(identity: surfaceCategoryRequestIdentity)
            }
        }
    }

    private func associationPicker(_ title: String, field: String, choices: [ProjectAsset]) -> some View {
        let current = association?.fields[field] ?? ""
        let selectedAvailable = choices.contains { $0.name == current }
        return Picker(LocalizedStringKey(title), selection: Binding(
            get: { association?.fields[field] ?? "" },
            set: { value in
                guard !isDisabled, let association else { return }
                store.setAssociation(association, field: field, value: value)
            }
        )) {
            Text("None").tag("")
            ForEach(choices) { asset in Text(asset.name).tag(asset.name) }
            if !current.isEmpty && didLoadChoices(for: field) && !selectedAvailable
                && isKnownUnavailableAssociation(current, field: field) {
                Text(current + " (" + L10n.text("Missing") + ")").tag(current)
            } else if !current.isEmpty && didLoadChoices(for: field) && !selectedAvailable {
                // Keep an unverified source value visible and selectable while
                // category inspection is incomplete; do not label it missing.
                Text(current).tag(current)
            }
        }
        .disabled(isDisabled || (field == "N_Values"
            && (!didLoadSurfaceCategories || surfaceCategoriesUnavailable)))
    }

    private func didLoadChoices(for field: String) -> Bool {
        field == "N_Values" ? didLoadSurfaceCategories : true
    }

    private func isKnownUnavailableAssociation(_ name: String, field: String) -> Bool {
        guard field == "N_Values" else {
            return !terrainChoices.contains { $0.name == name }
        }
        guard let asset = store.assets.first(where: { $0.section == .surfaceLayers && $0.name == name }) else {
            return true
        }
        if let category = surfaceCategories[SourceFilePaths.canonical(asset.url)]?.category {
            return category != "NValues"
        }
        return surfaceCategoryError == nil && !surfaceCategoriesUnavailable
    }

    private func loadSurfaceCategories(identity: SurfaceCategoryRequestIdentity) async {
        guard identity == surfaceCategoryRequestIdentity else { return }
        isLoadingSurfaceCategories = false
        surfaceCategories = [:]
        surfaceCategoryError = nil
        surfaceCategoryDetails = nil
        surfaceCategoriesUnavailable = false
        didLoadSurfaceCategories = false
        let assets = store.assets.filter { $0.section == .surfaceLayers }
        let capturedPaths = assets.map { SourceFilePaths.canonical($0.url) }.sorted()
        guard capturedPaths == identity.surfaceLayerPaths else { return }
        guard !assets.isEmpty else {
            didLoadSurfaceCategories = true
            return
        }
        guard let provider = session.provider else {
            surfaceCategoryError = "The N-value layer source service is unavailable."
            surfaceCategoriesUnavailable = true
            didLoadSurfaceCategories = true
            return
        }
        isLoadingSurfaceCategories = true
        defer {
            if identity == surfaceCategoryRequestIdentity {
                isLoadingSurfaceCategories = false
            }
        }
        do {
            let entries = try await provider.catalogSurfaceLayers(assets)
            guard identity == surfaceCategoryRequestIdentity, !Task.isCancelled else { return }
            surfaceCategories = entries.reduce(into: [:]) { result, entry in
                let path = SourceFilePaths.canonical(URL(fileURLWithPath: entry.path))
                result[path] = entry
            }
            let inspectablePaths = Set(assets.filter { $0.url.pathExtension.lowercased() == "h5" }
                .map { SourceFilePaths.canonical($0.url) })
            let returnedPaths = Set(surfaceCategories.keys)
            let hasUninspectedLayers = !inspectablePaths.isSubset(of: returnedPaths)
            let hasFailedCategories = entries.contains { $0.category == nil || $0.error != nil }
            if hasUninspectedLayers || hasFailedCategories {
                let details = entries.compactMap(\.error).filter { !$0.isEmpty }
                surfaceCategoryError = "Some surface layers could not be inspected."
                surfaceCategoryDetails = details.isEmpty ? nil : details.joined(separator: "\n")
            }
            didLoadSurfaceCategories = true
        } catch {
            guard identity == surfaceCategoryRequestIdentity, !Task.isCancelled else { return }
            surfaceCategoryError = error.localizedDescription
            surfaceCategoriesUnavailable = true
            didLoadSurfaceCategories = true
        }
    }
}

/// GeometryPrepareSummaryControl is a view over the real Geometry.PrepareSummary
/// returned by GeometryMeshService. Refresh performs a source read; it does
/// not prepare, save, or replace the user's draft.
struct GeometryPrepareSummaryWorkspaceView: View {
    @ObservedObject var session: ModelEditorSession
    @ObservedObject var store: WorkspaceStore

    private var mesh: GeometryMeshSession? { session.geometryMesh }
    private var summary: GeometryMeshPrepareSummary? { mesh?.snapshot?.prepareSummary }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Prepare Summary", systemImage: "checkmark.seal")
                    .font(.headline)
                Spacer()
                Button("Refresh Summary", systemImage: "arrow.clockwise") {
                    Task { await mesh?.reload() }
                }
                .disabled(mesh == nil || mesh?.isLoading == true || mesh?.isEditing == true
                    || mesh?.parentSaveInProgress == true || session.isSaving || session.loadingSelection)
                Button("Copy Prepare Log", systemImage: "doc.on.doc") {
                    if let log = summary?.prepareLog, !log.isEmpty { store.system.copy(log) }
                }
                .disabled(summary?.prepareLog?.isEmpty != false)
            }
            .padding(12)
            Divider()
            Form {
                if let mesh {
                    GeometryMeshPropertyTablesActionView(session: mesh)
                } else {
                    Section("Property Tables") {
                        Text("The geometry mesh service is unavailable.").foregroundStyle(.secondary)
                    }
                }
                if let summary {
                    Section("Status") {
                        LabeledContent("Geometry", value: session.modelName ?? "—")
                        LabeledContent("Succeeded", value: summary.succeeded.map { L10n.text($0 ? "Yes" : "No") } ?? L10n.text("Not available"))
                        summaryValue("Failure Reason", summary.failureReason)
                        summaryValue("Software Version", summary.softwareVersion)
                        summaryValue("Start Time", summary.startTime)
                        summaryValue("End Time", summary.endTime)
                        summaryDuration("Total Duration", summary.totalDurationSeconds)
                        summaryDuration("Property Table Duration", summary.propertyTableDurationSeconds)
                    }
                    Section("Preparation Log") { prepareLog(summary.prepareLog) }
                } else if mesh?.isLoading == true {
                    ProgressView("Loading prepare summary…").frame(maxWidth: .infinity, alignment: .leading)
                } else if mesh?.preparePending == true {
                    ContentUnavailableView("Prepare summary pending", systemImage: "clock.arrow.circlepath",
                        description: Text("Prepare is queued in this geometry draft and will run during parent model save."))
                } else if let error = mesh?.error {
                    ContentUnavailableView("Prepare summary unavailable", systemImage: "exclamationmark.triangle",
                        description: Text(L10n.text(error)))
                } else if mesh?.snapshot != nil {
                    ContentUnavailableView("Geometry not prepared", systemImage: "doc.text.magnifyingglass",
                        description: Text("This geometry hasn't been prepared yet. Compute a plan that uses it to generate a preparation log."))
                } else if mesh == nil {
                    ContentUnavailableView("Prepare summary unavailable", systemImage: "doc.text.magnifyingglass",
                        description: Text("The geometry mesh service is unavailable."))
                } else {
                    ContentUnavailableView("Prepare summary unavailable", systemImage: "doc.text.magnifyingglass",
                        description: Text("The source prepare summary has not been loaded."))
                }
            }
            .formStyle(.grouped)
        }
        .background(.background, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary))
    }

    @ViewBuilder private func summaryValue(_ title: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            LabeledContent(LocalizedStringKey(title), value: value).textSelection(.enabled)
        } else {
            LabeledContent(LocalizedStringKey(title)) {
                Text("Not supplied").foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder private func summaryDuration(_ title: String, _ seconds: Double?) -> some View {
        if let seconds, seconds.isFinite {
            LabeledContent(LocalizedStringKey(title), value: seconds.formatted() + " s")
        } else {
            LabeledContent(LocalizedStringKey(title)) {
                Text("Not supplied").foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder private func prepareLog(_ log: String?) -> some View {
        if let log, !log.isEmpty {
            ScrollView {
                Text(log)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(minHeight: 110, idealHeight: 170)
        } else {
            Label("Preparation completed without logging any messages.", systemImage: "text.alignleft")
                .foregroundStyle(.secondary)
                .padding(.vertical, 4)
        }
    }
}

/// LayerErrorIndicator is a compact entry point; LayerErrorList provides the
/// searchable message table and selected-message detail. nil means that the
/// source did not provide the list, while [] is an actual empty list.
struct GeometryLayerErrorIndicatorWorkspaceView: View {
    let issues: [EditorIssue]?
    let title: String
    @ObservedObject var store: WorkspaceStore
    @State private var presented = false

    private var mostSevere: EditorIssue.Severity? {
        issues?.map(\.severity).max { severityRank($0) < severityRank($1) }
    }
    var body: some View {
        Button {
            presented = true
        } label: {
            if let issues {
                if issues.isEmpty {
                    Label("No layer errors", systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                } else {
                    Label("\(issues.count.formatted()) layer issues", systemImage: severitySymbol(mostSevere))
                        .foregroundStyle(severityColor(mostSevere))
                }
            } else {
                Label("Layer errors unavailable", systemImage: "minus.circle")
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $presented) {
            TopologyFeatureErrorsWorkspaceView(featureName: title, issues: issues, store: store)
                .frame(minWidth: 620, minHeight: 420)
        }
    }
}

struct GeometryLayerErrorListWorkspaceView: View {
    let issues: [EditorIssue]?
    let title: String
    @ObservedObject var store: WorkspaceStore
    @State private var selectedID: String?
    @State private var query = ""
    @State private var severity = "All"

    private var filtered: [EditorIssue] {
        (issues ?? []).filter {
            (severity == "All" || $0.severity.rawValue == severity)
                && (query.isEmpty || $0.message.localizedCaseInsensitiveContains(query)
                    || ($0.feature ?? "").localizedCaseInsensitiveContains(query))
        }
    }
    private var selected: EditorIssue? { filtered.first { $0.id == selectedID } }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(LocalizedStringKey(title), systemImage: "exclamationmark.bubble")
                    .font(.headline)
                Spacer()
                TextField("Search errors", text: $query).textFieldStyle(.roundedBorder).frame(maxWidth: 240)
                Picker("Severity", selection: $severity) {
                    Text("All").tag("All")
                    Text("Errors").tag("error")
                    Text("Warnings").tag("warning")
                    Text("Information").tag("info")
                }.frame(maxWidth: 150)
                Button("Copy", systemImage: "doc.on.doc") {
                    let text = filtered.map { "[\($0.severity.rawValue)] \($0.feature ?? "") \($0.message)\n\($0.detail ?? "")" }
                        .joined(separator: "\n")
                    if !text.isEmpty { store.system.copy(text) }
                }.disabled(filtered.isEmpty)
            }.padding(12)
            Table(filtered, selection: $selectedID) {
                TableColumn("Severity") { issue in
                    Label(issue.severity.rawValue.capitalized, systemImage: severitySymbol(issue.severity))
                        .foregroundStyle(severityColor(issue.severity))
                }.width(min: 85, ideal: 105)
                TableColumn("Message", value: \.message)
                TableColumn("Feature") { issue in Text(issue.feature ?? "—") }
                    .width(min: 90, ideal: 140)
            }
            .overlay {
                if filtered.isEmpty {
                    if issues.map(\.isEmpty) == nil {
                        ContentUnavailableView("Error list unavailable", systemImage: "minus.circle",
                                               description: Text("The source adapter has not supplied messages for this selection."))
                    } else if issues?.isEmpty == true {
                        ContentUnavailableView("No layer errors reported", systemImage: "checkmark.circle")
                    } else {
                        ContentUnavailableView("No matching errors", systemImage: "magnifyingglass")
                    }
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Error Details").font(.subheadline.weight(.semibold))
                    Spacer()
                    if let location = selected?.location {
                        Button("Zoom to Location", systemImage: "viewfinder") { zoom(location) }
                    }
                }
                if let selected {
                    Text(selected.message).font(.headline).textSelection(.enabled)
                    if let detail = selected.detail { ScrollView { Text(detail).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) } }
                    if let location = selected.location {
                        Text("X: \(location.x.formatted())   Y: \(location.y.formatted())")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                } else {
                    Text("Select a message to view its details.").foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 120, maxHeight: 220, alignment: .topLeading)
        }
        .onChange(of: query) { _, _ in selectedID = nil }
        .onChange(of: severity) { _, _ in selectedID = nil }
    }

    private func zoom(_ point: MapPoint) {
        guard point.x.isFinite, point.y.isFinite else { return }
        let state = store.activeMapState
        let extent = state.currentExtent
        let halfWidth = max((extent.map { $0.upperRight.x - $0.lowerLeft.x } ?? 2) / 2, 0.000001)
        let halfHeight = max((extent.map { $0.upperRight.y - $0.lowerLeft.y } ?? 2) / 2, 0.000001)
        state.viewport = ViewportRequest(lowerLeft: .init(x: point.x - halfWidth, y: point.y - halfHeight),
                                         upperRight: .init(x: point.x + halfWidth, y: point.y + halfHeight))
    }
}

struct TopologyFeatureErrorsWorkspaceView: View {
    let featureName: String
    let issues: [EditorIssue]?
    @ObservedObject var store: WorkspaceStore
    var body: some View {
        GeometryLayerErrorListWorkspaceView(issues: issues, title: featureName, store: store)
    }
}

/// Source tag definitions, selected-feature assignments, and topology
/// metadata all come from the same GeometryTopologySession draft. The table
/// selection is resolved to source FIDs before any mutation is enabled.
struct GeometryFeatureMetadataWorkspaceView: View {
    let featureType: String
    let featureIDs: Set<String>
    let scope: String?
    @ObservedObject var session: ModelEditorSession
    @ObservedObject var store: WorkspaceStore
    @State private var tagQuery = ""
    @State private var selectedTagID = ""
    @State private var tagValue = ""
    @State private var tagBoolean = false
    @State private var selectedMetadataRow: String?
    @State private var showingCreateTag = false
    @State private var newTagName = ""
    @State private var newTagType = "String"

    private var featureKind: String? {
        switch featureType {
        case "Arcs": "arc"
        case "Regions": "region"
        default: nil
        }
    }

    private var topology: GeometryTopologySession? { session.geometryTopology }

    private var sourceTable: GeometryTopologyFeatureTable? {
        guard let featureKind, let snapshot = topology?.snapshot else { return nil }
        return featureKind == "arc" ? snapshot.arcs : snapshot.regions
    }

    private var selectionResolution: GeometryFeatureFIDSelection {
        guard let sourceTable, featureKind != nil else {
            return GeometryFeatureFIDSelection(fids: [], unresolvedIDs: featureIDs)
        }
        let modelRows = session.rows[featureType] ?? []
        var fids = Set<Int>()
        var unresolved = Set<String>()
        for rowID in featureIDs {
            if let exactTopologyRow = sourceTable.rows.first(where: { $0.id == rowID }) {
                fids.insert(exactTopologyRow.fid)
                continue
            }

            // The native table may expose a presentation row identity of its
            // own. Resolve only through that exact selected row's FID column;
            // row order and display text are never used as source identity.
            guard let modelRow = modelRows.first(where: { $0.id == rowID }),
                  let rawFID = modelRow.values["FID"],
                  let fid = Int(rawFID.trimmingCharacters(in: .whitespacesAndNewlines)),
                  sourceTable.rows.contains(where: { $0.fid == fid }) else {
                unresolved.insert(rowID)
                continue
            }
            fids.insert(fid)
        }
        if fids.count != featureIDs.count { unresolved.formUnion(featureIDs) }
        return GeometryFeatureFIDSelection(fids: fids, unresolvedIDs: unresolved)
    }

    private var selectedRows: [GeometryTopologyFeatureRow] {
        guard let sourceTable else { return [] }
        let fids = selectionResolution.fids
        return sourceTable.rows.filter { fids.contains($0.fid) }
    }

    private var selectionIsResolved: Bool {
        !featureIDs.isEmpty && selectionResolution.unresolvedIDs.isEmpty
            && selectedRows.count == selectionResolution.fids.count
            && selectionResolution.fids.count == featureIDs.count
    }

    private var definitions: [GeometryTopologyTagDefinition] {
        guard let featureKind else { return [] }
        return topology?.tagDefinitions(for: featureKind) ?? []
    }

    private var matchingDefinitions: [GeometryTopologyTagDefinition] {
        guard !tagQuery.isEmpty else { return definitions }
        return definitions.filter { $0.id.localizedStandardContains(tagQuery) }
    }

    private var recentTags: [GeometryTopologyRecentTag] {
        guard let featureKind else { return [] }
        return topology?.recentTags(for: featureKind) ?? []
    }

    private var definitionIdentity: String {
        definitions.map { $0.id + "\u{1f}" + $0.type }.joined(separator: "\u{1e}")
    }

    private var selectedDefinition: GeometryTopologyTagDefinition? {
        matchingDefinitions.first { $0.id == selectedTagID }
    }

    private var currentTagValues: [String?] {
        guard let selectedDefinition else { return [] }
        return selectedRows.map { $0.values[selectedDefinition.id] }
    }

    private var tagValuesVary: Bool { Set(currentTagValues).count > 1 }

    private var commonTagValue: String? {
        guard !currentTagValues.isEmpty, Set(currentTagValues).count == 1 else { return nil }
        return currentTagValues.first ?? nil
    }

    private var canEditTags: Bool {
        session.loaded && session.canEdit && !session.isBusy
            && topology?.canEdit == true && topology?.isEditing == false
    }

    private var tagNameIsAvailable: Bool {
        guard !newTagName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        // The retained source validates reserved topology columns. The table
        // also contains generated columns such as FID and Length that the
        // source does not treat as reserved tag names, so reject only an
        // existing tag definition locally.
        return !definitions.contains { $0.id.compare(newTagName, options: .caseInsensitive) == .orderedSame }
    }

    private var canCreateTag: Bool { canEditTags && tagNameIsAvailable }

    private var tagValueIsValid: Bool {
        guard let selectedDefinition else { return false }
        switch selectedDefinition.type.lowercased() {
        case "boolean", "bool": return true
        case "string": return true
        case "integer": return Int32(tagValue.trimmingCharacters(in: .whitespacesAndNewlines)) != nil
        case "numeric":
            guard let value = Double(tagValue.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
            return value.isFinite
        default: return false
        }
    }

    private var metadataRows: [GeometryFeatureMetadataRow] {
        guard let sourceTable, !selectedRows.isEmpty else { return [] }
        return sourceTable.columns.filter { !$0.isTag }.map { column in
            let values = selectedRows.map { $0.values[column.id] }
            let displayedValue: String
            if Set(values).count > 1 {
                displayedValue = L10n.text("Values vary by feature")
            } else if let value = values.first ?? nil {
                displayedValue = value.isEmpty ? "—" : value
            } else {
                displayedValue = L10n.text("Not supplied by the source model")
            }
            return GeometryFeatureMetadataRow(id: column.id, name: column.title, value: displayedValue)
        }
    }

    var body: some View {
        Form {
            Section("Feature Tags") {
                if featureKind == nil {
                    ContentUnavailableView("Tags are available only for arcs and regions.",
                        systemImage: "tag", description: Text("Select Arcs or Regions to edit tags."))
                } else if topology?.isLoading == true {
                    ProgressView("Loading topology tags…")
                } else if topology?.snapshot == nil {
                    ContentUnavailableView("Topology tags unavailable", systemImage: "tag.slash",
                        description: Text("Load the topology before editing tags."))
                } else {
                    HStack(spacing: 8) {
                        TextField("Search tags", text: $tagQuery)
                            .textFieldStyle(.roundedBorder)
                        if !availableRecentTags.isEmpty {
                            Menu("Recent Tags") {
                                ForEach(availableRecentTags) { recent in
                                    Button {
                                        applyRecentTag(recent)
                                    } label: {
                                        Text(verbatim: "\(recent.name): \(recent.value)")
                                    }
                                }
                            }
                            .disabled(!canEditTags || !selectionIsResolved)
                        }
                        Button("Add Tag", systemImage: "plus") {
                            newTagName = ""
                            newTagType = "String"
                            showingCreateTag = true
                        }
                        .disabled(!canEditTags)
                    }

                    if definitions.isEmpty {
                        ContentUnavailableView("No tag columns are defined for this feature table.",
                            systemImage: "tag", description: Text("Create a tag definition to add a source metadata column."))
                            .frame(minHeight: 80, maxHeight: 130)
                    } else if matchingDefinitions.isEmpty {
                        ContentUnavailableView("No matching tags.", systemImage: "magnifyingglass")
                            .frame(minHeight: 70, maxHeight: 100)
                    } else {
                        Picker("Tag", selection: $selectedTagID) {
                            ForEach(matchingDefinitions) { definition in
                                Text(verbatim: "\(definition.id) · \(L10n.text(definition.type))").tag(definition.id)
                            }
                        }
                        .disabled(matchingDefinitions.isEmpty)

                        if let selectedDefinition {
                            if featureIDs.isEmpty {
                                Label("Select source features to assign a tag.", systemImage: "cursorarrow.click")
                                    .foregroundStyle(.secondary)
                            } else if !selectionIsResolved {
                                Label("The selected rows cannot be mapped to exact source FIDs.",
                                    systemImage: "exclamationmark.triangle")
                                    .foregroundStyle(.secondary)
                            } else {
                                LabeledContent("Selected FIDs", value: selectedRows.map { String($0.fid) }.joined(separator: ", "))
                                    .font(.caption.monospaced())

                                if tagValuesVary {
                                    Text("Selected features currently have different values for this tag.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                } else if let commonTagValue {
                                    LabeledContent("Current value") {
                                        Text(commonTagValue.isEmpty ? "—" : commonTagValue)
                                            .textSelection(.enabled)
                                    }
                                }

                                if isBoolean(selectedDefinition) {
                                    Toggle("Tag value", isOn: $tagBoolean)
                                        .disabled(!canEditTags || selectedRows.isEmpty || !selectionIsResolved)
                                } else {
                                    TextField(tagValuesVary ? L10n.text("Values vary by feature") : L10n.text("Tag value"),
                                        text: $tagValue)
                                        .textFieldStyle(.roundedBorder)
                                        .disabled(!canEditTags || selectedRows.isEmpty || !selectionIsResolved)
                                }

                                HStack {
                                    Button("Assign Tag", systemImage: "tag") {
                                        assignSelectedTag()
                                    }
                                    .disabled(!canEditTags || selectedRows.isEmpty || !selectionIsResolved || !tagValueIsValid)
                                    Button("Remove Tag", systemImage: "tag.slash") {
                                        removeSelectedTag()
                                    }
                                    .disabled(!canEditTags || selectedRows.isEmpty || !selectionIsResolved)
                                }
                            }
                        }
                    }

                    if let error = topology?.error {
                        Label(L10n.text(error), systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            Section("Feature Metadata") {
                if featureKind == nil {
                    ContentUnavailableView("Metadata table unavailable", systemImage: "tablecells",
                        description: Text("Tags are available for arcs and regions."))
                } else if sourceTable == nil {
                    ContentUnavailableView("Metadata table unavailable", systemImage: "tablecells",
                        description: Text("Load the topology to view metadata."))
                } else if featureIDs.isEmpty {
                    ContentUnavailableView("Select a source feature", systemImage: "cursorarrow.click",
                        description: Text("Choose one or more arcs or regions to inspect source metadata."))
                } else if !selectionIsResolved {
                    ContentUnavailableView("Feature selection unavailable", systemImage: "exclamationmark.triangle",
                        description: Text("The selected rows cannot be mapped to exact source FIDs."))
                } else if metadataRows.isEmpty {
                    ContentUnavailableView("No source metadata properties are available.", systemImage: "tablecells")
                } else {
                    Table(metadataRows, selection: $selectedMetadataRow) {
                        TableColumn("Property", value: \.name)
                        TableColumn("Value", value: \.value)
                    }
                    .frame(minHeight: 100, idealHeight: 145)
                }
            }
        }
        .formStyle(.grouped)
        .task(id: session.geometryTopologyIdentity) {
            await session.ensureGeometryTopologyLoaded()
            selectInitialTag()
            handleEditorToolRequest()
        }
        .onChange(of: featureIDs) { _, _ in
            selectedMetadataRow = nil
            loadSelectedTagValue()
        }
        .onChange(of: tagQuery) { _, _ in selectInitialTag() }
        .onChange(of: session.modelAssetID) { _, _ in
            tagQuery = ""
            selectedMetadataRow = nil
            selectedTagID = ""
        }
        .onChange(of: definitionIdentity) { _, _ in selectInitialTag() }
        .onChange(of: selectedTagID) { _, _ in loadSelectedTagValue() }
        .onChange(of: store.editorToolPresentationRequest?.id) { _, _ in handleEditorToolRequest() }
        .sheet(isPresented: $showingCreateTag) {
            createTagSheet
        }
    }

    private var createTagSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Create Tag").font(.title2.weight(.semibold))
            TextField("Tag name", text: $newTagName)
                .textFieldStyle(.roundedBorder)
            Picker("Type", selection: $newTagType) {
                ForEach(["String", "Integer", "Numeric", "Boolean"], id: \.self) { type in
                    Text(L10n.text(type)).tag(type)
                }
            }
            .pickerStyle(.segmented)
            if !newTagName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !tagNameIsAvailable {
                Text("A tag definition with this name already exists.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") { showingCreateTag = false }
                Button("Create") { createTag() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canCreateTag)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private func isBoolean(_ definition: GeometryTopologyTagDefinition) -> Bool {
        ["boolean", "bool"].contains(definition.type.lowercased())
    }

    private var availableRecentTags: [GeometryTopologyRecentTag] {
        recentTags.filter { recent in definitions.contains(where: { $0.id == recent.name }) }
    }

    private func selectInitialTag() {
        if !matchingDefinitions.contains(where: { $0.id == selectedTagID }) {
            selectedTagID = matchingDefinitions.first?.id ?? ""
        }
        loadSelectedTagValue()
    }

    private func loadSelectedTagValue() {
        guard selectedDefinition != nil else {
            tagValue = ""
            tagBoolean = false
            return
        }
        guard !selectedRows.isEmpty, !tagValuesVary, let value = commonTagValue else {
            tagValue = ""
            tagBoolean = false
            return
        }
        tagValue = value
        tagBoolean = value.caseInsensitiveCompare("true") == .orderedSame
    }

    private func assignSelectedTag() {
        guard canEditTags, selectionIsResolved, !selectedRows.isEmpty,
              let selectedDefinition, tagValueIsValid, let topology, let featureKind else { return }
        let value = isBoolean(selectedDefinition) ? (tagBoolean ? "true" : "false") : tagValue
        let fids = selectedRows.map(\.fid)
        Task { await topology.setTag(featureKind: featureKind, featureIDs: fids,
            name: selectedDefinition.id, value: value) }
    }

    private func removeSelectedTag() {
        guard canEditTags, selectionIsResolved, !selectedRows.isEmpty,
              let selectedDefinition, let topology, let featureKind else { return }
        let fids = selectedRows.map(\.fid)
        Task { await topology.removeTag(featureKind: featureKind, featureIDs: fids,
            name: selectedDefinition.id) }
    }

    private func applyRecentTag(_ recent: GeometryTopologyRecentTag) {
        guard canEditTags, selectionIsResolved, !selectedRows.isEmpty,
              definitions.contains(where: { $0.id == recent.name }), let topology, let featureKind else { return }
        tagQuery = ""
        selectedTagID = recent.name
        let fids = selectedRows.map(\.fid)
        Task { await topology.setTag(featureKind: featureKind, featureIDs: fids,
            name: recent.name, value: recent.value) }
    }

    private func createTag() {
        guard canCreateTag, let topology, let featureKind else { return }
        let name = newTagName
        let type = newTagType
        tagQuery = ""
        selectedTagID = name
        showingCreateTag = false
        newTagName = ""
        Task { await topology.createTag(featureKind: featureKind, name: name, type: type) }
    }

    private func handleEditorToolRequest() {
        guard let request = store.editorToolPresentationRequest,
              store.primaryEditorSession(.geometry).id == session.id,
              request.projectSessionID == store.projectSessionID,
              request.assetID == session.modelAssetID,
              request.featureKind == featureKind,
              request.action == .tagCreate || request.action == .tagEdit,
              topology?.snapshot != nil else { return }

        switch request.action {
        case .tagCreate:
            newTagName = ""
            newTagType = "String"
            showingCreateTag = true
        case .tagEdit:
            tagQuery = ""
            selectInitialTag()
        default:
            return
        }
        store.consumeEditorToolPresentationRequest(request.id)
    }
}

private struct GeometryFeatureMetadataRow: Identifiable {
    let id: String
    let name: String
    let value: String
}

private struct GeometryFeatureFIDSelection {
    let fids: Set<Int>
    let unresolvedIDs: Set<String>
}

/// PointControl is hosted by the scalar boundary-condition controls when
/// SpatialDataType is Point. Reuse the source-backed station/input editor
/// when its presentation exists; when it does not, keep the split-list,
/// detail, and coordinate-plot structure visible without inventing rows.
struct GeometryPointControlWorkspaceView: View {
    let layer: SpatialBoundaryLayer
    @ObservedObject var session: ModelEditorSession
    @ObservedObject var store: WorkspaceStore

    private var pointData: SpatialPointPresentation? {
        session.spatialPresentations[layer.id]?.pointData
    }

    var body: some View {
        Group {
            if let pointData {
                SpatialPointEditor(layer: layer, data: pointData, session: session, store: store)
            } else {
                unavailablePointDataWorkspace
            }
        }
    }

    private var unavailablePointDataWorkspace: some View {
        VStack(spacing: 0) {
            HStack {
                Label(LocalizedStringKey(layer.title), systemImage: layer.symbol)
                    .font(.headline)
                Text("Point Data").foregroundStyle(.secondary)
                Spacer()
                Button("Add Station", systemImage: "plus") {}
                    .disabled(true)
                    .help("Point station data is not supplied by the current source adapter.")
                Button("Remove Station", systemImage: "minus") {}
                    .disabled(true)
                Button("Add Input", systemImage: "plus") {}
                    .disabled(true)
                Button("Remove Input", systemImage: "minus") {}
                    .disabled(true)
            }
            .padding(12)
            Divider()
            HSplitView {
                VStack(spacing: 0) {
                    Text("Shared Stations").font(.headline).frame(maxWidth: .infinity, alignment: .leading).padding(10)
                    Table([GeometryPointControlPlaceholderRow]()) {
                        TableColumn("Station") { _ in Text("—") }
                        TableColumn("X Coordinate") { _ in Text("—") }
                        TableColumn("Y Coordinate") { _ in Text("—") }
                    }
                    .overlay {
                        ContentUnavailableView("Station list unavailable", systemImage: "mappin.and.ellipse",
                                               description: Text("The source adapter has not supplied point stations for this layer."))
                    }
                    Divider()
                    Text("Station Inputs").font(.headline).frame(maxWidth: .infinity, alignment: .leading).padding(10)
                    Table([GeometryPointControlPlaceholderRow]()) {
                        TableColumn("Station") { _ in Text("—") }
                        TableColumn("Enabled") { _ in Text("—") }
                    }
                    .overlay {
                        ContentUnavailableView("Input list unavailable", systemImage: "list.bullet",
                                               description: Text("The source adapter has not supplied point inputs for this layer."))
                    }
                }
                .frame(minWidth: 280, idealWidth: 340)

                VSplitView {
                    Form {
                        Section("Shared Station") {
                            unavailableValue("Name")
                            unavailableValue("X Coordinate")
                            unavailableValue("Y Coordinate")
                            unavailableValue("Height Above Ground")
                        }
                        Section("Station Input") {
                            Toggle("Enabled", isOn: .constant(false)).disabled(true)
                            Picker("Station", selection: .constant("")) { Text("Not supplied").tag("") }.disabled(true)
                            Picker("Input Type", selection: .constant("")) { Text("Not supplied").tag("") }.disabled(true)
                            unavailableValue("Value")
                        }
                    }
                    .formStyle(.grouped)

                    Chart([SpatialPointPresentation.Station]()) { station in
                        PointMark(
                            x: .value(L10n.text("X Coordinate"), station.x),
                            y: .value(L10n.text("Y Coordinate"), station.y)
                        )
                    }
                    .chartXAxisLabel("X Coordinate")
                    .chartYAxisLabel("Y Coordinate")
                    .frame(minHeight: 180)
                    .overlay {
                        Label("Point coordinates unavailable", systemImage: "chart.xyaxis.line")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(12)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                .frame(minWidth: 430)
            }
        }
    }

    private func unavailableValue(_ title: String) -> some View {
        LabeledContent(LocalizedStringKey(title)) {
            Text("Not supplied").foregroundStyle(.tertiary)
        }
    }
}

private struct GeometryPointControlPlaceholderRow: Identifiable {
    let id = "unavailable"
}

private func severityRank(_ severity: EditorIssue.Severity) -> Int {
    switch severity { case .info: 0; case .warning: 1; case .error: 2 }
}

private func severitySymbol(_ severity: EditorIssue.Severity?) -> String {
    switch severity {
    case .error: "xmark.octagon.fill"
    case .warning: "exclamationmark.triangle.fill"
    case .info: "info.circle.fill"
    case nil: "minus.circle"
    }
}

private func severityColor(_ severity: EditorIssue.Severity?) -> Color {
    switch severity {
    case .error: .red
    case .warning: .orange
    case .info, nil: .secondary
    }
}
