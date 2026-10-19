import SwiftUI

struct BoundaryLineCoordinate: Codable, Hashable, Sendable {
    let x: Double
    let y: Double
    var isFinite: Bool { x.isFinite && y.isFinite }
}

struct BoundaryLineMapStyle {
    // BoundaryConditionLineLayerVC.RenderLayerFrom source defaults.
    var lineColor = Color(red: 5.0 / 255, green: 213.0 / 255, blue: 1)
    var lineWidth: CGFloat = 3
    // DefaultEditSymbology.PointSymbology uses VectorSymbology.DefaultSymbology.
    var vertexPenColor = Color.black
    var vertexPenWidth: CGFloat = 1
    var vertexFillColor = Color(red: 0, green: 0, blue: 1).opacity(0.5)
    var vertexSize: CGFloat = 3
    // Selection and hover are transient native highlights over the source style.
    var selectedLineColor = Color(red: 41.0 / 255, green: 126.0 / 255, blue: 1)
    var selectedLineWidth: CGFloat = 3.5
    var selectedVertexSize: CGFloat = 8
    var hoverLineColor = Color.orange
    var hoverLineWidth: CGFloat = 4
    var hasConditionalOverrides = false

    static let sourceDefault = Self()
}

private extension BoundaryLinePresentation {
    var finiteMapGeometry: [BoundaryLineCoordinate] {
        guard let geometry, geometry.allSatisfy({ $0.isFinite }) else { return [] }
        return geometry
    }
    var hasMapGeometry: Bool { finiteMapGeometry.count >= 2 }
}

struct BoundaryLineMapWorkspace: View {
    let lines: [BoundaryLinePresentation]
    let selectedLineID: String?
    @Binding var quickEditingLineID: String?
    @ObservedObject var session: ModelEditorSession
    let onCreate: (BoundaryLinePresentation) -> Void
    let onViewPayload: (BoundaryLinePresentation, String) -> Void
    var style: BoundaryLineMapStyle = .sourceDefault
    var canEditStyle = false
    var styleButtonHelp = "Boundary line styling is available only for the active Project or Buildable map."
    var styleContextError: String? = nil
    var onEditStyle: () -> Void = {}

    @State private var zoomFactor = 1.0
    @State private var panOffset = CGSize.zero
    @State private var dragStartPan = CGSize.zero
    @State private var isPanning = false
    @State private var hoverCoordinate: BoundaryLineCoordinate?
    @State private var hoverLineID: String?
    @State private var magnificationBaseline = 1.0

    private var mappableLines: [BoundaryLinePresentation] { lines.filter(\.hasMapGeometry) }
    private var selectedLine: BoundaryLinePresentation? { lines.first { $0.id == selectedLineID } }
    private var hoveredLine: BoundaryLinePresentation? { lines.first { $0.id == hoverLineID } }

    var body: some View {
        VStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                fullMapToolbar
                    .fixedSize(horizontal: true, vertical: false)
                compactMapToolbar
                    .frame(maxWidth: .infinity)
            }
            .padding(12)
            Divider()

