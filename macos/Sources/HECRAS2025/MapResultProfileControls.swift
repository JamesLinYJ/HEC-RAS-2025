import SwiftUI

/// The source RasProfileStateSlider follows the active map context and enables
/// profile controls only when its actual context exposes profile state. The
/// native map has three concrete owners for that state; resolution preserves
/// the same linked-result, selected-result, then map-profile precedence used by
/// ProjectMapView.
@MainActor
enum MapResultProfileOwner {
    case linkedResults
    case selectedResult(MapProfileSession)
    case map(MapProfileSession)
}

@MainActor
enum MapResultProfileOwnerResolver {
    static func resolve(mapState: MapState) -> MapResultProfileOwner? {
        if mapState.linkedResults.isActive { return .linkedResults }
        if let timeline = mapState.resultMap.selectedTimeline { return .selectedResult(timeline) }
        if mapState.profiles.isConfigured { return .map(mapState.profiles) }
        return nil
    }
}

/// Mount this view at the map's timeline slot. Every displayed value and
/// action delegates to the active source-backed profile session; no synthetic
/// timeline or fallback index is created when a context has no profile state.
@MainActor
struct MapResultProfileControls: View {
    @ObservedObject var mapState: MapState

    @ViewBuilder
    var body: some View {
        switch MapResultProfileOwnerResolver.resolve(mapState: mapState) {
        case .linkedResults:
            MapLinkedProfileTimeline(mapState: mapState)
        case .selectedResult(let session):
            ProfileTimeline(mapState: mapState, session: session)
        case .map(_):
            ProfileTimeline(mapState: mapState)
        case nil:
            EmptyView()
        }
    }
}
