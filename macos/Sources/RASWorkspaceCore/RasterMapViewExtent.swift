import Foundation

/// A map-coordinate viewport for source-backed raster sampling. Pixel dimensions
/// bound the work performed by the backend and preserve the visible aspect ratio.
public struct RasterMapViewExtent: Codable, Hashable, Sendable {
    public let minX: Double
    public let minY: Double
    public let maxX: Double
    public let maxY: Double
    public let pixelWidth: Int
    public let pixelHeight: Int

    public init(
        minX: Double,
        minY: Double,
        maxX: Double,
        maxY: Double,
        pixelWidth: Int = 1024,
        pixelHeight: Int = 1024
    ) {
        self.minX = minX
        self.minY = minY
        self.maxX = maxX
        self.maxY = maxY
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
}
