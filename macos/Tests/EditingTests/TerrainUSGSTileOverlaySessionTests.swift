import RASWorkspaceCore
import XCTest
@testable import HECRAS2025

final class TerrainUSGSTileOverlaySessionTests: XCTestCase {
    @MainActor
    func testOnlyCurrentOwnerCanInstallSelectOrClearSnapshot() {
        let session = TerrainUSGSTileOverlaySession()
        let first = makeTicket(owner: UUID(), request: UUID())
        let second = makeTicket(owner: UUID(), request: UUID())

        session.begin(first)
        XCTAssertTrue(session.install(makeSnapshot(for: first), matching: first))
        XCTAssertEqual(session.snapshot?.ticket, first)

        session.begin(second)
        XCTAssertNil(session.snapshot)
        XCTAssertFalse(session.install(makeSnapshot(for: first), matching: first))
        session.clear(matching: first)
        XCTAssertNil(session.snapshot)

        XCTAssertTrue(session.install(makeSnapshot(for: second), matching: second))
        session.select(["different-product"], matching: first)
        XCTAssertEqual(session.snapshot?.selectedProductIDs, ["product"])
        session.clear(matching: first)
        XCTAssertEqual(session.snapshot?.ticket, second)

        session.clear(matching: second)
        XCTAssertNil(session.snapshot)
    }

    func testHitTestChoosesSmallestActualProjectedFootprintAndReportsAllOverlaps() {
        let outer = product("outer", boundary: [
            (0, 0), (10, 0), (10, 10), (0, 10)
        ])
        let inner = product("inner", boundary: [
            (2, 2), (4, 2), (4, 4), (2, 4)
        ])
        let hit = TerrainUSGSTileHitTest.hit(at: MapPoint(x: 3, y: 3), products: [outer, inner])

        XCTAssertEqual(hit?.selected.id, "inner")
        XCTAssertEqual(hit?.overlaps.map(\.id), ["inner", "outer"])
        XCTAssertNil(TerrainUSGSTileHitTest.hit(at: MapPoint(x: 11, y: 11), products: [outer, inner]))
    }

    private func makeTicket(owner: UUID, request: UUID) -> TerrainUSGSTileOverlayTicket {
        TerrainUSGSTileOverlayTicket(ownerID: owner, requestID: request,
            projectSessionID: UUID(), editorID: UUID(), captureID: UUID().uuidString,
            mapID: UUID(), mapWorkflowIdentity: "map-workflow",
            terrainAssetPath: "/tmp/terrain.hdf", terrainSourceRevision: String(repeating: "A", count: 64))
    }

    private func makeSnapshot(for ticket: TerrainUSGSTileOverlayTicket) -> TerrainUSGSTileOverlaySnapshot {
        TerrainUSGSTileOverlaySnapshot(ticket: ticket, targetProjectionWkt: "test-wkt",
            extent: TerrainUSGSQueryExtent(minX: 0, maxX: 1, minY: 0, maxY: 1),
            products: [product("product", boundary: [(0, 0), (1, 0), (1, 1), (0, 1)])],
            selectedProductIDs: ["product"])
    }

    private func product(_ id: String, boundary: [(Double, Double)]) -> TerrainUSGSProduct {
        TerrainUSGSProduct(id: id, title: id, publicationDate: nil, sizeInBytes: nil,
            resolution: "1 m", cellSize: 1, metadataUrl: nil, boundingBox: nil,
            projectedBoundary: boundary.map { TerrainUSGSMapPoint(x: $0.0, y: $0.1) })
    }
}
