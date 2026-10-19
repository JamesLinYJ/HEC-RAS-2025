import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

struct VectorMapPlotFrameBindingTests {
    @Test
    func liveViewportTracksCanvasScaleAndOffset() throws {
        let mapID = UUID()
        let size = CGSize(width: 240, height: 120)
        let points = [MapPoint(x: 0, y: 0), MapPoint(x: 100, y: 100)]
        let baselineTransform = MapTransform(points: points, size: size, scale: 1, offset: .zero)
        let shiftedTransform = MapTransform(points: points, size: size, scale: 1.25,
            offset: CGSize(width: 18, height: -7))
        guard let baseline = MapVectorPlotFrameBinding.visibleWorldViewport(
                transform: baselineTransform, size: size),
              let shifted = MapVectorPlotFrameBinding.visibleWorldViewport(
                transform: shiftedTransform, size: size) else {
            Issue.record("The test camera must produce finite world bounds.")
            return
        }
        #expect(!baseline.matches(shifted))

        let request = RasterMapViewExtent(minX: baseline.minX, minY: baseline.minY,
            maxX: baseline.maxX, maxY: baseline.maxY, pixelWidth: 240, pixelHeight: 120)
        let frame = try VectorPlotRenderedLayer(mapID: mapID,
            sourceLayerID: "camera-layer", sourceRevision: "source",
            visualizationRevision: "vis", viewport: baseline,
            pixelWidth: 240, pixelHeight: 120,
            rgba: Data(repeating: 0, count: 240 * 120 * 4), labels: [])
        #expect(MapVectorPlotFrameBinding.currentFrame(frame,
            mapID: mapID, layerID: "camera-layer", sourceRevision: "source",
            expectedVisualizationRevision: "vis", requestedViewport: request,
            liveViewport: baseline) != nil)
        #expect(MapVectorPlotFrameBinding.currentFrame(frame,
            mapID: mapID, layerID: "camera-layer", sourceRevision: "source",
            expectedVisualizationRevision: "vis", requestedViewport: request,
            liveViewport: shifted) == nil)
    }

    @Test
    func acceptsOnlyTheCurrentMapLayerSourceRevisionAndCameraRequest() throws {
        let mapID = UUID()
        let viewport = MapVectorPlotViewport(minX: 10, minY: 20, maxX: 30, maxY: 40)
        let frame = try VectorPlotRenderedLayer(mapID: mapID,
            sourceLayerID: "map-layer-17", sourceRevision: "source-sha",
            visualizationRevision: "vis-sha", viewport: viewport,
            pixelWidth: 320, pixelHeight: 200,
            rgba: Data(repeating: 0, count: 320 * 200 * 4), labels: [])
        let request = RasterMapViewExtent(minX: 10, minY: 20, maxX: 30, maxY: 40,
            pixelWidth: 320, pixelHeight: 200)
        let liveCamera = MapVectorPlotViewport(minX: 10, minY: 20, maxX: 30, maxY: 40)

        #expect(MapVectorPlotFrameBinding.currentFrame(frame,
            mapID: mapID, layerID: "map-layer-17", sourceRevision: "source-sha",
            expectedVisualizationRevision: "vis-sha", requestedViewport: request,
            liveViewport: liveCamera) != nil)
        #expect(MapVectorPlotFrameBinding.currentFrame(frame,
            mapID: UUID(), layerID: "map-layer-17", sourceRevision: "source-sha",
            expectedVisualizationRevision: "vis-sha", requestedViewport: request,
            liveViewport: liveCamera) == nil)
        #expect(MapVectorPlotFrameBinding.currentFrame(frame,
            mapID: mapID, layerID: "other-layer", sourceRevision: "source-sha",
            expectedVisualizationRevision: "vis-sha", requestedViewport: request,
            liveViewport: liveCamera) == nil)
        #expect(MapVectorPlotFrameBinding.currentFrame(frame,
            mapID: mapID, layerID: "map-layer-17", sourceRevision: "changed-source",
            expectedVisualizationRevision: "vis-sha", requestedViewport: request,
            liveViewport: liveCamera) == nil)
        #expect(MapVectorPlotFrameBinding.currentFrame(frame,
            mapID: mapID, layerID: "map-layer-17", sourceRevision: "source-sha",
            expectedVisualizationRevision: "changed-vis", requestedViewport: request,
            liveViewport: liveCamera) == nil)

        let movedRequest = RasterMapViewExtent(minX: 11, minY: 20, maxX: 31, maxY: 40,
            pixelWidth: 320, pixelHeight: 200)
        #expect(MapVectorPlotFrameBinding.currentFrame(frame,
            mapID: mapID, layerID: "map-layer-17", sourceRevision: "source-sha",
            expectedVisualizationRevision: "vis-sha", requestedViewport: movedRequest,
            liveViewport: liveCamera) == nil)
        let movedLiveCamera = MapVectorPlotViewport(minX: 11, minY: 20, maxX: 31, maxY: 40)
        #expect(MapVectorPlotFrameBinding.currentFrame(frame,
            mapID: mapID, layerID: "map-layer-17", sourceRevision: "source-sha",
            expectedVisualizationRevision: "vis-sha", requestedViewport: request,
            liveViewport: movedLiveCamera) == nil)
        let resizedRequest = RasterMapViewExtent(minX: 10, minY: 20, maxX: 30, maxY: 40,
            pixelWidth: 640, pixelHeight: 400)
        #expect(MapVectorPlotFrameBinding.currentFrame(frame,
            mapID: mapID, layerID: "map-layer-17", sourceRevision: "source-sha",
            expectedVisualizationRevision: "vis-sha", requestedViewport: resizedRequest,
            liveViewport: liveCamera) == nil)
    }
}
