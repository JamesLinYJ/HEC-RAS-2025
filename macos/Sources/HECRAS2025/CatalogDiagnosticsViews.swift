import SwiftUI

struct CatalogLayerDiagnosticLogDatum: Decodable, Equatable, Sendable {
    let key: String
    let value: String?
}

/// A source `Utility.Logging.Message` copied into the catalog snapshot. The
/// raw severity is retained so an unknown future source value is never
/// silently presented as Information.
struct CatalogLayerDiagnostic: Decodable, Equatable, Sendable {
    let code: String
    let severity: String
    let evaluatedMessage: String
    let logData: [CatalogLayerDiagnosticLogDatum]
}

enum CatalogLayerDiagnosticSeverity: String, CaseIterable, Sendable {
    case information
    case trace
    case debug
    case warning
    case error
    case unknown

    init(sourceValue: String) {
        self = Self(rawValue: sourceValue.lowercased()) ?? .unknown
    }

    /// Matches Utility.Logging.MessageSeverity's source enum order.
    var sourceRank: Int {
        switch self {
        case .information: 0
        case .trace: 1
        case .debug: 2
        case .warning: 3
        case .error: 4
        case .unknown: -1
        }
    }

    var title: String {
        switch self {
        case .information: "Information"
        case .trace: "Trace"
        case .debug: "Debug"
        case .warning: "Warning"
        case .error: "Error"
        case .unknown: "Unknown"
        }
    }

    var symbol: String {
        switch self {
        case .information: "info.circle"
        case .trace, .debug: "ellipsis.bubble"
        case .warning: "exclamationmark.triangle"
        case .error: "xmark.octagon"
        case .unknown: "questionmark.circle"
        }
    }

    var color: Color {
        switch self {
        case .information: .blue
        case .trace, .debug: .secondary
        case .warning, .unknown: .orange
        case .error: .red
        }
    }
}

enum CatalogLayerDiagnosticsState: Equatable, Sendable {
    case notApplicable
    case notLoaded
    case unavailable
    case sourceChanged
    case readFailed(String?)
    case resultSelectionRequired
    case noIssues
    case issues([CatalogLayerDiagnostic])
}

enum CatalogLayerDiagnosticsProjection {
    private static let sourceNodeClasses: Set<String> = [
        "DefaultRasCatalogNode",
        "BoundaryConditionNode", "BoundaryConditionNodeVM", "ObservableBoundaryCondition",
        "ClassificationNode", "ClassificationNodeVM", "ObservableClassificationLayer",
        "GeometryNode", "GeometryNodeVM", "ObservableGeometry",
        "NValueNode", "NValueNodeVM", "ObservableNValueLayer",
        "PlanNode", "PlanNodeVM", "ObservablePlan",
        "TerrainNode", "TerrainNodeVM", "ObservableTerrain",
        "PointMapLayerVisualContext", "PolylineMapLayerVisualContext", "PolygonMapLayerVisualContext",
        "ResultNode", "ResultNodeVM", "ObservableResult",
        "MultiResultNode", "MultiResultNodeVM"
    ]

    static func applies(to sourceClass: String) -> Bool {
        sourceNodeClasses.contains(sourceClass)
    }

    static func state(for node: LayerTreeNode) -> CatalogLayerDiagnosticsState {
        guard applies(to: node.sourceClass) else { return .notApplicable }
        switch node.diagnosticStatus?.lowercased() {
        case "sourcechanged":
            // A payload observed during a changing source read is not safe to
            // show as current, even if a buggy/older host included messages.
            return .sourceChanged
        case "unavailable":
            return .unavailable
        case "readfailed":
            return .readFailed(node.diagnosticReadError)
        case nil, "loaded":
            break
        default:
            // An unknown future host status must not make stale or empty
            // messages look like a successful, clean source read.
            return .notLoaded
        }
        if let messages = node.layerErrors {
            return messages.isEmpty ? .noIssues : .issues(messages)
        }
        if node.sourceClass == "MultiResultNode" || node.sourceClass == "MultiResultNodeVM" {
            return .resultSelectionRequired
        }
        return .notLoaded
    }

