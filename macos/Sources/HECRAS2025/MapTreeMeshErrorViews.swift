import RASWorkspaceCore
import SwiftUI

struct MapMeshErrorPropertiesView: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var mapState: MapState
    @ObservedObject var session: MapTreeMeshErrorSession
    let context: MapTreeMeshErrorContext

    private var controlsDisabled: Bool {
        session.sourceReadsSuspended || session.snapshot == nil || session.isLoading
            || session.isApplying || session.snapshot?.status == "writerProtected"
    }

    private var threshold: Binding<Int> {
        Binding(get: { session.snapshot?.maxFacesPerNode ?? 8 }, set: { value in
            Task { await session.setMaxFacesPerNode(value) }
        })
    }

    private var checkMeshErrors: Binding<Bool> {
        Binding(get: { session.snapshot?.checkMeshErrors ?? false }, set: { value in
            Task { await session.setCheckMeshErrors(value) }
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L10n.text("Mesh Errors")).font(.headline)
                Spacer()
                Button {
                    Task { await session.refresh() }
                } label: {
                    Label(L10n.text("Refresh"), systemImage: "arrow.clockwise")
                }
                .disabled(session.sourceReadsSuspended || session.isLoading || session.isApplying)
            }

            if session.isLoading && session.snapshot == nil {
                ProgressView(L10n.text("Loading Mesh Errors…"))
                    .controlSize(.small)
            }
            if session.sourceReadsSuspended {
                Label(L10n.text("Mesh diagnostics are paused while a compute writer is active."),
                    systemImage: "pause.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error = session.error {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }

            if let snapshot = session.snapshot {
                Toggle(L10n.text("Check mesh errors"), isOn: checkMeshErrors)
                    .disabled(controlsDisabled)
                Stepper(value: threshold, in: 3...64) {
                    HStack {
                        Text(L10n.text("Maximum faces per node"))
                        Spacer()
                        Text("\(snapshot.maxFacesPerNode)").monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(controlsDisabled)

                sourceState(snapshot)
                if snapshot.checkMeshErrors && snapshot.status == "available" {
                    if snapshot.issues.isEmpty {
                        Label(L10n.text("No high-degree mesh nodes were found."),
                            systemImage: "checkmark.circle")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text(L10n.format("%d mesh nodes exceed the threshold", snapshot.totalIssueCount))
                            .font(.caption).foregroundStyle(.secondary)
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 4) {
                                ForEach(snapshot.issues) { issue in
                                    issueRow(issue)
                                }
                            }
                        }
                        .frame(maxHeight: 220)
                    }
                }
            } else if !session.isLoading && session.error == nil && !session.sourceReadsSuspended {
                Text(L10n.text("Mesh error properties are unavailable for this source."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .task(id: context) {
            await session.configure(context, provider: store.mapTreeMeshErrorProvider(for: mapState))
        }
    }

    @ViewBuilder
    private func sourceState(_ snapshot: MapTreeMeshErrorSnapshot) -> some View {
        switch snapshot.status {
        case "writerProtected":
            Label(L10n.text("Mesh diagnostics are waiting for the active compute writer to release this source."),
                systemImage: "hourglass")
                .font(.caption).foregroundStyle(.secondary)
        case "disabled":
            Label(L10n.text("Mesh error checking is disabled for this FlowArea."),
                systemImage: "minus.circle")
                .font(.caption).foregroundStyle(.secondary)
        case "available":
            if snapshot.isChecked == true && snapshot.isEffectivelyVisible == true {
                Label(L10n.text("Showing errors for the checked, visible FlowArea."),
                    systemImage: "eye")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Label(L10n.text("The FlowArea is hidden or unchecked; errors are not drawn on the map."),
                    systemImage: "eye.slash")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case "partial":
            Label(L10n.format("Showing %d of %d mesh errors", snapshot.issues.count,
                snapshot.totalIssueCount), systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.orange)
        case "savedReadbackUnavailable":
            VStack(alignment: .leading, spacing: 3) {
                Label(L10n.text("Mesh error settings were saved, but diagnostics could not be refreshed."),
                    systemImage: "checkmark.circle")
                    .font(.caption).foregroundStyle(.secondary)
                if let diagnostic = snapshot.diagnostic,
                   let newline = diagnostic.firstIndex(of: "\n") {
                    let detail = String(diagnostic[diagnostic.index(after: newline)...])
                    if !detail.isEmpty {
                        Text(detail).font(.caption2).foregroundStyle(.tertiary)
                            .textSelection(.enabled)
                    }
                }
            }
        default:
            Text(snapshot.diagnostic.map(L10n.text) ?? L10n.text("Mesh error status is unavailable."))
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        }
    }

    private func issueRow(_ issue: MapTreeMeshErrorIssue) -> some View {
        Button {
            session.selectIssue(issue)
            guard let viewport = MapTreeMeshErrorNavigation.viewport(for: issue,
                current: mapState.currentExtent) else { return }
            mapState.viewport = viewport
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.format("Node %d — %d faces", issue.nodeIndex, issue.faceCount))
                    Text(L10n.format("Mesh %d · %d adjacent cells", issue.meshIndex + 1, issue.cells.count))
                        .font(.caption2).foregroundStyle(.secondary)
                    Text(L10n.format("X %@, Y %@", Self.coordinate(issue.node.x), Self.coordinate(issue.node.y)))
                        .font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
                }
                Spacer(minLength: 0)
                Image(systemName: "scope").foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
            .padding(.vertical, 3)
        }
        .buttonStyle(.plain)
        .help(L10n.text("Zoom to the cells surrounding this mesh node."))
    }

    private static func coordinate(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...3)))
    }
}

