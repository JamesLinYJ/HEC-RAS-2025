import RASWorkspaceCore
import Testing
@testable import HECRAS2025

struct GeometrySpecializedMapStyleTests {
    @Test
    func topologyArcUsesGlobalPenAndPreservesSelectionEmphasis() throws {
        let style = VectorStyleValues(penColor: "#FF16A0C8", penWidth: 4.5)
        let normal = GeometryMapStylePresentation.topologyArc(style, selected: false)
        let selected = GeometryMapStylePresentation.topologyArc(style, selected: true)

        #expect(normal.ink == .source("#FF16A0C8"))
        #expect(normal.width == 4.5)
        #expect(selected.ink == .selection)
        #expect(selected.width == 4.5)
    }

    @Test
    func internalArcVertexUsesItsDedicatedPointStyle() {
        let style = VectorStyleValues(penColor: "#FF112233", penWidth: 1.75,
            fillColor: "#80445566", pointSize: 6)
        let appearance = GeometryMapStylePresentation.arcInternalPoint(style)

        #expect(appearance.fill == .source("#80445566"))
        #expect(appearance.outline == .source("#FF112233"))
        #expect(appearance.diameter == 6)
        #expect(appearance.outlineWidth == 1.75)
    }

    @Test
    func topologyNodeUsesSourceStateOverridesAndKeepsSelectedOverlay() throws {
        let style = VectorStyleValues(penColor: "#FF223344", penWidth: 2,
            fillColor: "#80445566", pointSize: 9)
        let deletable = VectorStyleValues(fillColor: "#FFAABBCC")
        let arcs = [GeometryTopologyIncidentArc(arcID: 2, length: 20),
                    GeometryTopologyIncidentArc(arcID: 5, length: 12)]
        let normal = GeometryMapStylePresentation.topologyNode(style, deletableStyle: deletable,
            selected: false, incidentArcs: arcs, worldUnitsPerPoint: 1, sourceDefaultPointSize: 5)
        let selected = GeometryMapStylePresentation.topologyNode(style, deletableStyle: deletable,
            selected: true, incidentArcs: arcs, worldUnitsPerPoint: 1, sourceDefaultPointSize: 5)

        #expect(normal.fill == .source("#FFAABBCC"))
        #expect(normal.outline == .source("#FF223344"))
        #expect(normal.diameter == 2)
        #expect(normal.outlineWidth == 2)
        #expect(selected.fill == .selection)
        #expect(selected.outline == .white)
        #expect(selected.diameter == 11)
        #expect(selected.outlineWidth == 0.9)
    }

    @Test
    func topologyNodeCallbacksUseExactlyTwoDistinctArcsAndCurrentViewportScale() {
        let deletable = VectorStyleValues(fillColor: "#FFABCDEF")
        let twoDistinct = [GeometryTopologyIncidentArc(arcID: 3, length: 30),
                           GeometryTopologyIncidentArc(arcID: 4, length: 20)]
        let repeatedArc = [GeometryTopologyIncidentArc(arcID: 3, length: 30),
                           GeometryTopologyIncidentArc(arcID: 3, length: 20)]
        let base = "#FF123456"

        #expect(GeometryMapStylePresentation.conditionalNodeFill(base, deletableStyle: deletable,
            incidentArcs: twoDistinct) == "#FFABCDEF")
        #expect(GeometryMapStylePresentation.conditionalNodeFill(base, deletableStyle: deletable,
            incidentArcs: repeatedArc) == base)
        #expect(GeometryMapStylePresentation.conditionalNodeFill(base, deletableStyle: deletable,
            incidentArcs: nil) == base)
        #expect(GeometryMapStylePresentation.sourceNodeDiameter(basePointSize: 9,
            incidentArcs: twoDistinct, worldUnitsPerPoint: 1, sourceDefaultPointSize: 5) == 3)
        #expect(GeometryMapStylePresentation.sourceNodeDiameter(basePointSize: 9,
            incidentArcs: twoDistinct, worldUnitsPerPoint: 0.5, sourceDefaultPointSize: 5) == 9)
        #expect(GeometryMapStylePresentation.sourceNodeDiameter(basePointSize: 9,
            incidentArcs: twoDistinct, worldUnitsPerPoint: 20, sourceDefaultPointSize: 5) == 0)
    }

    @Test
    func meshCellOutlineUsesGlobalMeshPenWithoutReplacingFlowAreaFill() throws {
        let style = VectorStyleValues(penColor: "#80335577", penWidth: 0.75)
        let normal = GeometryMapStylePresentation.meshCell(style, selected: false)
        let selected = GeometryMapStylePresentation.meshCell(style, selected: true)

        #expect(normal.ink == .source("#80335577"))
        #expect(normal.width == 0.75)
        #expect(selected.ink == .selection)
        #expect(selected.width == 2.8)
    }

    @Test
    func specializedStylesUseTheRetainedGeometryDefinitions() throws {
        #expect(SourceVectorStyleCatalog.definition(for: "Arc_Line_Symbology")?.variants.first?.sourceContext
            == "Ras.Visual.WinUI.Contexts.TopologyVisualContext")
        #expect(SourceVectorStyleCatalog.definition(for: "Node_Symbology")?.variants.first?.conditionCapability
            == .topologyNodeState)
        #expect(SourceVectorStyleCatalog.definition(for: "Deletable_Node_Symbology")?.variants.first?.type == "Point")
        #expect(SourceVectorStyleCatalog.definition(for: "Internal_Point_Symbology")?.variants.first?.type == "Point")
        #expect(SourceVectorStyleCatalog.definition(for: "Mesh_Line_Symbology")?.variants.first?.sourceContext
            == "Ras.Visual.WinUI.Contexts.FlowAreaLayerVisualContext")
    }

    @Test
    func sourceWidthsAndPointSizesThatCannotDrawAreClampedOnlyAtPresentation() {
        let thin = GeometryMapStylePresentation.topologyArc(
            VectorStyleValues(penWidth: -2), selected: false)
        let empty = GeometryMapStylePresentation.topologyNode(VectorStyleValues(pointSize: -4),
            deletableStyle: VectorStyleValues(), selected: false, incidentArcs: nil,
            worldUnitsPerPoint: nil, sourceDefaultPointSize: 5)

        #expect(thin.width == 0)
        #expect(empty.diameter == 0)
        #expect(empty.outlineWidth == 1)
    }
}
