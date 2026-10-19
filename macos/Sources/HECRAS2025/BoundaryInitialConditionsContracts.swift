import Foundation
import RASWorkspaceCore

/// A source-exact, immutable editor/project snapshot for one attach attempt.
/// The project XML submitted to the backend may include the Store's description
/// draft; capturedDocumentXML remains the live ProjectDocument baseline used by
/// the commit acknowledgement to preserve newer project edits.
struct BoundaryInitialConditionsCapture: Sendable {
    let id: String
    let projectSessionID: UUID
    let editorID: UUID
    let loadRevision: Int
    let editRevision: Int
    let asset: ProjectAsset
    let projectPath: String
    let projectRevision: String
    let capturedDocumentXML: String
    let submittedProjectXML: String
    let projectXmlFingerprint: String
    let descriptionDraft: String
    let model: BackendModelProvider.ModelSaveRequest
    let editorFields: [String: String]
    let editorRows: [String: [EditorRow]]
    let editorImages: [String: [ImageAttachment]]
    let editorSamples: [String: [ChartSample]]
    let editorSourceState: String?
}

struct BoundaryInitialConditionsInspectionRequest: Encodable, Sendable {
    let model: BackendModelProvider.ModelSaveRequest
    let projectRevision: String
    let resultPath: String
    let timestamp: String?
    let numberCulture: String?
}

struct BoundaryInitialConditionsInspection: Codable, Sendable, Equatable {
    let assetPath: String
    let assetRevision: String
    let projectPath: String
    let projectRevision: String
    let projectXmlFingerprint: String
    let resultPath: String
    let resultRevision: String?
    /// Kept as the original source text. It is never decoded as a Swift Date.
    let timestamp: String
    let numberCulture: String?
    let canAttach: Bool
    let errorMessage: String?
}

struct BoundaryInitialConditionsAttachRequest: Encodable, Sendable {
    let model: BackendModelProvider.ModelSaveRequest
    let projectRevision: String
    let projectXmlFingerprint: String?
    let resultPath: String
    let resultRevision: String
    let operationID: String
    let timestamp: String?
    let numberCulture: String?
}

struct BoundaryInitialConditionsReceipt: Decodable, Sendable {
    let operationID: String
    let assetPath: String
    let projectPath: String
    let resultPath: String
    let resultRevision: String
    let projectRevision: String
    /// Exact saved UTF-8 project XML returned by the transaction journal.
    let projectXml: String
    let connectionName: String
    let timestamp: String?
    let model: BackendModelProvider.ModelSnapshot
    let alreadyCommitted: Bool
}

enum BoundaryInitialConditionsOperationState: String, Decodable, Sendable {
    case notFound
    case prepared
    case committed
    case rolledBack
    case conflict
}

struct BoundaryInitialConditionsOperationStatus: Decodable, Sendable {
    let state: BoundaryInitialConditionsOperationState
    let receipt: BoundaryInitialConditionsReceipt?
    let errorMessage: String?
}

@MainActor
protocol BoundaryInitialConditionsProvider {
    func inspect(_ request: BoundaryInitialConditionsInspectionRequest) async throws -> BoundaryInitialConditionsInspection
    func attach(_ request: BoundaryInitialConditionsAttachRequest) async throws -> BoundaryInitialConditionsReceipt
    func status(_ request: BoundaryInitialConditionsAttachRequest) async throws -> BoundaryInitialConditionsOperationStatus
}

extension BoundaryInitialConditionsProvider {
    func status(_ request: BoundaryInitialConditionsAttachRequest) async throws -> BoundaryInitialConditionsOperationStatus {
        throw CocoaError(.featureUnsupported)
    }
}

