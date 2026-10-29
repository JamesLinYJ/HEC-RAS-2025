import Foundation
import RASWorkspaceCore

struct PlanExportPresentation: Sendable {
    let destination: URL?
    let sourceFiles: [URL]
    let requiredConnections: [String]
    let validationMessage: String?
}

struct PlanExportBackendRequest: Encodable, Equatable, Sendable {
    let projectPath: String
    let projectXml: String
    let planPath: String?
    var outputPath: String?
    let zip: Bool
    let clipRasters: Bool
    let resampleCellsize: Float?
    let externalConnections: String
    let replaceFile: Bool
    var revision: String? = nil
    var coreLayerContext: CoreLayerRequestContext? = nil
    let projectSessionID: String?
}

struct PlanExportBackendChoice: Decodable, Sendable {
    let id: String
    let title: String
}

struct PlanExportBackendInspection: Decodable, Sendable {
    let revision: String
    let canExecute: Bool
    let validationMessage: String?
    let plans: [PlanExportBackendChoice]
    let selectedPlanPath: String?
    let suggestedOutputPath: String?
    let sourceFiles: [String]
    let requiredConnections: [String]
}

struct PlanExportBackendReceipt: Codable, Sendable, Equatable {
    let outputPath: String
    let zip: Bool
    let projectFilename: String
    let fileCount: Int
    let projectPath: String
    let planPath: String
    let projectSessionID: String
    let sourceRevision: String
    let coreLayerIdentityToken: String?
    let outputSHA256: String?
    let outputBytes: Int64
    let receiptID: String
}

struct PlanExportBackendDuplexRequest: Encodable, Sendable {
    let export: PlanExportBackendRequest
    let uploadAfterExport: Bool
}

struct PlanExportBackendDuplexResult: Decodable, Sendable {
    let state: String
    let receipt: PlanExportBackendReceipt?
}

struct PlanExportBackendControl: Encodable, Sendable {
    let type = "cancel"
}

struct PlanModelUploadBackendRequest: Encodable, Sendable {
    let receipt: PlanExportBackendReceipt
    let projectSessionID: String
    let modelID: String
    let owner: String
    let s3AccessKey: String
    let s3SecretKey: String
    let projectPath: String
    let planPath: String
    let sourceRevision: String
    let receiptID: String
    let coreLayerContext: CoreLayerRequestContext?
}

struct PlanModelUploadBackendResult: Decodable, Sendable {
    let state: String
    let modelID: String
    let outputPath: String
    let receiptID: String
}

@MainActor
protocol PlanExportTransport: AnyObject {
    func accessFolders(_ request: PlanExportBackendRequest) async throws -> [String]
    func inspect(_ request: PlanExportBackendRequest) async throws -> PlanExportBackendInspection
    func export(_ request: PlanExportBackendDuplexRequest,
                progress: @escaping @MainActor (BackendProgressUpdate) -> Void) async throws -> PlanExportBackendDuplexResult
    func upload(_ request: PlanModelUploadBackendRequest,
                progress: @escaping @MainActor (BackendProgressUpdate) -> Void) async throws -> PlanModelUploadBackendResult
    func cancelActiveOperation()
}

@MainActor
private final class BackendPlanExportTransport: PlanExportTransport {
    private let client: BackendProcessClient
    private var activeExport: BackendDuplexOperation<PlanExportBackendControl, BackendProgressUpdate,
        PlanExportBackendDuplexResult>?
    private var activeUpload: BackendDuplexOperation<PlanExportBackendControl, BackendProgressUpdate,
        PlanModelUploadBackendResult>?

    init(client: BackendProcessClient) { self.client = client }

    func accessFolders(_ request: PlanExportBackendRequest) async throws -> [String] {
        try await client.request("planExport.accessFolders", parameters: request, as: [String].self)
    }

    func inspect(_ request: PlanExportBackendRequest) async throws -> PlanExportBackendInspection {
        try await client.request("planExport.inspect", parameters: request, as: PlanExportBackendInspection.self)
    }

    func export(_ request: PlanExportBackendDuplexRequest,
                progress: @escaping @MainActor (BackendProgressUpdate) -> Void) async throws -> PlanExportBackendDuplexResult {
        let operation = try client.startDuplex("planExport.executeDuplex", parameters: request,
            control: PlanExportBackendControl.self, event: BackendProgressUpdate.self,
            as: PlanExportBackendDuplexResult.self)
        activeExport = operation
        defer { activeExport = nil }
        try await consume(operation, progress: progress)
        return try await operation.value()
    }

