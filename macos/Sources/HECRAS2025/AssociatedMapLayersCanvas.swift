import RASWorkspaceCore
import SwiftUI

/// Renders only real raster bytes returned by `map.associations.load`. The
/// caller supplies the same map points used by the vector and geometry
/// canvases, so this layer shares their camera and cannot create its own map.
struct AssociatedMapLayersCanvas: View {
    @ObservedObject var session: AssociatedMapLayerSession
    @ObservedObject var mapState: MapState
    let points: [MapPoint]
    let scale: CGFloat
    let offset: CGSize

    var body: some View {
        RasterCanvas(layers: session.visibleLayers, points: points, scale: scale,
            offset: offset, revision: Int(truncatingIfNeeded: session.renderRevision))
            .allowsHitTesting(false)
            .accessibilityElement(children: .contain)
    }
}
