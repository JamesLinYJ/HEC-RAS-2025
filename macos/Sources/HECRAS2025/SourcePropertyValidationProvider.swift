import CryptoKit
import Foundation
import RASWorkspaceCore

struct SourcePropertyValidationRequest: Encodable, Sendable {
    let model: BackendModelProvider.ModelSaveRequest
    let requestID: String
    let editorID: String
    let loadRevision: Int
    let editRevision: Int
    let selectionRevision: Int
    let validationSource: String
    let fieldID: String
    let propertyName: String
    let text: String
    let selectedRowIDs: [String]
    let sourceStateFingerprint: String
    let parentDraftIdentity: String
}

struct SourcePropertyValidationMessage: Decodable, Sendable {
    let id: String
    let text: String
    let level: String

    var presentation: SharedVisualValidationMessage? {
        let severity: SharedVisualValidationLevel
        switch level {
        case "success": severity = .success
        case "warn": severity = .warn
        case "error": severity = .error
        case "typeError": severity = .typeError
        default: return nil
        }
        return SharedVisualValidationMessage(id: id, text: text, level: severity)
    }
}

struct SourcePropertyValidationResponse: Decodable, Sendable {
    let requestID: String
    let editorID: String
    let loadRevision: Int
    let editRevision: Int
    let selectionRevision: Int
    let validationSource: String
    let fieldID: String
    let propertyName: String
    let text: String
    let selectedRowIDs: [String]
    let sourceRevision: String
    let sourceStateFingerprint: String
    let parentDraftIdentity: String
    let tableSelections: [String: [String]]
    let planTimeWindowEdits: [PlanTimeWindowEdit]
    let messages: [SourcePropertyValidationMessage]

    func validated(for request: SourcePropertyValidationRequest) throws -> [SharedVisualValidationMessage] {
        guard requestID == request.requestID, editorID == request.editorID,
              loadRevision == request.loadRevision, editRevision == request.editRevision,
              selectionRevision == request.selectionRevision,
              validationSource == request.validationSource, fieldID == request.fieldID,
              propertyName == request.propertyName, text == request.text,
              selectedRowIDs == request.selectedRowIDs,
              sourceRevision == request.model.revision,
              sourceStateFingerprint == request.sourceStateFingerprint,
              parentDraftIdentity == request.parentDraftIdentity,
              tableSelections == request.model.tableSelections,
              planTimeWindowEdits == request.model.planTimeWindowEdits else {
            throw BackendServiceError(code: "sourceChanged",
                message: "The source property validation result no longer matches the current editor draft.")
        }
        let presentations = messages.compactMap(\.presentation)
        guard presentations.count == messages.count else {
            throw BackendServiceError(code: "invalidResponse",
                message: "The source property validator returned an unsupported message level.")
        }
        return presentations
    }
}

@MainActor
struct BackendSourcePropertyValidationProvider {
    let client: BackendProcessClient

    func validate(_ request: SourcePropertyValidationRequest) async throws -> [SharedVisualValidationMessage] {
        let route: String
        switch request.validationSource {
        case "LeveeModPropertiesDetailEditor": route = "model.sourceProperty.validate"
        case "ConceptualMeshControlPointEditor": route = "topology.regionProperty.validate"
        default:
            throw BackendServiceError(code: "unsupported", message: "This source property validator is unavailable.")
        }
        let response = try await client.request(route, parameters: request, as: SourcePropertyValidationResponse.self)
        return try response.validated(for: request)
    }

    static func fingerprint(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func fingerprint<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return fingerprint(try encoder.encode(value))
    }

    private static func fingerprint(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
