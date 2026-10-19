import Foundation
import RASWorkspaceCore

@MainActor
final class BackendCreationToolProvider: ToolProvider {
    private let client: BackendProcessClient
    private var project: ProjectDocument?
    private var projectSessionID: UUID?
    private var prepared: (request: Request, revision: String)?
    private var executing = false
    var onRunningChanged: (@MainActor (Bool) -> Void)?
    var onCreated: (@MainActor (ProjectAsset, Bool) -> Void)?
    var projectXML: @MainActor () -> String? = { nil }
    var coreLayerContext: @MainActor () -> CoreLayerRequestContext? = { nil }

    init(client: BackendProcessClient? = nil) {
        self.client = client ?? BackendProcessClient(executableURL: Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/Backend/HECRASBackend"))
    }
    func setProject(_ document: ProjectDocument?, sessionID: UUID) {
        project = document; projectSessionID = sessionID; prepared = nil
    }
    private func sourceRequest(_ request: ToolRequest) throws -> Request {
        let kind: String
        switch request.kind {
        case ToolKind.newGeometry.id: kind = "newGeometry"
        case ToolKind.newPlan.id: kind = "newPlan"
        case ToolKind.newBoundary.id: kind = "newBoundary"
        default: throw DataToolError.unavailable
        }
        guard let project, let url = project.url, request.context?.projectSessionID == projectSessionID else {
            throw BackendServiceError(code: "sourceChanged", message: "Open a saved project before creating a model.")
        }
        return Request(kind: kind, projectPath: url.path, projectXml: projectXML() ?? project.editorXML,
            fields: request.fields, coreLayerContext: coreLayerContext())
    }
    func prepare(_ request: ToolRequest) async throws -> DataToolPresentation {
        guard !executing else { throw DataToolError.unavailable }
        prepared = nil
        let source = try sourceRequest(request)
        let result = try await client.request("modelCreation.inspect", parameters: source, as: Inspection.self)
        try Task.checkCancellation()
        guard source == (try sourceRequest(request)) else { throw CancellationError() }
        prepared = (source, result.revision)
        var editor = EditorSnapshot(fields: request.fields, rows: [:], samples: [:], canEdit: true, images: [:])
        editor.choiceOptions = result.choices.mapValues { $0.map { EditorChoice(id: $0.id, title: $0.title, titleIsUserData: true) } }
        let windows = try result.boundaryTimeWindows.mapValues { value in
            guard let start = Self.parseDate(value.start), let end = Self.parseDate(value.end) else {
                throw BackendServiceError(code: "sourceFailure", message: "The boundary condition returned an invalid time window.")
            }
            return CreationTimeWindow(start: start, end: end)
        }
        return DataToolPresentation(editor: editor, canExecute: result.canExecute, canCancel: false,
            creation: .init(boundaryTimeWindows: windows,
                validationMessage: result.validationMessage.map(L10n.text), warning: result.warning.map(L10n.text)))
    }
    func execute(_ request: ToolRequest) async throws {
        var source = try sourceRequest(request)
        guard !executing, let prepared, prepared.request == source, let document = project else {
            throw BackendServiceError(code: "sourceChanged", message: "Refresh the creation form before creating the model.")
        }
        source.revision = prepared.revision
        executing = true; onRunningChanged?(true)
        defer { executing = false; onRunningChanged?(false); self.prepared = nil }
        // Publication is deliberately not cancellable from the sheet: the
        // backend commits one new file, then associations join this same draft.
        let result = try await client.request("modelCreation.create", parameters: source, as: CreatedModel.self)
        guard project === document, request.context?.projectSessionID == projectSessionID else {
            throw BackendServiceError(code: "sourceChanged", message: "The project changed while the model was being created.")
        }
        guard let section = ProjectSection(rawValue: result.section) else { throw DataToolError.unavailable }
        var changed = false
        if let group = result.group, let element = result.element, let primaryKey = result.primaryKey {
            let association = ProjectAssociation(group: group, element: element, primaryKey: primaryKey, name: result.name, fields: [:])
            for (field, value) in result.associations where !value.isEmpty {
                try document.setAssociation(association, field: field, value: value); changed = true
            }
        }
        onCreated?(ProjectAsset(url: URL(fileURLWithPath: result.assetPath), section: section), changed)
    }
    private struct Request: Encodable, Equatable, Sendable {
        let kind: String; let projectPath: String; let projectXml: String
        let fields: [String: String]; var revision: String? = nil
        var coreLayerContext: CoreLayerRequestContext? = nil
    }
    private struct Choice: Decodable, Sendable { let id: String; let title: String }
    private static func parseDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter.date(from: value)
    }
    private struct Window: Decodable, Sendable { let start: String; let end: String }
    private struct Inspection: Decodable, Sendable {
        let revision: String; let canExecute: Bool; let validationMessage: String?; let warning: String?
        let choices: [String: [Choice]]; let boundaryTimeWindows: [String: Window]
    }
    private struct CreatedModel: Decodable, Sendable {
        let assetPath: String; let section: String; let group: String?; let element: String?; let primaryKey: String?
        let name: String; let associations: [String: String]
    }
}
