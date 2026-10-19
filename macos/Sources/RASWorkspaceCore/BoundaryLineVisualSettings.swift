import Foundation

/// VectorSymbologyHelpers stores colors as #AARRGGBB in the original .vis.
public struct BoundaryVectorVisualStyle: Equatable, Sendable {
    public var penColor: String
    public var penWidth: Double
    public var fillColor: String
    public var pointSize: Int

    public init(penColor: String, penWidth: Double, fillColor: String, pointSize: Int) {
        self.penColor = penColor; self.penWidth = penWidth
        self.fillColor = fillColor; self.pointSize = pointSize
    }
}

/// Defaults from BoundaryConditionLineLayerVC / DefaultEditSymbology, with
/// per-map overrides from the owning BoundaryConditionLineLayer context.
public struct BoundaryLineVisualSettings: Equatable, Sendable {
    public var line: BoundaryVectorVisualStyle
    public var vertex: BoundaryVectorVisualStyle
    public var hasConditionalOverrides: Bool

    public init(
        line: BoundaryVectorVisualStyle = .init(penColor: "#FF05D5FF", penWidth: 3,
            fillColor: "#FF05D5FF", pointSize: 3),
        vertex: BoundaryVectorVisualStyle = .init(penColor: "#FF000000", penWidth: 1,
            fillColor: "#800000FF", pointSize: 3),
        hasConditionalOverrides: Bool = false
    ) {
        self.line = line; self.vertex = vertex
        self.hasConditionalOverrides = hasConditionalOverrides
    }
}
