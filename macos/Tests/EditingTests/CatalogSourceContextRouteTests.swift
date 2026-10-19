import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

struct CatalogSourceContextRouteTests {
    @Test
    func vectorLayerDiagnosticsStayBoundToEachSupportedMapClass() {
        let classes = [
            "PointMapLayerVisualContext",
            "PolylineMapLayerVisualContext",
            "PolygonMapLayerVisualContext"
        ]

        for (index, sourceClass) in classes.enumerated() {
            let diagnostic = CatalogLayerDiagnostic(code: "MAP_\(index)", severity: "Warning",
                evaluatedMessage: "Issue for exact vector node \(index)", logData: [])
            let node = LayerTreeNode(id: "node-\(index)", sourceClass: sourceClass,
                name: "Same display name", layerErrors: [diagnostic], diagnosticStatus: "loaded")
            let stale = LayerTreeNode(id: node.id, sourceClass: sourceClass,
                name: node.name, layerErrors: [diagnostic], diagnosticStatus: "sourceChanged")

            #expect(CatalogLayerDiagnosticsProjection.applies(to: sourceClass))
            #expect(CatalogLayerDiagnosticsProjection.state(for: node) == .issues([diagnostic]))
            #expect(CatalogLayerDiagnosticsProjection.state(for: stale) == .sourceChanged)
        }

        #expect(!CatalogLayerDiagnosticsProjection.applies(to: "GdbVectorLayerVisualContext"))
    }

    @Test
    func mapLayerRemovalConfirmationRequiresExactContextLocatorAndPath() throws {
        let sessionID = UUID()
        let mapID = UUID()
        let context = LayerTreeContext(projectSessionID: sessionID,
            projectURL: URL(fileURLWithPath: "/task/project.ras"), mapID: mapID,
            mode: "Project", focusedGeometryIDs: [], focusedPlanIDs: [])
        let exact = vectorNode(id: "layer:0.2", path: "/task/maps/shared.shp")
        let request = try #require(CatalogMapLayerRemovalRequest(node: exact, context: context))

        #expect(request.matches(exact, activeContext: context,
            projectSessionID: sessionID, activeMapID: mapID))

        let sameNameDifferentFile = vectorNode(id: "layer:0.2", path: "/task/maps/other.shp")
        #expect(!request.matches(sameNameDifferentFile, activeContext: context,
            projectSessionID: sessionID, activeMapID: mapID))

        var movedSerializedRow = exact
        movedSerializedRow.sourceLocator = CatalogTreeNodeLocator(rootName: "Layers",
            nodeType: "MapLayer", nodeName: "Shared vector", nodePath: [0, 3],
            mapType: "PolylinesVector", filename: "/task/maps/shared.shp",
            filenameRelative: "/task/maps/shared.shp")
        #expect(!request.matches(movedSerializedRow, activeContext: context,
            projectSessionID: sessionID, activeMapID: mapID))

        let changedMap = LayerTreeContext(projectSessionID: sessionID,
            projectURL: context.projectURL, mapID: UUID(), mode: context.mode,
            focusedGeometryIDs: [], focusedPlanIDs: [])
        #expect(!request.matches(exact, activeContext: changedMap,
            projectSessionID: sessionID, activeMapID: changedMap.mapID))
        #expect(!request.matches(exact, activeContext: context,
            projectSessionID: UUID(), activeMapID: mapID))

        let wrongClass = LayerTreeNode(id: exact.id, sourceClass: "PointMapLayerVisualContext",
            name: exact.name, assetID: exact.assetID, sourceLocator: exact.sourceLocator)
        #expect(!request.matches(wrongClass, activeContext: context,
            projectSessionID: sessionID, activeMapID: mapID))
    }

    @Test
    func mapLayerRoutesRejectUnresolvedOrMismatchedMapTypes() {
        let unresolved = vectorNode(id: "layer:0", path: "relative.shp")
        #expect(CatalogSourceContextRoutes.mapLayerFilePath(for: unresolved) == nil)

        let mismatched = LayerTreeNode(id: "layer:1", sourceClass: "PointMapLayerVisualContext",
            name: "Roads", assetID: "/task/roads.shp",
            sourceLocator: locator(mapType: "PolylinesVector", path: "/task/roads.shp"))
        #expect(CatalogSourceContextRoutes.mapLayerFilePath(for: mismatched) == nil)
    }

    @Test
    func terrainInputEditorFolderRouteRequiresExactRasterRowAndCollection() {
        let item = EditorChoice(id: "terrain-input:/task/elevation.tif", title: "Elevation")
        let raster = SourceItemPresentation(scope: "TerrainLayersEditor/SelectedInputWithMap",
            schemaIDs: ["RasterTerrainInputProperties"],
            terrainInfo: .init(type: "RasterTerrainInput", filename: "/task/elevation.tif", error: nil, validExtent: nil))
        let collection = SourceCollection(items: [item], sourcePriorityReversed: false,
            canImport: true, canReorder: true, multipleImports: true,
            itemDetails: [item.id: raster], terrainConnected: true)

        #expect(CatalogSourceContextRoutes.rasterTerrainEditorFilePath(
            fieldID: TerrainEditorContract.sourceField, itemID: item.id,
            collection: collection) == SourceFilePaths.canonical(URL(fileURLWithPath: "/task/elevation.tif")))
        #expect(CatalogSourceContextRoutes.rasterTerrainEditorFilePath(
            fieldID: "ClassificationLayersEditor", itemID: item.id,
            collection: collection) == nil)
        #expect(CatalogSourceContextRoutes.rasterTerrainEditorFilePath(
            fieldID: TerrainEditorContract.sourceField, itemID: "same-name-different-id",
            collection: collection) == nil)

        let duplicateIdentity = SourceCollection(items: [item, .init(id: item.id,
                title: "Duplicate row identity")], sourcePriorityReversed: false,
            canImport: true, canReorder: true, multipleImports: true,
            itemDetails: [item.id: raster], terrainConnected: true)
        #expect(CatalogSourceContextRoutes.rasterTerrainEditorFilePath(
            fieldID: TerrainEditorContract.sourceField, itemID: item.id,
            collection: duplicateIdentity) == nil)

        var disconnected = collection
        disconnected.terrainConnected = false
        #expect(CatalogSourceContextRoutes.rasterTerrainEditorFilePath(
            fieldID: TerrainEditorContract.sourceField, itemID: item.id,
            collection: disconnected) == nil)
    }

    private func vectorNode(id: String, path: String) -> LayerTreeNode {
        LayerTreeNode(id: id, sourceClass: "PolylineMapLayerVisualContext", name: "Shared vector",
            assetID: path, sourceLocator: locator(mapType: "PolylinesVector", path: path))
    }

    private func locator(mapType: String, path: String) -> CatalogTreeNodeLocator {
        CatalogTreeNodeLocator(rootName: "Layers", nodeType: "MapLayer", nodeName: "Shared vector",
            nodePath: [0, 2], mapType: mapType, filename: path, filenameRelative: path)
    }
}
