import Foundation
import OSLog
import RASWorkspaceCore
import SwiftUI

extension PlanComputeDuplexEvent: BackendOperationProgressProviding {
    var backendOperationProgress: BackendOperationProgress {
        BackendOperationProgress(fraction: fraction, message: message, taskName: taskName)
    }
}

struct WorkspaceDeveloperLogEntry: Identifiable, Hashable, Sendable {
    let id: UUID
    let time: Date
    let operation: String
    let text: String
    let severity: WorkspaceMessageSeverity
}

/// The retained DevLogs stream is separate from expiring workspace messages
/// and the persistent application log file.
@MainActor
final class WorkspaceDeveloperLogCenter: ObservableObject {
    static let shared = WorkspaceDeveloperLogCenter()

    @Published private(set) var entries: [WorkspaceDeveloperLogEntry] = []
    private let capacity: Int

    init(capacity: Int = 2_000) { self.capacity = max(1, capacity) }

    func log(_ text: String, severity: WorkspaceMessageSeverity = .information,
             operation: String = "Developer Tools", at time: Date = Date()) {
        guard !text.isEmpty else { return }
        entries.append(WorkspaceDeveloperLogEntry(id: UUID(), time: time,
            operation: operation, text: text, severity: severity))
        if entries.count > capacity { entries.removeFirst(entries.count - capacity) }

        let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "HECRAS2025",
                            category: operation)
        switch severity {
        case .trace, .debug: logger.debug("\(text, privacy: .private)")
        case .information: logger.info("\(text, privacy: .private)")
        case .warning: logger.warning("\(text, privacy: .private)")
        case .error: logger.error("\(text, privacy: .private)")
        }
    }

    func clear() { entries.removeAll(keepingCapacity: true) }
}

/// Job state is projected from actual backend stream events and explicit
/// source-operation progress. No placeholder jobs are created.
@MainActor
final class WorkspaceJobRegistry: ObservableObject, JobProvider {
    static let shared = WorkspaceJobRegistry(observeBackend: true)

    @Published private(set) var jobs: [Job] = []
    var onJobsChanged: (@MainActor ([Job]) -> Void)?

    private var cancellations: [String: @Sendable () -> Bool] = [:]
    private var startedAt: [String: Date] = [:]
    private var backendObserverID: UUID?
    private var backendEventContinuation: AsyncStream<BackendOperationEvent>.Continuation?
    private var backendEventTask: Task<Void, Never>?

    init(observeBackend: Bool = false) {
        if observeBackend { startObservingBackendEvents() }
    }

    /// There is exactly one bridge from Core events into the shared registry,
    /// even when multiple workspace stores attach to the same process client.
    func startObservingBackendEvents() {
        guard backendObserverID == nil else { return }
        let channel = AsyncStream<BackendOperationEvent>.makeStream()
        let stream = channel.stream
        let continuation = channel.continuation
        backendEventContinuation = continuation
        backendEventTask = Task { @MainActor [weak self] in
            for await event in stream {
                guard let self else { return }
                self.receive(event)
            }
        }
        let eventSink = channel.continuation
        backendObserverID = BackendOperationEventCenter.shared.addObserver { event in
            // Yield synchronously at the Core callback boundary. A Task per
            // event can reorder a terminal before its started/progress frames.
            eventSink.yield(event)
        }
    }

    func receive(_ event: BackendOperationEvent) {
        guard event.isJob else {
            logBackendDiagnostic(event)
            return
        }
        switch event.phase {
        case .started:
            guard jobs.first(where: { $0.id == event.invocationID }) == nil else { return }
            let name = event.taskName.flatMap { $0.isEmpty ? nil : L10n.text($0) }
                ?? L10n.text("Backend operation")
            if let cancel = event.requestSourceCancellation,
               event.cancellationCapability == .sourceControl {
                cancellations[event.invocationID] = cancel
            }
            startedAt[event.invocationID] = Date()
            set(Job(id: event.invocationID, name: name, progress: .nan,
                message: event.message ?? "", isComplete: false, taskSucceeded: false,
                isCancelling: false, timeTaken: nil,
                isCancellable: cancellations[event.invocationID] != nil,
                showStatusMessage: true, canDelete: true))

        case .progress:
            guard let current = job(event.invocationID), !current.isComplete else { return }
            let value = event.progress.flatMap { $0.isFinite ? min(max($0, 0), 1) * 100 : nil }
                ?? current.progress
            set(copy(current, name: event.taskName.map(L10n.text) ?? current.name,
                progress: value, message: event.message.map(L10n.text) ?? current.message))

        case .completed, .failed, .cancelled:
            guard let current = job(event.invocationID) else { return }
            let phase = event.phase
            let succeeded = phase == .completed && event.sourceSucceeded != false
            let cancelled = phase == .cancelled || event.sourceCancelled == true
            let terminalMessage = (event.message ?? event.errorMessage).map(L10n.text) ?? current.message
            let duration = startedAt.removeValue(forKey: event.invocationID)
                .map { max(0, Date().timeIntervalSince($0)) }
            cancellations.removeValue(forKey: event.invocationID)
            logBackendDiagnostic(event)
            set(copy(current, progress: succeeded ? 100 : current.progress,
                message: terminalMessage, isComplete: true, taskSucceeded: succeeded,
                isCancelling: false, isCancelled: cancelled, timeTaken: duration, isCancellable: false,
                canDelete: true))
        }
    }

    /// Used for actual network transfers and other source operations that do
    /// not run through BackendProcessClient.
    @discardableResult
    func beginSourceJob(name: String, cancel: (@Sendable () -> Bool)? = nil,
                        at date: Date = Date()) -> String {
        let id = UUID().uuidString
        if let cancel { cancellations[id] = cancel }
        startedAt[id] = date
        set(Job(id: id, name: name, progress: .nan, message: "",
            isComplete: false, taskSucceeded: false, isCancelling: false,
            timeTaken: nil, isCancellable: cancel != nil,
            showStatusMessage: true, canDelete: true))
        return id
    }

