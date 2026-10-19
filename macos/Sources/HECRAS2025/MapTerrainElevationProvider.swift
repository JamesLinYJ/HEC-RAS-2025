import Foundation
import RASWorkspaceCore

struct MapTerrainElevationCoordinate: Encodable, Sendable {
    let x: Double
    let y: Double
}

struct MapTerrainElevationDependency: Codable, Hashable, Sendable {
    let path: String
    let revision: String
    let role: String
}

struct MapTerrainElevationRequest: Encodable, Sendable {
    let map: MapResultChartMapRequest
    let terrainNode: CatalogTreeNodeLocator
    let expectedTerrainPath: String
    let expectedTerrainRevision: String
    let expectedDependencies: [MapTerrainElevationDependency]
    let endpoints: [MapTerrainElevationCoordinate]
    let resultOwners: [MapResultGeometryOwner]?

    init(map: MapResultChartMapRequest, capture: AssociatedMapLayerCapture,
         payload: AssociatedMapLayerPayload, endpoints: [MapPoint]) throws {
        let dependencies = payload.dependencies.filter {
            $0.role == "source-hdf" || $0.role == "terrain-input-raster"
        }.map {
            MapTerrainElevationDependency(path: $0.path, revision: $0.revision, role: $0.role)
        }
        guard capture.associationNode.nodeType == "Terrain",
              capture.associationNode.associationKind == "Terrain",
              capture.isChecked, capture.effectiveVisible,
              payload.status == .available, payload.isChecked, payload.effectiveVisible,
              capture.map.mapID.caseInsensitiveCompare(map.mapID) == .orderedSame,
              capture.map.mapIndex == map.mapIndex, capture.map.mapName == map.mapName,
              capture.map.mapType == map.mapType,
              capture.map.projectXmlSHA.caseInsensitiveCompare(map.projectXmlSHA) == .orderedSame,
              capture.map.expectedVisualizationRevision.caseInsensitiveCompare(map.expectedVisualizationRevision) == .orderedSame,
              SourceFilePaths.canonical(URL(fileURLWithPath: capture.map.projectPath))
                == SourceFilePaths.canonical(URL(fileURLWithPath: map.projectPath)),
              SourceFilePaths.canonical(URL(fileURLWithPath: payload.assetPath)) == capture.assetPath,
              dependencies.contains(where: { $0.role == "source-hdf" &&
                  SourceFilePaths.canonical(URL(fileURLWithPath: $0.path))
                    == SourceFilePaths.canonical(URL(fileURLWithPath: payload.assetPath)) &&
                  $0.revision.caseInsensitiveCompare(payload.revision) == .orderedSame }),
              dependencies.allSatisfy({ $0.path.hasPrefix("/") && Self.isSHA256($0.revision) }),
              endpoints.count == 2, endpoints.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else {
            throw BackendServiceError(code: "sourceChanged",
                message: "The active Terrain source is not ready for a length measurement.")
        }
        self.map = map
        terrainNode = capture.associationNode
        expectedTerrainPath = capture.assetPath
        expectedTerrainRevision = payload.revision
        expectedDependencies = dependencies
        self.endpoints = endpoints.map { MapTerrainElevationCoordinate(x: $0.x, y: $0.y) }
        resultOwners = capture.resultOwners.isEmpty ? nil : capture.resultOwners
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isHexDigit }
    }
}

struct MapTerrainElevationResult: Decodable, Sendable {
    let projectPath: String
    let projectRevision: String
    let projectXmlSHA: String
    let visualizationRevision: String
    let mapID: String
    let mapIndex: Int
    let mapName: String
    let mapType: String
    let contextToken: String
    let terrainNode: CatalogTreeNodeLocator
    let terrainPath: String
    let terrainRevision: String
    let sourceDependencies: [MapTerrainElevationDependency]
    let elevations: [Double?]

    func validate(for request: MapTerrainElevationRequest) throws {
        let map = request.map
        let contextMatches = request.resultOwners?.first.map {
            contextToken.caseInsensitiveCompare($0.contextToken) == .orderedSame
        } ?? true
        guard SourceFilePaths.canonical(URL(fileURLWithPath: projectPath))
                == SourceFilePaths.canonical(URL(fileURLWithPath: map.projectPath)),
              projectXmlSHA.caseInsensitiveCompare(map.projectXmlSHA) == .orderedSame,
              visualizationRevision.caseInsensitiveCompare(map.expectedVisualizationRevision) == .orderedSame,
              mapID.caseInsensitiveCompare(map.mapID) == .orderedSame,
              mapIndex == map.mapIndex, mapName == map.mapName, mapType == map.mapType,
              terrainNode == request.terrainNode,
              contextMatches,
              SourceFilePaths.canonical(URL(fileURLWithPath: terrainPath))
                == SourceFilePaths.canonical(URL(fileURLWithPath: request.expectedTerrainPath)),
              Self.isSHA256(projectRevision), Self.isSHA256(contextToken), Self.isSHA256(terrainRevision),
              elevations.count == 2, elevations.allSatisfy({ $0 == nil || $0!.isFinite }),
              Self.sameDependencies(sourceDependencies, request.expectedDependencies) else {
            throw BackendServiceError(code: "sourceChanged",
                message: "The Terrain slope reply belongs to a different or outdated map source.")
        }
    }

    private static func sameDependencies(_ left: [MapTerrainElevationDependency],
                                         _ right: [MapTerrainElevationDependency]) -> Bool {
        guard left.count == right.count else { return false }
        return right.allSatisfy { expected in
            left.filter { actual in
                actual.role == expected.role &&
                    SourceFilePaths.canonical(URL(fileURLWithPath: actual.path))
                        == SourceFilePaths.canonical(URL(fileURLWithPath: expected.path)) &&
                    actual.revision.caseInsensitiveCompare(expected.revision) == .orderedSame
            }.count == 1
        }
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isHexDigit }
    }
}

protocol MapTerrainElevationProviding {
    func sample(_ request: MapTerrainElevationRequest) async throws -> MapTerrainElevationResult
}

struct BackendMapTerrainElevationProvider: MapTerrainElevationProviding {
    let client: BackendProcessClient

    func sample(_ request: MapTerrainElevationRequest) async throws -> MapTerrainElevationResult {
        let result = try await client.request("map.measureTerrainElevations", parameters: request,
            as: MapTerrainElevationResult.self)
        try result.validate(for: request)
        return result
    }
}
