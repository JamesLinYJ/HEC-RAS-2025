import RASWorkspaceCore
import SwiftUI

struct PlanComputePage: View {
    @ObservedObject var compute: PlanComputeSession
    @ObservedObject var store: WorkspaceStore
    let planEditorID: UUID
    let projectSessionID: UUID
    let context: PlanPrecomputeContext?
    let isResult: Bool
    let isCurrent: @MainActor (String) -> Bool
    let begin: @MainActor (PlanComputeInspection) -> Bool
    let end: @MainActor () -> Void
    let completed: @MainActor (PlanComputeExecutionResult) -> Void

    private var matchingInspection: PlanComputeInspection? {
        guard let context, compute.inspectionContextID == context.id else { return nil }
        return compute.inspection
    }
    private var matchingResult: PlanComputeExecutionResult? {
        return compute.executionResult
    }
    private var matchingLiveMessageStream: PlanComputeJobMessageStream? {
        guard let context, compute.liveMessageStream.contextID == context.id else { return nil }
        return compute.liveMessageStream
    }

    var body: some View {
        Form {
            Section("Plan Compute") {
                HStack {
                    Button {
                        guard let context else { return }
                        Task { _ = await compute.inspect(context: context, isCurrent: isCurrent) }
                    } label: {
                        Label(L10n.text("Inspect Compute"), systemImage: "checkmark.magnifyingglass")
                    }
                    .disabled(context == nil || isResult || compute.isInspecting || compute.isRunning || !compute.isAvailable)

                    Button {
                        guard let context, let inspection = matchingInspection else { return }
                        Task {
                            _ = await compute.execute(context: context, inspection: inspection,
                                isCurrent: isCurrent, begin: begin, end: end, completed: completed)
                        }
                    } label: {
                        Label(L10n.text("Run Compute"), systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(context == nil || isResult || matchingInspection?.canExecute != true ||
                        compute.isRunning || compute.isInspecting || !compute.isAvailable)

                    if compute.isRunning {
                        Button(role: .destructive) { compute.cancel() } label: {
                            Label(L10n.text(compute.isCancelling ? "Cancellation Requested" : "Cancel Compute"),
                                  systemImage: "stop.fill")
                        }
                        .disabled(compute.isCancelling)
                    }
                }
                if compute.isInspecting { ProgressView(L10n.text("Inspecting source plan…")) }
                if let error = compute.errorMessage {
                    Label(L10n.text(error), systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
                if isResult {
                    Label(L10n.text("Only source plans can start a compute."), systemImage: "lock.fill")
                        .foregroundStyle(.secondary)
                } else if !compute.isAvailable {
                    Label(L10n.text("No active compute provider is available."), systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                } else if context == nil {
                    Label(L10n.text("Load a source plan to inspect or run compute."), systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                }
            }

            if let inspection = matchingInspection {
                Section("Source Solver Readiness") {
                    Label(L10n.text(inspection.canExecute ? "The source solver is ready." : "The source solver cannot run this plan."),
                          systemImage: inspection.canExecute ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .foregroundStyle(inspection.canExecute ? .green : .red)
                    ForEach(Array(inspection.reasons.enumerated()), id: \.offset) { _, reason in
                        Text(L10n.text(reason)).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    if !inspection.messages.isEmpty {
                        PlanDiagnosticOperationResultView(result: .init(revision: inspection.revision,
                            result: inspection.canExecute, messages: inspection.messages), store: store,
                            onNavigate: { target in
                                guard let context, isCurrent(context.id),
                                      matchingInspection?.inspectionId == inspection.inspectionId else { return false }
                                return compute.onNavigateDiagnosticTarget?(target, context.id) == true
                            }, isTargetCurrent: { target in
                                guard let context, isCurrent(context.id),
                                      matchingInspection?.inspectionId == inspection.inspectionId else { return false }
                                return diagnosticTargetIsCurrent(target, contextID: context.id)
                            }, onCompute: computeFromDiagnostic)
                    } else {
                        Text(L10n.text("No source validation messages."))
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Source Compute Side Effects") {
                    ForEach(Array(inspection.sideEffects.enumerated()), id: \.offset) { _, effect in
                        Label(L10n.text(effect), systemImage: "arrow.right.circle")
                            .textSelection(.enabled)
                    }
                }

                Section("Source Dependencies") {
                    ForEach(inspection.sourceDependencies) { dependency in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(dependencyRoleLabel(dependency.role)).font(.headline)
                                Spacer()
                                Text(L10n.text(dependency.willWrite ? "Source compute writes this file" : "Read by source compute"))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Text(dependency.path)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                            Text(dependency.revision)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        .padding(.vertical, 3)
                    }
                }
            }

            if compute.isRunning {
                Section("Compute Progress") {
                    if let fraction = compute.progress.fraction {
                        ProgressView(value: fraction)
                        Text("\(Int(fraction * 100))%")
                            .monospacedDigit().foregroundStyle(.secondary)
                    } else {
                        ProgressView()
                    }
                    if let task = compute.progress.taskName {
                        Text(L10n.text(task)).font(.headline)
                    }
                    if let message = compute.progress.message {
                        Text(L10n.text(message)).textSelection(.enabled)
                    }
                    if compute.isCancelling {
                        Label(L10n.text("Cancellation requested; waiting for the source solver."),
                              systemImage: "hourglass")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let liveMessageStream = matchingLiveMessageStream {
                Section("Live Solver Messages") {
                    PlanComputeJobMessagesView(runID: liveMessageStream.runID,
                        messages: liveMessageStream.messages,
                        issue: liveMessageStream.issue,
                        store: store,
                        onNavigate: liveMessageNavigation,
                        isTargetCurrent: liveMessageTargetIsCurrent,
                        onCompute: computeFromDiagnostic)
                }
            }

            if !compute.sourceValues.isEmpty {
                Section("Live Timestep Statistics") {
                    ForEach(Array(compute.sourceValues.keys.sorted()), id: \.self) { key in
                        LabeledContent(L10n.text(valueLabel(key)), value: compute.sourceValues[key] ?? "—")
                            .monospacedDigit()
                            .textSelection(.enabled)
                    }
                }
            }

            if let result = matchingResult {
                Section("Compute Result") {
                    if compute.executionContextID != context?.id {
                        Label(L10n.text("The last computation used previous plan settings."), systemImage: "clock.arrow.circlepath")
                            .foregroundStyle(.secondary)
                    }
                    Label(stateTitle(result.state), systemImage: stateSymbol(result.state))
                        .foregroundStyle(stateColor(result.state))
                    if let error = result.errorMessage {
                        Text(L10n.text(error)).foregroundStyle(.red).textSelection(.enabled)
                    }
                    if let path = result.resultPath {
                        LabeledContent(L10n.text("Result HDF"), value: path)
                            .textSelection(.enabled)
                        if let revision = result.resultRevision {
                            LabeledContent(L10n.text("Result SHA-256"), value: revision)
                                .textSelection(.enabled)
                        }
                    } else {
                        Text(L10n.text("No result file was created."))
                            .foregroundStyle(.secondary)
                    }
                    if let summary = result.summary {
                        summaryRows(summary)
                    }
                    if !result.finalDependencies.isEmpty {
                        DisclosureGroup(L10n.text("Final Source Revisions")) {
                            ForEach(result.finalDependencies) { dependency in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(dependencyRoleLabel(dependency.role)).font(.caption.weight(.semibold))
                                    Text(dependency.path).font(.caption.monospaced()).textSelection(.enabled)
                                    Text(dependency.revision).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                                }
                                .padding(.vertical, 3)
                            }
                        }
                    }
                    if !result.messages.isEmpty {
                        PlanDiagnosticOperationResultView(result: .init(revision: result.revision,
                            result: result.state == "completed", messages: result.messages),
                            store: store,
                            onNavigate: resultNavigation,
                            isTargetCurrent: resultTargetIsCurrent,
                            onCompute: computeFromDiagnostic)
                    }
                    if let log = result.summary?.computeLog, !log.isEmpty {
                        DisclosureGroup(L10n.text("Source Compute Log")) {
                            ScrollView([.horizontal, .vertical]) {
                                Text(log).font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(minHeight: 100)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: context?.id) { _, value in compute.clearIfStale(currentContextID: value) }
    }

    private var liveMessageNavigation: (@MainActor (PlanDiagnosticTarget) -> Bool)? {
        guard let context, isCurrent(context.id), compute.liveMessageStream.contextID == context.id else { return nil }
        return { target in compute.onNavigateDiagnosticTarget?(target, context.id) == true }
    }

    private var resultNavigation: (@MainActor (PlanDiagnosticTarget) -> Bool)? {
        guard let context, isCurrent(context.id), compute.executionContextID == context.id else { return nil }
        return { target in compute.onNavigateDiagnosticTarget?(target, context.id) == true }
    }

    private var liveMessageTargetIsCurrent: (@MainActor (PlanDiagnosticTarget) -> Bool)? {
        guard let context, isCurrent(context.id),
              compute.liveMessageStream.contextID == context.id else { return nil }
        return { target in self.diagnosticTargetIsCurrent(target, contextID: context.id) }
    }

    private var resultTargetIsCurrent: (@MainActor (PlanDiagnosticTarget) -> Bool)? {
        guard let context, isCurrent(context.id), compute.executionContextID == context.id else { return nil }
        return { target in self.diagnosticTargetIsCurrent(target, contextID: context.id) }
    }

    private func diagnosticTargetIsCurrent(_ target: PlanDiagnosticTarget, contextID: String) -> Bool {
        guard isCurrent(contextID), store.activeTab == .editor(.plan),
              store.projectSessionID == projectSessionID,
              !store.isClosingTab else { return false }
        return store.isCurrentPlanDiagnosticTarget(target,
            projectSessionID: projectSessionID, planEditorID: planEditorID,
            planContextID: contextID)
    }

    private func computeFromDiagnostic(_ target: PlanDiagnosticTarget) async -> Bool {
        if target.kind == "geometry" {
            guard let context, diagnosticTargetIsCurrent(target, contextID: context.id) else { return false }
            return await store.requestGeometryPropertyTables(from: target, projectSessionID: projectSessionID,
                planEditorID: planEditorID, planContextID: context.id)
        }
        guard target.kind == "plan", let context, isCurrent(context.id),
              let inspection = matchingInspection, inspection.canExecute,
              diagnosticTargetIsCurrent(target, contextID: context.id),
              !compute.isRunning, !compute.isInspecting,
              await PlanDiagnosticFileFingerprint.matches(target),
              diagnosticTargetIsCurrent(target, contextID: context.id),
              let result = await compute.execute(context: context, inspection: inspection,
                isCurrent: isCurrent, begin: begin, end: end, completed: completed) else { return false }
        return result.state == "completed"
    }

    @ViewBuilder
    private func summaryRows(_ summary: PlanComputeSummary) -> some View {
        LabeledContent(L10n.text("Solver Success"), value: L10n.text(summary.success ? "Yes" : "No"))
        if let solver = summary.solver { LabeledContent(L10n.text("Solver"), value: solver) }
        if let software = summary.softwareVersion { LabeledContent(L10n.text("Software Version"), value: software) }
        if let start = summary.startTime { LabeledContent(L10n.text("Start Time"), value: start) }
        if let end = summary.endTime { LabeledContent(L10n.text("End Time"), value: end) }
        if let duration = summary.totalDurationSeconds { LabeledContent(L10n.text("Total Duration"), value: duration.formatted()) }
        if let duration = summary.solverInitDurationSeconds { LabeledContent(L10n.text("Solver Initialization Duration"), value: duration.formatted()) }
        if let duration = summary.outputDurationSeconds { LabeledContent(L10n.text("Output Duration"), value: duration.formatted()) }
        if let retries = summary.globalRetryCount { LabeledContent(L10n.text("Global Retry Count"), value: retries.formatted()) }
        if let failure = summary.failureReason { LabeledContent(L10n.text("Failure Reason"), value: L10n.text(failure)).textSelection(.enabled) }
    }

    private func valueLabel(_ key: String) -> String {
        let labels: [String: String] = [
            "Steps": "Steps", "LastIterations": "Last Iterations",
            "LastGlobalTimestep": "Global Timestep", "LastMaxGlobalTimestep": "Maximum Global Timestep",
            "LastLimitingCell": "Limiting Cell", "LastLimitingFace": "Limiting Face",
            "LastActiveCells": "Active Cells", "WetCellCount": "Wet Cells", "DryCellCount": "Dry Cells",
            "TotalCellCount": "Total Cells", "PercentWet": "Percent Wet", "SimulationTime": "Simulation Time",
            "ElapsedTime": "Elapsed Time", "EstimatedTimeRemaining": "Estimated Time Remaining",
            "ComputationalSpeed": "Computational Speed", "Retries": "Retries",
            "RetryElevationCount": "Elevation Retries", "RetryNaNCount": "NaN Retries",
            "RetryNegVolumeCount": "Negative Volume Retries", "AdvectionLimitCount": "Advection Limits",
            "UserLimitCount": "User Limits", "CelerityLimitCount": "Celerity Limits",
            "IncreaseLimitCount": "Increase Limits"
        ]
        return labels[key] ?? key
    }

    private func dependencyRoleLabel(_ role: String) -> String {
        let labels: [String: String] = [
            "Project": "Project", "Plan": "Plan", "Geometry": "Geometry",
            "BoundaryCondition": "Boundary Conditions", "Terrain": "Terrain",
            "TerrainRaster": "Terrain Raster", "NValues": "N-Values Layer",
            "NValueClassification": "N-Value Classification",
            "BoundaryPayloadInput": "Boundary Payload Input",
            "BoundaryInitialConditionInput": "Boundary Initial Condition Input",
            "BoundarySpatialInput": "Boundary Spatial Input",
            "ResultOutput": "Result Output", "Result": "Result HDF"
        ]
        return L10n.text(labels[role] ?? role)
    }

    private func stateTitle(_ state: String) -> String {
        switch state {
        case "completed": L10n.text("Plan compute completed.")
        case "cancelled": L10n.text("Plan compute was cancelled.")
        default: L10n.text("Plan compute failed.")
        }
    }

    private func stateSymbol(_ state: String) -> String {
        switch state {
        case "completed": "checkmark.circle.fill"
        case "cancelled": "stop.circle.fill"
        default: "xmark.octagon.fill"
        }
    }

    private func stateColor(_ state: String) -> Color {
        switch state {
        case "completed": .green
        case "cancelled": .orange
        default: .red
        }
    }
}
