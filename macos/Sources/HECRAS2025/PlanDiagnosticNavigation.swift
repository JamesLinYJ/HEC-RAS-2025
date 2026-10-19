import CryptoKit
import Combine
import Foundation
import RASWorkspaceCore

enum PlanDiagnosticNavigationPhase: Equatable {
    case validating
    case ready
}
enum PlanDiagnosticNavigationAction: Equatable {
    case open
    case computeGeometryPropertyTables
}

struct PlanDiagnosticNavigationRequest: Equatable, Identifiable {
    let id: UUID
    let target: PlanDiagnosticTarget
    let projectSessionID: UUID
    let planEditorID: UUID
    let planContextID: String
    let destinationKind: ModelEditorKind
    let destinationAssetID: String
    let destinationPageID: String
    let action: PlanDiagnosticNavigationAction
    var phase: PlanDiagnosticNavigationPhase

    init(id: UUID = UUID(), target: PlanDiagnosticTarget, projectSessionID: UUID,
         planEditorID: UUID, planContextID: String, destinationKind: ModelEditorKind,
         destinationAssetID: String, destinationPageID: String,
         action: PlanDiagnosticNavigationAction = .open,
         phase: PlanDiagnosticNavigationPhase = .validating) {
        self.id = id
        self.target = target
        self.projectSessionID = projectSessionID
        self.planEditorID = planEditorID
        self.planContextID = planContextID
        self.destinationKind = destinationKind
        self.destinationAssetID = destinationAssetID
        self.destinationPageID = destinationPageID
        self.action = action
        self.phase = phase
    }

    func changingPhase(_ phase: PlanDiagnosticNavigationPhase) -> Self {
        Self(id: id, target: target, projectSessionID: projectSessionID,
             planEditorID: planEditorID, planContextID: planContextID,
             destinationKind: destinationKind, destinationAssetID: destinationAssetID,
             destinationPageID: destinationPageID, action: action, phase: phase)
    }
}

private struct PlanDiagnosticNavigationDestination: Equatable {
    let kind: ModelEditorKind
    let assetID: String
    let pageID: String
}

enum PlanDiagnosticNavigationIdentity {
    static func uniqueAssociation(named name: String, group: String,
                                  in rows: [ProjectAssociation]) -> ProjectAssociation? {
        let matches = rows.filter { $0.group == group && $0.name == name }
        guard matches.count == 1 else { return nil }
        return matches[0]
    }

    static func uniqueAssociatedAsset(named name: String, section: ProjectSection,
                                      in assets: [ProjectAsset]) -> ProjectAsset? {
        let matches = assets.filter { $0.section == section && $0.isModelFile && $0.name == name }
        guard matches.count == 1 else { return nil }
        return matches[0]
    }

    static func uniqueFeatureRow(index: Int, name: String, names: [String]) -> Bool {
        guard index >= 0, names.indices.contains(index), names[index] == name else { return false }
        return names.filter { $0 == name }.count == 1
    }
}

