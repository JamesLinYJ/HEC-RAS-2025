import Foundation

enum TerrainTopologyOperation: String, Codable, Sendable {
    case load
    case select
    case draw
    case remove
    case undo
    case redo
    case sortProfile
    case split
    case moveNodes
    case moveVertex
    case insertVertex
    case deleteVertex
    case maskRegion
    case setMetadata
}

enum TerrainTopologySplitMode: String, CaseIterable, Identifiable, Codable, Hashable, Sendable {
    case anywhere = "Anywhere"
    case atVertex = "AtVertex"
    var id: String { rawValue }
}

struct TerrainTopologyCommand: Encodable, Sendable {
    let operation: TerrainTopologyOperation
    var featureIDs: [String] = []
    var points: [TerrainMapCoordinate] = []
    var mapCellSize: Double? = nil
    var splitMode: TerrainTopologySplitMode? = nil
    var vertexIndex: Int? = nil
    var metadataKind: String? = nil
    var metadataColumn: String? = nil
    var metadataValue: String? = nil

    init(operation: TerrainTopologyOperation, featureIDs: [String] = [],
         points: [TerrainMapCoordinate] = [], mapCellSize: Double? = nil,
         splitMode: TerrainTopologySplitMode? = nil, vertexIndex: Int? = nil,
         metadataKind: String? = nil, metadataColumn: String? = nil,
         metadataValue: String? = nil) {
        self.operation = operation
        self.featureIDs = featureIDs
        self.points = points
        self.mapCellSize = mapCellSize
        self.splitMode = splitMode
        self.vertexIndex = vertexIndex
        self.metadataKind = metadataKind
        self.metadataColumn = metadataColumn
        self.metadataValue = metadataValue
    }
}

struct TerrainTopologyFeature: Decodable, Identifiable, Sendable {
    let id: String
    let kind: String
    let points: [TerrainMapCoordinate]
    let parentId: String?
    let vertexIndex: Int?
    let controlPointIndex: Int?
    let isMask: Bool?
    let metadata: [TerrainTopologyMetadataField]?
    let rings: [[TerrainMapCoordinate]]?

    var isEditableVertex: Bool { kind == "arcVertex" && vertexIndex != nil && parentId != nil }
}

struct TerrainTopologyMetadataField: Decodable, Identifiable, Sendable {
    let id: String
    let title: String
    let sourceType: String
    let value: String?
    let readOnly: Bool
    let options: [String]?
}

struct TerrainTopologyData: Decodable, Sendable {
    let inputId: String
    let sourceRevision: String
    let draftIdentity: String
    let features: [TerrainTopologyFeature]
    let selectedFeatureIDs: [String]
    let canUndo: Bool
    let canRedo: Bool

    func feature(id: String) -> TerrainTopologyFeature? { features.first { $0.id == id } }
}
