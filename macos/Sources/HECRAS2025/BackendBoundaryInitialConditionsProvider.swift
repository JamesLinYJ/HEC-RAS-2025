import CryptoKit
import Foundation
import RASWorkspaceCore

@MainActor
final class BackendBoundaryInitialConditionsProvider: BoundaryInitialConditionsProvider {
    private let client: BackendProcessClient

    init(client: BackendProcessClient? = nil) {
        self.client = client ?? BackendProcessClient(executableURL: Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/Backend/HECRASBackend"))
    }

    func inspect(_ request: BoundaryInitialConditionsInspectionRequest) async throws -> BoundaryInitialConditionsInspection {
        try validateModel(request.model, projectRevision: request.projectRevision)
        let before = try Self.fileRevision(request.resultPath)
        let response = try await client.request("boundary.initialConditions.inspect", parameters: request,
            as: BoundaryInitialConditionsInspection.self)
        let after = try Self.fileRevision(request.resultPath)
        guard before == after else { throw Self.sourceChanged }
        try validate(response, against: request, resultRevision: before)
        return response
    }

    func attach(_ request: BoundaryInitialConditionsAttachRequest) async throws -> BoundaryInitialConditionsReceipt {
        try validateModel(request.model, projectRevision: request.projectRevision)
        guard !request.operationID.isEmpty, !request.resultRevision.isEmpty else {
            throw Self.invalidRequest
        }
        try validateProjectFingerprint(request.projectXmlFingerprint, model: request.model)
        let receipt = try await client.request("boundary.initialConditions.attach", parameters: request,
            as: BoundaryInitialConditionsReceipt.self)
        try validate(receipt, against: request)
        return receipt
    }

    func status(_ request: BoundaryInitialConditionsAttachRequest) async throws -> BoundaryInitialConditionsOperationStatus {
        try validateModel(request.model, projectRevision: request.projectRevision)
        guard !request.operationID.isEmpty else { throw Self.invalidRequest }
        try validateProjectFingerprint(request.projectXmlFingerprint, model: request.model)
        let status = try await client.request("boundary.initialConditions.status", parameters: request,
            as: BoundaryInitialConditionsOperationStatus.self)
        if let receipt = status.receipt {
            try validate(receipt, against: request)
            guard status.state == .committed else { throw Self.protocolFailure }
        } else if status.state == .committed {
            throw Self.protocolFailure
        }
        return status
    }

    private func validateModel(_ model: BackendModelProvider.ModelSaveRequest, projectRevision: String) throws {
        guard model.kind == ModelEditorKind.boundaryCondition.rawValue,
              !model.assetPath.isEmpty, !model.revision.isEmpty,
              let projectPath = model.projectPath, !projectPath.isEmpty,
              let projectXML = model.projectXml, !projectXML.isEmpty,
              !projectRevision.isEmpty else { throw Self.invalidRequest }
    }

    private func validateProjectFingerprint(_ fingerprint: String?, model: BackendModelProvider.ModelSaveRequest) throws {
        guard let fingerprint, let projectXML = model.projectXml,
              Self.sameDigest(fingerprint, Self.digest(Data(projectXML.utf8))) else { throw Self.invalidRequest }
    }

    private func validate(_ response: BoundaryInitialConditionsInspection,
                          against request: BoundaryInitialConditionsInspectionRequest,
                          resultRevision: String) throws {
        guard Self.samePath(response.assetPath, request.model.assetPath),
              Self.sameDigest(response.assetRevision, request.model.revision),
              Self.samePath(response.projectPath, request.model.projectPath),
              Self.sameDigest(response.projectRevision, request.projectRevision),
              let projectXML = request.model.projectXml,
              Self.sameDigest(response.projectXmlFingerprint, Self.digest(Data(projectXML.utf8))),
              Self.samePath(response.resultPath, request.resultPath),
              response.resultRevision.map({ Self.sameDigest($0, resultRevision) }) ?? !response.canAttach,
              response.timestamp == (request.timestamp ?? ""),
              response.numberCulture == request.numberCulture else { throw Self.protocolFailure }
        if response.canAttach, response.resultRevision == nil { throw Self.protocolFailure }
    }

    private func validate(_ receipt: BoundaryInitialConditionsReceipt,
                          against request: BoundaryInitialConditionsAttachRequest) throws {
        guard receipt.operationID == request.operationID,
              Self.samePath(receipt.assetPath, request.model.assetPath),
              Self.samePath(receipt.projectPath, request.model.projectPath),
              Self.samePath(receipt.resultPath, request.resultPath),
              Self.sameDigest(receipt.resultRevision, request.resultRevision),
              Self.sameDigest(receipt.projectRevision, Self.digest(Data(receipt.projectXml.utf8))),
              !receipt.connectionName.isEmpty,
              (receipt.timestamp ?? "") == (request.timestamp ?? ""),
              receipt.model.revision != request.model.revision else { throw Self.protocolFailure }
    }

    private static let invalidRequest = BackendServiceError(code: "invalidInput",
        message: "The initial-conditions request no longer matches the captured boundary condition and project.")
    private static let sourceChanged = BackendServiceError(code: "sourceChanged",
        message: "A source file changed while initial conditions were being attached.")
    private static let protocolFailure = BackendServiceError(code: "protocolFailure",
        message: "The initial-conditions service returned a response for a different source operation.")

    private static func samePath(_ left: String?, _ right: String?) -> Bool {
        guard let left, let right else { return left == nil && right == nil }
        return SourceFilePaths.canonical(URL(fileURLWithPath: left))
            == SourceFilePaths.canonical(URL(fileURLWithPath: right))
    }

    private static func sameDigest(_ left: String, _ right: String) -> Bool {
        left.caseInsensitiveCompare(right) == .orderedSame
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02X", $0) }.joined()
    }

    private static func fileRevision(_ path: String) throws -> String {
        let url = URL(fileURLWithPath: path)
        guard url.isFileURL, FileManager.default.fileExists(atPath: url.path) else {
            throw BackendServiceError(code: "invalidInput", message: "Choose an existing RAS result file.")
        }
        return digest(try Data(contentsOf: url, options: [.mappedIfSafe]))
    }
}
