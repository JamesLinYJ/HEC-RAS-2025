import Foundation
import Testing
@testable import HECRAS2025

struct MapDynamicProfileChartFacetTests {
    @Test
    func terrainAndDifferentResultQuantitiesNeverSharePhysicalAxis() throws {
        let line = profileFacetLine(id: "line", distances: [0, 1, 2], series: [
            profileFacetSeries(id: "terrain", kind: "Terrain", mapType: "Depth", units: "ft"),
            profileFacetSeries(id: "depth", mapType: "Depth", units: "ft"),
            profileFacetSeries(id: "velocity", mapType: "Velocity", units: "ft/s"),
            profileFacetSeries(id: "wse", mapType: "WaterSurfaceElevation", units: "ft")
        ])
        let projection = MapDynamicProfileChartProjection(lines: [line])
        #expect(projection.facets.count == 3)
        #expect(projection.facets.map(\.id.quantity) == [.elevation, .depth, .velocity])
        let elevation = try #require(projection.facets.first { $0.id.quantity == .elevation })
        #expect(elevation.seriesIDs == ["terrain", "wse"])
        #expect(elevation.samples.allSatisfy { ["terrain", "wse"].contains($0.datasetKey) })
        #expect(projection.distanceDomain == 0...2)
    }

    @Test
    func sourceProfileSeparatesDifferentUnitsAndUnknownQuantitiesWithoutConvertingSamples() throws {
        let line = profileFacetLine(id: "line", distances: [0, 1, 2], series: [
            profileFacetSeries(id: "depth-ft", mapType: "Depth", units: "ft"),
            profileFacetSeries(id: "depth-m", mapType: "Depth", units: "m"),
            profileFacetSeries(id: "unknown-a", mapType: nil, units: "ft"),
            profileFacetSeries(id: "unknown-b", mapType: nil, units: "ft")
        ])
        let projection = MapDynamicProfileChartProjection(lines: [line])
        #expect(projection.facets.count == 4)
        #expect(projection.facets.filter { $0.id.quantity == .depth }.map(\.id.units) == ["ft", "m"])
        let metric = try #require(projection.facets.first { $0.id.units == "m" })
        #expect(metric.samples.first?.y == 100)
        #expect(metric.samples[1].y.isNaN)
        #expect(metric.samples.last?.y == 101)
    }

    @Test
    func facetsRetainSameNamedSourceIdentitiesGapsAndCommonStationRange() throws {
        let first = profileFacetLine(id: "line-a", distances: [0, 1, 2], series: [
            profileFacetSeries(id: "a", lineID: "line-a", mapType: "Depth", units: "ft")
        ])
        let second = profileFacetLine(id: "line-b", distances: [0, 5, 10], series: [
            profileFacetSeries(id: "b", lineID: "line-b", mapType: "Velocity", units: "ft/s")
        ])
        let projection = MapDynamicProfileChartProjection(lines: [first, second])
        #expect(projection.distanceDomain == 0...10)
        #expect(projection.facets.flatMap(\.seriesIDs) == ["a", "b"])
        for facet in projection.facets {
            let segments = SeriesPlotPoint.segments(facet.samples)
            #expect(segments.count == 2)
            #expect(segments.allSatisfy { $0.isIsolated })
            #expect(Set(segments.map(\.segment)).count == 2)
        }
    }
}

private func profileFacetSeries(id: String, lineID: String = "line", kind: String = "Result", mapType: String?, units: String)
    -> MapDynamicProfileSeries {
    .init(id: id, lineId: lineID, sourceKind: kind, sourcePath: "/source/" + id + ".h5",
        sourceRevision: "source-sha", name: "Same displayed name", mapType: mapType,
        profileIndex: kind == "Result" ? 0 : nil, time: nil, units: units,
        samples: [100, nil, 101], terrainPath: nil, terrainRevision: nil, unavailableReason: nil)
}

private func profileFacetLine(id: String, distances: [Double], series: [MapDynamicProfileSeries])
    -> MapDynamicProfileLineResult {
    let coordinates = distances.map { GeometryTopologyCoordinate(x: $0, y: 0) }
    return .init(id: id, points: coordinates, samplePoints: coordinates, distances: distances, series: series)
}
