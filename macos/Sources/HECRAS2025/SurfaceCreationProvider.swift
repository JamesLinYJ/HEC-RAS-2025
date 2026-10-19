import Foundation
import RASWorkspaceCore

enum SurfaceCreationKind: String, CaseIterable, Identifiable, Sendable {
    case terrain = "newTerrain"
    case classification = "newClassification"
    case nValue = "newNValue"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .terrain: "New Terrain"
        case .classification: "New Classification Layer"
        case .nValue: "New Manning's N Layer"
        }
    }
    var defaultName: String {
        switch self {
        case .terrain: "Terrain"
        case .classification: "Classifications"
        case .nValue: "N Values"
        }
    }
    var section: ProjectSection {
        switch self {
        case .terrain: .terrains
        case .classification, .nValue: .surfaceLayers
        }
    }
    var editorKind: ModelEditorKind {
        switch self {
        case .terrain: .terrain
        case .classification, .nValue: .surface
        }
    }
}

struct SurfaceCreationRequest: Codable, Equatable, Sendable {
    let kind: String
    let projectPath: String
    let projectXml: String
    let name: String
    var revision: String? = nil
    var coreLayerContext: CoreLayerRequestContext? = nil

    init(kind: SurfaceCreationKind, projectPath: String, projectXml: String, name: String,
         revision: String? = nil, coreLayerContext: CoreLayerRequestContext? = nil) {
        self.kind = kind.rawValue
        self.projectPath = projectPath
        self.projectXml = projectXml
        self.name = name
        self.revision = revision
        self.coreLayerContext = coreLayerContext
    }
}

struct SurfaceCreationInspection: Decodable, Equatable, Sendable {
    let revision: String
    let canExecute: Bool
    let validationMessage: String?
    let suggestedName: String
    let targetDirectory: String
}

struct SurfaceCreationResult: Decodable, Equatable, Sendable {
    let assetPath: String
    let section: String
    let group: String?
    let element: String?
    let primaryKey: String?
    let name: String
    let associations: [String: String]
}

@MainActor protocol SurfaceCreationProvider {
    func inspect(_ request: SurfaceCreationRequest) async throws -> SurfaceCreationInspection
    func create(_ request: SurfaceCreationRequest) async throws -> SurfaceCreationResult
}

@MainActor struct BackendSurfaceCreationProvider: SurfaceCreationProvider {
    let client: BackendProcessClient

    func inspect(_ request: SurfaceCreationRequest) async throws -> SurfaceCreationInspection {
        try await client.request("surfaceCreation.inspect", parameters: request)
    }

    func create(_ request: SurfaceCreationRequest) async throws -> SurfaceCreationResult {
        try await client.request("surfaceCreation.create", parameters: request)
    }
}
