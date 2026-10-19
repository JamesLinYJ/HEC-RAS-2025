import SwiftUI

/// Presents the source Result's embedded Plan snapshot and opens the Plan
/// picker with candidates returned for that exact result and project draft.
/// Acceptance is always handed to the owning Result page, which opens the
/// source-backed linked-profile workspace.
struct ResultPlanAssociationPanel: View {
    @ObservedObject var session: ResultPlanContextSession
    let onLinkedResultSelection: @MainActor (LinkedResultSelection) -> Void
    var isCompact = false

    @State private var showingPicker = false
    @State private var acceptedSelection: LinkedResultSelection?
    @State private var pendingSelection: LinkedResultSelection?

    private var snapshot: ResultPlanContextSnapshot? { session.snapshot }
    private var identity: String {
        [snapshot?.projectPath ?? "", snapshot?.projectRevision ?? "",
         snapshot?.resultPath ?? "", snapshot?.revision ?? "",
         session.coreLayerContext?.identityToken ?? "",
         snapshot?.candidateGroups.flatMap(\.results).map(\.id).joined(separator: "\n") ?? ""]
            .joined(separator: "\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if session.isLoading {
                ProgressView(L10n.text("Loading embedded plan context…"))
                    .controlSize(.small)
            } else if let error = session.error {
                VStack(alignment: .leading, spacing: 8) {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red).font(.caption)
                    Button {
                        Task { await reload() }
                    } label: {
                        Label(L10n.text("Refresh"), systemImage: "arrow.clockwise")
                    }
                }
            } else if let snapshot {
                if !isCompact {
                    embeddedPlanDetails(snapshot)
                }
                if snapshot.candidateGroups.isEmpty {
                    Label(L10n.text("No other plans to link."), systemImage: "link")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let acceptedSelection,
                   acceptedSelection.anchor.resultPath == snapshot.resultPath,
                   acceptedSelection.anchor.revision == snapshot.revision {
                    acceptedSelectionDetails(acceptedSelection)
                }
            } else {
                Text(L10n.text("Open a saved project result to inspect its embedded plan."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(isCompact ? 10 : 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
        .sheet(isPresented: $showingPicker, onDismiss: finishPicker) {
            if let snapshot {
                ResultPlanPickerDialogView(snapshot: snapshot) { selection in
                    acceptedSelection = selection
                    pendingSelection = selection
                }
            }
        }
        .onChange(of: identity) { _, _ in
            acceptedSelection = nil
            pendingSelection = nil
            showingPicker = false
        }
    }

    private func finishPicker() {
        guard let selection = pendingSelection else { return }
        pendingSelection = nil
        onLinkedResultSelection(selection.withCoreLayerContext(session.coreLayerContext))
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.text("Embedded Plan Context")).font(.headline)
                if let snapshot {
                    Text(snapshot.anchorHasPlan ? (snapshot.anchorPlanName ?? "") : L10n.text("No Plan"))
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            Spacer(minLength: 8)
            Button {
                Task { await reload() }
            } label: {
                Label(L10n.text("Refresh"), systemImage: "arrow.clockwise")
            }
            .disabled(session.isLoading || snapshot == nil)
            .help(L10n.text("Reload embedded Plan details and saved Result candidates."))

            Button {
                showingPicker = true
            } label: {
                Label(L10n.text("Link Plans…"), systemImage: "link")
            }
            .disabled(session.isLoading || session.error != nil || snapshot?.candidateGroups.isEmpty != false)
            .help(L10n.text("Choose other Result plans for a linked profile context."))
        }
    }

    @ViewBuilder
    private func embeddedPlanDetails(_ snapshot: ResultPlanContextSnapshot) -> some View {
        if snapshot.embeddedPlanGroups.isEmpty {
            Text(L10n.text("No embedded Plan computation details are available."))
                .font(.caption).foregroundStyle(.secondary)
        } else {
            ForEach(snapshot.embeddedPlanGroups) { group in
                VStack(alignment: .leading, spacing: 5) {
                    Text(L10n.text(group.title)).font(.subheadline.weight(.semibold))
                    ForEach(group.items) { item in
                        LabeledContent(L10n.text(item.label),
                            value: item.isLocalizedValue ? L10n.text(item.value) : item.value)
                            .font(.caption)
                            .textSelection(.enabled)
                    }
                }
                .padding(.vertical, 3)
            }
        }
    }

    private func acceptedSelectionDetails(_ selection: LinkedResultSelection) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Divider()
            Text(L10n.text("Selected Results")).font(.subheadline.weight(.semibold))
            Text(L10n.format("%d results across %d plans are selected.",
                             selection.results.count, selection.planCount))
                .font(.caption).foregroundStyle(.secondary)
            ForEach(selection.results) { result in
                Label(result.name, systemImage: result.id == selection.anchor.id ? "largecircle.fill.circle" : "circle")
                    .font(.caption).textSelection(.enabled)
            }
        }
    }

    @MainActor
    private func reload() async {
        // The parent page owns the actual project and inspector inputs. Its
        // task will reload this session when the source identity changes.
        // A direct refresh is triggered through the session's retained context.
        await session.reloadCurrentContext()
    }
}

private struct ResultPlanPickerDialogView: View {
    @Environment(\.dismiss) private var dismiss
    let snapshot: ResultPlanContextSnapshot
    let onAccept: (LinkedResultSelection) -> Void
    @State private var selectedGroupIDs = Set<String>()

