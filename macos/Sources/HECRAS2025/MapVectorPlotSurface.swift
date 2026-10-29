import RASWorkspaceCore
import SwiftUI

/// Observes transient source-rendered frames without moving the original
/// vector layers out of their selection, editing or draw-order owners.
@MainActor
struct MapVectorPlotSurface: View {
    @ObservedObject private var renderScaling = WorkspaceRenderScaling.shared
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var mapState: MapState
    @ObservedObject var provider: WorkspaceVectorSymbologyProvider
    let mapID: UUID
    let scale: CGFloat
    let offset: CGSize
    @Binding var pointer: MapPoint?
    let orderedLayers: [MapVectorLayer]

    private struct RefreshKey: Hashable {
        let projectSessionID: UUID
        let workflow: String
        let viewport: RasterMapViewExtent?
        let renderScale: Double
        let sourceIdentities: [String]
    }

    private var refreshKey: RefreshKey {
        RefreshKey(projectSessionID: store.projectSessionID,
            workflow: store.mapWorkflowIdentity(mapID), viewport: mapState.resultViewport,
            renderScale: renderScaling.factor,
            sourceIdentities: orderedLayers.map {
                $0.id + "|" + SourceFilePaths.canonical($0.url) + "|" + ($0.sourceRevision ?? "")
            })
    }

    var body: some View {
        VectorMapCanvas(store: store, mapState: mapState, mapID: mapID,
            scale: scale, offset: offset, pointer: $pointer,
            orderedLayers: orderedLayers,
            plotFrames: provider.plotFrames(mapID: mapID),
            plotViewport: mapState.resultViewport)
            .overlay(alignment: .topLeading) {
                VectorPlotRenderStatusBanner(provider: provider, mapID: mapID)
                    .padding()
            }
            .task(id: refreshKey) {
                guard store.existingMapState(for: mapID) === mapState else { return }
                await provider.refreshPlotFrames(mapID: mapID)
            }
    }
}
