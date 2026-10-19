import SwiftUI

// PrecipitationEditor and the point/grid spatial controls combine source input
// selection, its scoped properties, raster bands, a map and actual timesteps.
struct SpatialDatasetPage: View {
    let layer: SpatialBoundaryLayer
    @ObservedObject var session: ModelEditorSession
    @ObservedObject var store: WorkspaceStore
    var showsPointEditor = true
    var requestImport: ((ToolKind) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var display = "Map"
    @State private var showGridImport = false
    private var presentation: SpatialDatasetPresentation { session.spatialPresentations[layer.id] ?? .init() }
    private var gridImportAvailable: Bool { presentation.gridData != nil && layer.selectedType(in: session.fields) == "Gridded" }
    private var sourceField: SourceEditorField? {
        if let id = presentation.sourceFieldID, let field = SourceEditorLibrary.shared.field(storageID: id) {
            return id == field.storageID ? field : field.inScope(String(id.dropLast(field.storageID.count + 1)))
        }
        return layer == .precipitation ? SourceEditorLibrary.shared.schema("PrecipitationEditor")?.fields.first : nil
    }
    private var selectedDetail: SourceItemPresentation? {
        guard let field = sourceField, let selected = session.fields[field.storageID] else { return nil }
        return session.sourceCollections[field.storageID]?.itemDetails[selected]
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(LocalizedStringKey(layer.title), systemImage: layer.symbol).font(.title2.weight(.semibold))
                Spacer()
                Button("Save") { Task { await session.saveLoadedModel() } }.disabled(!session.canEdit || session.isBusy || !session.hasUnsavedEditorChanges)
                Button("Import…") {
                    if presentation.gridData != nil, layer.selectedType(in: session.fields) == "Gridded" { showGridImport = true }
                    else { requestImport?(presentation.importTool) }
                }
                    .disabled(!session.canEdit || session.isBusy || !(gridImportAvailable || presentation.canImport && store.toolProvider != nil && requestImport != nil))
                Button("Close", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(16)
            Divider()
            if showsPointEditor, let data = presentation.pointData, layer.selectedType(in: session.fields) == "Point" {
                SpatialPointEditor(layer: layer, data: data, session: session, store: store)
            } else if presentation.gridData != nil, layer.selectedType(in: session.fields) == "Gridded" {
                SpatialGridDatasetView(layer: layer, session: session)
            } else { HSplitView {
                VStack(spacing: 0) {
                    if let sourceField {
                        LayerSourceField(field: sourceField, session: session, store: store, fillsHeight: true, title: "Input Layers", overviewTitle: "View All").padding(12)
                    } else {
                        BoundarySpatialInputPanel()
                    }
                    if let detail = selectedDetail {
                        Divider()
                        SourceForm(page: .init(title: "Layer Properties", schemaIDs: detail.schemaIDs, layout: .form, scopePrefix: detail.scope), session: session, store: store)
                            .frame(minHeight: 170, maxHeight: 300)
                    }
                }.frame(minWidth: 260, idealWidth: 320, maxWidth: 430)
                VStack(spacing: 0) {
                    Picker("View", selection: $display) {
                        Text("Map").tag("Map"); Text("Table").tag("Table")
                        Text("Chart").tag("Chart")
                    }.pickerStyle(.segmented).frame(maxWidth: 310).padding(12)
                    if display == "Table", let tableID = presentation.tableID {
                        DataToolBandTable(editor: session, store: store, tableID: tableID)
                    } else if display == "Table" {
                        BoundarySpatialPlaceholderTable()
                    } else if display == "Chart" {
                        TimeSeriesPage(page: presentation.seriesPage ?? .init(title: "Time Series", schemaIDs: [], layout: .timeSeries), session: session, store: store, chartOnly: true)
                    } else if display == "Map" {
                        DataToolPreviewView(preview: presentation.preview, loading: session.loadingSelection, isCurrent: !session.loadingSelection)
                    }
                    SpatialDatasetTimeline(layerID: layer.id, presentation: presentation, session: session)
                }.frame(minWidth: 420)
            } }
            if let error = session.error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).textSelection(.enabled).padding(12) }
        }
        .sheet(isPresented: $showGridImport) {
            SpatialGridImportSheet(layer: layer, session: session, store: store, openCumulusImporter: {
                requestImport?(.griddedImport)
            })
        }
    }
}

struct SpatialDatasetTimeline: View {
    let layerID: String
    let presentation: SpatialDatasetPresentation
    @ObservedObject var session: ModelEditorSession
    private var selectedIndex: Int? { presentation.timeSteps.firstIndex { $0.id == presentation.selectedTimeStepID } }
    private var canSelect: Bool { presentation.canSelectTime && !session.isBusy && !session.loadingSelection }
    var body: some View {
        VStack(spacing: 10) {
            Picker("Current Timestep", selection: Binding(get: { presentation.selectedTimeStepID }, set: select)) {
                Text("None").tag(String?.none)
                ForEach(presentation.timeSteps) { step in Text(step.title).tag(Optional(step.id)) }
            }.disabled(!canSelect || presentation.timeSteps.isEmpty)
            HStack {
                Button { move(-1) } label: { Label("Previous Timestep", systemImage: "chevron.left") }.disabled(!canSelect || selectedIndex == nil || selectedIndex == 0)
                Slider(value: Binding(get: { Double(selectedIndex ?? 0) }, set: { index in
                    let value = Int(index.rounded()); guard presentation.timeSteps.indices.contains(value) else { return }
                    select(presentation.timeSteps[value].id)
                }), in: 0...Double(max(1, presentation.timeSteps.count - 1)), step: 1) { Text("Timeline") }
                    .disabled(!canSelect || selectedIndex == nil || presentation.timeSteps.count < 2)
                Button { move(1) } label: { Label("Next Timestep", systemImage: "chevron.right") }.disabled(!canSelect || selectedIndex == nil || selectedIndex == presentation.timeSteps.count - 1)
            }.labelStyle(.iconOnly)
        }.padding(14)
    }
    private func select(_ id: String?) { Task { await session.perform(.selectSpatialTime(layerID: layerID, stepID: id)) } }
    private func move(_ delta: Int) {
        guard let index = selectedIndex, presentation.timeSteps.indices.contains(index + delta) else { return }
        select(presentation.timeSteps[index + delta].id)
    }
}
