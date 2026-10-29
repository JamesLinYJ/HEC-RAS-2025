import Foundation
import CryptoKit
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

@MainActor
private final class PlanExportMockTransport: PlanExportTransport {
    var folders: [String] = []
    var inspection: PlanExportBackendInspection?
    var uploadState = "completed"
    var accessFolderCalls = 0
    var inspectCalls = 0
    var exportRequests: [PlanExportBackendDuplexRequest] = []
    var uploadRequests: [PlanModelUploadBackendRequest] = []
    var cancelCalls = 0
    var exportProgress = BackendProgressUpdate(fraction: 0.5, message: "ZIP committed")
    var uploadProgress = BackendProgressUpdate(fraction: 0.75, message: "Upload stage")

    func accessFolders(_ request: PlanExportBackendRequest) async throws -> [String] {
        accessFolderCalls += 1
        return folders
    }

    func inspect(_ request: PlanExportBackendRequest) async throws -> PlanExportBackendInspection {
        inspectCalls += 1
        return inspection ?? PlanExportBackendInspection(revision: "source-revision-1", canExecute: true,
            validationMessage: nil, plans: [PlanExportBackendChoice(id: request.planPath ?? "", title: "Selected Plan")],
            selectedPlanPath: request.planPath, suggestedOutputPath: nil, sourceFiles: [], requiredConnections: [])
    }

    func export(_ request: PlanExportBackendDuplexRequest,
                progress: @escaping @MainActor (BackendProgressUpdate) -> Void) async throws -> PlanExportBackendDuplexResult {
        exportRequests.append(request)
        progress(exportProgress)
        let source = request.export
        let output = try outputURL(source.outputPath)
        if source.zip {
            try Data("PK\u{03}\u{04} mock committed archive".utf8).write(to: output)
        } else {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        }
        let contents = source.zip ? try Data(contentsOf: output) : Data()
        let hash = source.zip ? Self.sha256(contents) : nil
        let receipt = PlanExportBackendReceipt(outputPath: output.path, zip: source.zip,
            projectFilename: "Mock.ras", fileCount: 3, projectPath: source.projectPath,
            planPath: source.planPath ?? "", projectSessionID: source.projectSessionID ?? "",
            sourceRevision: source.revision ?? "", coreLayerIdentityToken: source.coreLayerContext?.identityToken,
            outputSHA256: hash, outputBytes: Int64(contents.count), receiptID: "mock-receipt-" + UUID().uuidString)
        return PlanExportBackendDuplexResult(state: "completed", receipt: receipt)
    }

    func upload(_ request: PlanModelUploadBackendRequest,
                progress: @escaping @MainActor (BackendProgressUpdate) -> Void) async throws -> PlanModelUploadBackendResult {
        uploadRequests.append(request)
        progress(uploadProgress)
        return PlanModelUploadBackendResult(state: uploadState, modelID: request.modelID,
            outputPath: request.receipt.outputPath, receiptID: request.receiptID)
    }

    func cancelActiveOperation() { cancelCalls += 1 }

