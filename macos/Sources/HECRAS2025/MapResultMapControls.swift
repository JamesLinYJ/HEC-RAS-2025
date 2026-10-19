import SwiftUI

struct MapResultMapControls: View {
    @ObservedObject var session: MapResultMapSession

    private var selectedNodeBinding: Binding<String> {
        Binding(get: { session.selectedNodeID ?? "" }, set: session.selectNode)
    }

    private var selectedLayerBinding: Binding<String> {
        Binding(get: { session.selectedLayerID ?? "" }, set: session.selectResultLayer)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                MapResultVelocityParticlesButton(session: session.velocityParticles)

                if !session.nodes.isEmpty {
                    Picker("Result Node", selection: selectedNodeBinding) {
                        ForEach(session.nodes) { node in
                            Text(node.name).tag(node.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .help("Choose the result node whose timeline is shown below.")

                    Picker("Result Layer", selection: selectedLayerBinding) {
                        ForEach(session.selectedLayers) { layer in
                            Text(layer.name).tag(layer.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .disabled(session.selectedLayers.isEmpty)
                    .help("Choose which result layer's legend to show. All result layers remain visible on the map.")
                }

                Button(action: session.reload) {
                    Label("Reload Result Map", systemImage: "arrow.clockwise")
                }
                .disabled(session.nodes.isEmpty || session.isLoading || session.isReloading
                    || session.isSourceReadsSuspended)

                if session.isLoading || session.isReloading {
                    ProgressView().controlSize(.small)
                        .accessibilityLabel(Text(session.isLoading ? "Loading result map" : "Reloading result map"))
                }
            }

            if session.nodes.isEmpty {
                Text(session.unavailableMessage ?? L10n.text("No active Result map nodes are available."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            } else if let message = session.unavailableMessage {
                Label("Result map unavailable", systemImage: "exclamationmark.triangle")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            if let node = session.selectedNode, let status = node.liveComputeStatus {
                HStack(spacing: 7) {
                    Image(systemName: "hourglass")
                    Text(L10n.format("Active Result status: %@", L10n.text(status.localizedTitle)))
                    if status == .running, let fraction = node.liveComputeFraction {
                        ProgressView(value: fraction).frame(maxWidth: 120)
                    }
                }
                .font(.caption).foregroundStyle(status == .failed ? .red : .secondary)
                if node.liveProfileMetadataCount > 0 {
                    Text(L10n.format("Profile names and times received: %d",
                        node.liveProfileMetadataCount))
                        .font(.caption2).foregroundStyle(.secondary)
                }
                if node.isLiveProfileMetadataOnly {
                    Text(L10n.text("Live profile metadata does not include readable raster frames."))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }

            if let legend = session.selectedLegend {
                MapLegendView(legend: legend, size: CGSize(width: 230, height: 170))
            } else if session.selectedNode?.layerCount ?? 0 > 0 {
                Text("No result legend is available for the selected layer.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .workspaceGlass()
    }
}
