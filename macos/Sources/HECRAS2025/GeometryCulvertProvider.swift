import Foundation
import RASWorkspaceCore

struct GeometryCulvertModelRequest: Codable, Hashable, Sendable {
    let assetPath: String
    let kind: String
    let projectPath: String?
    let projectXml: String?
    var coreLayerContext: CoreLayerRequestContext? = nil
}

struct GeometryCulvertMutation: Codable, Sendable {
    let operation: String
    let featureKind: String
    let featureIDs: [String]
    var fieldID: String? = nil
    var value: String? = nil
    var draftID: String? = nil
    var polyline: [GeometryCulvertCoordinate]? = nil
    var deltaX: Double? = nil
    var deltaY: Double? = nil
    var copiedBarrels: [GeometryCulvertCopiedBarrel]? = nil
    var tolerance: Double? = nil
    var windowSize: Int? = nil
    var passes: Int? = nil
    var previewID: String? = nil
    var targetFeatureID: String? = nil
    var outputDraftIDs: [String]? = nil
    var splitMode: String? = nil
    var mapCellSize: Double? = nil
    var mergeTolerance: Double? = nil
    var offsetDistance: Double? = nil
    var offsetSides: String? = nil
    var includeEndpoints: Bool? = nil
    var keepOriginal: Bool? = nil
    var splitPoint: GeometryCulvertCoordinate? = nil
}

struct GeometryCulvertMapCommandPreviewRequest: Encodable, Sendable {
    let model: GeometryCulvertModelRequest
    let revision: String
    let draftState: String
    let previewID: String
    let operation: String
    let featureIDs: [String]
    let splitPoint: GeometryCulvertCoordinate?
    let splitMode: String?
    let mapCellSize: Double?
    let mergeTolerance: Double?
    let offsetDistance: Double?
    let offsetSides: String?
    let includeEndpoints: Bool
    let keepOriginal: Bool
    let outputDraftIDs: [String]?
    let targetFeatureID: String?
}

struct GeometryCulvertMapCommandOutput: Codable, Hashable, Sendable {
    let draftID: String
    let polyline: [GeometryCulvertCoordinate]
}

struct GeometryCulvertMapCommandPreviewResponse: Decodable, Sendable {
    let previewID: String
    let revision: String
    let draftState: String
    let dependencyRevision: String
    let operation: String
    let capturedFeatureIDs: [String]
    let removedFeatureIDs: [String]
    let retainedFeatureIDs: [String]
    let outputs: [GeometryCulvertMapCommandOutput]
    let hasChange: Bool
    let canApply: Bool
    let warningCode: String?
    let errorCode: String?
}

struct GeometryCulvertSmartAddWindow: Codable, Hashable, Sendable {
    let extent: GeometryCulvertExtent
    let rows: Int
    let columns: Int

    init(extent: GeometryCulvertExtent, rows: Int, columns: Int) {
        self.extent = extent
        self.rows = rows
        self.columns = columns
    }
}

struct GeometryCulvertSmartAddOptions: Codable, Hashable, Sendable {
    var algorithm: String = "HessianRidgeness"
    var dpTolerancePixels: Double = 1.5
    var maxSegmentPixels: Double = 1500.0
    var previewThrottlePixels: Double = 1.5
    var highGroundAlpha: Double = 3.0
    var highGroundBailRatio: Double = 5.0
    var highGroundSnapRadiusCells: Int = 15
    var hessianFrangiBeta: Double = 0.5
    var hessianFeaturePenaltyKappa: Double = 3.0
    var hessianOffFeatureBailMultiplier: Double = 100.0
    var hessianMinExpansionsBudget: Int = 250_000
    var hessianExpansionsPerEuclidPx: Int = 500
    var hessianMaxEuclidCells: Int = 1500
}

struct GeometryCulvertSmartAddPreviewRequest: Encodable, Sendable {
    let model: GeometryCulvertModelRequest
    let revision: String
    let draftState: String
    let previewID: String
    let start: GeometryCulvertCoordinate
    let end: GeometryCulvertCoordinate
    let window: GeometryCulvertSmartAddWindow
    let options: GeometryCulvertSmartAddOptions
}

