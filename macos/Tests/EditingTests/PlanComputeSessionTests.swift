import Foundation
import Testing
import RASWorkspaceCore
@testable import HECRAS2025

@MainActor
private final class ControlledPlanComputeProvider: PlanComputeProvider {
    private(set) var inspectionRequests: [(ProjectAsset, EditorEdits)] = []
    private(set) var executeRequests: [(ProjectAsset, EditorEdits, String, PlanComputeCancellation)] = []
    private var inspectionContinuations: [Int: CheckedContinuation<PlanComputeInspection, any Error>] = [:]
    private var executionContinuations: [Int: CheckedContinuation<PlanComputeExecutionResult, any Error>] = [:]
    private var progressHandlers: [Int: @Sendable (BackendProgressUpdate) -> Void] = [:]

    func inspectCompute(_ asset: ProjectAsset, edits: EditorEdits) async throws -> PlanComputeInspection {
        let index = inspectionRequests.count + 1
        inspectionRequests.append((asset, edits))
        return try await withCheckedThrowingContinuation { inspectionContinuations[index] = $0 }
    }

    func executeCompute(_ asset: ProjectAsset, edits: EditorEdits, inspectionID: String,
                        cancellation: PlanComputeCancellation,
                        progress: @escaping @Sendable (BackendProgressUpdate) -> Void) async throws -> PlanComputeExecutionResult {
        let index = executeRequests.count + 1
        executeRequests.append((asset, edits, inspectionID, cancellation))
        progressHandlers[index] = progress
        return try await withCheckedThrowingContinuation { executionContinuations[index] = $0 }
    }

    func finishInspection(_ index: Int, _ result: PlanComputeInspection) {
        inspectionContinuations.removeValue(forKey: index)?.resume(returning: result)
    }

    func finishExecution(_ index: Int, _ result: PlanComputeExecutionResult) {
        executionContinuations.removeValue(forKey: index)?.resume(returning: result)
    }

    func emitProgress(_ index: Int, _ update: BackendProgressUpdate) { progressHandlers[index]?(update) }
}

struct PlanComputeSessionTests {
    @Test @MainActor
    func identicalInspectionRequestsCoalesceAndStaleRepliesAreNotPublished() async throws {
        let provider = ControlledPlanComputeProvider()
        let session = PlanComputeSession(provider: provider)
        let context = computeContext(id: "same-context")
        var current = true
        let isCurrent: @MainActor (String) -> Bool = { $0 == context.id && current }

        let first = Task { await session.inspect(context: context, isCurrent: isCurrent) }
        #expect(try await waitForCompute { provider.inspectionRequests.count == 1 })
        let second = Task { await session.inspect(context: context, isCurrent: isCurrent) }
        await Task.yield()
        #expect(provider.inspectionRequests.count == 1)

        current = false
        provider.finishInspection(1, computeInspection(revision: "compute-revision"))
        #expect(await first.value == nil)
        #expect(await second.value == nil)
        #expect(session.inspection == nil && !session.isInspecting)
    }

    @Test @MainActor
    func coalescedInspectionWaitersBothReceiveThePublishedInspection() async throws {
        let provider = ControlledPlanComputeProvider()
        let session = PlanComputeSession(provider: provider)
        let context = computeContext(id: "coalesced-context")
        let isCurrent: @MainActor (String) -> Bool = { $0 == context.id }

        let first = Task { await session.inspect(context: context, isCurrent: isCurrent) }
        #expect(try await waitForCompute { provider.inspectionRequests.count == 1 })
        let second = Task { await session.inspect(context: context, isCurrent: isCurrent) }
        await Task.yield()
        #expect(provider.inspectionRequests.count == 1)

        provider.finishInspection(1, computeInspection(revision: "compute-revision"))
        let firstResult = await first.value
        let secondResult = await second.value
        #expect(firstResult?.inspectionId == "inspection-id")
        #expect(secondResult?.inspectionId == firstResult?.inspectionId)
        #expect(session.inspection?.inspectionId == firstResult?.inspectionId)
        #expect(!session.isInspecting)
    }

