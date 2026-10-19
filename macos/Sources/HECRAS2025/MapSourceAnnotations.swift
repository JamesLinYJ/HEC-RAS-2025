import RASWorkspaceCore
import SwiftUI

/// Observes query publication separately from the Store reference so both
/// asynchronous product arrivals and exact editor capture changes redraw.
struct MapSourceAnnotations: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var mapState: MapState
    @ObservedObject var terrainOverlay: TerrainUSGSTileOverlaySession
    let points: [MapPoint]
    let scale: CGFloat
    let offset: CGSize
    let pointer: CGPoint?
    let allowsTerrainHover: Bool

    private var acceptedTerrainSnapshot: TerrainUSGSTileOverlaySnapshot? {
        guard let pending = terrainOverlay.snapshot,
              let editor = store.editorSession(pending.ticket.editorID),
              let capture = editor.captureTerrainRasterExportContext(),
              editor.isCurrentTerrainRasterExportContext(capture) else { return nil }
        return terrainOverlay.snapshot(projectSessionID: store.projectSessionID,
            mapID: mapState.id, mapWorkflowIdentity: store.mapWorkflowIdentity(mapState.id),
            terrainCapture: capture)
    }

    var body: some View {
        GeometryReader { proxy in
            let accepted = acceptedTerrainSnapshot
            let transform = MapTransform(points: points, size: proxy.size, scale: scale, offset: offset)
            let terrainPointer = allowsTerrainHover ? pointer : nil
            let tileHit = terrainPointer.flatMap { pointer in
                accepted.flatMap { TerrainUSGSTileHitTest.hit(at: transform.world(pointer), products: $0.products) }
            }
            ZStack {
                if let accepted {
                    TerrainUSGSTileMapOverlay(snapshot: accepted, points: points,
                        scale: scale, offset: offset, pointer: terrainPointer)
                }
                if tileHit == nil {
                    MapToolTipAnnotation(tool: mapState.activeToolAnnotation,
                        pointer: pointer, canvasSize: proxy.size)
                }
            }
        }
        .allowsHitTesting(false)
    }
}
