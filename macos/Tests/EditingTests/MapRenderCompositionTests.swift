import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

struct MapRenderCompositionTests {
    @Test
    func sourcePaintOrderUsesStableFamilySortAndReverseTreeOrder() {
        let mapID = UUID()
        let rows = [
            row(mapID, id: "vector", family: 6, tree: 9, kind: "Feature"),
            row(mapID, id: "terrain-old", family: 0, tree: 2, kind: "Terrain"),
            row(mapID, id: "boundary", family: 5, tree: 8, kind: "BoundaryCondition"),
            row(mapID, id: "geometry", family: 4, tree: 7, kind: "Geometry"),
            row(mapID, id: "result", family: 3, tree: 6, kind: "Result"),
            row(mapID, id: "nvalue", family: 2, tree: 5, kind: "NValue"),
            row(mapID, id: "classification", family: 1, tree: 4, kind: "Classification"),
            row(mapID, id: "terrain-new", family: 0, tree: 3, kind: "Terrain"),
            row(mapID, id: "other", family: 7, tree: 1, kind: "Folder")
        ]

        #expect(MapRenderComposition.orderedRecords(rows).map(\.contextIdentity) == [
            "terrain-new", "terrain-old", "classification", "nvalue", "result",
            "geometry", "boundary", "vector", "other"
        ])
    }

    @Test
    func rasterLayersJoinExactPayloadIDsInCompositionOrderAndRespectVisibility() throws {
        let mapID = UUID()
        let highTerrain = row(mapID, id: "terrain-high", family: 0, tree: 7,
            kind: "Terrain", payloads: ["raster-high"])
        let lowTerrain = row(mapID, id: "terrain-low", family: 0, tree: 2,
            kind: "Terrain", payloads: ["raster-low-1", "raster-low-2"])
        let result = row(mapID, id: "result", family: 3, tree: 1,
            kind: "Result", payloads: ["result-raster"])
        let candidates = try [
            raster("raster-low-2", mapID), raster("result-raster", mapID),
            raster("raster-low-1", mapID), raster("raster-high", mapID)
        ]

        let rendered = MapRenderComposition.rasterLayers(
            records: [lowTerrain, result, highTerrain], candidates: candidates,
            hiddenLayerIDs: ["raster-low-1"])

        #expect(rendered.map(\.id) == ["raster-high", "raster-low-2", "result-raster"])
    }

    private func row(_ mapID: UUID, id: String, family: Int, tree: Int,
                     kind: String, payloads: [String] = []) -> MapSourceRenderRecord {
        let locator = CatalogTreeNodeLocator(rootName: "Layers", nodeType: kind,
            nodeName: id, nodePath: [tree])
        return MapSourceRenderRecord(mapID: mapID, nodeID: id, locator: locator,
            familyOrder: family, treeOrdinal: tree, activeLayerOrdinal: 0,
            contextIdentity: id, payloadKind: kind, payloadLayerIDs: payloads,
            isChecked: true, isEffectivelyVisible: true, isStatic: false,
            staticInsertionAfterRaster: false)
    }

    private func raster(_ id: String, _ mapID: UUID) throws -> MapRasterLayer {
        try MapRasterLayer(id: id, name: id, width: 1, height: 1,
            rgba: Data([0, 0, 0, 255]), lowerLeft: MapPoint(x: 0, y: 0),
            upperRight: MapPoint(x: 1, y: 1), sourceMapID: mapID)
    }
}
