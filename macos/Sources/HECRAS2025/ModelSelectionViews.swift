import RASWorkspaceCore
import SwiftUI

// TerrainLayersEditor: LayerSourceControl beside the selected input's
// ContextResponsiveView, or TerrainProperties when Full Terrain is selected.
struct TerrainInputsPage: View {
    @ObservedObject var session: ModelEditorSession
    @ObservedObject var store: WorkspaceStore
    @State private var display = "Properties"
    private var sourceField: SourceEditorField? {
        SourceEditorLibrary.shared.schema("TerrainLayersEditor")?.fields.first { $0.id == "SelectedInputWithMap" }
    }
    private var selectedID: String? { sourceField.flatMap { session.fields[$0.storageID] }.flatMap { $0.isEmpty ? nil : $0 } }
    private var selectedDetail: SourceItemPresentation? {
        guard let field = sourceField, let selectedID else { return nil }
        return session.sourceCollections[field.storageID]?.itemDetails[selectedID]
    }
    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                if let field = sourceField {
                    LayerSourceField(field: field, session: session, store: store, fillsHeight: true, title: "Terrain Inputs", overviewTitle: "Full Terrain")
                        .padding(14)
                }
            }.frame(minWidth: 270, idealWidth: 330, maxWidth: 470)
            VStack(spacing: 0) {
                HStack {
                    Picker("View", selection: $display) { Text("Properties").tag("Properties"); Text("Map").tag("Map") }
                        .pickerStyle(.segmented).frame(maxWidth: 240)
                }.padding(12)
                if display == "Map" {
                    TerrainMapPreview(inputID: selectedID, session: session)
                        .id((session.modelAssetID ?? "") + "|" + (selectedID ?? ""))
                } else if session.loadingSelection {
                    ProgressView("Loading properties…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let detail = selectedDetail {
                    TerrainInputDetail(detail: detail, session: session, store: store, mapState: store.activeMapState)
                        .id(detail.scope)
                } else if selectedID != nil {
                    ContentUnavailableView("Layer properties unavailable", systemImage: "square.3.layers.3d")
                } else {
                    SourceForm(page: .form("Full Terrain", "TerrainProperties"), session: session, store: store)
                }
            }

        }
    }
}

private struct TerrainInputDetail: View {
    let detail: SourceItemPresentation
    @ObservedObject var session: ModelEditorSession
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var mapState: MapState
    var body: some View {
        if let error = detail.terrainInfo?.error {
            Label(L10n.text(error), systemImage: "exclamationmark.triangle").foregroundStyle(.red).textSelection(.enabled).padding()
        }
        if detail.schemaIDs == ["ConstantTerrainInput"] {
            ConstantTerrainProperties(detail: detail, session: session)
        } else if detail.schemaIDs.isEmpty, let info = detail.terrainInfo {
            VStack(alignment: .leading, spacing: 12) {
                Text(session.fields[detail.nameFieldID ?? ""] ?? "—").font(.title2)
                LabeledContent("Type", value: info.type)
                Text("Editing this terrain input type is not connected.").foregroundStyle(.secondary)
                Spacer()
            }.padding(20)
        } else if detail.schemaIDs.contains("FunctionalTerrainInputProperties") {
            FunctionalTerrainProperties(detail: detail, session: session, store: store, mapState: mapState)
        } else if detail.schemaIDs == ["RasterTerrainInputProperties"] {
            VStack(spacing: 0) {
                Text("Layer Properties").font(.title2.weight(.semibold)).frame(maxWidth: .infinity, alignment: .leading).padding(20)
                Form {
                    TerrainInputInfo(detail: detail, schema: "RasterTerrainInputProperties", session: session)
                    Section("Raster Information") {
                        RasterOverviewsDisclosure(
                            overviewCount: detail.terrainInfo?.overviewCount,
                            overviews: detail.terrainInfo?.overviews
                        )
                    }
                    if let filename = detail.terrainInfo?.filename {
                        LabeledContent("Source File") { Text(filename).textSelection(.enabled).lineLimit(3).help(filename) }
                    }
                }.formStyle(.grouped)
            }
        } else {
            SourceForm(page: .init(title: "Layer Properties", schemaIDs: detail.schemaIDs, layout: .form, scopePrefix: detail.scope), session: session, store: store)
        }
    }
}

