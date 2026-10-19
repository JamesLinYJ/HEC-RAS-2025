import SwiftUI

// PlanComputeControl and ComputeSummaryControl stay distinct so the live job
// state and its persisted summary can be read independently.
struct ComputePage: View {
    @ObservedObject var session: ModelEditorSession
    @ObservedObject var store: WorkspaceStore
    @State private var logQuery = ""

    private var log: String { session.fields["ComputeSummary_ComputeLog"] ?? "" }
    private var filteredLog: String {
        logQuery.isEmpty ? log : log.components(separatedBy: .newlines)
            .filter { $0.localizedCaseInsensitiveContains(logQuery) }
            .joined(separator: "\n")
    }

    var body: some View {
        if session.isSourcePlan, let compute = session.planCompute {
            VStack(spacing: 0) {
                PlanComputePage(compute: compute, store: store, planEditorID: session.id,
                    projectSessionID: store.projectSessionID, context: session.currentPlanComputeContext(),
                    isResult: false, isCurrent: { session.isCurrentPlanComputeContext($0) },
                    begin: { session.beginPlanCompute?($0) == true },
                    end: { session.endPlanCompute?() }, completed: { session.didComputePlan?($0) })
                if let path = compute.result?.resultPath,
                   let asset = store.assets.first(where: { $0.section == .results && $0.url.standardizedFileURL.resolvingSymlinksInPath().path == URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path }) {
                    Divider()
                    HStack {
                        Button { store.openEditor(.result, assetID: asset.id) } label: { Label("Open Result", systemImage: "chart.xyaxis.line") }
                            .disabled(store.isRunningPlanCompute)
                        Spacer()
                    }.padding(12)
                }
            }
        } else {
            persistedResultView
        }
    }

    private var persistedResultView: some View {
        VSplitView {
            Form {
                PlanComputeControl(session: session, store: store)
                ComputeSummaryControl(session: session)
            }
            .formStyle(.grouped)
            .frame(minHeight: 250)

            VStack(spacing: 0) {
                HStack {
                    Text("Compute Log").font(.headline)
                    TextField("Search log", text: $logQuery).textFieldStyle(.roundedBorder)
                    Button { store.system.copy(log) } label: { Label("Copy", systemImage: "doc.on.doc") }
                        .disabled(log.isEmpty)
                }
                .padding(12)
                ScrollView([.horizontal, .vertical]) {
                    Text(filteredLog.isEmpty ? "—" : filteredLog)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(12)
                }
            }
            .frame(minHeight: 160)
        }
    }
}

struct PlanComputeControl: View {
    @ObservedObject var session: ModelEditorSession
    @ObservedObject var store: WorkspaceStore

    private func value(_ key: String) -> String { session.fields[key] ?? "—" }
    private var isRunning: Bool { session.fields["IsComputeRunning"]?.lowercased() == "true" }
    private var computeSucceeded: Bool? {
        switch session.fields["ComputeSummary_Success"]?.lowercased() {
        case "true": true
        case "false": false
        default: nil
        }
    }

    var body: some View {
        Group {
            Section("Compute Status") {
                if let state = session.fields["IsComputeRunning"] {
                    if state.lowercased() == "true" {
                        Label("Running", systemImage: "hourglass")
                    } else if let succeeded = computeSucceeded {
                        Label(LocalizedStringKey(succeeded ? "Completed Successfully" : "Failed"),
                              systemImage: succeeded ? "checkmark.circle" : "exclamationmark.triangle")
                            .foregroundStyle(succeeded ? Color.green : .red)
                    } else {
                        LabeledContent("Status", value: "—")
                    }
                } else {
                    LabeledContent("Status", value: "—")
                }
                if let progress = Double(session.fields["Job_Progress"] ?? ""),
                   progress.isFinite, (0...100).contains(progress) {
                    ProgressView(value: progress, total: 100)
                        .accessibilityLabel("Compute Progress")
                    Text("\(progress.formatted())%")
                        .monospacedDigit()
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Simulation Time", value: value("SimulationTime"))
                LabeledContent("Elapsed Time", value: value("ElapsedTime"))
                LabeledContent("Estimated Time Remaining", value: value("EstimatedTimeRemaining"))
                LabeledContent("Computational Speed", value: value("ComputationalSpeed"))
                PlaybackControls(
                    isStopped: !isRunning,
                    pending: session.fields["Job_ID"].map { store.pendingJobActions.contains($0) } ?? false,
                    stop: cancellableJob.map { job in
                        { _ = Task<Void, Never> { await store.cancelJob(job.id) } }
                    }
                )
            }

            Section("Timestep Statistics") {
                ForEach([
                    ("Steps", "Steps"), ("Iterations", "LastIterations"),
                    ("Global Timestep", "LastGlobalTimestep"),
                    ("Maximum Global Timestep", "LastMaxGlobalTimestep"),
                    ("Limiting Cell", "LastLimitingCell"), ("Limiting Face", "LastLimitingFace"),
                    ("Active Cells", "LastActiveCells"), ("Wet Cells", "WetCellCount"),
                    ("Dry Cells", "DryCellCount"), ("Total Cells", "TotalCellCount"),
                    ("Percent Wet", "PercentWet")
                ], id: \.1) { label, key in
                    LabeledContent(LocalizedStringKey(label), value: value(key)).monospacedDigit()
                }
                ViewThatFits(in: .horizontal) {
                    HStack {
                        monitor("Percent Wet", key: "PercentWet")
                        monitor("Global Timestep", key: "LastGlobalTimestep")
                    }
                    VStack {
                        monitor("Percent Wet", key: "PercentWet")
                        monitor("Global Timestep", key: "LastGlobalTimestep")
                    }
                }
            }

            Section("Retries and Limits") {
                ForEach([
                    ("Retries", "Retries"), ("Elevation Retries", "RetryElevationCount"),
                    ("NaN Retries", "RetryNaNCount"), ("Negative Volume Retries", "RetryNegVolumeCount"),
                    ("Advection Limits", "AdvectionLimitCount"), ("User Limits", "UserLimitCount"),
                    ("Celerity Limits", "CelerityLimitCount"), ("Increase Limits", "IncreaseLimitCount")
                ], id: \.1) { label, key in
                    LabeledContent(LocalizedStringKey(label), value: value(key)).monospacedDigit()
                }
            }
        }
    }

    private var cancellableJob: Job? {
        guard store.jobProvider != nil, let id = session.fields["Job_ID"] else { return nil }
        return store.jobs.first { $0.id == id && !$0.isComplete && !$0.isCancelling && $0.isCancellable }
    }

    private func monitor(_ title: String, key: String) -> some View {
        RealTimeMonitorView(title: title, field: key, units: key == "PercentWet" ? "%" : "s", session: session)
            .frame(minWidth: 230)
    }
}

struct ComputeSummaryControl: View {
    @ObservedObject var session: ModelEditorSession
    private func value(_ key: String) -> String { session.fields["ComputeSummary_" + key] ?? "—" }

    var body: some View {
        Section("Compute Summary") {
            ForEach([
                ("Start Time", "StartTime"), ("End Time", "EndTime"), ("Total Duration", "TotalDuration"),
                ("Solver Initialization Duration", "SolverInitDuration"), ("Output Duration", "OutputDuration"),
                ("Failure Reason", "FailureReason"), ("Solver", "Solver"),
                ("Software Version", "SoftwareVersion")
            ], id: \.1) { label, key in
                LabeledContent(LocalizedStringKey(label), value: value(key)).textSelection(.enabled)
            }
        }
    }
}
