import Foundation
import RASWorkspaceCore
import XCTest

final class GeoJSONPolylineClipboardTests: XCTestCase {
    func testAddingClipboardLinesPreservesXYXYZAndXYZMOrdinateLayout() throws {
        let source = #"{"type":"FeatureCollection","features":[]}"#
        var document = try GeoJSONPolylineDocument(data: Data(source.utf8),
            sourceURL: URL(fileURLWithPath: "/tmp/clipboard-dimensions.geojson"))

        let xyID = try document.addLine(sourceCoordinates: [
            MapSourceCoordinate(x: 1, y: 2), MapSourceCoordinate(x: 3, y: 4)
        ], hasZ: false, hasM: false)
        let xyzID = try document.addLine(sourceCoordinates: [
            MapSourceCoordinate(x: 5, y: 6, z: 7), MapSourceCoordinate(x: 8, y: 9, z: 10)
        ], hasZ: true, hasM: false)
        let xyzmID = try document.addLine(sourceCoordinates: [
            MapSourceCoordinate(x: 11, y: 12, z: 13, m: 14), MapSourceCoordinate(x: 15, y: 16, z: 17, m: 18)
        ], hasZ: true, hasM: true)

        XCTAssertEqual(Set([xyID, xyzID, xyzmID]).count, 3)
        let encoded = String(decoding: try document.encoded(), as: UTF8.self)
        XCTAssertTrue(encoded.contains("[1,2]"))
        XCTAssertTrue(encoded.contains("[5,6,7]"))
        XCTAssertTrue(encoded.contains("[11,12,13,14]"))
        XCTAssertEqual(document.lines.count, 3)
    }

    func testMOnlyAndNonFiniteDimensionsAreRefusedWithoutChangingDocument() throws {
        let source = #"{"type":"FeatureCollection","features":[]}"#
        var document = try GeoJSONPolylineDocument(data: Data(source.utf8),
            sourceURL: URL(fileURLWithPath: "/tmp/clipboard-invalid-dimensions.geojson"))
        let baseline = try document.encoded()

        XCTAssertThrowsError(try document.addLine(sourceCoordinates: [
            MapSourceCoordinate(x: 1, y: 2, m: 3), MapSourceCoordinate(x: 4, y: 5, m: 6)
        ], hasZ: false, hasM: true))
        XCTAssertThrowsError(try document.addLine(sourceCoordinates: [
            MapSourceCoordinate(x: 1, y: 2, z: .nan), MapSourceCoordinate(x: 4, y: 5, z: 6)
        ], hasZ: true, hasM: false))
        XCTAssertEqual(try document.encoded(), baseline)
    }
}
