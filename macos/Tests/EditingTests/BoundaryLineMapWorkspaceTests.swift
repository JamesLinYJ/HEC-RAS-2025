import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

struct BoundaryLineMapWorkspaceTests {
    @Test
    func viewportTransformRoundTripsWorldCoordinatesAfterZoomAndPan() throws {
        let sourceLine = line("line-a", points: [
            .init(x: 10, y: 20), .init(x: 35, y: 27), .init(x: 42, y: 70)
        ])
        let transform = BoundaryLineMapTransform(
            lines: [sourceLine], size: CGSize(width: 780, height: 420),
            zoomFactor: 2.25, panOffset: CGSize(width: 31, height: -18)
        )
        let sourceCoordinate = BoundaryLineCoordinate(x: 29.25, y: 42.5)
        let screenPoint = try #require(transform.screenPoint(for: sourceCoordinate))
        let roundTrip = try #require(transform.coordinate(at: screenPoint))

        #expect(abs(roundTrip.x - sourceCoordinate.x) < 1e-9)
        #expect(abs(roundTrip.y - sourceCoordinate.y) < 1e-9)
    }

    @Test
    func transformedHitTestingAndMidpointKeepOriginalFeatureOrder() throws {
        // The first source feature has no usable polyline, but it still occupies
        // feature index 0. Map drawing filters it; source hover labels must not.
        let missingGeometry = line("line-no-geometry", points: nil)
        let sourceLine = line("line-second", points: [
            .init(x: 0, y: 0), .init(x: 10, y: 0), .init(x: 10, y: 10)
        ])
        let allSourceLines = [missingGeometry, sourceLine]
        let drawableLines = [sourceLine]
        let transform = BoundaryLineMapTransform(
            lines: drawableLines, size: CGSize(width: 640, height: 360),
            zoomFactor: 1.6, panOffset: CGSize(width: -23, height: 14)
        )
        let midpoint = try #require(transform.midpoint(for: sourceLine))
        let expectedMidpoint = try #require(transform.screenPoint(for: .init(x: 10, y: 0)))
        let hit = transform.hitTest(expectedMidpoint, lines: drawableLines, tolerance: 0.5)

        #expect(abs(midpoint.x - expectedMidpoint.x) < 1e-9)
        #expect(abs(midpoint.y - expectedMidpoint.y) < 1e-9)
        #expect(hit == sourceLine.id)
        #expect(BoundaryLineMapTransform.sourceFeatureIndex(for: sourceLine.id, in: allSourceLines) == 1)
    }

    @Test
    func hitTestingUsesViewportCoordinatesAndRejectsDistantPointer() throws {
        let sourceLine = line("line-c", points: [.init(x: -5, y: 4), .init(x: 15, y: 4)])
        let transform = BoundaryLineMapTransform(
            lines: [sourceLine], size: CGSize(width: 500, height: 300),
            zoomFactor: 0.75, panOffset: CGSize(width: 90, height: 45)
        )
        let onLine = try #require(transform.screenPoint(for: .init(x: 4, y: 4)))
        let distant = CGPoint(x: onLine.x, y: onLine.y + 80)

        #expect(transform.hitTest(onLine, lines: [sourceLine], tolerance: 1) == sourceLine.id)
        #expect(transform.hitTest(distant, lines: [sourceLine], tolerance: 1) == nil)
    }

    @Test
    func mapStyleInjectionReadsARGBAndRetainsConditionalOverrideState() throws {
        let settings = BoundaryLineVisualSettings(
            line: .init(penColor: "#400A80F0", penWidth: 5.5, fillColor: "#FF000000", pointSize: 3),
            vertex: .init(penColor: "#FF010203", penWidth: 2, fillColor: "#800000FF", pointSize: 7),
            hasConditionalOverrides: true
        )
        let style = try #require(BoundaryLineMapStyle(settings: settings))
        let decoded = try #require(BoundaryARGBColor.decode(settings.line.penColor))

        #expect(style.lineWidth == 5.5)
        #expect(style.vertexPenWidth == 2)
        #expect(style.vertexSize == 7)
        #expect(style.hasConditionalOverrides)
        #expect(BoundaryARGBColor.encode(decoded) == "#400A80F0")
    }

    private func line(_ id: String, points: [BoundaryLineCoordinate]?) -> BoundaryLinePresentation {
        BoundaryLinePresentation(
            id: id, scope: "Boundary/\(id)", name: id, payloads: [], geometry: points
        )
    }
}