    func upload(_ request: PlanModelUploadBackendRequest,
                progress: @escaping @MainActor (BackendProgressUpdate) -> Void) async throws -> PlanModelUploadBackendResult {
        let operation = try client.startDuplex("planExport.modelRepoUpload.execute", parameters: request,
            control: PlanExportBackendControl.self, event: BackendProgressUpdate.self,
            as: PlanModelUploadBackendResult.self)
        activeUpload = operation
        defer { activeUpload = nil }
        try await consume(operation, progress: progress)
        return try await operation.value()
    }

    func cancelActiveOperation() {
        if let activeExport { cancel(activeExport) }
        if let activeUpload { cancel(activeUpload) }
    }

    private func consume<Control, Result>(
        _ operation: BackendDuplexOperation<Control, BackendProgressUpdate, Result>,
        progress: @escaping @MainActor (BackendProgressUpdate) -> Void
    ) async throws where Control: Encodable & Sendable, Result: Decodable & Sendable {
        var cancellationSent = false
        for try await update in operation.events {
            if Task.isCancelled && !cancellationSent {
                cancel(operation)
                cancellationSent = true
            }
            progress(update)
        }
    }

    private func cancel<Control, Event, Result>(
        _ operation: BackendDuplexOperation<Control, Event, Result>
    ) where Control: Encodable & Sendable, Event: Decodable & Sendable,
           Result: Decodable & Sendable {
        if !operation.requestSourceCancellation() { operation.cancel() }
    }
}

@MainActor
final class BackendPlanExportProvider: ToolProvider {
    private let transport: any PlanExportTransport
    private var project: ProjectDocument?
    private var projectSessionID: UUID?
    private var prepared: (request: PlanExportBackendRequest, revision: String)?
    private var executing = false
    private(set) var lastCommittedReceipt: PlanExportBackendReceipt?
    var pathMappings: @MainActor () -> [PathMapping] = { [] }
    var projectXML: @MainActor () -> String? = { nil }
    var coreLayerContext: @MainActor () -> CoreLayerRequestContext? = { nil }
    var uploadCredentials: @MainActor () -> WorkspaceS3Credentials? = { nil }
    var applicationUID: @MainActor () -> String? = { nil }
    var authorizeFolders: @MainActor ([URL]) -> Bool = { _ in true }
    var onRunningChanged: (@MainActor (Bool) -> Void)?
    var onExported: (@MainActor (URL) -> Void)?

