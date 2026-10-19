import Foundation
import RASWorkspaceCore

/// A pointer sample against one immutable visible-source capture. Paths,
/// revisions, ownership, and the current Result profile are carried together
/// so the backend can sample the source object behind the rendered layer.
struct MapHoverIdentifyRequest: Encodable, Sendable {
    let map: MapResultChartMapRequest
    let contextToken: String
    let selectionOverrides: [MapResultSelectionOverride]
    let requestID: String
    let point: MapHoverCoordinate
    let probePoint: MapHoverCoordinate
    let worldUnitsPerScreenPoint: Double
    let profileSelections: [MapDynamicProfileSelection]
    let layers: [MapHoverLayerCapture]
}

struct MapHoverCoordinate: Codable, Equatable, Sendable {
    let x: Double
    let y: Double
}

struct MapHoverLayerCapture: Encodable, Sendable {
    let node: CatalogTreeNodeLocator
    let kind: String
    var sourcePath: String? = nil
    var sourceRevision: String? = nil
    var mapType: String? = nil
    var profileIndex: Int? = nil
    var rasterSource: RasterMapSourceDescriptor? = nil
    var mesh: MapHoverMeshCapture? = nil
    var associated: MapHoverAssociatedCapture? = nil
    var resultSelections: [MapHoverResultSelectionCapture]? = nil
}

struct MapHoverResultSelectionCapture: Encodable, Sendable {
    let selectionIndex: Int
    let resultPath: String
    let resultRevision: String
}

struct MapHoverAssociatedCapture: Encodable, Sendable {
    let geometryNodes: [CatalogTreeNodeLocator]
    let planNodes: [CatalogTreeNodeLocator]
    let resultOwners: [MapResultGeometryOwner]
    let dependencies: [MapHoverAssociatedDependency]
}

struct MapHoverAssociatedDependency: Encodable, Sendable {
    let path: String
    let revision: String
    let role: String
}

struct MapHoverMeshCapture: Encodable, Sendable {
    let node: CatalogTreeNodeLocator
    let geometryNode: CatalogTreeNodeLocator
    let sourceIdentity: String
    let geometryContextToken: String
    let sourcePath: String
    let sourceRevision: String
    let planNodes: [CatalogTreeNodeLocator]?
    let resultOwner: MapResultGeometryOwner?
    let model: GeometryMeshModelRequest?
    let ownerMode: String
    let meshDraftState: String
    let meshDraftSHA256: String
    let topologyDraftState: String?
    let topologyDraftSHA256: String
    let flowAreaVisibilityOverride: Bool
}

struct MapHoverIdentifyEntry: Decodable, Identifiable, Sendable {
    let node: CatalogTreeNodeLocator
    let kind: String
    let label: String
    let value: String?
    let valueType: String?
    let sourcePath: String?
    let sourceRevision: String?
    let mapType: String?
    let profileIndex: Int?
    let meshIndex: Int?
    let elementIndex: Int?

    var id: String {
        [node.sourceIdentity, kind, sourcePath ?? "", profileIndex.map(String.init) ?? "",
         meshIndex.map(String.init) ?? "", elementIndex.map(String.init) ?? "", label]
            .joined(separator: "|")
    }
}

struct MapHoverIdentifyResult: Decodable, Sendable {
    let requestID: String
    let projectPath: String
    let projectRevision: String
    let projectXmlSHA: String
    let visualizationRevision: String
    let mapID: String
    let mapIndex: Int
    let mapName: String
    let mapType: String
    let contextToken: String
    let point: MapHoverCoordinate
    let entries: [MapHoverIdentifyEntry]
}

struct MapHoverIdentifyFlight: Sendable {
    let request: MapHoverIdentifyRequest
    let sourceIdentity: String
    let screenX: Double
    let screenY: Double
    let localEntries: [MapHoverIdentifyEntry]
}
