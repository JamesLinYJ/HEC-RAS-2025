import Foundation
import RASWorkspaceCore

@MainActor
final class BackendToolProvider: ToolProvider {
    private let creation: BackendCreationToolProvider
    private let export: BackendPlanExportProvider
    private let unitCalculator: BackendUnitCalculatorProvider
    private let bugReport: BackendBugReportProvider
    private var executing = false
    var onRunningChanged: (@MainActor (Bool) -> Void)?
    var onCreated: (@MainActor (ProjectAsset, Bool) -> Void)?
    var onExported: (@MainActor (URL) -> Void)?
    var pathMappings: @MainActor () -> [PathMapping] = { [] }
    var projectXML: @MainActor () -> String? = { nil }
    var coreLayerContext: @MainActor () -> CoreLayerRequestContext? = { nil }
    var planUploadCredentials: @MainActor () -> WorkspaceS3Credentials? = { nil }
    var applicationUID: @MainActor () -> String? = { nil }
    var authorizeFolders: @MainActor ([URL]) -> Bool = { _ in true }
    var reportContext: @MainActor () -> BugReportNativeContext? = { nil }
    var onMessage: @MainActor (WorkspaceMessageSeverity, String) -> Void = { _, _ in }
    init(client: BackendProcessClient? = nil) {
        creation = BackendCreationToolProvider(client: client)
        export = BackendPlanExportProvider(client: client)
        unitCalculator = BackendUnitCalculatorProvider(client: client)
        bugReport = BackendBugReportProvider(client: client)
        creation.onRunningChanged = { [weak self] in self?.onRunningChanged?($0) }
        export.onRunningChanged = { [weak self] in self?.onRunningChanged?($0) }
        creation.onCreated = { [weak self] in self?.onCreated?($0, $1) }
        export.onExported = { [weak self] in self?.onExported?($0) }
        export.pathMappings = { [weak self] in self?.pathMappings() ?? [] }
        creation.projectXML = { [weak self] in self?.projectXML() }
        creation.coreLayerContext = { [weak self] in self?.coreLayerContext() }
        export.projectXML = { [weak self] in self?.projectXML() }
        export.coreLayerContext = { [weak self] in self?.coreLayerContext() }
        export.uploadCredentials = { [weak self] in self?.planUploadCredentials() }
        export.applicationUID = { [weak self] in self?.applicationUID() }
        export.authorizeFolders = { [weak self] in self?.authorizeFolders($0) ?? false }
        bugReport.reportContext = { [weak self] in self?.reportContext() }
        bugReport.onMessage = { [weak self] severity, text in self?.onMessage(severity, text) }
        bugReport.onRunningChanged = { [weak self] in self?.onRunningChanged?($0) }
    }
    func setProject(_ document: ProjectDocument?, sessionID: UUID) {
        creation.setProject(document, sessionID: sessionID); export.setProject(document, sessionID: sessionID)
        bugReport.setProject(document, sessionID: sessionID)
    }
    private func provider(_ request: ToolRequest) -> any ToolProvider {
        switch request.kind {
        case ToolKind.planExport.id: export
        case ToolKind.unitCalculator.id: unitCalculator
        case ToolKind.reportIssue.id: bugReport
        default: creation
        }
    }
    func prepare(_ request: ToolRequest) async throws -> DataToolPresentation {
        guard !executing else { throw DataToolError.unavailable }
        return try await provider(request).prepare(request)
    }
    func execute(_ request: ToolRequest) async throws {
        guard !executing else { throw DataToolError.unavailable }
        executing = true; defer { executing = false }
        try await provider(request).execute(request)
    }
    func execute(_ request: ToolRequest,
                 progress: @escaping @MainActor (DataToolProgress) -> Void) async throws {
        guard !executing else { throw DataToolError.unavailable }
        executing = true; defer { executing = false }
        try await provider(request).execute(request, progress: progress)
    }
    func perform(_ request: ToolRequest) async throws -> DataToolPresentation {
        guard !executing else { throw DataToolError.unavailable }
        return try await provider(request).perform(request)
    }
}
