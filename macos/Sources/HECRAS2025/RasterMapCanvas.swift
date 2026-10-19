import CoreGraphics
import RASWorkspaceCore
import SwiftUI

struct RasterMapCanvas: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var mapState: MapState
    let scale: CGFloat
    let offset: CGSize
    var orderedLayers: [MapRasterLayer]? = nil
    var body: some View {
        RasterCanvas(layers: orderedLayers ?? mapState.rasters(store.rasterLayers).filter { !mapState.hiddenLayers.contains($0.id) },
            points: mapState.transformPoints(vectors: store.mapLayers, rasters: store.rasterLayers),
            scale: scale, offset: offset, revision: store.rasterRevision + mapState.profileRenderRevision)
    }
}

struct RasterCanvas: View {
    let layers: [MapRasterLayer]
    let points: [MapPoint]
    let scale: CGFloat
    let offset: CGSize
    let revision: Int
    @State private var images: [String: CGImage] = [:]
    var body: some View {
        GeometryReader { proxy in
            let transform = MapTransform(points: points, size: proxy.size, scale: scale, offset: offset)
            Canvas { context, _ in
                for layer in layers {
                    guard let image = images[layer.id] else { continue }
                    let topLeft = transform.screen(MapPoint(x: layer.lowerLeft.x, y: layer.upperRight.y))
                    let bottomRight = transform.screen(MapPoint(x: layer.upperRight.x, y: layer.lowerLeft.y))
                    var layerContext = context; layerContext.opacity = layer.opacity
                    layerContext.draw(Image(decorative: image, scale: 1), in: CGRect(x: topLeft.x, y: topLeft.y,
                        width: bottomRight.x - topLeft.x, height: bottomRight.y - topLeft.y))
                }
            }.allowsHitTesting(false)
        }
        .task(id: String(revision) + layers.map(\.id).joined(separator: "\n")) {
            var updated: [String: CGImage] = [:]
            for layer in layers {
                guard let provider = CGDataProvider(data: layer.rgba as CFData), let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
                      let image = CGImage(width: layer.width, height: layer.height, bitsPerComponent: 8, bitsPerPixel: 32,
                        bytesPerRow: layer.width * 4, space: colorSpace,
                        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider,
                        decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { continue }
                updated[layer.id] = image
            }
            images = updated
        }
    }
}