            GeometryReader { proxy in
                if mappableLines.isEmpty {
                    VStack(spacing: 9) {
                        Image(systemName: "point.topleft.down.curvedto.point.bottomright.up")
                            .font(.system(size: 24))
                            .foregroundStyle(.secondary)
                        Text(L10n.text("No boundary line geometry is available."))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.primary.opacity(0.025))
                } else {
                    let transform = BoundaryLineMapTransform(lines: mappableLines, size: proxy.size,
                                                             zoomFactor: zoomFactor, panOffset: panOffset)
                    ZStack(alignment: .topLeading) {
                        Canvas { context, size in
                            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color.primary.opacity(0.025)))
                            for line in mappableLines {
                                let points = line.finiteMapGeometry.compactMap(transform.screenPoint(for:))
                                guard points.count >= 2 else { continue }
                                var path = Path()
                                path.move(to: points[0])
                                for point in points.dropFirst() { path.addLine(to: point) }
                                let selected = line.id == selectedLineID
                                context.stroke(
                                    path,
                                    with: .color(selected ? style.selectedLineColor : (line.id == hoverLineID ? style.hoverLineColor : style.lineColor)),
                                    style: StrokeStyle(lineWidth: selected ? style.selectedLineWidth : (line.id == hoverLineID ? style.hoverLineWidth : style.lineWidth),
                                                       lineCap: .round, lineJoin: .round)
                                )
                                let vertexRadius = (selected ? style.selectedVertexSize : style.vertexSize) / 2
                                for point in points {
                                    let vertex = CGRect(x: point.x - vertexRadius, y: point.y - vertexRadius,
                                                        width: vertexRadius * 2, height: vertexRadius * 2)
                                    context.fill(Path(ellipseIn: vertex), with: .color(selected ? style.selectedLineColor : style.vertexFillColor))
                                    context.stroke(Path(ellipseIn: vertex), with: .color(selected ? style.selectedLineColor : style.vertexPenColor),
                                                   lineWidth: selected ? 1.5 : style.vertexPenWidth)
                                }
                            }
                        }
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                if !isPanning {
                                    dragStartPan = panOffset
                                    let distance = hypot(value.translation.width, value.translation.height)
                                    if distance > 4 {
                                        isPanning = true
                                        quickEditingLineID = nil
                                    }
                                }
                                if isPanning {
                                    panOffset = CGSize(width: dragStartPan.width + value.translation.width,
                                                       height: dragStartPan.height + value.translation.height)
                                }
                            }
                            .onEnded { value in
                                if !isPanning,
                                   let lineID = transform.hitTest(value.location, lines: mappableLines, tolerance: 13) {
                                    session.selectBoundaryLine(lineID)
                                    quickEditingLineID = lineID
                                }
                                isPanning = false
                            })

                        if !isPanning {
                            ForEach(mappableLines) { line in
                                if line.id == selectedLineID,
                                   let anchor = transform.midpoint(for: line) {
                                    Button {
                                        session.selectBoundaryLine(line.id)
                                        quickEditingLineID = line.id
                                    } label: {
                                        Image(systemName: "slider.horizontal.3")
                                            .font(.system(size: 11, weight: .semibold))
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .controlSize(.small)
                                    .position(anchor)
                                    .accessibilityLabel(Text("\(L10n.text("Quick Edit")): \(session.boundaryLineName(line))"))
                                    .popover(isPresented: quickEditBinding(for: line), arrowEdge: .top) {
                                        BoundaryConditionLineQuickEditPicker(
                                            line: line,
                                            session: session,
                                            onCreate: { onCreate(line) },
                                            onViewPayload: { onViewPayload(line, $0) }
                                        )
                                    }
                                }
                            }
                        }
                    }
                    .background(Color.primary.opacity(0.025))
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            hoverCoordinate = transform.coordinate(at: location)
                            hoverLineID = transform.hitTest(location, lines: mappableLines, tolerance: 10)
                        case .ended:
                            hoverCoordinate = nil
                            hoverLineID = nil
                        }
                    }
                    .simultaneousGesture(MagnificationGesture()
                        .onChanged { magnification in
                            guard magnification.isFinite, magnification > 0 else { return }
                            let ratio = magnification / magnificationBaseline
                            zoomFactor = min(16, max(0.25, zoomFactor * ratio))
                            magnificationBaseline = magnification
                        }
                        .onEnded { _ in magnificationBaseline = 1 })
                    .overlay(alignment: .bottomLeading) {
                        if hoverCoordinate != nil || hoveredLine != nil {
                            VStack(alignment: .leading, spacing: 3) {
                                if let hoveredLine,
                                   let fid = BoundaryLineMapTransform.sourceFeatureIndex(for: hoveredLine.id, in: lines) {
                                    Text("BCL: \(fid)").font(.caption.weight(.semibold))
                                    Text(session.boundaryLineName(hoveredLine)).font(.caption)
                                }
                                if let hoverCoordinate {
                                    Text("\(L10n.text("X Coordinate")): \(hoverCoordinate.x.formatted(.number.precision(.fractionLength(3))))")
                                    Text("\(L10n.text("Y Coordinate")): \(hoverCoordinate.y.formatted(.number.precision(.fractionLength(3))))")
                                }
                            }
                            .font(.caption.monospacedDigit())
                            .padding(8)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                            .padding(8)
                            .allowsHitTesting(false)
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
            }
        }
        .background(.background)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 1)
        }
        .onChange(of: lines.map(\.id)) { _, _ in
            zoomFactor = 1
            panOffset = .zero
            hoverCoordinate = nil
            hoverLineID = nil
            quickEditingLineID = nil
        }
    }

    private var fullMapToolbar: some View {
        HStack(spacing: 9) {
            Label(L10n.text("Boundary Map"), systemImage: "map")
                .font(.headline)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            if let selectedLine {
                Text(session.boundaryLineName(selectedLine))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 112)
            }
            if style.hasConditionalOverrides {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(L10n.text("Conditional style overrides are preserved, but this canvas does not evaluate them."))
                    .help(L10n.text("Conditional style overrides are preserved, but this canvas does not evaluate them."))
            }
            if let styleContextError {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .accessibilityLabel(L10n.text(styleContextError))
                    .help(L10n.text(styleContextError))
            }
            zoomOutButton
            zoomInButton
            zoomPercentage
            fitButton
            styleButton
        }
    }

    private var compactMapToolbar: some View {
        HStack(spacing: 8) {
            Label(L10n.text("Boundary Map"), systemImage: "map")
                .labelStyle(.iconOnly)
                .accessibilityLabel(L10n.text("Boundary Map"))
                .help(L10n.text("Boundary Map"))
            Spacer(minLength: 4)
            if style.hasConditionalOverrides {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(L10n.text("Conditional style overrides are preserved, but this canvas does not evaluate them."))
                    .help(L10n.text("Conditional style overrides are preserved, but this canvas does not evaluate them."))
            }
            if let styleContextError {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .accessibilityLabel(L10n.text(styleContextError))
                    .help(L10n.text(styleContextError))
            }
            Menu {
                if let selectedLine {
                    Button { } label: { Text(verbatim: session.boundaryLineName(selectedLine)) }
                        .disabled(true)
                    Divider()
                }
                Button { } label: { Text("\(Int((zoomFactor * 100).rounded()))%") }
                    .disabled(true)
                Button { zoomFactor = max(0.25, zoomFactor / 1.25) } label: {
                    Label("Zoom Out", systemImage: "minus.magnifyingglass")
                }.disabled(zoomFactor <= 0.25)
                Button { zoomFactor = min(16, zoomFactor * 1.25) } label: {
                    Label("Zoom In", systemImage: "plus.magnifyingglass")
                }.disabled(zoomFactor >= 16)
                Button {
                    zoomFactor = 1
                    panOffset = .zero
                } label: {
                    Label("Fit to Data", systemImage: "arrow.up.left.and.down.right.magnifyingglass")
                }
                Divider()
                Button(action: onEditStyle) {
                    Label("Boundary Line Style", systemImage: "paintbrush.pointed")
                }
                .disabled(!canEditStyle)
                .help(L10n.text(styleButtonHelp))
                if let styleContextError {
                    Divider()
                    Button { } label: { Label(L10n.text(styleContextError), systemImage: "exclamationmark.triangle.fill") }
                        .disabled(true)
                }
                if style.hasConditionalOverrides {
                    Button { } label: { Label("Conditional style overrides are preserved, but this canvas does not evaluate them.", systemImage: "info.circle") }
                        .disabled(true)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .frame(minWidth: 28, minHeight: 24)
            }
            .menuStyle(.borderlessButton)
            .accessibilityLabel(L10n.text("Boundary Map"))
            .help(L10n.text("Boundary Map"))
        }
    }

    private var zoomOutButton: some View {
        Button { zoomFactor = max(0.25, zoomFactor / 1.25) } label: {
            Image(systemName: "minus.magnifyingglass")
        }
        .help(L10n.text("Zoom Out"))
        .accessibilityLabel(L10n.text("Zoom Out"))
        .disabled(zoomFactor <= 0.25)
    }

    private var zoomInButton: some View {
        Button { zoomFactor = min(16, zoomFactor * 1.25) } label: {
            Image(systemName: "plus.magnifyingglass")
        }
        .help(L10n.text("Zoom In"))
        .accessibilityLabel(L10n.text("Zoom In"))
        .disabled(zoomFactor >= 16)
    }

    private var zoomPercentage: some View {
        Text("\(Int((zoomFactor * 100).rounded()))%")
            .monospacedDigit()
            .font(.caption.monospacedDigit())
            .frame(minWidth: 38, alignment: .trailing)
    }

    private var fitButton: some View {
        Button {
            zoomFactor = 1
            panOffset = .zero
        } label: {
            Image(systemName: "arrow.up.left.and.down.right.magnifyingglass")
        }
        .help(L10n.text("Fit to Data"))
        .accessibilityLabel(L10n.text("Fit to Data"))
    }

    private var styleButton: some View {
        Button(action: onEditStyle) {
            Image(systemName: "paintbrush.pointed")
        }
        .disabled(!canEditStyle)
        .help(L10n.text(styleButtonHelp))
        .accessibilityLabel(L10n.text("Boundary Line Style"))
    }

    private func quickEditBinding(for line: BoundaryLinePresentation) -> Binding<Bool> {
        Binding(
            get: { quickEditingLineID == line.id },
            set: { isPresented in
                if isPresented {
                    session.selectBoundaryLine(line.id)
                    quickEditingLineID = line.id
                } else if quickEditingLineID == line.id {
                    quickEditingLineID = nil
                }
            }
        )
    }
}

