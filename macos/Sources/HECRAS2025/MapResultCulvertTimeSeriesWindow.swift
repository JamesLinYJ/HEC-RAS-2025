import SwiftUI

@MainActor
struct MapResultCulvertTimeSeriesWindow: View {
    @ObservedObject var store: WorkspaceStore
    let route: MapResultCulvertTimeSeriesWindowRoute

    @Environment(\.dismiss) private var dismiss
    @StateObject private var sourceMonitor = MapResultCulvertTimeSeriesSourceMonitor()
    @State private var capturedMapState: MapState?
    @State private var samples: [ChartSample] = []
    @State private var presentation = SeriesEditorPresentation()
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var activeGeneration = UUID()

    private var title: String {
        L10n.text(route.request.variable == "Flow"
            ? "Culvert Flow Time Series" : "Culvert Velocity Time Series")
    }

    var body: some View {
        VStack(spacing: 0) {
            if let capturedMapState {
                MapResultCulvertTimeSeriesStaleStatus(store: store,
                    mapState: capturedMapState, route: route,
                    isSourceStale: sourceMonitor.isStale)
            }
            Group {
                if isLoading {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Loading Result culvert time series…")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let errorMessage {
                    ContentUnavailableView {
                        Label("Culvert time series unavailable", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(verbatim: errorMessage).textSelection(.enabled)
                    }
                } else {
                    SeriesChartView(samples: samples, presentation: presentation,
                        emptyMessage: L10n.text("No time series values are available for the selected culvert barrels."))
                }
            }
        }
        .frame(minWidth: 700, minHeight: 480)
        .navigationTitle(title)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close", systemImage: "xmark") { dismiss() }
            }
            ToolbarItem(placement: .primaryAction) {
                if isLoading { ProgressView().controlSize(.small) }
            }
        }
        .task(id: route.identity) { await load() }
        .onDisappear {
            activeGeneration = UUID()
            isLoading = false
            sourceMonitor.stop()
        }
    }

    private func load() async {
        let generation = UUID()
        activeGeneration = generation
        samples = []
        errorMessage = nil
        guard let mapID = route.mapID,
              let mapState = store.existingMapState(for: mapID),
              store.isCurrentMapResultCulvertTimeSeriesRoute(route, state: mapState) else {
            errorMessage = L10n.text("The selected Result or map context changed before the culvert time series opened.")
            return
        }
        capturedMapState = mapState
        isLoading = true
        defer {
            if activeGeneration == generation { isLoading = false }
        }

        do {
            let snapshot = try await BackendMapResultCulvertTimeSeriesProvider().load(route) {
                [weak store, weak mapState] in
                guard let store, let mapState else { return false }
                return self.activeGeneration == generation && !Task.isCancelled
                    && store.isCurrentMapResultCulvertTimeSeriesRoute(route, state: mapState)
            }
            guard activeGeneration == generation, !Task.isCancelled,
                  store.isCurrentMapResultCulvertTimeSeriesRoute(route, state: mapState) else { return }
            guard let data = MapResultCulvertTimeSeriesChartData.make(from: snapshot,
                    variable: route.request.variable) else {
                throw MapResultCulvertTimeSeriesError.invalidReply
            }
            samples = data.samples
            presentation = data.presentation
            sourceMonitor.start(route: route)
        } catch is CancellationError {
            guard activeGeneration == generation, !Task.isCancelled else { return }
            if !store.isCurrentMapResultCulvertTimeSeriesRoute(route, state: mapState) {
                errorMessage = L10n.text("The selected Result or project changed while the culvert time series was loading.")
            }
        } catch {
            guard activeGeneration == generation, !Task.isCancelled else { return }
            errorMessage = L10n.text(error.localizedDescription)
        }
    }
}

@MainActor
private struct MapResultCulvertTimeSeriesStaleStatus: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var mapState: MapState
    let route: MapResultCulvertTimeSeriesWindowRoute
    let isSourceStale: Bool

    var body: some View {
        if isSourceStale || !store.isCurrentMapResultCulvertTimeSeriesRoute(route, state: mapState) {
            Label("The Result or map source changed after this chart was read. The displayed values are the retained snapshot.",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.orange.opacity(0.12))
        }
    }
}