    static func highestSeverity(in messages: [CatalogLayerDiagnostic]) -> CatalogLayerDiagnosticSeverity {
        let known = messages.map { CatalogLayerDiagnosticSeverity(sourceValue: $0.severity) }
            .filter { $0 != .unknown }
        guard let highest = known.max(by: { $0.sourceRank < $1.sourceRank }) else { return .unknown }
        return highest
    }

    @MainActor static func rowSummary(for messages: [CatalogLayerDiagnostic]) -> String {
        guard messages.count != 1 else {
            let message = messages[0].evaluatedMessage
            if !message.isEmpty { return message }
            let code = messages[0].code
            return code.isEmpty ? L10n.text("Catalog issue") : code
        }
        return L10n.format("%d issues - click for details", messages.count)
    }
}

/// Compact source-severity indicator used by both catalog and project-tree
/// rows. It reads only the diagnostics attached to this exact node snapshot.
struct CatalogLayerDiagnosticsRow: View {
    let node: LayerTreeNode
    @ObservedObject var store: WorkspaceStore
    @State private var isPresented = false

    private var state: CatalogLayerDiagnosticsState {
        CatalogLayerDiagnosticsProjection.state(for: node)
    }

    var body: some View {
        switch state {
        case .notApplicable, .noIssues:
            EmptyView()
        case .issues(let messages):
            Button { isPresented = true } label: {
                Label {
                    Text(CatalogLayerDiagnosticsProjection.rowSummary(for: messages))
                        .lineLimit(1)
                } icon: {
                    Image(systemName: CatalogLayerDiagnosticsProjection.highestSeverity(in: messages).symbol)
                }
                .foregroundStyle(CatalogLayerDiagnosticsProjection.highestSeverity(in: messages).color)
                .frame(maxWidth: 150, alignment: .leading)
                .clipped()
            }
            .buttonStyle(.plain)
            .help(CatalogLayerDiagnosticsProjection.rowSummary(for: messages))
            .popover(isPresented: $isPresented, arrowEdge: .trailing) {
                CatalogLayerDiagnosticsPopover(state: state, store: store)
            }
        case .notLoaded, .unavailable, .sourceChanged, .readFailed(_), .resultSelectionRequired:
            Button { isPresented = true } label: {
                Image(systemName: needsRefresh ? "arrow.clockwise.circle" : "questionmark.circle")
                    .foregroundStyle(needsRefresh ? Color.orange : Color.secondary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.text(CatalogLayerDiagnosticsStatusCopy.title(for: state)))
            .help(L10n.text(CatalogLayerDiagnosticsStatusCopy.title(for: state)))
            .popover(isPresented: $isPresented, arrowEdge: .trailing) {
                CatalogLayerDiagnosticsPopover(state: state, store: store)
            }
        }
    }

    private var needsRefresh: Bool {
        if case .sourceChanged = state { return true }
        if case .readFailed(_) = state { return true }
        return false
    }
}

/// Full diagnostic payload shown with the selected catalog summary. A known
/// empty source list, an unavailable source, and a changing source are
/// intentionally separate states.
struct CatalogLayerDiagnosticsSummary: View {
    let node: LayerTreeNode
    @ObservedObject var store: WorkspaceStore

    private var state: CatalogLayerDiagnosticsState {
        CatalogLayerDiagnosticsProjection.state(for: node)
    }

