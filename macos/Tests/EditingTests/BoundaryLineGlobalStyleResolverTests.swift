import RASWorkspaceCore
import Testing
@testable import HECRAS2025

struct BoundaryLineGlobalStyleResolverTests {
    @Test
    func globalChangesUpdateOnlyWholeOptionsThatStillMatchTheirPreviousDefault() {
        let previous = BoundaryLineVisualSettings(
            line: .init(penColor: "#FF010203", penWidth: 2, fillColor: "#FF010203", pointSize: 3),
            vertex: .init(penColor: "#FF040506", penWidth: 1, fillColor: "#80070809", pointSize: 5),
            hasConditionalOverrides: true
        )
        let current = BoundaryLineVisualSettings(
            line: .init(penColor: "#FF112233", penWidth: 2, fillColor: "#FF010203", pointSize: 3),
            vertex: previous.vertex,
            hasConditionalOverrides: true
        )
        let next = BoundaryLineVisualSettings(
            line: .init(penColor: "#FF101010", penWidth: 7, fillColor: "#FF101010", pointSize: 8),
            vertex: .init(penColor: "#FF202020", penWidth: 3, fillColor: "#80212223", pointSize: 9)
        )

        let updated = BoundaryLineGlobalStyleResolver.updated(
            current: current,
            previousDefaults: previous,
            newDefaults: next
        )

        #expect(updated.line == current.line)
        #expect(updated.vertex == next.vertex)
        #expect(updated.hasConditionalOverrides)
    }
}
