import Foundation
import RASWorkspaceCore

struct PlanComputeDependency: Decodable, Equatable, Identifiable, Sendable {
    let role: String
    let path: String
    let revision: String
    let willWrite: Bool

    var id: String { role + "|" + path }
}

struct PlanComputeInspection: Decodable, Equatable, Sendable {
    let inspectionId: String
    let revision: String
    let projectRevision: String
    let projectXmlFingerprint: String
    let canExecute: Bool
    let requiresCUDA: Bool
    let reasons: [String]
    let messages: [PlanPrecomputeMessage]
    let sourceDependencies: [PlanComputeDependency]
    let sideEffects: [String]
}

struct PlanComputeCancellation: Encodable, Equatable, Sendable {
    let directory: String
    let nonce: String
}

struct PlanComputeSummary: Decodable, Equatable, Sendable {
    let success: Bool
    let failureReason: String?
    let solver: String?
    let softwareVersion: String?
    let startTime: String?
    let endTime: String?
    let totalDurationSeconds: Double?
    let solverInitDurationSeconds: Double?
    let outputDurationSeconds: Double?
    let globalRetryCount: Int?
    let computeLog: String?
}

struct PlanComputeExecutionResult: Decodable, Equatable, Sendable {
    let inspectionId: String
    let revision: String
    let state: String
    let resultPath: String?
    let resultRevision: String?
    let summary: PlanComputeSummary?
    let messages: [PlanPrecomputeMessage]
    let errorMessage: String?
    let finalDependencies: [PlanComputeDependency]
    let sourceValues: [String: String]?
    let resultCompute: BackendResultComputeUpdate?

    init(inspectionId: String, revision: String, state: String, resultPath: String?,
         resultRevision: String?, summary: PlanComputeSummary?, messages: [PlanPrecomputeMessage],
         errorMessage: String?, finalDependencies: [PlanComputeDependency],
         sourceValues: [String: String]?, resultCompute: BackendResultComputeUpdate? = nil) {
        self.inspectionId = inspectionId
        self.revision = revision
        self.state = state
        self.resultPath = resultPath
        self.resultRevision = resultRevision
        self.summary = summary
        self.messages = messages
        self.errorMessage = errorMessage
        self.finalDependencies = finalDependencies
        self.sourceValues = sourceValues
        self.resultCompute = resultCompute
    }
}

@MainActor
protocol PlanComputeProvider {
    func inspectCompute(_ asset: ProjectAsset, edits: EditorEdits) async throws -> PlanComputeInspection
    func executeCompute(_ asset: ProjectAsset, edits: EditorEdits, inspectionID: String,
                        cancellation: PlanComputeCancellation,
                        progress: @escaping @Sendable (BackendProgressUpdate) -> Void) async throws -> PlanComputeExecutionResult
    func executeComputeDuplex(_ asset: ProjectAsset, edits: EditorEdits, inspectionID: String,
                              cancellation: PlanComputeCancellation,
                              targetUpdates: AsyncStream<PlanComputeLiveMapTargetUpdate>,
                              update: @escaping @MainActor @Sendable (PlanComputeDuplexUpdate) async -> Void) async throws -> PlanComputeExecutionResult
}

extension PlanComputeProvider {
    func executeComputeDuplex(_ asset: ProjectAsset, edits: EditorEdits, inspectionID: String,
                              cancellation: PlanComputeCancellation,
                              targetUpdates: AsyncStream<PlanComputeLiveMapTargetUpdate>,
                              update: @escaping @MainActor @Sendable (PlanComputeDuplexUpdate) async -> Void) async throws -> PlanComputeExecutionResult {
        try await executeCompute(asset, edits: edits, inspectionID: inspectionID,
            cancellation: cancellation, progress: { progress in
                Task { @MainActor in await update(.init(progress: progress, liveMapFrame: nil)) }
            })
    }
}

extension BackendModelProvider: PlanComputeProvider {
    func inspectCompute(_ asset: ProjectAsset, edits: EditorEdits) async throws -> PlanComputeInspection {
        struct Request: Encodable, Sendable {
            let model: BackendModelProvider.ModelSaveRequest
        }
        guard asset.section == .plans else { throw CocoaError(.featureUnsupported) }
        return try await client.request("plan.compute.inspect",
            parameters: Request(model: try saveRequest(asset, changes: edits)),
            as: PlanComputeInspection.self)
    }

    func executeCompute(_ asset: ProjectAsset, edits: EditorEdits, inspectionID: String,
                        cancellation: PlanComputeCancellation,
                        progress: @escaping @Sendable (BackendProgressUpdate) -> Void) async throws -> PlanComputeExecutionResult {
        struct Request: Encodable, Sendable {
            let model: BackendModelProvider.ModelSaveRequest
            let inspectionId: String
            let cancellation: PlanComputeCancellation
        }
        guard asset.section == .plans else { throw CocoaError(.featureUnsupported) }
        let request = Request(model: try saveRequest(asset, changes: edits),
            inspectionId: inspectionID, cancellation: cancellation)
        return try await client.request("plan.compute.execute", parameters: request,
            as: PlanComputeExecutionResult.self, progress: progress)
    }

    func executeComputeDuplex(_ asset: ProjectAsset, edits: EditorEdits, inspectionID: String,
                              cancellation: PlanComputeCancellation,
                              targetUpdates: AsyncStream<PlanComputeLiveMapTargetUpdate>,
                              update: @escaping @MainActor @Sendable (PlanComputeDuplexUpdate) async -> Void) async throws -> PlanComputeExecutionResult {
        struct Request: Encodable, Sendable {
            let model: BackendModelProvider.ModelSaveRequest
            let inspectionId: String
            let cancellation: PlanComputeCancellation
        }
        guard asset.section == .plans else { throw CocoaError(.featureUnsupported) }
        let request = Request(model: try saveRequest(asset, changes: edits),
            inspectionId: inspectionID, cancellation: cancellation)
        let operation = try client.startDuplex("plan.compute.execute", parameters: request,
            control: PlanComputeLiveMapControl.self, event: PlanComputeDuplexEvent.self,
            as: PlanComputeExecutionResult.self)
        let controlTask = Task.detached(priority: .userInitiated) {
            var sequence: UInt64 = 0
            for await update in targetUpdates {
                sequence &+= 1
                do {
                    switch update {
                    case .replace(let targets):
                        try operation.sendControl(.replaceTargets(targets), sequence: sequence)
                    case .cancel:
                        try operation.sendControl(.cancel, sequence: sequence)
                    }
                } catch let error as BackendServiceError where error.code == "duplexClosed" {
                    break
                }
            }
        }
        do {
            let result = try await withTaskCancellationHandler {
                for try await event in operation.events {
                    await update(.init(progress: event.progress, liveMapFrame: event.liveMapFrame,
                        liveVelocityFrame: event.liveVelocityFrame,
                        liveVelocityUnavailable: event.liveVelocityUnavailable))
                }
                return try await operation.value()
            } onCancel: {
                controlTask.cancel()
                operation.cancel()
            }
            controlTask.cancel()
            return result
        } catch {
            controlTask.cancel()
            operation.cancel()
            throw error
        }
    }
}
