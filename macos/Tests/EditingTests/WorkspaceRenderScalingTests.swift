import RASWorkspaceCore
import Testing
@testable import HECRAS2025

struct WorkspaceRenderScalingTests {
    @Test
    func capturedFactorScalesCanvasMetricsWithoutChangingSourceStyleValues() {
        let source = VectorStyleValues(penColor: "#FF123456", penWidth: 2.5,
                                       fillColor: "#80112233", pointSize: 7)
        let normalArc = GeometryMapStylePresentation.topologyArc(source, selected: false)
        let scaledArc = GeometryMapStylePresentation.topologyArc(source, selected: false, renderScale: 2)
        let normalPoint = GeometryMapStylePresentation.arcInternalPoint(source)
        let scaledPoint = GeometryMapStylePresentation.arcInternalPoint(source, renderScale: 2)

        #expect(normalArc.ink == scaledArc.ink)
        #expect(scaledArc.width == normalArc.width * 2)
        #expect(scaledPoint.fill == normalPoint.fill)
        #expect(scaledPoint.outline == normalPoint.outline)
        #expect(scaledPoint.diameter == normalPoint.diameter * 2)
        #expect(scaledPoint.outlineWidth == normalPoint.outlineWidth * 2)
        #expect(source.penWidth == 2.5)
        #expect(source.pointSize == 7)
        #expect(GeometryMapStylePresentation.sourceNodeDiameter(basePointSize: 9,
            incidentArcs: nil, worldUnitsPerPoint: nil, sourceDefaultPointSize: 5) == 9)
    }

    @Test
    func metricClampsInvalidAndUnrepresentableCanvasValues() {
        #expect(WorkspaceRenderScaling.metric(-2, factor: 3) == 0)
        #expect(WorkspaceRenderScaling.metric(.infinity, factor: 3) == 0)
        #expect(WorkspaceRenderScaling.metric(2, factor: .nan) == 2)
        #expect(WorkspaceRenderScaling.metric(1_000_000, factor: 10) == 1_000_000)
    }
}
