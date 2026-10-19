import RASWorkspaceCore
import SwiftUI

/// Source-style values translated into the native geometry canvases while
/// keeping selection emphasis as a separate presentation layer.
enum GeometryMapStylePresentation {
    static var sourceTopologyNodePointSize: Int {
        SourceVectorStyleCatalog.definition(for: "Node_Symbology")?.defaultStyle.pointSize ?? 0
    }

    enum Ink: Equatable {
        case source(String)
        case selection
        case white
    }

    struct Stroke: Equatable {
        let ink: Ink
        let width: Double
    }

    struct Point: Equatable {
        let fill: Ink
        let outline: Ink
        let diameter: Double
        let outlineWidth: Double
    }

    static func topologyArc(_ style: VectorStyleValues, selected: Bool,
                            renderScale: Double = 1) -> Stroke {
        if selected {
            return Stroke(ink: .selection,
                          width: scaledWidth(max(3.2, visibleWidth(style.penWidth)), factor: renderScale))
        }
        return Stroke(ink: .source(style.penColor),
                      width: scaledWidth(visibleWidth(style.penWidth), factor: renderScale))
    }

    static func arcInternalPoint(_ style: VectorStyleValues, renderScale: Double = 1) -> Point {
        Point(fill: .source(style.fillColor), outline: .source(style.penColor),
              diameter: scaledWidth(Double(max(0, style.pointSize)), factor: renderScale),
              outlineWidth: scaledWidth(visibleWidth(style.penWidth), factor: renderScale))
    }

    static func topologyNode(
        _ style: VectorStyleValues,
        deletableStyle: VectorStyleValues,
        selected: Bool,
        incidentArcs: [GeometryTopologyIncidentArc]?,
        worldUnitsPerPoint: Double?,
        sourceDefaultPointSize: Int,
        renderScale: Double = 1
    ) -> Point {
        if selected {
            return Point(fill: .selection, outline: .white,
                         diameter: scaledWidth(11, factor: renderScale),
                         outlineWidth: scaledWidth(0.9, factor: renderScale))
        }
        let fillColor = conditionalNodeFill(style.fillColor, deletableStyle: deletableStyle,
                                            incidentArcs: incidentArcs)
        let diameter = sourceNodeDiameter(basePointSize: style.pointSize, incidentArcs: incidentArcs,
            worldUnitsPerPoint: worldUnitsPerPoint, sourceDefaultPointSize: sourceDefaultPointSize)
        return Point(fill: .source(fillColor), outline: .source(style.penColor),
                     diameter: scaledWidth(Double(max(0, diameter)), factor: renderScale),
                     outlineWidth: scaledWidth(visibleWidth(style.penWidth), factor: renderScale))
    }

    static func conditionalNodeFill(
        _ baseFillColor: String,
        deletableStyle: VectorStyleValues,
        incidentArcs: [GeometryTopologyIncidentArc]?
    ) -> String {
        guard let incidentArcs, incidentArcs.count == 2,
              incidentArcs[0].arcID != incidentArcs[1].arcID else { return baseFillColor }
        return deletableStyle.fillColor
    }

    static func sourceNodeDiameter(
        basePointSize: Int,
        incidentArcs: [GeometryTopologyIncidentArc]?,
        worldUnitsPerPoint: Double?,
        sourceDefaultPointSize: Int
    ) -> Int {
        guard let incidentArcs,
              let worldUnitsPerPoint,
              worldUnitsPerPoint.isFinite, worldUnitsPerPoint > 0 else {
            return basePointSize
        }
        let ratio: Double
        if incidentArcs.isEmpty {
            ratio = 0
        } else {
            guard incidentArcs.allSatisfy({ $0.length.isFinite }) else { return basePointSize }
            ratio = incidentArcs.map(\.length).max()! / worldUnitsPerPoint
        }
        guard ratio.isFinite else { return basePointSize }
        if ratio > 50 { return basePointSize }
        if ratio < 2 { return 0 }
        return Int(Double(sourceDefaultPointSize) * (ratio / 50))
    }

    static func meshCell(_ style: VectorStyleValues, selected: Bool,
                         renderScale: Double = 1) -> Stroke {
        if selected {
            return Stroke(ink: .selection,
                          width: scaledWidth(max(2.8, visibleWidth(style.penWidth)), factor: renderScale))
        }
        return Stroke(ink: .source(style.penColor),
                      width: scaledWidth(visibleWidth(style.penWidth), factor: renderScale))
    }

    static func color(for ink: Ink) -> Color {
        switch ink {
        case .source(let value): BoundaryARGBColor.decode(value) ?? .primary
        case .selection: Color.accentColor
        case .white: Color.white
        }
    }

    private static func visibleWidth(_ width: Double) -> Double {
        width.isFinite ? max(0, width) : 0
    }

    private static func scaledWidth(_ width: Double, factor: Double) -> Double {
        Double(WorkspaceRenderScaling.metric(width, factor: factor))
    }
}
