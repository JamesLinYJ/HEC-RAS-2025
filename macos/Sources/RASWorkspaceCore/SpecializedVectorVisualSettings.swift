import Foundation

/// Exact persisted `.vis` identity for one source-owned geometry visual child.
/// The model asset ID comes from the live source Geometry tree node; the
/// retained `.vis` format itself stores Geometry as Type/Name and the path.
public struct SpecializedVectorVisualNodeIdentity: Codable, Hashable, Identifiable, Sendable {
    public let mapIndex: Int
    public let mapName: String
    public let mapType: String
    public let rootName: String
    public let geometryNodePath: [Int]
    public let geometryName: String
    public let geometryAssetID: String
    public let nodePath: [Int]
    public let nodeType: String
    public let nodeName: String

    public var definitionIDs: [String]? {
        SpecializedVectorVisualDefinitions.definitionIDs(forNodeType: nodeType)
    }

    public var id: String {
        [String(mapIndex), mapType, mapName, rootName,
         geometryNodePath.map(String.init).joined(separator: "."), geometryName, geometryAssetID,
         nodePath.map(String.init).joined(separator: "."), nodeType, nodeName]
            .joined(separator: "\u{1F}")
    }

    public init(
        mapIndex: Int,
        mapName: String,
        mapType: String,
        rootName: String,
        geometryNodePath: [Int],
        geometryName: String,
        geometryAssetID: String,
        nodePath: [Int],
        nodeType: String,
        nodeName: String
    ) {
        self.mapIndex = mapIndex
        self.mapName = mapName
        self.mapType = mapType
        self.rootName = rootName
        self.geometryNodePath = geometryNodePath
        self.geometryName = geometryName
        self.geometryAssetID = geometryAssetID
        self.nodePath = nodePath
        self.nodeType = nodeType
        self.nodeName = nodeName
    }
}

/// Source context types serialized by RasProjectTreeBase under a Geometry
/// node. Graph and other topology contexts are deliberately excluded.
public enum SpecializedVectorVisualDefinitions {
    public static func definitionIDs(forNodeType nodeType: String) -> [String]? {
        let ids: [String]
        switch nodeType {
        case "ConceptualMesh":
            ids = ["Arc_Line_Symbology", "Node_Symbology", "Deletable_Node_Symbology", "Internal_Point_Symbology"]
        case "FlowAreaLayer":
            ids = ["Mesh_Line_Symbology"]
        case "CulvertBarrelLayer":
            ids = ["Culvert_Barrel_Symbology", "Culvert_Barrel_Vertex_Symbology"]
        default:
            return nil
        }
        return ids.allSatisfy { SourceVectorStyleCatalog.definition(for: $0) != nil } ? ids : nil
    }
}