    private var allGroupIDs: Set<String> { Set(snapshot.candidateGroups.map(\.id)) }
    private var allSelected: Bool { !allGroupIDs.isEmpty && selectedGroupIDs == allGroupIDs }
    private var selectedGroups: [ResultPlanCandidateGroup] {
        snapshot.candidateGroups.filter { selectedGroupIDs.contains($0.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.text("Link Plans")).font(.title2.weight(.semibold))
                Text(L10n.format("Anchor: %@. Pick plans to scrub together.", snapshot.anchorName))
                    .font(.callout).foregroundStyle(.secondary)
            }

            HStack {
                Label(L10n.text("Available Result Plans"), systemImage: "square.stack.3d.up")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Button {
                    selectedGroupIDs = allSelected ? [] : allGroupIDs
                } label: {
                    Label(L10n.text(allSelected ? "Deselect All" : "Select All"),
                          systemImage: allSelected ? "checkmark.square" : "square")
                }
                .disabled(allGroupIDs.isEmpty)
            }

            if snapshot.candidateGroups.isEmpty {
                ContentUnavailableView(L10n.text("No other plans to link."),
                    systemImage: "link", description: Text(L10n.text("This Result has no other saved Result plans in the current project.")))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(snapshot.candidateGroups) { group in
                            groupChoice(group)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            HStack {
                Spacer()
                Button(L10n.text("Cancel"), role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(L10n.text("Link Plans")) { accept() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selectedGroups.isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 480, idealWidth: 560, minHeight: 360, idealHeight: 470)
    }

    private func groupChoice(_ group: ResultPlanCandidateGroup) -> some View {
        let isSelected = Binding(
            get: { selectedGroupIDs.contains(group.id) },
            set: { checked in
                if checked { selectedGroupIDs.insert(group.id) }
                else { selectedGroupIDs.remove(group.id) }
            }
        )
        return Toggle(isOn: isSelected) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(group.hasPlan ? (group.planName ?? "") : L10n.text("(no plan)"))
                        .font(.body.weight(.medium)).textSelection(.enabled)
                    Text(resultCountLabel(group.results.count))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "arrow.trianglehead.2.clockwise.rotate.90")
                    .foregroundStyle(.tertiary)
            }
        }
        .toggleStyle(.checkbox)
        .padding(10)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
    }

    private func resultCountLabel(_ count: Int) -> String {
        count == 1 ? L10n.text("1 result") : L10n.format("%d results", count)
    }

    private func accept() {
        guard !selectedGroups.isEmpty else { return }
        let selection = LinkedResultSelection(projectPath: snapshot.projectPath,
            projectRevision: snapshot.projectRevision, anchor: snapshot.anchor,
            selectedGroups: selectedGroups)
        guard selection.results.count == 1 + selectedGroups.reduce(0, { $0 + $1.results.count }) else { return }
        onAccept(selection)
        dismiss()
    }
}

/// Read-only equivalent of the source ResultPlanAssociationsViewer. Values
/// are the nested associations on this exact Result's embedded Plan.
struct ResultPlanAssociationSection: View {
    @ObservedObject var session: PlanResultAssociationSession

    var body: some View {
        Section(L10n.text("Embedded Plan Associations")) {
            HStack {
                Text(L10n.text("Associations stored in this Result's Plan"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    Task { await session.reloadCurrentContext() }
                } label: {
                    Label(L10n.text("Refresh"), systemImage: "arrow.clockwise")
                }
                .disabled(session.isLoading)
            }

            if session.isLoading {
                ProgressView(L10n.text("Reading embedded Plan associations…"))
                    .controlSize(.small)
            }

            if let error = session.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            if let snapshot = session.snapshot {
                if snapshot.hasPlan {
                    LabeledContent(L10n.text("Plan"), value: snapshot.planName ?? "—")
                        .textSelection(.enabled)
                    if let geometryName = snapshot.geometryName {
                        LabeledContent(L10n.text("Geometry"), value: geometryName)
                            .textSelection(.enabled)
                    }
                    if let boundaryConditionName = snapshot.boundaryConditionName {
                        LabeledContent(L10n.text("Boundary Condition"), value: boundaryConditionName)
                            .textSelection(.enabled)
                    }
                    if snapshot.geometryName == nil || snapshot.boundaryConditionName == nil {
                        Text(L10n.text("One or more associations are not stored on the embedded Plan."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text(L10n.text("No embedded Plan is stored in this Result."))
                        .foregroundStyle(.secondary)
                }
            } else if !session.isLoading && session.error == nil {
                Text(L10n.text("No embedded Plan association data is available."))
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("resultEmbeddedPlanAssociations")
    }
}
