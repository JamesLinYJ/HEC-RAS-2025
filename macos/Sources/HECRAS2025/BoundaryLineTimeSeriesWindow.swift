import SwiftUI

@MainActor
struct BoundaryLineTimeSeriesWindow: View {
    @ObservedObject var store: WorkspaceStore
    let route: BoundaryLineTimeSeriesWindowRoute

    @Environment(\.dismiss) private var dismiss
    @State private var samples: [ChartSample] = []
    @State private var presentation = SeriesEditorPresentation()
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var activeGeneration = UUID()

    private var title: String {
        L10n.text(route.request.variable)
            + " — " + L10n.text("BC Line")
    }

    var body: some View {
        Group {
            if isLoading {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Loading Boundary Condition line series…")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage {
                ContentUnavailableView {
                    Label("Boundary Condition series unavailable", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(verbatim: errorMessage).textSelection(.enabled)
                }
            } else {
                SeriesChartView(samples: samples, presentation: presentation,
                    emptyMessage: L10n.text("No time series values are available for the selected Boundary Condition lines."))
            }
        }
        .frame(minWidth: 620, minHeight: 420)
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
        }
    }

    private func load() async {
        let generation = UUID()
        activeGeneration = generation
        samples = []
        errorMessage = nil
        guard let mapID = route.mapID,
              let capturedMapState = store.existingMapState(for: mapID),
              isCurrent(capturedMapState) else {
            errorMessage = L10n.text("The saved map or Boundary Condition source changed before the chart opened.")
            return
        }

        isLoading = true
        defer {
            if activeGeneration == generation { isLoading = false }
        }

        do {
            let provider = BackendBoundaryLineTimeSeriesProvider()
            let snapshot = try await provider.load(route) { [weak store] in
                guard let store else { return false }
                return self.activeGeneration == generation && !Task.isCancelled
                    && self.isCurrent(capturedMapState, in: store)
            }
            guard activeGeneration == generation, !Task.isCancelled,
                  isCurrent(capturedMapState) else { return }
            guard let data = BoundaryLineTimeSeriesChartData.make(from: snapshot,
                    variable: route.request.variable) else {
                throw BoundaryMapError.mismatchedReply
            }
            samples = data.samples
            presentation = data.presentation
        } catch is CancellationError {
            return
        } catch {
            guard activeGeneration == generation, !Task.isCancelled,
                  isCurrent(capturedMapState) else { return }
            errorMessage = L10n.text(error.localizedDescription)
        }
    }

    private func isCurrent(_ mapState: MapState) -> Bool {
        isCurrent(mapState, in: store)
    }

    private func isCurrent(_ mapState: MapState, in store: WorkspaceStore) -> Bool {
        guard let mapID = route.mapID,
              route.projectSessionID == store.projectSessionID,
              store.existingMapState(for: mapID) === mapState,
              store.mapWorkflowIdentity(mapID) == route.mapWorkflowIdentity,
              store.mapSourceWorkflowIdentity(mapID) == route.mapSourceWorkflowIdentity,
              store.mapResultRequest(for: mapID) == route.request.map,
              let entry = mapState.boundaryMap.entries.first(where: {
                  $0.capture.identity == route.boundaryCaptureIdentity
              }),
              entry.status == .available,
              entry.contextToken == route.request.expectedBoundaryContextToken,
              entry.boundarySourceState == route.request.boundarySourceState,
              entry.capture.resultOwner == route.request.resultOwner,
              entry.capture.boundaryNode == route.request.boundaryNode,
              entry.capture.sourceRevision.caseInsensitiveCompare(route.request.expectedBoundaryRevision) == .orderedSame else {
            return false
        }
        let visibleByID = Dictionary(entry.visibleLines.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return route.expectedLines.allSatisfy { expected in
            guard let line = visibleByID["\(entry.capture.sourceIdentity)|\(expected.id)"] else { return false }
            return line.sourceOrdinal == expected.sourceOrdinal && line.name == expected.name
        }
    }
}