    func updateSourceJob(_ id: String, fraction: Double?, message: String? = nil) {
        guard let current = job(id), !current.isComplete else { return }
        let value = fraction.flatMap { $0.isFinite ? min(max($0, 0), 1) * 100 : nil }
            ?? current.progress
        set(copy(current, progress: value, message: message ?? current.message))
    }

    func finishSourceJob(_ id: String, succeeded: Bool, cancelled: Bool = false,
                         message: String? = nil) {
        guard let current = job(id), !current.isComplete else { return }
        let duration = startedAt.removeValue(forKey: id).map { max(0, Date().timeIntervalSince($0)) }
        cancellations.removeValue(forKey: id)
        set(copy(current, progress: succeeded ? 100 : current.progress,
            message: message ?? current.message, isComplete: true,
            taskSucceeded: succeeded, isCancelling: false, isCancelled: cancelled,
            timeTaken: duration,
            isCancellable: false, canDelete: true))
    }

    func cancel(_ id: String) async throws {
        guard let current = job(id), !current.isComplete,
              let cancellation = cancellations[id] else { return }
        guard cancellation() else {
            throw BackendServiceError(code: "cancelUnavailable",
                message: "The source operation could not accept a cancellation request.")
        }
        set(copy(current, isCancelling: true))
    }

    func remove(_ id: String) async throws {
        if let current = job(id), !current.isComplete, let cancellation = cancellations[id] {
            _ = cancellation()
        }
        cancellations.removeValue(forKey: id)
        startedAt.removeValue(forKey: id)
        jobs.removeAll { $0.id == id }
        onJobsChanged?(jobs)
    }

    private func job(_ id: String) -> Job? { jobs.first(where: { $0.id == id }) }

    private func logBackendDiagnostic(_ event: BackendOperationEvent) {
        switch event.phase {
        case .failed:
            let text = event.errorMessage ?? event.message
            if let text { WorkspaceDeveloperLogCenter.shared.log(L10n.text(text),
                severity: .error, operation: L10n.text(event.taskName ?? "Backend operation")) }
        case .cancelled:
            if let message = event.message {
                WorkspaceDeveloperLogCenter.shared.log(L10n.text(message),
                    severity: .information, operation: L10n.text(event.taskName ?? "Backend operation"))
            }
        case .started, .progress, .completed: break
        }
    }

    private func set(_ job: Job) {
        if let index = jobs.firstIndex(where: { $0.id == job.id }) { jobs[index] = job }
        else { jobs.append(job) }
        onJobsChanged?(jobs)
    }

    private func copy(_ job: Job, name: String? = nil, progress: Double? = nil,
                      message: String? = nil, isComplete: Bool? = nil,
                      taskSucceeded: Bool? = nil, isCancelling: Bool? = nil,
                      isCancelled: Bool? = nil, timeTaken: TimeInterval?? = nil, isCancellable: Bool? = nil,
                      canDelete: Bool? = nil) -> Job {
        Job(id: job.id, name: name ?? job.name, progress: progress ?? job.progress,
            message: message ?? job.message, isComplete: isComplete ?? job.isComplete,
            taskSucceeded: taskSucceeded ?? job.taskSucceeded,
            isCancelling: isCancelling ?? job.isCancelling,
            timeTaken: timeTaken ?? job.timeTaken,
            isCancelled: isCancelled ?? job.isCancelled,
            isCancellable: isCancellable ?? job.isCancellable,
            showStatusMessage: job.showStatusMessage, canDelete: canDelete ?? job.canDelete)
    }
}

struct WorkspaceDeveloperLogPreviewList: View {
    let entries: [WorkspaceDeveloperLogEntry]
    private var recentEntries: [WorkspaceDeveloperLogEntry] { Array(entries.suffix(8).reversed()) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Messages", systemImage: "text.alignleft").font(.headline)
                Spacer()
                Text(L10n.format("%d messages", entries.count)).font(.caption).foregroundStyle(.secondary)
            }.padding(14)
            Divider()
            if recentEntries.isEmpty {
                ContentUnavailableView("No Messages", systemImage: "text.alignleft",
                    description: Text("Developer log messages will appear here when available."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(recentEntries) { entry in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: entry.severity == .error ? "exclamationmark.triangle.fill" : "text.alignleft")
                                    .foregroundStyle(entry.severity == .error ? Color.red : .secondary)
                                    .padding(.top, 2)
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(entry.operation).font(.subheadline.weight(.semibold))
                                        Text(entry.severity.rawValue).font(.caption).foregroundStyle(.secondary)
                                        Spacer()
                                        Text(entry.time, style: .time).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                    }
                                    Text(entry.text).font(.caption).foregroundStyle(.secondary)
                                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                }
                            }.padding(12)
                            Divider()
                        }
                    }
                }
            }
        }.frame(width: 360, height: 340)
    }
}

/// These explicit actions feed the same five-severity logger used by the
/// Store's operation messages; they do not manufacture source operations.
struct WorkspaceDeveloperLogTestActions: View {
    private let logger: WorkspaceDeveloperLogCenter

    init(logger: WorkspaceDeveloperLogCenter = .shared) { self.logger = logger }

    var body: some View {
        Section("Developer Log Levels") {
            ForEach(WorkspaceMessageSeverity.allCases, id: \.self) { severity in
                Button(severity.rawValue) {
                    logger.log("Developer log test message.", severity: severity,
                        operation: "Developer Log Test")
                }
            }
        }
    }
}
