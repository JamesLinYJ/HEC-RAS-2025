import Foundation
import RASWorkspaceCore
import XCTest

final class GeoJSONPolylineDocumentTests: XCTestCase {
    func testVertexEditPreservesUnknownMembersTypedPropertiesNullAndExtraOrdinates() throws {
        let source = #"{"type":"FeatureCollection","foreign":{"count":7.2500,"nullable":null,"enabled":true},"features":[{"type":"Feature","id":"route/A","foreignFeature":{"keep":"yes"},"properties":{"name":"Main","nullable":null,"enabled":false,"rank":8.5000},"geometry":{"type":"LineString","foreignGeometry":[1,null],"coordinates":[[0,1,9,90],[2,3,10,100]]}}]}"#
        var document = try GeoJSONPolylineDocument(data: Data(source.utf8), sourceURL: URL(fileURLWithPath: "/tmp/lines.geojson"))
        let line = try XCTUnwrap(document.lines.first)
        XCTAssertTrue(line.canEdit)
        XCTAssertEqual(line.points.count, 2)

        try document.moveVertex(lineID: line.id, vertexIndex: 1, to: MapPoint(x: 4.5, y: -2))
        let output = String(decoding: try document.encoded(), as: UTF8.self)
        XCTAssertTrue(output.contains("\"foreign\":{\"count\":7.2500,\"nullable\":null,\"enabled\":true}"))
        XCTAssertTrue(output.contains("\"foreignFeature\":{\"keep\":\"yes\"}"))
        XCTAssertTrue(output.contains("\"nullable\":null,\"enabled\":false,\"rank\":8.5000"))
        XCTAssertTrue(output.contains("\"foreignGeometry\":[1,null]"))
        XCTAssertTrue(output.contains("[4.5,-2,10,100]"))
    }

    func testMultiLineComponentsRemainIndependentAndInterpolationPreservesDimensions() throws {
        let json = #"{"type":"FeatureCollection","features":[{"type":"Feature","id":42,"properties":{"name":"Bank"},"geometry":{"type":"MultiLineString","coordinates":[[[0,0,10,100],[10,0,20,200]],[[0,5,30,300],[10,5,40,400]]]}}]}"#
        var document = try GeoJSONPolylineDocument(data: Data(json.utf8), sourceURL: URL(fileURLWithPath: "/tmp/banks.geojson"))
        XCTAssertEqual(document.lines.count, 2)
        XCTAssertNotEqual(document.lines[0].id, document.lines[1].id)
        let firstID = document.lines[0].id
        try document.insertVertex(lineID: firstID, after: 0, at: MapPoint(x: 5, y: 2))
        try document.reverse(lineID: firstID)
        let output = String(decoding: try document.encoded(), as: UTF8.self)
        XCTAssertTrue(output.contains("[[10,0,20,200],[5,2,15,150],[0,0,10,100]]"))
        XCTAssertTrue(output.contains("[[0,5,30,300],[10,5,40,400]]"))
    }

    func testDuplicateContentWithoutGeoJSONIDsIsVisibleButNotEditable() throws {
        let json = #"{"type":"FeatureCollection","features":[{"type":"Feature","properties":{"name":"same"},"geometry":{"type":"LineString","coordinates":[[0,0],[1,1]]}},{"type":"Feature","properties":{"name":"same"},"geometry":{"type":"LineString","coordinates":[[0,0],[1,1]]}}]}"#
        let document = try GeoJSONPolylineDocument(data: Data(json.utf8), sourceURL: URL(fileURLWithPath: "/tmp/duplicate.geojson"))
        XCTAssertEqual(document.lines.count, 2)
        XCTAssertEqual(document.lines[0].id, document.lines[1].id)
        XCTAssertFalse(document.lines[0].canEdit)
        XCTAssertFalse(document.lines[1].canEdit)
    }

