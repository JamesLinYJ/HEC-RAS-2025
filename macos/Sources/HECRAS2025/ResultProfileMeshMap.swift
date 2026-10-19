import SwiftUI

/// Read-only element picker over coordinates carried by the selected Result.
/// The backend returns exact viewport features or an explicit zoom-required
/// response; this view never fills gaps with a sampled mesh.
struct ResultProfileMeshPicker: View {
    @ObservedObject var session: ResultProfileSession
    let flowAreaIndex: Int
    let elementKind: String?
    let selectedElementIndex: Int?
    let selectElement: (Int) -> Void
    var sampleLineMode = false
    var addSampleLinePoint: (GeometryTopologyCoordinate) -> Void = { _ in }

    @State private var zoom = 1.0
    @State private var pan = CGSize.zero
    @State private var panAtDragStart = CGSize.zero
    @State private var dragOffset = CGSize.zero
    @State private var draggingMap = false
    @State private var zoomAtMagnifyStart = 1.0
    @State private var sourceExtent: GeometryTopologyExtent?

    private var map: ResultProfileMapResult? { sampleLineMode ? session.sampleLineMapData : session.mapData }
    private var isLoading: Bool { sampleLineMode ? session.isLoadingSampleLineMap : session.isLoadingMap }
    private var sampleLineMapTaskKey: Int {
        sampleLineMode ? (session.sampleLineSources?.firstFlowAreaCellCount ?? 0) : 0
    }
    private var mapTaskID: String {
        "\(session.identity?.resultPath ?? "")|\(session.identity?.revision ?? "")|\(sampleLineMode ? 0 : flowAreaIndex)|\(sampleLineMode ? "Cell" : elementKind ?? "")|\(sampleLineMode)|\(sampleLineMapTaskKey)"
    }
    private var currentPan: CGSize {
        CGSize(width: pan.width + dragOffset.width, height: pan.height + dragOffset.height)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Label(L10n.text("Embedded Result mesh"), systemImage: "point.topleft.down.curvedto.point.bottomright.up")
                    .font(.headline)
                Spacer()
                if let map {
                    Text(L10n.format("%@ elements", map.totalElements.formatted()))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Button {
                    zoom = 1
                    pan = .zero
                    dragOffset = .zero
                    Task {
                        if sampleLineMode { await session.loadSampleLineMap() }
                        else { await session.loadMap(flowAreaIndex: flowAreaIndex, elementKind: elementKind ?? "Cell") }
                    }
                } label: {
                    Label(L10n.text("Fit to Result mesh"), systemImage: "viewfinder")
                }
                .labelStyle(.iconOnly)
                .help(L10n.text("Fit to Result mesh"))
                .disabled((sampleLineMode ? (session.sampleLineSources?.firstFlowAreaCellCount ?? 0) == 0 : elementKind == nil)
                    || (map?.sourceExtent ?? sourceExtent) == nil || isLoading)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)

            GeometryReader { geometry in
                ZStack {
                    Canvas { context, size in
                        drawMap(in: &context, size: size)
                    }
                    .background(Color(nsColor: .textBackgroundColor).opacity(0.6))

                    if isLoading {
                        ProgressView(L10n.text("Loading Result mesh…"))
                            .padding(10).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                            .allowsHitTesting(false)
                    } else if elementKind == nil || (map?.sourceExtent ?? sourceExtent) == nil {
                        ContentUnavailableView(L10n.text("No embedded Result mesh coordinates are available."),
                            systemImage: "map")
                            .allowsHitTesting(false)
                    } else if map?.requiresZoom == true {
                        Label(L10n.format("This extent exceeds the %d element preview limit. Zoom in to select exact elements.",
                            map?.elementLimit ?? 0), systemImage: "plus.magnifyingglass")
                            .font(.callout).foregroundStyle(.secondary)
                            .padding(10).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                            .allowsHitTesting(false)
                    } else if map?.isComplete == true, map?.elements.isEmpty == true, map?.available == true {
                        Label(L10n.text("No elements intersect this map extent."), systemImage: "map")
                            .font(.callout).foregroundStyle(.secondary)
                            .padding(10).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                            .allowsHitTesting(false)
                    }
                }
                .contentShape(Rectangle())
                .help(L10n.text(sampleLineMode
                    ? "Click points to draw a sample line; drag to pan; pinch to zoom."
                    : "Drag to pan; pinch to zoom; click a cell or face to read its stored profile."))
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard hypot(value.translation.width, value.translation.height) > 5 else { return }
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
                            requestVisibleMap(size: geometry.size)
                        } else if sampleLineMode, let coordinate = coordinate(at: value.location, size: geometry.size) {
                            addSampleLinePoint(coordinate)
                        } else if let index = hit(at: value.location, size: geometry.size) {
                            selectElement(index)
                        }
                    })
                .simultaneousGesture(MagnificationGesture()
                    .onChanged { value in
                        if zoomAtMagnifyStart == zoom { zoomAtMagnifyStart = zoom }
                        zoom = min(12, max(0.45, zoomAtMagnifyStart * value))
                    }
                    .onEnded { _ in
                        zoomAtMagnifyStart = zoom
                        requestVisibleMap(size: geometry.size)
                    })
                .onChange(of: geometry.size) { _, newSize in
                    guard map?.sourceExtent != nil else { return }
                    requestVisibleMap(size: newSize)
                }
            }
            // This picker is also embedded in a linked-profile ScrollView.
            // Bound the canvas so its GeometryReader cannot consume an entire
            // panel and push the profile and variable controls out of view.
            .frame(height: 260)

            HStack(spacing: 8) {
                if sampleLineMode {
                    Text(L10n.format("%d sample-line points", session.sampleLinePoints.count))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                } else if let map, map.isComplete, let intersecting = map.intersectingElements {
                    Text(L10n.format("Showing %d elements in this extent (%d in mesh).",
                        intersecting, map.totalElements))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                } else if let map, map.requiresZoom {
                    Text(L10n.text("Zoom in to load exact selectable geometry."))
                        .font(.caption).foregroundStyle(.secondary)
                } else if let map, let reason = map.unavailableReason {
                    Text(L10n.text(reason)).font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(L10n.text("Select an element on the map to read its stored profile."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if let selectedElementIndex {
                    Text(L10n.format("Element %d", selectedElementIndex))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
        }
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(.quaternary, lineWidth: 1)
        }
        .task(id: mapTaskID) {
            if sampleLineMode {
                guard (session.sampleLineSources?.firstFlowAreaCellCount ?? 0) > 0 else {
                    session.cancelSampleLineMap()
                    return
                }
            } else if elementKind == nil {
                session.cancelMap()
                return
            }
            zoom = 1
            pan = .zero
            dragOffset = .zero
            sourceExtent = nil
            if sampleLineMode { await session.loadSampleLineMap() }
            else if let elementKind { await session.loadMap(flowAreaIndex: flowAreaIndex, elementKind: elementKind) }
        }
        .onChange(of: map?.sourceExtent) { _, extent in
            if let extent { sourceExtent = extent }
        }
        .onDisappear {
            if sampleLineMode { session.cancelSampleLineMap() }
            else { session.cancelMap() }
        }
    }

    private func drawMap(in context: inout GraphicsContext, size: CGSize) {
        guard let map, let extent = map.sourceExtent ?? sourceExtent,
              let projection = GeometryMeshMapProjection(extent: extent, size: size,
                zoom: zoom, pan: currentPan) else { return }

        var bounds = Path()
        let corners = [
            GeometryTopologyCoordinate(x: extent.minX, y: extent.minY),
            GeometryTopologyCoordinate(x: extent.maxX, y: extent.minY),
            GeometryTopologyCoordinate(x: extent.maxX, y: extent.maxY),
            GeometryTopologyCoordinate(x: extent.minX, y: extent.maxY)
        ].map(projection.project)
        if let first = corners.first {
            bounds.move(to: first)
            for point in corners.dropFirst() { bounds.addLine(to: point) }
            bounds.closeSubpath()
            context.stroke(bounds, with: .color(.secondary.opacity(0.35)), lineWidth: 1)
        }

        for element in map.elements {
            let selected = selectedElementIndex == element.elementIndex
            let path = GeometryMeshMapPath.make(paths: element.paths, projection: projection,
                close: elementKind == "Cell")
            if elementKind == "Cell" {
                context.fill(path, with: .color(selected ? .accentColor.opacity(0.22) : .teal.opacity(0.045)),
                    style: FillStyle(eoFill: true, antialiased: true))
                context.stroke(path, with: .color(selected ? .accentColor : .teal.opacity(0.8)),
                    style: StrokeStyle(lineWidth: selected ? 2.8 : 0.7, lineJoin: .round))
            } else {
                context.stroke(path, with: .color(selected ? .accentColor : .orange.opacity(0.8)),
                    style: StrokeStyle(lineWidth: selected ? 3 : 1.15, lineCap: .round, lineJoin: .round))
            }
        }
        if sampleLineMode, !session.sampleLinePoints.isEmpty {
            var sampleLine = Path()
            for (index, coordinate) in session.sampleLinePoints.enumerated() {
                let point = projection.project(coordinate)
                if index == 0 { sampleLine.move(to: point) }
                else { sampleLine.addLine(to: point) }
                let marker = Path(ellipseIn: CGRect(x: point.x - 3.5, y: point.y - 3.5, width: 7, height: 7))
                context.fill(marker, with: .color(.red))
            }
            context.stroke(sampleLine, with: .color(.red), style: StrokeStyle(lineWidth: 2.6, lineCap: .round, lineJoin: .round))
        }
    }

    private func hit(at location: CGPoint, size: CGSize) -> Int? {
        guard let map, map.isComplete, let extent = map.sourceExtent ?? sourceExtent,
              let projection = GeometryMeshMapProjection(extent: extent, size: size,
                zoom: zoom, pan: currentPan) else { return nil }
        for element in map.elements.reversed() {
            let path = GeometryMeshMapPath.make(paths: element.paths, projection: projection,
                close: elementKind == "Cell")
            if elementKind == "Cell" {
                if path.contains(location, eoFill: true) { return element.elementIndex }
            } else {
                if path.strokedPath(.init(lineWidth: 11)).contains(location) { return element.elementIndex }
            }
        }
        return nil
    }

    private func coordinate(at location: CGPoint, size: CGSize) -> GeometryTopologyCoordinate? {
        guard let map, map.isComplete, let extent = map.sourceExtent ?? sourceExtent,
              let projection = GeometryMeshMapProjection(extent: extent, size: size,
                zoom: zoom, pan: currentPan) else { return nil }
        return projection.coordinate(at: location)
    }

    private func requestVisibleMap(size: CGSize) {
        guard let extent = map?.sourceExtent ?? sourceExtent,
              let projection = GeometryMeshMapProjection(extent: extent, size: size,
                zoom: zoom, pan: currentPan),
              let first = projection.coordinate(at: CGPoint(x: 0, y: 0)),
              let second = projection.coordinate(at: CGPoint(x: size.width, y: size.height)) else { return }
        let visible = GeometryTopologyExtent(minX: min(first.x, second.x), minY: min(first.y, second.y),
            maxX: max(first.x, second.x), maxY: max(first.y, second.y))
        Task {
            if sampleLineMode { await session.loadSampleLineMap(extent: visible) }
            else if let elementKind { await session.loadMap(flowAreaIndex: flowAreaIndex, elementKind: elementKind, extent: visible) }
        }
    }
}
