import SwiftUI

/// Lets the user select one exact, visible source row as the active map
/// context. Result rows continue to synchronize with their own per-map
/// timeline; names are presentation only and never establish identity.
struct MapSourceContextPicker: View {
    @ObservedObject var mapState: MapState

    private var rows: [MapSourceRenderRecord] {
        MapRenderComposition.orderedRecords(mapState.sourceMapRenderRows)
    }
    private var selected: MapSourceRenderRecord? {
        rows.first { $0.contextIdentity == mapState.selectedSourceContextIdentity }
    }

    private func displayName(for row: MapSourceRenderRecord) -> String {
        row.locator.nodeType == "WindLayer" ? L10n.text("Wind Forces") : row.locator.nodeName
    }

    var body: some View {
        if !rows.isEmpty {
            Menu {
                ForEach(rows) { row in
                    Button {
                        mapState.selectSourceContext(row.contextIdentity)
                    } label: {
                        if selected?.contextIdentity == row.contextIdentity {
                            Label {
                                Text(verbatim: displayName(for: row))
                            } icon: {
                                Image(systemName: "checkmark")
                            }
                        } else {
                            Text(verbatim: displayName(for: row))
                        }
                    }
                }
            } label: {
                Label {
                    Text(verbatim: selected.map { displayName(for: $0) } ?? L10n.text("Map Context"))
                        .lineLimit(1)
                } icon: {
                    Image(systemName: "square.3.layers.3d")
                }
                .font(.caption.weight(.medium))
                .padding(.horizontal, 10).padding(.vertical, 7)
                .workspaceGlass()
            }
            .menuStyle(.borderlessButton)
            .help(L10n.text("Choose active map source"))
        }
    }
}

/// The map exposes one active-context legend in an interactive popover. It
/// does not stack result and associated legends over the map or use a fallback
/// from an unrelated layer.
struct MapSourceLegendButton: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var mapState: MapState
    @State private var isPresented = false

    private var row: MapSourceRenderRecord? {
        guard let identity = mapState.selectedSourceContextIdentity else { return nil }
        return MapRenderComposition.orderedRecords(mapState.sourceMapRenderRows)
            .first { $0.contextIdentity == identity }
    }

    var body: some View {
        if mapState.showLegend, let row, let presentation = legend(for: row) {
            Button { isPresented.toggle() } label: {
                Label(L10n.text("Map Legend"), systemImage: "list.bullet.rectangle")
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .workspaceGlass()
            }
            .buttonStyle(.plain)
            .popover(isPresented: $isPresented, arrowEdge: .top) {
                legendContent(presentation)
                    .frame(width: 270, height: 320)
                    .padding(10)
                    .glassEffect(.regular, in: .rect(cornerRadius: 14))
            }
        }
    }

    @ViewBuilder
    private func legendContent(_ presentation: LegendPresentation) -> some View {
        switch presentation {
        case .ramp(let legend):
            MapLegendView(legend: legend, size: CGSize(width: 250, height: 290))
        case .discrete(let title, let values):
            VStack(alignment: .leading, spacing: 8) {
                Text(verbatim: title).font(.headline).lineLimit(2)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 5) {
                        ForEach(values) { value in
                            HStack(spacing: 8) {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(color(for: value))
                                    .frame(width: 16, height: 16)
                                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(.quaternary))
                                Text(verbatim: value.label).font(.caption).lineLimit(2)
                                Spacer(minLength: 0)
                            }
                        }
                    }
                }
            }
            .padding(10)
        }
    }

    private enum LegendPresentation {
        case ramp(MapLegend)
        case discrete(String, [AssociatedMapLayerLegendValue])
    }

    private func legend(for row: MapSourceRenderRecord) -> LegendPresentation? {
        switch row.payloadKind {
        case "Result", "MultiResult":
            guard let legend = mapState.resultMap.legends(for: row.locator).first(where: {
                row.payloadLayerIDs.contains($0.id)
            }) else { return nil }
            return .ramp(legend)
        case "Terrain", "NValue", "Classification":
            guard let state = mapState.associatedMapLayers.entries.first(where: {
                $0.capture.associationNode == row.locator
            }), let payload = state.payload, payload.status == .available,
                  payload.isChecked, payload.effectiveVisible, !payload.legend.isEmpty else { return nil }
            if payload.kind == .classification {
                return .discrete(row.locator.nodeName, payload.legend)
            }
            let count = payload.legend.count
            let stops = payload.legend.enumerated().map { index, value in
                MapLegend.Stop(id: value.id,
                    position: count <= 1 ? 1 : Double(index) / Double(count - 1),
                    color: rgbaHex(value), label: value.label)
            }
            return .ramp(MapLegend(id: state.id, title: row.locator.nodeName, units: "", stops: stops))
        default:
            let sourceLegends = mapState.resultLegends + store.mapLegends
            return sourceLegends.first { row.payloadLayerIDs.contains($0.id) }.map(LegendPresentation.ramp)
        }
    }

    private func rgbaHex(_ value: AssociatedMapLayerLegendValue) -> String {
        String(format: "%02X%02X%02X%02X", value.red, value.green, value.blue, value.alpha)
    }

    private func color(for value: AssociatedMapLayerLegendValue) -> Color {
        Color(.sRGB, red: Double(value.red) / 255, green: Double(value.green) / 255,
              blue: Double(value.blue) / 255, opacity: Double(value.alpha) / 255)
    }
}
