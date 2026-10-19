import SwiftUI

// ManningsNEditor.AvailableNValueSources exposes Constant and ClassificationLayer.
// ImportedRaster/Debug values may exist in a file but are not offered as new modes.
struct ManningEditorPage: View {
    nonisolated static let tableID = "ClassificationLayerManningNEditor/InterpretationTable"
    @ObservedObject var session: ModelEditorSession
    @ObservedObject var store: WorkspaceStore
    @State private var selection: Set<String> = []
    @State private var query = ""
    private let modeID = "ManningsNEditor/NValueLayer_Mode"
    private let classificationID = "ClassificationLayerManningNEditor/NValueLayer_ClassificationLayer"
    private var mode: String { session.fields[modeID] ?? "" }
    private var rows: [EditorRow] { (session.rows[Self.tableID] ?? []).filter { query.isEmpty || ($0.values["Key"] ?? "").localizedCaseInsensitiveContains(query) } }
    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Manning’s n") {
                    Picker("Mode", selection: Binding(get: { mode }, set: { setSelection(modeID, $0) })) {
                        Text("Constant").tag("Constant")
                        Text("Classification Layer").tag("ClassificationLayer")
                        if !["Constant", "ClassificationLayer"].contains(mode) {
                            Text(L10n.text(SourceEditorLibrary.shared.schema("ManningsNEditor")?.fields.first?.choices.first(where: { $0.id == mode })?.title ?? (mode.isEmpty ? "None" : mode))).tag(mode)
                        }
                    }.disabled(!session.canEdit || session.fields[modeID] == nil)
                    if mode == "Constant" {
                        SchemaFields(schema: "ConstantManningsNEditor", session: session, store: store)
                        Text("Recommended Manning’s n range: 0.009–0.15.").font(.caption).foregroundStyle(.secondary)
                    } else if mode == "ClassificationLayer" {
                        Picker("Classification Layer", selection: Binding(get: { session.fields[classificationID] ?? "" }, set: { setSelection(classificationID, $0) })) {
                            Text("None").tag("")
                            ForEach(session.choiceOptions[classificationID] ?? []) { item in Text(item.title).tag(item.id) }
                            if let current = session.fields[classificationID], !current.isEmpty,
                               !(session.choiceOptions[classificationID] ?? []).contains(where: { $0.id == current }) { Text(current.hasPrefix("missing:") ? String(current.dropFirst(8)) + " (" + L10n.text("Missing") + ")" : current).tag(current) }
                        }.disabled(!session.canEdit || session.fields[classificationID] == nil)
                    }
                    ForEach(session.textSuggestions["ManningWarning"] ?? [], id: \.self) { warning in
                        Label(L10n.text(warning), systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                    }
                }
            }.formStyle(.grouped).fixedSize(horizontal: false, vertical: true)
            if mode == "ClassificationLayer" {
                Divider()
                HStack {
                    Text("Classification Map").font(.headline)
                    TextField("Filter classifications", text: $query).textFieldStyle(.roundedBorder).frame(maxWidth: 240)
                    Spacer()
                    Button("Set NLCD") { Task { await session.perform(.setDefaultNValues) } }
                        .disabled(!session.canEdit || !session.availableOperations.contains(.setDefaultNValues))
                }.padding(12)
                if session.rows[Self.tableID] == nil {
                    Label("The original model adapter for this tool is unavailable.", systemImage: "externaldrive.badge.questionmark")
                        .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12)
                }
                Table(rows, selection: $selection) {
                    TableColumn(L10n.text("Classification")) { row in Text(row.values["Key"] ?? "").textSelection(.enabled) }
                    TableColumn(L10n.text("Manning’s n")) { row in
                        TableCell(column: .init(id: "Value", title: "Manning’s n", sourceType: "float"), rowID: row.id, tableID: Self.tableID, session: session, store: store)
                    }
                }
            } else { Spacer(minLength: 0) }
        }
        .disabled(session.isBusy || session.loadingSelection)
        .onChange(of: session.modelAssetID) { _, _ in selection = []; query = "" }
        .onChange(of: session.rows[Self.tableID]?.map(\.id)) { _, ids in selection.formIntersection(ids ?? []) }
    }
    private func setSelection(_ field: String, _ value: String) {
        guard session.fields[field] != value else { return }
        session.set(field, value)
        Task { await session.perform(.refreshManning) }
    }
}


struct SurfaceOverviewPage: View {
    @ObservedObject var session: ModelEditorSession
    @ObservedObject var store: WorkspaceStore
    var body: some View {
        Form {
            if session.fields["NValueCatalogSummary/Context_Name"] != nil {
                Section("Manning Layer Information") { SchemaFields(schema: "NValueCatalogSummary", session: session, store: store) }
            } else if session.fields["ClassificationCatalogSummary/Context_Name"] != nil {
                Section("Classification Layer Information") { SchemaFields(schema: "ClassificationCatalogSummary", session: session, store: store) }
            } else {
                ContentUnavailableView("Model data unavailable", systemImage: "square.3.layers.3d")
            }
        }.formStyle(.grouped)
    }
}
