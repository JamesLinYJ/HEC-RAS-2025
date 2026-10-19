import SwiftUI
import RASWorkspaceCore

/// Native drawing and hit testing for source coordinates returned by the
/// renamed geometry topology reader. It deliberately does not invent a basemap
/// or substitute mesh-build/result geometry for the saved topology.
struct GeometryTopologyMapView: View {
    @ObservedObject private var renderScaling = WorkspaceRenderScaling.shared
    let map: GeometryTopologyMapData
    let cameraIdentity: String?
    let activeFeatureKind: String
    let selectedIDs: Set<String>
    var diagnosticFeatureIDs: Set<String> = []
    let arcStyle: VectorStyleValues
    let internalPointStyle: VectorStyleValues
    let nodeStyle: VectorStyleValues
    let deletableNodeStyle: VectorStyleValues
    let selectionChanged: (Set<String>) -> Void

    @State private var visibleKinds: Set<String> = ["arc", "region", "node"]
    @State private var showsArcVertices = false
    @State private var zoom = 1.0
    @State private var pan = CGSize.zero
    @State private var dragOffset = CGSize.zero
    @State private var panAtDragStart = CGSize.zero
    @State private var draggingMap = false

    private var currentPan: CGSize {
        CGSize(width: pan.width + dragOffset.width, height: pan.height + dragOffset.height)
    }