    private func outputURL(_ path: String?) throws -> URL {
        guard let path, !path.isEmpty else { throw BackendServiceError(code: "missingOutput", message: "Missing output path") }
        return URL(fileURLWithPath: path)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private enum PlanUploadTestHash {
    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

struct PlanModelUploadProviderTests {
    @Test @MainActor
    func missingCredentialsAndDirectoryModeNeverOfferOrCallUpload() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let mock = PlanExportMockTransport(), provider = BackendPlanExportProvider(transport: mock)
        provider.setProject(fixture.project, sessionID: fixture.sessionID)
        provider.coreLayerContext = { fixture.coreContext }
        let zipped = fixture.request(zip: true, upload: false)
        let missingCredentials = try await provider.prepare(zipped)
        #expect(!missingCredentials.uploadAvailable)
        let draft = ModelEditorSession()
        draft.startDraft(EditorSnapshot(fields: ["PlanExporterControl/ExportTypeIndex": "0",
            "PlanExporterControl/EnableUpload": "true"], rows: [:], samples: [:], canEdit: true, images: [:]))
        let state = DataToolSession()
        let context = DataToolContext(projectSessionID: fixture.sessionID, mapID: UUID(), assetID: fixture.planPath, extent: nil)
        let unsafeRequest = state.request(kind: .planExport, editor: draft, context: context)
        #expect(unsafeRequest.fields["PlanExporterControl/EnableUpload"] == "false")

        let deniedProvider = BackendPlanExportProvider(transport: mock)
        deniedProvider.setProject(fixture.project, sessionID: fixture.sessionID)
        deniedProvider.coreLayerContext = { fixture.coreContext }
        let explicitUpload = fixture.request(zip: true, upload: true)
        _ = try await deniedProvider.prepare(explicitUpload)
        do {
            try await deniedProvider.execute(explicitUpload)
            Issue.record("A direct upload request without saved credentials must be rejected before export.")
        } catch let error as BackendServiceError {
            #expect(error.code == "credentialsUnavailable")
        }
        #expect(mock.exportRequests.isEmpty && mock.uploadRequests.isEmpty)
        try await provider.execute(zipped)
        #expect(mock.exportRequests.count == 1 && mock.uploadRequests.isEmpty)
        #expect(provider.lastCommittedReceipt?.zip == true)

        let directoryProvider = BackendPlanExportProvider(transport: mock)
        directoryProvider.setProject(fixture.project, sessionID: fixture.sessionID)
        directoryProvider.coreLayerContext = { fixture.coreContext }
        let directory = fixture.request(zip: false, upload: true)
        directoryProvider.uploadCredentials = { WorkspaceS3Credentials(accessKey: "access", secretKey: "secret") }
        let directoryPresentation = try await directoryProvider.prepare(directory)
        #expect(!directoryPresentation.uploadAvailable)
        let directoryDraft = ModelEditorSession()
        directoryDraft.startDraft(EditorSnapshot(fields: ["PlanExporterControl/ExportTypeIndex": "1",
            "PlanExporterControl/EnableUpload": "true"], rows: [:], samples: [:], canEdit: true, images: [:]))
        let directoryRequest = state.request(kind: .planExport, editor: directoryDraft, context: context)
        #expect(directoryRequest.fields["PlanExporterControl/EnableUpload"] == "false")
        try await directoryProvider.execute(directory)
        #expect(mock.exportRequests.last?.uploadAfterExport == false)
        #expect(mock.uploadRequests.isEmpty)
        #expect(!BackendPlanExportProvider.canOfferUpload(zip: false,
            credentials: WorkspaceS3Credentials(accessKey: "access", secretKey: "secret")))
        #expect(!BackendPlanExportProvider.canOfferUpload(zip: true,
            credentials: WorkspaceS3Credentials(accessKey: " ", secretKey: "secret")))
    }

    @Test @MainActor
    func zipThenUploadEmitsBothStagesAndCancellationKeepsCommittedReceipt() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let mock = PlanExportMockTransport(), provider = BackendPlanExportProvider(transport: mock)
        provider.setProject(fixture.project, sessionID: fixture.sessionID)
        provider.coreLayerContext = { fixture.coreContext }
        provider.uploadCredentials = { WorkspaceS3Credentials(accessKey: "offline-access", secretKey: "offline-secret") }
        provider.applicationUID = { "offline-owner" }
        let request = fixture.request(zip: true, upload: true)
        let presentation = try await provider.prepare(request)
        #expect(presentation.uploadAvailable)
        var events: [String] = []
        try await provider.execute(request) { events.append($0.message) }
        #expect(mock.exportRequests.count == 1 && mock.exportRequests[0].uploadAfterExport)
        #expect(mock.uploadRequests.count == 1)
        #expect(mock.uploadRequests[0].modelID == "offline-model-42")
        #expect(mock.uploadRequests[0].owner == "offline-owner")
        #expect(mock.uploadRequests[0].s3AccessKey == "offline-access")
        #expect(mock.uploadRequests[0].s3SecretKey == "offline-secret")
        #expect(mock.uploadRequests[0].projectPath == fixture.coreContext.projectPath)
        #expect(mock.uploadRequests[0].planPath == fixture.planPath)
        #expect(mock.uploadRequests[0].coreLayerContext == fixture.coreContext)
        #expect(mock.uploadRequests[0].receiptID == provider.lastCommittedReceipt?.receiptID)
        #expect(events == ["ZIP committed", "Upload stage"])
        let uploadedReceipt = try #require(provider.lastCommittedReceipt)
        #expect(FileManager.default.fileExists(atPath: uploadedReceipt.outputPath))

        mock.uploadState = "cancelled"
        let retryProvider = BackendPlanExportProvider(transport: mock)
        retryProvider.setProject(fixture.project, sessionID: fixture.sessionID)
        retryProvider.coreLayerContext = { fixture.coreContext }
        retryProvider.uploadCredentials = { WorkspaceS3Credentials(accessKey: "offline-access", secretKey: "offline-secret") }
        retryProvider.applicationUID = { "offline-owner" }
        _ = try await retryProvider.prepare(request)
        do {
            try await retryProvider.execute(request)
            Issue.record("A cancelled upload must return cancellation while retaining the committed ZIP receipt.")
        } catch is CancellationError { }
        let receipt = try #require(retryProvider.lastCommittedReceipt)
        #expect(FileManager.default.fileExists(atPath: receipt.outputPath))
        #expect(PlanUploadTestHash.sha256(try Data(contentsOf: URL(fileURLWithPath: receipt.outputPath))) == receipt.outputSHA256)
    }

    @MainActor
    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("plan-upload-provider-" + UUID().uuidString,
            isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let projectURL = root.appendingPathComponent("Mock.ras")
        let project = try ProjectDocument(name: "Mock", units: "SI")
        try project.save(to: projectURL)
        let sessionID = UUID()
        let coreContext = CoreLayerRequestContext.capture(projectSessionID: sessionID,
            projectURL: projectURL, projectRevision: project.sourceRevision, references: [])
        let planPath = root.appendingPathComponent("Plans/Selected.h5").path
        return Fixture(root: root, projectURL: projectURL, project: project,
            sessionID: sessionID, planPath: planPath, coreContext: coreContext)
    }

    @MainActor
    private struct Fixture {
        let root: URL
        let projectURL: URL
        let project: ProjectDocument
        let sessionID: UUID
        let planPath: String
        let coreContext: CoreLayerRequestContext

        func request(zip: Bool, upload: Bool) -> ToolRequest {
            let output = root.appendingPathComponent(zip ? "Mock.zip" : "Mock.export", isDirectory: !zip)
            return ToolRequest(kind: ToolKind.planExport.id,
                fields: ["PlanExporterControl/Plan": planPath,
                    "PlanExporterControl/ExportTypeIndex": zip ? "0" : "1",
                    "PlanExporterControl/EnableUpload": upload ? "true" : "false",
                    "PlanExporterControl/ModelId": "offline-model-42"],
                inputFiles: [], destination: output, images: [:],
                context: DataToolContext(projectSessionID: sessionID, mapID: UUID(), assetID: planPath, extent: nil))
        }
    }
}
