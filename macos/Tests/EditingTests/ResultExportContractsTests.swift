import Foundation
import Testing
import RASWorkspaceCore
@testable import HECRAS2025

struct ResultExportContractsTests {
    private func node(_ type: String = "Result", name: String = "Run") -> CatalogTreeNodeLocator {
        CatalogTreeNodeLocator(rootName: "Plan", nodeType: type, nodeName: name,
            nodePath: [0], assetID: "/tmp/Run.hdf")
    }

    private func owner(name: String, currentProfile: Int? = 2,
                       revision: String = "rev-1") -> DepthShapefileExportOwner {
        DepthShapefileExportOwner(node: node(name: name), nodeKind: "Result", name: name,
            selectionIndex: 0, resultPath: "/tmp/\(name).hdf", resultRevision: revision,
            resultName: name, currentProfileIndex: currentProfile,
            profiles: [
                DepthShapefileExportProfile(index: 1, name: "Profile 1", time: "2025-01-01T00:00:00Z"),
                DepthShapefileExportProfile(index: 2, name: "Profile 2", time: "2025-01-02T00:00:00Z")
            ])
    }

    @Test func depthOwnerSelectionIsExplicitAndProfileScoped() {
        let first = owner(name: "First")
        let second = owner(name: "Second")
        var selection = DepthShapefileExportSelection()

        #expect(selection.ownerID == nil)
        #expect(selection.profileIndex == nil)

        selection.selectOwner(second)
        #expect(selection.ownerID == second.id)
        #expect(selection.profileIndex == 2)

        selection.selectProfile(1, for: [first, second])
        #expect(selection.profileIndex == 1)
        selection.selectProfile(99, for: [first, second])
        #expect(selection.profileIndex == nil)
    }

    @Test func depthSelectionDropsChangedExactOwnerAndMissingCurrentProfile() {
        let original = owner(name: "Run", currentProfile: 2)
        var selection = DepthShapefileExportSelection()
        selection.selectOwner(original)
        selection.retainExactOwner(in: [owner(name: "Run", currentProfile: 1, revision: "rev-2")])
        #expect(selection.ownerID == nil)
        #expect(selection.profileIndex == nil)

        let noCurrentProfile = owner(name: "No Active Profile", currentProfile: 8)
        selection.selectOwner(noCurrentProfile)
        #expect(selection.ownerID == noCurrentProfile.id)
        #expect(selection.profileIndex == nil)
    }

