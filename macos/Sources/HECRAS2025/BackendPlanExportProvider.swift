import Foundation
import RASWorkspaceCore

struct PlanExportPresentation: Sendable {
    let destination: URL?
    let sourceFiles: [URL]
    let requiredConnections: [String]
    let validationMessage: String?
}

@MainActor
final class BackendPlanExportProvider: ToolProvider {
    private let client: BackendProcessClient
    private var project: ProjectDocument?
    private var projectSessionID: UUID?
    private var prepared: (request: Request, revision: String)?
    private var executing = false
    var pathMappings: @MainActor () -> [PathMapping] = { [] }
    var projectXML: @MainActor () -> String? = { nil }
    var authorizeFolders: @MainActor ([URL]) -> Bool = { _ in true }
    var onRunningChanged: (@MainActor (Bool) -> Void)?
    var onExported: (@MainActor (URL) -> Void)?

    init(client: BackendProcessClient? = nil) {
        self.client = client ?? BackendProcessClient(executableURL: Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/Backend/HECRASBackend"))
    }
    func setProject(_ document: ProjectDocument?, sessionID: UUID) {
        project = document; projectSessionID = sessionID; prepared = nil
    }
    private func sourceRequest(_ request: ToolRequest) throws -> Request {
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
        return Request(projectPath: url.path, projectXml: xml.xmlString,
            planPath: request.fields["PlanExporterControl/Plan"] ?? request.context?.assetID,
            outputPath: request.destination?.path, zip: request.fields["PlanExporterControl/ExportTypeIndex"] != "1",
            clipRasters: request.fields["PlanExporterControl/ClipRasters"] != "false", resampleCellsize: cell,
            externalConnections: request.fields["PlanExporterControl/ExternalConnectionIndex"] == "1" ? "CopyToProject" : "ReferenceByAbsolutePath",
            replaceFile: request.replaceDestination)
    }
    func prepare(_ request: ToolRequest) async throws -> DataToolPresentation {
        guard !executing else { throw DataToolError.unavailable }
        prepared = nil
        var source = try sourceRequest(request)
        let origin = source
        let folders = try await client.request("planExport.accessFolders", parameters: source, as: [String].self)
        try Task.checkCancellation()
        guard origin == (try sourceRequest(request)) else { throw CancellationError() }
        guard authorizeFolders(folders.map { URL(fileURLWithPath: $0, isDirectory: true) }) else {
            throw BackendServiceError(code: "accessCancelled", message: "Folder access was cancelled.")
        }
        var result = try await client.request("planExport.inspect", parameters: source, as: Inspection.self)
        if source.outputPath == nil, let suggested = result.suggestedOutputPath {
            source.outputPath = suggested
            result = try await client.request("planExport.inspect", parameters: source, as: Inspection.self)
        }
        try Task.checkCancellation()
        guard origin == (try sourceRequest(request)) else { throw CancellationError() }
        prepared = (source, result.revision)
        var fields = request.fields
        if let path = source.outputPath { fields["PlanExporterControl/OutputPath"] = path }
        if let plan = result.selectedPlanPath { fields["PlanExporterControl/Plan"] = plan }
        var editor = EditorSnapshot(fields: fields, rows: [:], samples: [:], canEdit: true, images: [:])
        editor.choiceOptions["PlanExporterControl/Plan"] = result.plans.map { .init(id: $0.id, title: $0.title, titleIsUserData: true) }
        return DataToolPresentation(editor: editor, canExecute: result.canExecute, canCancel: false,
            planExport: .init(destination: source.outputPath.map { URL(fileURLWithPath: $0) }, sourceFiles: result.sourceFiles.map { URL(fileURLWithPath: $0) },
                requiredConnections: result.requiredConnections, validationMessage: result.validationMessage.map(L10n.text)))
    }
    func execute(_ request: ToolRequest) async throws {
        var source = try sourceRequest(request)
        guard !executing, let prepared, source == prepared.request else {
            throw BackendServiceError(code: "sourceChanged", message: "Refresh the export form before exporting the plan.")
        }
        source.revision = prepared.revision
        executing = true; onRunningChanged?(true)
        defer { executing = false; onRunningChanged?(false); self.prepared = nil }
        let result = try await client.request("planExport.execute", parameters: source, as: ExportResult.self)
        onExported?(URL(fileURLWithPath: result.outputPath))
    }
    private struct Request: Encodable, Equatable, Sendable {
        let projectPath: String; let projectXml: String; let planPath: String?
        var outputPath: String?; let zip: Bool; let clipRasters: Bool; let resampleCellsize: Float?
        let externalConnections: String; let replaceFile: Bool; var revision: String? = nil
    }
    private struct Choice: Decodable, Sendable { let id: String; let title: String }
    private struct Inspection: Decodable, Sendable {
        let revision: String; let canExecute: Bool; let validationMessage: String?
        let plans: [Choice]; let selectedPlanPath: String?; let suggestedOutputPath: String?
        let sourceFiles: [String]; let requiredConnections: [String]
    }
    private struct ExportResult: Decodable, Sendable {
        let outputPath: String; let zip: Bool; let projectFilename: String; let fileCount: Int
    }
}