    private var visibleFeatures: [GeometryTopologyMapFeature] {
        map.features.filter { visibleKinds.contains($0.featureKind) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Label(L10n.text("Topology map"), systemImage: "map")
                    .font(.headline)
                Spacer(minLength: 10)
                layerToggle("arc", title: "Arcs")
                layerToggle("region", title: "Regions")
                layerToggle("node", title: "Nodes")
                Toggle(L10n.text("Show Arc Vertices"), isOn: $showsArcVertices)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .help(L10n.text("Show Arc Vertices"))
                Divider().frame(height: 18)
                Button {
                    zoom = max(0.55, zoom / 1.25)
                } label: {
                    Image(systemName: "minus.magnifyingglass")
                }
                .help(L10n.text("Zoom out"))
                .accessibilityLabel(L10n.text("Zoom out"))
                .disabled(zoom <= 0.55)

                Button {
                    zoom = min(5, zoom * 1.25)
                } label: {
                    Image(systemName: "plus.magnifyingglass")
                }
                .help(L10n.text("Zoom in"))
                .accessibilityLabel(L10n.text("Zoom in"))
                .disabled(zoom >= 5)

                Button {
                    zoom = 1
                    pan = .zero
                    dragOffset = .zero
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }
                .help(L10n.text("Fit extent"))
                .accessibilityLabel(L10n.text("Fit extent"))
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            GeometryReader { geometry in
                let renderScale = renderScaling.factor
                Canvas { context, size in
                    guard let projection = GeometryTopologyMapProjection(extent: map.extent, size: size,
                                                                           zoom: zoom, pan: currentPan) else {
                        return
                    }
                    drawPolygons(in: &context, projection: projection, renderScale: renderScale)
                    drawLines(in: &context, projection: projection, renderScale: renderScale)
                    if showsArcVertices { drawArcVertices(in: &context, projection: projection, renderScale: renderScale) }
                    drawPoints(in: &context, projection: projection, renderScale: renderScale)
                    drawDiagnosticHighlights(in: &context, projection: projection, renderScale: renderScale)
                }
                .background(Color(nsColor: .textBackgroundColor).opacity(0.55))
                .overlay {
                    if map.features.isEmpty || map.extent == nil {
                        VStack(spacing: 7) {
                            Image(systemName: "map")
                                .font(.title2)
                                .foregroundStyle(.secondary)
                            Text(L10n.text("No source geometry coordinates are available."))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                            Text(L10n.text("Click a source feature on the map to select it."))
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(14)
                        .allowsHitTesting(false)
                    }
                }
                .contentShape(Rectangle())
                .help(L10n.text("Drag to pan; click to select."))
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let distance = hypot(value.translation.width, value.translation.height)
                        guard distance > 5 else { return }
                        if !draggingMap {
                            panAtDragStart = pan
                            draggingMap = true
                        }
                        dragOffset = value.translation
                    }
                    .onEnded { value in
                        if draggingMap {
                            pan = CGSize(width: panAtDragStart.width + value.translation.width,
                                         height: panAtDragStart.height + value.translation.height)
                            dragOffset = .zero
                            draggingMap = false
                        } else {
                            selectionChanged(selection(at: value.location, canvasSize: geometry.size))
                        }
                    })
            }
            .frame(minHeight: 220, idealHeight: 320)

            Divider()
            extentFooter
        }
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(.quaternary, lineWidth: 1)
        }
        .onChange(of: cameraIdentity) { _, _ in
            resetCamera()
        }
        .onChange(of: map.extent) { oldExtent, newExtent in
            if oldExtent != newExtent { resetCamera() }
        }
    }

    private func resetCamera() {
        zoom = 1
        pan = .zero
        dragOffset = .zero
        draggingMap = false
    }

    private func layerToggle(_ kind: String, title: String) -> some View {
        Toggle(L10n.text(title), isOn: Binding(
            get: { visibleKinds.contains(kind) },
            set: { isVisible in
                if isVisible { visibleKinds.insert(kind) }
                else { visibleKinds.remove(kind) }
            }))
            .toggleStyle(.checkbox)
            .controlSize(.small)
            .help(L10n.text("Map layers") + ": " + L10n.text(title))
            .accessibilityLabel(L10n.text(title))
    }

    private var extentFooter: some View {
        HStack(spacing: 8) {
            Label(L10n.text("Source extent"), systemImage: "arrow.up.left.and.arrow.down.right")
                .foregroundStyle(.secondary)
            if let extent = map.extent {
                Text("X  \(coordinateText(extent.minX)) … \(coordinateText(extent.maxX))")
                Text("Y  \(coordinateText(extent.minY)) … \(coordinateText(extent.maxY))")
            } else {
                Text(L10n.text("Extent unavailable"))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .font(.caption.monospacedDigit())
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    private func coordinateText(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(2...5)))
    }

    private func drawPolygons(in context: inout GraphicsContext, projection: GeometryTopologyMapProjection,
                              renderScale: Double) {
        for feature in visibleFeatures where feature.geometryType == "polygon" {
            let path = screenPath(for: feature, projection: projection, close: true)
            guard !path.isEmpty else { continue }
            let selected = isSelected(feature)
            let fill = selected ? Color.accentColor.opacity(0.24) : Color.indigo.opacity(0.075)
            let stroke = selected ? Color.accentColor : Color.indigo.opacity(0.7)
            context.fill(path, with: .color(fill), style: FillStyle(eoFill: true, antialiased: true))
            let width = WorkspaceRenderScaling.metric(selected ? 2.6 : 1.2, factor: renderScale)
            context.stroke(path, with: .color(stroke), style: StrokeStyle(lineWidth: width, lineJoin: .round))
        }
    }

    private func drawLines(in context: inout GraphicsContext, projection: GeometryTopologyMapProjection,
                           renderScale: Double) {
        for feature in visibleFeatures where feature.geometryType == "line" {
            let path = screenPath(for: feature, projection: projection, close: false)
            guard !path.isEmpty else { continue }
            let selected = isSelected(feature)
            let appearance = GeometryMapStylePresentation.topologyArc(arcStyle, selected: selected,
                                                                      renderScale: renderScale)
            context.stroke(path, with: .color(GeometryMapStylePresentation.color(for: appearance.ink)),
                           style: StrokeStyle(lineWidth: CGFloat(appearance.width), lineCap: .round, lineJoin: .round))
        }
    }

    private func drawArcVertices(in context: inout GraphicsContext, projection: GeometryTopologyMapProjection,
                                 renderScale: Double) {
        let appearance = GeometryMapStylePresentation.arcInternalPoint(internalPointStyle,
                                                                       renderScale: renderScale)
        let fill = GeometryMapStylePresentation.color(for: appearance.fill)
        let outline = GeometryMapStylePresentation.color(for: appearance.outline)
        let diameter = CGFloat(appearance.diameter)
        for feature in visibleFeatures where feature.featureKind == "arc" && feature.geometryType == "line" {
            for path in feature.paths where path.count > 2 {
                for coordinate in path.dropFirst().dropLast() {
                    let center = projection.project(coordinate)
                    let marker = Path(ellipseIn: CGRect(x: center.x - diameter / 2,
                        y: center.y - diameter / 2, width: diameter, height: diameter))
                    context.fill(marker, with: .color(fill))
                    context.stroke(marker, with: .color(outline), lineWidth: CGFloat(appearance.outlineWidth))
                }
            }
        }
    }

    private func drawPoints(in context: inout GraphicsContext, projection: GeometryTopologyMapProjection,
                            renderScale: Double) {
        for feature in visibleFeatures where feature.geometryType == "point" {
            guard let coordinate = feature.paths.first?.first else { continue }
            let center = projection.project(coordinate)
            let selected = isSelected(feature)
            let radius: CGFloat
            let fill: Color
            let outline: Color
            let outlineWidth: CGFloat
            if feature.featureKind == "node" {
                let appearance = GeometryMapStylePresentation.topologyNode(
                    nodeStyle, deletableStyle: deletableNodeStyle, selected: selected,
                    incidentArcs: feature.incidentArcs,
                    worldUnitsPerPoint: projection.worldUnitsPerPoint,
                    sourceDefaultPointSize: GeometryMapStylePresentation.sourceTopologyNodePointSize,
                    renderScale: renderScale)
                radius = CGFloat(appearance.diameter / 2)
                fill = GeometryMapStylePresentation.color(for: appearance.fill)
                outline = GeometryMapStylePresentation.color(for: appearance.outline)
                outlineWidth = CGFloat(appearance.outlineWidth)
            } else {
                radius = WorkspaceRenderScaling.metric(selected ? 5.5 : 4.5, factor: renderScale)
                fill = selected ? .accentColor : .indigo
                outline = .white.opacity(0.9)
                outlineWidth = WorkspaceRenderScaling.metric(0.9, factor: renderScale)
            }
            let point = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius,
                                             width: radius * 2, height: radius * 2))
            context.fill(point, with: .color(fill))
            context.stroke(point, with: .color(outline), lineWidth: outlineWidth)
        }
    }

    private func drawDiagnosticHighlights(in context: inout GraphicsContext,
                                          projection: GeometryTopologyMapProjection,
                                          renderScale: Double) {
        let color = Color.pink
        for feature in visibleFeatures where diagnosticFeatureIDs.contains(feature.id) {
            switch feature.geometryType {
            case "polygon":
                let path = screenPath(for: feature, projection: projection, close: true)
                guard !path.isEmpty else { continue }
                context.stroke(path, with: .color(color),
                    style: StrokeStyle(lineWidth: WorkspaceRenderScaling.metric(4, factor: renderScale),
                                       lineJoin: .round, dash: [7, 4]))
            case "line":
                let path = screenPath(for: feature, projection: projection, close: false)
                guard !path.isEmpty else { continue }
                context.stroke(path, with: .color(color),
                    style: StrokeStyle(lineWidth: WorkspaceRenderScaling.metric(5, factor: renderScale),
                                       lineCap: .round, lineJoin: .round, dash: [7, 4]))
            case "point":
                guard let coordinate = feature.paths.first?.first else { continue }
                let center = projection.project(coordinate)
                let diameter = WorkspaceRenderScaling.metric(20, factor: renderScale)
                let ring = Path(ellipseIn: CGRect(x: center.x - diameter / 2, y: center.y - diameter / 2,
                                                  width: diameter, height: diameter))
                context.stroke(ring, with: .color(color),
                               lineWidth: WorkspaceRenderScaling.metric(3, factor: renderScale))
            default:
                continue
            }
        }
    }

    private func screenPath(for feature: GeometryTopologyMapFeature,
                            projection: GeometryTopologyMapProjection, close: Bool) -> Path {
        var result = Path()
        for path in feature.paths where !path.isEmpty {
            let points = path.map(projection.project)
            guard let first = points.first else { continue }
            result.move(to: first)
            for point in points.dropFirst() { result.addLine(to: point) }
            if close { result.closeSubpath() }
        }
        return result
    }

    private func isSelected(_ feature: GeometryTopologyMapFeature) -> Bool {
        feature.featureKind == activeFeatureKind && !selectedIDs.isDisjoint(with: feature.selectionIDs)
    }

    private func selection(at location: CGPoint, canvasSize: CGSize) -> Set<String> {
        let hitTolerance = max(WorkspaceRenderScaling.metric(10, factor: renderScaling.factor), 10)
        let lineTolerance = max(WorkspaceRenderScaling.metric(7, factor: renderScaling.factor), 7)
        guard let projection = GeometryTopologyMapProjection(extent: map.extent, size: canvasSize,
                                                               zoom: zoom, pan: pan) else { return [] }
        let candidates = visibleFeatures.filter { $0.featureKind == activeFeatureKind }

        for feature in candidates.reversed() where feature.geometryType == "point" {
            guard let coordinate = feature.paths.first?.first else { continue }
            let point = projection.project(coordinate)
            if hypot(point.x - location.x, point.y - location.y) <= hitTolerance { return Set(feature.selectionIDs) }
        }
        for feature in candidates.reversed() where feature.geometryType == "line" {
            guard let path = feature.paths.first, path.count >= 2 else { continue }
            let points = path.map(projection.project)
            for (start, end) in zip(points, points.dropFirst()) where distance(location, toSegmentFrom: start, to: end) <= lineTolerance {
                return Set(feature.selectionIDs)
            }
        }
        for feature in candidates.reversed() where feature.geometryType == "polygon" {
            let path = screenPath(for: feature, projection: projection, close: true)
            if path.contains(location, eoFill: true) { return Set(feature.selectionIDs) }
        }
        return []
    }

    private func distance(_ point: CGPoint, toSegmentFrom start: CGPoint, to end: CGPoint) -> CGFloat {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let denominator = dx * dx + dy * dy
        guard denominator > 0 else { return hypot(point.x - start.x, point.y - start.y) }
        let fraction = min(1, max(0, ((point.x - start.x) * dx + (point.y - start.y) * dy) / denominator))
        let projection = CGPoint(x: start.x + fraction * dx, y: start.y + fraction * dy)
        return hypot(point.x - projection.x, point.y - projection.y)
    }
}

