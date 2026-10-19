import Darwin
import Foundation
import SwiftUI
import RASWorkspaceCore

struct PlanComputeProgress: Sendable, Equatable {
    let fraction: Double?
    let message: String?
    let taskName: String?
}

struct PlanComputeJobMessageStream: Sendable, Equatable {
    private(set) var contextID: String? = nil
    private(set) var runID: String? = nil
    private(set) var messages: [PlanComputeJobMessage] = []
    private(set) var issue: String? = nil

    mutating func reset() {
        contextID = nil
        runID = nil
        messages = []
        issue = nil
    }

    mutating func begin(contextID: String) {
        reset()
        self.contextID = contextID
    }

    mutating func observe(runID nextRunID: String) {
        guard !nextRunID.isEmpty else { return }
        if let runID, runID != nextRunID {
            issue = "The live solver message sequence is incomplete."
            return
        }
        runID = nextRunID
    }

    mutating func append(_ update: PlanComputeJobMessageUpdate, envelopeRunID: String?) {
        guard issue == nil else { return }
        guard let envelopeRunID, !envelopeRunID.isEmpty else {
            issue = "The live solver message sequence is incomplete."
            return
        }
        observe(runID: envelopeRunID)
        guard issue == nil else { return }
        guard update.runId == envelopeRunID, runID == envelopeRunID else {
            issue = "The live solver message sequence is incomplete."
            return
        }
        for message in update.messages {
            guard message.index == messages.count else {
                issue = "The live solver message sequence is incomplete."
                return
            }
            messages.append(message)
        }
    }

    mutating func verifyTerminal(runID terminalRunID: String?) {
        guard let runID else { return }
        guard let terminalRunID, runID == terminalRunID else {
            issue = "The live solver message sequence is incomplete."
            return
        }
    }
}

/// A nonce-owned, mode-restricted marker directory used for cooperative
/// cancellation. The backend remains responsible for waiting on the source
/// solver and returning its terminal state before this directory is removed.
final class PlanComputeCancellationLease: @unchecked Sendable {
    let request: PlanComputeCancellation
    let ownerURL: URL
    let markerURL: URL
    private let lock = NSLock()
    private var cleaned = false

    private init(request: PlanComputeCancellation, ownerURL: URL, markerURL: URL) {
        self.request = request
        self.ownerURL = ownerURL
        self.markerURL = markerURL
    }

    static func create() throws -> PlanComputeCancellationLease {
        let temp = URL(fileURLWithPath: SourceFilePaths.canonical(FileManager.default.temporaryDirectory), isDirectory: true)
        let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let directory = temp.appendingPathComponent("hecras-plan-compute-" + nonce, isDirectory: true)
        guard mkdir(directory.path, mode_t(0o700)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        let owner = directory.appendingPathComponent("owner", isDirectory: false)
        let marker = directory.appendingPathComponent("cancel", isDirectory: false)
        do {
            try writeExclusive(nonce, to: owner, permissions: 0o600)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: owner.path)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            return PlanComputeCancellationLease(
                request: .init(directory: directory.path, nonce: nonce), ownerURL: owner, markerURL: marker)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    func requestCancellation() {
        lock.withLock {
            guard !cleaned, !FileManager.default.fileExists(atPath: markerURL.path) else { return }
            try? Self.writeExclusive(request.nonce, to: markerURL, permissions: 0o600)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: markerURL.path)
        }
    }

    func cleanup() {
        lock.withLock {
            guard !cleaned else { return }
            cleaned = true
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: request.directory, isDirectory: true))
        }
    }

    private static func writeExclusive(_ text: String, to url: URL, permissions: mode_t) throws {
        let descriptor = Darwin.open(url.path, O_CREAT | O_EXCL | O_WRONLY, permissions)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(descriptor) }
        let data = Data(text.utf8)
        let written = data.withUnsafeBytes { bytes in
            Darwin.write(descriptor, bytes.baseAddress, bytes.count)
        }
        guard written == data.count else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}

