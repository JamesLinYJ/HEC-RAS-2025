import Foundation
import RASWorkspaceCore

struct CatalogModelActionRequest: Encodable, Sendable {
    let projectPath: String
    let projectXml: String
    let assetPath: String
    let kind: String
    let expectedAssetSHA: String
    let action: String
    let name: String?
}

struct CatalogModelActionDependency: Decodable, Equatable, Identifiable, Sendable {
    let assetPath: String?
    let kind: String
    let name: String
    let revision: String?
    let reason: String
    var id: String { [kind, name, assetPath ?? ""].joined(separator: "/") }
}

struct CatalogModelActionTrashPath: Decodable, Equatable, Identifiable, Sendable {
    let path: String
    let revision: String
    let originalAsset: Bool
    var id: String { path }
}

struct CatalogModelActionStagedTarget: Decodable, Equatable, Sendable {
    let stagePath: String
    let targetPath: String
    let stageSHA: String
    let expectedTargetSHA: String?
}

struct CatalogModelActionStagingDirectory: Decodable, Equatable, Sendable {
    let path: String
    let token: String
}

struct CatalogModelActionMetadataMutation: Decodable, Equatable, Sendable {
    let section: String
    let rowName: String
    let identityAttribute: String
    let identityValue: String
    let attribute: String
    let oldValue: String?
    let newValue: String?
    let removeRow: Bool
}

struct CatalogModelActionInspection: Decodable, Equatable, Sendable {
    let projectPath: String
    let assetPath: String
    let canonicalAssetPath: String
    let kind: String
    let name: String
    let revision: String
    let availableActions: [String]
    let deleteDependencies: [CatalogModelActionDependency]
    let trashPaths: [CatalogModelActionTrashPath]
}

struct CatalogModelActionReceipt: Decodable, Equatable, Sendable {
    let action: String
    let kind: String
    let originalAssetPath: String
    let canonicalOriginalAssetPath: String
    let originalName: String
    let originalSHA: String
    let newName: String?
    let newAssetPath: String?
    let actualClone: Bool
    let stagedTargets: [CatalogModelActionStagedTarget]
    let metadataMutations: [CatalogModelActionMetadataMutation]
    let deleteDependencies: [CatalogModelActionDependency]
    let stagingDirectories: [CatalogModelActionStagingDirectory]
    let projectXmlFingerprint: String
    let trashPaths: [CatalogModelActionTrashPath]?
}

struct CatalogModelActionCleanupRequest: Encodable, Sendable {
    let stagingDirectory: String
    let token: String
}

@MainActor
final class BackendCatalogModelActionProvider {
    private let client: BackendProcessClient

    init(client: BackendProcessClient) { self.client = client }

    func inspect(_ request: CatalogModelActionRequest) async throws -> CatalogModelActionInspection {
        try await client.request("catalog.modelAction.inspect", parameters: request, as: CatalogModelActionInspection.self)
    }

    func perform(_ request: CatalogModelActionRequest) async throws -> CatalogModelActionReceipt {
        try await client.request("catalog.modelAction.perform", parameters: request, as: CatalogModelActionReceipt.self)
    }

    func cleanup(_ receipt: CatalogModelActionReceipt) async {
        for directory in receipt.stagingDirectories {
            let request = CatalogModelActionCleanupRequest(stagingDirectory: directory.path, token: directory.token)
            let _: Bool? = try? await client.request("catalog.modelAction.cleanup", parameters: request, as: Bool.self)
        }
    }
}
