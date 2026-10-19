import Foundation
import RASWorkspaceCore

private struct TestingUtilityCredentialPayload: Encodable, Sendable {
    let baseUrl: String
    let s3Key: String?
    let s3Secret: String?
}

private struct TestingWorkspaceRequest: Encodable, Sendable {
    let credentials: TestingUtilityCredentialPayload
}

private struct TestingWorkspaceResponse: Decodable, Sendable {
    let objects: [TestingServerObject]
    let commits: [TestingCommit]
    let status: String
    let log: [String]
    let points: [TestingPoint]
    let canEditPoints: Bool
    let pointOwnerID: String?
}

private struct TestingServerObject: Decodable, Sendable {
    let id: String
    let name: String
    let folder: String
    let kind: String
    let version: String
    let publicationDateUnixMilliseconds: Int64?
    let description: String
    let poiCount: Int?
}

private struct TestingCommit: Decodable, Sendable {
    let id: String
    let displayID: String
    let message: String
}

private struct TestingPoint: Codable, Sendable {
    let serverID: Int?
    let name: String
    let x: Double
    let y: Double
}

private struct TestingActionRequest: Encodable, Sendable {
    let credentials: TestingUtilityCredentialPayload
    let action: String
    let id: String
    var name: String? = nil
    var folder: String? = nil
    var text: String? = nil
    var points: [TestingPoint]? = nil
    var commit: String? = nil
    var tag: String? = nil
    var iterations = 1
}

private struct TestingActionResponse: Decodable, Sendable {
    let snapshot: TestingWorkspaceResponse
    let projectURL: String?
}

private struct TestingPoiImportRequest: Encodable, Sendable { let sourcePath: String }

private struct TestingUploadPrepareRequest: Encodable, Sendable {
    let credentials: TestingUtilityCredentialPayload
    let kind: String
    let sourcePath: String?
    let geometryID: String?
}

private struct TestingUploadPrepareResponse: Decodable, Sendable {
    let sourcePath: String?
    let suggestedName: String
    let folder: String
    let description: String
    let plans: [TestingPlan]
    let selectedPlanIDs: [String]
    let geometries: [TestingGeometry]
    let selectedGeometryID: String?
    let existingNames: [String]
    let pointEditor: TestingPointEditor?
    let sourceGeometryValid: Bool
    let projectName: String
    let commits: [TestingCommit]
}

private struct TestingPlan: Decodable, Sendable {
    let id: String
    let name: String
    let geometry: String?
    let boundaryCondition: String?
}

private struct TestingGeometry: Decodable, Sendable { let id: String; let title: String }
private struct TestingPointEditor: Decodable, Sendable { let points: [TestingPoint] }

private struct TestingUploadExecuteRequest: Encodable, Sendable {
    let credentials: TestingUtilityCredentialPayload
    let kind: String
    let sourcePath: String?
    let geometryID: String?
    let serverObjectID: String?
    let name: String
    let folder: String
    let description: String
    let planIDs: [String]
    let points: [TestingPoint]
    let queueRunAfterUpload: Bool
    let runCommit: String?
    let runTag: String
    let runIterations: Int
}

private struct TestingUploadResult: Decodable, Sendable {
    let message: String
    let serverObjectID: String?
    let runQueued: Bool
    let cancelled: Bool
    let uploadCompleted: Bool
    let continuationError: String?
}

private struct TestingUploadControl: Encodable, Sendable { let type: String }

/// Routes the native Testing Utility workspace and uploader into the retained
/// Testing.Core services hosted by the bundled backend.
@MainActor
final class BackendTestingProvider: TestingProvider, TestingUploadProvider {
    static let sourceDefaultUtilityURL = "https://rastesting-api.hecdev.net"
    static let utilityURLDefaultsKey = "Ras_Interface_WinUI_AppData_RasApplicationData_Instance_DevAppData_TestingUtilityUrl"

    private let client: BackendProcessClient
    private let utilityBaseURL: @MainActor () -> String
    private let credentialsStore: any WorkspaceS3CredentialStoring
    private var activeUpload: BackendDuplexOperation<TestingUploadControl,
        BackendProgressUpdate, TestingUploadResult>?

