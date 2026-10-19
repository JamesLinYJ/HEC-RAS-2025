import SwiftUI

extension SourceEditorField {
    var isTimeWindowField: Bool {
        sourceSetter.contains("_TimeWindow_StartTime") || sourceSetter.contains("_TimeWindow_EndTime") ||
        sourceSetter.contains("_TimeWindowGroup_StartTime") || sourceSetter.contains("_TimeWindowGroup_EndTime")
    }
}

// Used by both complete editor forms and embedded source sections so pairing
// does not disappear when a source control is embedded in another page.
struct SourceFieldRows: View {
    let fields: [SourceEditorField]
    @ObservedObject var session: ModelEditorSession
    @ObservedObject var store: WorkspaceStore
    private struct Row: Identifiable {
        let fields: [SourceEditorField]
        var id: String { fields[0].storageID }
    }
    private var rows: [Row] {
        var used: Set<String> = []
        return fields.compactMap { field in
            guard !used.contains(field.storageID) else { return nil }
            let members: [SourceEditorField]
            if let radio = field.radioBinding {
                members = fields.filter { $0.scope == field.scope && $0.radioBinding?.route == radio.route }
            } else if field.isTimeWindowField {
                members = fields.filter { $0.scope == field.scope && $0.isTimeWindowField }
            } else if ["InputDoubleStringPropertyItem_", "DoubleTextPropertyItem_", "RadioButtonInputTextPropertyItem_", "SpatialDataHeader_"].contains(where: field.sourceSetter.contains) {
                members = fields.filter { $0.scope == field.scope && $0.sourceControl == field.sourceControl }
            } else { members = [field] }
            used.formUnion(members.map(\.storageID))
            return Row(fields: members)
        }
    }
    var body: some View {
        ForEach(rows) { row in
            Group {
                if row.fields.first?.radioBinding != nil {
                    RadioInputGroup(fields: row.fields, session: session, store: store)
                } else if row.fields.count > 1, row.fields.allSatisfy(\.isTimeWindowField) {
                    OriginalTimeWindowGroup(fields: row.fields, session: session)
                } else if row.fields.count > 1, row.fields.allSatisfy({ $0.sourceSetter.contains("InputDoubleStringPropertyItem_") || $0.sourceSetter.contains("DoubleTextPropertyItem_") }) {
                    OriginalDoubleStringPropertyItem(fields: row.fields, session: session)
                } else if row.fields.count > 1 {
                    HStack(alignment: .firstTextBaseline, spacing: 16) {
                        ForEach(row.fields) { field in
                            SourceField(field: field, session: session, store: store).frame(maxWidth: .infinity)
                        }
                    }
                } else if let field = row.fields.first {
                    SourceField(field: field, session: session, store: store)
                }
            }.disabled(session.isBusy || session.loadingSelection || store.isSavingAll)
        }
    }
}
