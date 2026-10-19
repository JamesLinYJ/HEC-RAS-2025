import Foundation

/// Retained renamed-source definitions for application-global vector styles.
/// IDs are persistence identities; display names and layer labels are not keys.
public enum SourceVectorStyleCatalog {
    private static let sourceDefault = VectorStyleValues()
    private static let allPointFields = VectorStyleField.allCases
    private static let lineFields: [VectorStyleField] = [.penColor, .penWidth]
    private static let polygonFields: [VectorStyleField] = [.penColor, .penWidth, .fillColor]

    private static let boundaryLine = VectorStyleValues(
        penColor: "#FF05D5FF", penWidth: 3, fillColor: "#FF05D5FF"
    )
    private static let culvertLine = VectorStyleValues(
        penColor: "#FF0000FF", penWidth: 4, fillColor: "#FF0000FF"
    )
    private static let meshLine = VectorStyleValues(
        penColor: "#80000000", penWidth: 1, fillColor: "#80000000"
    )
    private static let topologyArc = VectorStyleValues(
        penColor: "#FF200040", penWidth: 2, fillColor: "#20388EFF"
    )
    private static let topologyNode = VectorStyleValues(
        penColor: "#FF5B379E", penWidth: 2, fillColor: "#FFC5A6FF", pointSize: 5
    )
    private static let deletableTopologyNode = VectorStyleValues(
        penColor: "#FF5B379E", penWidth: 2, fillColor: "#FF4287F5", pointSize: 5
    )
    private static let topologyInternalPoint = VectorStyleValues(
        penColor: "#FF545353", penWidth: 1, fillColor: "#FFB3B3B3", pointSize: 3
    )
    private static let labelText = VectorStyleValues(
        penColor: "#FFFFFFFF", penWidth: 12, fillColor: "#FFFFFFFF", pointSize: 3,
        haloColor: "#C4000000", haloThickness: 2, textEmphasis: 1
    )

    /// Exact fallback for source renderers that have no registered definition.
    /// This mirrors `VectorSymbology.DefaultSymbology()` in the retained source.
    public static let fallbackStyle = sourceDefault

    private static func variant(
        _ sourceContext: String,
        name: String,
        layerName: String,
        type: String,
        defaultStyle: VectorStyleValues? = nil,
        supportedFields: [VectorStyleField],
        conditionCapability: VectorStyleConditionCapability = .attributeTable
    ) -> VectorStyleDefinitionVariant {
        VectorStyleDefinitionVariant(
            sourceContext: sourceContext,
            name: name,
            layerName: layerName,
            type: type,
            defaultStyle: defaultStyle ?? sourceDefault,
            supportedFields: supportedFields,
            conditionCapability: conditionCapability
        )
    }

    private static func definition(
        _ id: String,
        variants: [VectorStyleDefinitionVariant]
    ) -> VectorStyleDefinition {
        VectorStyleDefinition(id: id, variants: variants)
    }

