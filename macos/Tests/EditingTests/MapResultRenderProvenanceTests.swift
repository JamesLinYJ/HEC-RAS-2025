import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

struct MapResultRenderProvenanceTests {
    @Test
    func layerOwnershipJoinsCanonicalPathAndCaseInsensitiveRevisionWithoutCrossAssigning() throws {
        let mapID = UUID()
        let canonicalPath = "/tmp/hecras-render-\(UUID().uuidString)/Results/Run.h5"
        let equivalentLayerPath = canonicalPath.replacingOccurrences(
            of: "/Results/Run.h5", with: "/Results/../Results/Run.h5")
        let unrelatedPath = canonicalPath.replacingOccurrences(
            of: "/Results/Run.h5", with: "/Other/Run.h5")
        let uppercaseRevision = String(repeating: "A", count: 64)
        let lowercaseRevision = uppercaseRevision.lowercased()

        let matchingLayer = Self.layer(id: "depth", mapID: mapID,
            resultPath: equivalentLayerPath, revision: uppercaseRevision)
        let wrongRevisionLayer = Self.layer(id: "velocity", mapID: mapID,
            resultPath: canonicalPath, revision: String(repeating: "B", count: 64))
        let wrongPathLayer = Self.layer(id: "shear", mapID: mapID,
            resultPath: unrelatedPath, revision: lowercaseRevision)
        let response = MapResultRenderResult(contextToken: "context", sourceID: "multi-result",
            selectedProfileIndex: 0, selectedProfileTime: nil, steps: [],
            layers: [matchingLayer, wrongRevisionLayer, wrongPathLayer],
            sources: [
                .init(resultPath: canonicalPath, revision: lowercaseRevision,
                    resultName: "Run", selectionIndices: [0, 2], terrainPath: nil,
                    terrainRevision: nil, available: true, profileIndex: 0,
                    unavailableReason: nil),
                .init(resultPath: canonicalPath, revision: String(repeating: "C", count: 64),
                    resultName: "Other revision", selectionIndices: [1], terrainPath: nil,
                    terrainRevision: nil, available: true, profileIndex: 0,
                    unavailableReason: nil)
            ], unavailableReason: nil)

        let update = try response.mapUpdate(expectedMapID: mapID)

        #expect(update.rasterSelectionIndicesByLayerID == [matchingLayer.id: [0, 2]],
            "A canonical path match with a SHA case difference should retain the source's full selection membership.")
        #expect(update.rasterSourceIdentityByLayerID?.count == 1)
        #expect(update.rasterSourceIdentityByLayerID?[matchingLayer.id]
            == MapRasterSourceIdentity(resultPath: equivalentLayerPath,
                revision: uppercaseRevision),
            "The joined provenance should retain the layer's original result identity.")
        #expect(update.rasterSelectionIndicesByLayerID?[wrongRevisionLayer.id] == nil,
            "A source at the same canonical path but with a different SHA must not own this layer.")
        #expect(update.rasterSourceIdentityByLayerID?[wrongRevisionLayer.id] == nil)
        #expect(update.rasterSelectionIndicesByLayerID?[wrongPathLayer.id] == nil,
            "A matching SHA at another canonical path must not own this layer.")
        #expect(update.rasterSourceIdentityByLayerID?[wrongPathLayer.id] == nil)
    }

    private static func layer(id: String, mapID: UUID, resultPath: String,
                              revision: String) -> MapResultRenderLayerPayload {
        MapResultRenderLayerPayload(id: id, sourceID: "multi-result",
            sourceMapID: mapID.uuidString, resultPath: resultPath, revision: revision,
            resultName: "Run", mapType: "Depth", terrainPath: "/tmp/Terrain.h5",
            terrainRevision: String(repeating: "D", count: 64), profileIndex: 0,
            profileName: "Profile 0", time: "2026-10-18T00:00:00.0000000", units: "ft",
            width: 1, height: 1, rgba: Data([0, 0, 0, 255]), minX: 0, minY: 0,
            maxX: 1, maxY: 1, noDataValue: -9999, legendStops: [])
    }
}
