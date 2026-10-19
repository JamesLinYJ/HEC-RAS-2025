import Foundation
import RASWorkspaceCore

struct ProjectProjectionExportRequest: Encodable, Sendable {
    let projectPath: String
    let projectXml: String
    let expectedProjectRevision: String
    let destinationPath: String
}

struct ProjectProjectionExportReceipt: Decodable, Equatable, Sendable {
    let projectPath: String
    let projectRevision: String
    let outputPath: String
}

struct IncompleteResultDeletePreparationRequest: Encodable, Sendable {
    let projectPath: String
    let projectXml: String
    let projectRevision: String
    let resultPath: String
    let resultRevision: String
}

struct IncompleteResultDeletePreparation: Decodable, Equatable, Sendable {
    let projectPath: String
    let projectRevision: String
    let resultPath: String
    let resultName: String
    let resultRevision: String

    func matches(projectPath: URL, projectRevision: String,
                 resultPath: URL, resultRevision: String) -> Bool {
        Self.canonical(self.projectPath) == Self.canonical(projectPath.path)
            && self.projectRevision.caseInsensitiveCompare(projectRevision) == .orderedSame
            && Self.canonical(self.resultPath) == Self.canonical(resultPath.path)
            && self.resultRevision.caseInsensitiveCompare(resultRevision) == .orderedSame
    }

    private static func canonical(_ path: String) -> String {
        SourceFilePaths.canonical(URL(fileURLWithPath: path))
    }
}

@MainActor
final class BackendCatalogHeaderActionProvider {
    private let client: BackendProcessClient

    init(client: BackendProcessClient) { self.client = client }

    func exportProjection(_ request: ProjectProjectionExportRequest) async throws -> ProjectProjectionExportReceipt {
        try await client.request("project.projection.export", parameters: request,
                                 as: ProjectProjectionExportReceipt.self)
    }

    func prepareIncompleteResultRemoval(
        _ request: IncompleteResultDeletePreparationRequest
    ) async throws -> IncompleteResultDeletePreparation {
        try await client.request("result.removeIncomplete.prepare", parameters: request,
                                 as: IncompleteResultDeletePreparation.self)
    }
}
