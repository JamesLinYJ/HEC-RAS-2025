import SwiftUI

enum ClassificationImportKind: Sendable { case shapefile, generic }

// ClassificationVectorImporter: imported layers have their own source-bound
// options. ClassificationLayersEditor belongs to the model editor instead.
struct ClassificationImportContent: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var state: DataToolSession
    @ObservedObject var editor: ModelEditorSession
    let current: Bool
    private var selected: DataToolLayer? { state.presentation.layers.first { $0.id == state.selectedSettingsLayerID } }
    var body: some View {
        HSplitView {
            VSplitView {
                VStack(spacing: 0) {
                    DataFileList(state: state, store: store, changed: {})
                    Divider(); DataLayerList(title: "Importing Layers", state: state)
                }.frame(minHeight: 220)
                Form {
                    if let layer = selected, let scope = layer.scope {
                        Section {
                            Text(layer.name).font(.headline).textSelection(.enabled)
                            switch layer.classificationKind {
                            case .shapefile:
                                Picker("Classification Column", selection: text(scope, "ShapefileColumn")) {
                                    Text("None").tag("")
                                    ForEach(editor.choiceOptions[scope + "/ClassificationVectorImporter/ShapefileColumn"] ?? []) { choice in
                                        Text(choice.title).tag(choice.id)
                                    }
                                }
                            case .generic:
                                TextField("Default Classification", text: text(scope, "DefaultClassification"))
                                    .textInputSuggestions {
                                        ForEach(editor.textSuggestions[scope + "/ClassificationVectorImporter/DefaultClassification"] ?? [], id: \.self) { value in Text(value).textInputCompletion(value) }
                                    }
                            case nil: Text("Select a classification source.").foregroundStyle(.secondary)
                            }
                        }
                    } else { Section { Text("Select a layer to edit its import settings.").foregroundStyle(.secondary) } }
                }.formStyle(.grouped).frame(minHeight: 170).disabled(!editor.canEdit)
            }.frame(minWidth: 300, idealWidth: 350, maxWidth: 470)
            DataToolPreviewView(preview: state.presentation.preview, loading: state.preparing, isCurrent: current)
        }
    }
    private func text(_ scope: String, _ id: String) -> Binding<String> {
        let key = scope + "/ClassificationVectorImporter/" + id
        return Binding(get: { editor.fields[key] ?? "" }, set: { editor.set(key, $0) })
    }
}

struct SourceItemPresentation: Sendable {
    let scope: String
    let schemaIDs: [String]
    var polygons: PolygonClassificationsPresentation? = nil
    // The adapter supplies the real object's Name binding for inline rename.
    var nameFieldID: String? = nil
    var flowArea: FlowAreaPresentation? = nil
    var patch: PatchEditorPresentation? = nil
    var classificationInfo: ClassificationInputInfo? = nil
    var terrainInfo: TerrainInputMetadata? = nil
    func validate() throws {
        try flowArea?.validate()
        try patch?.validate(scope: scope)
    }
}
struct PolygonClassificationItem: Identifiable, Sendable {
    let id: String
    let scope: String
    let classification: String
    var vertexCount: Int? = nil
    var vertices: [ClassificationVertex] = []
    var hasZ = false
    var hasM = false
    var fieldID: String { scope + "/PolygonClassificationInputProperties/ClassifierMod_Classification" }
}
struct PolygonClassificationsPresentation: Sendable {
    let items: [PolygonClassificationItem]
    let selectedIDs: Set<String>
    var canSelect = false
}

