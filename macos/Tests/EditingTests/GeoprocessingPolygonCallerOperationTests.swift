import XCTest
@testable import HECRAS2025

final class GeoprocessingPolygonCallerOperationTests: XCTestCase {
    func testPolygonBoundaryCallersReuseFilterAndSmoothPolylineAlgorithms() {
        XCTAssertEqual(GeoprocessingPolylineOperation.filterPolygonBoundaries.backendOperation.rawValue, "Filter")
        XCTAssertEqual(GeoprocessingPolylineOperation.smoothPolygonBoundaries.backendOperation.rawValue, "Smooth")
        XCTAssertEqual(GeoprocessingPolylineOperation.filterPolygonBoundaries.inputGeometryKind, .polygon)
        XCTAssertEqual(GeoprocessingPolylineOperation.smoothPolygonBoundaries.inputGeometryKind, .polygon)
        XCTAssertFalse(GeoprocessingPolylineOperation.filterPolygonBoundaries.isSourceOperation)
        XCTAssertFalse(GeoprocessingPolylineOperation.smoothPolygonBoundaries.isSourceOperation)
        XCTAssertEqual(GeoprocessingPolylineOperation.filterPolygonBoundaries.outputTitle, "Filtered Polylines")
        XCTAssertEqual(GeoprocessingPolylineOperation.smoothPolygonBoundaries.outputTitle, "Smoothed Lines")
    }
}