private struct TerrainInputInfo: View {
    let detail: SourceItemPresentation
    let schema: String
    @ObservedObject var session: ModelEditorSession
    var body: some View {
        Section("Info") {
            LabeledContent("Name", value: session.fields[detail.nameFieldID ?? detail.scope + "/" + schema + "/Context_Name"] ?? "—")
            LabeledContent("Type", value: L10n.text(session.fields[detail.scope + "/" + schema + "/Context_TypeName"] ?? "—"))
        }
    }
}

// The original map-extent action belongs inside Valid Extent, so it scrolls
// with that group and remains reachable in compact/detached windows.
private struct FunctionalTerrainProperties: View {
    let detail: SourceItemPresentation
    @ObservedObject var session: ModelEditorSession
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var mapState: MapState
    var body: some View {
        VStack(spacing: 0) {
            Text("Layer Properties").font(.title2.weight(.semibold)).frame(maxWidth: .infinity, alignment: .leading).padding(20)
            Form {
                TerrainInputInfo(detail: detail, schema: "FunctionalTerrainInputProperties", session: session)
                Section("Surface Expression") { input("Context_Expression") }
                Section("Valid Extent") {
                    input("Context_MinX"); input("Context_MaxX"); input("Context_MinY"); input("Context_MaxY")
                    Button("Set to Current Map Extent") {
                        session.useMapExtent(mapState.currentExtent, terrainInputScope: detail.scope)
                    }.buttonStyle(.glass)
                        .disabled(!session.canEdit || session.isBusy || session.loadingSelection || !TerrainExtent.isValid(mapState.currentExtent))
                }
            }.formStyle(.grouped)
        }
    }
    @ViewBuilder private func input(_ id: String) -> some View {
        if let field = SourceEditorLibrary.shared.schema("FunctionalTerrainInputProperties")?.fields.first(where: { $0.id == id }) {
            SourceField(field: field.inScope(detail.scope), session: session, store: store)
        }
    }
}

// AttributeTableDataGrid/PropertySetEditor selection is distinct from the
// selected rows in a filtered/sorted display. The adapter chooses the detail
// editor and binds it to the actual feature/property-set identity.
struct TableSelectionDetail: View {
    let page: ModelEditorPage
    let presentation: TableSelectionPresentation?
    @ObservedObject var session: ModelEditorSession
    @ObservedObject var store: WorkspaceStore
    var showsPatchSizing = true
    @State private var tab = "Properties"
    var body: some View {
        if session.loadingSelection {
            ProgressView("Loading properties…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let presentation, !presentation.rowIDs.isEmpty {
            if let detail = presentation.detail {
                if showsPatchSizing, detail.patch != nil {
                    TabView(selection: $tab) {
                        properties(detail).tabItem { Text("Properties") }.tag("Properties")
                        PatchSizingPage(detail: detail, session: session, store: store).tabItem { Text("Patch Sizing") }.tag("Patch Sizing")
                    }.id(detail.scope)
                } else { properties(detail) }
            } else {
                ContentUnavailableView("Object properties unavailable", systemImage: "slider.horizontal.3")
            }
        } else {
            ContentUnavailableView {
                Label("Select objects to edit their properties.", systemImage: "cursorarrow.click")
            } description: { Text(LocalizedStringKey(page.title)) }
        }
    }
    private func properties(_ detail: SourceItemPresentation) -> some View {
        SourceForm(page: .init(title: "Selected Object Properties", schemaIDs: detail.schemaIDs, layout: .form, scopePrefix: detail.scope), session: session, store: store).id(detail.scope)
    }
}

enum TerrainExtent {
    static func isValid(_ extent: ViewportRequest?) -> Bool {
        guard let extent else { return false }
        return [extent.lowerLeft.x, extent.lowerLeft.y, extent.upperRight.x, extent.upperRight.y].allSatisfy(\.isFinite)
            && extent.lowerLeft.x < extent.upperRight.x && extent.lowerLeft.y < extent.upperRight.y
    }
}
extension ModelEditorSession {
    @discardableResult
    func useMapExtent(_ extent: ViewportRequest?, terrainInputScope: String) -> Bool {
        guard canEdit, !isBusy, !loadingSelection, TerrainExtent.isValid(extent), let extent else { return false }
        let scope = terrainInputScope + "/FunctionalTerrainInputProperties/Context_"
        set(scope + "MinX", String(extent.lowerLeft.x)); set(scope + "MaxX", String(extent.upperRight.x))
        set(scope + "MinY", String(extent.lowerLeft.y)); set(scope + "MaxY", String(extent.upperRight.y))
        return true
    }
}