struct BoundaryLineMapTransform {
    private let minX: Double
    private let maxY: Double
    private let scale: Double
    private let offsetX: Double
    private let offsetY: Double
    private let viewportWidth: Double
    private let viewportHeight: Double
    private let zoomFactor: Double
    private let panX: Double
    private let panY: Double

    init(lines: [BoundaryLinePresentation], size: CGSize, zoomFactor: Double = 1, panOffset: CGSize = .zero) {
        let points = lines.flatMap(\.finiteMapGeometry)
        let minX = points.map(\.x).min() ?? 0
        let maxX = points.map(\.x).max() ?? 0
        let minY = points.map(\.y).min() ?? 0
        let maxY = points.map(\.y).max() ?? 0
        let availableWidth = max(1, Double(size.width) - 52)
        let availableHeight = max(1, Double(size.height) - 52)
        let width = maxX - minX
        let height = maxY - minY
        let horizontalScale = width > 0 ? availableWidth / width : .infinity
        let verticalScale = height > 0 ? availableHeight / height : .infinity
        let fittedScale = min(horizontalScale, verticalScale)
        let scale = fittedScale.isFinite && fittedScale > 0 ? fittedScale : 1
        self.minX = minX
        self.maxY = maxY
        self.scale = scale
        viewportWidth = Double(size.width)
        viewportHeight = Double(size.height)
        self.zoomFactor = min(16, max(0.25, zoomFactor.isFinite ? zoomFactor : 1))
        panX = Double(panOffset.width)
        panY = Double(panOffset.height)
        offsetX = (viewportWidth - width * scale) / 2
        offsetY = (viewportHeight - height * scale) / 2
    }