    func testMapFeatureAndLayerExposeStableSourceAndComponentIdentities() throws {
        let json = #"{"type":"FeatureCollection","features":[{"type":"Feature","id":"multi","properties":{},"geometry":{"type":"MultiLineString","coordinates":[[[0,0],[1,1]],[[2,2],[3,3]]]}}]}"#
        let url = URL(fileURLWithPath: "/tmp/multi.geojson")
        let mapID = UUID()
        let layer = try MapVectorLayer(data: Data(json.utf8), sourceURL: url)
        let attached = MapVectorLayer(url: url, features: layer.features, sourceMapID: mapID, sourceRevision: layer.sourceRevision)
        let feature = try XCTUnwrap(attached.features.first)
        XCTAssertEqual(feature.paths.count, 2)
        XCTAssertEqual(feature.pathStableIdentities.count, 2)
        XCTAssertNotEqual(feature.pathStableIdentities[0], feature.pathStableIdentities[1])
        XCTAssertEqual(feature.sourceFeatureIndex, 0)
        XCTAssertEqual(feature.geometryPath, "geometry")
        XCTAssertTrue(feature.stableIdentity.contains("geojson-id:string:"))
        XCTAssertEqual(attached.sourceMapID, mapID)
        XCTAssertEqual(attached.sourceRevision?.count, 64)
    }

    func testDocumentLinesCarrySourceFeatureAndComponentOrdinals() throws {
        let json = #"{"type":"FeatureCollection","features":[{"type":"Feature","id":"other","properties":{},"geometry":{"type":"Point","coordinates":[9,9]}},{"type":"Feature","id":"multi","properties":{},"geometry":{"type":"MultiLineString","coordinates":[[[0,0],[1,1]],[[2,2],[3,3]]]}}]}"#
        let document = try GeoJSONPolylineDocument(data: Data(json.utf8), sourceURL: URL(fileURLWithPath: "/tmp/lines.geojson"))
        XCTAssertEqual(document.lines.map(\.sourceFeatureOrdinal), [1, 1])
        XCTAssertEqual(document.lines.map(\.componentOrdinal), [0, 1])
        XCTAssertEqual(document.lines.map(\.geometryPath), ["geometry", "geometry"])
    }

    func testSplitMultiLineKeepsStableUnchangedComponentAndInterpolatesZM() throws {
        let json = #"{"type":"FeatureCollection","foreign":{"preserve":true},"features":[{"type":"Feature","id":"banks","properties":{"name":"Banks","rank":2.500},"foreignFeature":{"keep":"yes"},"geometry":{"type":"MultiLineString","coordinates":[[[0,0,10,100],[10,0,20,200]],[[20,0,30,300],[21,0,31,310]]]}}]}"#
        var document = try GeoJSONPolylineDocument(data: Data(json.utf8), sourceURL: URL(fileURLWithPath: "/tmp/split-banks.geojson"))
        let original = document.lines
        let splitIDs = try document.split(lineID: original[0].id, near: MapPoint(x: 5, y: 0), maximumDistance: 0.1)

        XCTAssertEqual(splitIDs.count, 2)
        XCTAssertEqual(document.lines.map(\.id), [splitIDs[0], splitIDs[1], original[1].id])
        let output = String(decoding: try document.encoded(), as: UTF8.self)
        XCTAssertTrue(output.contains("[5,0,15,150]"))
        XCTAssertTrue(output.contains("\"foreign\":{\"preserve\":true}"))
        XCTAssertTrue(output.contains("\"foreignFeature\":{\"keep\":\"yes\"}"))
        XCTAssertTrue(output.contains("\"rank\":2.500"))
    }