    var body: some View {
        switch state {
        case .notApplicable:
            EmptyView()
        case .notLoaded, .unavailable, .sourceChanged, .readFailed(_), .resultSelectionRequired:
            CatalogLayerDiagnosticsStatusNotice(state: state)
        case .noIssues:
            Label(L10n.text("No source errors or warnings."), systemImage: "checkmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .issues(let messages):
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Label(L10n.text("Catalog issues"), systemImage:
                        CatalogLayerDiagnosticsProjection.highestSeverity(in: messages).symbol)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(CatalogLayerDiagnosticsProjection.highestSeverity(in: messages).color)
                    Text(messages.count.formatted()).monospacedDigit().foregroundStyle(.secondary)
                    Spacer()
                    Button(L10n.text("Copy Messages"), systemImage: "doc.on.doc") {
                        store.system.copy(CatalogLayerDiagnosticsText.render(messages))
                    }
                }
                ForEach(Array(messages.enumerated()), id: \.offset) { entry in
                    CatalogLayerDiagnosticMessageRow(message: entry.element)
                }
            }
            .padding(10)
            .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

private enum CatalogLayerDiagnosticsStatusCopy {
    static func title(for state: CatalogLayerDiagnosticsState) -> String {
        switch state {
        case .notLoaded: "Catalog diagnostics not loaded"
        case .unavailable: "Catalog diagnostics unavailable"
        case .sourceChanged: "Source changed while reading catalog diagnostics"
        case .readFailed(_): "Could not read catalog diagnostics"
        case .resultSelectionRequired: "Select an individual Result to view diagnostics"
        case .notApplicable, .noIssues, .issues(_): "Catalog diagnostics"
        }
    }

    static func detail(for state: CatalogLayerDiagnosticsState) -> String {
        switch state {
        case .notLoaded:
            "The current tree snapshot did not include diagnostics for this exact node."
        case .unavailable:
            "The source did not provide diagnostics for this node. No clean state is inferred."
        case .sourceChanged:
            "The source changed during the diagnostic read. Refresh the catalog before relying on these messages."
        case .readFailed(let message):
            message.flatMap { $0.isEmpty ? nil : $0 } ?? "The source diagnostics collection could not be read."
        case .resultSelectionRequired:
            "This group has no single Result selection. Select a Result child to inspect its source diagnostics."
        case .notApplicable, .noIssues, .issues(_):
            ""
        }
    }
}

private struct CatalogLayerDiagnosticsStatusNotice: View {
    let state: CatalogLayerDiagnosticsState

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.text(CatalogLayerDiagnosticsStatusCopy.title(for: state)))
                    .font(.caption.weight(.medium))
                Text(L10n.text(CatalogLayerDiagnosticsStatusCopy.detail(for: state)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: state == .sourceChanged || isReadFailure ? "arrow.clockwise.circle" : "questionmark.circle")
                .foregroundStyle(state == .sourceChanged || isReadFailure ? Color.orange : Color.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 7))
    }

    private var isReadFailure: Bool {
        if case .readFailed(_) = state { return true }
        return false
    }
}

private struct CatalogLayerDiagnosticsPopover: View {
    let state: CatalogLayerDiagnosticsState
    @ObservedObject var store: WorkspaceStore

    var body: some View {
        switch state {
        case .issues(let messages):
            CatalogLayerDiagnosticsMessageList(messages: messages, store: store)
        case .noIssues:
            ContentUnavailableView(L10n.text("No source errors or warnings."), systemImage: "checkmark.circle")
                .frame(width: 430, height: 190)
        case .notLoaded, .unavailable, .sourceChanged, .readFailed(_), .resultSelectionRequired:
            CatalogLayerDiagnosticsStatusNotice(state: state)
                .frame(width: 390)
                .padding(8)
        case .notApplicable:
            EmptyView()
        }
    }
}

private struct CatalogLayerDiagnosticsMessageList: View {
    let messages: [CatalogLayerDiagnostic]
    @ObservedObject var store: WorkspaceStore
    @State private var severityFilter = "All"
    @State private var searchText = ""

    private var filteredMessages: [(offset: Int, message: CatalogLayerDiagnostic)] {
        let matches = messages.enumerated().filter { pair in
            let message = pair.element
            let severityMatches = severityFilter == "All"
                || message.severity.lowercased() == severityFilter.lowercased()
            let searchMatches = searchText.isEmpty
                || message.code.localizedCaseInsensitiveContains(searchText)
                || message.severity.localizedCaseInsensitiveContains(searchText)
                || message.evaluatedMessage.localizedCaseInsensitiveContains(searchText)
                || message.logData.contains {
                    $0.key.localizedCaseInsensitiveContains(searchText)
                        || ($0.value ?? "").localizedCaseInsensitiveContains(searchText)
                }
            return severityMatches && searchMatches
        }
        return matches.map { (offset: $0.offset, message: $0.element) }
    }