    func screenPoint(for point: BoundaryLineCoordinate) -> CGPoint? {
        guard point.isFinite else { return nil }
        let fitX = offsetX + (point.x - minX) * scale
        let fitY = offsetY + (maxY - point.y) * scale
        let x = (fitX - viewportWidth / 2) * zoomFactor + viewportWidth / 2 + panX
        let y = (fitY - viewportHeight / 2) * zoomFactor + viewportHeight / 2 + panY
        return CGPoint(x: CGFloat(x), y: CGFloat(y))
    }

    func coordinate(at location: CGPoint) -> BoundaryLineCoordinate? {
        guard scale.isFinite, scale > 0, zoomFactor > 0 else { return nil }
        let fitX = (Double(location.x) - viewportWidth / 2 - panX) / zoomFactor + viewportWidth / 2
        let fitY = (Double(location.y) - viewportHeight / 2 - panY) / zoomFactor + viewportHeight / 2
        let coordinate = BoundaryLineCoordinate(x: minX + (fitX - offsetX) / scale,
                                                y: maxY - (fitY - offsetY) / scale)
        return coordinate.isFinite ? coordinate : nil
    }

    func midpoint(for line: BoundaryLinePresentation) -> CGPoint? {
        let points = line.finiteMapGeometry
        guard points.count >= 2 else { return nil }
        let lengths = zip(points, points.dropFirst()).map { hypot($1.x - $0.x, $1.y - $0.y) }
        let totalLength = lengths.reduce(0, +)
        guard totalLength.isFinite else { return nil }
        if totalLength == 0 { return screenPoint(for: points[0]) }
        let target = totalLength / 2
        var traversed = 0.0
        for (index, length) in lengths.enumerated() {
            if length > 0, traversed + length >= target {
                let fraction = (target - traversed) / length
                let point = BoundaryLineCoordinate(
                    x: points[index].x + (points[index + 1].x - points[index].x) * fraction,
                    y: points[index].y + (points[index + 1].y - points[index].y) * fraction
                )
                return screenPoint(for: point)
            }
            traversed += length
        }
        return screenPoint(for: points[0])
    }

    func hitTest(_ location: CGPoint, lines: [BoundaryLinePresentation], tolerance: Double) -> String? {
        var nearest: (id: String, distance: Double)?
        for line in lines {
            let points = line.finiteMapGeometry.compactMap(screenPoint(for:))
            guard points.count >= 2 else { continue }
            for (start, end) in zip(points, points.dropFirst()) {
                let distance = distance(from: location, to: start, end)
                if distance <= tolerance, distance < (nearest?.distance ?? .infinity) {
                    nearest = (line.id, distance)
                }
            }
        }
        return nearest?.id
    }

    static func sourceFeatureIndex(for lineID: String, in lines: [BoundaryLinePresentation]) -> Int? {
        lines.firstIndex { $0.id == lineID }
    }

    private func distance(from point: CGPoint, to start: CGPoint, _ end: CGPoint) -> Double {
        let startX = Double(start.x), startY = Double(start.y)
        let dx = Double(end.x) - startX
        let dy = Double(end.y) - startY
        let lengthSquared = dx * dx + dy * dy
        let fraction = lengthSquared > 0
            ? min(1, max(0, ((Double(point.x) - startX) * dx + (Double(point.y) - startY) * dy) / lengthSquared))
            : 0
        return hypot(Double(point.x) - (startX + fraction * dx), Double(point.y) - (startY + fraction * dy))
    }
}