struct ClassificationLayersPage: View {
    @ObservedObject var session: ModelEditorSession
    @ObservedObject var store: WorkspaceStore
    @State private var display = "Properties"
    private var sourceField: SourceEditorField? { SourceEditorLibrary.shared.schema("ClassificationLayersEditor")?.fields.first { $0.id == "ClassificationLayer_SelectedClassificationInput" } }
    private var selectedDetail: SourceItemPresentation? {
        guard let field = sourceField, let id = session.fields[field.storageID] else { return nil }
        return session.sourceCollections[field.storageID]?.itemDetails[id]
    }
    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 0) {
                if let field = sourceField { LayerSourceField(field: field, session: session, store: store, fillsHeight: true).padding(14) }
            }.frame(minWidth: 270, idealWidth: 330, maxWidth: 470)
            VStack(spacing: 0) {
                Picker("View", selection: $display) { Text("Properties").tag("Properties"); Text("Map").tag("Map") }.pickerStyle(.segmented).frame(maxWidth: 240).padding(10)
                if display == "Map" {
                    ClassificationMapView(session: session, store: store)
                } else if session.loadingSelection {
                ProgressView("Loading properties…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let detail = selectedDetail {
                if let polygons = detail.polygons, let field = sourceField {
                    PolygonClassificationsView(
                        presentation: polygons,
                        sourceFieldID: field.storageID,
                        sourceItemScope: detail.scope,
                        inputID: session.fields[field.storageID],
                        session: session,
                        store: store
                    )
                        .id(detail.scope)
                } else {
                    VStack(spacing: 0) {
                        if let info = detail.classificationInfo {
                            VStack(alignment: .leading, spacing: 12) {
                                if let file = info.filename {
                                    LabeledContent("Source File") {
                                        Text(file).lineLimit(2).truncationMode(.middle).textSelection(.enabled).help(file)
                                    }
                                }
                                if let extent = info.extent { LabeledContent("Extent", value: extent).textSelection(.enabled) }
                                if let field = info.valueFieldID {
                                    TextField("Classification", text: Binding(get: { session.fields[field] ?? "" }, set: { session.set(field, $0) })).disabled(!session.canEdit || session.isBusy)
                                }
                            }.padding(16)
                        }
                        if !detail.schemaIDs.isEmpty { SourceForm(page: .init(title: "Layer Properties", schemaIDs: detail.schemaIDs, layout: .form, scopePrefix: detail.scope), session: session, store: store) }
                        else { Spacer() }
                    }
                }
            } else if sourceField.flatMap({ session.fields[$0.storageID] }).map({ !$0.isEmpty }) == true {
                ContentUnavailableView("Layer properties unavailable", systemImage: "square.3.layers.3d")
            } else if session.sourceCollections[ClassificationEditorContract.sourceField] != nil {
                SourceForm(page: .form("All Layers", "ClassificationLayerSummary"), session: session, store: store)
            } else {
                ContentUnavailableView("Select a classification layer", systemImage: "square.3.layers.3d", description: Text("Choose a classification model from the surface layer picker."))
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct PolygonClassificationsView: View {
    let presentation: PolygonClassificationsPresentation
    let sourceFieldID: String
    let sourceItemScope: String
    let inputID: String?
    @ObservedObject var session: ModelEditorSession
    @ObservedObject var store: WorkspaceStore
    @State private var selection: Set<String> = []
    @State private var editingPolygon: ClassificationMapPolygon?
    @State private var pendingDeleteIDs: Set<String> = []
    @State private var showingDeleteConfirmation = false
    private var geometryAvailable: Bool {
        session.sourceCollections[sourceFieldID]?.classificationTools != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Polygons").font(.title2)
                Spacer()
                Text(L10n.format("%d polygons", presentation.items.count))
                    .font(.caption).foregroundStyle(.secondary)
                ClassificationPasteFeaturesButton(inputID: inputID, session: session, store: store)
                if !selection.isEmpty {
                    Button("Delete Selected", systemImage: "trash", role: .destructive) {
                        pendingDeleteIDs = selection
                        showingDeleteConfirmation = true
                    }
                    .disabled(inputID == nil || !geometryAvailable || !session.canEdit || session.isBusy)
                }
            }
            .padding([.top, .horizontal], 20)
            List(selection: Binding(get: { selection }, set: { ids in
                guard presentation.canSelect else { return }
                selection = ids
                Task { await session.perform(.selectPolygonClassifications(field: sourceFieldID, scope: sourceItemScope, ids: ids)) }
            })) {
                ForEach(presentation.items) { item in
                    HStack {
                    DoubleClickText(title: "Classification", text: Binding(get: { session.fields[item.fieldID] ?? item.classification }, set: { session.set(item.fieldID, $0) }), prompt: Text("Classification"), suggestions: session.textSuggestions[item.fieldID] ?? [], showsLabel: false)
                        .disabled(!session.canEdit || session.isBusy)
                    if let count = item.vertexCount { Text(L10n.format("%d vertices", count)).font(.caption).foregroundStyle(.secondary) }
                    }.tag(item.id)
                        .contextMenu {
                            Button("Select Polygon") { select(item) }
                                .disabled(!presentation.canSelect)
                            Button("Edit Vertices…") {
                                guard let inputID else { return }
                                editingPolygon = ClassificationMapPolygon(
                                    inputID: inputID,
                                    inputScope: sourceItemScope,
                                    item: item
                                )
                            }
                            .disabled(inputID == nil || !geometryAvailable || !session.canEdit || session.isBusy)
                            Button("Delete Polygon", role: .destructive) {
                                pendingDeleteIDs = [item.id]
                                showingDeleteConfirmation = true
                            }
                            .disabled(inputID == nil || !geometryAvailable || !session.canEdit || session.isBusy)
                        }
                }
            }
        }.onAppear { selection = presentation.selectedIDs }
            .onChange(of: presentation.selectedIDs) { _, ids in selection = ids }
            .sheet(item: $editingPolygon) { polygon in
                PolygonVerticesSheet(polygon: polygon, inputID: polygon.inputID, session: session, store: store)
            }
            .confirmationDialog("Delete Polygon", isPresented: $showingDeleteConfirmation, titleVisibility: .visible) {
                Button("Delete Polygon", role: .destructive) { deletePendingPolygons() }
                Button("Cancel", role: .cancel) { pendingDeleteIDs = [] }
            } message: {
                Text(L10n.format("Delete %d selected polygon(s)?", pendingDeleteIDs.count))
            }
    }

    private func select(_ item: PolygonClassificationItem) {
        guard presentation.canSelect else { return }
        selection = [item.id]
        Task {
            await session.perform(.selectPolygonClassifications(
                field: sourceFieldID,
                scope: sourceItemScope,
                ids: [item.id]
            ))
        }
    }

    private func deletePendingPolygons() {
        guard let inputID, geometryAvailable, !pendingDeleteIDs.isEmpty else { return }
        let ids = pendingDeleteIDs.sorted()
        Task {
            if await session.perform(.editClassificationGeometry(.init(
                operation: "delete",
                inputId: inputID,
                polygonIds: ids
            ))) {
                selection.subtract(ids)
            }
            pendingDeleteIDs = []
        }
    }
}