    func testSplitAtVertexAndLineStringFeatureMetadataAreRetained() throws {
        let json = #"{"type":"FeatureCollection","features":[{"type":"Feature","id":"route","foreignFeature":7,"properties":{"name":"Route","nullable":null},"geometry":{"type":"LineString","coordinates":[[0,0,1,10],[5,0,2,20],[10,0,3,30]]}},{"type":"Feature","id":"other","properties":{},"geometry":{"type":"LineString","coordinates":[[30,0],[31,0]]}}]}"#
        var document = try GeoJSONPolylineDocument(data: Data(json.utf8), sourceURL: URL(fileURLWithPath: "/tmp/split-route.geojson"))
        let otherID = try XCTUnwrap(document.lines.last?.id)
        let splitIDs = try document.split(lineID: try XCTUnwrap(document.lines.first?.id), near: MapPoint(x: 5, y: 0),
            mode: .atVertex, maximumDistance: 0)

        XCTAssertEqual(document.lines.map(\.id), [splitIDs[0], splitIDs[1], otherID])
        let output = String(decoding: try document.encoded(), as: UTF8.self)
        XCTAssertTrue(output.contains("\"foreignFeature\":7"))
        XCTAssertTrue(output.contains("\"nullable\":null"))
        XCTAssertTrue(output.contains("[5,0,2,20]"))
        XCTAssertTrue(output.contains("\"id\":\"other\""))
    }

    func testMergeReversesConnectedComponentAndLeavesOtherComponentsStable() throws {
        let json = #"{"type":"FeatureCollection","features":[{"type":"Feature","id":"route","properties":{"name":"Route"},"geometry":{"type":"MultiLineString","coordinates":[[[0,0,1,10],[1,0,2,20]],[[2,0,3,30],[1,0,4,40]],[[8,0,5,50],[9,0,6,60]]]}}]}"#
        var document = try GeoJSONPolylineDocument(data: Data(json.utf8), sourceURL: URL(fileURLWithPath: "/tmp/merge-route.geojson"))
        let original = document.lines
        let mergedIDs = try document.merge(lineIDs: [original[1].id, original[0].id], tolerance: 0)

        XCTAssertEqual(mergedIDs, [original[0].id])
        XCTAssertEqual(document.lines.map(\.id), [original[0].id, original[2].id])
        let output = String(decoding: try document.encoded(), as: UTF8.self)
        XCTAssertTrue(output.contains("[[0,0,1,10],[1,0,4,40],[2,0,3,30]]"))
        XCTAssertTrue(output.contains("[[8,0,5,50],[9,0,6,60]]"))
    }

    func testMergeRejectsSeparateFeaturesWithoutChangingEitherFeature() throws {
        let json = #"{"type":"FeatureCollection","features":[{"type":"Feature","id":"one","properties":{"name":"One"},"geometry":{"type":"LineString","coordinates":[[0,0],[1,0]]}},{"type":"Feature","id":"two","properties":{"name":"Two"},"geometry":{"type":"LineString","coordinates":[[1,0],[2,0]]}}]}"#
        var document = try GeoJSONPolylineDocument(data: Data(json.utf8), sourceURL: URL(fileURLWithPath: "/tmp/merge-separate.geojson"))
        let before = try document.encoded()
        XCTAssertThrowsError(try document.merge(lineIDs: document.lines.map(\.id), tolerance: 0))
        XCTAssertEqual(try document.encoded(), before)
    }

    func testEndpointAttachCopiesAllExtraOrdinatesFromChosenEnd() throws {
        let json = #"{"type":"FeatureCollection","features":[{"type":"Feature","id":"bank","properties":{},"geometry":{"type":"LineString","coordinates":[[0,0,7,70],[10,0,9,90]]}}]}"#
        var document = try GeoJSONPolylineDocument(data: Data(json.utf8), sourceURL: URL(fileURLWithPath: "/tmp/attach-endpoint.geojson"))
        let line = try XCTUnwrap(document.lines.first)
        let inserted = try document.attachEndpoint(lineID: line.id, at: MapPoint(x: 12, y: 3), near: MapPoint(x: 10, y: 0), maximumDistance: 0)
        XCTAssertEqual(inserted, 2)
        XCTAssertTrue(String(decoding: try document.encoded(), as: UTF8.self).contains("[12,3,9,90]"))
    }
}