    /// A deterministic source catalog. The retained registry chooses the
    /// first reflected registration for duplicate IDs, but reflection ordering
    /// is not explicitly guaranteed. This port lists the generic polyline
    /// declaration before the map-file declaration and preserves both variants.
    public static let definitions: [VectorStyleDefinition] = [
        definition("BC_Line_Symbology", variants: [
            variant("Ras.Visual.WinUI.Contexts.BoundaryConditionLineLayerVC", name: "Line", layerName: "Boundary Condition Line", type: "Line", defaultStyle: boundaryLine, supportedFields: lineFields)
        ]),
        definition("BC_Line_Vertex_Symbology", variants: [
            variant("Ras.Visual.WinUI.Contexts.BoundaryConditionLineLayerVC", name: "Vertex", layerName: "Boundary Condition Line", type: "Point", supportedFields: allPointFields)
        ]),
        definition("Culvert_Barrel_Symbology", variants: [
            variant("Ras.Visual.WinUI.Contexts.CulvertBarrelLayerVisualContext", name: "Line", layerName: "Culvert Barrels", type: "Line", defaultStyle: culvertLine, supportedFields: lineFields)
        ]),
        definition("Culvert_Barrel_Vertex_Symbology", variants: [
            variant("Ras.Visual.WinUI.Contexts.CulvertBarrelLayerVisualContext", name: "Vertex", layerName: "Culvert Barrels", type: "Point", supportedFields: allPointFields)
        ]),
        definition("Mesh_Line_Symbology", variants: [
            variant("Ras.Visual.WinUI.Contexts.FlowAreaLayerVisualContext", name: "Face", layerName: "Mesh", type: "Line", defaultStyle: meshLine, supportedFields: lineFields)
        ]),
        definition("Arc_Line_Symbology", variants: [
            variant("Ras.Visual.WinUI.Contexts.TopologyVisualContext", name: "Arc", layerName: "Conceptual Mesh", type: "Line", defaultStyle: topologyArc, supportedFields: lineFields)
        ]),
        definition("Node_Symbology", variants: [
            variant("Ras.Visual.WinUI.Contexts.TopologyVisualContext", name: "Node", layerName: "Conceptual Mesh", type: "Point", defaultStyle: topologyNode, supportedFields: allPointFields, conditionCapability: .topologyNodeState)
        ]),
        definition("Deletable_Node_Symbology", variants: [
            variant("Ras.Visual.WinUI.Contexts.TopologyVisualContext", name: "Deletable Node", layerName: "Conceptual Mesh", type: "Point", defaultStyle: deletableTopologyNode, supportedFields: allPointFields)
        ]),
        definition("Internal_Point_Symbology", variants: [
            variant("Ras.Visual.WinUI.Contexts.TopologyVisualContext", name: "Arc Internal Vertex", layerName: "Conceptual Mesh", type: "Point", defaultStyle: topologyInternalPoint, supportedFields: allPointFields)
        ]),
        definition("Graph_Arc", variants: [
            variant("Ras.Visual.WinUI.Contexts.GraphVisualContext", name: "Arc", layerName: "Graph", type: "Line", defaultStyle: topologyArc, supportedFields: lineFields)
        ]),
        definition("Graph_Node", variants: [
            variant("Ras.Visual.WinUI.Contexts.GraphVisualContext", name: "Node", layerName: "Graph", type: "Point", defaultStyle: topologyNode, supportedFields: allPointFields)
        ]),
        definition("Graph_InternalPoint", variants: [
            variant("Ras.Visual.WinUI.Contexts.GraphVisualContext", name: "Arc Internal Vertex", layerName: "Graph", type: "Point", defaultStyle: topologyInternalPoint, supportedFields: allPointFields)
        ]),
        definition("Point_Symbology", variants: [
            variant("Visual.Mapping.Observables.PointLayerVisualContext", name: "Point", layerName: "Generic Point Layer", type: "Point", supportedFields: allPointFields)
        ]),
        definition("Point_Map_Layer_Symbology", variants: [
            variant("Visual.Mapping.Observables.PointMapLayerVisualContext", name: "Point", layerName: "Point Map Layer", type: "Point", supportedFields: allPointFields)
        ]),
        definition("Polyline_Line_Symbology", variants: [
            variant("Visual.Mapping.Observables.PolylineLayerVisualContext", name: "Line", layerName: "Generic Polyline Layer", type: "Line", supportedFields: lineFields),
            variant("Visual.Mapping.Observables.PolylineMapLayerVisualContext", name: "Polyline", layerName: "Polyline Map Layer", type: "Line", supportedFields: lineFields)
        ]),
        definition("Polyline_Vertex_Symbology", variants: [
            variant("Visual.Mapping.Observables.PolylineLayerVisualContext", name: "Vertex", layerName: "Generic Polyline Layer", type: "Point", supportedFields: allPointFields),
            variant("Visual.Mapping.Observables.PolylineMapLayerVisualContext", name: "Vertex", layerName: "Polyline Map Layer", type: "Point", supportedFields: allPointFields)
        ]),
        definition("Polygon_Shape_Symbology", variants: [
            variant("Visual.Mapping.Observables.PolygonLayerVisualContext", name: "Polygon", layerName: "Generic Polygon Layer", type: "Polygon", supportedFields: polygonFields)
        ]),
        definition("Polygon_Vertex_Symbology", variants: [
            variant("Visual.Mapping.Observables.PolygonLayerVisualContext", name: "Vertex", layerName: "Generic Polygon Layer", type: "Point", supportedFields: allPointFields)
        ]),
        definition("Polygon_Map_Layer_Shape_Symbology", variants: [
            variant("Visual.Mapping.Observables.PolygonMapLayerVisualContext", name: "Polygon", layerName: "Polygon Map Layer", type: "Polygon", supportedFields: polygonFields)
        ]),
        definition("Polygon_Map_Layer_Vertex_Symbology", variants: [
            variant("Visual.Mapping.Observables.PolygonMapLayerVisualContext", name: "Vertex", layerName: "Polygon Map Layer", type: "Point", supportedFields: allPointFields)
        ]),
        definition("Gdb_Point_Symbology", variants: [
            variant("Visual.Mapping.Observables.GdbVectorLayerVisualContext", name: "Point", layerName: "GDB Vector", type: "Point", supportedFields: allPointFields)
        ]),
        definition("Gdb_Line_Symbology", variants: [
            variant("Visual.Mapping.Observables.GdbVectorLayerVisualContext", name: "Line", layerName: "GDB Vector", type: "Line", supportedFields: lineFields)
        ]),
        definition("Gdb_Line_Vertex_Symbology", variants: [
            variant("Visual.Mapping.Observables.GdbVectorLayerVisualContext", name: "Vertex", layerName: "GDB Vector", type: "Point", supportedFields: allPointFields)
        ]),
        definition("Gdb_Polygon_Symbology", variants: [
            variant("Visual.Mapping.Observables.GdbVectorLayerVisualContext", name: "Polygon", layerName: "GDB Vector", type: "Polygon", supportedFields: polygonFields)
        ]),
        definition("Label_Text_Symbology", variants: [
            variant("Visual.Mapping.Observables.Symbology.ObservableLabelHandler", name: "Text", layerName: "Map Labels", type: "Text", defaultStyle: labelText, supportedFields: [], conditionCapability: .globalOnly)
        ])
    ]

    /// All unique source IDs in deterministic order. The dictionary's keys
    /// remain the exact source IDs, including the two polyline collisions.
    public static let byID: [String: VectorStyleDefinition] = Dictionary(
        uniqueKeysWithValues: definitions.map { ($0.id, $0) }
    )

    public static func definition(for id: String) -> VectorStyleDefinition? {
        byID[id]
    }

    public static func variants(for id: String) -> [VectorStyleDefinitionVariant] {
        byID[id]?.variants ?? []
    }

    /// Resolve the local style first, then the app-global default, matching
    /// source local-override precedence. A nil local style inherits global.
    public static func resolvedStyle(
        globalStyle: VectorStyleValues,
        localStyle: VectorStyleValues?
    ) -> VectorStyleValues {
        localStyle ?? globalStyle
    }
}