    @Test func rasterInspectionRejectsAnotherVisualizationRevision() {
        let mapID = UUID()
        let source = RasterMapSourceDescriptor(id: "raster-1", projectPath: "/tmp/Project.ras",
            visualizationPath: "/tmp/Project.vis", visualizationRevision: "vis-1",
            mapIndex: 0, mapName: "Current", mapType: "Project", nodePath: [0],
            nodeName: "Depth", mapLayerType: "SingleBandRasterMapLayer", filename: "depth.tif",
            filenameRelative: "depth.tif", sourcePath: "/tmp/depth.tif", sourceMapID: mapID,
            sourceRevision: "source-1")
        let reply = RasterRGBExportInspection(sourceID: source.id, sourceName: "Depth",
            sourceRevision: "source-1", visualizationRevision: "vis-2",
            fullMinX: 0, fullMinY: 0, fullMaxX: 10, fullMaxY: 10,
            currentView: nil, suggestedCellSize: nil, plotOptions: [])

        #expect(throws: (any Error).self) {
            try ResultExportReplyValidation.rasterInspection(reply, source: source)
        }
    }

    @Test func rasterPreviewRequiresTheSelectedMapIdentity() throws {
        let mapID = UUID()
        let source = RasterMapSourceDescriptor(id: "raster-1", projectPath: "/tmp/Project.ras",
            visualizationPath: "/tmp/Project.vis", visualizationRevision: "vis-1",
            mapIndex: 0, mapName: "Current", mapType: "Project", nodePath: [0],
            nodeName: "Depth", mapLayerType: "SingleBandRasterMapLayer", filename: "depth.tif",
            filenameRelative: "depth.tif", sourcePath: "/tmp/depth.tif", sourceMapID: mapID,
            sourceRevision: "source-1")
        let view = RasterMapViewExtent(minX: 0, minY: 0, maxX: 10, maxY: 10)
        let capture = RasterRGBExportCapture(projectSessionID: UUID(), mapID: mapID,
            mapWorkflowIdentity: "workflow", source: source, projectXml: "<Project />",
            currentView: view)
        let inspection = RasterRGBExportInspection(sourceID: source.id, sourceName: "Depth",
            sourceRevision: "source-1", visualizationRevision: "vis-1",
            fullMinX: 0, fullMinY: 0, fullMaxX: 10, fullMaxY: 10,
            currentView: view, suggestedCellSize: 1, plotOptions: [])
        let wrongMap = UUID()
        let raster = RasterRGBExportRasterPayload(id: source.id, sourceMapID: wrongMap.uuidString,
            name: "Depth", width: 1, height: 1, rgba: Data([0, 0, 0, 255]),
            minX: 0, minY: 0, maxX: 10, maxY: 10)
        let preview = RasterRGBExportPreview(sourceID: source.id, sourceRevision: "source-1",
            visualizationRevision: "vis-1", cellSize: 1, minX: 0, minY: 0,
            maxX: 10, maxY: 10, outputWidth: 10, outputHeight: 10,
            estimatedFileSizeBytes: 400, raster: raster)

        #expect(throws: (any Error).self) {
            try ResultExportReplyValidation.rasterPreview(preview, capture: capture,
                inspection: inspection, region: .currentView, cellSize: 1)
        }
    }

    @Test func depthPreviewRequiresTheCapturedViewportAndProfile() throws {
        let mapID = UUID()
        let map = MapResultChartMapRequest(projectPath: "/tmp/Project.ras",
            projectXml: "<Project />", projectXmlSHA: "xml-1", mapID: mapID.uuidString,
            mapIndex: 0, mapName: "Current", mapType: "Project",
            expectedVisualizationRevision: "vis-1")
        let tree = LayerTreeContext(projectSessionID: UUID(), projectURL: URL(fileURLWithPath: "/tmp/Project.ras"),
            mapID: mapID, mode: "Map", focusedGeometryIDs: [], focusedPlanIDs: [])
        let viewport = RasterMapViewExtent(minX: 0, minY: 0, maxX: 100, maxY: 50)
        let contextToken = "context"
        let snapshot = MapResultSourcesSnapshot(map: map, identity: "workflow",
            sources: MapResultChartSources(projectPath: map.projectPath,
                projectRevision: "project-1", mapID: map.mapID, mapIndex: map.mapIndex,
                mapName: map.mapName, mapType: map.mapType, projectXmlSHA: map.projectXmlSHA,
                visualizationRevision: map.expectedVisualizationRevision,
                contextToken: contextToken, activeNodes: []), selectionOverrides: [])
        let capture = DepthShapefileExportCapture(projectSessionID: UUID(), mapID: mapID,
            mapWorkflowIdentity: "workflow", map: map,
            mapTree: ResultExportMapTreeRequest(map: map, treeContext: tree),
            resultSnapshot: snapshot, selectionOverrides: [],
            contextToken: contextToken, viewport: viewport)
        let exactOwner = DepthShapefileExportOwner(node: node(), nodeKind: "Result", name: "Run",
            selectionIndex: 0, resultPath: "/tmp/Run.hdf", resultRevision: "rev-1",
            resultName: "Run", currentProfileIndex: 1,
            profiles: [DepthShapefileExportProfile(index: 1, name: "Profile 1",
                time: "2025-01-01T00:00:00Z")])
        let profile = try #require(exactOwner.profiles.first)
        let preview = DepthShapefileExportPreview(mapID: mapID.uuidString,
            contextToken: "context", resultNode: exactOwner.node, selectionIndex: 0,
            resultPath: exactOwner.resultPath, resultRevision: exactOwner.resultRevision,
            profileIndex: profile.index, profileName: profile.name, profileTime: profile.time,
            viewport: RasterMapViewExtent(minX: 10, minY: 10, maxX: 90, maxY: 40),
            cellSize: 10, simplifyDistance: 0.05, resultRaster: nil,
            polygons: [], polylines: [])

        #expect(throws: (any Error).self) {
            try ResultExportReplyValidation.depthPreview(preview, capture: capture,
                owner: exactOwner, profile: profile, cellSize: 10, simplifyDistance: 0.05)
        }
    }
}
