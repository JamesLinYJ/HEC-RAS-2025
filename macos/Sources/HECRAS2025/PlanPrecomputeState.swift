import Foundation
import RASWorkspaceCore
import SwiftUI

struct PlanPrecomputeResult: Codable, Sendable, Equatable {
    let revision: String
    let result: Bool
    let messages: [PlanPrecomputeMessage]
}

struct PlanPrecomputeDraftResponse: Decodable, Sendable, Equatable {
    let captureID: String
    let result: PlanPrecomputeResult
}

struct PlanPrecomputeMessage: Codable, Sendable, Equatable, Identifiable {
    let code: String
    let defaultSeverity: String
    let evaluatedMessage: String
    let logData: [PlanPrecomputeLogDatum]
    let extraCount: Int

    var id: String { code }
}

struct PlanPrecomputeLogDatum: Codable, Sendable, Equatable {
    let key: String
    let value: String?
    let target: PlanDiagnosticTarget?
    init(key: String, value: String?, target: PlanDiagnosticTarget? = nil) {
        self.key = key; self.value = value; self.target = target
    }
}

@MainActor
protocol PlanPrecomputeProvider {
    func inspect(_ asset: ProjectAsset, edits: EditorEdits) async throws -> PlanPrecomputeResult
    func inspect(_ asset: ProjectAsset, edits: EditorEdits,
                 associatedDrafts: PlanPrecomputeAssociatedDraftsCapture?) async throws -> PlanPrecomputeDraftResponse
}

@MainActor
extension PlanPrecomputeProvider {
    func inspect(_ asset: ProjectAsset, edits: EditorEdits,
                 associatedDrafts: PlanPrecomputeAssociatedDraftsCapture?) async throws -> PlanPrecomputeDraftResponse {
        guard associatedDrafts?.geometry == nil, associatedDrafts?.boundaryCondition == nil else {
            throw BackendServiceError(code: "unsupported",
                message: "The active Plan precompute service cannot inspect unsaved associated model drafts.")
        }
        let result = try await inspect(asset, edits: edits)
        return PlanPrecomputeDraftResponse(captureID: associatedDrafts?.id ?? "", result: result)
    }
}

@MainActor
final class PlanPrecomputeState: ObservableObject {
    @Published private(set) var isRefreshing = false
    @Published private(set) var result: PlanPrecomputeResult?
    @Published private(set) var resultContextID: String?
    @Published private(set) var resultProjectSessionID: UUID?
    @Published private(set) var resultAssociatedDraftsID: String?
    @Published private(set) var errorMessage: String?

    private var requestGeneration = 0
    private var activeContextID: String?
    private var activeProjectSessionID: UUID?
    private var activeEditorID: UUID?
    private var activeAssetsRevision: Int?
    private var activeAssociatedDraftsID: String?
    private var requestTask: Task<Void, Never>?

