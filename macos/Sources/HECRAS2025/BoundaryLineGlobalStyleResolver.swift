import RASWorkspaceCore

/// Applies the source's two-level style behavior to the boundary editor canvas.
/// Global values are the baseline; a non-nil per-property value read from the
/// owning `.vis` symbology is a local override. Conditional rules are retained
/// and surfaced separately because this canvas does not evaluate them.
enum BoundaryLineGlobalStyleResolver {
    static func defaults(
        line: VectorStyleValues,
        vertex: VectorStyleValues
    ) -> BoundaryLineVisualSettings? {
        guard let validLine = line.validatedForPersistence(),
              let validVertex = vertex.validatedForPersistence() else { return nil }
        return BoundaryLineVisualSettings(
            line: .init(penColor: validLine.penColor, penWidth: validLine.penWidth,
                fillColor: validLine.fillColor, pointSize: validLine.pointSize),
            vertex: .init(penColor: validVertex.penColor, penWidth: validVertex.penWidth,
                fillColor: validVertex.fillColor, pointSize: validVertex.pointSize)
        )
    }

    /// The retained source updates an option to a changed global default only
    /// while that whole option still matched its previous default. Preserve a
    /// locally changed line or vertex option as a whole, while allowing the
    /// other option to adopt the new default.
    static func updated(
        current: BoundaryLineVisualSettings,
        previousDefaults: BoundaryLineVisualSettings,
        newDefaults: BoundaryLineVisualSettings
    ) -> BoundaryLineVisualSettings {
        BoundaryLineVisualSettings(
            line: current.line.penColor == previousDefaults.line.penColor
                    && current.line.penWidth == previousDefaults.line.penWidth
                ? newDefaults.line : current.line,
            vertex: current.vertex == previousDefaults.vertex ? newDefaults.vertex : current.vertex,
            hasConditionalOverrides: current.hasConditionalOverrides
        )
    }
}
