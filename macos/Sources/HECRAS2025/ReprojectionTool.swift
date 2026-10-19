import SwiftUI

struct ToolProjectionMatch: Identifiable, Sendable {
    let id: String
    let title: String
    let code: String
}

struct ReprojectionContent: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var state: DataToolSession
    @ObservedObject var editor: ModelEditorSession
    let current: Bool
    let toolAdapterAvailable: Bool
    let reproject: () -> Void
    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                ReprojectionDefinition(store: store, editor: editor, side: "Source")
                Divider()
                Table(state.coordinates) {
                    TableColumn("X") { (row: ToolCoordinateRow) in coordinateCell(row, x: true) }
                    TableColumn("Y") { (row: ToolCoordinateRow) in coordinateCell(row, x: false) }
                }
                HStack {
                    Button("Add Rows") {
                        state.coordinates += (0..<5).map { _ in .init(id: UUID().uuidString, x: "", y: "") }
                    }
                    Spacer()
                }.padding(12)
            }.frame(minWidth: 320, maxWidth: .infinity)
            VStack { Spacer(); Image(systemName: "arrow.right").font(.title2).foregroundStyle(.secondary); Spacer() }.frame(width: 44)
            VStack(spacing: 0) {
                ReprojectionDefinition(store: store, editor: editor, side: "Dest")
                Divider()
                Table(destinationRows) {
                    TableColumn("X") { (row: ToolCoordinateRow) in Text(row.x).textSelection(.enabled) }
                    TableColumn("Y") { (row: ToolCoordinateRow) in Text(row.y).textSelection(.enabled) }
                }
                HStack { Spacer(); Button("Reproject", action: reproject).disabled(state.busy || !toolAdapterAvailable) }.padding(12)
            }.frame(minWidth: 320, maxWidth: .infinity)
        }
        .onAppear {
            if state.coordinates.isEmpty { state.coordinates = (0..<10).map { _ in .init(id: UUID().uuidString, x: "", y: "") } }
        }
    }
    private var destinationRows: [ToolCoordinateRow] {
        // Stale results are cleared visually as soon as coordinates/definitions
        // change; the UI never transforms coordinates itself.
        let requested = state.coordinates.map(\.id)
        guard current else { return requested.map { .init(id: $0, x: "", y: "") } }
        let results = Dictionary(state.presentation.destinationRows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return requested.map { results[$0] ?? .init(id: $0, x: "", y: "") }
    }
    private func coordinateCell(_ row: ToolCoordinateRow, x: Bool) -> some View {
        TextField(x ? "X" : "Y", text: Binding(get: {
            let value = state.coordinates.first { $0.id == row.id }
            return (x ? value?.x : value?.y) ?? ""
        }, set: { value in
            guard let index = state.coordinates.firstIndex(where: { $0.id == row.id }) else { return }
            if x { state.coordinates[index].x = value } else { state.coordinates[index].y = value }
        })).textFieldStyle(.plain)
    }
}

private struct ReprojectionDefinition: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var editor: ModelEditorSession
    let side: String
    @State private var searching = false
    @State private var error: String?
    private var optionID: String { "ViewModel_" + side + "ProjectionOption" }
    private var customID: String { "ViewModel_" + side + "CustomProjectionText" }
    private var isCustom: Bool { editor.fields["ReprojectionToolControl/" + optionID] == "Custom" }
    var body: some View {
        Form {
            Section(LocalizedStringKey(side == "Source" ? "Source" : "Destination (Read-Only)")) {
                DataToolField(schema: "ReprojectionToolControl", id: optionID, editor: editor, store: store)
                if isCustom {
                    DataToolField(schema: "ReprojectionToolControl", id: customID, editor: editor, store: store)
                    HStack {
                        Button("Search EPSG…") { searching = true }.disabled(store.projectionProvider == nil)
                            .sheet(isPresented: $searching) {
                                ProjectionSearchView(provider: store.projectionProvider) { match in
                                    editor.set("ReprojectionToolControl/" + customID, String(match.code)); searching = false
                                }
                            }
                        Button("Read PRJ File…") { if let url = store.system.chooseProjectionFile() { readProjection(url) } }
                    }
                    Text("Drop a projection file here.").font(.caption).foregroundStyle(.secondary)
                        .dropDestination(for: URL.self) { files, _ in
                            guard let url = files.first, url.isFileURL else { return false }; readProjection(url); return true
                        }
                }
                ForEach([("Validity", "IsValidString"), ("Units", "UnitName"), ("EPSG Code", "EpsgCode"), ("UTM Zone", "UtmZone")], id: \.1) { title, id in
                    LabeledContent(LocalizedStringKey(title), value: editor.fields[side + "/ProjectionSummary/" + id] ?? "—").textSelection(.enabled)
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
        }.formStyle(.grouped).frame(height: isCustom ? 360 : 245)
    }
    private func readProjection(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            guard (values.fileSize ?? 0) <= 4 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
            editor.set("ReprojectionToolControl/" + customID, try String(contentsOf: url, encoding: .utf8)); error = nil
        } catch { self.error = error.localizedDescription }
    }
}

