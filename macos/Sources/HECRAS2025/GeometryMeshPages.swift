import RASWorkspaceCore
import SwiftUI

struct GeometryMeshPage: View {
    @ObservedObject var session: ModelEditorSession
    @ObservedObject var store: WorkspaceStore
    var navigate: ((String) -> Void)? = nil
    var selectTopologyFeatures: ((String, [String]) -> Void)? = nil
    var body: some View {
        if let mesh = session.geometryMesh {
            GeometryMeshWorkspacePage(session: mesh, store: store, navigate: navigate,
                selectTopologyFeatures: selectTopologyFeatures,
                prepareAndSave: { await session.saveLoadedModel() },
                persistDiagnosticsPreferences: { capture in
                    guard let persist = session.persistDiagnosticsPreferences else { throw CancellationError() }
                    return try await persist(capture)
                })
                .task(id: session.geometryMeshIdentity + "|" + store.meshDiagnosticsPreferencesIdentity(for: session)) {
                    await session.ensureGeometryMeshLoaded()
                    store.installMeshDiagnosticsPreferences(for: session)
                }
                .overlay(alignment: .bottom) {
                    if let error = session.error {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout).foregroundStyle(.red).padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.regularMaterial)
                    }
                }
        } else {
            ContentUnavailableView("Mesh data unavailable", systemImage: "square.grid.3x3",
                description: Text("The geometry mesh service is unavailable."))
        }
    }
}

@MainActor
struct FlowAreaSelection {
    let session: ModelEditorSession
    var collection: SourceCollection? { session.sourceCollections[GeometryMeshBindings.flowArea] }
    var id: String? { session.fields[GeometryMeshBindings.flowArea].flatMap { $0.isEmpty ? nil : $0 } }
    var detail: SourceItemPresentation? { id.flatMap { collection?.itemDetails[$0] } }
}

struct FlowAreaPicker: View {
    @ObservedObject var session: ModelEditorSession
    private var source: FlowAreaSelection { .init(session: session) }
    var body: some View {
        Picker("Flow Area", selection: Binding(get: { source.id }, set: { id in
            Task { await session.perform(.selectSource(field: GeometryMeshBindings.flowArea, id: id)) }
        })) {
            if source.id == nil { Text("Select a flow area").tag(nil as String?) }
            ForEach(source.collection?.items ?? []) { choice in Text(choice.title).tag(Optional(choice.id)) }
        }.disabled(source.collection?.items.isEmpty != false || session.isBusy || session.loadingSelection)
    }
}

struct FlowAreaInformationPage: View {
    @ObservedObject var session: ModelEditorSession
    @ObservedObject var store: WorkspaceStore
    private var source: FlowAreaSelection { .init(session: session) }
    var body: some View {
        VStack(spacing: 0) {
            FlowAreaPicker(session: session).padding(14)
            Divider()
            if session.loadingSelection { ProgressView("Loading properties…").frame(maxWidth: .infinity, maxHeight: .infinity) }
            else if let detail = source.detail {
                Form {
                    Section("Flow Area") {
                        ForEach(SourceEditorLibrary.shared.schema("FlowAreaEditorControl")?.fields ?? []) { field in
                            SourceField(field: field.inScope(detail.scope), session: session, store: store)
                        }
                    }
                    Section("Mesh Information") {
                        if let count = detail.flowArea?.cellCount { LabeledContent("Cell Count", value: count.formatted()).textSelection(.enabled) }
                        else { Text("Cell count unavailable").foregroundStyle(.secondary) }
                    }
                    if let metadata = detail.flowArea?.metadata, !metadata.isEmpty {
                        Section("Metadata") {
                            ForEach(metadata) { value in LabeledContent(value.titleIsUserData ? value.title : L10n.text(value.title), value: value.value).textSelection(.enabled) }
                        }
                    }
                }.formStyle(.grouped).id(detail.scope)
            } else {
                ContentUnavailableView("Mesh data unavailable", systemImage: "square.grid.3x3", description: Text("Select a flow area supplied by the source model."))
            }
        }
    }
}

