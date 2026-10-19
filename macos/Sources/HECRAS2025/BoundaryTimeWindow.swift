import SwiftUI

enum BoundaryFieldReferences {
    static func find(suffix: String, schemas: [String], values: [String: String]) -> SourceEditorField? {
        let candidates = schemas.flatMap { SourceEditorLibrary.shared.schema($0)?.fields ?? [] }.filter { $0.id.hasSuffix(suffix) }
        return candidates.first { values[$0.storageID] != nil } ?? candidates.first
    }
}

// BoundaryConditionCatalogSummary and BoundaryConditionTimeWindow share the
// actual property routes supplied by the source. No duplicate description or
// guessed filesystem dates stand in for unavailable model metadata.
struct BoundaryCatalogFields: View {
    @ObservedObject var session: ModelEditorSession
    @ObservedObject var store: WorkspaceStore
    private func value(_ suffix: String) -> String? {
        BoundaryFieldReferences.find(suffix: suffix, schemas: ["BoundaryConditionCatalogSummary"], values: session.fields).flatMap { session.fields[$0.storageID] }
    }
    var body: some View {
        LabeledContent("Name", value: value("_Name") ?? session.modelName ?? "—").textSelection(.enabled)
        CatalogFilePath(title: "Filename", path: value("_Filename") ?? session.modelAssetID ?? "", store: store)
        LabeledContent("Date Created", value: value("_DateCreated") ?? "—")
        LabeledContent("Date Last Modified", value: value("_DateLastModified") ?? "—")
    }
}

struct BoundaryTimeWindowField: View {
    @ObservedObject var session: ModelEditorSession
    @ObservedObject var store: WorkspaceStore
    private func field(_ suffix: String) -> SourceEditorField? {
        BoundaryFieldReferences.find(suffix: suffix, schemas: ["BoundaryConditionTimeWindow", "BoundaryConditionsSummary"], values: session.fields)
    }
    private func date(_ suffix: String) -> Date? {
        field(suffix).flatMap { session.fields[$0.storageID] }.flatMap { ISO8601DateFormatter().date(from: $0) }
    }
    var body: some View {
        SourceFieldRows(fields: [field("_StartTime"), field("_EndTime")].compactMap { $0 }, session: session, store: store)
        if let start = date("_StartTime"), let end = date("_EndTime") {
            if end > start {
                TimeDifferenceView(startTime: start, endTime: end)
                SourceTimelineView(primaryLineName: session.modelName ?? L10n.text("Boundary Condition"), startTime: start, endTime: end, entries: [])
            } else {
                Label("The end time must follow the start time.", systemImage: "exclamationmark.triangle").foregroundStyle(.red)
            }
        }
    }
}