    @Test @MainActor
    func parentCancellationWritesPrivateMarkerAndWaitsForSourceTerminalBeforeReleasingLease() async throws {
        let provider = ControlledPlanComputeProvider()
        let session = PlanComputeSession(provider: provider)
        let context = computeContext(id: "cancel-context")
        var endCount = 0
        var completedStates: [String] = []
        let isCurrent: @MainActor (String) -> Bool = { $0 == context.id }
        let begin: @MainActor (PlanComputeInspection) -> Bool = { $0.canExecute }
        let end: @MainActor () -> Void = { endCount += 1 }
        let completed: @MainActor (PlanComputeExecutionResult) -> Void = { completedStates.append($0.state) }

        let request = Task {
            await session.run(context: context, isCurrent: isCurrent, begin: begin, end: end, completed: completed)
        }
        #expect(try await waitForCompute { provider.inspectionRequests.count == 1 })
        provider.finishInspection(1, computeInspection(revision: "compute-revision"))
        #expect(try await waitForCompute { provider.executeRequests.count == 1 && session.isRunning })

        let cancellation = try #require(provider.executeRequests.first?.3)
        let directory = URL(fileURLWithPath: cancellation.directory, isDirectory: true)
        let owner = try #require(String(data: Data(contentsOf: directory.appendingPathComponent("owner")), encoding: .utf8))
        #expect(owner == cancellation.nonce)
        #expect(permissions(directory) == 0o700)
        #expect(permissions(directory.appendingPathComponent("owner")) == 0o600)

        request.cancel()
        #expect(try await waitForCompute { FileManager.default.fileExists(atPath: directory.appendingPathComponent("cancel").path) })
        let marker = directory.appendingPathComponent("cancel")
        #expect(String(data: try Data(contentsOf: marker), encoding: .utf8) == cancellation.nonce)
        #expect(permissions(marker) == 0o600)
        #expect(endCount == 0 && session.isRunning)

        let progress = BackendProgressUpdate(fraction: 0.25, message: "Solving", taskName: "CPU solver",
            values: ["Steps": "4", "LastIterations": "2"])
        provider.emitProgress(1, progress)
        #expect(try await waitForCompute { session.sourceValues["Steps"] == "4" })
        #expect(session.sourceValues["LastIterations"] == "2")

        provider.finishExecution(1, computeExecution(state: "cancelled", sourceValues: ["Steps": "5"]))
        _ = await request.value
        #expect(endCount == 1 && completedStates == ["cancelled"])
        #expect(!session.isRunning && !session.isCancelling)
        #expect(session.executionResult?.state == "cancelled")
        #expect(session.sourceValues["Steps"] == "5")
        #expect(!FileManager.default.fileExists(atPath: directory.path))

        // Changing ordinary draft identity hides only the inspection. The
        // retained source summary remains available until the parent changes
        // asset/project and explicitly invalidates the sub-session.
        session.clearIfStale(currentContextID: "new-plan-settings")
        #expect(session.inspection == nil)
        #expect(session.executionResult?.state == "cancelled")
        #expect(session.sourceValues["Steps"] == "5")
        session.invalidate()
        #expect(session.executionResult == nil && session.sourceValues.isEmpty)
    }

    @Test @MainActor
    func rejectedWorkspaceLeaseDoesNotStartSourceRequest() async throws {
        let provider = ControlledPlanComputeProvider()
        let session = PlanComputeSession(provider: provider)
        let context = computeContext(id: "lease-context")
        let task = Task {
            await session.run(context: context, isCurrent: { $0 == context.id },
                begin: { _ in false }, end: {}, completed: { _ in })
        }
        #expect(try await waitForCompute { provider.inspectionRequests.count == 1 })
        provider.finishInspection(1, computeInspection(revision: "compute-revision"))
        #expect(await task.value == nil)
        #expect(provider.executeRequests.isEmpty && !session.isRunning)
    }

    @Test @MainActor
    func terminalExecutionRequiresFreshInspectionAndRetainsPreviousResultAcrossDraftChanges() async throws {
        let provider = ControlledPlanComputeProvider()
        let session = PlanComputeSession(provider: provider)
        let context = computeContext(id: "repeat-compute-context")
        let isCurrent: @MainActor (String) -> Bool = { $0 == context.id }

        let firstRun = Task {
            await session.run(context: context, isCurrent: isCurrent,
                begin: { $0.canExecute }, end: {}, completed: { _ in })
        }
        #expect(try await waitForCompute { provider.inspectionRequests.count == 1 })
        provider.finishInspection(1, computeInspection(revision: "compute-revision"))
        #expect(try await waitForCompute { provider.executeRequests.count == 1 })
        provider.finishExecution(1, computeExecution(state: "completed", sourceValues: ["Steps": "20"]))
        #expect(await firstRun.value?.state == "completed")
        #expect(session.inspection == nil && session.executionResult?.state == "completed")

        let nextInspection = Task { await session.inspect(context: context, isCurrent: isCurrent) }
        #expect(try await waitForCompute { provider.inspectionRequests.count == 2 })
        #expect(session.executionResult?.state == "completed")
        provider.finishInspection(2, computeInspection(revision: "compute-revision"))
        #expect(await nextInspection.value?.inspectionId == "inspection-id")

        session.clearIfStale(currentContextID: "different-plan-settings")
        #expect(session.inspection == nil)
        #expect(session.executionResult?.state == "completed" && session.sourceValues["Steps"] == "20")
        session.invalidate()
        #expect(session.executionResult == nil && session.sourceValues.isEmpty)
    }

