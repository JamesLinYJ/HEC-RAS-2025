import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

struct MapContextComponentsTests {
    @Test
    func visibleRowsAreScopedOrderedAndSelectionMustBeUnique() {
        let mapID = UUID()
        let otherMapID = UUID()
        let first = row(mapID: mapID, nodeName: "Terrain A", context: "terrain-a",
                        family: 0, ordinal: 4)
        let second = row(mapID: mapID, nodeName: "Boundary", context: "boundary",
                         family: 1, ordinal: 0)
        let earlierInFamily = row(mapID: mapID, nodeName: "Terrain B", context: "terrain-b",
                                  family: 0, ordinal: 2)
        let hidden = row(mapID: mapID, nodeName: "Hidden", context: "hidden",
                         family: 0, ordinal: 1, checked: false)
        let ineffective = row(mapID: mapID, nodeName: "Parent Hidden", context: "parent-hidden",
                              family: 0, ordinal: 0, effectivelyVisible: false)
        let otherMap = row(mapID: otherMapID, nodeName: "Other Map", context: "other-map",
                           family: 0, ordinal: 0)

        let visible = MapContextComponentResolver.visibleRows(
            [first, second, earlierInFamily, hidden, ineffective, otherMap], mapID: mapID)

        #expect(visible.map(\.contextIdentity) == ["terrain-b", "terrain-a", "boundary"])
        #expect(MapContextComponentResolver.exactRow(contextIdentity: "terrain-a", among: visible) == first)
        #expect(MapContextComponentResolver.exactRow(contextIdentity: "missing", among: visible) == nil)
    }

    @Test
    func ambiguousIdentityDoesNotResolveAndVectorPayloadIsMapScoped() {
        let mapID = UUID()
        let otherMapID = UUID()
        let row = row(mapID: mapID, nodeName: "Roads", context: "road-row",
                      payloadKind: "MapLayer", payloadIDs: ["map-road-node"])
        let duplicate = self.row(mapID: mapID, nodeName: "Roads copy", context: "road-row",
                                 payloadKind: "MapLayer", payloadIDs: ["other-node"])

        #expect(MapContextComponentResolver.exactRow(
            contextIdentity: "road-row", among: [row, duplicate]) == nil)

        let url = URL(fileURLWithPath: "/tmp/map-context/roads.geojson")
        let exact = MapVectorLayer(url: url, features: [], sourceMapID: mapID,
                                   visualIdentity: "map-road-node")
        let foreign = MapVectorLayer(url: url, features: [], sourceMapID: otherMapID,
                                     visualIdentity: "map-road-node")
        let unrelated = MapVectorLayer(url: url, features: [], sourceMapID: mapID,
                                       visualIdentity: "unrelated-node")

        #expect(MapContextComponentResolver.exactVectorLayers(
            for: row, candidates: [foreign, unrelated, exact]).map(\.id) == ["map-road-node"])
        #expect(MapContextComponentResolver.exactVectorLayers(
            for: row, candidates: [exact, exact]).isEmpty,
            "Duplicate payload identity is ambiguous and must not route to an arbitrary source.")
        #expect(MapContextComponentResolver.exactVectorLayers(
            for: duplicate, candidates: [exact]).isEmpty)
    }

    private func row(mapID: UUID, nodeName: String, context: String,
                     family: Int = 0, ordinal: Int = 0, payloadKind: String = "Terrain",
                     payloadIDs: [String] = [], checked: Bool = true,
                     effectivelyVisible: Bool = true) -> MapSourceRenderRecord {
        let locator = CatalogTreeNodeLocator(rootName: "Layers", nodeType: payloadKind,
            nodeName: nodeName, nodePath: [ordinal], assetID: "/tmp/map-context/\(nodeName).hdf")
        return MapSourceRenderRecord(mapID: mapID, nodeID: "node-\(context)", locator: locator,
            familyOrder: family, treeOrdinal: ordinal, activeLayerOrdinal: ordinal,
            contextIdentity: context, payloadKind: payloadKind, payloadLayerIDs: payloadIDs,
            isChecked: checked, isEffectivelyVisible: effectivelyVisible,
            isStatic: false, staticInsertionAfterRaster: false)
    }
}

@MainActor
struct WorkspaceSpreadsheetModelTests {
    @Test
    func sparseGridAndSourceRowAndColumnActionsStayConsistent() {
        let model = WorkspaceSpreadsheetModel()

        #expect(model.rowCount == 1_000)
        #expect(model.columnCount == 1_000)
        #expect(model.materializedCellCount == 0)
        #expect(model.value(row: 0, column: 0) == "0")

        model.setValue("12.5", row: 999, column: 999)
        #expect(model.materializedCellCount == 1)
        model.addColumn()
        #expect(model.columnCount == 1_001)
        #expect(model.value(row: 0, column: 1_000) == "0")

        model.addRow()
        #expect(model.rowCount == 1_001)
        #expect(model.value(row: 1_000, column: 0) == "01")
        #expect(model.value(row: 1_000, column: 999) == "12.51")
        #expect(model.value(row: 1_000, column: 1_000) == "01")

        model.setValue("0", row: 1_000, column: 999)
        #expect(model.value(row: 1_000, column: 999) == "0")
        #expect(model.materializedCellCount == 1_001)
    }
}