    private var availableSeverities: [String] {
        var values = CatalogLayerDiagnosticSeverity.allCases
            .filter { $0 != .unknown }
            .map(\.rawValue)
        for message in messages where !values.contains(message.severity.lowercased()) {
            values.append(message.severity.lowercased())
        }
        return values
    }

    @MainActor private func severityLabel(_ rawValue: String) -> String {
        let severity = CatalogLayerDiagnosticSeverity(sourceValue: rawValue)
        if severity == .unknown {
            return rawValue.isEmpty ? L10n.text("Unknown") : rawValue
        }
        return L10n.text(severity.title)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text(L10n.text("Catalog issues")).font(.headline)
                Text(filteredMessages.count.formatted()).monospacedDigit().foregroundStyle(.secondary)
                Spacer()
                Button(L10n.text("Copy Messages"), systemImage: "doc.on.doc") {
                    store.system.copy(CatalogLayerDiagnosticsText.render(filteredMessages.map(\.message)))
                }
                .disabled(filteredMessages.isEmpty)
            }
            .padding(12)
            Divider()
            HStack {
                Picker(L10n.text("Severity"), selection: $severityFilter) {
                    Text(L10n.text("All Severities")).tag("All")
                    ForEach(availableSeverities, id: \.self) { severity in
                        Text(severityLabel(severity))
                            .tag(severity)
                    }
                }
                .pickerStyle(.menu)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            List(filteredMessages, id: \.offset) { entry in
                CatalogLayerDiagnosticMessageRow(message: entry.message)
                    .listRowBackground(CatalogLayerDiagnosticSeverity(sourceValue: entry.message.severity).color.opacity(0.08))
            }
            .listStyle(.inset)
            .searchable(text: $searchText, prompt: L10n.text("Filter catalog issues"))
            .overlay {
                if filteredMessages.isEmpty {
                    ContentUnavailableView(L10n.text("No Matching Catalog Issues"), systemImage: "line.3.horizontal.decrease.circle")
                }
            }
        }
        .frame(width: 620, height: 430)
    }
}

private struct CatalogLayerDiagnosticMessageRow: View {
    let message: CatalogLayerDiagnostic

    private var severity: CatalogLayerDiagnosticSeverity {
        CatalogLayerDiagnosticSeverity(sourceValue: message.severity)
    }

    var body: some View {
        let severityTitle = severity == .unknown
            ? (message.severity.isEmpty ? L10n.text("Unknown") : message.severity)
            : L10n.text(severity.title)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Label(severityTitle, systemImage: severity.symbol)
                    .foregroundStyle(severity.color)
                Text(message.code.isEmpty ? "—" : message.code)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Spacer()
            }
            if !message.evaluatedMessage.isEmpty {
                Text(message.evaluatedMessage)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !message.logData.isEmpty {
                DisclosureGroup(L10n.text("Log data")) {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
                        ForEach(Array(message.logData.enumerated()), id: \.offset) { entry in
                            GridRow {
                                Text(entry.element.key)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                Text(entry.element.value ?? "—")
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    .font(.caption)
                    .padding(.top, 5)
                }
                .font(.caption)
            }
        }
        .padding(.vertical, 4)
    }
}

private enum CatalogLayerDiagnosticsText {
    static func render(_ messages: [CatalogLayerDiagnostic]) -> String {
        messages.map { message in
            let headline = "[\(message.severity)] \(message.code): \(message.evaluatedMessage)"
            return ([headline] + message.logData.map { "\($0.key): \($0.value ?? "—")" })
                .joined(separator: "\n")
        }.joined(separator: "\n\n")
    }
}
