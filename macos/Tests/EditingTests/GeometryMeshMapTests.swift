import Foundation
import SwiftUI
import Testing
@testable import HECRAS2025

struct GeometryMeshMapTests {
    @Test func projectionPreservesSourceCoordinatesAndCameraTransform() throws {
        let extent = GeometryTopologyExtent(minX: 100, minY: 200, maxX: 140, maxY: 220)
        let projection = try #require(GeometryMeshMapProjection(extent: extent,
            size: CGSize(width: 420, height: 240), zoom: 1.5, pan: CGSize(width: 14, height: -9)))
        let source = GeometryTopologyCoordinate(x: 127.25, y: 213.5)
        let screen = projection.project(source)
        let roundTrip = try #require(projection.coordinate(at: screen))
        #expect(abs(roundTrip.x - source.x) < 1e-9)
        #expect(abs(roundTrip.y - source.y) < 1e-9)

        let west = projection.project(.init(x: 100, y: 210))
        let east = projection.project(.init(x: 140, y: 210))
        let south = projection.project(.init(x: 120, y: 200))
        let north = projection.project(.init(x: 120, y: 220))
        #expect(west.x < east.x)
        #expect(north.y < south.y)
    }

    @Test func mapPathsKeepTopologyHolesEmptyAndMapCellsKeepSourceOrdinals() throws {
        let extent = GeometryTopologyExtent(minX: 0, minY: 0, maxX: 10, maxY: 10)
        let projection = try #require(GeometryMeshMapProjection(extent: extent,
            size: CGSize(width: 220, height: 220), zoom: 1, pan: .zero))
        let outer = [
            GeometryTopologyCoordinate(x: 0, y: 0), .init(x: 10, y: 0),
            .init(x: 10, y: 10), .init(x: 0, y: 10)
        ]
        let hole = [
            GeometryTopologyCoordinate(x: 3, y: 3), .init(x: 7, y: 3),
            .init(x: 7, y: 7), .init(x: 3, y: 7)
        ]
        let regionPath = GeometryMeshMapPath.make(paths: [outer, hole], projection: projection, close: true)
        #expect(regionPath.contains(projection.project(.init(x: 1, y: 1)), eoFill: true))
        #expect(!regionPath.contains(projection.project(.init(x: 5, y: 5)), eoFill: true))

        let cell = GeometryMeshMapCell(id: "flow-area-row:2:cell:37", flowAreaID: "flow-area-row:2",
            flowAreaName: "Channel", meshIndex: 2, cellIndex: 37, coordinates: outer)
        #expect(cell.id == cell.flowAreaID + ":cell:" + String(cell.cellIndex))
        #expect(cell.meshIndex == 2 && cell.cellIndex == 37)
        #expect(cell.id != "region:37")
    }
}
