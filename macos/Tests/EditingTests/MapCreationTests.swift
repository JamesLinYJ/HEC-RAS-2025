import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

struct MapCreationTests {
    @Test @MainActor
    func projectMapsIncludeSharedLayersWhileBuildableMapsUseOnlyExplicitMembership() throws {
        let workspace = WorkspaceStore()
        workspace.addBlankMapDocument()
        let firstBlankID = try #require(workspace.mapDocuments.first?.id)
        workspace.addBlankMapDocument()
        let secondBlankID = try #require(workspace.mapDocuments.last?.id)
        workspace.addProjectMapDocument()
        let projectMap = try #require(workspace.mapDocuments.last)

        let firstLayer = try vectorLayer("first")
        let secondLayer = try vectorLayer("second")
        let firstRaster = try rasterLayer("first-raster")
        let secondRaster = try rasterLayer("second-raster")
        let sharedLayers = [firstLayer, secondLayer]
        let sharedRasters = [firstRaster, secondRaster]
        let firstBlank = workspace.mapState(for: firstBlankID)
        let secondBlank = workspace.mapState(for: secondBlankID)
        let projectState = workspace.mapState(for: projectMap.id)

        workspace.includeMapLayer(firstLayer.id, in: firstBlankID)
        workspace.includeMapLayer(firstRaster.id, in: firstBlankID)

        #expect(projectMap.kind == .project)
        #expect(workspace.mapDocuments.first?.kind == .buildable)
        #expect(projectState.vectors(sharedLayers).map(\.id) == [firstLayer.id, secondLayer.id])
        #expect(projectState.rasters(sharedRasters).map(\.id) == [firstRaster.id, secondRaster.id])
        #expect(firstBlank.vectors(sharedLayers).map(\.id) == [firstLayer.id])
        #expect(firstBlank.rasters(sharedRasters).map(\.id) == [firstRaster.id])
        #expect(secondBlank.vectors(sharedLayers).isEmpty)
        #expect(secondBlank.rasters(sharedRasters).isEmpty)
        #expect(firstBlank.includedLayerIDs == [firstLayer.id, firstRaster.id])
        #expect(secondBlank.includedLayerIDs.isEmpty)
        #expect(projectState.includedLayerIDs.isEmpty)
    }

    @Test @MainActor
    func blankMapMembershipVisibilityAndViewportStayWithTheirMapID() throws {
        let workspace = WorkspaceStore()
        workspace.addBlankMapDocument()
        let firstID = try #require(workspace.mapDocuments.first?.id)
        workspace.addBlankMapDocument()
        let secondID = try #require(workspace.mapDocuments.last?.id)
        let first = workspace.mapState(for: firstID)
        let second = workspace.mapState(for: secondID)
        let layer = try vectorLayer("independent")

        workspace.includeMapLayer(layer.id, in: firstID)
        first.hiddenLayers.insert(layer.id)
        first.scale = 2
        first.offset = CGSize(width: 18, height: -7)
        first.viewport = ViewportRequest(lowerLeft: MapPoint(x: 1, y: 2), upperRight: MapPoint(x: 9, y: 10))
        first.currentExtent = ViewportRequest(lowerLeft: MapPoint(x: 3, y: 4), upperRight: MapPoint(x: 7, y: 8))

        #expect(first.vectors([layer]).map(\.id) == [layer.id])
        #expect(second.vectors([layer]).isEmpty)
        #expect(first.hiddenLayers == [layer.id])
        #expect(second.hiddenLayers.isEmpty)
        #expect(first.scale == 2)
        #expect(second.scale == 1)
        #expect(first.offset.width == 18 && first.offset.height == -7)
        #expect(second.offset.width == 0 && second.offset.height == 0)
        #expect(first.viewport?.id != nil)
        #expect(second.viewport?.id == nil)
        #expect(first.currentExtent?.id != nil)
        #expect(second.currentExtent?.id == nil)
    }

    private func vectorLayer(_ name: String) throws -> MapVectorLayer {
        let json = #"{"type":"FeatureCollection","features":[]}"#
        return try MapVectorLayer(data: Data(json.utf8), sourceURL: URL(fileURLWithPath: "/map-fixtures/\(name).geojson"))
    }

    private func rasterLayer(_ name: String) throws -> MapRasterLayer {
        try MapRasterLayer(id: name, name: name, width: 1, height: 1, rgba: Data([0, 0, 0, 255]),
            lowerLeft: MapPoint(x: 0, y: 0), upperRight: MapPoint(x: 1, y: 1))
    }
}
