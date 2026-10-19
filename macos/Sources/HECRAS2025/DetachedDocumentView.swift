import SwiftUI

struct DetachedSeriesRoute: Hashable, Codable {
    let sessionID: UUID
    let assetID: String
    let title: String
    let schemas: [String]
    let scope: String?
}
struct DetachedMapChartRoute: Hashable, Codable { let sessionID: UUID }
struct DetachedDynamicProfileRoute: Hashable, Codable { let sessionID: UUID }
struct DetachedDocumentRoute: Hashable, Codable {
    let projectSessionID: UUID
    let editor: String?
    let mapID: UUID?
    var chatDisplayID: UUID? = nil
    var series: DetachedSeriesRoute? = nil
    var mapChart: DetachedMapChartRoute? = nil
    var dynamicProfile: DetachedDynamicProfileRoute? = nil
}
struct DetachedDocumentView: View {
    @ObservedObject var store: WorkspaceStore
    let route: DetachedDocumentRoute?
    var body: some View {
        Group {
            if !store.hasProject || route?.projectSessionID != store.projectSessionID {
                ContentUnavailableView("Project Closed", systemImage: "folder", description: Text("Open the workspace to choose a project."))
            } else if let profile = route?.dynamicProfile {
                if let session = store.mapDynamicProfileWindows[profile.sessionID] {
                    MapDynamicProfileWindow(store: store, session: session)
                } else {
                    ContentUnavailableView(L10n.text("Profile Plot Closed"), systemImage: "chart.xyaxis.line",
                        description: Text(L10n.text("The selected map, result source, or polyline changed.")))
                }
            } else if let chart = route?.mapChart {
                if let session = store.mapChartSessions[chart.sessionID] {
                    MapResultChartWindow(session: session)
                        .onDisappear { store.unregisterMapChart(chart.sessionID) }
                } else {
                    ContentUnavailableView("Chart Closed", systemImage: "chart.xyaxis.line",
                        description: Text("The chart source or project is no longer open."))
                }
            } else if let route, let series = route.series {
                SeriesDocumentView(store: store, projectSessionID: route.projectSessionID, route: series)
            } else if let name = route?.editor, let kind = ModelEditorKind(rawValue: name) {
                ModelEditorWorkspace(store: store, kind: kind, isDetached: true)
                    .navigationTitle(L10n.text(kind.rawValue))
            } else if let id = route?.chatDisplayID, let document = store.chatDisplayDocument(id) {
                ChatDisplayView(payload: document.payload, objects: document.objects, store: store, fillsDocument: true)
                    .padding(20).navigationTitle(document.payload.displayTitle)
            } else {
                ProjectMapView(store: store, mapID: route?.mapID ?? MapState.projectMapID)
                    .navigationTitle(store.mapName(route?.mapID ?? MapState.projectMapID))
            }
        }
        .disabled(store.isSavingAll)
        .frame(minWidth: 720, minHeight: 500)
        .environment(\.locale, store.interfaceLocale)
        .preferredColorScheme(store.theme == "Dark" ? .dark : store.theme == "Light" ? .light : nil)
    }
}

struct SeriesDocumentView: View {
    @ObservedObject var store: WorkspaceStore
    let projectSessionID: UUID
    let route: DetachedSeriesRoute
    var body: some View {
        Group {
            if projectSessionID == store.projectSessionID, let session = store.editorSession(route.sessionID),
               session.modelAssetID == route.assetID, session.loaded {
                TimeSeriesPage(page: .init(title: route.title, schemaIDs: route.schemas, layout: .timeSeries, scopePrefix: route.scope), session: session, store: store, chartOnly: true)
                    .navigationTitle(L10n.text(route.title))
            } else {
                ContentUnavailableView("Series Closed", systemImage: "chart.xyaxis.line", description: Text("The source editor or project is no longer open."))
            }
        }.frame(minWidth: 680, minHeight: 420)
            .environment(\.locale, store.interfaceLocale)
    }
}