struct MeshDegreeErrorsPage: View {
    @ObservedObject var session: ModelEditorSession
    @ObservedObject var store: WorkspaceStore
    @State private var selectedID: String?
    private var source: FlowAreaSelection { .init(session: session) }
    private var issues: [MeshNodeDegreeIssue]? { source.detail?.flowArea?.degreeIssues }
    private var selected: MeshNodeDegreeIssue? { issues?.first { $0.id == selectedID } }
    var body: some View {
        VStack(spacing: 0) {
            FlowAreaPicker(session: session).padding(14)
            Form {
                ForEach(SourceEditorLibrary.shared.schema("MeshErrorProperties")?.fields ?? []) { field in
                    SourceField(field: field.inScope(source.detail?.scope), session: session, store: store)
                }
            }.formStyle(.grouped).frame(minHeight: 120, maxHeight: 180)
            Divider()
            HStack {
                Text("Mesh Errors").font(.headline)
                if let issues { Text(issues.count.formatted()).foregroundStyle(.secondary) }
                Spacer()
                Button("Zoom to Error", action: zoom).disabled(selected?.viewport == nil)
                Button("Copy") { if let selected { store.system.copy(L10n.format("Node %d - %d faces", selected.nodeIndex, selected.faceCount)) } }.disabled(selected == nil)
            }.padding(12)
            Table(issues ?? [], selection: $selectedID) {
                TableColumn(L10n.text("Node")) { issue in Text(issue.nodeIndex.formatted()).monospacedDigit() }
                TableColumn(L10n.text("Faces")) { issue in Text(issue.faceCount.formatted()).monospacedDigit() }
                TableColumn(L10n.text("Description")) { issue in Text(L10n.format("Node %d - %d faces", issue.nodeIndex, issue.faceCount)) }
            }.overlay {
                if session.loadingSelection { ProgressView("Loading properties…") }
                else if issues == nil { ContentUnavailableView("Mesh error list unavailable", systemImage: "stethoscope") }
                else if issues?.isEmpty == true { ContentUnavailableView("No issues reported", systemImage: "checkmark.circle") }
            }
        }
        .onChange(of: selectedID) { _, _ in zoom() }
        .onChange(of: source.detail?.scope) { _, _ in selectedID = nil }
        .onChange(of: session.modelAssetID) { _, _ in selectedID = nil }
    }
    private func zoom() { if let extent = selected?.viewport { store.activeMapState.viewport = extent } }
}

struct RegionPatchPage: View {
    @ObservedObject var session: ModelEditorSession
    @ObservedObject var store: WorkspaceStore
    @State private var detailTab = "Properties"
    private let page = ModelEditorPage.table("Regions", "ConceptualMeshControlPointEditor")
    private var selection: TableSelectionPresentation? { session.tablePresentations[GeometryMeshBindings.regions]?.selection }
    var body: some View {
        VSplitView {
            ModelTablePage(page: page, session: session, store: store, showsSelectionDetail: false).frame(minHeight: 180)
            TabView(selection: $detailTab) {
                TableSelectionDetail(page: page, presentation: selection, session: session, store: store, showsPatchSizing: false).tabItem { Text("Properties") }.tag("Properties")
                PatchSizingPage(detail: selection?.detail, session: session, store: store).tabItem { Text("Patch Sizing") }.tag("Patch Sizing")
            }.frame(minHeight: 230)
        }
    }
}

