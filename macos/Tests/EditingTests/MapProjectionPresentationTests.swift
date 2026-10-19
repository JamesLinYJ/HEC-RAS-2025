import XCTest
@testable import HECRAS2025
import RASWorkspaceCore

final class MapProjectionPresentationTests: XCTestCase {
    func testWheelZoomKeepsWorldPointUnderPointerFixed() throws {
        let points = [MapPoint(x: -20, y: 40), MapPoint(x: 180, y: 240)]
        let size = CGSize(width: 920, height: 640)
        let offset = CGSize(width: 38, height: -27)
        let pointer = CGPoint(x: 231, y: 487)
        let before = MapTransform(points: points, size: size, scale: 1.4, offset: offset).world(pointer)
        let update = try XCTUnwrap(MapPointerCamera.wheelZoom(scale: 1.4, offset: offset,
            canvasSize: size, pointer: pointer, delta: 120))
        let after = MapTransform(points: points, size: size, scale: update.scale, offset: update.offset).world(pointer)

        XCTAssertEqual(after.x, before.x, accuracy: 1e-10)
        XCTAssertEqual(after.y, before.y, accuracy: 1e-10)
        XCTAssertEqual(update.scale, 1.75, accuracy: 1e-12)
    }

    func testWheelZoomRetainsOriginalOneStepZoomOutLimitAndScaleBounds() throws {
        let size = CGSize(width: 800, height: 600)
        let pointer = CGPoint(x: 300, y: 200)
        let zoomOut = try XCTUnwrap(MapPointerCamera.wheelZoom(scale: 1, offset: .zero,
            canvasSize: size, pointer: pointer, delta: -1_200))
        XCTAssertEqual(zoomOut.scale, 0.75, accuracy: 1e-12)

        let zoomIn = try XCTUnwrap(MapPointerCamera.wheelZoom(scale: 255, offset: .zero,
            canvasSize: size, pointer: pointer, delta: 120))
        XCTAssertEqual(zoomIn.scale, MapPointerCamera.maximumScale)
    }

    func testPanAppliesScreenTranslationExactlyOnceAndRejectsNonfiniteValues() throws {
        let result = try XCTUnwrap(MapPointerCamera.pan(offset: CGSize(width: 12, height: -7),
            by: CGSize(width: -25, height: 42)))
        XCTAssertEqual(result, CGSize(width: -13, height: 35))
        XCTAssertNil(MapPointerCamera.pan(offset: .zero, by: CGSize(width: CGFloat.infinity, height: 1)))
    }

    func testWheelZoomRunsOnlyWhenSourceToolIsIdle() {
        XCTAssertTrue(MapCanvasNavigation.allowsWheelZoom(toolIsActive: false))
        XCTAssertFalse(MapCanvasNavigation.allowsWheelZoom(toolIsActive: true))
    }

    func testProjectedFootMetadataOverridesProjectUnitSetting() throws {
        let units = MapProjectionUnits.from(evaluation(
            units: "SI", unitName: "Feet", normalizedType: "EPSG", normalizedValue: "2263",
            isProjected: true, wkt: nil))
        XCTAssertEqual(units.coordinateLabel, "ft")
        let extent = ViewportRequest(lowerLeft: MapPoint(x: 0, y: 0), upperRight: MapPoint(x: 20_000, y: 10_000), animated: false)
        let metric = try XCTUnwrap(MapScaleBarMeasurement.calculate(extent: extent, canvasWidth: 1_000, units: units))
        XCTAssertEqual(metric.unitLabel, "ft")
        XCTAssertEqual(metric.distance, 2_000, accuracy: 1e-12)
    }

    func testLocalProjectUnitsComeFromProjectionEvaluation() {
        let si = MapProjectionUnits.from(evaluation(
            units: "SI", unitName: "SI", normalizedType: "Local", normalizedValue: "SI", isProjected: nil, wkt: nil))
        let us = MapProjectionUnits.from(evaluation(
            units: "USC", unitName: "USC", normalizedType: "Local", normalizedValue: "USC", isProjected: nil, wkt: nil))
        XCTAssertEqual(si.coordinateLabel, "m")
        XCTAssertEqual(us.coordinateLabel, "ft")
    }

    func testGeographicScaleUsesActualEllipsoidAndLatitude() throws {
        let wkt = #"GEOGCRS["WGS 84",DATUM["World Geodetic System 1984",ELLIPSOID["WGS 84",6378137,298.257223563,LENGTHUNIT["metre",1]]],CS[ellipsoidal,2],ANGLEUNIT["degree",0.0174532925199433]]"#
        let units = MapProjectionUnits.from(evaluation(
            units: "SI", unitName: "Degrees", normalizedType: "EPSG", normalizedValue: "4326",
            isProjected: false, wkt: wkt))
        XCTAssertEqual(units.coordinateLabel, "°")
        let equatorMeters = try XCTUnwrap(units.eastWestMetersPerCoordinate(atY: 0))
        let sixtyDegreeMeters = try XCTUnwrap(units.eastWestMetersPerCoordinate(atY: 60))
        XCTAssertEqual(equatorMeters, 111_319.490793, accuracy: 0.01)
        XCTAssertEqual(sixtyDegreeMeters / equatorMeters, 0.5, accuracy: 0.002)

        let equatorExtent = ViewportRequest(lowerLeft: MapPoint(x: 0, y: 0), upperRight: MapPoint(x: 1, y: 0), animated: false)
        let metric = try XCTUnwrap(MapScaleBarMeasurement.calculate(extent: equatorExtent, canvasWidth: 1_000, units: units))
        XCTAssertEqual(metric.unitLabel, "km")
        XCTAssertEqual(metric.distance, 20, accuracy: 1e-12)
    }

    func testScaleBarIsUnavailableWhenProjectionUnitsAreUnavailable() {
        let units = MapProjectionUnits.from(evaluation(
            units: "SI", unitName: nil, normalizedType: "WKT", normalizedValue: "",
            isProjected: nil, wkt: nil))
        let extent = ViewportRequest(lowerLeft: MapPoint(x: 0, y: 0), upperRight: MapPoint(x: 100, y: 100), animated: false)
        XCTAssertNil(MapScaleBarMeasurement.calculate(extent: extent, canvasWidth: 500, units: units))
    }

    func testToolTipPlacementKeepsAnnotationInsideMapCanvas() throws {
        let position = try XCTUnwrap(MapToolTipPlacement.position(
            pointer: CGPoint(x: 992, y: 691), canvasSize: CGSize(width: 1_000, height: 700),
            panelSize: CGSize(width: 260, height: 88)))
        XCTAssertGreaterThanOrEqual(position.x - 130, 8)
        XCTAssertLessThanOrEqual(position.x + 130, 992)
        XCTAssertGreaterThanOrEqual(position.y - 44, 8)
        XCTAssertLessThanOrEqual(position.y + 44, 692)
    }

    private func evaluation(units: String?, unitName: String?, normalizedType: String,
                            normalizedValue: String, isProjected: Bool?, wkt: String?) -> ProjectionEvaluation {
        ProjectionEvaluation(isValid: true, name: "Map CRS", units: units, unitName: unitName,
            epsgCode: nil, utmZone: nil, wkt: wkt, error: nil,
            normalizedType: normalizedType, normalizedValue: normalizedValue,
            validity: "Valid", isVertical: false, isProjected: isProjected, areaOfUse: nil)
    }
}
