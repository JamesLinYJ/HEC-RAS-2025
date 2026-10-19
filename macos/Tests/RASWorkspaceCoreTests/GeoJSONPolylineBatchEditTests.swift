import Foundation
import RASWorkspaceCore
import XCTest

final class GeoJSONPolylineBatchEditTests: XCTestCase {
    func testBatchMovePreservesExtraOrdinatesAndUnknownGeoJSONMembers() throws {
        let json = #"{"type":"FeatureCollection","foreign":{"keep":true},"features":[{"type":"Feature","id":"route","properties":{"rank":2.500},"foreignFeature":"keep","geometry":{"type":"LineString","coordinates":[[0,0,0,0],[5,0,10,100],[10,0,20,200],[15,0,30,300]]}}]}"#
        var document = try GeoJSONPolylineDocument(data: Data(json.utf8), sourceURL: URL(fileURLWithPath: "/tmp/batch-move.geojson"))
        let line = try XCTUnwrap(document.lines.first)

        let selected = try document.moveVertices(lineID: line.id, vertexIndices: [1, 2],
            by: MapPoint(x: 2, y: 3), duplicateTolerance: 0, interactionPoint: MapPoint(x: 7, y: 3))

        XCTAssertEqual(selected, [1, 2])
        let output = String(decoding: try document.encoded(), as: UTF8.self)
        XCTAssertTrue(output.contains("[7,3,10,100]"))
        XCTAssertTrue(output.contains("[12,3,20,200]"))
        XCTAssertTrue(output.contains("\"foreign\":{\"keep\":true}"))
        XCTAssertTrue(output.contains("\"foreignFeature\":\"keep\""))
        XCTAssertTrue(output.contains("\"rank\":2.500"))
    }

    func testBatchMoveCollapsesMovedPointAtSourceDuplicateTolerance() throws {
        let json = #"{"type":"FeatureCollection","foreign":7,"features":[{"type":"Feature","id":"route","properties":{},"geometry":{"type":"LineString","coordinates":[[0,0,0,0],[5,0,1,10],[10,0,2,20],[20,0,3,30]]}}]}"#
        var document = try GeoJSONPolylineDocument(data: Data(json.utf8), sourceURL: URL(fileURLWithPath: "/tmp/batch-collapse.geojson"))
        let line = try XCTUnwrap(document.lines.first)

        let selection = try document.moveVertices(lineID: line.id, vertexIndices: [1],
            by: MapPoint(x: 5, y: 0), duplicateTolerance: 0.1, interactionPoint: MapPoint(x: 10, y: 0))

        XCTAssertTrue(selection.isEmpty, "Source duplicate collapse clears the point selection")
        XCTAssertEqual(document.lines.first?.points.count, 3)
        let output = String(decoding: try document.encoded(), as: UTF8.self)
        XCTAssertFalse(output.contains("[10,0,1,10]"))
        XCTAssertTrue(output.contains("[10,0,2,20]"))
        XCTAssertTrue(output.contains("\"foreign\":7"))
    }

    func testBatchDeleteKeepsSourceNextPointSelectionAndRejectsInvalidLine() throws {
        let json = #"{"type":"FeatureCollection","foreign":{"keep":true},"features":[{"type":"Feature","id":"route","properties":{"name":"Route"},"foreignFeature":true,"geometry":{"type":"LineString","coordinates":[[0,0,0,0],[1,1,1,10],[2,2,2,20],[3,3,3,30],[4,4,4,40]]}}]}"#
        var document = try GeoJSONPolylineDocument(data: Data(json.utf8), sourceURL: URL(fileURLWithPath: "/tmp/batch-delete.geojson"))
        let line = try XCTUnwrap(document.lines.first)

        let result = try document.deleteVertices(lineID: line.id, vertexIndices: [1, 3])
        XCTAssertFalse(result.lineDeleted)
        XCTAssertEqual(result.selectedVertexIndex, 1)
        XCTAssertEqual(try XCTUnwrap(document.lines.first?.points), [MapPoint(x: 0, y: 0), MapPoint(x: 2, y: 2), MapPoint(x: 4, y: 4)])
        let afterDelete = try document.encoded()
        XCTAssertTrue(String(decoding: afterDelete, as: UTF8.self).contains("\"foreignFeature\":true"))

        XCTAssertThrowsError(try document.deleteVertices(lineID: line.id, vertexIndices: [0, 1]))
        XCTAssertEqual(try document.encoded(), afterDelete, "Rejected invalid deletion must leave the AST unchanged")
    }

    func testDeletingEveryPointRemovesOnlyTheEditableLineFromItsGeoJSONOwner() throws {
        let json = #"{"type":"FeatureCollection","foreign":{"keep":true},"features":[{"type":"Feature","id":"route","properties":{"name":"Route"},"foreignFeature":"keep","geometry":{"type":"MultiLineString","coordinates":[[[0,0],[1,1]],[[10,10],[11,11]]]}}]}"#
        var document = try GeoJSONPolylineDocument(data: Data(json.utf8), sourceURL: URL(fileURLWithPath: "/tmp/delete-component.geojson"))
        let original = document.lines

        let deleted = try document.deleteVertices(lineID: original[0].id, vertexIndices: [0, 1])

        XCTAssertTrue(deleted.lineDeleted)
        XCTAssertEqual(document.lines.map(\.id), [original[1].id])
        let output = String(decoding: try document.encoded(), as: UTF8.self)
        XCTAssertTrue(output.contains("\"foreign\":{\"keep\":true}"))
        XCTAssertTrue(output.contains("\"foreignFeature\":\"keep\""))
    }

    func testDeletingLastMultiLineComponentRemovesParentFeatureAndPreservesCollectionAst() throws {
        let json = #"{"type":"FeatureCollection","foreignCollection":{"keep":true},"features":[{"type":"Feature","id":"route","properties":{"name":"Route","foreignProperty":[1,true]},"foreignFeature":{"keep":"route metadata"},"geometry":{"type":"MultiLineString","foreignGeometry":9,"coordinates":[[[0,0],[1,1]]] }},{"type":"Feature","id":"marker","properties":{"keep":"unrelated feature"},"geometry":{"type":"Point","coordinates":[20,30]}}]}"#
        var document = try GeoJSONPolylineDocument(data: Data(json.utf8), sourceURL: URL(fileURLWithPath: "/tmp/delete-last-component.geojson"))
        let line = try XCTUnwrap(document.lines.first)

        let deletion = try document.deleteVertices(lineID: line.id, vertexIndices: [0, 1])

        XCTAssertTrue(deletion.lineDeleted)
        XCTAssertTrue(document.lines.isEmpty)
        let output = String(decoding: try document.encoded(), as: UTF8.self)
        XCTAssertFalse(output.contains("\"id\":\"route\""))
        XCTAssertFalse(output.contains("MultiLineString"), "Do not leave a parent geometry with an empty component list")
        XCTAssertTrue(output.contains("\"foreignCollection\":{\"keep\":true}"))
        XCTAssertTrue(output.contains("\"id\":\"marker\""))
        XCTAssertTrue(output.contains("\"keep\":\"unrelated feature\""))
    }
}
