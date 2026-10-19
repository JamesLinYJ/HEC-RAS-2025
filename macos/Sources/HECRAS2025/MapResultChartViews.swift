import SwiftUI

/// Native controls for map-visible Result and MultiResult contexts. This view
/// is hosted by the map source panel; selection changes are sent through the
/// fresh-token backend route and remain per-map session state.
struct MapResultSourcePanel: View {
    @ObservedObject var session: MapResultSourcesSession
    var store: WorkspaceStore? = nil
    var onlyNodeIdentity: String? = nil
    var autoLoadSources = true
    var missingNodeMessage: String? = nil

    private var visibleNodes: [MapResultChartActiveNode] {
        let nodes = session.sources?.activeNodes ?? []
        guard let onlyNodeIdentity else { return nodes }
        return nodes.filter { $0.id == onlyNodeIdentity }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(L10n.text("Map Result Sources"), systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.headline)
                Spacer()
                Button {
                    Task { await session.loadSources(force: true) }
                } label: {
                    Label(L10n.text("Refresh"), systemImage: "arrow.clockwise")
                }
                .disabled(session.isLoading || session.isSelecting || session.isStale || session.sourceReadsBlocked)
            }

            if session.isLoading {
                ProgressView(L10n.text("Loading active map result sources…"))
                    .controlSize(.small)
            }
            if let error = session.errorMessage {
                Label(L10n.text(error), systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.red)
                if !session.isStale && !session.sourceReadsBlocked {
                    Button(L10n.text("Retry")) { Task { await session.loadSources(force: true) } }
                        .disabled(session.isSelecting)
                }
            }
            if session.sources != nil {
                if visibleNodes.isEmpty {
                    let emptyMessage = onlyNodeIdentity == nil
                        ? "No visible Result or MultiResult sources are active on this map."
                        : (missingNodeMessage ?? "This MultiResult is not active on the selected map. Enable it in the map tree to edit its selections.")
                    ContentUnavailableView(L10n.text(emptyMessage), systemImage: "chart.xyaxis.line")
                        .frame(minHeight: 130)
                } else {
                    if session.isSelecting {
                        ProgressView(L10n.text("Updating result selection…"))
                            .controlSize(.small)
                    }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(visibleNodes) { node in
                                MapResultSourceNodeRow(node: node, session: session, store: store)
                            }
                        }
                    }
                    .frame(maxHeight: 390)
                }
            } else {
                ContentUnavailableView(L10n.text("Load the map's active result sources to choose chart inputs."),
                    systemImage: "chart.xyaxis.line")
                    .frame(minHeight: 130)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.16), in: RoundedRectangle(cornerRadius: 10))
        .task { if autoLoadSources { await session.loadSources() } }
    }
}

private struct MapResultSourceNodeRow: View {
    let node: MapResultChartActiveNode
    @ObservedObject var session: MapResultSourcesSession
    let store: WorkspaceStore?

    private var presentedNode: MapResultChartActiveNode { session.displayNode(node) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: node.nodeKind == "MultiResult" ? "square.stack.3d.up" : "doc.chart.line.uptrend.xyaxis")
                    .foregroundStyle(.secondary)
                Text(verbatim: node.name).font(.subheadline.weight(.semibold)).textSelection(.enabled)
                Text(L10n.text(node.nodeKind == "MultiResult" ? "Multiple Results" : "Result"))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if node.nodeKind == "MultiResult" {
                    Button {
                        Task { await session.addSelection(nodeID: node.id) }
                    } label: {
                        Label(L10n.text("Add Selection"), systemImage: "plus")
                    }
                    .disabled(session.selectionActionsBlocked
                        || presentedNode.selections.count >= 32)
                    .help(L10n.text("Add another Result selection slot."))
                }
            }

            ForEach(presentedNode.selections) { slot in
                MapResultSourceSelectionRow(node: presentedNode, slot: slot, session: session, store: store)
            }
        }
        .padding(10)
        .background(.background.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary, lineWidth: 1))
    }
}