struct PatchSizingPage: View {
    let detail: SourceItemPresentation?
    @ObservedObject var session: ModelEditorSession
    @ObservedObject var store: WorkspaceStore
    private var editable: Bool { session.canEdit && !session.isBusy && !session.loadingSelection && !store.isSavingAll }
    var body: some View {
        if session.loadingSelection || detail?.patch?.state == .loading {
            ProgressView("Loading patch sides…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let detail, let patch = detail.patch {
            switch patch.state {
            case .mixedTypes: ContentUnavailableView("Selected regions have different patch types.", systemImage: "square.on.square")
            case .unavailable: ContentUnavailableView("Patch sizing unavailable", systemImage: "square.dashed", description: Text(patch.message))
            case .loading: ProgressView("Loading patch sides…")
            case .ready:
                Form {
                    if !patch.message.isEmpty { Section { Text(patch.message).foregroundStyle(.secondary) } }
                    switch patch.kind {
                    case .triangle:
                        scalarSizing(schema: "TrianglePatchQuickEditor", scope: detail.scope)
                        ratios(scope: detail.scope, enabled: patch.canResizeAll)
                    case .cartesian:
                        scalarSizing(schema: "CartesianPatchQuickEditor", scope: detail.scope)
                        ratios(scope: detail.scope, enabled: patch.canResizeAll)
                    case .quad:
                        Section("Patch Side Layout") {
                            PatchSideLayoutDiagram(dimensions: patch.dimensions, session: session)
                        }
                        ForEach(patch.dimensions) { dimension in
                            Section(LocalizedStringKey(dimension.title)) {
                                PatchDimensionEditor(scope: detail.scope, dimension: dimension, session: session, store: store)
                            }
                        }
                        if patch.dimensions.isEmpty { Text("Patch side data unavailable").foregroundStyle(.secondary) }
                    case .empty, nil: Text("This region does not contain mesh cells.").foregroundStyle(.secondary)
                    }
                }.formStyle(.grouped).id(detail.scope)
            }
        } else { ContentUnavailableView("Select regions to edit patch sizing.", systemImage: "cursorarrow.click") }
    }
    @ViewBuilder private func scalarSizing(schema: String, scope: String) -> some View {
        Section("Cell Size") {
            ForEach(SourceEditorLibrary.shared.schema(schema)?.fields ?? []) { field in
                SourceField(field: field.inScope(scope), session: session, store: store)
            }
        }
    }
    private func ratios(scope: String, enabled: Bool) -> some View {
        HStack {
            Text("Scale Cell Size")
            Spacer()
            Button("Half") { Task { await session.editPatch(scope: scope, operation: .resizeAll(0.5)) } }
            Button("Double") { Task { await session.editPatch(scope: scope, operation: .resizeAll(2)) } }
        }.disabled(!enabled || !editable)
    }
}

/// A schematic companion to PatchEditor. Labels and dimensions are drawn
/// only from the selected patch's source presentation; the rectangle conveys
/// orientation, not inferred mesh geometry.
struct PatchSideLayoutDiagram: View {
    let dimensions: [PatchDimensionPresentation]
    @ObservedObject var session: ModelEditorSession

