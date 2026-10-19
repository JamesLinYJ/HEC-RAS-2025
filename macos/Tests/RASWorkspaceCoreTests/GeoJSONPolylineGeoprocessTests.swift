import Foundation
import RASWorkspaceCore
import XCTest

final class GeoJSONPolylineGeoprocessTests: XCTestCase {
    func testXYTransformReplacesOnlyCoordinatesAndKeepsFeatureIdentity() throws {
        let source = #"{"type":"FeatureCollection","foreign":{"count":7.2500},"features":[{"type":"Feature","id":"route","foreignFeature":{"keep":"yes"},"properties":{"name":"River","rank":8.5000,"nullable":null},"geometry":{"type":"LineString","foreignGeometry":true,"coordinates":[[0,0],[1,0.1],[2,0]]}}]}"#
        var document = try GeoJSONPolylineDocument(data: Data(source.utf8), sourceURL: URL(fileURLWithPath: "/tmp/filter.geojson"))
        let originalLine = try XCTUnwrap(document.lines.first)
        let coordinates = try document.xyCoordinates(lineID: originalLine.id)
        XCTAssertEqual(coordinates, [[0, 0], [1, 0.1], [2, 0]])

        try document.replaceXYCoordinates(lineID: originalLine.id, coordinates: [[0, 0], [2, 0]])
        let output = String(decoding: try document.encoded(), as: UTF8.self)
        XCTAssertEqual(document.lines.first?.id, originalLine.id)
        XCTAssertEqual(document.lines.first?.points, [MapPoint(x: 0, y: 0), MapPoint(x: 2, y: 0)])
        XCTAssertTrue(output.contains("\"foreign\":{\"count\":7.2500}"))
        XCTAssertTrue(output.contains("\"foreignFeature\":{\"keep\":\"yes\"}"))
        XCTAssertTrue(output.contains("\"rank\":8.5000,\"nullable\":null"))
        XCTAssertTrue(output.contains("\"foreignGeometry\":true"))
    }

    func testXYTransformRejectsZAndMWithoutChangingSourceTree() throws {
        let source = #"{"type":"FeatureCollection","features":[{"type":"Feature","id":"route-zm","properties":{"name":"River"},"geometry":{"type":"LineString","coordinates":[[0,0,4,40],[1,1,5,50]]}}]}"#
        var document = try GeoJSONPolylineDocument(data: Data(source.utf8), sourceURL: URL(fileURLWithPath: "/tmp/zm.geojson"))
        let line = try XCTUnwrap(document.lines.first)
        let before = try document.encoded()
        XCTAssertThrowsError(try document.xyCoordinates(lineID: line.id))
        XCTAssertThrowsError(try document.replaceXYCoordinates(lineID: line.id, coordinates: [[0, 0], [1, 1]]))
        XCTAssertEqual(try document.encoded(), before)
    }

    func testXYTransformRejectsInvalidResultCoordinates() throws {
        let source = #"{"type":"Feature","id":"route","properties":{},"geometry":{"type":"LineString","coordinates":[[0,0],[1,1]]}}"#
        var document = try GeoJSONPolylineDocument(data: Data(source.utf8), sourceURL: URL(fileURLWithPath: "/tmp/invalid-transform.geojson"))
        let line = try XCTUnwrap(document.lines.first)
        let before = try document.encoded()
        XCTAssertThrowsError(try document.replaceXYCoordinates(lineID: line.id, coordinates: [[0, 0], [.infinity, 1]]))
        XCTAssertThrowsError(try document.replaceXYCoordinates(lineID: line.id, coordinates: [[1, 1], [1, 1]]))
        XCTAssertThrowsError(try document.replaceXYCoordinates(lineID: line.id, coordinates: [[0, 0], [0.5, 0], [1, 1]]))
        XCTAssertEqual(try document.encoded(), before)
    }
}
