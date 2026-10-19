import CoreGraphics
import Foundation
import RASWorkspaceCore

struct MapSourceRasterLabel: Decodable, Equatable, Sendable {
    let text: String
    let x: Double
    let y: Double
}

/// Actual RGBA output from a retained source RenderLayer. The request viewport
/// proves which map camera produced it; raster bounds describe its rendered
/// pixel grid after the source RasterDefinition's cell-size rounding.
struct MapSourceRasterFrame: Decodable, Sendable {
    let viewport: RasterMapViewExtent
    let width: Int
    let height: Int
    let rgba: Data
    let minX: Double
    let minY: Double
    let maxX: Double
    let maxY: Double
    let labels: [MapSourceRasterLabel]

    @MainActor
    func validated(for expectedViewport: RasterMapViewExtent) throws -> MapSourceRasterFrame {
        let (pixelCount, pixelOverflow) = width.multipliedReportingOverflow(by: height)
        let (byteCount, byteOverflow) = pixelCount.multipliedReportingOverflow(by: 4)
        guard viewport == expectedViewport,
              width == expectedViewport.pixelWidth, height == expectedViewport.pixelHeight,
              width > 0, height > 0, !pixelOverflow, !byteOverflow,
              rgba.count == byteCount,
              minX.isFinite, minY.isFinite, maxX.isFinite, maxY.isFinite,
              minX < maxX, minY < maxY,
              labels.allSatisfy({ !$0.text.isEmpty && $0.x.isFinite && $0.y.isFinite }) else {
            throw BackendServiceError(code: "sourceRenderMismatch",
                message: L10n.text("The source renderer returned data for a different map viewport."))
        }
        return self
    }

    var image: CGImage? {
        let (pixelCount, pixelOverflow) = width.multipliedReportingOverflow(by: height)
        let (byteCount, byteOverflow) = pixelCount.multipliedReportingOverflow(by: 4)
        let (rowBytes, rowOverflow) = width.multipliedReportingOverflow(by: 4)
        guard width > 0, height > 0, !pixelOverflow, !byteOverflow, !rowOverflow,
              rgba.count == byteCount,
              let provider = CGDataProvider(data: rgba as CFData),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(width: width, height: height,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: rowBytes,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
                | CGBitmapInfo.byteOrder32Big.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
