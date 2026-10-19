import RASWorkspaceCore
import SwiftUI

/// Renders the retained BoundaryConditionLine polylines in the shared map
/// camera. Each source line is an independent path; the canvas never connects
/// rows, invents endpoints, or edits their coordinates.
struct BoundaryMapCanvas: View {
    @ObservedObject private var renderScaling = WorkspaceRenderScaling.shared
    @ObservedObject var session: BoundaryMapSession
    @ObservedObject var mapState: MapState
    let points: [MapPoint]
    let scale: CGFloat
    let offset: CGSize
    let isInteractive: Bool

    init(session: BoundaryMapSession, mapState: MapState, points: [MapPoint],
         scale: CGFloat, offset: CGSize, isInteractive: Bool = true) {
        self.session = session
        self.mapState = mapState
        self.points = points
        self.scale = scale
        self.offset = offset
        self.isInteractive = isInteractive
    }

    var body: some View {
        GeometryReader { proxy in
            let renderScale = renderScaling.factor
            let transform = MapTransform(points: points, size: proxy.size, scale: scale, offset: offset)
            Canvas { context, _ in
                for presentation in session.visibleLines {
                    let coordinates = presentation.line.coordinates
                    guard coordinates.count >= 2,
                          coordinates.allSatisfy(Self.isFinite) else { continue }
                    let style = session.visualStyle(for: presentation.sourceIdentity)
                    let defaults = BoundaryMapRenderStyle.sourceDefault
                    let lineColor = SourceARGBColor.color(style.line.penColor)
                        ?? SourceARGBColor.color(defaults.line.penColor) ?? .primary
                    let vertexFill = SourceARGBColor.color(style.vertex.fillColor)
                        ?? SourceARGBColor.color(defaults.vertex.fillColor) ?? .clear
                    let vertexOutline = SourceARGBColor.color(style.vertex.penColor)
                        ?? SourceARGBColor.color(defaults.vertex.penColor) ?? .primary
                    let lineWidth = WorkspaceRenderScaling.metric(
                        Double(Self.safeWidth(style.line.penWidth, fallback: defaults.line.penWidth)), factor: renderScale)
                    let vertexWidth = WorkspaceRenderScaling.metric(
                        Double(Self.safeWidth(style.vertex.penWidth, fallback: defaults.vertex.penWidth)), factor: renderScale)
                    let vertexDiameter = WorkspaceRenderScaling.metric(
                        Double(max(style.vertex.pointSize, 0)), factor: renderScale)
                    var path = Path()
                    path.move(to: transform.screen(coordinates[0]))
                    for point in coordinates.dropFirst() { path.addLine(to: transform.screen(point)) }
                    let selected = session.selectedLineIDs.contains(presentation.id)
                    let hovered = presentation.id == session.hoveredLineID
                    let highlightColor = selected ? Color.orange : Color.accentColor

                    // Interaction feedback is an ephemeral halo behind the
                    // unchanged source line style.
                    if selected || hovered {
                        context.stroke(path, with: .color(highlightColor.opacity(selected ? 0.55 : 0.4)),
                            style: StrokeStyle(lineWidth: Self.selectionWidth(around: lineWidth, factor: renderScale),
                                               lineCap: .round, lineJoin: .round))
                    }
                    context.stroke(path, with: .color(lineColor),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))

                    if session.showsStrokeVertices(for: presentation.sourceIdentity) {
                        let finiteCoordinates = coordinates.filter(Self.isFinite)
                        var vertices = Path()
                        for point in finiteCoordinates {
                            vertices.addPath(transform.pointPath(point, diameter: vertexDiameter))
                        }
                        if selected || hovered {
                            var selectionRings = Path()
                            for point in finiteCoordinates {
                                selectionRings.addPath(transform.pointPath(point,
                                    diameter: Self.selectionDiameter(around: vertexDiameter, factor: renderScale)))
                            }
                        context.stroke(selectionRings, with: .color(highlightColor),
                            lineWidth: WorkspaceRenderScaling.metric(2, factor: renderScale))
                        }
                        context.fill(vertices, with: .color(vertexFill))
                        context.stroke(vertices, with: .color(vertexOutline), lineWidth: vertexWidth)
                    }

                    if selected || hovered {
                        let statusColor = selected ? Color.orange : Color.accentColor
                        let label = context.resolve(Text(verbatim: L10n.format("BCL: %d", presentation.line.sourceOrdinal))
                            .font(.caption2.weight(.medium)).foregroundStyle(statusColor))
                        context.draw(label, at: transform.screen(coordinates[0]), anchor: .bottomLeading)
                    }
                }
            }
            .contentShape(Rectangle())
            .gesture(SpatialTapGesture().onEnded { value in
                let transform = MapTransform(points: points, size: proxy.size, scale: scale, offset: offset)
                let modifiers = MapInput.currentModifiers()
                if !session.selectLine(at: value.location, transform: transform, modifiers: modifiers),
                   !modifiers.contains(.command), !modifiers.contains(.control) {
                    session.selectLine(nil)
                }
            }, including: isInteractive ? .all : .none)
            .onContinuousHover { phase in
                let transform = MapTransform(points: points, size: proxy.size, scale: scale, offset: offset)
                switch phase {
                case .active(let location): session.hoverLine(at: location, transform: transform)
                case .ended: session.setHoveredLine(nil)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L10n.text("Boundary Condition map lines"))
            .accessibilityValue(session.selectedLineIDs.isEmpty
                ? L10n.text("No Boundary Condition line is selected.")
                : L10n.format("%d Boundary Condition lines are selected.", session.selectedLineIDs.count))
        }
        .allowsHitTesting(session.visibleLines.isEmpty == false)
    }

    private static func isFinite(_ point: MapPoint) -> Bool {
        point.x.isFinite && point.y.isFinite
    }

    private static func safeWidth(_ value: Double, fallback: Double) -> CGFloat {
        let sourceValue = value.isFinite && value >= 0 ? value : fallback
        return CGFloat(sourceValue)
    }

    private static func selectionWidth(around width: CGFloat, factor: Double) -> CGFloat {
        let halo = WorkspaceRenderScaling.metric(4, factor: factor)
        return width <= CGFloat.greatestFiniteMagnitude - halo ? width + halo : width
    }

    private static func selectionDiameter(around diameter: CGFloat, factor: Double) -> CGFloat {
        let halo = WorkspaceRenderScaling.metric(6, factor: factor)
        return diameter <= CGFloat.greatestFiniteMagnitude - halo ? diameter + halo : diameter
    }
}
