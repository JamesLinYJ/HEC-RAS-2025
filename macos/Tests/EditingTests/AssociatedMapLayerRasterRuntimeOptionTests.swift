import Foundation
import Testing
@testable import HECRAS2025

struct AssociatedMapLayerRasterRuntimeOptionTests {
    @Test
    func tileOutlineOptionRequiresTheExactSelectedRasterCapture() throws {
        let mapID = UUID()
        let projectSessionID = UUID()
        let projectPath = "/tmp/raster-runtime-option/project.prj"
        let geometryPath = "/tmp/raster-runtime-option/Geometry/area.hdf"
        let rasterPath = "/tmp/raster-runtime-option/Terrains/dem.hdf"
        let geometry = CatalogTreeNodeLocator(rootName: "Focused Geometries",
            nodeType: "Geometry", nodeName: "Area", nodePath: [0, 0], assetID: geometryPath)
        let map = MapTreeMapIdentity(projectPath: projectPath, projectXml: "<Project />",
            projectXmlSHA: String(repeating: "A", count: 64), mapID: mapID.uuidString,
            mapIndex: 0, mapName: "Map", mapType: "Geometry",
            expectedVisualizationRevision: String(repeating: "B", count: 64))
        let terrain = CatalogTreeNodeLocator(rootName: "Matching Layers",
            nodeType: "Terrain", nodeName: "Terrain", nodePath: [1, 0], assetID: rasterPath,
            associationAssetID: rasterPath, associationKind: "Terrain")
        let capture = try AssociatedMapLayerCapture(projectSessionID: projectSessionID,
            mapID: mapID, mapWorkflowIdentity: "map-runtime-option", map: map,
            geometryNodes: [geometry], associationNode: terrain, assetPath: rasterPath,
            isChecked: true, effectiveVisible: true)

        let option = AssociatedMapLayerRasterRuntimeOption(locator: terrain,
            assetPath: rasterPath, plotRasterTileOutlines: true)
        #expect(AssociatedMapLayerRasterTileOutlineToggle.supports(capture))
        #expect(option.matches(capture))

        let wrongAsset = AssociatedMapLayerRasterRuntimeOption(locator: terrain,
            assetPath: "/tmp/raster-runtime-option/Terrains/other.hdf",
            plotRasterTileOutlines: true)
        #expect(!wrongAsset.matches(capture),
            "A runtime plot option cannot move to another raster file behind the same tree row.")

        let otherRow = CatalogTreeNodeLocator(rootName: "Matching Layers",
            nodeType: "Terrain", nodeName: "Terrain", nodePath: [1, 1], assetID: rasterPath,
            associationAssetID: rasterPath, associationKind: "Terrain")
        let wrongRow = AssociatedMapLayerRasterRuntimeOption(locator: otherRow,
            assetPath: rasterPath, plotRasterTileOutlines: true)
        #expect(!wrongRow.matches(capture),
            "A runtime plot option cannot attach to another same-named tree row.")

        let uncheckedCapture = try AssociatedMapLayerCapture(projectSessionID: projectSessionID,
            mapID: mapID, mapWorkflowIdentity: "map-runtime-option", map: map,
            geometryNodes: [geometry], associationNode: terrain, assetPath: rasterPath,
            isChecked: false, effectiveVisible: false)
        #expect(!AssociatedMapLayerRasterTileOutlineToggle.supports(uncheckedCapture))
        #expect(!option.matches(uncheckedCapture),
            "A runtime plot option cannot be retained for an unchecked source row.")

        let hiddenCapture = try AssociatedMapLayerCapture(projectSessionID: projectSessionID,
            mapID: mapID, mapWorkflowIdentity: "map-runtime-option", map: map,
            geometryNodes: [geometry], associationNode: terrain, assetPath: rasterPath,
            isChecked: true, effectiveVisible: false)
        #expect(!AssociatedMapLayerRasterTileOutlineToggle.supports(hiddenCapture))
        #expect(!option.matches(hiddenCapture),
            "A runtime plot option cannot be retained for a checked but ancestor-hidden source row.")

        let classificationPath = "/tmp/raster-runtime-option/Classification/classes.hdf"
        let classification = CatalogTreeNodeLocator(rootName: "Matching Layers",
            nodeType: "Classification", nodeName: "Classification", nodePath: [1, 2],
            assetID: classificationPath, associationAssetID: classificationPath,
            associationKind: "Classification")
        let classificationCapture = try AssociatedMapLayerCapture(
            projectSessionID: projectSessionID, mapID: mapID,
            mapWorkflowIdentity: "map-runtime-option", map: map,
            geometryNodes: [geometry], associationNode: classification,
            assetPath: classificationPath, isChecked: true, effectiveVisible: true)
        #expect(!AssociatedMapLayerRasterTileOutlineToggle.supports(classificationCapture))
    }
}