    func refresh(session: ModelEditorSession, store: WorkspaceStore? = nil, force: Bool = false) {
        guard let context = session.currentPlanPrecomputeContext(),
              let sourceRevision = context.edits.sourceRevision else {
            errorMessage = L10n.text("Run the source plan check to see diagnostics.")
            return
        }
        guard let provider = session.provider as? any PlanPrecomputeProvider else {
            errorMessage = L10n.text("Plan precompute is unavailable from the active model service.")
            return
        }
        guard store.map({ !$0.isSavingAll && !$0.isClosingTab }) ?? true else { return }
        let projectSessionID = store?.projectSessionID
        let associatedCapture: PlanPrecomputeAssociatedDraftsCapture?
        do {
            associatedCapture = try store?.capturePlanPrecomputeAssociatedDrafts(
                planEditorID: session.id, planContextID: context.id,
                projectSessionID: projectSessionID ?? UUID())
        } catch {
            requestGeneration += 1
            requestTask?.cancel()
            requestTask = nil
            isRefreshing = false
            activeContextID = nil
            activeProjectSessionID = nil
            activeEditorID = nil
            activeAssetsRevision = nil
            activeAssociatedDraftsID = nil
            result = nil
            resultContextID = nil
            resultProjectSessionID = nil
            resultAssociatedDraftsID = nil
            errorMessage = L10n.text(error.localizedDescription)
            return
        }
        let associatedDraftsID = associatedCapture?.id ?? "unscoped"
        let editorID = session.id
        let assetsRevision = store?.assetsRevision
        if store != nil, isRefreshing, activeContextID == context.id,
           activeProjectSessionID == projectSessionID,
           activeEditorID == editorID,
           activeAssetsRevision == assetsRevision,
           activeAssociatedDraftsID == associatedDraftsID { return }
        if !force, resultContextID == context.id,
           activeProjectSessionID == projectSessionID,
           activeEditorID == editorID,
           activeAssetsRevision == assetsRevision,
           resultAssociatedDraftsID == associatedDraftsID { return }

        requestGeneration += 1
        let generation = requestGeneration
        requestTask?.cancel()
        requestTask = nil
        activeContextID = context.id
        activeProjectSessionID = projectSessionID
        activeEditorID = editorID
        activeAssetsRevision = assetsRevision
        activeAssociatedDraftsID = associatedDraftsID
        isRefreshing = true
        result = nil
        resultContextID = nil
        resultProjectSessionID = nil
        resultAssociatedDraftsID = nil
        errorMessage = nil

        let requiresStoreGuard = store != nil
        requestTask = Task { [weak self, weak session, weak store] in
            do {
                let response = try await provider.inspect(context.asset, edits: context.edits,
                    associatedDrafts: associatedCapture)
                guard let self, self.requestGeneration == generation else { return }
                self.requestTask = nil
                self.isRefreshing = false
                let workspaceIsCurrent = store.map {
                    $0.projectSessionID == projectSessionID && $0.assetsRevision == assetsRevision
                } ?? !requiresStoreGuard
                let associatedDraftsAreCurrent = store.map { currentStore in
                    associatedCapture.map { currentStore.isCurrentPlanPrecomputeAssociatedDrafts($0) }
                        ?? !requiresStoreGuard
                } ?? (associatedCapture == nil)
                guard let session,
                      workspaceIsCurrent,
                      associatedDraftsAreCurrent,
                      session.id == editorID,
                      session.isCurrentPlanPrecomputeContext(context.id) else {
                    self.clearIfStale(currentContextID: nil)
                    return
                }
                guard response.captureID == (associatedCapture?.id ?? ""),
                      response.result.revision == sourceRevision else {
                    self.errorMessage = L10n.text("The model source changed during the check. Reload the plan and try again.")
                    self.activeContextID = nil
                    return
                }
                self.result = response.result
                self.resultContextID = context.id
                self.resultProjectSessionID = projectSessionID
                self.resultAssociatedDraftsID = associatedDraftsID
                self.activeContextID = context.id
            } catch {
                guard let self, self.requestGeneration == generation else { return }
                self.requestTask = nil
                self.isRefreshing = false
                let workspaceIsCurrent = store.map {
                    $0.projectSessionID == projectSessionID && $0.assetsRevision == assetsRevision
                } ?? !requiresStoreGuard
                let associatedDraftsAreCurrent = store.map { currentStore in
                    associatedCapture.map { currentStore.isCurrentPlanPrecomputeAssociatedDrafts($0) }
                        ?? !requiresStoreGuard
                } ?? (associatedCapture == nil)
                guard let session,
                      workspaceIsCurrent,
                      associatedDraftsAreCurrent,
                      session.id == editorID,
                      session.isCurrentPlanPrecomputeContext(context.id) else {
                    self.clearIfStale(currentContextID: nil)
                    return
                }
                self.errorMessage = error.localizedDescription
                self.activeContextID = context.id
            }
        }
    }

    func clearIfStale(currentContextID: String?, currentAssociatedDraftsID: String? = nil) {
        let associatedDraftsAreStale = currentAssociatedDraftsID.map {
            activeAssociatedDraftsID != $0 || resultAssociatedDraftsID != $0
        } ?? false
        if activeContextID != currentContextID || associatedDraftsAreStale {
            requestGeneration += 1
            requestTask?.cancel()
            requestTask = nil
            activeContextID = nil
            activeProjectSessionID = nil
            activeEditorID = nil
            activeAssetsRevision = nil
            activeAssociatedDraftsID = nil
            isRefreshing = false
        }
        if resultContextID != currentContextID || associatedDraftsAreStale {
            result = nil
            resultContextID = nil
            resultProjectSessionID = nil
            resultAssociatedDraftsID = nil
            errorMessage = nil
        }
    }
}
