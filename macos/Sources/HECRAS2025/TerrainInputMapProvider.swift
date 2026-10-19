import Foundation
import RASWorkspaceCore

/// The subset of a map-tree request needed to resolve transient TerrainInput
/// contexts. In particular this deliberately has no compute-read lease: the
/// caller must honor the map's ordinary source-read gate before rendering.
struct TerrainInputMapTreeRequest: Encodable, Equatable, Sendable {
    let projectPath: String
    let projectXml: String
    let projectXmlSHA: String
    let mapID: String
    let mapIndex: Int
    let mapName: String
    let mapType: String
    let expectedVisualizationRevision: String
    var resultSelectionOverrides: [MapTreeResultSelectionOverride]

    init(map: MapResultChartMapRequest,
         resultSelectionOverrides: [MapTreeResultSelectionOverride]) {
        projectPath = map.projectPath
        projectXml = map.projectXml
        projectXmlSHA = map.projectXmlSHA
        mapID = map.mapID
        mapIndex = map.mapIndex
        mapName = map.mapName
        mapType = map.mapType
        expectedVisualizationRevision = map.expectedVisualizationRevision
        self.resultSelectionOverrides = resultSelectionOverrides
    }
}

struct TerrainInputMapContextRequest: Encodable, Sendable {
    let map: TerrainInputMapTreeRequest
    let inputNodeID: String
    let expectedSourceClass: String
    let expectedTerrainPath: String
}

struct TerrainInputMapContextFeature: Decodable, Sendable {
    let id: String
    let kind: String
    let points: [TerrainMapCoordinate]
    let closed: Bool
}

struct TerrainInputMapContextData: Decodable, Sendable {
    let inputNodeID: String
    let inputIndex: Int
    let terrainPath: String
    let terrainRevision: String
    let sourceClass: String
    let features: [TerrainInputMapContextFeature]

    @MainActor
    func validated(for request: TerrainInputMapContextRequest) throws -> [TerrainInputRenderedFeature] {
        guard inputNodeID == request.inputNodeID, inputIndex >= 0,
              sourceClass == request.expectedSourceClass,
              Self.canonical(terrainPath) == Self.canonical(request.expectedTerrainPath),
              Self.isSHA256(terrainRevision),
              Set(features.map(\.id)).count == features.count,
              features.allSatisfy({ feature in
                  let minimum = feature.kind == "line" ? 2 : feature.kind == "polygon" ? 3 : Int.max
                  return feature.id.hasPrefix(inputNodeID + ":feature:")
                      && feature.points.count >= minimum
                      && feature.points.allSatisfy { $0.x.isFinite && $0.y.isFinite }
                      && feature.closed == (feature.kind == "polygon")
              }) else {
            throw BackendServiceError(code: "protocolFailure",
                message: L10n.text("The selected terrain input no longer matches the current map."))
        }
        return features.map {
            TerrainInputRenderedFeature(id: $0.id, inputNodeID: inputNodeID,
                inputIndex: inputIndex, sourceClass: sourceClass, kind: $0.kind,
                points: $0.points, closed: $0.closed,
                terrainPath: Self.canonical(terrainPath), terrainRevision: terrainRevision)
        }
    }

    private static func canonical(_ path: String) -> String {
        SourceFilePaths.canonical(URL(fileURLWithPath: path))
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
        }
    }
}

@MainActor
protocol TerrainInputMapContextProvider {
    func renderTerrainInput(_ request: TerrainInputMapContextRequest) async throws -> TerrainInputMapContextData
}

@MainActor
struct BackendTerrainInputMapProvider: TerrainInputMapContextProvider {
    private let client: BackendProcessClient

    init(client: BackendProcessClient? = nil) {
        self.client = client ?? BackendProcessClient(executableURL: Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/Backend/HECRASBackend"))
    }

    func renderTerrainInput(_ request: TerrainInputMapContextRequest) async throws -> TerrainInputMapContextData {
        try await client.request("map.terrainInput.render", parameters: request,
            as: TerrainInputMapContextData.self)
    }
}
