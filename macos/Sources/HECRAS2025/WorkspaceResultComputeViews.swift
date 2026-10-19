import SwiftUI

enum ResultComputePresentationPath {
    static func applies(to sourceClass: String) -> Bool {
        ["ResultNode", "ResultNodeVM", "ObservableResult", "MultiResultNode", "MultiResultNodeVM", "TransientResultComputeNode"]
            .contains(sourceClass)
    }

    static func exactResultPath(for node: LayerTreeNode, assetPath: String? = nil) -> String? {
        if node.sourceClass == "MultiResultNode" || node.sourceClass == "MultiResultNodeVM" {
            return node.resultComputeSourcePath
        }
        return node.resultComputeSourcePath ?? assetPath ?? node.assetID
    }
}

struct ResultComputeStatusIndicator: View {
    let node: LayerTreeNode
    @ObservedObject var store: WorkspaceStore
    var assetPath: String? = nil
    @State private var isPresented = false

    private var resultPath: String? { ResultComputePresentationPath.exactResultPath(for: node, assetPath: assetPath) }
    private var presentation: WorkspaceResultComputePresentation {
        WorkspaceResultComputePresentation.resolve(
            path: resultPath,
            projectSessionID: store.projectSessionID,
            sourceRevision: node.resultComputeSourceRevision,
            liveEntries: store.liveResultComputeByPath,
            persistedState: node.resultComputeState,
            persistedFailureReason: node.resultComputeFailureReason)
    }

    var body: some View {
        Button { isPresented = true } label: {
            if presentation.status == .running, let fraction = presentation.fraction {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .frame(width: 50)
            } else {
                Image(systemName: symbol(for: presentation.status))
                    .foregroundStyle(color(for: presentation.status))
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.text(presentation.status.localizedTitle))
        .help(L10n.text(presentation.status.localizedTitle))
        .popover(isPresented: $isPresented, arrowEdge: .trailing) {
            ResultComputeStatusPopover(presentation: presentation)
        }
    }
}

struct ResultComputeStatusDetails: View {
    let node: LayerTreeNode
    @ObservedObject var store: WorkspaceStore
    var assetPath: String? = nil

    private var resultPath: String? { ResultComputePresentationPath.exactResultPath(for: node, assetPath: assetPath) }
    private var presentation: WorkspaceResultComputePresentation {
        WorkspaceResultComputePresentation.resolve(
            path: resultPath,
            projectSessionID: store.projectSessionID,
            sourceRevision: node.resultComputeSourceRevision,
            liveEntries: store.liveResultComputeByPath,
            persistedState: node.resultComputeState,
            persistedFailureReason: node.resultComputeFailureReason)
    }

    var body: some View {
        GroupBox(L10n.text("Compute Status")) {
            VStack(alignment: .leading, spacing: 8) {
                Label(L10n.text(presentation.status.localizedTitle), systemImage: symbol(for: presentation.status))
                    .foregroundStyle(color(for: presentation.status))
                if presentation.status == .running, let fraction = presentation.fraction {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                        .accessibilityLabel(L10n.text("Compute Progress"))
                }
                if let taskName = presentation.taskName, !taskName.isEmpty {
                    Text(taskName).font(.caption).foregroundStyle(.secondary)
                }
                if let message = presentation.message, !message.isEmpty {
                    Text(message).font(.caption).textSelection(.enabled)
                }
                if let reason = presentation.failureReason, !reason.isEmpty,
                   presentation.status == .failed || presentation.status == .cancelled {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(L10n.text("Failure Reason")).font(.caption).foregroundStyle(.secondary)
                        Text(reason).font(.caption).textSelection(.enabled)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct ResultComputeStatusPopover: View {
    let presentation: WorkspaceResultComputePresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(L10n.text(presentation.status.localizedTitle), systemImage: symbol(for: presentation.status))
                .foregroundStyle(color(for: presentation.status))
            if presentation.status == .running, let fraction = presentation.fraction {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .accessibilityLabel(L10n.text("Compute Progress"))
            }
            if let taskName = presentation.taskName, !taskName.isEmpty {
                Text(taskName).font(.caption).foregroundStyle(.secondary)
            }
            if let message = presentation.message, !message.isEmpty {
                Text(message).font(.caption).textSelection(.enabled)
            }
            if let reason = presentation.failureReason, !reason.isEmpty,
               presentation.status == .failed || presentation.status == .cancelled {
                Divider()
                Text(L10n.text("Failure Reason")).font(.caption).foregroundStyle(.secondary)
                Text(reason).font(.caption).textSelection(.enabled)
            }
        }
        .padding(12)
        .frame(minWidth: 220, idealWidth: 280, maxWidth: 320, alignment: .leading)
    }
}

private func symbol(for status: WorkspaceResultComputeStatus) -> String {
    switch status {
    case .running: "hourglass"
    case .completed: "checkmark.circle.fill"
    case .failed: "xmark.octagon.fill"
    case .cancelled: "minus.circle.fill"
    case .unknown: "questionmark.circle"
    }
}

private func color(for status: WorkspaceResultComputeStatus) -> Color {
    switch status {
    case .running: .blue
    case .completed: .green
    case .failed: .red
    case .cancelled: .orange
    case .unknown: .secondary
    }
}
