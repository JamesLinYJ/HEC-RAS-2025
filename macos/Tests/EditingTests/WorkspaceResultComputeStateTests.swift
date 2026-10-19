import Foundation
import Testing
import RASWorkspaceCore
@testable import HECRAS2025

struct WorkspaceResultComputeStateTests {
    @Test
    func olderProgressAndCatalogPayloadsDecodeWithoutComputeCorrelation() throws {
        let oldProgress = try JSONDecoder().decode(BackendProgressUpdate.self,
            from: Data(#"{"fraction":0.25,"message":"Solving","taskName":"CPU solver","values":{}}"#.utf8))
        #expect(oldProgress.resultCompute == nil)

        let preNameEnvelope = #"{"runId":"00000000-0000-0000-0000-000000000003","projectPath":"/fixture/Project.ras","projectRevision":"p","projectXmlFingerprint":"x","planPath":"/fixture/Plans/Plan A.h5","planRevision":"r","resultPath":"/fixture/Results/Run 1.h5","state":"running"}"#
        let preNameProgress = try JSONDecoder().decode(BackendProgressUpdate.self,
            from: Data((#"{"resultCompute":\#(preNameEnvelope)}"#).utf8))
        #expect(preNameProgress.resultCompute?.resultName == nil)

        let oldTerminal = Data(#"{"inspectionId":"inspect","revision":"plan","state":"completed","resultPath":"/fixture/result.h5","resultRevision":"sha","summary":null,"messages":[],"errorMessage":null,"finalDependencies":[],"sourceValues":{}}"#.utf8)
        let terminal = try JSONDecoder().decode(PlanComputeExecutionResult.self, from: oldTerminal)
        #expect(terminal.resultCompute == nil)

        let oldNode = try JSONDecoder().decode(CatalogTreeNodeResponse.self,
            from: Data(#"{"id":"result","sourceClass":"ResultNodeVM","name":"Run 1","assetID":"/fixture/result.h5"}"#.utf8))
        #expect(oldNode.resultComputeState == nil && oldNode.resultComputeFailureReason == nil)
        #expect(oldNode.resultComputeSourcePath == nil && oldNode.resultComputeSourceRevision == nil)
    }

    @Test
    func persistedMissingSummaryAndFallbackReasonRemainUnknown() {
        let presentation = WorkspaceResultComputePresentation.resolve(
            path: "/fixture/result.h5", projectSessionID: UUID(), liveEntries: [:],
            persistedState: nil, persistedFailureReason: "Unknown Compute Error")
        #expect(presentation.status == .unknown)
        #expect(presentation.failureReason == nil && !presentation.isLive)

        let failedSummary = WorkspaceResultComputePresentation.resolve(
            path: "/fixture/result.h5", projectSessionID: UUID(), liveEntries: [:],
            persistedState: "failed", persistedFailureReason: "Source failure")
        #expect(failedSummary.status == .failed && failedSummary.failureReason == "Source failure")
    }

    @Test
    func liveUpdatesRequireCurrentProjectOwnerAndExactSourceIdentity() throws {
        let capture = resultComputeCapture()
        let envelope = resultComputeEnvelope()
        let update = BackendProgressUpdate(fraction: 0.4, message: "Solving", taskName: "CPU solver",
            resultCompute: envelope)

        let unrelatedEnvelope = BackendResultComputeUpdate(runId: "00000000-0000-0000-0000-000000000099",
            projectPath: envelope.projectPath, projectRevision: envelope.projectRevision,
            projectXmlFingerprint: envelope.projectXmlFingerprint, planPath: envelope.planPath,
            planRevision: envelope.planRevision, resultPath: envelope.resultPath, state: "running")
        #expect(WorkspaceResultComputeReducer.acceptProgress(unrelatedEnvelope, progress: update,
            capture: capture, activeCapture: capture, projectSessionID: capture.projectSessionID,
            editorID: capture.editorID, operationOwnerToken: capture.operationOwnerToken,
            operationContextID: capture.operationContextID) == nil)

        let accepted = WorkspaceResultComputeReducer.acceptProgress(envelope, progress: update,
            capture: capture, activeCapture: capture, projectSessionID: capture.projectSessionID,
            editorID: capture.editorID, operationOwnerToken: capture.operationOwnerToken,
            operationContextID: capture.operationContextID)
        #expect(accepted?.status == .running && accepted?.fraction == 0.4)
        #expect(accepted?.resultPath == "/fixture/results/run-1.h5")

        let staleOwner = resultComputeCapture(operationOwnerToken: "previous-run-owner")
        #expect(WorkspaceResultComputeReducer.acceptProgress(envelope, progress: update,
            capture: staleOwner, activeCapture: capture, projectSessionID: capture.projectSessionID,
            editorID: capture.editorID, operationOwnerToken: staleOwner.operationOwnerToken,
            operationContextID: staleOwner.operationContextID) == nil)

        #expect(WorkspaceResultComputeReducer.acceptProgress(envelope, progress: update,
            capture: capture, activeCapture: capture, projectSessionID: UUID(),
            editorID: capture.editorID, operationOwnerToken: capture.operationOwnerToken,
            operationContextID: capture.operationContextID) == nil)

        let wrongPlan = BackendResultComputeUpdate(runId: envelope.runId,
            projectPath: envelope.projectPath, projectRevision: envelope.projectRevision,
            projectXmlFingerprint: envelope.projectXmlFingerprint, planPath: "/fixture/Plans/Other.h5",
            planRevision: envelope.planRevision, resultPath: envelope.resultPath, state: "running")
        let wrongPlanUpdate = BackendProgressUpdate(fraction: 0.4, resultCompute: wrongPlan)
        #expect(WorkspaceResultComputeReducer.acceptProgress(wrongPlan, progress: wrongPlanUpdate,
            capture: capture, activeCapture: capture, projectSessionID: capture.projectSessionID,
            editorID: capture.editorID, operationOwnerToken: capture.operationOwnerToken,
            operationContextID: capture.operationContextID) == nil)

        let beforeSourceCreated = BackendResultComputeUpdate(runId: envelope.runId,
            projectPath: envelope.projectPath, projectRevision: envelope.projectRevision,
            projectXmlFingerprint: envelope.projectXmlFingerprint, planPath: envelope.planPath,
            planRevision: envelope.planRevision, resultPath: nil, state: "running")
        #expect(WorkspaceResultComputeReducer.acceptProgress(beforeSourceCreated,
            progress: BackendProgressUpdate(resultCompute: beforeSourceCreated),
            capture: capture, activeCapture: capture, projectSessionID: capture.projectSessionID,
            editorID: capture.editorID, operationOwnerToken: capture.operationOwnerToken,
            operationContextID: capture.operationContextID) == nil)
    }

    @Test
    func terminalReconciliationRequiresExactReturnedPathRevisionAndRun() throws {
        let capture = resultComputeCapture()
        let envelope = resultComputeEnvelope(state: "completed", resultRevision: String(repeating: "C", count: 64))
        let result = PlanComputeExecutionResult(inspectionId: "inspection", revision: capture.planRevision,
            state: "completed", resultPath: envelope.resultPath, resultRevision: envelope.resultRevision,
            summary: nil, messages: [], errorMessage: nil, finalDependencies: [], sourceValues: [:],
            resultCompute: envelope)
        let accepted = try #require(WorkspaceResultComputeReducer.acceptTerminal(envelope, result: result,
            capture: capture, activeCapture: capture, projectSessionID: capture.projectSessionID,
            editorID: capture.editorID, operationOwnerToken: capture.operationOwnerToken,
            operationContextID: capture.operationContextID))
        #expect(accepted.status == .completed && accepted.resultRevision == envelope.resultRevision)
        let staleSelectedRevision = WorkspaceResultComputePresentation.resolve(
            path: accepted.resultPath, projectSessionID: capture.projectSessionID,
            sourceRevision: "old-result-revision",
            liveEntries: [accepted.resultPath: accepted], persistedState: nil,
            persistedFailureReason: nil)
        #expect(staleSelectedRevision.status == .unknown)

        let mismatched = PlanComputeExecutionResult(inspectionId: "inspection", revision: capture.planRevision,
            state: "completed", resultPath: "/fixture/results/another.h5", resultRevision: envelope.resultRevision,
            summary: nil, messages: [], errorMessage: nil, finalDependencies: [], sourceValues: [:],
            resultCompute: envelope)
        #expect(WorkspaceResultComputeReducer.acceptTerminal(envelope, result: mismatched,
            capture: capture, activeCapture: capture, projectSessionID: capture.projectSessionID,
            editorID: capture.editorID, operationOwnerToken: capture.operationOwnerToken,
            operationContextID: capture.operationContextID) == nil)

        let noStableResultRevision = BackendResultComputeUpdate(runId: envelope.runId,
            projectPath: envelope.projectPath, projectRevision: envelope.projectRevision,
            projectXmlFingerprint: envelope.projectXmlFingerprint, planPath: envelope.planPath,
            planRevision: envelope.planRevision, resultPath: envelope.resultPath,
            state: "completed", resultRevision: nil)
        let noStableRevisionResult = PlanComputeExecutionResult(inspectionId: "inspection",
            revision: capture.planRevision, state: "completed", resultPath: envelope.resultPath,
            resultRevision: nil, summary: nil, messages: [], errorMessage: nil,
            finalDependencies: [], sourceValues: [:], resultCompute: noStableResultRevision)
        #expect(WorkspaceResultComputeReducer.acceptTerminal(noStableResultRevision,
            result: noStableRevisionResult, capture: capture, activeCapture: capture,
            projectSessionID: capture.projectSessionID, editorID: capture.editorID,
            operationOwnerToken: capture.operationOwnerToken,
            operationContextID: capture.operationContextID) == nil)

        let running = WorkspaceResultComputeEntry(runID: envelope.runId,
            projectSessionID: capture.projectSessionID, editorID: capture.editorID,
            operationOwnerToken: capture.operationOwnerToken, operationContextID: capture.operationContextID,
            projectPath: capture.projectPath, projectRevision: capture.projectRevision,
            projectXmlFingerprint: capture.projectXmlFingerprint, planPath: capture.planPath,
            planRevision: capture.planRevision, resultPath: "/fixture/results/run-1.h5", resultName: "Run 1",
            resultRevision: nil, status: .running, fraction: 0.9, message: nil,
            taskName: nil, failureReason: nil)
        #expect(!WorkspaceResultComputeReducer.shouldReplace(accepted, with: running))
        let conflictingTerminal = WorkspaceResultComputeEntry(runID: accepted.runID,
            projectSessionID: accepted.projectSessionID, editorID: accepted.editorID,
            operationOwnerToken: accepted.operationOwnerToken, operationContextID: accepted.operationContextID,
            projectPath: accepted.projectPath, projectRevision: accepted.projectRevision,
            projectXmlFingerprint: accepted.projectXmlFingerprint, planPath: accepted.planPath,
            planRevision: accepted.planRevision, resultPath: accepted.resultPath, resultName: accepted.resultName,
            resultRevision: accepted.resultRevision, status: .failed, fraction: nil,
            message: nil, taskName: nil, failureReason: "late conflicting terminal")
        #expect(!WorkspaceResultComputeReducer.shouldReplace(accepted, with: conflictingTerminal))
    }

    @Test
    func acceptedCatalogResultSnapshotRetiresExactTerminalWithoutLoadedMap() throws {
        let capture = resultComputeCapture()
        let revision = String(repeating: "A", count: 64)
        let envelope = resultComputeEnvelope(state: "cancelled", resultRevision: revision)
        let result = PlanComputeExecutionResult(inspectionId: "inspection",
            revision: capture.planRevision, state: "cancelled", resultPath: envelope.resultPath,
            resultRevision: revision, summary: nil, messages: [], errorMessage: nil,
            finalDependencies: [], sourceValues: [:], resultCompute: envelope)
        let cancelled = try #require(WorkspaceResultComputeReducer.acceptTerminal(envelope,
            result: result, capture: capture, activeCapture: capture,
            projectSessionID: capture.projectSessionID, editorID: capture.editorID,
            operationOwnerToken: capture.operationOwnerToken,
            operationContextID: capture.operationContextID))

        // This accepted catalog snapshot has a Result source row but no map
        // context or MultiResult map node. Only that source row's exact SHA
        // may retire the terminal callback entry.
        let exactResult = LayerTreeNode(id: "source-result", sourceClass: "ObservableResult",
            name: "Run 1", assetID: envelope.resultPath,
            resultComputeState: "failed", resultComputeFailureReason: "User Cancelled",
            resultComputeSourcePath: "/fixture/results/../results/run-1.h5",
            resultComputeSourceRevision: revision)
        let wrongRevision = LayerTreeNode(id: "wrong-revision", sourceClass: "ResultNodeVM",
            name: "Run 1", resultComputeSourcePath: envelope.resultPath,
            resultComputeSourceRevision: String(repeating: "B", count: 64))
        let transientOnly = LayerTreeNode(id: "transient", sourceClass: "TransientResultComputeNode",
            name: "Run 1", resultComputeSourcePath: envelope.resultPath,
            resultComputeSourceRevision: revision)
        let roots = [LayerTreeNode(id: "project", sourceClass: "ModelSectionContext",
            name: "Project", children: [exactResult, wrongRevision, transientOnly])]
        let confirmed = WorkspaceResultComputeCatalogReconciliation.confirmedTerminalEntries(
            in: LayerTreeSnapshot(roots: roots), projectSessionID: capture.projectSessionID,
            liveEntries: [cancelled.resultPath: cancelled])
        #expect(confirmed == [cancelled])

        var liveEntries = [cancelled.resultPath: cancelled]
        for entry in confirmed { liveEntries.removeValue(forKey: entry.resultPath) }
        let persisted = WorkspaceResultComputePresentation.resolve(path: envelope.resultPath,
            projectSessionID: capture.projectSessionID, sourceRevision: revision,
            liveEntries: liveEntries, persistedState: "failed",
            persistedFailureReason: "User Cancelled")
        #expect(persisted.status == .failed)
        #expect(persisted.failureReason == "User Cancelled" && !persisted.isLive)
    }

    @Test
    func multiResultNeverUsesItsPlanAssetAsTheSelectedResultPath() {
        let group = LayerTreeNode(id: "multi", sourceClass: "MultiResultNodeVM", name: "Plan A",
            assetID: "/fixture/Plans/Plan A.h5")
        #expect(ResultComputePresentationPath.exactResultPath(for: group) == nil)

        let selected = LayerTreeNode(id: "multi", sourceClass: "MultiResultNodeVM", name: "Plan A",
            assetID: "/fixture/Plans/Plan A.h5", resultComputeSourcePath: "/fixture/Results/Run 1.h5",
            resultComputeSourceRevision: "selected-revision")
        #expect(ResultComputePresentationPath.exactResultPath(for: selected) == "/fixture/Results/Run 1.h5")
    }

    @Test
    func transientResultProjectionUsesActualIdentityAndDeduplicatesMaterializedSourceRows() throws {
        let capture = resultComputeCapture()
        let envelope = resultComputeEnvelope()
        let progress = BackendProgressUpdate(resultCompute: envelope)
        let entry = try #require(WorkspaceResultComputeReducer.acceptProgress(envelope, progress: progress,
            capture: capture, activeCapture: capture, projectSessionID: capture.projectSessionID,
            editorID: capture.editorID, operationOwnerToken: capture.operationOwnerToken,
            operationContextID: capture.operationContextID))
        let transient = TransientResultComputeRow(entry: entry)
        #expect(transient.resultPath == "/fixture/results/run-1.h5")
        #expect(transient.resultName == "run-1.h5")
        #expect(transient.runID == envelope.runId)
        let namedEnvelope = resultComputeEnvelope(resultName: "Source Run Name")
        let namedEntry = try #require(WorkspaceResultComputeReducer.acceptProgress(namedEnvelope,
            progress: BackendProgressUpdate(resultCompute: namedEnvelope), capture: capture,
            activeCapture: capture, projectSessionID: capture.projectSessionID,
            editorID: capture.editorID, operationOwnerToken: capture.operationOwnerToken,
            operationContextID: capture.operationContextID))
        #expect(TransientResultComputeRow(entry: namedEntry).resultName == "Source Run Name")

        let results = LayerTreeNode(id: "results", sourceClass: "ResultRootContext", name: "Results")
        let project = LayerTreeNode(id: "project", sourceClass: "ModelSectionContext", name: "Project", children: [results])
        let projected = try #require(TransientResultComputeProjection.apply(
            snapshotRoots: [project], rows: [transient.resultPath: transient],
            projectSessionID: capture.projectSessionID))
        let projectedResults = try #require(projected.first?.find("results"))
        #expect(projectedResults.children?.count == 1)
        #expect(projectedResults.children?.first?.sourceClass == "TransientResultComputeNode")
        #expect(projectedResults.children?.first?.assetID == transient.resultPath)

        let materialized = LayerTreeNode(id: "source-result", sourceClass: "ObservableResult", name: "Run 1",
            assetID: entry.resultPath, resultComputeSourcePath: entry.resultPath)
        let sourceResults = LayerTreeNode(id: "results", sourceClass: "ResultRootContext", name: "Results",
            children: [materialized])
        let sourceProject = LayerTreeNode(id: "project", sourceClass: "ModelSectionContext", name: "Project",
            children: [sourceResults])
        let merged = try #require(TransientResultComputeProjection.apply(
            snapshotRoots: [sourceProject], rows: [transient.resultPath: transient],
            projectSessionID: capture.projectSessionID))
        let mergedResults = try #require(merged.first?.find("results"))
        #expect(mergedResults.children?.count == 1)
        #expect(mergedResults.children?.first?.sourceClass == "ObservableResult")
    }

    @Test @MainActor
    func transientRowsRetireUnconfirmedRunAndClearWhenProjectChanges() async throws {
        let capture = resultComputeCapture()
        let envelope = resultComputeEnvelope()
        let entry = try #require(WorkspaceResultComputeReducer.acceptProgress(envelope,
            progress: BackendProgressUpdate(resultCompute: envelope), capture: capture,
            activeCapture: capture, projectSessionID: capture.projectSessionID,
            editorID: capture.editorID, operationOwnerToken: capture.operationOwnerToken,
            operationContextID: capture.operationContextID))
        let session = LayerTreeSession()
        session.upsertTransientResultComputeRow(entry)
        let transientRow = TransientResultComputeRow(entry: entry)
        let row = try #require(session.roots?.lazy.compactMap { $0.find(transientRow.id) }.first)
        #expect(row.transientResultComputeStatus == "running")
        #expect(session.markUnconfirmedTransientResultComputeRowsUnknown(projectSessionID: capture.projectSessionID,
            editorID: capture.editorID, operationOwnerToken: "stale-owner", operationContextID: capture.operationContextID).isEmpty)
        #expect(session.markUnconfirmedTransientResultComputeRowsUnknown(projectSessionID: capture.projectSessionID,
            editorID: capture.editorID, operationOwnerToken: capture.operationOwnerToken,
            operationContextID: capture.operationContextID) == [entry.resultPath])
        #expect(session.roots?.lazy.compactMap { $0.find(row.id) }.first?.transientResultComputeStatus == "unknown")

        let nextProject = UUID()
        await session.load(provider: nil, context: LayerTreeContext(projectSessionID: nextProject,
            projectURL: nil, mapID: MapState.projectMapID, mode: "Catalog",
            focusedGeometryIDs: [], focusedPlanIDs: []))
        #expect(session.roots == nil)
    }
}

private func resultComputeCapture(operationOwnerToken: String = "run-owner") -> WorkspaceResultComputeCapture {
    WorkspaceResultComputeCapture(projectSessionID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        editorID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
        operationOwnerToken: operationOwnerToken, operationContextID: "plan-context",
        projectPath: "/fixture/Project.ras", projectRevision: "project-revision",
        projectXmlFingerprint: "project-xml-fingerprint", planPath: "/fixture/Plans/Plan A.h5",
        planRevision: "plan-revision")
}

private func resultComputeEnvelope(state: String = "running", resultRevision: String? = nil,
                                   resultName: String? = nil) -> BackendResultComputeUpdate {
    BackendResultComputeUpdate(runId: "00000000-0000-0000-0000-000000000003",
        projectPath: "/fixture/Project.ras", projectRevision: "project-revision",
        projectXmlFingerprint: "project-xml-fingerprint", planPath: "/fixture/Plans/Plan A.h5",
        planRevision: "plan-revision", resultPath: "/fixture/results/run-1.h5", resultName: resultName,
        state: state, resultRevision: resultRevision,
        failureReason: state == "failed" ? "Source compute failure" : nil)
}
