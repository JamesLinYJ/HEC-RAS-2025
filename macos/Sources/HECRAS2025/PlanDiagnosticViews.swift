import Foundation
import SwiftUI
import RASWorkspaceCore

struct PlanDiagnosticOperationResultView: View {
    let result: PlanPrecomputeResult
    let store: WorkspaceStore?
    let onNavigate: (@MainActor (PlanDiagnosticTarget) -> Bool)?
    let isTargetCurrent: (@MainActor (PlanDiagnosticTarget) -> Bool)?
    let onCompute: (@MainActor (PlanDiagnosticTarget) async -> Bool)?

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
                ForEach(Array(result.messages.enumerated()), id: \.offset) { index, message in
                    PlanDiagnosticMessageCard(
                        id: "precompute|\(index)|\(message.code)",
                        code: message.code,
                        severity: message.defaultSeverity,
                        text: message.evaluatedMessage,
                        logData: message.logData.map { PlanDiagnosticDisplayLogDatum(key: $0.key, value: $0.value, target: $0.target) },
                        extraCount: message.extraCount,
                        ordinal: nil,
                        store: store,
                        onNavigate: onNavigate,
                        isTargetCurrent: isTargetCurrent,
                        onCompute: onCompute
                    )
                }
            }
        }
        .padding(.vertical, 4)
    }
}

struct PlanComputeJobMessagesView: View {
    let runID: String?
    let messages: [PlanComputeJobMessage]
    let issue: String?
    let store: WorkspaceStore?
    let onNavigate: (@MainActor (PlanDiagnosticTarget) -> Bool)?
    let isTargetCurrent: (@MainActor (PlanDiagnosticTarget) -> Bool)?
    let onCompute: (@MainActor (PlanDiagnosticTarget) async -> Bool)?

    var body: some View {
        if let issue {
            Label(L10n.text(issue), systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .textSelection(.enabled)
        }

        if messages.isEmpty {
            Text(L10n.text("No live messages reported yet."))
                .foregroundStyle(.secondary)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(messages) { message in
                        PlanDiagnosticMessageCard(
                            id: "\(runID ?? "run")|\(message.index)",
                            code: message.code,
                            severity: message.defaultSeverity,
                            text: message.evaluatedMessage,
                            logData: message.logData.map { PlanDiagnosticDisplayLogDatum(key: $0.key, value: $0.value, target: $0.target) },
                            extraCount: 0,
                            ordinal: message.index,
                            store: store,
                            onNavigate: onNavigate,
                            isTargetCurrent: isTargetCurrent,
                            onCompute: onCompute
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 90, maxHeight: 340)
        }
    }
}

private struct PlanDiagnosticDisplayLogDatum: Identifiable {
    let key: String
    let value: String?
    let target: PlanDiagnosticTarget?

    var id: String { key }
}

private struct PlanDiagnosticMessageCard: View {
    let id: String
    let code: String
    let severity: String
    let text: String
    let logData: [PlanDiagnosticDisplayLogDatum]
    let extraCount: Int
    let ordinal: Int?
    let store: WorkspaceStore?
    let onNavigate: (@MainActor (PlanDiagnosticTarget) -> Bool)?
    let isTargetCurrent: (@MainActor (PlanDiagnosticTarget) -> Bool)?
    let onCompute: (@MainActor (PlanDiagnosticTarget) async -> Bool)?

    private var normalizedSeverity: String { severity.lowercased() }
    private var severityTitle: String {
        switch normalizedSeverity {
        case "error": L10n.text("Error")
        case "warning": L10n.text("Warning")
        case "information": L10n.text("Information")
        case "debug": L10n.text("Debug")
        case "trace": L10n.text("Trace")
        default: severity
        }
    }
    private var severitySymbol: String {
        switch normalizedSeverity {
        case "error": "xmark.octagon"
        case "warning": "exclamationmark.triangle"
        case "information": "info.circle"
        case "debug", "trace": "ellipsis.bubble"
        default: "text.bubble"
        }
    }
    private var severityColor: Color {
        switch normalizedSeverity {
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
                Text(code)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                if let ordinal {
                    Text("#\(ordinal + 1)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            Text(text)
                .textSelection(.enabled)

            if extraCount > 0 {
                HStack(spacing: 4) {
                    Text("More occurrences")
                    Text(extraCount, format: .number)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if !logData.isEmpty {
                DisclosureGroup("Log data") {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
                        ForEach(Array(logData.enumerated()), id: \.offset) { entry in
                            GridRow {
                                Text(entry.element.key)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                logDatumValue(entry.element)
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
        .accessibilityIdentifier(id)
    }

    private func actionTitle(_ kind: String) -> String {
        switch kind {
        case "plan": L10n.text("Open Plan")
        case "geometry": L10n.text("Open Geometry")
        case "flowArea": L10n.text("Open 2D Flow Area")
        case "boundaryCondition": L10n.text("Open Boundary Conditions")
        case "boundaryConditionLine": L10n.text("Open Boundary Condition Line")
        default: L10n.text("Open")
        }
    }

    @ViewBuilder
    private func logDatumValue(_ datum: PlanDiagnosticDisplayLogDatum) -> some View {
        if let target = datum.target,
           ["plan", "geometry", "boundaryCondition"].contains(target.kind),
           let store, let isTargetCurrent, isTargetCurrent(target), let onNavigate {
            logDatumContent(datum)
                .contextMenu {
                    PlanDiagnosticContextMenuItems(store: store, target: target,
                        isTargetCurrent: isTargetCurrent, onNavigate: onNavigate,
                        onCompute: onCompute)
                }
        } else {
            logDatumContent(datum)
        }
    }

    private func logDatumContent(_ datum: PlanDiagnosticDisplayLogDatum) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(datum.value ?? "—")
                .textSelection(.enabled)
            if let target = datum.target, let onNavigate {
                Button {
                    _ = onNavigate(target)
                } label: {
                    Label(actionTitle(target.kind), systemImage: "arrow.up.right.square")
                }
                .buttonStyle(.link)
                .accessibilityHint(L10n.text("Open the related item."))
            }
        }
    }
}
