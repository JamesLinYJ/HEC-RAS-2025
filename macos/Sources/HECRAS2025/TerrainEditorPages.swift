import RASWorkspaceCore
import SwiftUI

// Raster, levee and channel editors own different contexts in the original UI.
// Keeping them in separate tabs prevents similarly named fields being conflated.
struct TerrainModificationsPage: View {
    @ObservedObject var session: ModelEditorSession
    @ObservedObject var store: WorkspaceStore
    var body: some View {
        TerrainModificationWorkbench(session: session, store: store)
    }
}

struct ConstantTerrainProperties: View {
    let detail: SourceItemPresentation
    @ObservedObject var session: ModelEditorSession
    private var prefix: String { detail.scope + "/ConstantTerrainInput/Context_" }
    var body: some View {
        Form {
            Section("Info") {
                LabeledContent("Name", value: session.fields[detail.nameFieldID ?? ""] ?? "—")
                LabeledContent("Type", value: L10n.text(detail.terrainInfo?.type ?? "Constant"))
            }
            Section("Elevation") { input("Value", title: "Value") }
            Section("Valid Extent") {
                input("MinX", title: "Min X"); input("MaxX", title: "Max X")
                input("MinY", title: "Min Y"); input("MaxY", title: "Max Y")
            }
        }.formStyle(.grouped).disabled(!session.canEdit || session.isBusy || session.loadingSelection)
    }
    private func input(_ property: String, title: String) -> some View {
        TextField(LocalizedStringKey(title), text: Binding(get: { session.fields[prefix + property] ?? "" }, set: { session.set(prefix + property, $0) }))
            .textFieldStyle(.roundedBorder)
    }
}

struct TerrainMapPreview: View {
    let inputID: String?
    @ObservedObject var session: ModelEditorSession
    @State private var data: TerrainMapData?
    @State private var loading = false
    @State private var error: String?
    private var preview: DataToolPreview {
        var rasters: [MapRasterLayer] = []
        if let terrain = data?.raster, let layer = try? terrain.presentation(name: "Full Terrain").rasters.first { rasters.append(layer) }
        if let selected = data?.selectedRaster, let layer = try? selected.presentation(name: "Selected Terrain Input").rasters.first { rasters.append(layer) }
        return .init(rasters: rasters)
    }
    private var selectedName: String {
        guard let inputID else { return "Full Terrain" }
        return session.sourceCollections[TerrainEditorContract.sourceField]?.items.first(where: { $0.id == inputID })?.title ?? "Selected Terrain Input"
    }
    private var selectedMapRowIDs: Set<String> {
        guard let tableID = data?.features?.first?.tableId,
              let rowIDs = session.tablePresentations[tableID]?.selection?.rowIDs else { return [] }
        return Set(rowIDs)
    }
    var body: some View {
        VStack(spacing: 0) {
            if let error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).textSelection(.enabled).padding(12) }
            TerrainFeatureMapCanvas(
                rasters: preview.rasters,
                features: data?.features ?? [],
                selectedRowIDs: selectedMapRowIDs,
                loading: loading,
                onSelect: { feature in
                    Task { _ = await session.perform(.selectTableRows(table: feature.tableId, ids: [feature.id])) }
                }
            )
            if data?.raster != nil || data?.selectedRaster != nil {
                HStack(spacing: 16) {
                    Label("Full Terrain", systemImage: "square.fill").foregroundStyle(.secondary)
                    if inputID != nil { Label(selectedName, systemImage: "square.fill").foregroundStyle(.blue) }
                    Spacer()
                    if let selected = data?.selectedRaster {
                        Text("Selected Range")
                        Text(selected.minimum?.formatted() ?? "—")
                        Text("…")
                        Text(selected.maximum?.formatted() ?? "—")
                    }
                }.padding(12)
            }
            Text("Preview uses the source terrain coordinate system.").font(.caption).foregroundStyle(.secondary).padding(8)
        }
        .task(id: session.terrainMapIdentity) {
            // Never leave a previous source revision visible as though it were
            // the current terrain when a refresh is cancelled or rejected.
            data = nil
            error = nil
            guard !session.isBusy else { loading = false; return }
            loading = true
            do {
                let result = try await session.terrainMap(inputID: inputID)
                try Task.checkCancellation()
                guard result.inputId == inputID, result.sourceRevision == session.terrainSourceRevision else { throw CancellationError() }
                data = result
                error = nil
            }
            catch { if !Task.isCancelled { self.error = L10n.text(error.localizedDescription) } }
            if !Task.isCancelled { loading = false }
        }
    }
}
