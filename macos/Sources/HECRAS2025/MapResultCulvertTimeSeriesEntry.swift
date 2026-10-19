import SwiftUI

@MainActor
struct MapResultCulvertTimeSeriesEntry: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var mapState: MapState
    @ObservedObject var session: StoredCulvertProfileSession
    @Environment(\.openWindow) private var openWindow
    @State private var selectedBarrelIDs: Set<String> = []
    @State private var message: String?

    private var capture: StoredCulvertProfileCapture? { session.capture }
    private var profile: MapResultCulvertProfileSnapshot? { session.snapshot }
    private var canUseSource: Bool {
        guard let capture, let profile else { return false }
        return store.mapResultCulvertTimeSeriesCaptureIsCurrent(capture,
            profile: profile, state: mapState, mapID: mapState.id)
    }
    private var canPlotSource: Bool {
        canUseSource && profile?.outputAvailable == true
    }
    private var selectedIDsInSourceOrder: [String] {
        (profile?.barrels ?? []).filter { selectedBarrelIDs.contains($0.id) }.map(\.id)
    }

    @ViewBuilder
    var body: some View {
        if session.capture != nil || session.snapshot != nil || session.isLoading {
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    if session.isLoading && profile == nil {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Loading Result culvert barrels…").foregroundStyle(.secondary)
                        }
                    } else if let profile, profile.geometryAvailable, !profile.barrels.isEmpty {
                        HStack {
                            Button("Select All") { selectedBarrelIDs = Set(profile.barrels.map(\.id)) }
                                .disabled(!canUseSource)
                            Button("Deselect All") { selectedBarrelIDs.removeAll() }
                                .disabled(selectedBarrelIDs.isEmpty)
                            Spacer()
                            Text(L10n.format("%d selected", selectedIDsInSourceOrder.count))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        ScrollView {
                            VStack(alignment: .leading, spacing: 3) {
                                ForEach(profile.barrels) { barrel in
                                    Toggle(isOn: selectionBinding(for: barrel.id)) {
                                        Text(barrel.name.isEmpty
                                            ? L10n.format("Culvert Barrel %d", barrel.sourceOrdinal + 1)
                                            : barrel.name)
                                            .lineLimit(1)
                                    }
                                    .toggleStyle(.checkbox)
                                    .disabled(!canUseSource)
                                    .accessibilityIdentifier("result-culvert-barrel-\(barrel.sourceOrdinal)")
                                }
                            }
                        }
                        .frame(maxHeight: min(CGFloat(profile.barrels.count) * 25, 150))

                        HStack(spacing: 8) {
                            Button("Copy Selection", systemImage: "doc.on.doc") { copySelection(profile) }
                                .disabled(!canUseSource || selectedIDsInSourceOrder.isEmpty)
                            Button("Plot Culvert Flow", systemImage: "chart.xyaxis.line") {
                                openTimeSeries(variable: "Flow")
                            }
                            .disabled(!canPlotSource || selectedIDsInSourceOrder.isEmpty)
                            Button("Plot Culvert Velocity", systemImage: "chart.xyaxis.line") {
                                openTimeSeries(variable: "Velocity")
                            }
                            .disabled(!canPlotSource || selectedIDsInSourceOrder.isEmpty)
                        }
                        .controlSize(.small)
                        if !canUseSource {
                            Label("The Result culvert source is out of date. Refresh the map before continuing.",
                                  systemImage: "exclamationmark.triangle")
                                .font(.caption).foregroundStyle(.orange)
                        }
                    } else if let diagnostic = session.diagnostic, !diagnostic.isEmpty {
                        Text(L10n.text(diagnostic)).font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("No Result-owned culvert barrels are available.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let message {
                        Text(L10n.text(message)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Label("Result Culvert Barrels", systemImage: "water.waves")
            }
            .onChange(of: capture?.identity) { _, _ in
                selectedBarrelIDs.removeAll()
                message = nil
            }
            .onChange(of: profile?.barrels) { _, newValue in
                let currentIDs = Set((newValue ?? []).map(\.id))
                selectedBarrelIDs.formIntersection(currentIDs)
            }
        }
    }

    private func selectionBinding(for id: String) -> Binding<Bool> {
        Binding(get: { selectedBarrelIDs.contains(id) }, set: { selected in
            if selected { selectedBarrelIDs.insert(id) }
            else { selectedBarrelIDs.remove(id) }
            message = nil
        })
    }

    private func copySelection(_ profile: MapResultCulvertProfileSnapshot) {
        guard canUseSource, !selectedIDsInSourceOrder.isEmpty else { return }
        let selected = Set(selectedIDsInSourceOrder)
        let payload = profile.barrels.filter { selected.contains($0.id) }.map { barrel in
            GeometryCulvertCopiedBarrel(draftID: "", name: barrel.name,
                barrelPropertyName: barrel.barrelPropertyName,
                upstreamInvert: barrel.upstreamInvert,
                downstreamInvert: barrel.downstreamInvert,
                upstreamOpeningName: barrel.upstreamOpeningName,
                downstreamOpeningName: barrel.downstreamOpeningName,
                polyline: barrel.coordinates.map { GeometryCulvertCoordinate(x: $0.x, y: $0.y) })
        }
        message = GeometryCulvertClipboard.write(payload)
            ? L10n.text("Selected culvert barrels copied.")
            : L10n.text("The selected culvert data is too large to copy.")
    }

    private func openTimeSeries(variable: String) {
        guard canPlotSource, !selectedIDsInSourceOrder.isEmpty else { return }
        do {
            let route = try store.mapResultCulvertTimeSeriesRoute(mapID: mapState.id,
                barrelIDs: selectedIDsInSourceOrder, variable: variable)
            openWindow(value: route)
            message = nil
        } catch {
            message = error.localizedDescription
        }
    }
}