enum MapTreeMeshErrorNavigation {
    static func viewport(for issue: MapTreeMeshErrorIssue,
                         current: ViewportRequest?) -> ViewportRequest? {
        let center: MapPoint
        let halfWidth: Double
        let halfHeight: Double
        if let extent = issue.extent {
            center = MapPoint(x: extent.minX / 2 + extent.maxX / 2,
                y: extent.minY / 2 + extent.maxY / 2)
            // MeshErrorProperties uses Extent.RatioAroundCenter(2.0), which
            // doubles the source cell extent around its actual center.
            let width = extent.maxX - extent.minX
            let height = extent.maxY - extent.minY
            let fallback = fallbackHalfSpan(current: current)
            halfWidth = width > 0 ? width : fallback
            halfHeight = height > 0 ? height : fallback
        } else {
            center = MapPoint(x: issue.node.x, y: issue.node.y)
            let fallback = fallbackHalfSpan(current: current)
            halfWidth = fallback
            halfHeight = fallback
        }
        let lower = MapPoint(x: center.x - halfWidth, y: center.y - halfHeight)
        let upper = MapPoint(x: center.x + halfWidth, y: center.y + halfHeight)
        guard [center.x, center.y, lower.x, lower.y, upper.x, upper.y].allSatisfy(\.isFinite),
              lower.x < upper.x, lower.y < upper.y else { return nil }
        return ViewportRequest(lowerLeft: lower, upperRight: upper, padding: 32)
    }

    private static func fallbackHalfSpan(current: ViewportRequest?) -> Double {
        guard let current else { return 1 }
        let span = max(current.upperRight.x - current.lowerLeft.x,
                       current.upperRight.y - current.lowerLeft.y)
        return span.isFinite && span > 0 ? max(span * 0.02, 1e-9) : 1
    }
}

enum MapTreeMeshErrorOverlayProjection {
    static func isVisible(_ snapshot: MapTreeMeshErrorSnapshot, mapID: UUID) -> Bool {
        snapshot.mapID.caseInsensitiveCompare(mapID.uuidString) == .orderedSame
            && snapshot.checkMeshErrors && snapshot.isChecked == true
            && snapshot.isEffectivelyVisible == true
            && (snapshot.status == "available" || snapshot.status == "partial")
    }

