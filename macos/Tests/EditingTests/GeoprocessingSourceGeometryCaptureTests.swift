import CryptoKit
import Foundation
import XCTest
@testable import HECRAS2025
import RASWorkspaceCore

final class GeoprocessingSourceGeometryCaptureTests: XCTestCase {
    func testGeoJSONGeometryCollectionAndMultiPolygonResolveExactComponentsAndDimensions() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("geoprocessing-geometry-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("source.geojson")
        let source = """
        {"type":"FeatureCollection","features":[{"type":"Feature","id":"poly","properties":{},"geometry":{"type":"GeometryCollection","geometries":[{"type":"Polygon","coordinates":[[[0,0,1,11],[8,0,2,12],[8,8,3,13],[0,8,4,14],[0,0,1,11]],[[2,2],[2,3],[3,3],[3,2],[2,2]]]},{"type":"MultiPolygon","coordinates":[[[[10,0],[12,0],[12,2],[10,2],[10,0]]],[[[20,0,7],[22,0,8],[22,2,9],[20,2,10],[20,0,7]]]]}]}}]}
        """
        try Data(source.utf8).write(to: url)

        let layer = try MapVectorLayer(contentsOf: url)
        let polygons = try GeoprocessingSourceGeometryCapture.polygons(from: layer)

        XCTAssertEqual(polygons.count, 3)
        XCTAssertEqual(polygons.map(\.sourceFeatureIndex), [0, 0, 0])
        XCTAssertEqual(polygons[0].holes.count, 1)
        XCTAssertEqual(polygons[0].zValues, ["1.0", "2.0", "3.0", "4.0", "1.0"])
        XCTAssertEqual(polygons[0].mValues, ["11.0", "12.0", "13.0", "14.0", "11.0"])
        XCTAssertNil(polygons[0].holeZValues?.first ?? nil)
        XCTAssertEqual(polygons.map(\.pathIdentity).count, Set(polygons.map(\.pathIdentity)).count)
        let firstMultiPolygon = try XCTUnwrap(layer.features.first {
            $0.kind == .polygon && $0.geometryPath == "geometry.geometries[1].coordinates[0]"
        })
        let originalPathIdentity = try XCTUnwrap(firstMultiPolygon.pathStableIdentities.first)
        XCTAssertEqual(polygons[1].pathIdentity, originalPathIdentity,
                       "Capture must preserve the complete path identity for source geometry path \(firstMultiPolygon.geometryPath ?? "<missing>").")
        XCTAssertEqual(polygons[2].zValues, ["7.0", "8.0", "9.0", "10.0", "7.0"])
    }

    func testShapefileRingContainmentPreservesOuterHoleIslandAndNullRingDimensions() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("geoprocessing-rings-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("rings.shp")
        let bytes = Data([0x52, 0x49, 0x4E, 0x47])
        try bytes.write(to: url)

        func ring(_ min: Double, _ max: Double) -> [MapPoint] {
            [MapPoint(x: min, y: min), MapPoint(x: max, y: min), MapPoint(x: max, y: max),
             MapPoint(x: min, y: max), MapPoint(x: min, y: min)]
        }
        let paths = [ring(0, 10), ring(2, 8), ring(3, 4), ring(20, 30)]
        let sourcePaths = paths.enumerated().map { ringIndex, path in
            path.map { point in
                MapSourceCoordinate(x: point.x, y: point.y,
                    z: ringIndex == 1 ? nil : point.x + point.y,
                    m: ringIndex == 1 ? nil : point.x - point.y)
            }
        }
        let feature = MapFeature(id: 0, kind: .polygon, paths: paths, attributes: [:],
            stableIdentity: "record:0", pathStableIdentities: (0..<4).map { "record:0|part:\($0)" },
            sourceFeatureIndex: 0, geometryPath: "shape.parts", sourceCoordinatePaths: sourcePaths)
        let revision = SHA256.hash(data: bytes).map { String(format: "%02X", $0) }.joined()
        let layer = MapVectorLayer(url: url, features: [feature], sourceRevision: revision)

        let polygons = try GeoprocessingSourceGeometryCapture.polygons(from: layer)

        XCTAssertEqual(polygons.map(\.pathIndex), [0, 2, 3])
        XCTAssertEqual(polygons[0].holes.count, 1)
        XCTAssertEqual(polygons[0].holes[0], paths[1].map { [$0.x, $0.y] })
        XCTAssertEqual(polygons[0].holeZValues?.count, 1)
        XCTAssertNil(polygons[0].holeZValues?.first ?? nil)
        XCTAssertNotNil(polygons[0].zValues)
        XCTAssertNotNil(polygons[1].zValues)
        XCTAssertEqual(polygons[1].holes.count, 0)
        XCTAssertEqual(polygons[2].holes.count, 0)
    }
}
