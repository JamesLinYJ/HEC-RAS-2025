import Foundation

/// Exact identity for one persisted MapLayer node in a project's `.vis` map
/// tree. `nodePath` uses the source MapTreeService convention: the root child
/// index followed by each descendant's index among its parent's Node children.
public struct VectorVisualNodeIdentity: Codable, Hashable, Sendable {
    public let mapIndex: Int
    public let mapName: String
    public let mapType: String
    public let rootName: String?
    public let nodePath: [Int]
    public let nodeType: String
    public let nodeName: String
    public let mapLayerType: String
    public let filename: String?
    public let filenameRelative: String?
    public let assetID: String?
    public let gdbLayerName: String?
    public let gdbVectorType: String?

    public var supportedStyleDefinitionIDs: [String]? {
        VectorVisualStyleDefinitions.ids(mapLayerType: mapLayerType, gdbVectorType: gdbVectorType)
    }

    public init(
        mapIndex: Int,
        mapName: String,
        mapType: String,
        rootName: String? = nil,
        nodePath: [Int],
        nodeType: String = "MapLayer",
        nodeName: String,
        mapLayerType: String,
        filename: String?,
        filenameRelative: String?,
        assetID: String?,
        gdbLayerName: String? = nil,
        gdbVectorType: String? = nil
    ) {
        self.mapIndex = mapIndex
        self.mapName = mapName
        self.mapType = mapType
        self.rootName = rootName
        self.nodePath = nodePath
        self.nodeType = nodeType
        self.nodeName = nodeName
        self.mapLayerType = mapLayerType
        self.filename = filename
        self.filenameRelative = filenameRelative
        self.assetID = assetID
        self.gdbLayerName = gdbLayerName
        self.gdbVectorType = gdbVectorType
    }
}

/// Definition IDs proven by the retained generic MapLayer visual contexts.
/// GDB nodes require the serialized `GdbVectorType` because the source chooses
/// their point, line, or polygon context from that value.
public enum VectorVisualStyleDefinitions {
    public static func ids(mapLayerType: String, gdbVectorType: String? = nil) -> [String]? {
        let ids: [String]
        switch mapLayerType {
        case "PointsVector": ids = ["Point_Map_Layer_Symbology"]
        case "PolylinesVector": ids = ["Polyline_Line_Symbology", "Polyline_Vertex_Symbology"]
        case "PolygonsVector": ids = ["Polygon_Map_Layer_Shape_Symbology", "Polygon_Map_Layer_Vertex_Symbology"]
        case "GdbVectorLayer":
            switch gdbVectorType {
            case "Point", "PointCollection": ids = ["Gdb_Point_Symbology"]
            case "Line", "LineCollection": ids = ["Gdb_Line_Symbology", "Gdb_Line_Vertex_Symbology"]
            case "Polygon", "PolygonCollection": ids = ["Gdb_Polygon_Symbology"]
            default: return nil
            }
        default: return nil
        }
        return ids.allSatisfy({ SourceVectorStyleCatalog.definition(for: $0) != nil }) ? ids : nil
    }
}

/// One of the four ordered condition collections serialized by the retained
/// VectorSymbologyOption implementation.
public struct VectorVisualConditionGroup: Codable, Equatable, Sendable {
    public let field: VectorStyleField
    public var rules: [VectorStyleRule]

    public init(field: VectorStyleField, rules: [VectorStyleRule] = []) {
        self.field = field
        self.rules = rules
    }
}

/// Effective values for one definition in one persisted vector MapLayer.
/// Condition groups always retain source order, including groups not exposed
/// by that definition's base-style editor.
public struct VectorVisualSettingsOptions: Codable, Equatable, Sendable {
    public var values: VectorStyleValues
    public var conditionGroups: [VectorVisualConditionGroup]

    public init(
        values: VectorStyleValues,
        conditionGroups: [VectorVisualConditionGroup] = VectorStyleField.allCases.map {
            VectorVisualConditionGroup(field: $0)
        }
    ) {
        self.values = values
        self.conditionGroups = conditionGroups
    }

    public func rules(for field: VectorStyleField) -> [VectorStyleRule] {
        conditionGroups.first(where: { $0.field == field })?.rules ?? []
    }
}

/// An immutable source revision and the definitions that belong to this
/// concrete persisted layer. The dictionary keys are source definition IDs.
public struct VectorVisualSettingsSnapshot: Codable, Equatable, Sendable {
    public let options: [String: VectorVisualSettingsOptions]
    public let revision: String?

    public init(options: [String: VectorVisualSettingsOptions], revision: String?) {
        self.options = options
        self.revision = revision
    }
}

/// Presence-aware local `.vis` attributes for boundary line symbology. A nil
/// value means inherit the current global default; it is distinct from an
/// explicit override whose value happens to equal a former default.
public struct BoundaryLineVisualStyleOverrides: Equatable, Sendable {
    public var penColor: String?
    public var penWidth: Double?
    public var fillColor: String?
    public var pointSize: Int?

    public init(penColor: String? = nil, penWidth: Double? = nil,
                fillColor: String? = nil, pointSize: Int? = nil) {
        self.penColor = penColor
        self.penWidth = penWidth
        self.fillColor = fillColor
        self.pointSize = pointSize
    }
}

public struct BoundaryLineVisualOverrides: Equatable, Sendable {
    public var line: BoundaryLineVisualStyleOverrides
    public var vertex: BoundaryLineVisualStyleOverrides
    public var hasConditionalOverrides: Bool

    public init(
        line: BoundaryLineVisualStyleOverrides = .init(),
        vertex: BoundaryLineVisualStyleOverrides = .init(),
        hasConditionalOverrides: Bool = false
    ) {
        self.line = line
        self.vertex = vertex
        self.hasConditionalOverrides = hasConditionalOverrides
    }
}