    @Test @MainActor
    func unknownBackendTerminalStateIsNotPublishedAsAnExecutionResult() async throws {
        let provider = ControlledPlanComputeProvider()
        let session = PlanComputeSession(provider: provider)
        let context = computeContext(id: "unknown-terminal-context")
        let task = Task {
            await session.run(context: context, isCurrent: { $0 == context.id },
                begin: { $0.canExecute }, end: {}, completed: { _ in })
        }
        #expect(try await waitForCompute { provider.inspectionRequests.count == 1 })
        provider.finishInspection(1, computeInspection(revision: "compute-revision"))
        #expect(try await waitForCompute { provider.executeRequests.count == 1 })
        provider.finishExecution(1, computeExecution(state: "unknown", sourceValues: [:]))

        #expect(await task.value == nil)
        #expect(session.executionResult == nil && !session.isRunning)
        #expect(session.errorMessage == L10n.text("The source solver returned an unknown terminal state."))
    }

    @Test
    func actualBackendSummaryUsesIsoStringsWithoutGlobalDateDecoderAssumptions() throws {
        let data = Data(#"{"success":true,"failureReason":null,"solver":"CPU_Explicit","softwareVersion":"source","startTime":"2026-10-16T01:02:03+00:00","endTime":"2026-10-16T01:02:05+00:00","totalDurationSeconds":2,"solverInitDurationSeconds":0.25,"outputDurationSeconds":0.5,"globalRetryCount":0,"computeLog":"complete"}"#.utf8)
        let summary = try JSONDecoder().decode(PlanComputeSummary.self, from: data)
        #expect(summary.startTime == "2026-10-16T01:02:03+00:00")
        #expect(summary.endTime == "2026-10-16T01:02:05+00:00")
    }
}

@MainActor
private func computeContext(id: String) -> PlanPrecomputeContext {
    let asset = ProjectAsset(url: URL(fileURLWithPath: "/fixture/Plans/Plan A.h5"), section: .plans)
    let edits = EditorEdits(fields: ["Plan/Description": "draft"], rows: [:], images: [:], sourceRevision: "compute-revision")
    return PlanPrecomputeContext(id: id, asset: asset, edits: edits)
}

private func computeInspection(revision: String) -> PlanComputeInspection {
    .init(inspectionId: "inspection-id", revision: revision, projectRevision: "project-revision",
        projectXmlFingerprint: "project-draft-fingerprint", canExecute: true, requiresCUDA: false,
        reasons: [], messages: [], sourceDependencies: [
            .init(role: "Plan", path: "/fixture/Plans/Plan A.h5", revision: "sha256:plan", willWrite: false)
        ], sideEffects: ["Geometry and Boundary Conditions are saved by the source solver."])
}

private func computeExecution(state: String, sourceValues: [String: String]) -> PlanComputeExecutionResult {
    .init(inspectionId: "inspection-id", revision: "compute-revision", state: state,
        resultPath: "/fixture/Results/Plan A.h5", resultRevision: "result-sha",
        summary: .init(success: false, failureReason: "User Cancelled", solver: "CPU_Explicit",
            softwareVersion: "source", startTime: "2026-10-16T01:02:03+00:00", endTime: "2026-10-16T01:02:05+00:00",
            totalDurationSeconds: 2, solverInitDurationSeconds: 0.25, outputDurationSeconds: 0.5,
            globalRetryCount: 0, computeLog: "source cancellation log"),
        messages: [], errorMessage: nil, finalDependencies: [], sourceValues: sourceValues)
}

private func permissions(_ url: URL) -> Int? {
    (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue
}

@MainActor
private func waitForCompute(_ condition: @MainActor () -> Bool) async throws -> Bool {
    let deadline = ContinuousClock.now + .seconds(3)
    while !condition() {
        if ContinuousClock.now >= deadline { throw PlanComputeTestError.timedOut }
        try await Task.sleep(for: .milliseconds(5))
    }
    return true
}

private enum PlanComputeTestError: Error { case timedOut }
