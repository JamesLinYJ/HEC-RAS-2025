import RASWorkspaceCore
import SwiftUI

// MeshDiagnostics.HistoryEntries/CurrentEntry and LayerErrorList render actual
// source diagnostics. Empty history is unavailable; an entry with no issues is
// a completed check that returned no issues.
struct ModelDiagnosticsView: View {
    @ObservedObject var session: ModelEditorSession
    @ObservedObject var store: WorkspaceStore
    @State private var entryID: String?
    @State private var selectedIssue: String?
    @State private var query = ""
    @State private var severity = "All"
    private var entry: EditorDiagnosticEntry? { session.diagnosticHistory.first { $0.id == entryID } ?? session.diagnosticHistory.last }
    private var issues: [EditorIssue] {
        (entry?.issues ?? []).filter {
            (severity == "All" || $0.severity.rawValue == severity) &&
            (query.isEmpty || $0.message.localizedCaseInsensitiveContains(query) || ($0.feature ?? "").localizedCaseInsensitiveContains(query))
        }
    }
    private var issue: EditorIssue? { entry?.issues.first { $0.id == selectedIssue } }
    var body: some View {
        HSplitView {
            List(session.diagnosticHistory, selection: $entryID) { item in
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title)
                    if let date = item.date { Text(date, style: .date).font(.caption).foregroundStyle(.secondary) }
                }.tag(item.id)
            }.listStyle(.sidebar).frame(minWidth: 150, idealWidth: 190, maxWidth: 260)
            VStack(spacing: 0) {
                VStack(spacing: 0) {
                    HStack {
                        TextField("Search diagnostics", text: $query).textFieldStyle(.roundedBorder)
                        Picker("Severity", selection: $severity) {
                            Text("All").tag("All")
                            Text("Errors").tag("error"); Text("Warnings").tag("warning"); Text("Information").tag("info")
                        }.frame(maxWidth: 180)
                        Button { copyIssues() } label: { Label("Copy", systemImage: "doc.on.doc") }.disabled(issues.isEmpty)
                    }.padding(12)
                    Table(issues, selection: $selectedIssue) {
                        TableColumn(L10n.text("Severity")) { row in Label(L10n.text(title(row.severity)), systemImage: symbol(row.severity)).foregroundStyle(color(row.severity)) }.width(min: 90, ideal: 115, max: 160)
                        TableColumn(L10n.text("Message"), value: \.message)
                        TableColumn(L10n.text("Feature")) { row in Text(row.feature ?? "—") }
                    }.overlay {
                        if entry == nil { ContentUnavailableView("Diagnostics unavailable", systemImage: "stethoscope") }
                        else if entry?.issues.isEmpty == true { ContentUnavailableView("No issues reported", systemImage: "checkmark.circle") }
                    }
                }.frame(minHeight: 160, maxHeight: .infinity)
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    if let issue {
                        Label(issue.message, systemImage: symbol(issue.severity)).font(.headline).textSelection(.enabled)
                        if let location = issue.location {
                            HStack {
                                Text("X: \(location.x.formatted())  Y: \(location.y.formatted())").font(.caption.monospacedDigit())
                                Spacer()
                                Button("Zoom to Feature") { centerMap(location) }
                            }
                        }
                        if let detail = issue.detail { ScrollView { Text(detail).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) } }
                    } else { Text("Select a diagnostic to view details.").foregroundStyle(.secondary) }
                }.padding(16).frame(maxWidth: .infinity, minHeight: 200, idealHeight: 260, maxHeight: 380, alignment: .topLeading)
            }
        }
        .onChange(of: entryID) { _, _ in selectedIssue = nil }
        .onChange(of: session.modelAssetID) { _, _ in entryID = nil; selectedIssue = nil; query = "" }
    }
    private func title(_ value: EditorIssue.Severity) -> String { switch value { case .error: "Error"; case .warning: "Warning"; case .info: "Information" } }
    private func symbol(_ value: EditorIssue.Severity) -> String { switch value { case .error: "xmark.octagon"; case .warning: "exclamationmark.triangle"; case .info: "info.circle" } }
    private func color(_ value: EditorIssue.Severity) -> Color { switch value { case .error: .red; case .warning: .orange; case .info: .secondary } }
    private func copyIssues() { store.system.copy(issues.map { [title($0.severity), $0.feature ?? "", $0.message, $0.detail ?? ""].joined(separator: "\t") }.joined(separator: "\n")) }
    private func centerMap(_ point: MapPoint) {
        guard point.x.isFinite, point.y.isFinite else { return }
        let state = store.mapState(for: store.lastActiveMapID)
        let extent = state.currentExtent
        let halfWidth = max((extent.map { $0.upperRight.x - $0.lowerLeft.x } ?? 2) / 2, 0.000001)
        let halfHeight = max((extent.map { $0.upperRight.y - $0.lowerLeft.y } ?? 2) / 2, 0.000001)
        state.viewport = ViewportRequest(lowerLeft: .init(x: point.x - halfWidth, y: point.y - halfHeight), upperRight: .init(x: point.x + halfWidth, y: point.y + halfHeight))
    }
}