struct GeometryCulvertSmartAddPreviewResponse: Decodable, Sendable {
    let previewID: String
    let revision: String
    let draftState: String
    let dependencyRevision: String
    let terrainName: String?
    let canAppend: Bool
    let path: [GeometryCulvertCoordinate]
    let errorCode: String?
}

struct GeometryCulvertCopiedBarrel: Codable, Hashable, Sendable {
    let draftID: String
    let name: String
    let barrelPropertyName: String
    let upstreamInvert: String
    let downstreamInvert: String
    let upstreamOpeningName: String
    let downstreamOpeningName: String
    let polyline: [GeometryCulvertCoordinate]
}

struct GeometryCulvertColumn: Codable, Identifiable, Sendable {
    let id: String
    let title: String
    let sourceType: String
    let readOnly: Bool
}

struct GeometryCulvertField: Codable, Identifiable, Sendable {
    let id: String
    let title: String
    let sourceType: String
    let choices: [String]
    let readOnly: Bool
    let minimum: Double?
    let maximum: Double?
    var forceSetCommand: String? = nil
    var showClearButton: Bool = false
    var clearCommand: String? = nil
    var errorValidationSource: String? = nil
    var errorValidationPropertyName: String? = nil
}

struct GeometryCulvertFeatureRow: Codable, Identifiable, Sendable {
    let id: String
    let fid: Int
    let values: [String: String]
    let polyline: [GeometryCulvertCoordinate]
    var errors: [String: [String]]? = nil
}

struct GeometryCulvertFeatureTable: Codable, Sendable {
    let featureKind: String
    let columns: [GeometryCulvertColumn]
    let editableFields: [GeometryCulvertField]
    let rows: [GeometryCulvertFeatureRow]
}

struct GeometryCulvertCoordinate: Codable, Hashable, Sendable {
    let x: Double
    let y: Double
    var z: String? = nil
    var m: String? = nil
}

struct GeometryCulvertExtent: Codable, Hashable, Sendable {
    let minX: Double
    let minY: Double
    let maxX: Double
    let maxY: Double
}

struct GeometryCulvertProfile: Codable, Identifiable, Sendable {
    let barrelID: String
    let barrelName: String
    let length: Double
    let samples: [GeometryCulvertProfileSample]
    var id: String { barrelID }
}

struct GeometryCulvertProfileSample: Codable, Identifiable, Sendable {
    let distance: Double
    let x: Double
    let y: Double
    let elevation: Double
    var id: String { String(distance.bitPattern) + ":" + String(x.bitPattern) + ":" + String(y.bitPattern) }
}

struct GeometryCulvertSnapshot: Codable, Sendable {
    let revision: String
    let draftState: String
    let canEdit: Bool
    let isDirty: Bool
    let barrels: GeometryCulvertFeatureTable
    let barrelProperties: GeometryCulvertFeatureTable
    let openingProperties: GeometryCulvertFeatureTable
    let associatedTerrainName: String?
    let profiles: [GeometryCulvertProfile]
    var associatedTerrainExtent: GeometryCulvertExtent? = nil
    var dependencyRevision: String? = nil
}

struct GeometryCulvertTerrainPreviewRequest: Encodable, Sendable {
    let model: GeometryCulvertModelRequest
    let expectedDependencyRevision: String?
}

struct GeometryCulvertTerrainPreview: Decodable, Sendable {
    let dependencyRevision: String
    let terrainName: String?
    let sourceExtent: GeometryCulvertExtent?
    let renderedExtent: GeometryCulvertExtent?
    let width: Int
    let height: Int
    let rgba: Data

    var hasImage: Bool {
        width > 0 && height > 0 && rgba.count == width * height * 4 && renderedExtent != nil
    }
}

@MainActor
protocol GeometryCulvertProvider {
    func modelRequest(for asset: ProjectAsset) -> GeometryCulvertModelRequest
    func load(_ model: GeometryCulvertModelRequest, expectedRevision: String?, draftState: String?,
              selectedBarrelIDs: [String]) async throws -> GeometryCulvertSnapshot
    func edit(_ model: GeometryCulvertModelRequest, revision: String, draftState: String,
              mutation: GeometryCulvertMutation, selectedBarrelIDs: [String]) async throws -> GeometryCulvertSnapshot
}