/// Hashes source files off the main actor and in bounded chunks. Diagnostic
/// navigation can involve large HDF inputs, so it never materializes a file as
/// one in-memory Data value on the UI thread.
enum PlanDiagnosticFileFingerprint {
    static func sha256(path: String) async throws -> String {
        let worker = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
            defer { try? handle.close() }
            var hasher = SHA256()
            while true {
                try Task.checkCancellation()
                guard let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty else { break }
                hasher.update(data: chunk)
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    static func matches(_ target: PlanDiagnosticTarget) async -> Bool {
        let expected = [
            (target.projectPath, target.projectRevision),
            (target.planPath, target.planRevision),
            (target.assetPath, target.assetRevision)
        ]
        do {
            return try await withThrowingTaskGroup(of: (String, String).self) { group in
                for (path, revision) in expected {
                    group.addTask {
                        (revision, try await sha256(path: path))
                    }
                }
                for try await (revision, actual) in group {
                    guard revision.caseInsensitiveCompare(actual) == .orderedSame else {
                        group.cancelAll()
                        return false
                    }
                }
                return true
            }
        } catch {
            return false
        }
    }
}

@MainActor
extension WorkspaceStore {
    /// Synchronous in-memory guard used by source-diagnostic context menus.
    /// The caller still hashes every captured file before performing an action.
    func isCurrentPlanDiagnosticTarget(_ target: PlanDiagnosticTarget,
                                       projectSessionID: UUID,
                                       planEditorID: UUID,
                                       planContextID: String) -> Bool {
        planDiagnosticDestination(target, projectSessionID: projectSessionID,
            planEditorID: planEditorID, planContextID: planContextID) != nil
    }

    /// Begins a guarded navigation from a diagnostic emitted by one exact
    /// Plan editor/context. The editor owns model replacement prompts; this
    /// method only requests the target and opens its primary editor after the
    /// captured source revisions have been rechecked.
    @discardableResult
    func navigateToPlanDiagnosticTarget(_ target: PlanDiagnosticTarget,
                                        projectSessionID expectedProjectSessionID: UUID,
                                        planEditorID: UUID,
                                        planContextID: String,
                                        action: PlanDiagnosticNavigationAction = .open) -> Bool {
        guard action == .open || target.kind == "geometry" else { return false }
        guard let destination = planDiagnosticDestination(target,
                  projectSessionID: expectedProjectSessionID,
                  planEditorID: planEditorID, planContextID: planContextID) else { return false }

        let request = PlanDiagnosticNavigationRequest(target: target,
            projectSessionID: expectedProjectSessionID, planEditorID: planEditorID,
            planContextID: planContextID, destinationKind: destination.kind,
            destinationAssetID: destination.assetID, destinationPageID: destination.pageID, action: action)
        pendingPlanDiagnosticNavigation = request

        Task { [weak self] in
            guard let self else { return }
            guard await self.matchesWhilePlanDiagnosticNavigationIsCurrent(target, requestID: request.id) else {
                self.failPlanDiagnosticNavigation(request)
                return
            }
            guard self.pendingPlanDiagnosticNavigation?.id == request.id,
                  let current = self.planDiagnosticDestination(target,
                      projectSessionID: expectedProjectSessionID,
                      planEditorID: planEditorID, planContextID: planContextID),
                  current == destination else {
                self.failPlanDiagnosticNavigation(request)
                return
            }
            self.pendingPlanDiagnosticNavigation = request.changingPhase(.ready)
            guard await self.waitForPlanComputeToFinish(requestID: request.id) else { return }
            guard self.pendingPlanDiagnosticNavigation?.id == request.id,
                  !self.isRunningPlanCompute,
                  self.planDiagnosticDestination(target,
                      projectSessionID: expectedProjectSessionID,
                      planEditorID: planEditorID, planContextID: planContextID) == destination else {
                self.failPlanDiagnosticNavigation(request)
                return
            }
            self.openEditor(destination.kind, assetID: destination.assetID)
        }
        return true
    }
    func requestGeometryPropertyTables(from target: PlanDiagnosticTarget,
                                       projectSessionID: UUID, planEditorID: UUID,
                                       planContextID: String) async -> Bool {
        guard target.kind == "geometry" else { return false }
        return navigateToPlanDiagnosticTarget(target, projectSessionID: projectSessionID,
            planEditorID: planEditorID, planContextID: planContextID, action: .computeGeometryPropertyTables)
    }

    /// Revalidates the exact origin context, current project association and
    /// target hashes immediately before the destination editor selects a row.
    func verifyPlanDiagnosticNavigation(_ request: PlanDiagnosticNavigationRequest) async -> Bool {
        guard request.phase == .ready,
              pendingPlanDiagnosticNavigation?.id == request.id,
              planDiagnosticDestination(request.target,
                  projectSessionID: request.projectSessionID,
                  planEditorID: request.planEditorID,
                  planContextID: request.planContextID) == PlanDiagnosticNavigationDestination(
                      kind: request.destinationKind, assetID: request.destinationAssetID,
                      pageID: request.destinationPageID),
              await matchesWhilePlanDiagnosticNavigationIsCurrent(request.target, requestID: request.id),
              pendingPlanDiagnosticNavigation?.id == request.id,
              planDiagnosticDestination(request.target,
                  projectSessionID: request.projectSessionID,
                  planEditorID: request.planEditorID,
                  planContextID: request.planContextID) == PlanDiagnosticNavigationDestination(
                      kind: request.destinationKind, assetID: request.destinationAssetID,
                      pageID: request.destinationPageID) else { return false }
        return true
    }

    func isCurrentPlanDiagnosticNavigation(_ request: PlanDiagnosticNavigationRequest) -> Bool {
        guard request.phase == .ready,
              pendingPlanDiagnosticNavigation?.id == request.id,
              projectSessionID == request.projectSessionID else { return false }
        return planDiagnosticDestination(request.target,
            projectSessionID: request.projectSessionID,
            planEditorID: request.planEditorID,
            planContextID: request.planContextID) == PlanDiagnosticNavigationDestination(
                kind: request.destinationKind, assetID: request.destinationAssetID,
                pageID: request.destinationPageID)
    }

    func failPlanDiagnosticNavigation(_ request: PlanDiagnosticNavigationRequest,
                                      in editor: ModelEditorSession? = nil) {
        guard pendingPlanDiagnosticNavigation?.id == request.id else { return }
        pendingPlanDiagnosticNavigation = nil
        let owner = editor ?? editorSession(request.planEditorID)
        owner?.error = L10n.text("This diagnostic target is no longer current. Refresh it and try again.")
    }

    func finishPlanDiagnosticNavigation(_ request: PlanDiagnosticNavigationRequest) {
        guard pendingPlanDiagnosticNavigation?.id == request.id else { return }
        pendingPlanDiagnosticNavigation = nil
    }

    private func waitForPlanComputeToFinish(requestID: UUID) async -> Bool {
        for await (isRunning, request) in Publishers.CombineLatest(
            $isRunningPlanCompute, $pendingPlanDiagnosticNavigation).values {
            guard request?.id == requestID else { return false }
            if !isRunning { return true }
        }
        return false
    }

    /// Races file verification against the published request identity. If the
    /// request is replaced or cleared, cancelling the structured hash task
    /// propagates into each bounded FileHandle worker immediately.
    private func matchesWhilePlanDiagnosticNavigationIsCurrent(
        _ target: PlanDiagnosticTarget, requestID: UUID
    ) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await PlanDiagnosticFileFingerprint.matches(target)
            }
            group.addTask { [weak self] in
                guard let self else { return false }
                await self.waitForPlanDiagnosticNavigationInvalidation(requestID: requestID)
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
    }

    private func waitForPlanDiagnosticNavigationInvalidation(requestID: UUID) async {
        for await request in $pendingPlanDiagnosticNavigation.values {
            if Task.isCancelled || request?.id != requestID { return }
        }
    }

    private func planDiagnosticDestination(_ target: PlanDiagnosticTarget,
                                           projectSessionID expectedProjectSessionID: UUID,
                                           planEditorID: UUID,
                                           planContextID: String) -> PlanDiagnosticNavigationDestination? {
        guard projectSessionID == expectedProjectSessionID,
              let document,
              let documentURL = document.url,
              let projectRevision = document.sourceRevision else { return nil }
        let planAssets = assets.filter {
            $0.section == .plans && $0.isModelFile
                && Self.samePlanDiagnosticPath($0.id, target.planPath)
        }
        guard Self.samePlanDiagnosticPath(documentURL.path, target.projectPath),
              Self.samePlanDiagnosticRevision(projectRevision, target.projectRevision),
              planAssets.count == 1,
              let planSession = editorSession(planEditorID) else { return nil }
        let planAsset = planAssets[0]
        guard planSession.isSourcePlan,
              planSession.modelAssetID == planAsset.id,
              Self.samePlanDiagnosticRevision(planSession.sourceFileRevision, target.planRevision),
              let planContext = planSession.currentPlanComputeContext(),
              planContext.id == planContextID,
              planContext.asset.id == planAsset.id else { return nil }

        let targetPath = Self.planDiagnosticCanonicalPath(target.assetPath)
        guard !targetPath.isEmpty, !target.assetRevision.isEmpty else { return nil }

        switch target.kind {
        case "plan":
            guard target.featureID == nil, target.featureName == nil,
                  Self.samePlanDiagnosticPath(target.assetPath, planAsset.id),
                  Self.samePlanDiagnosticRevision(target.assetRevision, target.planRevision) else { return nil }
            return .init(kind: .plan, assetID: planAsset.id, pageID: "Summary")
        case "geometry", "flowArea":
            guard let association = PlanDiagnosticNavigationIdentity.uniqueAssociation(
                named: planAsset.name, group: "PlanAssociations",
                in: document.associationRows(group: "PlanAssociations")) else { return nil }
            guard let geometryName = association.fields["Geometry"], !geometryName.isEmpty,
                  let geometry = uniqueAssociatedAsset(named: geometryName, section: .geometries),
                  Self.samePlanDiagnosticPath(targetPath, geometry.id) else { return nil }
            if target.kind == "geometry" {
                guard target.featureID == nil, target.featureName == nil else { return nil }
                return .init(kind: .geometry, assetID: geometry.id, pageID: "Summary")
            }
            guard target.featureName?.isEmpty == false,
                  Self.featureIndex(target.featureID, prefix: "flow-area-row:") != nil else { return nil }
            return .init(kind: .geometry, assetID: geometry.id, pageID: "Mesh")
        case "boundaryCondition", "boundaryConditionLine":
            guard let association = PlanDiagnosticNavigationIdentity.uniqueAssociation(
                named: planAsset.name, group: "PlanAssociations",
                in: document.associationRows(group: "PlanAssociations")) else { return nil }
            guard let boundaryName = association.fields["BoundaryCondition"], !boundaryName.isEmpty,
                  let boundary = uniqueAssociatedAsset(named: boundaryName, section: .boundaryConditions),
                  Self.samePlanDiagnosticPath(targetPath, boundary.id) else { return nil }
            if target.kind == "boundaryCondition" {
                guard target.featureID == nil, target.featureName == nil else { return nil }
                return .init(kind: .boundaryCondition, assetID: boundary.id, pageID: "General Options")
            }
            guard target.featureName?.isEmpty == false,
                  Self.featureIndex(target.featureID, prefix: "boundary-line-row:") != nil else { return nil }
            return .init(kind: .boundaryCondition, assetID: boundary.id, pageID: "Boundary Lines")
        default:
            return nil
        }
    }

    private func uniqueAssociatedAsset(named name: String, section: ProjectSection) -> ProjectAsset? {
        PlanDiagnosticNavigationIdentity.uniqueAssociatedAsset(named: name, section: section, in: assets)
    }

    private static func featureIndex(_ token: String?, prefix: String) -> Int? {
        guard let token, token.hasPrefix(prefix) else { return nil }
        let suffix = String(token.dropFirst(prefix.count))
        guard let index = Int(suffix), index >= 0, String(index) == suffix else { return nil }
        return index
    }

    private static func samePlanDiagnosticPath(_ lhs: String, _ rhs: String) -> Bool {
        planDiagnosticCanonicalPath(lhs) == planDiagnosticCanonicalPath(rhs)
    }

    private static func planDiagnosticCanonicalPath(_ path: String) -> String {
        SourceFilePaths.canonical(URL(fileURLWithPath: path))
    }

    private static func samePlanDiagnosticRevision(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs, let rhs, !lhs.isEmpty, !rhs.isEmpty else { return false }
        return lhs.caseInsensitiveCompare(rhs) == .orderedSame
    }
}
