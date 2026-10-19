import Foundation
import XCTest
@testable import RASWorkspaceCore

final class MapVectorInstanceBindingTests: XCTestCase {
    func testMixedGeometryInstancesKeepNodeIdentityAndSourceOrdinals() throws {
        let source = #"{"type":"FeatureCollection","features":[{"type":"Feature","id":"mixed","properties":{"name":"shared"},"geometry":{"type":"GeometryCollection","geometries":[{"type":"Point","coordinates":[1,2]},{"type":"LineString","coordinates":[[0,0],[2,2]]},{"type":"Polygon","coordinates":[[[0,0],[0,4],[4,4],[4,0],[0,0]],[[1,1],[1,2],[2,2],[2,1],[1,1]]]}]}},{"type":"Feature","id":"roads","properties":{"name":"roads"},"geometry":{"type":"MultiLineString","coordinates":[[[10,0],[11,1]],[[20,0],[21,1]]]}},{"type":"Feature","id":"areas","properties":{"name":"areas"},"geometry":{"type":"MultiPolygon","coordinates":[[[[30,0],[30,4],[34,4],[34,0],[30,0]]],[[[40,0],[40,4],[44,4],[44,0],[40,0]]]]}}]}"#
        let sourceData = Data(source.utf8)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("shared-\(UUID().uuidString).geojson")
        let base = try MapVectorLayer(data: sourceData, sourceURL: url)
        let sourcePath = SourceFilePaths.canonical(url)
        let mapID = UUID()

        let firstLine = base.instanced(
            binding: MapVectorInstanceBinding(id: "node-line-a", sourcePath: sourcePath,
                name: "Roads A", kind: .line, isVisible: true),
            sourceMapID: mapID
        )
        let secondLine = base.instanced(
            binding: MapVectorInstanceBinding(id: "node-line-b", sourcePath: sourcePath,
                name: "Roads B", kind: .line, isVisible: false),
            sourceMapID: mapID
        )
        let point = base.instanced(
            binding: MapVectorInstanceBinding(id: "node-point", sourcePath: sourcePath,
                name: "Survey points", kind: .point, isVisible: true),
            sourceMapID: mapID
        )
        let polygon = base.instanced(
            binding: MapVectorInstanceBinding(id: "node-polygon", sourcePath: sourcePath,
                name: "Areas", kind: .polygon, isVisible: true),
            sourceMapID: mapID
        )

        XCTAssertEqual(firstLine.id, "node-line-a")
        XCTAssertEqual(secondLine.id, "node-line-b")
        XCTAssertNotEqual(firstLine.id, secondLine.id)
        XCTAssertEqual(firstLine.name, "Roads A")
        XCTAssertEqual(secondLine.name, "Roads B")
        XCTAssertTrue(firstLine.isSourceVisible)
        XCTAssertFalse(secondLine.isSourceVisible)
        XCTAssertEqual(firstLine.url, base.url)
        XCTAssertEqual(firstLine.sourceRevision, base.sourceRevision)
        XCTAssertEqual(firstLine.sourceMapID, mapID)

        XCTAssertEqual(firstLine.features.map(\.id), [1, 3])
        XCTAssertEqual(firstLine.features.map(\.sourceFeatureIndex), [0, 1])
        XCTAssertEqual(firstLine.features.map(\.geometryPath), ["geometry.geometries[1]", "geometry"])
        XCTAssertEqual(firstLine.features.map(\.stableIdentity), base.features.filter { $0.kind == .line }.map(\.stableIdentity))
        XCTAssertEqual(firstLine.features.map(\.pathStableIdentities), base.features.filter { $0.kind == .line }.map(\.pathStableIdentities))
        XCTAssertEqual(firstLine.features.last?.paths.count, 2)
        XCTAssertEqual(firstLine.features.last?.attributes["name"], "roads")
        XCTAssertEqual(secondLine.features.map(\.sourceFeatureIndex), [0, 1])

        XCTAssertEqual(point.features.map(\.id), [0])
        XCTAssertEqual(point.features.map(\.kind), [.point])
        XCTAssertEqual(point.features.first?.sourceFeatureIndex, 0)

        XCTAssertEqual(polygon.features.map(\.id), [2, 4, 5])
        XCTAssertEqual(polygon.features.map(\.sourceFeatureIndex), [0, 2, 2])
        XCTAssertEqual(polygon.features.first?.paths.count, 2)
        XCTAssertEqual(polygon.features.first?.pathStableIdentities.count, 2)
        XCTAssertEqual(polygon.features.last?.geometryPath, "geometry.coordinates[1]")
        XCTAssertTrue(polygon.features.allSatisfy { $0.kind == .polygon })
        XCTAssertEqual(base.features.map(\.kind), [.point, .line, .polygon, .line, .polygon, .polygon])
    }

    func testInstanceBindingUsesPhysicalSourceAliasWithoutReplacingURLIdentity() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let physicalFolder = folder.appendingPathComponent("physical", isDirectory: true)
        let aliasFolder = folder.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createDirectory(at: physicalFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createSymbolicLink(at: aliasFolder, withDestinationURL: physicalFolder)

        let sourceData = Data(#"{"type":"Feature","id":"one","properties":{},"geometry":{"type":"Point","coordinates":[5,6]}}"#.utf8)
        let physicalURL = physicalFolder.appendingPathComponent("one.geojson")
        let aliasURL = aliasFolder.appendingPathComponent("one.geojson")
        try sourceData.write(to: physicalURL)
        let base = try MapVectorLayer(contentsOf: aliasURL)
        let canonicalPath = SourceFilePaths.canonical(physicalURL)
        let mapID = UUID()
        let instance = base.instanced(
            binding: MapVectorInstanceBinding(id: "map-node-1", sourcePath: canonicalPath,
                name: "Renamed source", kind: .point, isVisible: false),
            sourceMapID: mapID
        )

        XCTAssertEqual(instance.url, aliasURL)
        XCTAssertEqual(instance.id, "map-node-1")
        XCTAssertEqual(instance.name, "Renamed source")
        XCTAssertEqual(instance.sourceMapID, mapID)
        XCTAssertEqual(instance.sourceRevision, base.sourceRevision)
        XCTAssertFalse(instance.isSourceVisible)
        XCTAssertEqual(try Data(contentsOf: physicalURL), sourceData)

        let plainLayer = try MapVectorLayer(data: sourceData, sourceURL: physicalURL)
        XCTAssertEqual(plainLayer.id, physicalURL.standardizedFileURL.path)
        XCTAssertEqual(plainLayer.name, "one")
        XCTAssertTrue(plainLayer.isSourceVisible)
        XCTAssertNil(plainLayer.visualIdentity)
        XCTAssertNil(plainLayer.visualName)
    }
}
