import SwiftUI

/// Native counterpart of LayerErrorIndicator. The summary and rows only use
/// the source Result.LayerErrors payload; missing timestamps remain absent.
struct ResultLayerErrorIndicatorView: View {
    let messages: [TopologyBuildMessagePresentation]
    @ObservedObject var store: WorkspaceStore
    @State private var isPresented = false

    private var highestSeverity: TopologyMessageSeverity {
        messages.map(\.severity).max { sourceRank($0) < sourceRank($1) } ?? .information
    }

    private var summary: String {
        if messages.count == 1 { return messages[0].text }
        return L10n.format("%d issues - click for details", messages.count)
    }

    fileprivate static let severities: [TopologyMessageSeverity] =
        [.trace, .debug, .information, .warning, .error]

    var body: some View {
        if !messages.isEmpty {
            Button { isPresented = true } label: {
                Label {
                    Text(summary).lineLimit(2).multilineTextAlignment(.leading)
                } icon: {
                    Image(systemName: highestSeverity.symbol)
                }
                .foregroundStyle(highestSeverity.color)
            }
            .buttonStyle(.plain)
            .help(summary)
            .popover(isPresented: $isPresented, arrowEdge: .trailing) {
                ResultLayerErrorListView(messages: messages, store: store)
            }
        }
    }

    private func sourceRank(_ severity: TopologyMessageSeverity) -> Int {
        // Match the retained MessageSeverity enum's numeric ordering used by
        // LayerErrorIndicator.HighestSeverity.
        switch severity {
        case .information: 0
        case .trace: 1
        case .debug: 2
        case .warning: 3
        case .error: 4
        }
    }
}

private struct ResultLayerErrorListView: View {
    let messages: [TopologyBuildMessagePresentation]
    @ObservedObject var store: WorkspaceStore
    @State private var severityFilter = "All"
    @State private var searchText = ""

    private var filteredMessages: [TopologyBuildMessagePresentation] {
        let matching = messages.enumerated().filter { pair in
            let message = pair.element
            let severityMatches = severityFilter == "All"
                || message.severity.rawValue == severityFilter.lowercased()
            let searchMatches = searchText.isEmpty
                || message.code.localizedCaseInsensitiveContains(searchText)
                || message.text.localizedCaseInsensitiveContains(searchText)
                || message.context.contains {
                    $0.key.localizedCaseInsensitiveContains(searchText)
                        || $0.value.localizedCaseInsensitiveContains(searchText)
                }
            return severityMatches && searchMatches
        }
        // MessageListControl sorts by the source MessageSeverity enum when
        // severity sorting is enabled. Keep that stable order in the native list.
        return matching.sorted { lhs, rhs in
            let leftRank = sourceRank(lhs.element.severity)
            let rightRank = sourceRank(rhs.element.severity)
            return leftRank == rightRank ? lhs.offset < rhs.offset : leftRank > rightRank
        }.map(\.element)
    }

    private func sourceRank(_ severity: TopologyMessageSeverity) -> Int {
        switch severity {
        case .information: 0
        case .trace: 1
        case .debug: 2
        case .warning: 3
        case .error: 4
        }
    }

    private var diagnosticText: String {
        filteredMessages.map { message in
            let header = "[\(message.severity.title)] \(message.code): \(message.text)"
            let values = message.context.map { "\($0.key): \($0.value)" }
            return ([header] + values).joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text(L10n.text("Result issues")).font(.headline)
                Text(filteredMessages.count.formatted()).monospacedDigit().foregroundStyle(.secondary)
                Spacer()
                Button(L10n.text("Copy Messages"), systemImage: "doc.on.doc") {
                    store.system.copy(diagnosticText)
                }
                .disabled(filteredMessages.isEmpty)
            }
            .padding(12)

            Divider()

            HStack {
                Picker(L10n.text("Severity"), selection: $severityFilter) {
                    Text(L10n.text("All Severities")).tag("All")
                    ForEach(ResultLayerErrorIndicatorView.severities, id: \.rawValue) { severity in
                        Text(L10n.text(severity.title)).tag(severity.rawValue)
                    }
                }
                .pickerStyle(.menu)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            List(filteredMessages) { message in
                ResultLayerErrorMessageRow(message: message)
                    .listRowBackground(message.severity.color.opacity(0.08))
            }
            .listStyle(.inset)
            .searchable(text: $searchText, prompt: L10n.text("Filter result errors"))
            .overlay {
                if filteredMessages.isEmpty {
                    ContentUnavailableView(L10n.text("No Matching Result Errors"),
                                           systemImage: "checkmark.circle")
                }
            }
        }
        .frame(width: 620, height: 430)
    }
}

private struct ResultLayerErrorMessageRow: View {
    let message: TopologyBuildMessagePresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Label(L10n.text(message.severity.title), systemImage: message.severity.symbol)
                    .foregroundStyle(message.severity.color)
                Text(message.code.isEmpty ? "—" : message.code)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Spacer()
            }
            Text(message.text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            if !message.context.isEmpty {
                DisclosureGroup(L10n.text("Log data")) {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
                        ForEach(Array(message.context.enumerated()), id: \.offset) { entry in
                            GridRow {
                                Text(entry.element.key)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                Text(entry.element.value)
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
        .padding(.vertical, 5)
    }
}
