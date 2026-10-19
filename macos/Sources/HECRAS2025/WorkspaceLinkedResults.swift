import RASWorkspaceCore
import SwiftUI

@MainActor
struct MapLinkedResultsSection: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var mapState: MapState
    @State private var pendingCapture: MapLinkedResultCapture?
    @State private var captureError: String?

    private var nodes: [MapResultChartActiveNode] {
        mapState.resultSources.sources?.activeNodes ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if mapState.linkedResults.isActive {
                linkedContextPanel
            } else {
                Label(L10n.text("Link Plans from a saved map Result slot"), systemImage: "link")
                    .font(.headline)
                if nodes.isEmpty {
                    Text(L10n.text("No active saved Result slots are available."))
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(nodes) { node in
                        GroupBox {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(verbatim: node.name).font(.subheadline.weight(.medium))
                                ForEach(node.selections) { slot in
                                    slotAction(node: node, slot: slot)
                                }
                            }
                        }
                    }
                }
            }
            if let captureError {
                Label(captureError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
        }
        .sheet(item: $pendingCapture) { capture in
            MapLinkedResultPicker(store: store, mapState: mapState, capture: capture)
        }
        .onChange(of: mapState.linkedResults.capture?.id) { _, newValue in
            if newValue == nil { captureError = nil }
        }
    }

    private func slotAction(node: MapResultChartActiveNode,
                            slot: MapResultChartSelectionSlot) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.format("Selection %d", slot.selectionIndex + 1))
                    .font(.caption.weight(.medium))
                if let result = slot.selectedResult {
                    Text(verbatim: result.resultName).font(.caption)
                    Text(verbatim: result.resultPath).font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                } else {
                    Text(L10n.text("No saved Result selected."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
            Button(L10n.text("Link Plans…")) { openPicker(node: node, slot: slot) }
                .disabled(slot.selectedResult == nil || slot.selectedResult?.isComputing == true
                    || mapState.resultSources.isLoading || mapState.resultSources.isSelecting
                    || store.isRunningProjectTool || store.document?.url == nil)
        }
    }

    private var linkedContextPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(L10n.text("Linked Result Context"), systemImage: "link")
                    .font(.headline)
                Spacer()
                Button(L10n.text("Return to Original Map Context")) {
                    mapState.returnToOriginalMapContext()
                }
            }
            if let anchor = mapState.linkedResults.selection?.anchor {
                Text(L10n.format("Anchor: %@", anchor.name)).font(.caption)
                Text(L10n.format("%d Results in %d selected plan groups",
                    mapState.linkedResults.selection?.results.count ?? 0,
                    mapState.linkedResults.selection?.selectedGroups.count ?? 0))
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Picker(L10n.text("Linked Map Type"), selection: Binding(
                    get: { mapState.linkedResults.mapType },
                    set: { value in Task { await mapState.linkedResults.setMapType(value, viewport: mapState.resultViewport) } })) {
                    ForEach(LinkedResultMapType.allCases) { type in
                        Text(L10n.text(type.labelKey)).tag(type)
                    }
                }
                .frame(width: 180)
                Button(L10n.text("Profile Map")) {
                    Task { await mapState.linkedResults.setFrameMode(.profile, viewport: mapState.resultViewport) }
                }
                .disabled(mapState.linkedResults.frameMode == .profile || mapState.linkedResults.isMapLoading)
                Button(L10n.text("Maximum Map")) {
                    Task { await mapState.linkedResults.setFrameMode(.maximum, viewport: mapState.resultViewport) }
                }
                .disabled(mapState.linkedResults.mapSnapshot?.maximumAvailable != true
                    || mapState.linkedResults.frameMode == .maximum || mapState.linkedResults.isMapLoading)
            }
            if mapState.linkedResults.isMapLoading {
                ProgressView(L10n.text("Rendering linked Results in this map…"))
                    .controlSize(.small)
            } else if let code = mapState.linkedResults.mapErrorCode {
                Label(L10n.format("Linked map request failed: %@", code), systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.red)
            } else if mapState.linkedResults.mapSnapshot?.layers.isEmpty == true {
                Text(L10n.text("No linked Result map layers are available for this shared profile."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !mapState.linkedResults.sourceFrames.isEmpty {
                Divider()
                ForEach(mapState.linkedResults.sourceFrames) { frame in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: frame.unavailableReason == nil ? "checkmark.circle" : "clock.badge.questionmark")
                            .foregroundStyle(frame.unavailableReason == nil ? .green : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: frame.name).font(.caption.weight(.medium))
                            if let index = frame.profileIndex {
                                Text(L10n.format("Matched profile %d", index)).font(.caption2)
                            }
                            if let time = frame.time {
                                Text(verbatim: time).font(.caption2.monospaced()).textSelection(.enabled)
                            }
                            if let reason = frame.unavailableReason {
                                Text(L10n.text(reason)).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
            if let profileError = mapState.linkedResults.profileError {
                Label(profileError, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.red)
            }
        }
    }

    private func openPicker(node: MapResultChartActiveNode, slot: MapResultChartSelectionSlot) {
        captureError = nil
        guard let result = slot.selectedResult, !result.isComputing,
              let snapshot = mapState.resultSources.snapshot,
              let projectURL = store.document?.url,
              let projectXML = store.document?.editorXML(overridingDescription: store.descriptionDraft) else {
            captureError = L10n.text("This action requires an exact saved Result selection and an open project.")
            return
        }
        do {
            pendingCapture = try MapLinkedResultCapture(projectSessionID: store.projectSessionID,
                mapID: mapState.id, mapWorkflowIdentity: store.mapWorkflowIdentity(mapState.id),
                projectPath: projectURL, projectXML: projectXML,
                contextToken: snapshot.sources.contextToken,
                sourceIdentity: mapState.linkedResultSourceIdentity,
                resultNodeIdentity: node.id, selectionIndex: slot.selectionIndex,
                anchorPath: result.resultPath, anchorRevision: result.revision)
        } catch {
            captureError = L10n.text(error.localizedDescription)
        }
    }
}

@MainActor
private struct MapLinkedResultPicker: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var mapState: MapState
    let capture: MapLinkedResultCapture
    @Environment(\.dismiss) private var dismiss
    @State private var context: ResultPlanContextSnapshot?
    @State private var selectedGroupIDs = Set<String>()
    @State private var isLoading = false
    @State private var isSubmitting = false
    @State private var errorMessage: String?

    private var projectURL: URL { URL(fileURLWithPath: capture.projectPath) }
    private var provider: BackendResultPlanContextProvider {
        BackendResultPlanContextProvider(client: mapState.linkedResults.client)
    }
    private var ownerIdentity: String {
        [store.projectSessionID.uuidString, store.mapWorkflowIdentity(mapState.id),
            mapState.linkedResultSourceIdentity,
            store.document?.url?.standardizedFileURL.path ?? ""].joined(separator: "\n")
    }
    private var canAccept: Bool {
        context != nil && !selectedGroupIDs.isEmpty && !isLoading && !isSubmitting && isCurrentOwner()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(L10n.text("Link Plans"), systemImage: "link")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button(L10n.text("Cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isSubmitting)
            }
            if isLoading {
                ProgressView(L10n.text("Reading saved Result plan groups…"))
            } else if let errorMessage {
                ContentUnavailableView(L10n.text("Plan groups could not be loaded."),
                    systemImage: "exclamationmark.triangle", description: Text(errorMessage))
            } else if let context, context.candidateGroups.isEmpty {
                ContentUnavailableView(L10n.text("No other saved plan groups are available for this Result."),
                    systemImage: "square.stack.3d.up")
            } else if let context {
                Text(L10n.format("Anchor Result: %@", context.anchor.name)).font(.subheadline)
                Text(L10n.text("Select whole plan groups. Every saved Result in a selected group will share the map timeline."))
                    .font(.caption).foregroundStyle(.secondary)
                List(context.candidateGroups) { group in
                    Toggle(isOn: groupBinding(group)) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(group.hasPlan ? (group.planName ?? "") : L10n.text("(no plan)"))
                                .font(.subheadline.weight(.medium))
                            Text(L10n.format("%d saved Results", group.results.count))
                                .font(.caption).foregroundStyle(.secondary)
                            ForEach(group.results) { result in
                                Text(verbatim: result.name).font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .toggleStyle(.checkbox)
                }
            }
            if let errorMessage, !isLoading {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            HStack {
                if isSubmitting { ProgressView(L10n.text("Linking Results to the current map…")).controlSize(.small) }
                Spacer()
                Button(L10n.text("Link Selected Plans"), action: accept)
                    .keyboardShortcut(.defaultAction).disabled(!canAccept)
            }
        }
        .padding(18).frame(minWidth: 550, idealWidth: 650, minHeight: 430, idealHeight: 550)
        .interactiveDismissDisabled(isSubmitting)
        .task(id: capture.id) { await loadContext() }
        .onChange(of: ownerIdentity) { _, _ in
            if !isCurrentOwner() { errorMessage = L10n.text("The map Result selection changed. Reopen Link Plans.") }
        }
    }

    private func groupBinding(_ group: ResultPlanCandidateGroup) -> Binding<Bool> {
        Binding(get: { selectedGroupIDs.contains(group.id) }, set: { enabled in
            if enabled { selectedGroupIDs.insert(group.id) }
            else { selectedGroupIDs.remove(group.id) }
        })
    }

    private func loadContext() async {
        isLoading = true; errorMessage = nil; context = nil; selectedGroupIDs = []
        defer { isLoading = false }
        guard isCurrentOwner() else {
            errorMessage = L10n.text("The map Result selection changed. Reopen Link Plans.")
            return
        }
        do {
            let loaded = try await provider.inspect(resultPath: URL(fileURLWithPath: capture.anchorPath),
                projectPath: projectURL, projectXml: capture.projectXML, revision: capture.anchorRevision)
            guard !Task.isCancelled, isCurrentOwner(),
                  MapLinkedResultCapture.canonical(loaded.projectPath) == MapLinkedResultCapture.canonical(capture.projectPath),
                  MapLinkedResultCapture.canonical(loaded.resultPath) == capture.anchorPath,
                  loaded.revision.caseInsensitiveCompare(capture.anchorRevision) == .orderedSame,
                  !loaded.projectRevision.isEmpty else {
                errorMessage = L10n.text("The map Result selection changed. Reopen Link Plans.")
                return
            }
            context = loaded
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = L10n.text(error.localizedDescription)
        }
    }

    private func accept() {
        guard canAccept, let context else { return }
        isSubmitting = true; errorMessage = nil
        let acceptedCapture = capture
        Task { [store, mapState] in
            defer { isSubmitting = false }
            do {
                let selection = try MapLinkedResultSelectionBuilder.build(context: context,
                    capture: capture, selectedGroupIDs: selectedGroupIDs)
                guard isCurrentOwner() else {
                    errorMessage = L10n.text("The map Result selection changed. Reopen Link Plans.")
                    return
                }
                let activated = try await mapState.activateLinkedResults(selection, capture: capture,
                    projectXML: capture.projectXML, viewport: mapState.resultViewport,
                    ownerIsCurrent: { [weak store, weak mapState] in
                        guard let store, let mapState else { return false }
                        return acceptedCapture.matches(projectSessionID: store.projectSessionID,
                            mapWorkflowIdentity: store.mapWorkflowIdentity(mapState.id),
                            projectPath: store.document?.url,
                            projectXML: store.document?.editorXML(overridingDescription: store.descriptionDraft),
                            sourceIdentity: mapState.linkedResultSourceIdentity,
                            sources: mapState.resultSources.snapshot)
                    })
                guard activated, isCurrentOwner() else {
                    errorMessage = L10n.text("The map Result context changed before the linked Results could be activated.")
                    return
                }
                dismiss()
            } catch {
                errorMessage = L10n.text(error.localizedDescription)
            }
        }
    }

    private func isCurrentOwner() -> Bool {
        capture.matches(projectSessionID: store.projectSessionID,
            mapWorkflowIdentity: store.mapWorkflowIdentity(mapState.id),
            projectPath: store.document?.url,
            projectXML: store.document?.editorXML(overridingDescription: store.descriptionDraft),
            sourceIdentity: mapState.linkedResultSourceIdentity,
            sources: mapState.resultSources.snapshot)
    }
}

@MainActor
struct MapLinkedProfileTimeline: View {
    @ObservedObject var mapState: MapState

    private var context: MapLinkedResultContextSession { mapState.linkedResults }
    private var viewport: RasterMapViewExtent? { mapState.resultViewport }

    var body: some View {
        HStack(spacing: 9) {
            Button { Task { await context.selectProfile(context.profileIndex - 1, viewport: viewport) } } label: {
                Image(systemName: "backward.frame")
            }
            .disabled(!context.steps.contains { $0.profileIndex == context.profileIndex - 1 } || context.isProfileLoading)
            .accessibilityLabel(L10n.text("Previous Linked Profile"))
            Picker(L10n.text("Shared Profile"), selection: Binding(get: { context.profileIndex }, set: { index in
                Task { await context.selectProfile(index, viewport: viewport) }
            })) {
                ForEach(context.steps) { step in Text(verbatim: step.name).tag(step.profileIndex) }
            }
            .disabled(context.steps.isEmpty || context.isProfileLoading)
            Button { Task { await context.selectProfile(context.profileIndex + 1, viewport: viewport) } } label: {
                Image(systemName: "forward.frame")
            }
            .disabled(!context.steps.contains { $0.profileIndex == context.profileIndex + 1 } || context.isProfileLoading)
            .accessibilityLabel(L10n.text("Next Linked Profile"))
            if let step = context.currentStep {
                Text(verbatim: step.time).font(.caption.monospaced()).textSelection(.enabled)
            }
            if context.isProfileLoading || context.isMapLoading { ProgressView().controlSize(.small) }
            if let error = context.profileError {
                Text(error).font(.caption).foregroundStyle(.red).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.regularMaterial)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.text("Linked Result shared timeline"))
    }
}