private struct GeometryTopologyMapProjection {
    private let minX: Double
    private let minY: Double
    private let scale: CGFloat
    private let originX: CGFloat
    private let originY: CGFloat
    private let height: CGFloat

    var worldUnitsPerPoint: Double? {
        guard scale.isFinite, scale > 0 else { return nil }
        return 1 / Double(scale)
    }

    init?(extent: GeometryTopologyExtent?, size: CGSize, zoom: Double, pan: CGSize) {
        guard let extent, size.width > 1, size.height > 1 else { return nil }
        var lowX = extent.minX
        var highX = extent.maxX
        var lowY = extent.minY
        var highY = extent.maxY
        if highX <= lowX { lowX -= 0.5; highX += 0.5 }
        if highY <= lowY { lowY -= 0.5; highY += 0.5 }

        let spanX = CGFloat(highX - lowX)
        let spanY = CGFloat(highY - lowY)
        let availableWidth = max(1, size.width - 32)
        let availableHeight = max(1, size.height - 32)
        let fitScale = min(availableWidth / spanX, availableHeight / spanY)
        let scaled = fitScale * CGFloat(zoom)
        let contentWidth = CGFloat(spanX) * scaled
        let contentHeight = CGFloat(spanY) * scaled
        self.minX = lowX
        self.minY = lowY
        self.scale = scaled
        self.originX = (size.width - contentWidth) / 2 + pan.width
        self.originY = (size.height - contentHeight) / 2 - pan.height
        self.height = size.height
    }

    func project(_ coordinate: GeometryTopologyCoordinate) -> CGPoint {
        CGPoint(x: originX + CGFloat(coordinate.x - minX) * scale,
                y: height - originY - CGFloat(coordinate.y - minY) * scale)
    }
}