    private var northSouth: PatchDimensionPresentation? {
        dimensions.first { dimension in
            let key = (dimension.id + dimension.title).lowercased()
            return key.contains("northsouth") || key.contains("north/south") || key.contains("height")
        }
    }
    private var eastWest: PatchDimensionPresentation? {
        dimensions.first { dimension in
            let key = (dimension.id + dimension.title).lowercased()
            return key.contains("eastwest") || key.contains("east/west") || key.contains("width")
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(spacing: 4) {
                Text("North").font(.caption).foregroundStyle(.secondary)
                RoundedRectangle(cornerRadius: 4)
                    .fill(.quaternary.opacity(0.45))
                    .frame(width: 120, height: 82)
                    .overlay {
                        RoundedRectangle(cornerRadius: 4).strokeBorder(.secondary.opacity(0.65), lineWidth: 1)
                        Image(systemName: "square.grid.3x3")
                            .font(.title2).foregroundStyle(.secondary)
                    }
                Text("South").font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 8) {
                dimensionRow(northSouth, fallback: "North / South")
                dimensionRow(eastWest, fallback: "East / West")
                if dimensions.isEmpty {
                    Text("Patch side dimensions are not supplied.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private func dimensionRow(_ dimension: PatchDimensionPresentation?, fallback: String) -> some View {
        if let dimension {
            let value = session.fields[dimension.valueFieldID]
            let mode = session.fields[dimension.modeFieldID]
            let mismatch = session.fields[dimension.mismatchFieldID] == "true"
            LabeledContent(LocalizedStringKey(dimension.title)) {
                if mismatch {
                    Text("Mixed values").foregroundStyle(.secondary)
                } else if let value, !value.isEmpty {
                    Text([mode, value].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                        .monospacedDigit().textSelection(.enabled)
                } else {
                    Text("Not supplied").foregroundStyle(.tertiary)
                }
            }
        } else {
            LabeledContent(LocalizedStringKey(fallback)) {
                Text("Not supplied").foregroundStyle(.tertiary)
            }
        }
    }
}

struct PatchDimensionEditor: View {
    let scope: String
    let dimension: PatchDimensionPresentation
    @ObservedObject var session: ModelEditorSession
    @ObservedObject var store: WorkspaceStore
    @State private var draft = ""
    @State private var hasDraft = false
    @FocusState private var focused: Bool
    private var mode: String { session.fields[dimension.modeFieldID] ?? "" }
    private var sourceValue: String { session.fields[dimension.valueFieldID] ?? "" }
    private var mixed: Bool { session.fields[dimension.mismatchFieldID] == "true" }
    private var modes: [EditorChoice] { SourceEditorLibrary.shared.schema("QuadPatchQuickEditorDimensionEditor")?.fields.first { $0.id == "SizeFunction" }?.choices ?? [] }
    private var editable: Bool { session.canEdit && !session.isBusy && !session.loadingSelection && !store.isSavingAll }
    private var supportedMode: Bool { mode == "Constant" || mode == "CountWithBias" }
    private var canApply: Bool { dimension.canApply && supportedMode && Double(draft).map(\.isFinite) == true && (mixed || draft != sourceValue) }
    var body: some View {
        Picker("Size Function", selection: Binding(get: { mode }, set: { value in
            Task { await session.editPatch(scope: scope, operation: .setDimensionMode(id: dimension.id, mode: value)) }
        })) {
            if mode.isEmpty { Text("Mixed values").tag("") }
            ForEach(modes) { option in Text(LocalizedStringKey(option.title)).tag(option.id) }
        }.disabled(!editable || !dimension.canChangeMode)
        HStack {
            TextField(LocalizedStringKey(mode == "CountWithBias" ? "Point Count" : "Cell Size"), text: Binding(get: { draft }, set: { draft = $0; hasDraft = true }), prompt: Text(mixed ? "Mixed values" : "—"))
                .focused($focused).onSubmit(apply).onExitCommand { restore(); focused = false }
                .disabled(!editable || !dimension.canApply || !supportedMode)
            Button("Apply", action: apply).disabled(!editable || !canApply)
            Button("Reset", action: restore).disabled(!hasDraft)
        }
        if mixed { Text("The selected sides have different values.").font(.caption).foregroundStyle(.secondary) }
        HStack {
            Spacer()
            Button("Half") { Task { await session.editPatch(scope: scope, operation: .resizeDimension(id: dimension.id, ratio: 0.5)) } }
            Button("Double") { Task { await session.editPatch(scope: scope, operation: .resizeDimension(id: dimension.id, ratio: 2)) } }
        }.disabled(!editable || !dimension.canResize || !supportedMode)
        .onAppear(perform: restore)
        .onChange(of: sourceValue) { _, _ in if !hasDraft { restore() } }
        .onChange(of: mode) { _, _ in restore() }
        .onChange(of: dimension.scope) { _, _ in restore() }
    }
    private func restore() { draft = mixed ? "" : sourceValue; hasDraft = false }
    private func apply() {
        guard editable, canApply else { return }
        let submitted = draft
        Task {
            if await session.editPatch(scope: scope, operation: .applyDimension(id: dimension.id, value: submitted)), draft == submitted { restore(); focused = false }
        }
    }
}
