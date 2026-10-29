import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

struct MapHoverIdentifyVectorTests {
    @Test @MainActor
    func sharedActiveLayerAndTreeFocusRemainFirstAndTreeFocusWorksWithoutActivePayload() {
        let mapID = UUID()
        let path = URL(fileURLWithPath: "/tmp/overlapping-hover.geojson")
        let layerA = makeLayer(id: "focused-instance", path: path,
            mapID: mapID, revision: "A", fid: 7)
        let layerB = makeLayer(id: "other-instance", path: path,
            mapID: mapID, revision: "B", fid: 22)
        let rowA = makeRow(mapID: mapID, ordinal: 0, layer: layerA, nodeName: "Focused")
        let rowB = makeRow(mapID: mapID, ordinal: 1, layer: layerB, nodeName: "Other")
        let transform = MapTransform(points: [layerA, layerB].flatMap(\.points),
            size: CGSize(width: 240, height: 180), scale: 1, offset: .zero)
        for activeLayerID in [layerA.id, nil] as [String?] {
            let entries = MapHoverIdentifyVector.entries(
                at: transform.screen(MapPoint(x: 2, y: 3)), transform: transform,
                mapID: mapID, records: [rowA, rowB], candidates: [layerA, layerB],
                selectedLayerID: activeLayerID, selectedContextIdentity: rowA.contextIdentity,
                vectorStyles: [:])
            #expect(entries.map(\.value) == ["7", "22"])
            #expect(MapRenderComposition.hoverPreferredNodeIdentities([rowA, rowB],
                selectedLayerID: activeLayerID, selectedContextIdentity: rowA.contextIdentity)
                == [rowA.locator.sourceIdentity])
        }
    }

    @Test @MainActor
    func overlappingVisibleRowsReturnEachRendererFIDWithActiveLayerFirst() {
        let mapID = UUID(uuidString: "00000000-0000-0000-0000-000000000041")!
        let sharedPath = URL(fileURLWithPath: "/tmp/shared-source.geojson")
        let layerA = makeLayer(id: "source-instance-a", path: sharedPath,
            mapID: mapID, revision: "A", fid: 7)
        let layerB = makeLayer(id: "source-instance-b", path: sharedPath,
            mapID: mapID, revision: "B", fid: 22)
        let rowA = makeRow(mapID: mapID, ordinal: 0, layer: layerA, nodeName: "Shared")
        let rowB = makeRow(mapID: mapID, ordinal: 1, layer: layerB, nodeName: "Shared")
        let layers = [layerA, layerB]
        let transform = MapTransform(points: layers.flatMap(\.points),
            size: CGSize(width: 240, height: 180), scale: 1, offset: .zero)
        let location = transform.screen(MapPoint(x: 2, y: 3))

        let entries = MapHoverIdentifyVector.entries(at: location, transform: transform,
            mapID: mapID, records: [rowA, rowB], candidates: layers,
            selectedLayerID: layerB.id, selectedContextIdentity: rowA.contextIdentity,
            vectorStyles: [:])

        #expect(entries.map(\.value) == ["22", "7"])
        #expect(entries.map(\.node) == [rowB.locator, rowA.locator])
        #expect(entries.map(\.sourcePath) == [SourceFilePaths.canonical(sharedPath),
            SourceFilePaths.canonical(sharedPath)])
        #expect(entries.map(\.sourceRevision) == ["B", "A"])
        #expect(entries.allSatisfy { $0.kind == "vector" && $0.valueType == "feature-id" })
    }

    @Test @MainActor
    func rowCannotBeJoinedToAnotherVectorInstanceByMatchingPathOrDisplayName() {
        let mapID = UUID(uuidString: "00000000-0000-0000-0000-000000000042")!
        let path = URL(fileURLWithPath: "/tmp/shared-source.geojson")
        let renderedLayer = makeLayer(id: "rendered-instance", path: path,
            mapID: mapID, revision: "A", fid: 7)
        let unrelatedLayer = makeLayer(id: "unrelated-instance", path: path,
            mapID: mapID, revision: "A", fid: 91)
        let row = makeRow(mapID: mapID, ordinal: 0, layer: renderedLayer,
            nodeName: "Identical display name")
        let transform = MapTransform(points: renderedLayer.points,
            size: CGSize(width: 240, height: 180), scale: 1, offset: .zero)
        let location = transform.screen(MapPoint(x: 2, y: 3))

        let entries = MapHoverIdentifyVector.entries(at: location, transform: transform,
            mapID: mapID, records: [row], candidates: [unrelatedLayer],
            selectedLayerID: unrelatedLayer.id, selectedContextIdentity: row.contextIdentity,
            vectorStyles: [:])

        #expect(entries.isEmpty)
        #expect(MapHoverIdentifyVector.sources(mapID: mapID, records: [row],
            candidates: [unrelatedLayer], selectedLayerID: nil,
            selectedContextIdentity: nil).isEmpty)
    }

    private func makeLayer(id: String, path: URL, mapID: UUID,
                           revision: String, fid: Int) -> MapVectorLayer {
        let feature = MapFeature(id: 0, kind: .point,
            paths: [[MapPoint(x: 2, y: 3)]], attributes: [:],
            stableIdentity: "feature-\(id)", sourceFeatureIndex: fid)
        return MapVectorLayer(url: path, features: [feature], sourceMapID: mapID,
            sourceRevision: revision, visualIdentity: id)
    }

    private func makeRow(mapID: UUID, ordinal: Int, layer: MapVectorLayer,
                         nodeName: String) -> MapSourceRenderRecord {
        let locator = CatalogTreeNodeLocator(rootName: "Map", nodeType: "MapLayer",
            nodeName: nodeName, nodePath: [ordinal], mapType: "GeoJSONMapLayer")
        return MapSourceRenderRecord(mapID: mapID, nodeID: "node-\(ordinal)", locator: locator,
            familyOrder: 6, treeOrdinal: ordinal, activeLayerOrdinal: ordinal,
            contextIdentity: "\(mapID.uuidString)|\(ordinal)", payloadKind: "MapLayer",
            payloadLayerIDs: [layer.id], isChecked: true, isEffectivelyVisible: true,
            isStatic: false, staticInsertionAfterRaster: false)
    }
}
