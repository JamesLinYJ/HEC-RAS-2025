import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

struct MapResultRenderTests {
    @Test
    func responseInstallsOnlyTheExactMapScopedRgbaLayers() throws {
        let mapID = UUID()
        let payload = MapResultRenderLayerPayload(
            id: "result-node|0|/project/Results/Run.h5|Depth",
            sourceID: "Results|MultiResult|Plan|0|||",
            sourceMapID: mapID.uuidString,
            resultPath: "/project/Results/Run.h5",
            revision: String(repeating: "A", count: 64),
            resultName: "Run",
            mapType: "Depth",
            terrainPath: "/project/Terrains/Bed.h5",
            terrainRevision: String(repeating: "B", count: 64),
            profileIndex: 3,
            profileName: "2026-10-16 01:30:00",
            time: "2026-10-16T01:30:00.0000000",
            units: "ft",
            width: 2,
            height: 1,
            rgba: Data([10, 20, 30, 255, 40, 50, 60, 128]),
            minX: 0,
            minY: 1,
            maxX: 2,
            maxY: 3,
            noDataValue: -9999,
            legendStops: [.init(color: "#000000FF", value: 0), .init(color: "#FFFFFFFF", value: 10)])
        let response = MapResultRenderResult(
            contextToken: "context",
            sourceID: payload.sourceID,
            selectedProfileIndex: 3,
            selectedProfileTime: payload.time,
            steps: [.init(id: 3, label: payload.profileName, time: payload.time)],
            layers: [payload],
            sources: [.init(resultPath: payload.resultPath, revision: payload.revision,
                resultName: payload.resultName, selectionIndices: [0],
                terrainPath: payload.terrainPath, terrainRevision: payload.terrainRevision,
                available: true, profileIndex: 3, unavailableReason: nil)],
            unavailableReason: nil)

        let update = try response.mapUpdate(expectedMapID: mapID)
        #expect(update.rasters?.count == 1)
        #expect(update.rasters?.first?.sourceMapID == mapID)
        #expect(update.rasters?.first?.rgba == payload.rgba)
        #expect(update.rasters?.first?.lowerLeft == MapPoint(x: 0, y: 1))
        #expect(update.rasters?.first?.upperRight == MapPoint(x: 2, y: 3))
        #expect(update.vectors == nil)
    }

    @Test
    func mismatchedMapIdentityCannotInstallAResultRaster() throws {
        let firstMap = UUID()
        let otherMap = UUID()
        let payload = MapResultRenderLayerPayload(
            id: "result", sourceID: "node", sourceMapID: otherMap.uuidString,
            resultPath: "/project/Results/Run.h5", revision: String(repeating: "A", count: 64),
            resultName: "Run", mapType: "Depth", terrainPath: "/project/Terrains/Bed.h5",
            terrainRevision: String(repeating: "B", count: 64), profileIndex: 0,
            profileName: "Profile 0", time: "2026-10-16T00:00:00.0000000", units: "ft",
            width: 1, height: 1, rgba: Data([0, 0, 0, 255]), minX: 0, minY: 0, maxX: 1,
            maxY: 1, noDataValue: -9999, legendStops: [])

        #expect(throws: BackendServiceError.self) {
            try payload.makeLayer(expectedMapID: firstMap)
        }
    }

    @Test
    func unavailableRenderResponseDoesNotInventRasterContent() throws {
        let response = MapResultRenderResult(contextToken: "context", sourceID: "node",
            selectedProfileIndex: 1, selectedProfileTime: nil,
            steps: [.init(id: 0, label: "Profile 0", time: "2026-10-16T00:00:00.0000000"),
                    .init(id: 1, label: "Profile 1", time: "2026-10-16T00:30:00.0000000")],
            layers: [], sources: [], unavailableReason: "No source profile is available.")

        let update = try response.mapUpdate(expectedMapID: UUID())
        #expect(update.rasters?.isEmpty == true)
        #expect(response.unavailableReason == "No source profile is available.")
        #expect(response.steps.map(\.id) == [0, 1])
    }
}