private struct MapResultSourceSelectionRow: View {
    let node: MapResultChartActiveNode
    let slot: MapResultChartSelectionSlot
    @ObservedObject var session: MapResultSourcesSession
    let store: WorkspaceStore?

    private var canChooseModes: Bool { node.nodeKind == "MultiResult" }
    private var disabled: Bool { session.selectionActionsBlocked }

    private var liveCandidate: WorkspaceResultComputeEntry? {
        session.liveComputeCandidate(nodeID: node.id)
    }

    private var selectedLiveEntry: WorkspaceResultComputeEntry? {
        session.selectedLiveEntry(nodeID: node.id, selectionIndex: slot.selectionIndex)
    }

    private var livePickerTag: String? { liveCandidate.map { "live-run:\($0.runID)" } }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(L10n.format("Selection %d", slot.selectionIndex + 1))
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Picker(L10n.text("Result Selection"), selection: Binding(
                    get: { slot.selectionMode },
                    set: { newMode in Task { await session.setSelection(nodeID: node.id,
                        selectionIndex: slot.selectionIndex, mode: newMode) } })) {
                    ForEach(MapResultSelectionMode.allCases) { mode in
                        Text(L10n.text(mode.titleKey)).tag(mode)
                    }
                }
                .labelsHidden()
                .accessibilityLabel(L10n.text("Result Selection"))
                .pickerStyle(.segmented)
                .disabled(disabled || !canChooseModes)