    init(client: BackendProcessClient? = nil) {
        let backend = client ?? BackendProcessClient(executableURL: Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/Backend/HECRASBackend"))
        transport = BackendPlanExportTransport(client: backend)
    }

    init(transport: any PlanExportTransport) { self.transport = transport }

    func setProject(_ document: ProjectDocument?, sessionID: UUID) {
        project = document
        projectSessionID = sessionID
        prepared = nil
    }

    private func sourceRequest(_ request: ToolRequest,
                              capturedCoreLayerContext: CoreLayerRequestContext?) throws -> PlanExportBackendRequest {
        guard request.kind == ToolKind.planExport.id else { throw DataToolError.unavailable }
        guard let project, let url = project.url, request.context?.projectSessionID == projectSessionID else {
            throw BackendServiceError(code: "sourceChanged", message: "Open a saved project before exporting a plan.")
        }
        let xml = try XMLDocument(xmlString: projectXML() ?? project.editorXML)
        if let group = xml.rootElement()?.elements(forName: "Connections").first {
            for connection in project.connections where ["File", "Directory"].contains(connection.type) {
                // Explicit path mappings resolve legacy Windows paths. Missing
                // unrelated connections do not prevent another plan's export.
                guard let resolved = try? connection.resolve(relativeTo: url.deletingLastPathComponent(), mappings: pathMappings()),
                      let node = group.elements(forName: "Connection").first(where: { $0.attribute(forName: "Name")?.stringValue == connection.name }) else { continue }
                for name in ["RelativePath", "AbsolutePath"] { node.elements(forName: name).forEach { $0.detach() } }
                node.addChild(XMLElement(name: "AbsolutePath", stringValue: resolved.path))
            }
        }
        let cell: Float?
        if request.fields["PlanExporterControl/EnableResample"] == "true" {
            guard let value = Float(request.fields["PlanExporterControl/ResampleCellsize"] ?? ""), value.isFinite, value > 0 else {
                throw BackendServiceError(code: "invalidInput", message: "Enter a finite resample cell size greater than zero.")
            }
            cell = value
        } else { cell = nil }
        let projectPath = capturedCoreLayerContext?.projectPath ?? url.standardizedFileURL.path
        return PlanExportBackendRequest(projectPath: projectPath, projectXml: xml.xmlString,
            planPath: request.fields["PlanExporterControl/Plan"] ?? request.context?.assetID,
            outputPath: request.destination?.path, zip: request.fields["PlanExporterControl/ExportTypeIndex"] != "1",
            clipRasters: request.fields["PlanExporterControl/ClipRasters"] != "false", resampleCellsize: cell,
            externalConnections: request.fields["PlanExporterControl/ExternalConnectionIndex"] == "1" ? "CopyToProject" : "ReferenceByAbsolutePath",
            replaceFile: request.replaceDestination, coreLayerContext: capturedCoreLayerContext,
            projectSessionID: request.context?.projectSessionID.uuidString)
    }

    func prepare(_ request: ToolRequest) async throws -> DataToolPresentation {
        guard !executing else { throw DataToolError.unavailable }
        prepared = nil
        let capturedCoreLayerContext = coreLayerContext()
        var source = try sourceRequest(request, capturedCoreLayerContext: capturedCoreLayerContext)
        let origin = source
        let folders = try await transport.accessFolders(source)
        try Task.checkCancellation()
        guard capturedCoreLayerContext == coreLayerContext(),
              origin == (try sourceRequest(request, capturedCoreLayerContext: capturedCoreLayerContext)) else {
            throw CancellationError()
        }
        guard authorizeFolders(folders.map { URL(fileURLWithPath: $0, isDirectory: true) }) else {
            throw BackendServiceError(code: "accessCancelled", message: "Folder access was cancelled.")
        }
        var result = try await transport.inspect(source)
        if source.outputPath == nil, let suggested = result.suggestedOutputPath {
            source.outputPath = suggested
            result = try await transport.inspect(source)
        }
        try Task.checkCancellation()
        guard capturedCoreLayerContext == coreLayerContext(),
              origin == (try sourceRequest(request, capturedCoreLayerContext: capturedCoreLayerContext)) else {
            throw CancellationError()
        }
        prepared = (source, result.revision)
        var fields = request.fields
        if let path = source.outputPath { fields["PlanExporterControl/OutputPath"] = path }
        if let plan = result.selectedPlanPath { fields["PlanExporterControl/Plan"] = plan }
        var editor = EditorSnapshot(fields: fields, rows: [:], samples: [:], canEdit: true, images: [:])
        editor.choiceOptions["PlanExporterControl/Plan"] = result.plans.map { .init(id: $0.id, title: $0.title, titleIsUserData: true) }
        let uploadReady = Self.canOfferUpload(zip: source.zip, credentials: uploadCredentials())
        return DataToolPresentation(editor: editor, canExecute: result.canExecute, canCancel: true,
            uploadAvailable: uploadReady,
            planExport: .init(destination: source.outputPath.map { URL(fileURLWithPath: $0) }, sourceFiles: result.sourceFiles.map { URL(fileURLWithPath: $0) },
                requiredConnections: result.requiredConnections, validationMessage: result.validationMessage.map(L10n.text)))
    }

    func execute(_ request: ToolRequest) async throws {
        try await execute(request, progress: { _ in })
    }

    func execute(_ request: ToolRequest,
                 progress: @escaping @MainActor (DataToolProgress) -> Void) async throws {
        let capturedCoreLayerContext = coreLayerContext()
        var source = try sourceRequest(request, capturedCoreLayerContext: capturedCoreLayerContext)
        guard !executing, let prepared, source == prepared.request else {
            throw BackendServiceError(code: "sourceChanged", message: "Refresh the export form before exporting the plan.")
        }
        let modelID = request.fields["PlanExporterControl/ModelId"] ?? ""
        let uploadRequested = source.zip && request.fields["PlanExporterControl/EnableUpload"] == "true"
        let credentials = uploadRequested ? uploadCredentials() : nil
        guard !uploadRequested || Self.canOfferUpload(zip: source.zip, credentials: credentials) else {
            throw BackendServiceError(code: "credentialsUnavailable",
                message: L10n.text("Configure and authenticate developer S3 credentials in Settings before uploading a plan ZIP."))
        }
        guard !uploadRequested || !modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BackendServiceError(code: "invalidInput", message: L10n.text("Enter a model ID before uploading the plan ZIP."))
        }
        let owner = applicationUID().flatMap { $0.isEmpty ? nil : $0 } ?? "anonymous"
        source.revision = prepared.revision
        executing = true
        onRunningChanged?(true)
        defer { executing = false; onRunningChanged?(false); self.prepared = nil }

        let exportRequest = PlanExportBackendDuplexRequest(export: source, uploadAfterExport: uploadRequested)
        let exportResult = try await transport.export(exportRequest, progress: { update in
            progress(DataToolProgress(message: update.message ?? update.taskName ?? "", fraction: update.fraction))
        })
        guard exportResult.state == "completed", let receipt = exportResult.receipt else {
            throw CancellationError()
        }
        try validate(receipt, against: source)
        lastCommittedReceipt = receipt
        onExported?(URL(fileURLWithPath: receipt.outputPath))
        guard uploadRequested else { return }
        try Task.checkCancellation()
        guard capturedCoreLayerContext == coreLayerContext(),
              try sourceRequest(request, capturedCoreLayerContext: capturedCoreLayerContext) == prepared.request else {
            throw BackendServiceError(code: "sourceChanged",
                message: L10n.text("The project or selected Plan changed after export. The ZIP was saved; refresh before uploading."))
        }
        guard let credentials, Self.canOfferUpload(zip: source.zip, credentials: credentials) else {
            throw BackendServiceError(code: "credentialsUnavailable",
                message: L10n.text("Configure and authenticate developer S3 credentials in Settings before uploading a plan ZIP."))
        }
        guard let planPath = source.planPath, !planPath.isEmpty, let sourceRevision = source.revision else {
            throw BackendServiceError(code: "invalidReceipt",
                message: L10n.text("The selected project and Plan no longer match the committed ZIP."))
        }
        let uploadRequest = PlanModelUploadBackendRequest(receipt: receipt,
            projectSessionID: receipt.projectSessionID, modelID: modelID, owner: owner,
            s3AccessKey: credentials.accessKey, s3SecretKey: credentials.secretKey,
            projectPath: source.projectPath, planPath: planPath, sourceRevision: sourceRevision,
            receiptID: receipt.receiptID, coreLayerContext: capturedCoreLayerContext)
        let uploadResult = try await transport.upload(uploadRequest, progress: { update in
            progress(DataToolProgress(message: update.message ?? update.taskName ?? "", fraction: update.fraction))
        })
        if uploadResult.state == "cancelled" { throw CancellationError() }
        guard uploadResult.state == "completed", uploadResult.modelID == modelID,
              uploadResult.outputPath == receipt.outputPath, uploadResult.receiptID == receipt.receiptID else {
            throw BackendServiceError(code: "invalidReceipt",
                message: L10n.text("The model repository did not confirm the exact exported ZIP."))
        }
    }

    func cancelActiveOperation() { transport.cancelActiveOperation() }

    static func canOfferUpload(zip: Bool, credentials: WorkspaceS3Credentials?) -> Bool {
        guard zip, let credentials else { return false }
        return !credentials.accessKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !credentials.secretKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func validate(_ receipt: PlanExportBackendReceipt, against request: PlanExportBackendRequest) throws {
        let outputIdentityMatches = request.zip
            ? (receipt.outputSHA256?.count == 64 && receipt.outputBytes > 0)
            : (receipt.outputSHA256 == nil && receipt.outputBytes == 0)
        guard receipt.zip == request.zip, outputIdentityMatches,
              receipt.projectPath == request.projectPath,
              receipt.planPath == request.planPath,
              receipt.projectSessionID == request.projectSessionID,
              receipt.sourceRevision == request.revision,
              receipt.coreLayerIdentityToken == request.coreLayerContext?.identityToken,
              receipt.outputPath == request.outputPath,
              !receipt.receiptID.isEmpty else {
            throw BackendServiceError(code: "invalidReceipt",
                message: L10n.text("The plan export did not return a receipt for the selected project, Plan, and ZIP."))
        }
    }
}
