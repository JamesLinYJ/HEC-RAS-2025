import AppKit
import SwiftUI

// RasterClassificationInputProperties embeds this table. The source Key getter
// is immutable, and its RowsCollectionChanged throws for inserted/deleted rows.
struct ClassificationMappingField: View {
    let field: SourceEditorField
    @ObservedObject var session: ModelEditorSession
    @State private var selection: Set<String> = []
    @State private var filter = ""
    private var rows: [EditorRow] { session.rows[field.storageID] ?? [] }
    private var visible: [EditorRow] { rows.filter { filter.isEmpty || ($0.values["Key"] ?? "").localizedCaseInsensitiveContains(filter) || ($0.values["Value"] ?? "").localizedCaseInsensitiveContains(filter) } }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { TextField("Filter classifications", text: $filter).textFieldStyle(.roundedBorder); Spacer(); Text("Classification IDs are read-only.").font(.caption).foregroundStyle(.secondary) }
            if session.rows[field.storageID] == nil {
                Label("The original model adapter for this tool is unavailable.", systemImage: "externaldrive.badge.questionmark")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Table(visible, selection: $selection) {
                TableColumn(L10n.text("ID")) { row in Text(row.values["Key"] ?? "").textSelection(.enabled) }.width(min: 70, ideal: 90, max: 160)
                TableColumn(L10n.text("Name")) { row in
                    if session.canEdit && !session.isBusy && !session.loadingSelection {
                        TextField("Name", text: Binding(get: {
                            session.rows[field.storageID]?.first { $0.id == row.id }?.values["Value"] ?? ""
                        }, set: { session.setCell(table: field.storageID, rowID: row.id, column: "Value", value: $0) }))
                            .textFieldStyle(.plain)
                    } else { Text(row.values["Value"] ?? "").textSelection(.enabled) }
                }
            }.frame(minHeight: 300, idealHeight: 360, maxHeight: 500)
            .onChange(of: session.modelAssetID) { _, _ in selection = [] }
            .onChange(of: field.storageID) { _, _ in selection = []; filter = "" }
            .onChange(of: visible.map(\.id)) { _, ids in selection.formIntersection(ids) }
            .onCopyCommand {
                let selected = visible.filter { selection.contains($0.id) }
                guard !selected.isEmpty else { return [] }
                func escaped(_ value: String) -> String {
                    value.contains(where: { $0 == "\t" || $0.isNewline || $0 == "\"" }) ? "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : value
                }
                let header = [L10n.text("ID"), L10n.text("Name")].map(escaped).joined(separator: "\t")
                let text = ([header] + selected.map { [escaped($0.values["Key"] ?? ""), escaped($0.values["Value"] ?? "")].joined(separator: "\t") }).joined(separator: "\n")
                return [NSItemProvider(object: text as NSString)]
            }
        }
    }
}