@MainActor
protocol GeometryCulvertTerrainPreviewProviding {
    func terrainPreview(_ model: GeometryCulvertModelRequest,
                       expectedDependencyRevision: String?) async throws -> GeometryCulvertTerrainPreview
}

@MainActor
protocol GeometryCulvertMapCommandProviding {
    func previewMapCommand(_ request: GeometryCulvertMapCommandPreviewRequest) async throws
        -> GeometryCulvertMapCommandPreviewResponse
    func previewSmartAdd(_ request: GeometryCulvertSmartAddPreviewRequest) async throws
        -> GeometryCulvertSmartAddPreviewResponse
}

@MainActor
final class BackendGeometryCulvertProvider: GeometryCulvertProvider, GeometryCulvertTerrainPreviewProviding,
    GeometryCulvertMapCommandProviding {
    private let client: BackendProcessClient
    private let currentProject: @MainActor () -> ProjectDocument?
    private let currentCoreLayerContext: @MainActor () -> CoreLayerRequestContext?

    init(client: BackendProcessClient? = nil,
         currentProject: @escaping @MainActor () -> ProjectDocument? = { nil },
         currentCoreLayerContext: @escaping @MainActor () -> CoreLayerRequestContext? = { nil }) {
        self.client = client ?? BackendProcessClient(executableURL: Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/Backend/HECRASBackend"))
        self.currentProject = currentProject
        self.currentCoreLayerContext = currentCoreLayerContext
    }

    func modelRequest(for asset: ProjectAsset) -> GeometryCulvertModelRequest {
        let project = currentProject()
        return GeometryCulvertModelRequest(assetPath: asset.url.path, kind: "Geometry",
            projectPath: project?.url?.path, projectXml: project?.editorXML,
            coreLayerContext: currentCoreLayerContext())
    }

    func load(_ model: GeometryCulvertModelRequest, expectedRevision: String?, draftState: String?,
              selectedBarrelIDs: [String]) async throws -> GeometryCulvertSnapshot {
        struct Request: Encodable, Sendable {
            let model: GeometryCulvertModelRequest
            let revision: String?
            let draftState: String?
            let selectedBarrelIDs: [String]
        }
        return try await client.request("geometry.culverts.load", parameters: Request(model: model,
            revision: expectedRevision, draftState: draftState, selectedBarrelIDs: selectedBarrelIDs),
            as: GeometryCulvertSnapshot.self)
    }

    func edit(_ model: GeometryCulvertModelRequest, revision: String, draftState: String,
              mutation: GeometryCulvertMutation, selectedBarrelIDs: [String]) async throws -> GeometryCulvertSnapshot {
        struct Request: Encodable, Sendable {
            let model: GeometryCulvertModelRequest
            let revision: String
            let draftState: String
            let mutation: GeometryCulvertMutation
            let selectedBarrelIDs: [String]
        }
        return try await client.request("geometry.culverts.edit", parameters: Request(model: model,
            revision: revision, draftState: draftState, mutation: mutation, selectedBarrelIDs: selectedBarrelIDs),
            as: GeometryCulvertSnapshot.self)
    }

    func terrainPreview(_ model: GeometryCulvertModelRequest,
                        expectedDependencyRevision: String?) async throws -> GeometryCulvertTerrainPreview {
        try await client.request("geometry.culverts.terrainPreview",
            parameters: GeometryCulvertTerrainPreviewRequest(model: model,
                expectedDependencyRevision: expectedDependencyRevision),
            as: GeometryCulvertTerrainPreview.self)
    }

    func previewMapCommand(_ request: GeometryCulvertMapCommandPreviewRequest) async throws
        -> GeometryCulvertMapCommandPreviewResponse {
        try await client.request("geometry.culverts.mapCommandPreview", parameters: request,
            as: GeometryCulvertMapCommandPreviewResponse.self)
    }

    func previewSmartAdd(_ request: GeometryCulvertSmartAddPreviewRequest) async throws
        -> GeometryCulvertSmartAddPreviewResponse {
        try await client.request("geometry.culverts.smartAddPreview", parameters: request,
            as: GeometryCulvertSmartAddPreviewResponse.self)
    }
}