@MainActor
final class PlanComputeSession: ObservableObject {
    @Published private(set) var isInspecting = false
    @Published private(set) var isRunning = false
    @Published private(set) var isCancelling = false
    @Published private(set) var inspection: PlanComputeInspection?
    @Published private(set) var inspectionContextID: String?
    @Published private(set) var executionResult: PlanComputeExecutionResult?
    @Published private(set) var executionContextID: String?
    @Published private(set) var errorMessage: String?
    @Published private(set) var progress = PlanComputeProgress(fraction: nil, message: nil, taskName: nil)
    @Published private(set) var sourceValues: [String: String] = [:]
    @Published private(set) var liveMessageStream = PlanComputeJobMessageStream()

    private struct InspectionFlight {
        let contextID: String
        let token: UUID
        let task: Task<PlanComputeInspection, any Error>
        var waiterCount: Int
    }

    private let provider: (any PlanComputeProvider)?
    private var inspectionFlight: InspectionFlight?
    private var operationOwner: String?
    private var operationContextID: String?
    private var cancellationLease: PlanComputeCancellationLease?
    private var liveMapTargetContinuation: AsyncStream<PlanComputeLiveMapTargetUpdate>.Continuation?

    var currentOperationOwner: String? { operationOwner }
    var currentOperationContextID: String? { operationContextID }
    var onResultComputeUpdate: (@MainActor (BackendResultComputeUpdate, BackendProgressUpdate, String, String) -> Void)?
    var onLiveMapRasterFrame: (@MainActor (PlanComputeLiveMapFrame, String, String) -> Void)?
    var onLiveVelocityFieldFrame: (@MainActor (PlanComputeLiveVelocityFrame, String, String) -> Void)?
    var onLiveVelocityUnavailable: (@MainActor (PlanComputeLiveVelocityUnavailable, String, String) -> Void)?
    var onNavigateDiagnosticTarget: (@MainActor (PlanDiagnosticTarget, String) -> Bool)?

    var result: PlanComputeExecutionResult? { executionResult }
    var isAvailable: Bool { provider != nil }

    init(provider: (any PlanComputeProvider)?) { self.provider = provider }

    func inspect(context: PlanPrecomputeContext, force: Bool = false,
                  isCurrent: @escaping @MainActor (String) -> Bool) async -> PlanComputeInspection? {
        guard !isRunning else { return nil }
        guard let provider else {
            errorMessage = L10n.text("No active compute provider is available.")
            return nil
        }
        guard isCurrent(context.id) else { return nil }
        if !force, inspectionContextID == context.id, let inspection { return inspection }

        let flight: InspectionFlight
        if var current = inspectionFlight, current.contextID == context.id {
            current.waiterCount += 1
            inspectionFlight = current
            flight = current
        } else {
            errorMessage = nil
            isInspecting = true
            inspection = nil
            inspectionContextID = nil
            let task = Task { @MainActor in
                try await provider.inspectCompute(context.asset, edits: context.edits)
            }
            flight = InspectionFlight(contextID: context.id, token: UUID(), task: task, waiterCount: 1)
            inspectionFlight = flight
        }

        do {
            let result = try await flight.task.value
            guard isCurrent(context.id) else {
                if inspectionFlight?.token == flight.token {
                    clearIfStale(currentContextID: nil)
                }
                return nil
            }
            guard inspectionFlight?.token == flight.token else { return nil }
            guard result.revision == context.edits.sourceRevision else {
                isInspecting = false
                errorMessage = L10n.text("The model source changed during compute inspection. Reload the plan and try again.")
                finishInspectionWaiter(token: flight.token)
                return nil
            }
            if inspectionContextID != context.id || inspection?.inspectionId != result.inspectionId {
                inspection = result
                inspectionContextID = context.id
                errorMessage = nil
            }
            isInspecting = false
            finishInspectionWaiter(token: flight.token)
            return inspectionContextID == context.id ? inspection : nil
        } catch {
            guard isCurrent(context.id) else {
                if inspectionFlight?.token == flight.token {
                    clearIfStale(currentContextID: nil)
                }
                return nil
            }
            if inspectionFlight?.token == flight.token {
                isInspecting = false
                errorMessage = error.localizedDescription
                finishInspectionWaiter(token: flight.token)
            }
            return nil
        }
    }

