import RASWorkspaceCore
import SwiftUI

/// A read-only coverage map for one exact Cumulus COG. Its background is the
/// active saved map's existing background-map session; it never queries the
/// debug USGS index service or invents source coverage.
@MainActor
struct CumulusGridFootprintMapPreview: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject private var mapState: MapState
    let footprint: CumulusGridFootprint
    let clipExtent: ViewportRequest?

    init(store: WorkspaceStore, mapState: MapState, footprint: CumulusGridFootprint,
         clipExtent: ViewportRequest? = nil) {
        self.store = store
        self.footprint = footprint
        self.clipExtent = clipExtent
        _mapState = ObservedObject(wrappedValue: mapState)
    }

    private var points: [MapPoint] {
        footprint.points.map { MapPoint(x: $0.x, y: $0.y) }
    }

    private var frameExtent: ViewportRequest {
        ViewportRequest(
            lowerLeft: MapPoint(x: footprint.extent.minX, y: footprint.extent.minY),
            upperRight: MapPoint(x: footprint.extent.maxX, y: footprint.extent.maxY),
            animated: false, padding: 0)
    }

    private var hasCurrentBackgroundSnapshot: Bool {
        guard let render = mapState.backgroundMapSession.snapshot?.render else { return false }
        let viewport = render.viewport
        return store.existingMapState(for: mapState.id) === mapState
            && render.mapID == mapState.id.uuidString
            && render.projectSessionID == store.projectSessionID.uuidString
            && viewport.minX < footprint.extent.maxX && viewport.maxX > footprint.extent.minX
            && viewport.minY < footprint.extent.maxY && viewport.maxY > footprint.extent.minY
    }

    var body: some View {
        GeometryReader { proxy in
            let fit = MapViewportFit(request: frameExtent, points: points, size: proxy.size)
            let scale = fit?.scale ?? 1
            let offset = fit?.offset ?? .zero
            ZStack {
                if hasCurrentBackgroundSnapshot {
                    BackgroundMapCanvas(session: mapState.backgroundMapSession,
                        points: points, scale: scale, offset: offset)
                } else {
                    Color.secondary.opacity(0.06)
                }
                Canvas { context, size in
                    guard points.count == 48, points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return }
                    let transform = MapTransform(points: points, size: size, scale: scale, offset: offset)
                    var outline = Path()
                    guard let first = points.first else { return }
                    outline.move(to: transform.screen(first))
                    for point in points.dropFirst() { outline.addLine(to: transform.screen(point)) }
                    outline.closeSubpath()
                    context.fill(outline, with: .color(.cyan.opacity(0.16)), style: FillStyle(eoFill: true))
                    context.stroke(outline, with: .color(.cyan), style: StrokeStyle(lineWidth: 2, lineJoin: .round))
                    if let clipExtent {
                        let topLeft = transform.screen(clipExtent.lowerLeft)
                        let bottomRight = transform.screen(clipExtent.upperRight)
                        let rect = CGRect(x: topLeft.x, y: bottomRight.y,
                            width: bottomRight.x - topLeft.x, height: topLeft.y - bottomRight.y).standardized
                        let clip = Path(rect)
                        context.fill(clip, with: .color(.orange.opacity(0.18)))
                        context.stroke(clip, with: .color(.orange),
                            style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                    }
                }
                .allowsHitTesting(false)
            }
            .background(Color.secondary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(alignment: .topLeading) {
                Text(L10n.text("Selected remote COG coverage"))
                    .font(.caption.weight(.semibold))
                    .padding(6)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 5))
                    .padding(6)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.25)))
        .accessibilityLabel(L10n.text("Selected COG footprint in the captured map projection"))
    }
}
