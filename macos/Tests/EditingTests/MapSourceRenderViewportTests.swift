import CoreGraphics
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

struct MapSourceRenderViewportTests {
    @Test
    func largeHiDPICameraKeepsAspectWithinBothSideAndTotalPixelBudgets() throws {
        let size = CGSize(width: 2_300, height: 1_200)
        let viewport = try #require(MapSourceRenderViewport.capture(
            points: [MapPoint(x: 10, y: 20), MapPoint(x: 110, y: 70)],
            size: size, scale: 1.25, offset: CGSize(width: 13, height: -9),
            deviceRenderScale: 2))

        let extent = viewport.extent
        #expect(extent.pixelWidth <= 2_048)
        #expect(extent.pixelHeight <= 2_048)
        #expect(extent.pixelWidth * extent.pixelHeight <= 2_097_152)
        let widthRatio = Double(extent.pixelWidth) / (Double(size.width) * 2)
        let heightRatio = Double(extent.pixelHeight) / (Double(size.height) * 2)
        #expect(abs(widthRatio - heightRatio) < 0.002)
        #expect(viewport.renderScale == 2 * min(
            Double(extent.pixelWidth) / Double(size.width),
            Double(extent.pixelHeight) / Double(size.height)))
        #expect(extent.minX.isFinite && extent.minY.isFinite &&
            extent.maxX.isFinite && extent.maxY.isFinite &&
            extent.minX < extent.maxX && extent.minY < extent.maxY)
    }

    @Test
    func invalidCanvasCameraDoesNotProduceASourceRasterRequest() {
        #expect(MapSourceRenderViewport.capture(points: [], size: .zero, scale: 1,
            offset: .zero, deviceRenderScale: 2) == nil)
        #expect(MapSourceRenderViewport.capture(points: [MapPoint(x: 0, y: 0)],
            size: CGSize(width: 400, height: 300), scale: 0, offset: .zero,
            deviceRenderScale: 2) == nil)
    }
}
