import Foundation
import Testing
@testable import HECRAS2025

struct MapResultCulvertTimeSeriesChartDataTests {
    @Test @MainActor
    func chartRetainsSourceNoDataAndShowsTheStoredResultUnits() throws {
        let snapshot = makeSnapshot(times: ["2026-10-16T00:00:00.0000000Z"],
            values: [-9999], name: "")

        let data = try #require(MapResultCulvertTimeSeriesChartData.make(
            from: snapshot, variable: "Flow"))
        let dataset = try #require(data.presentation.chart?.datasets.first)
        let axis = try #require(data.presentation.chart?.axes.first { $0.direction == .y })

        #expect(dataset.name == L10n.format("Culvert Barrel %d", 1))
        #expect(dataset.noDataValue == -9999)
        #expect(axis.units == "CFS")
        #expect(data.samples.map(\.y) == [-9999])
        #expect(dataset.forDisplay(data.samples[0]).y.isNaN)
    }

    @Test @MainActor
    func chartRejectsEmptyTimeAndSeriesArrays() {
        let noTimes = makeSnapshot(times: [], values: [])
        let noSeries = makeSnapshot(times: ["2026-10-16T00:00:00.0000000Z"],
            values: [], includeDataset: false)

        #expect(MapResultCulvertTimeSeriesChartData.make(from: noTimes, variable: "Flow")?.samples.count == nil)
        #expect(MapResultCulvertTimeSeriesChartData.make(from: noSeries, variable: "Flow")?.samples.count == nil)
    }

    private func makeSnapshot(times: [String], values: [Double], name: String = "Barrel 1",
                              includeDataset: Bool = true) -> MapResultCulvertTimeSeriesSnapshot {
        MapResultCulvertTimeSeriesSnapshot(
            projectCanonicalPath: "/tmp/culvert.ras",
            projectRevision: String(repeating: "A", count: 64),
            projectXmlSHA: String(repeating: "B", count: 64),
            visualizationRevision: String(repeating: "C", count: 64),
            coreLayerContextIdentity: "",
            mapID: "00000000-0000-0000-0000-000000000001",
            mapIndex: 0, mapName: "Map", mapType: "Project", contextToken: "context",
            resultNode: CatalogTreeNodeLocator(rootName: "Results", nodeType: "Result",
                nodeName: "Result", nodePath: [0]),
            selectionIndex: 0, selectedResultPath: "/tmp/result.h5",
            selectedResultRevision: String(repeating: "D", count: 64),
            variable: "Flow", units: "CFS", times: times, noDataValue: -9999,
            datasets: includeDataset ? [MapResultCulvertTimeSeriesDataset(
                id: "barrel:source:0", name: name, sourceOrdinal: 0,
                colorRGBA: "FF0000FF", strokeWidth: 2, values: values)] : [])
    }
}
