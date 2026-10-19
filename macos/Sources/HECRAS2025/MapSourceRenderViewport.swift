import Foundation
import RASWorkspaceCore
import SwiftUI

/// Exact visible project-world extent plus a bounded raster sample grid. The
/// retained renderer's pen scaling accounts for the sample density so the
/// resulting image keeps the same apparent line width after it is drawn into
/// the map's point-sized canvas.
struct MapSourceRenderViewport: Equatable {
    let extent: RasterMapViewExtent
    let renderScale: Double

    var identity: String {
        [extent.minX, extent.minY, extent.maxX, extent.maxY, renderScale]
            .map { String($0.bitPattern, radix: 16) }
            .joined(separator: ":") + ":\(extent.pixelWidth):\(extent.pixelHeight)"
    }

    static func capture(points: [MapPoint], size: CGSize, scale: CGFloat,
                        offset: CGSize, deviceRenderScale: Double) -> MapSourceRenderViewport? {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
              scale.isFinite, scale > 0, deviceRenderScale.isFinite,
              deviceRenderScale > 0, deviceRenderScale <= 64 else { return nil }
        let transform = MapTransform(points: points, size: size, scale: scale, offset: offset)
        guard transform.factor.isFinite, transform.factor > 0 else { return nil }
        let first = transform.world(.zero)
        let second = transform.world(CGPoint(x: size.width, y: size.height))
        let minX = min(first.x, second.x)
        let maxX = max(first.x, second.x)
        let minY = min(first.y, second.y)
        let maxY = max(first.y, second.y)
        guard minX.isFinite, maxX.isFinite, minY.isFinite, maxY.isFinite,
              minX < maxX, minY < maxY else { return nil }

        let desiredWidth = Double(size.width) * deviceRenderScale
        let desiredHeight = Double(size.height) * deviceRenderScale
        guard desiredWidth.isFinite, desiredHeight.isFinite,
              desiredWidth > 0, desiredHeight > 0 else { return nil }
        let pixelLimit = 2_097_152.0
        let samplingRatio = min(1.0, 2048.0 / desiredWidth, 2048.0 / desiredHeight,
            sqrt(pixelLimit / (desiredWidth * desiredHeight)))
        guard samplingRatio.isFinite, samplingRatio > 0 else { return nil }
        var pixelWidth = min(2048, max(1, Int((desiredWidth * samplingRatio).rounded())))
        var pixelHeight = min(2048, max(1, Int((desiredHeight * samplingRatio).rounded())))
        var pixelCount = pixelWidth * pixelHeight
        // Rounding each side can cross the area cap by a few pixels even when
        // the continuous sampling ratio is valid. Reduce the more oversampled
        // axis one pixel at a time while preserving the requested aspect ratio.
        while pixelCount > 2_097_152 {
            let widthSampling = Double(pixelWidth) / desiredWidth
            let heightSampling = Double(pixelHeight) / desiredHeight
            if widthSampling >= heightSampling, pixelWidth > 1 {
                pixelWidth -= 1
            } else if pixelHeight > 1 {
                pixelHeight -= 1
            } else {
                return nil
            }
            pixelCount = pixelWidth * pixelHeight
        }

        // One scalar controls the source renderer's isotropic pen/marker size.
        // Use the lower actual sample ratio after integer rounding so neither
        // axis can render thicker than the point-sized map would show.
        let actualSamplingRatio = min(Double(pixelWidth) / Double(size.width),
            Double(pixelHeight) / Double(size.height))
        let sourceRenderScale = deviceRenderScale * actualSamplingRatio
        guard sourceRenderScale.isFinite, sourceRenderScale > 0, sourceRenderScale <= 64 else { return nil }
        let extent = RasterMapViewExtent(minX: minX, minY: minY, maxX: maxX, maxY: maxY,
            pixelWidth: pixelWidth, pixelHeight: pixelHeight)
        return MapSourceRenderViewport(extent: extent, renderScale: sourceRenderScale)
    }
}
