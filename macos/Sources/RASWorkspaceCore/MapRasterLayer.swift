import Foundation

// A rendering contract for the original terrain/result raster layers. The
// model adapter supplies georeferencing and RGBA pixels; UI code does not
// interpret HDF datasets, reproject coordinates, or calculate hydraulic data.
public struct MapRasterLayer: Identifiable, Sendable {
    public let id: String
    /// When this raster comes from a `.vis` Map/Tree node, binds it to the
    /// native map document that owns that node. Result/profile rasters remain
    /// unscoped and keep the default `nil` value.
    public let sourceMapID: UUID?
    public let name: String
    public let width: Int
    public let height: Int
    public let rgba: Data
    public let lowerLeft: MapPoint
    public let upperRight: MapPoint
    public let opacity: Double
    public var points: [MapPoint] { [lowerLeft, upperRight] }
    public init(id: String, name: String, width: Int, height: Int, rgba: Data,
                lowerLeft: MapPoint, upperRight: MapPoint, opacity: Double = 1,
                sourceMapID: UUID? = nil) throws {
        let count = width.multipliedReportingOverflow(by: height)
        let byteCount = count.partialValue.multipliedReportingOverflow(by: 4)
        guard width > 0, height > 0, !count.overflow, !byteCount.overflow, rgba.count == byteCount.partialValue,
              lowerLeft.x.isFinite, lowerLeft.y.isFinite, upperRight.x.isFinite, upperRight.y.isFinite,
              upperRight.x > lowerLeft.x, upperRight.y > lowerLeft.y,
              opacity.isFinite, (0...1).contains(opacity) else {
            throw ProjectFileError.invalid("Invalid raster rendering data.")
        }
        self.id = id; self.sourceMapID = sourceMapID; self.name = name; self.width = width; self.height = height; self.rgba = rgba
        self.lowerLeft = lowerLeft; self.upperRight = upperRight; self.opacity = opacity
    }
}
