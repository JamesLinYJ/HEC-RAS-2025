import Foundation
import CoreGraphics
import Testing
@testable import HECRAS2025

struct MapOverlayPlacementTests {
    @Test
    func allSourceCornersAnchorAndClampTheOverlayFootprint() throws {
        let canvas = CGSize(width: 240, height: 180)
        let size = CGSize(width: 80, height: 40)
        let cases: [(MapOverlayCorner, CGPoint)] = [
            (.topLeft, CGPoint(x: 0, y: 0)),
            (.topCenter, CGPoint(x: 80, y: 0)),
            (.topRight, CGPoint(x: 160, y: 0)),
            (.bottomLeft, CGPoint(x: 0, y: 140)),
            (.bottomCenter, CGPoint(x: 80, y: 140)),
            (.bottomRight, CGPoint(x: 160, y: 140))
        ]

        for (corner, origin) in cases {
            let input = MapOverlayGeometryInput(id: corner.rawValue,
                placement: MapOverlayPlacement(corner: corner), desiredSize: size,
                isResizable: false)
            let frame = try #require(MapOverlayPlacementSolver.arrange([input], in: canvas).first?.frame)
            #expect(frame.origin == origin)
            #expect(frame.size == size)
        }

        let oversized = MapOverlayGeometryInput(id: "small-canvas",
            placement: MapOverlayPlacement(corner: .bottomRight),
            desiredSize: CGSize(width: 300, height: 200), isResizable: false)
        let frame = try #require(MapOverlayPlacementSolver.arrange([oversized], in: canvas).first?.frame)
        #expect(frame.origin == CGPoint(x: -60, y: -20))
    }

    @Test
    func freePlacementUsesBothFiniteOffsetsAndCollapsedFootprintIsSourceSized() throws {
        let free = MapOverlayGeometryInput(id: "free",
            placement: MapOverlayPlacement(corner: .topRight,
                cornerOffsetX: 12, cornerOffsetY: 18),
            desiredSize: CGSize(width: 40, height: 30), isResizable: false)
        let frame = try #require(MapOverlayPlacementSolver.arrange([free],
            in: CGSize(width: 200, height: 120)).first?.frame)
        #expect(frame.origin == CGPoint(x: 148, y: 18))

        let partialData = Data(#"{"corner":"TopLeft","isCollapsed":false,"stackOrder":0,"cornerOffsetX":9}"#.utf8)
        let partiallySpecified = try JSONDecoder().decode(MapOverlayPlacement.self, from: partialData)
        #expect(partiallySpecified.isDocked)
        #expect(partiallySpecified.isValid)
        let collapsed = MapOverlayGeometryInput(id: "collapsed",
            placement: MapOverlayPlacement(corner: .bottomRight, isCollapsed: true),
            desiredSize: CGSize(width: 240, height: 150), isResizable: true)
        #expect(MapOverlayPlacementSolver.footprint(of: collapsed)
            == MapOverlayPlacementSolver.collapsedPillSize)
    }

    @Test
    func stackInsertionReindexesStableItemsSeparatelyFromRuntimeZOrder() throws {
        let existingA = MapOverlayGeometryInput(id: "a",
            placement: MapOverlayPlacement(corner: .topCenter, stackOrder: 0),
            desiredSize: CGSize(width: 40, height: 20), zIndex: 30)
        let existingB = MapOverlayGeometryInput(id: "b",
            placement: MapOverlayPlacement(corner: .topCenter, stackOrder: 1),
            desiredSize: CGSize(width: 40, height: 20), zIndex: -1)
        let inserted = MapOverlayGeometryInput(id: "inserted",
            placement: MapOverlayPlacement(corner: .bottomRight,
                cornerOffsetX: 0, cornerOffsetY: 0),
            desiredSize: CGSize(width: 40, height: 20), zIndex: 10)

        let changes = MapOverlayPlacementSolver.insertingIntoStack(inserted, at: 1,
            corner: .topCenter, peers: [existingA, existingB])
        #expect(changes.map(\.id) == ["a", "inserted", "b"])
        #expect(changes.map(\.placement.stackOrder) == [0, 1, 2])
        #expect(changes.allSatisfy { $0.placement.isDocked && $0.placement.corner == .topCenter })
        #expect(MapOverlayPlacementSolver.renderingOrder([existingA, existingB, inserted])
            .map(\.id) == ["b", "inserted", "a"])

        let encoded = try JSONEncoder().encode(changes[0].placement)
        let serialized = try #require(String(data: encoded, encoding: .utf8))
        #expect(!serialized.contains("zIndex"))
    }

    @Test
    func aMalformedAppGlobalItemDoesNotEraseOtherPlacementKeys() throws {
        let suite = "MapOverlayPlacementTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let good = MapOverlayPlacement(corner: .bottomCenter, isCollapsed: true,
            stackOrder: 2, cornerOffsetX: 3, cornerOffsetY: 5, width: 240, height: 160)
        MapOverlayPlacementStore.save(good, for: "source-overview", defaults: defaults)
        let savedData = try #require(defaults.dictionary(forKey: MapOverlayPlacementStore.defaultsKey)?["source-overview"] as? Data)
        defaults.set(["source-overview": savedData,
                      "broken-item": Data("{\"corner\":\"not-a-source-corner\"}".utf8)],
                     forKey: MapOverlayPlacementStore.defaultsKey)

        #expect(MapOverlayPlacementStore.load("broken-item", defaults: defaults) == nil)
        #expect(MapOverlayPlacementStore.load("source-overview", defaults: defaults) == good)
    }

    @Test
    func anUnknownAppGlobalRootValueIsLeftUntouched() throws {
        let suite = "MapOverlayPlacementRootTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("unrecognized-app-data-value", forKey: MapOverlayPlacementStore.defaultsKey)

        MapOverlayPlacementStore.save(MapOverlayPlacement(corner: .topLeft),
            for: "source-overview", defaults: defaults)
        MapOverlayPlacementStore.remove("source-overview", defaults: defaults)
        #expect(defaults.string(forKey: MapOverlayPlacementStore.defaultsKey)
            == "unrecognized-app-data-value")
    }

    @Test
    func resizeClampsBothDimensionsToTheOverlayConstraints() {
        let size = MapOverlayPlacementSolver.resized(CGSize(width: 120, height: 90),
            by: CGSize(width: -200, height: 500),
            minimum: CGSize(width: 80, height: 70),
            maximum: CGSize(width: 200, height: 240))
        #expect(size == CGSize(width: 80, height: 240))
    }
}
