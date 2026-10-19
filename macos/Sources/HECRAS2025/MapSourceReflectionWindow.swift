import SwiftUI

/// An exact, project-session-scoped route to inspect the native map-source row
/// selected in a map's Components pane.
struct MapSourceReflectionRoute: Codable, Hashable {
    let projectSessionID: UUID
    let mapID: UUID
    let contextIdentity: String
}

/// Read-only reflection of the current Swift map-source context record.
///
/// The provider deliberately resolves the row on every refresh. It will not
/// keep displaying a stale row if the project, map, selection, or visible
/// source context changes while the reflection window is open.
@MainActor
struct MapSourceReflectionWindow: View {
    @ObservedObject var store: WorkspaceStore
    let route: MapSourceReflectionRoute?

    private var currentMapState: MapState? {
        guard let route,
              store.projectSessionID == route.projectSessionID,
              let mapState = store.existingMapState(for: route.mapID) else { return nil }
        return mapState
    }

    var body: some View {
        Group {
            if let route, let mapState = currentMapState {
                MapSourceReflectionContent(store: store, mapState: mapState, route: route)
            } else {
                ContentUnavailableView("Map Source Context Is No Longer Available",
                    systemImage: "point.3.connected.trianglepath.dotted",
                    description: Text("Select the same visible map component again to inspect its current context."))
            }
        }
        .frame(minWidth: 620, minHeight: 460)
    }

}

@MainActor
private struct MapSourceReflectionContent: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var mapState: MapState
    let route: MapSourceReflectionRoute

    private var exactCurrentRow: MapSourceRenderRecord? {
        let rows = MapContextComponentResolver.visibleRows(mapState.sourceMapRenderRows, mapID: route.mapID)
        return MapContextComponentResolver.exactRow(contextIdentity: route.contextIdentity, among: rows)
    }

    private var isCurrentContext: Bool {
        store.projectSessionID == route.projectSessionID
            && store.existingMapState(for: route.mapID) === mapState
            && mapState.selectedSourceContextIdentity == route.contextIdentity
            && exactCurrentRow != nil
    }

    var body: some View {
        Group {
            if isCurrentContext, let row = exactCurrentRow {
                VStack(alignment: .leading, spacing: 8) {
                    Label(row.locator.nodeName, systemImage: "point.3.connected.trianglepath.dotted")
                        .font(.headline)
                        .textSelection(.enabled)
                    Text(row.payloadKind)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    SharedVisualReflectionTreeControl(
                        rootProvider: {
                            guard store.projectSessionID == route.projectSessionID,
                                  store.existingMapState(for: route.mapID) === mapState,
                                  mapState.selectedSourceContextIdentity == route.contextIdentity else { return nil }
                            return exactCurrentRow
                        },
                        rootTitle: "MapSourceRenderRecord",
                        maxDepth: 3)
                }
                .padding(12)
            } else {
                ContentUnavailableView("Map Source Context Is No Longer Selected",
                    systemImage: "point.3.connected.trianglepath.dotted",
                    description: Text("Select this same visible component again to open its current reflection window."))
            }
        }
    }
}
