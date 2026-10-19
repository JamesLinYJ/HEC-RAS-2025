import SwiftUI

// Presentation contract matches Visual.Observables.BatchJob / JobHub.
struct Job: Identifiable, Sendable {
    let id: String
    let name: String
    let progress: Double
    let message: String
    let isComplete: Bool
    let taskSucceeded: Bool
    let isCancelling: Bool
    let timeTaken: TimeInterval?
    var isCancelled = false
    var isCancellable = true
    var showStatusMessage = true
    var canDelete = false
    var state: JobState {
        if !isComplete { return isCancelling ? .cancelling : .running }
        if taskSucceeded { return .succeeded }
        return isCancelled ? .cancelled : .failed
    }
    var fraction: Double? { progress.isFinite ? min(max(progress, 0), 100) / 100 : nil }
    var validDuration: TimeInterval? { timeTaken.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil } }
}
enum JobState: String {
    case running = "Running", cancelling = "Cancelling…", succeeded = "Succeeded", failed = "Failed", cancelled = "Cancelled"
    var symbol: String {
        switch self {
        case .running: "arrow.trianglehead.2.clockwise"
        case .cancelling: "hourglass"
        case .succeeded: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .cancelled: "xmark.circle"
        }
    }
}
@MainActor
protocol JobProvider {
    func cancel(_ id: String) async throws
    func remove(_ id: String) async throws
}

// The same source state renders in the task hub and import preview lists.
struct JobProgressRow: View {
    let job: Job
    var pending = false
    var cancel: (() -> Void)?
    var remove: (() -> Void)?
    private var statusColor: Color { job.state == .failed ? .red : job.state == .succeeded ? .green : .secondary }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(job.name).font(.headline).textSelection(.enabled)
                Spacer()
                Label(LocalizedStringKey(job.state.rawValue), systemImage: job.state.symbol).font(.caption).foregroundStyle(statusColor)
            }
            if !job.isComplete { ProgressView(value: job.fraction).accessibilityLabel(job.name) }
            if job.showStatusMessage && !job.message.isEmpty { Text(job.message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            HStack {
                if let duration = job.validDuration { Text(Duration.seconds(duration).formatted(.time(pattern: .hourMinuteSecond))).font(.caption.monospacedDigit()) }
                Spacer()
                if let fraction = job.fraction, !job.isComplete { Text(fraction, format: .percent.precision(.fractionLength(0))).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                if let cancel, job.isCancellable, !job.isComplete { Button("Cancel", action: cancel).disabled(job.isCancelling || pending) }
                if let remove, job.canDelete { Button("Remove", action: remove).disabled(pending) }
            }
        }.padding(.vertical, 6)
    }
}

// ImportingPreviewList collapses completely when the source collection is empty.
struct ImportingPreviewList: View {
    let jobs: [Job]
    var body: some View {
        if !jobs.isEmpty {
            VStack(alignment: .leading, spacing: 10) { ForEach(jobs) { JobProgressRow(job: $0) } }.padding(.vertical, 6)
        }
    }
}

struct JobsPopover: View {
    @ObservedObject var store: WorkspaceStore
    var body: some View {
        JobListContent(store: store, showsTitle: true)
            .frame(width: 520, height: 500)
    }
}

struct JobListContent: View {
    @ObservedObject var store: WorkspaceStore
    var showsTitle = false
    @State private var filter = JobListFilter.all

    private var running: [Job] { store.jobs.filter { !$0.isComplete } }
    private var filteredJobs: [Job] {
        switch filter {
        case .all: store.jobs
        case .running: running
        case .completed: store.jobs.filter(\.isComplete)
        case .failed: store.jobs.filter { $0.state == .failed }
        }
    }
    private var averageProgress: Double? {
        let values = running.compactMap(\.fraction)
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    var body: some View {
        VStack(spacing: 0) {
            if showsTitle {
                HStack {
                    Label("Jobs", systemImage: "arrow.trianglehead.2.clockwise")
                        .font(.headline)
                    Spacer()
                    Text(L10n.format("%d jobs", store.jobs.count))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(16)
            }
            if !running.isEmpty {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(L10n.format("%d running", running.count)).font(.headline)
                        Text("Average progress").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let averageProgress {
                        ProgressView(value: averageProgress).frame(width: 150)
                        Text(averageProgress, format: .percent.precision(.fractionLength(0)))
                            .font(.caption.monospacedDigit())
                            .frame(width: 42, alignment: .trailing)
                    } else {
                        ProgressView().controlSize(.small).frame(width: 150, alignment: .leading)
                        Text("—").font(.caption.monospacedDigit()).frame(width: 42, alignment: .trailing)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Color.accentColor.opacity(0.06))
            }
            if store.jobProvider == nil {
                WorkspaceDialogNotice(message: "Cancel and remove are unavailable because no job service is configured.")
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
            }
            Picker("Show Jobs", selection: $filter) {
                ForEach(JobListFilter.allCases) { value in Text(LocalizedStringKey(value.rawValue)).tag(value) }
            }
            .pickerStyle(.segmented)
            .padding(12)
            Divider()
            if filteredJobs.isEmpty {
                ContentUnavailableView(filter.emptyTitle, systemImage: filter.emptySymbol,
                    description: Text(filter == .all ? "Jobs will appear here when a task starts." : "There are no jobs in this category."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(filteredJobs) { job in
                    JobProgressRow(job: job, pending: store.pendingJobActions.contains(job.id),
                        cancel: store.jobProvider == nil ? nil : { _ = Task<Void, Never> { await store.cancelJob(job.id) } },
                        remove: store.jobProvider == nil ? nil : { _ = Task<Void, Never> { await store.removeJob(job.id) } })
                }
                .listStyle(.plain)
            }
        }
    }
}

private enum JobListFilter: String, CaseIterable, Identifiable {
    case all = "All", running = "Running", completed = "Completed", failed = "Failed"
    var id: String { rawValue }
    var emptyTitle: String {
        switch self { case .all, .running: "No Active Jobs"; case .completed: "No Completed Jobs"; case .failed: "No Failed Jobs" }
    }
    var emptySymbol: String { self == .failed ? "checkmark.circle" : "arrow.trianglehead.2.clockwise" }
}