    func run(context: PlanPrecomputeContext,
             isCurrent: @escaping @MainActor (String) -> Bool,
             begin: @escaping @MainActor (PlanComputeInspection) -> Bool,
             end: @escaping @MainActor () -> Void,
             completed: @escaping @MainActor (PlanComputeExecutionResult) -> Void) async -> PlanComputeExecutionResult? {
        guard !isRunning else { return nil }
        guard let inspection = await inspect(context: context, force: true, isCurrent: isCurrent),
              isCurrent(context.id) else { return nil }
        return await execute(context: context, inspection: inspection, isCurrent: isCurrent,
            begin: begin, end: end, completed: completed)
    }

    func execute(context: PlanPrecomputeContext, inspection: PlanComputeInspection,
                  isCurrent: @escaping @MainActor (String) -> Bool,
                  begin: @escaping @MainActor (PlanComputeInspection) -> Bool,
                  end: @escaping @MainActor () -> Void,
                  completed: @escaping @MainActor (PlanComputeExecutionResult) -> Void) async -> PlanComputeExecutionResult? {
        guard !isRunning, let provider,
              inspectionContextID == context.id,
              self.inspection?.inspectionId == inspection.inspectionId,
              isCurrent(context.id) else {
            errorMessage = L10n.text("The compute inspection is no longer current.")
            return nil
        }
        guard inspection.canExecute else {
            errorMessage = inspection.reasons.isEmpty
                ? L10n.text("The current plan cannot be computed.")
                : inspection.reasons.joined(separator: "\n")
            return nil
        }

        let lease: PlanComputeCancellationLease
        do { lease = try PlanComputeCancellationLease.create() }
        catch {
            errorMessage = error.localizedDescription
            return nil
        }
        let owner = UUID().uuidString
        operationOwner = owner
        operationContextID = context.id
        guard begin(inspection) else {
            if operationOwner == owner {
                operationOwner = nil
                operationContextID = nil
            }
            lease.cleanup()
            errorMessage = L10n.text("The compute operation could not acquire the workspace lease.")
            return nil
        }

        cancellationLease = lease
        isRunning = true
        isCancelling = false
        errorMessage = nil
        executionResult = nil
        executionContextID = nil
        sourceValues = [:]
        liveMessageStream.begin(contextID: context.id)
        progress = PlanComputeProgress(fraction: nil, message: nil, taskName: nil)
        defer {
            liveMapTargetContinuation?.finish()
            liveMapTargetContinuation = nil
            lease.cleanup()
            end()
            if operationOwner == owner {
                operationOwner = nil
                operationContextID = nil
                cancellationLease = nil
                isRunning = false
                isCancelling = false
                self.inspection = nil
                inspectionContextID = nil
            }
            if liveMessageStream.contextID == context.id && !isCurrent(context.id) {
                liveMessageStream.reset()
            }
        }

        let targetStream = AsyncStream<PlanComputeLiveMapTargetUpdate>.makeStream(
            bufferingPolicy: .bufferingNewest(1))
        liveMapTargetContinuation = targetStream.continuation
        targetStream.continuation.yield(.replace([]))
        let operation = Task { @MainActor [self] in
            try await provider.executeComputeDuplex(context.asset, edits: context.edits,
                inspectionID: inspection.inspectionId, cancellation: lease.request,
                targetUpdates: targetStream.stream,
                update: { [weak self] update in
                    guard let self else { return }
                    self.accept(update, owner: owner, contextID: context.id)
                })
        }

        do {
            let response = try await withTaskCancellationHandler {
                try await operation.value
            } onCancel: {
                // The backend request task is deliberately unstructured and is
                // not cancelled here. The source BatchJob must acknowledge the
                // nonce marker before this method releases the workspace lease.
                lease.requestCancellation()
                Task { @MainActor [weak self] in
                    guard self?.operationOwner == owner else { return }
                    self?.isCancelling = true
                }
            }
            guard operationOwner == owner else { return response }
            guard response.inspectionId == inspection.inspectionId,
                  response.revision == inspection.revision else {
                errorMessage = L10n.text("The compute response does not match the inspected plan revision.")
                return nil
            }
            guard ["completed", "failed", "cancelled"].contains(response.state) else {
                errorMessage = L10n.text("The source solver returned an unknown terminal state.")
                return nil
            }
            liveMessageStream.verifyTerminal(runID: response.resultCompute?.runId)
            sourceValues.merge(response.sourceValues ?? [:]) { _, latest in latest }
            executionResult = response
            executionContextID = context.id
            progress = PlanComputeProgress(fraction: response.state == "completed" ? 1 : progress.fraction,
                message: response.errorMessage, taskName: L10n.text("Plan Compute"))
            if response.state == "failed" { errorMessage = response.errorMessage ?? L10n.text("Plan compute failed.") }
            if response.state == "cancelled" { errorMessage = response.errorMessage ?? L10n.text("Plan compute was cancelled.") }
            if isCurrent(context.id) { completed(response) }
            return response
        } catch {
            guard operationOwner == owner else { return nil }
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func cancel() {
        guard isRunning, !isCancelling else { return }
        isCancelling = true
        cancellationLease?.requestCancellation()
        liveMapTargetContinuation?.yield(.cancel)
    }

    /// Replaces all map render targets owned by this running compute. An empty
    /// target set explicitly retires every live viewport subscription.
    func updateLiveMapRenderTargets(_ targets: [PlanComputeLiveMapTarget]) {
        guard isRunning else { return }
        liveMapTargetContinuation?.yield(.replace(targets))
    }

    func clearIfStale(currentContextID: String?) {
        if inspectionContextID != currentContextID {
            inspection = nil
            inspectionContextID = nil
        }
        if !isRunning && liveMessageStream.contextID != currentContextID {
            liveMessageStream.reset()
        }
        if !isRunning && inspectionFlight?.contextID != currentContextID {
            inspectionFlight = nil
            isInspecting = false
        }
        if !isRunning && inspectionContextID == nil {
            errorMessage = nil
        }
    }

    func invalidate() {
        guard !isRunning else { return }
        inspectionFlight = nil
        isInspecting = false
        inspection = nil
        inspectionContextID = nil
        executionResult = nil
        executionContextID = nil
        sourceValues = [:]
        liveMessageStream.reset()
        errorMessage = nil
        progress = PlanComputeProgress(fraction: nil, message: nil, taskName: nil)
    }

    private func accept(_ update: BackendProgressUpdate, owner: String, contextID: String) {
        guard operationOwner == owner, operationContextID == contextID else { return }
        if let resultCompute = update.resultCompute {
            onResultComputeUpdate?(resultCompute, update, owner, contextID)
        }
        var currentMessageStream = liveMessageStream
        if let runID = update.resultCompute?.runId { currentMessageStream.observe(runID: runID) }
        if let messages = update.planMessages {
            currentMessageStream.append(messages, envelopeRunID: update.resultCompute?.runId)
        }
        liveMessageStream = currentMessageStream
        if let fraction = update.fraction, fraction.isFinite { progress = PlanComputeProgress(
            fraction: min(max(fraction, 0), 1), message: update.message, taskName: update.taskName) }
        else if update.message != nil || update.taskName != nil {
            progress = PlanComputeProgress(fraction: progress.fraction, message: update.message, taskName: update.taskName)
        }
        if let values = update.values { sourceValues.merge(values) { _, latest in latest } }
    }

    private func accept(_ update: PlanComputeDuplexUpdate, owner: String, contextID: String) {
        accept(update.progress, owner: owner, contextID: contextID)
        guard operationOwner == owner, operationContextID == contextID else { return }
        if let frame = update.liveMapFrame { onLiveMapRasterFrame?(frame, owner, contextID) }
        if let frame = update.liveVelocityFrame { onLiveVelocityFieldFrame?(frame, owner, contextID) }
        if let unavailable = update.liveVelocityUnavailable { onLiveVelocityUnavailable?(unavailable, owner, contextID) }
    }

    private func finishInspectionWaiter(token: UUID) {
        guard var flight = inspectionFlight, flight.token == token else { return }
        flight.waiterCount -= 1
        if flight.waiterCount <= 0 {
            inspectionFlight = nil
            isInspecting = false
        } else {
            inspectionFlight = flight
        }
    }
}
