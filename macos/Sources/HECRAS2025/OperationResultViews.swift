import SwiftUI

struct PlanPrecomputeOperationResultView: View {
    let result: PlanPrecomputeResult

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(
                L10n.text(result.result ? "Plan can compute" : "Plan cannot compute"),
                systemImage: result.result ? "checkmark.circle.fill" : "xmark.octagon.fill"
            )
            .font(.headline)
            .foregroundStyle(result.result ? .green : .red)

            if result.messages.isEmpty {
                Text("No validation messages.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(result.messages) { message in
                    PlanPrecomputeMessageRow(message: message)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

private struct PlanPrecomputeMessageRow: View {
    let message: PlanPrecomputeMessage

    private var severity: String { message.defaultSeverity.lowercased() }
    private var severityTitle: String {
        switch severity {
        case "error": L10n.text("Error")
        case "warning": L10n.text("Warning")
        case "information": L10n.text("Information")
        case "debug": L10n.text("Debug")
        case "trace": L10n.text("Trace")
        default: message.defaultSeverity
        }
    }
    private var severitySymbol: String {
        switch severity {
        case "error": "xmark.octagon"
        case "warning": "exclamationmark.triangle"
        case "information": "info.circle"
        case "debug", "trace": "ellipsis.bubble"
        default: "text.bubble"
        }
    }
    private var severityColor: Color {
        switch severity {
        case "error": .red
        case "warning": .orange
        case "information": .blue
        default: .secondary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label(severityTitle, systemImage: severitySymbol)
                    .foregroundStyle(severityColor)
                Text(message.code)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Text(message.evaluatedMessage)
                .textSelection(.enabled)

            if message.extraCount > 0 {
                HStack(spacing: 4) {
                    Text("More occurrences")
                    Text(message.extraCount, format: .number)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if !message.logData.isEmpty {
                DisclosureGroup("Log data") {
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
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
    }
}
