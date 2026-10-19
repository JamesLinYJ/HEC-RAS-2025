import Foundation
import RASWorkspaceCore

struct CatalogGeometryNamedBackupPresentation: Identifiable {
    let id = UUID()
    let geometry: ProjectAsset
}

/// Exact file routes for source-backed catalog/map-tree context actions.
/// Display names are deliberately not used to locate a layer or model.
enum CatalogSourceContextRoutes {
    private static let mapLayerClasses: [String: String] = [
        "PointsVector": "PointMapLayerVisualContext",
        "PolylinesVector": "PolylineMapLayerVisualContext",
        "PolygonsVector": "PolygonMapLayerVisualContext",
        "SingleBandRasterMapLayer": "RasterMapLayerVisualContext"
    ]

    static func mapLayerFilePath(for node: LayerTreeNode) -> String? {
        guard let locator = node.sourceLocator,
              locator.nodeType == "MapLayer",
              let mapType = locator.mapType,
              mapLayerClasses[mapType] == node.sourceClass,
              let path = node.assetID, path.hasPrefix("/"), !path.isEmpty else { return nil }
        return SourceFilePaths.canonical(URL(fileURLWithPath: path))
    }

    static func rasterTerrainEditorFilePath(fieldID: String, itemID: String,
        collection: SourceCollection?) -> String? {
        guard fieldID == TerrainEditorContract.sourceField,
              let collection, collection.terrainConnected,
              collection.items.filter({ $0.id == itemID }).count == 1,
              let details = collection.itemDetails[itemID],
              details.schemaIDs.contains("RasterTerrainInputProperties"),
              let filename = details.terrainInfo?.filename,
              filename.hasPrefix("/"), !filename.isEmpty else { return nil }
        return SourceFilePaths.canonical(URL(fileURLWithPath: filename))
    }
}

/// Captures the exact tree context and serialized node identity before asking
/// the existing provider to remove a map reference. A stale confirmation can
/// never target a same-named row in a different project or map.
struct CatalogMapLayerRemovalRequest: Identifiable, Equatable, Sendable {
    let id: UUID
    let context: LayerTreeContext
    let nodeID: String
    let locatorIdentity: String
    let assetPath: String
    let displayName: String

    init?(node: LayerTreeNode, context: LayerTreeContext) {
        guard let locator = node.sourceLocator,
              let path = CatalogSourceContextRoutes.mapLayerFilePath(for: node),
              !node.id.isEmpty else { return nil }
        id = UUID()
        self.context = context
        nodeID = node.id
        locatorIdentity = locator.sourceIdentity
        assetPath = path
        displayName = node.name
    }

    func matches(_ node: LayerTreeNode?, activeContext: LayerTreeContext?,
        projectSessionID: UUID, activeMapID: UUID) -> Bool {
        guard let node, let locator = node.sourceLocator,
              activeContext == context,
              context.projectSessionID == projectSessionID,
              context.mapID == activeMapID,
              node.id == nodeID,
              locator.sourceIdentity == locatorIdentity,
              CatalogSourceContextRoutes.mapLayerFilePath(for: node) == assetPath else { return false }
        return true
    }
}