    static func isVisible(_ snapshot: MapTreeMeshErrorSnapshot, mapID: UUID,
                          sources: [ProjectGeometryMapSourceState]) -> Bool {
        guard isVisible(snapshot, mapID: mapID) else { return false }
        let matches = sources.filter { source in
            source.capture.mapID == mapID
                && source.capture.projectSessionID.uuidString.caseInsensitiveCompare(snapshot.projectSessionID) == .orderedSame
                && source.capture.mapWorkflowIdentity == snapshot.mapWorkflowIdentity
                && source.capture.geometryCanonicalPath == SourceFilePaths.canonical(
                    URL(fileURLWithPath: snapshot.sourcePath))
                && source.snapshot?.contextToken == snapshot.contextToken
                && source.snapshot?.geometryRevision.caseInsensitiveCompare(snapshot.sourceRevision) == .orderedSame
                && source.snapshot?.flowAreasState.locator == snapshot.flowAreaNode
        }
        guard matches.count == 1, let source = matches.first else { return false }
        if let draftIdentity = snapshot.geometryMeshDraftIdentity {
            return source.flowAreaGenerationPresentation?.phase
                == ProjectGeometryMapFlowAreaGenerationPresentation.Phase.childDraft
                && source.flowAreaGenerationPresentation?.identity == draftIdentity
        }
        return source.flowAreaGenerationPresentation == nil
    }

    @MainActor
    static func selectedIssueID(snapshot: MapTreeMeshErrorSnapshot,
                                session: MapTreeMeshErrorSession) -> String? {
        guard let context = session.context,
              context.mapID.uuidString.caseInsensitiveCompare(snapshot.mapID) == .orderedSame,
              context.flowAreaNode == snapshot.flowAreaNode,
              context.sourcePath == snapshot.sourcePath,
              context.sourceRevision.caseInsensitiveCompare(snapshot.sourceRevision) == .orderedSame,
              context.contextToken == snapshot.contextToken,
              context.geometryMeshDraftIdentity == snapshot.geometryMeshDraftIdentity else { return nil }
        return session.selectedIssueID
    }
}

struct MapTreeMeshErrorOverlayCanvas: View {
    @ObservedObject var session: MapTreeMeshErrorSession
    @ObservedObject var mapState: MapState
    let points: [MapPoint]
    let scale: CGFloat
    let offset: CGSize

    var body: some View {
        Canvas { context, size in
            guard !session.sourceReadsSuspended else { return }
            let transform = MapTransform(points: points, size: size, scale: scale, offset: offset)
            for snapshot in session.overlaySnapshots where
                MapTreeMeshErrorOverlayProjection.isVisible(snapshot, mapID: mapState.id,
                    sources: mapState.projectGeometryMap.sources) {
                let selected = MapTreeMeshErrorOverlayProjection.selectedIssueID(
                    snapshot: snapshot, session: session)
                for issue in snapshot.issues {
                    let isSelected = selected == issue.id
                    for cell in issue.cells {
                        guard cell.coordinates.count >= 3 else { continue }
                        var path = Path()
                        let projected = cell.coordinates.map { transform.screen(MapPoint(x: $0.x, y: $0.y)) }
                        guard projected.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { continue }
                        path.move(to: projected[0])
                        for point in projected.dropFirst() { path.addLine(to: point) }
                        path.closeSubpath()
                        context.fill(path, with: .color(isSelected
                            ? Color.orange.opacity(0.30) : Color.red.opacity(0.20)))
                        context.stroke(path, with: .color(isSelected
                            ? Color.orange : Color.red.opacity(0.72)), lineWidth: isSelected ? 2 : 1)
                    }
                    let node = transform.screen(MapPoint(x: issue.node.x, y: issue.node.y))
                    guard node.x.isFinite, node.y.isFinite else { continue }
                    let diameter: CGFloat = isSelected ? 10 : 7
                    let marker = Path(ellipseIn: CGRect(x: node.x - diameter / 2,
                        y: node.y - diameter / 2, width: diameter, height: diameter))
                    context.fill(marker, with: .color(isSelected ? .orange : .red))
                    context.stroke(marker, with: .color(.white.opacity(0.9)), lineWidth: 1)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
