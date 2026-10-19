import Foundation

/// Source definition identities used by the retained generic map-layer renderer.
/// Keep these IDs identical to the `VectorSymbologyDefinition` IDs in the
/// renamed source; they are also the keys used by global symbology defaults.
public enum MapVectorStyleDefinitionIDs {
    public static let point = "Point_Map_Layer_Symbology"
    public static let polylineLine = "Polyline_Line_Symbology"
    public static let polylineVertex = "Polyline_Vertex_Symbology"
    public static let polygonShape = "Polygon_Map_Layer_Shape_Symbology"
    public static let polygonVertex = "Polygon_Map_Layer_Vertex_Symbology"

    public static let mapLayerDefinitions = [
        point, polylineLine, polylineVertex, polygonShape, polygonVertex
    ]

    public static func primaryDefinition(for kind: MapFeature.Kind) -> String {
        switch kind {
        case .point: return point
        case .line: return polylineLine
        case .polygon: return polygonShape
        }
    }

    public static func vertexDefinition(for kind: MapFeature.Kind) -> String? {
        switch kind {
        case .point: return nil
        case .line: return polylineVertex
        case .polygon: return polygonVertex
        }
    }
}

/// The render-ready source style for one vector layer. Feature overrides are
/// keyed by the source feature/table row ordinal, not the transient canvas ID.
public struct MapVectorStylePresentation: Sendable, Equatable {
    public var base: [String: VectorStyleValues]
    public var perSourceFeatureOverrides: [Int: [String: VectorStyleValues]]
    /// Set only when the provider proved that MapFeature.sourceFeatureIndex
    /// selects the same row used by the source condition evaluator.
    public var sourceFeatureOrdinalBindingVerified: Bool

    public init(base: [String: VectorStyleValues] = [:],
                perSourceFeatureOverrides: [Int: [String: VectorStyleValues]] = [:],
                sourceFeatureOrdinalBindingVerified: Bool = false) {
        self.base = base
        self.perSourceFeatureOverrides = perSourceFeatureOverrides
        self.sourceFeatureOrdinalBindingVerified = sourceFeatureOrdinalBindingVerified
    }

    /// Returns a feature-specific value only when the caller has a proven
    /// source row ordinal. Features without such a binding use the base style.
    public func values(for definitionID: String, sourceFeatureIndex: Int?) -> VectorStyleValues? {
        if sourceFeatureOrdinalBindingVerified, let sourceFeatureIndex,
           let override = perSourceFeatureOverrides[sourceFeatureIndex]?[definitionID] {
            return override
        }
        return base[definitionID]
    }

    /// Generic map layers without a local provider presentation still use the
    /// retained source defaults rather than an invented layer-index palette.
    public static var sourceMapLayerDefaults: MapVectorStylePresentation {
        var values: [String: VectorStyleValues] = [:]
        for id in MapVectorStyleDefinitionIDs.mapLayerDefinitions {
            if let definition = SourceVectorStyleCatalog.definition(for: id) {
                values[id] = definition.defaultStyle
            }
        }
        return MapVectorStylePresentation(base: values)
    }
}
