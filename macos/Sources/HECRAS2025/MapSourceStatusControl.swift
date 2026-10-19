import SwiftUI

/// Map diagnostics stay available without covering the drawing area. The
/// status is attached to the map chrome and includes the original per-source
/// progress/error detail in a native, scrollable popover.
struct MapSourceStatusControl: View {
    @ObservedObject var geometry: ProjectGeometryMapSession
    @ObservedObject var associated: AssociatedMapLayerSession
    @ObservedObject var store: WorkspaceStore
    let mapID: UUID
    let refreshGeometry: @MainActor () -> Void

    @State private var isPresented = false

    private var shouldShow: Bool {
        geometry.isConfigured || geometry.error != nil || associated.isConfigured
            || associated.errorMessage != nil || !associated.preflightDiagnostics.isEmpty
    }

    private var issueCount: Int {
        let geometryIssues = (geometry.error == nil ? 0 : 1) + geometry.preflightDiagnostics.count
            + geometry.sources.filter { $0.error != nil }.count
        let associatedIssues = (associated.errorMessage == nil ? 0 : 1)
            + associated.preflightDiagnostics.count
            + associated.entries.filter { $0.status == .unavailable || $0.status == .failed }.count
        return geometryIssues + associatedIssues
    }

    var body: some View {
        if shouldShow {
            Button { isPresented.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: issueCount == 0 ? "square.3.layers.3d" : "exclamationmark.triangle.fill")
                    Text(L10n.text("Map Sources"))
                    if issueCount > 0 {
                        Text(issueCount.formatted()).monospacedDigit()
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(.orange.opacity(0.18), in: Capsule())
                    }
                    if geometry.isLoading || associated.isLoading {
                        ProgressView().controlSize(.small)
                    }
                }
                .font(.caption.weight(.medium))
                .padding(.horizontal, 10).padding(.vertical, 7)
                .workspaceGlass()
            }
            .buttonStyle(.plain)
            .popover(isPresented: $isPresented, arrowEdge: .top) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if geometry.isConfigured || geometry.error != nil {
                            ProjectGeometryMapStatusOverlay(session: geometry, store: store,
                                mapID: mapID, refreshConfiguration: refreshGeometry)
                            Divider()
                        }
                        associatedStatus
                    }
                    .padding(12)
                }
                .frame(width: 390, height: 430)
            }
            .help(L10n.text("Map Sources"))
        }
    }

    @ViewBuilder
    private var associatedStatus: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(L10n.text("Associated Layers")).font(.headline)
            if associated.isLoading {
                Label(L10n.text("Loading associated layers"), systemImage: "hourglass")
                    .font(.caption.weight(.medium))
            }
            if let error = associated.errorMessage {
                Label(L10n.text("Associated layers unavailable"), systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.medium)).foregroundStyle(.orange)
                Text(L10n.text(error)).font(.caption).foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            ForEach(associated.preflightDiagnostics.indices, id: \.self) { index in
                Text(L10n.text(associated.preflightDiagnostics[index]))
                    .font(.caption).foregroundStyle(.orange).textSelection(.enabled)
            }
            ForEach(associated.entries.filter({ $0.status != nil && $0.status != .available })) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.capture.associationNode.nodeName).font(.caption.weight(.medium))
                    if let status = entry.status {
                        Text(L10n.text(status.rawValue.capitalized)).font(.caption).foregroundStyle(.secondary)
                    }
                    if let diagnostic = entry.diagnostic, !diagnostic.isEmpty {
                        Text(L10n.text(diagnostic)).font(.caption).foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
            if !associated.isLoading, associated.errorMessage == nil,
               associated.preflightDiagnostics.isEmpty,
               associated.entries.allSatisfy({ $0.status == nil || $0.status == .available }) {
                Text(L10n.text("No source issues are reported."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