                if node.nodeKind == "MultiResult" {
                    Button {
                        Task { await session.removeSelection(nodeID: node.id,
                            selectionIndex: slot.selectionIndex) }
                    } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless)
                    .disabled(disabled || node.selections.count <= 1)
                    .help(L10n.text("Remove this Result selection."))
                }
            }

            if slot.selectionMode == .explicit {
                if slot.choices.isEmpty && liveCandidate == nil {
                    Label(L10n.text("No stored Results are available for this selection."),
                        systemImage: "exclamationmark.circle")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Picker(L10n.text("Result"), selection: Binding(
                        get: { livePickerTag.flatMap { tag in selectedLiveEntry == nil ? nil : tag }
                            ?? slot.selectedResult?.id ?? "" },
                        set: { identifier in
                            if let liveCandidate, identifier == livePickerTag {
                                Task { await session.setSelection(nodeID: node.id,
                                    selectionIndex: slot.selectionIndex, mode: .explicit,
                                    liveRunID: liveCandidate.runID) }
                                return
                            }
                            guard let choice = slot.choices.first(where: { $0.id == identifier }) else { return }
                            Task { await session.setSelection(nodeID: node.id,
                                selectionIndex: slot.selectionIndex, mode: .explicit, choice: choice) }
                        })) {
                        Text(L10n.text("Choose a Result" )).tag("")
                        if let liveCandidate, let livePickerTag {
                            Text(L10n.format("Active compute — %@", liveCandidate.resultName)).tag(livePickerTag)
                        }
                        ForEach(slot.choices) { choice in
                            Text(choiceTitle(choice)).tag(choice.id)
                        }
                    }
                    .disabled(disabled)
                }
            }
            if let store {
                MapResultSourceSelectionDetails(node: node, slot: slot, session: session, store: store)
            } else if let selected = slot.selectedResult {
                if slot.selectionMode != .explicit {
                    HStack(spacing: 6) {
                        Text(verbatim: selected.resultName).textSelection(.enabled)
                        if let plan = selected.planName, !plan.isEmpty {
                            Text("•").foregroundStyle(.tertiary)
                            Text(verbatim: plan).foregroundStyle(.secondary)
                        }
                        if selected.isComputing {
                            Label(L10n.text("Computing"), systemImage: "hourglass")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .font(.caption)
                }
            } else if slot.selectionMode != .explicit {
                Label(L10n.text("This selection has no available stored Result."),
                    systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.leading, 24)
    }

    private func choiceTitle(_ choice: MapResultChartSourceChoice) -> String {
        if let endTime = choice.endTime, !endTime.isEmpty {
            return "\(choice.resultName) — \(endTime)"
        }
        return choice.resultName
    }

}

private struct MapResultSourceSelectionDetails: View {
    let node: MapResultChartActiveNode
    let slot: MapResultChartSelectionSlot
    @ObservedObject var session: MapResultSourcesSession
    @ObservedObject var store: WorkspaceStore

    private var liveEntry: WorkspaceResultComputeEntry? {
        if let explicitlyBoundRun = session.selectedLiveEntry(
            nodeID: node.id, selectionIndex: slot.selectionIndex) {
            return explicitlyBoundRun
        }
        guard slot.selectionMode == .latest else { return nil }
        return session.liveComputeCandidate(nodeID: node.id)
            ?? MultiResultSelectionProjection.transientLatestEntry(for: node,
                choices: slot.choices, projectSessionID: store.projectSessionID,
                isPlanComputeActive: store.isRunningPlanCompute,
                liveEntries: store.liveResultComputeByPath)
    }

    var body: some View {
        if let liveEntry {
            MapResultTransientLatestRow(entry: liveEntry)
        } else if let selected = slot.selectedResult {
            VStack(alignment: .leading, spacing: 5) {
                if slot.selectionMode != .explicit {
                    HStack(spacing: 6) {
                        Text(verbatim: selected.resultName).textSelection(.enabled)
                        if let plan = selected.planName, !plan.isEmpty {
                            Text("•").foregroundStyle(.tertiary)
                            Text(verbatim: plan).foregroundStyle(.secondary)
                        }
                        if selected.isComputing {
                            Label(L10n.text("Computing"), systemImage: "hourglass")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .font(.caption)
                }
                MapResultSourceSelectionStatus(node: node, choice: selected, store: store)
            }
        } else if slot.selectionMode != .explicit {
            Label(L10n.text("This selection has no available stored Result."),
                systemImage: "exclamationmark.circle")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct MapResultTransientLatestRow: View {
    let entry: WorkspaceResultComputeEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: symbol(for: entry.status))
                Text(L10n.format("Active Result: %@", L10n.text(entry.status.localizedTitle)))
                if entry.status == .running, let fraction = entry.fraction {
                    ProgressView(value: fraction).frame(maxWidth: 110)
                } else if entry.status == .running {
                    ProgressView().controlSize(.small)
                }
                Spacer(minLength: 0)
            }
            .font(.caption).foregroundStyle(entry.status == .failed ? .red : .secondary)
            Text(verbatim: entry.resultName).font(.caption.weight(.medium)).textSelection(.enabled)
            Text(verbatim: entry.resultPath).font(.caption2.monospaced()).foregroundStyle(.secondary)
                .textSelection(.enabled)
            LabeledContent(L10n.text("Run ID"), value: entry.runID)
                .font(.caption2).textSelection(.enabled)
            if let activity = entry.message ?? entry.taskName, !activity.isEmpty {
                Text(verbatim: activity).font(.caption2).foregroundStyle(.secondary)
            }
            if let reason = entry.failureReason, !reason.isEmpty {
                Text(verbatim: reason).font(.caption2).foregroundStyle(.red).textSelection(.enabled)
            }
            if let timeline = entry.profileTimeline {
                ForEach(timeline.blocks) { block in
                    Text(L10n.format("Output block %@: %d profile names and times received",
                        block.name, block.profiles.count))
                        .font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                    if let error = block.errorMessage {
                        Text(verbatim: error).font(.caption2).foregroundStyle(.orange).textSelection(.enabled)
                    }
                }
                if let error = timeline.metadataError {
                    Text(L10n.text(error)).font(.caption2).foregroundStyle(.orange).textSelection(.enabled)
                }
            }
            Label(L10n.text("Live profile metadata does not include readable raster frames."),
                systemImage: "questionmark.circle")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.leading, 24)
    }

    private func symbol(for status: WorkspaceResultComputeStatus) -> String {
        switch status {
        case .running: "hourglass"
        case .completed: "checkmark.circle.fill"
        case .failed: "xmark.octagon.fill"
        case .cancelled: "xmark.circle"
        case .unknown: "questionmark.circle"
        }
    }
}

private struct MapResultSourceSelectionStatus: View {
    let node: MapResultChartActiveNode
    let choice: MapResultChartSourceChoice
    @ObservedObject var store: WorkspaceStore
    @State private var diagnosticsExpanded = false

    private var presentation: WorkspaceResultComputePresentation {
        MultiResultSelectionProjection.computePresentation(for: node, choice: choice,
            projectSessionID: store.projectSessionID, liveEntries: store.liveResultComputeByPath)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: symbol(for: presentation.status))
                Text(L10n.text(presentation.status.localizedTitle))
                if presentation.isLive, let fraction = presentation.fraction {
                    ProgressView(value: fraction).frame(maxWidth: 110)
                }
                Spacer(minLength: 0)
            }
            .font(.caption).foregroundStyle(presentation.status == .failed ? .red : .secondary)

            if presentation.isLive {
                if let activity = presentation.message ?? presentation.taskName, !activity.isEmpty {
                    Text(verbatim: activity).font(.caption2).foregroundStyle(.secondary)
                }
            } else if presentation.status == .failed,
                      let reason = presentation.failureReason, !reason.isEmpty {
                Text(verbatim: reason).font(.caption2).foregroundStyle(.red).textSelection(.enabled)
            }

            diagnostics
        }
        .padding(.leading, 24)
    }

    @ViewBuilder
    private var diagnostics: some View {
        switch MultiResultSelectionProjection.diagnostics(for: choice) {
        case .unknown:
            Label(L10n.text("Diagnostics are unknown or unavailable."), systemImage: "questionmark.circle")
                .font(.caption2).foregroundStyle(.secondary)
        case .noIssues:
            Label(L10n.text("No stored diagnostic messages."), systemImage: "checkmark.circle")
                .font(.caption2).foregroundStyle(.secondary)
        case .readFailed(let message):
            VStack(alignment: .leading, spacing: 3) {
                Label(L10n.text("Diagnostic read failed"), systemImage: "exclamationmark.triangle")
                    .font(.caption2).foregroundStyle(.orange)
                if let message, !message.isEmpty {
                    Text(verbatim: message).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
        case .issues(let errors):
            DisclosureGroup(isExpanded: $diagnosticsExpanded) {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(Array(errors.enumerated()), id: \.offset) { _, error in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 5) {
                                Image(systemName: CatalogLayerDiagnosticSeverity(sourceValue: error.severity).symbol)
                                Text(verbatim: error.code.isEmpty
                                    ? L10n.text(CatalogLayerDiagnosticSeverity(sourceValue: error.severity).title)
                                    : error.code)
                                Text(L10n.text(CatalogLayerDiagnosticSeverity(sourceValue: error.severity).title))
                                    .foregroundStyle(.secondary).help(error.severity)
                            }
                            .font(.caption2)
                            if error.evaluatedMessage.isEmpty {
                                Text(L10n.text("No diagnostic message text is available."))
                                    .font(.caption2).foregroundStyle(.secondary)
                            } else {
                                Text(verbatim: error.evaluatedMessage)
                                    .font(.caption2).textSelection(.enabled)
                            }
                            ForEach(Array(error.logData.enumerated()), id: \.offset) { _, item in
                                HStack(alignment: .top, spacing: 5) {
                                    Text(verbatim: item.key).foregroundStyle(.secondary)
                                    Text(verbatim: item.value ?? L10n.text("(null)"))
                                        .textSelection(.enabled)
                                }.font(.caption2)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.leading, 8)
            } label: {
                Label(L10n.format("Diagnostics (%d)", errors.count), systemImage: "text.bubble")
                    .font(.caption2)
            }
        }
    }

    private func symbol(for status: WorkspaceResultComputeStatus) -> String {
        switch status {
        case .running: "hourglass"
        case .completed: "checkmark.circle.fill"
        case .failed: "xmark.octagon.fill"
        case .cancelled: "xmark.circle"
        case .unknown: "questionmark.circle"
        }
    }
}

/// Detached-window content for one captured polyline and source snapshot.
/// Window registration and routing are owned by the parent map workspace.
struct MapResultChartWindow: View {
    @ObservedObject var session: MapResultChartSession

    private var chartData: MapResultChartPresentationData? {
        guard let result = session.result else { return nil }
        return .init(samples: MapResultChartData.samples(for: result),
            presentation: MapResultChartData.presentation(for: result, mode: session.mode))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Label(L10n.text(session.mode.titleKey),
                    systemImage: session.mode == .flow ? "waveform.path.ecg" : "sum")
                    .font(.headline)
                Spacer()
                Button {
                    Task { await session.compute() }
                } label: {
                    Label(session.result == nil ? L10n.text("Compute") : L10n.text("Recompute"),
                        systemImage: "arrow.clockwise")
                }
                .disabled(!session.canCompute || session.isComputing)
            }

            capturedSourceSummary

            if session.sourceSnapshot.sources.activeNodes.contains(where: { node in
                node.selections.contains(where: { $0.selectedResult != nil })
            }) {
                Label(L10n.text("Computing this map-line chart may create or update a Result post-processing cache."),
                    systemImage: "externaldrive.badge.exclamationmark")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.yellow.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }

            if let result = session.result, !result.sideEffects.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(result.sideEffects) { effect in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(L10n.text("Result post-processing cache path"))
                                .font(.caption).foregroundStyle(.secondary)
                            if let path = effect.path, !path.isEmpty {
                                Text(verbatim: path).font(.caption2.monospaced()).textSelection(.enabled)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .padding(9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.yellow.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }

            if session.isComputing {
                OperationProgressView(title: L10n.text("Computing map line time series…"),
                    message: session.progressMessage ?? session.progressTaskName ?? "",
                    fraction: session.progressFraction, cancelling: session.isCancelling,
                    cancel: session.cancelComputation)
                    .padding(.vertical, 4)
            }

            if let error = session.errorMessage {
                Label(L10n.text(error), systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.red)
                if !session.isStale && !session.isComputing {
                    Button(L10n.text("Retry")) { Task { await session.compute() } }
                        .disabled(!session.canCompute)
                }
            }

            if let result = session.result, let chartData {
                if chartData.samples.isEmpty {
                    ContentUnavailableView(L10n.text("The selected results contain no plottable stored values for this line."),
                        systemImage: "chart.xyaxis.line")
                        .frame(minHeight: 220)
                } else {
                    SeriesChartView(samples: chartData.samples, presentation: chartData.presentation,
                        emptyMessage: L10n.text("The selected results contain no plottable stored values for this line."))
                        .frame(minHeight: 340)
                }
                ForEach(MapResultChartData.unavailableEntries(in: result)) { entry in
                    Label(L10n.format("%@ could not produce a map-line series: %@",
                        entry.series.resultName,
                        L10n.text(entry.series.unavailableReason ?? "The source did not provide a stored map-line series.")),
                        systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else if !session.isComputing && session.errorMessage == nil {
                ContentUnavailableView(L10n.text("Compute the selected results over this map line to plot stored values."),
                    systemImage: "chart.xyaxis.line")
                    .frame(minHeight: 240)
            }
        }
        .padding(14)
        .frame(minWidth: 620, minHeight: 480)
        .task { await session.startOnOpen() }
        .onDisappear { session.close() }
    }

    private var capturedSourceSummary: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(L10n.text("Captured Result Sources"))
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(session.sourceSnapshot.sources.activeNodes) { node in
                ForEach(node.selections) { slot in
                    HStack(spacing: 6) {
                        Text(verbatim: node.name).lineLimit(1)
                        Text(L10n.format("Selection %d", slot.selectionIndex + 1)).foregroundStyle(.secondary)
                        if let result = slot.selectedResult {
                            Text(verbatim: result.resultName).lineLimit(1)
                            if let type = node.selectedMapType, !type.isEmpty {
                                Text("•").foregroundStyle(.tertiary)
                                Text(verbatim: type).foregroundStyle(.secondary)
                            }
                        } else {
                            Text(L10n.text("No stored Result selected.")).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .font(.caption)
                }
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.18), in: RoundedRectangle(cornerRadius: 8))
    }

}
