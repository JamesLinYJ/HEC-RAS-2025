import SwiftUI

struct ThinkingMessage: Sendable {
    struct Step: Identifiable, Sendable {
        enum Status: String, Sendable { case pending = "Pending", running = "Running", done = "Done", failed = "Failed" }
        let index: Int
        let text: String
        let status: Status
        var id: Int { index }
    }
    struct Group: Identifiable, Sendable {
        let id: String
        let title: String
        let narrative: String
    }
    let steps: [Step]
    let statusLines: [String]
    let groups: [Group]
    let lastNote: String
    let isBusy: Bool
    let isExpanded: Bool
    @MainActor var header: String {
        if let line = statusLines.last { return line }
        if !lastNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return lastNote }
        return L10n.text(steps.isEmpty ? "Thinking…" : "Working…")
    }
    var headerColor: Color {
        if steps.contains(where: { $0.status == .running }) { return .blue }
        if !steps.isEmpty && steps.allSatisfy({ $0.status == .done }) { return .green }
        return .secondary
    }
}

// ObservableThinkingMessage/Group/Step presentation only. The adapter supplies
// actual status text; this control never invents reasoning or progress.
struct ThinkingMessageView: View {
    let message: ThinkingMessage
    @State private var expanded: Bool
    init(message: ThinkingMessage) {
        self.message = message; _expanded = State(initialValue: message.isExpanded)
    }
    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(message.steps) { step in
                    HStack(alignment: .firstTextBaseline) {
                        Image(systemName: symbol(step.status)).foregroundStyle(color(step.status))
                        Text("\(step.index + 1). \(step.text)").textSelection(.enabled)
                        Spacer(minLength: 0)
                        Text(L10n.text(step.status.rawValue)).font(.caption).foregroundStyle(color(step.status))
                    }
                }
                ForEach(message.groups) { group in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(group.title).font(.subheadline.weight(.semibold))
                        Text(group.narrative).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
                ForEach(Array(message.statusLines.enumerated()), id: \.offset) { _, line in
                    Text(line).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }.padding(.top, 8)
        } label: {
            HStack {
                if message.isBusy { ProgressView().controlSize(.small) }
                Text(message.header).foregroundStyle(message.headerColor)
            }
        }.onChange(of: message.isExpanded) { _, value in expanded = value }
    }
    private func color(_ status: ThinkingMessage.Step.Status) -> Color {
        switch status { case .running: .blue; case .done: .green; case .failed: .red; case .pending: .secondary }
    }
    private func symbol(_ status: ThinkingMessage.Step.Status) -> String {
        switch status { case .running: "arrow.triangle.2.circlepath"; case .done: "checkmark.circle"; case .failed: "exclamationmark.circle"; case .pending: "circle.dotted" }
    }
}

struct DeveloperFeedMessage: Sendable {
    let summary: String
    let entryType: String
    let actionName: String
    let durationDisplay: String
    let request: String
    let response: String
    let isInProgress: Bool
    let isExpanded: Bool
    var isError = false
    var color: Color {
        switch entryType.lowercased() {
        case "tool call": .blue
        case "reflect": .purple
        case "plan": .green
        case "system": .gray
        case "user": .yellow
        case "error": .red
        case "final": .teal
        default: .secondary
        }
    }
    var symbol: String {
        switch entryType.lowercased() {
        case "tool call": "wrench.and.screwdriver"
        case "reflect": "brain"
        case "plan": "list.bullet.clipboard"
        case "system": "gearshape"
        case "user": "person"
        case "error": "exclamationmark.triangle"
        case "final": "checkmark.circle"
        default: "doc.text"
        }
    }
}
struct DeveloperFeedMessageView: View {
    let message: DeveloperFeedMessage
    @State private var expanded: Bool
    init(message: DeveloperFeedMessage) { self.message = message; _expanded = State(initialValue: message.isExpanded) }
    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 12) {
                Text([message.entryType, message.actionName].filter { !$0.isEmpty }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                if !message.request.isEmpty {
                    Text("Request").font(.subheadline.weight(.semibold))
                    Text(message.request).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                }
                if !message.response.isEmpty {
                    Text("Response").font(.subheadline.weight(.semibold))
                    Text(message.response).font(.system(.caption, design: .monospaced)).foregroundStyle(message.isError ? Color.red : .primary).textSelection(.enabled)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
        } label: {
            HStack {
                if message.isInProgress { ProgressView().controlSize(.small) }
                else { Image(systemName: message.symbol).foregroundStyle(message.color) }
                Text(message.summary)
                Spacer(minLength: 0)
                Text(message.durationDisplay).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }.onChange(of: message.isExpanded) { _, value in expanded = value }
    }
}
