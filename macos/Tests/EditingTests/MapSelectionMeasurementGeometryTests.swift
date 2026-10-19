import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

struct MapSelectionMeasurementGeometryTests {
    @Test
    func measurementUsesTheSourcePlanarLengthAndPolygonAreaAlgorithms() {
        let line = [MapPoint(x: 0, y: 0), MapPoint(x: 3, y: 4), MapPoint(x: 3, y: 8)]
        #expect(MapSelectionMeasurementGeometry.length(line) == 9)

        let square = [MapPoint(x: 0, y: 0), MapPoint(x: 2, y: 0),
                      MapPoint(x: 2, y: 2), MapPoint(x: 0, y: 2)]
        #expect(abs(MapSelectionMeasurementGeometry.area(square)) == 4)
        #expect(MapSelectionMeasurementGeometry.threeSignificantFigures(1234) == "1,234")
    }

    @Test
    func extentIntersectsAndContainedMatchSourceGeometryQueries() {
        let extent = [MapPoint(x: 0, y: 0), MapPoint(x: 1, y: 1)]
        let crossingLine = feature("crossing", .line, [[MapPoint(x: -1, y: 0.5), MapPoint(x: 2, y: 0.5)]])
        let containedLine = feature("inside", .line, [[MapPoint(x: 0.2, y: 0.2), MapPoint(x: 0.8, y: 0.8)]])
        let point = feature("point", .point, [[MapPoint(x: 0.5, y: 0.5)]])

        #expect(MapSelectionMeasurementGeometry.intersects(crossingLine, toolID: "Map.SelectExtent",
            points: extent, hitMode: .intersects))
        #expect(!MapSelectionMeasurementGeometry.intersects(crossingLine, toolID: "Map.SelectExtent",
            points: extent, hitMode: .contained))
        #expect(MapSelectionMeasurementGeometry.intersects(containedLine, toolID: "Map.SelectExtent",
            points: extent, hitMode: .contained))
        #expect(MapSelectionMeasurementGeometry.intersects(point, toolID: "Map.SelectExtent",
            points: extent, hitMode: .contained))
    }

    @Test
    func pathAndLassoSelectOnlyFeaturesCrossedOrInsideTheDrawnGeometry() {
        let stroke = [MapPoint(x: 0, y: 0.5), MapPoint(x: 1, y: 0.5)]
        let crossing = feature("crossing", .line, [[MapPoint(x: 0.5, y: 0), MapPoint(x: 0.5, y: 1)]])
        let lasso = [MapPoint(x: 0, y: 0), MapPoint(x: 2, y: 0), MapPoint(x: 2, y: 2), MapPoint(x: 0, y: 2)]
        let inside = feature("inside", .polygon, [[MapPoint(x: 0.5, y: 0.5), MapPoint(x: 1.5, y: 0.5),
                                                   MapPoint(x: 1.5, y: 1.5), MapPoint(x: 0.5, y: 1.5)]])
        let outside = feature("outside", .polygon, [[MapPoint(x: 3, y: 3), MapPoint(x: 4, y: 3),
                                                     MapPoint(x: 4, y: 4), MapPoint(x: 3, y: 4)]])

        #expect(MapSelectionMeasurementGeometry.intersects(crossing, toolID: "Map.SelectPath",
            points: stroke, hitMode: .intersects))
        #expect(MapSelectionMeasurementGeometry.isValidLasso(lasso))
        #expect(MapSelectionMeasurementGeometry.intersects(inside, toolID: "Map.SelectLasso",
            points: lasso, hitMode: .contained))
        #expect(!MapSelectionMeasurementGeometry.intersects(outside, toolID: "Map.SelectLasso",
            points: lasso, hitMode: .intersects))
    }

    private func feature(_ identity: String, _ kind: MapFeature.Kind,
                         _ paths: [[MapPoint]]) -> MapFeature {
        MapFeature(id: 0, kind: kind, paths: paths, attributes: [:], stableIdentity: identity)
    }
}
