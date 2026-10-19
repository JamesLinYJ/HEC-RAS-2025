import Foundation
import RASWorkspaceCore

@MainActor
extension BackendModelProvider {
    private struct DraftRequest: Encodable, Sendable {
        let plan: ModelSaveRequest
        let associatedGeometry: ModelSaveRequest?
        let associatedBoundaryCondition: ModelSaveRequest?
        let captureID: String
    }

    func inspect(_ asset: ProjectAsset, edits: EditorEdits,
                 associatedDrafts: PlanPrecomputeAssociatedDraftsCapture?) async throws -> PlanPrecomputeDraftResponse {
        guard asset.section == .plans else { throw CocoaError(.featureUnsupported) }
        guard let associatedDrafts else {
            let result = try await inspect(asset, edits: edits)
            return PlanPrecomputeDraftResponse(captureID: "", result: result)
        }
        guard let project, let projectURL = project.url,
              projectURL.standardizedFileURL.path ==
                URL(fileURLWithPath: associatedDrafts.projectPath).standardizedFileURL.path,
              project.editorXML == associatedDrafts.projectXML else {
            throw BackendServiceError(code: "sourceChanged",
                message: "The owning project changed while the Plan check was being prepared.")
        }

        let plan = try saveRequest(asset, changes: edits)
        guard plan.projectPath.map({ URL(fileURLWithPath: $0).standardizedFileURL.path }) ==
                Optional(projectURL.standardizedFileURL.path),
              plan.projectXml == associatedDrafts.projectXML else {
            throw BackendServiceError(code: "sourceChanged",
                message: "Reload the Plan and project before checking associated drafts.")
        }

        let geometry = try makeAssociatedRequest(associatedDrafts.geometry,
            expectedSection: .geometries, expectedKind: "Geometry",
            projectPath: projectURL.path, projectXML: associatedDrafts.projectXML)
        let boundary = try makeAssociatedRequest(associatedDrafts.boundaryCondition,
            expectedSection: .boundaryConditions, expectedKind: "Boundary Conditions",
            projectPath: projectURL.path, projectXML: associatedDrafts.projectXML)
        let request = DraftRequest(plan: plan, associatedGeometry: geometry,
            associatedBoundaryCondition: boundary, captureID: associatedDrafts.id)
        let response = try await client.request("model.precomputeDrafts", parameters: request,
            as: PlanPrecomputeDraftResponse.self)
        guard response.captureID == associatedDrafts.id else {
            throw BackendServiceError(code: "sourceChanged",
                message: "The Plan check returned for a different associated draft capture.")
        }
        return response
    }

    private func makeAssociatedRequest(_ capture: PlanPrecomputeAssociatedEditorCapture?,
        expectedSection: ProjectSection, expectedKind: String,
        projectPath: String, projectXML: String) throws -> ModelSaveRequest? {
        guard let capture else { return nil }
        guard capture.asset.section == expectedSection else {
            throw BackendServiceError(code: "sourceChanged",
                message: "An associated editor no longer matches the selected Plan model.")
        }
        let request = try saveRequest(capture.asset, changes: capture.edits)
        guard request.kind == expectedKind,
              request.projectPath.map({ URL(fileURLWithPath: $0).standardizedFileURL.path }) ==
                Optional(URL(fileURLWithPath: projectPath).standardizedFileURL.path),
              request.projectXml == projectXML else {
            throw BackendServiceError(code: "sourceChanged",
                message: "Reload the associated model and project before checking Plan readiness.")
        }
        return request
    }
}