    init(client: BackendProcessClient? = nil,
         utilityBaseURL: @escaping @MainActor () -> String = {
             UserDefaults.standard.string(forKey: BackendTestingProvider.utilityURLDefaultsKey)
                 ?? BackendTestingProvider.sourceDefaultUtilityURL
         },
         credentials: any WorkspaceS3CredentialStoring = WorkspaceS3KeychainStore.shared) {
        self.client = client ?? BackendProcessClient(executableURL: Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/Backend/HECRASBackend"))
        self.credentialsStore = credentials
        self.utilityBaseURL = utilityBaseURL
    }

    func load(projectURL: URL?) async throws -> TestingSnapshot {
        _ = projectURL
        let credentials = credentialPayload(includeS3: false)
        return try await sanitized(using: credentials) {
            let response: TestingWorkspaceResponse = try await client.request("testing.workspace.load",
                parameters: TestingWorkspaceRequest(credentials: credentials))
            return try Self.snapshot(response)
        }
    }

    func perform(_ action: TestingAction) async throws -> TestingResult {
        let mapping = try Self.request(for: action)
        let credentials = credentialPayload(includeS3: mapping.requiresS3)
        var request = TestingActionRequest(credentials: credentials, action: mapping.action, id: mapping.id)
        request.name = mapping.name; request.folder = mapping.folder; request.text = mapping.text
        request.points = mapping.points; request.commit = mapping.commit; request.tag = mapping.tag
        request.iterations = mapping.iterations
        return try await sanitized(using: credentials) {
            let response: TestingActionResponse = try await client.request("testing.action", parameters: request)
            return TestingResult(snapshot: try Self.snapshot(response.snapshot),
                projectURL: response.projectURL.map { URL(fileURLWithPath: $0) })
        }
    }

    func importPoints(_ shapefile: URL) async throws -> [InterestPoint] {
        guard shapefile.isFileURL else { throw BackendServiceError(code: "invalidInput", message: "Choose a local POI shapefile.") }
        let request = TestingPoiImportRequest(sourcePath: shapefile.path)
        let points: [TestingPoint] = try await client.request("testing.poi.import", parameters: request)
        return points.map(Self.point)
    }

    func prepare(sourceURL: URL?, kind: ToolKind, geometryID: String?) async throws -> TestingUploadSnapshot {
        let request = TestingUploadPrepareRequest(credentials: credentialPayload(includeS3: false),
            kind: Self.kindName(kind), sourcePath: sourceURL?.path, geometryID: geometryID)
        let response: TestingUploadPrepareResponse = try await sanitized(using: request.credentials) {
            try await client.request("testing.upload.prepare", parameters: request)
        }
        let localPoints = response.pointEditor.map { editor in
            TestingSnapshot(objects: [], commits: [], points: editor.points.map(Self.point), canEditPoints: true,
                vectors: [], status: "", log: [])
        }
        return TestingUploadSnapshot(sourceURL: response.sourcePath.map { URL(fileURLWithPath: $0) },
            suggestedName: response.suggestedName, folder: response.folder, description: response.description,
            plans: response.plans.map { TestingPlanChoice(id: $0.id, name: $0.name,
                geometry: $0.geometry, boundaryCondition: $0.boundaryCondition) },
            selectedPlanIDs: Set(response.selectedPlanIDs),
            geometries: response.geometries.map { EditorChoice(id: $0.id, title: $0.title, titleIsUserData: true) },
            selectedGeometryID: response.selectedGeometryID, serverObjectID: nil,
            existingNames: Set(response.existingNames), pointEditor: localPoints,
            sourceGeometryValid: response.sourceGeometryValid, projectName: response.projectName,
            commits: response.commits.map(Self.choice))
    }

    func upload(_ request: TestingUploadRequest,
                progress: @escaping @MainActor (Double?, String) -> Void) async throws -> TestingUploadOutcome {
        let needsS3 = request.kind == .testingProjectUpload && !Self.isPointsOnly(request)
        let credentials = credentialPayload(includeS3: needsS3)
        let payload = TestingUploadExecuteRequest(credentials: credentials, kind: Self.kindName(request.kind),
            sourcePath: request.sourceURL?.path, geometryID: request.geometryID,
            serverObjectID: request.serverObjectID, name: request.name, folder: request.folder,
            description: request.description, planIDs: request.planIDs,
            points: request.points.map { TestingPoint(serverID: $0.serverID, name: $0.name, x: $0.x, y: $0.y) },
            queueRunAfterUpload: request.queueRunAfterUpload, runCommit: request.runCommit,
            runTag: request.runTag, runIterations: request.runIterations)
        let result: TestingUploadResult = try await sanitized(using: credentials) {
            if needsS3 {
                let operation = try client.startDuplex("testing.upload.execute", parameters: payload,
                    control: TestingUploadControl.self, event: BackendProgressUpdate.self,
                    as: TestingUploadResult.self)
                activeUpload = operation
                do {
                    for try await update in operation.events {
                        if Task.isCancelled {
                            _ = operation.requestSourceCancellation()
                            throw CancellationError()
                        }
                        progress(update.fraction.map { $0 * 100 },
                            self.redact(update.message ?? update.taskName, using: credentials) ?? "")
                    }
                    let result = try await operation.value()
                    activeUpload = nil
                    return result
                } catch {
                    activeUpload = nil
                    throw error
                }
            }
            return try await client.request("testing.upload.execute", parameters: payload, progress: { update in
                Task { @MainActor in
                    progress(update.fraction.map { $0 * 100 },
                        self.redact(update.message ?? update.taskName, using: credentials) ?? "")
                }
            })
        }
        return TestingUploadOutcome(message: redact(result.message, using: credentials) ?? "Upload completed.",
            serverObjectID: result.serverObjectID,
            runQueued: result.runQueued, cancelled: result.cancelled, uploadCompleted: result.uploadCompleted,
            continuationError: redact(result.continuationError, using: credentials))
    }

    func cancelUpload() {
        guard let operation = activeUpload else { return }
        if !operation.requestSourceCancellation() { operation.cancel() }
    }

    private func credentialPayload(includeS3: Bool) -> TestingUtilityCredentialPayload {
        let saved = includeS3 ? credentialsStore.load() : nil
        return TestingUtilityCredentialPayload(
            baseUrl: utilityBaseURL().trimmingCharacters(in: .whitespacesAndNewlines),
            s3Key: saved?.accessKey, s3Secret: saved?.secretKey)
    }

    private func sanitized<T>(using credentials: TestingUtilityCredentialPayload,
                              operation: () async throws -> T) async throws -> T {
        do { return try await operation() }
        catch is CancellationError { throw CancellationError() }
        catch {
            let message = redact(error.localizedDescription, using: credentials) ?? ""
            throw BackendServiceError(code: "testingUtilityFailure",
                message: message.isEmpty ? "The Testing Utility operation failed." : message)
        }
    }

    private func redact(_ message: String?, using credentials: TestingUtilityCredentialPayload) -> String? {
        guard var message else { return nil }
        for secret in [credentials.s3Key, credentials.s3Secret].compactMap({ $0 }).filter({ !$0.isEmpty }) {
            message = message.replacingOccurrences(of: secret, with: "[redacted]")
        }
        return message
    }

    private static func snapshot(_ response: TestingWorkspaceResponse) throws -> TestingSnapshot {
        let objects = try response.objects.map { object -> TestingObject in
            guard let kind = TestingObject.Kind(rawValue: object.kind) else {
                throw BackendServiceError(code: "protocolFailure", message: "The Testing Utility returned an unsupported object type.")
            }
            return TestingObject(id: object.id, name: object.name, folder: object.folder, kind: kind,
                version: object.version, publicationDate: object.publicationDateUnixMilliseconds.map {
                    Date(timeIntervalSince1970: Double($0) / 1_000)
                }, description: object.description, poiCount: object.poiCount)
        }
        return TestingSnapshot(objects: objects, commits: response.commits.map(choice), points: response.points.map(point),
            canEditPoints: response.canEditPoints, vectors: [], status: response.status, log: response.log,
            pointOwnerID: response.pointOwnerID)
    }

    private static func point(_ value: TestingPoint) -> InterestPoint {
        InterestPoint(id: UUID(), serverID: value.serverID, name: value.name, x: value.x, y: value.y)
    }

    private static func choice(_ value: TestingCommit) -> EditorChoice {
        var message = value.message.components(separatedBy: .newlines).first ?? ""
        if message.count > 60 { message = String(message.prefix(60)) + "…" }
        let title = [value.displayID, message].filter { !$0.isEmpty }.joined(separator: " ")
        return EditorChoice(id: value.id, title: title, titleIsUserData: true)
    }

    private static func kindName(_ kind: ToolKind) -> String {
        kind == .testingProjectUpload ? "project" : "geometry"
    }

    private static func isPointsOnly(_ request: TestingUploadRequest) -> Bool {
        request.kind == .testingProjectUpload && request.serverObjectID != nil && request.planIDs.isEmpty
    }

    private static func request(for action: TestingAction) throws -> ActionMapping {
        switch action {
        case .details(let id): ActionMapping(action: "details", id: id)
        case .open(let id): ActionMapping(action: "open", id: id, requiresS3: true)
        case .edit(let id): ActionMapping(action: "edit", id: id)
        case .rename(let id, let name): ActionMapping(action: "rename", id: id, name: name)
        case .move(let id, let folder): ActionMapping(action: "move", id: id, folder: folder)
        case .description(let id, let text): ActionMapping(action: "description", id: id, text: text)
        case .savePoints:
            throw BackendServiceError(code: "invalidState", message: "Select a testing project before saving points of interest.")
        case .reconcilePoints(let id, let points):
            ActionMapping(action: "savePoints", id: id, points: encode(points))
        case .queueRun(let id, let commit, let tag, let iterations):
            ActionMapping(action: "queueRun", id: id, commit: commit, tag: tag, iterations: iterations)
        }
    }

    private static func encode(_ points: [InterestPoint]) -> [TestingPoint] {
        points.map { TestingPoint(serverID: $0.serverID, name: $0.name, x: $0.x, y: $0.y) }
    }

    private struct ActionMapping {
        let action: String
        let id: String
        var name: String? = nil
        var folder: String? = nil
        var text: String? = nil
        var points: [TestingPoint]? = nil
        var commit: String? = nil
        var tag: String? = nil
        var iterations = 1
        var requiresS3 = false
    }
}
