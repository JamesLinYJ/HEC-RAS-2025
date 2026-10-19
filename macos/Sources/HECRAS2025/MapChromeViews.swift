import RASWorkspaceCore
import SwiftUI

// RasMapUndoRedo: source edit-stack capabilities stay per-map. Presence of a
// provider does not imply that an undo or redo item actually exists.
struct MapHistoryControls: View {
    @ObservedObject var store: WorkspaceStore
    let mapID: UUID
    @State private var performing = false
    private var editor: PolylineMapEditingSession { store.mapState(for: mapID).polylineEditor }
    private var usesLineEditor: Bool { editor.currentScope != nil }
    private var hasService: Bool { usesLineEditor || store.mapInteractionProvider != nil }
    private var availability: MapHistoryAvailability? {
        usesLineEditor ? .init(canUndo: editor.canUndo && editor.isEditAllowed, canRedo: editor.canRedo && editor.isEditAllowed) : store.mapHistoryAvailability[mapID]
    }
    var body: some View {
        ControlGroup {
            Button { run(redo: false) } label: { Label("Undo Map Edit", systemImage: "arrow.uturn.backward") }
                .disabled(availability?.canUndo != true)
            Button { run(redo: true) } label: { Label("Redo Map Edit", systemImage: "arrow.uturn.forward") }
                .disabled(availability?.canRedo != true)
        }
        .disabled(performing || !hasService || editor.isBusy)
        .help(!hasService ? L10n.text("Map editing service is not connected.") : L10n.text("Map Edit History"))
    }
    private func run(redo: Bool) {
        guard !performing, hasService, redo ? availability?.canRedo == true : availability?.canUndo == true else { return }
        store.activateMap(mapID); performing = true
        Task {
            if usesLineEditor {
                if redo { _ = await editor.redo() } else { _ = await editor.undo() }
            } else if redo { await store.redoMapEdit() } else { await store.undoMapEdit() }
            performing = false
        }
    }
}

// MapOverlayChrome/MapToolBar use native control groups and an overflow menu
// in compact windows. Overlay toggles remain presentation, not model drafts.
struct MapChromeToolbar: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var mapState: MapState
    let mapID: UUID
    @Binding var showScaleBar: Bool
    @Binding var showMapOverlays: Bool
    @Binding var overlayOpacity: Double
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { tools; Divider().frame(height: 18); navigation; history; display; MapAnalysisMenu(store: store) }
            HStack(spacing: 8) { tools; navigation; Menu { history; display; MapAnalysisMenu(store: store) } label: { Label("More Map Actions", systemImage: "ellipsis") } }
        }
        .labelStyle(.iconOnly).buttonStyle(.borderless).controlSize(.large)
        .padding(10).workspaceGlass()
    }
    private var tools: some View {
        HStack(spacing: 10) {
            MapToolMenu(store: store, mapState: mapState, mapID: mapID)
            MapPolylineTools(store: store, mapState: mapState)
            MapSourceLayersPopover(store: store, mapState: mapState)
            MapResultsPopover(store: store, mapState: mapState)
            MapLineChartMenu(store: store, mapState: mapState)
            Button { store.activateMap(mapID); store.addMapLayer() } label: { Label("Add map layer", systemImage: "plus") }
                .disabled(mapState.kind == .unsupported)
        }
    }
    private var navigation: some View {
        ControlGroup {
            Button { mapState.resetViewport() } label: { Label("Zoom to full extent", systemImage: "arrow.up.left.and.arrow.down.right") }
            Button { mapState.scale = min(mapState.scale * 1.5, 256) } label: { Label("Zoom in", systemImage: "plus.magnifyingglass") }
            Button { mapState.scale = max(mapState.scale / 1.5, 0.125) } label: { Label("Zoom out", systemImage: "minus.magnifyingglass") }
        }
    }
    private var history: some View { MapHistoryControls(store: store, mapID: mapID) }
    private var display: some View {
        Menu {
            Toggle("Map Overlays", isOn: $showMapOverlays)
            Slider(value: $overlayOpacity, in: 0...1) { Text("Overlay Opacity") }
            Divider()
            Toggle("Coordinate grid", isOn: $mapState.showGrid)
            Toggle("Map Legend", isOn: $mapState.showLegend)
            Toggle("Map Overview", isOn: $mapState.showMinimap)
            Toggle("Scale Bar", isOn: $showScaleBar)
            Divider()
            Button("Zoom to Location") { store.activateMap(mapID); store.showZoomLocation = true }
        } label: { Label("Map Overlays", systemImage: "square.3.layers.3d") }
    }
}

// The retained ScaleBar uses live map cell size and UnitSystem to select a
// 1/2/5 distance. This view receives units evaluated from the actual map CRS;
// when that metadata is unavailable it omits the scale instead of guessing.
struct MapCoordinateScaleBar: View {
    let extent: ViewportRequest?
    let canvasWidth: CGFloat
    let units: MapProjectionUnits?
    init(extent: ViewportRequest?, canvasWidth: CGFloat, units: MapProjectionUnits? = nil) {
        self.extent = extent
        self.canvasWidth = canvasWidth
        self.units = units
    }
    private var metric: MapScaleBarMeasurement? {
        MapScaleBarMeasurement.calculate(extent: extent, canvasWidth: Double(canvasWidth), units: units)
    }
    var body: some View {
        if let metric {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 0) {
                    Text("0").fixedSize()
                    if metric.showsHalfDistance {
                        Spacer(minLength: 0)
                        Text((metric.halfDistance).formatted(.number.precision(.significantDigits(1...3))))
                            .fixedSize()
                    }
                    Spacer(minLength: 0)
                    Text(metric.distance.formatted(.number.precision(.significantDigits(1...3)))
                        + " " + metric.unitLabel)
                        .fixedSize()
                }.font(.caption2.monospacedDigit()).lineLimit(1)
                HStack(spacing: 0) {
                    Rectangle().fill(.primary).frame(height: 4)
                    Rectangle().fill(.background).frame(height: 4)
                }.overlay(Rectangle().stroke(.primary, lineWidth: 1))
            }.frame(width: CGFloat(metric.pixelWidth)).padding(10).workspaceGlass()
                .accessibilityLabel("Scale Bar")
                .accessibilityValue(metric.distance.formatted() + " " + metric.unitLabel)
        }
    }
}

// MapOverlayChrome exposes the source's placement, collapse, move and resize
// affordances using SwiftUI gestures. Coordinates here are window points;
// moving chrome never edits the source map's world coordinate extent.
enum MapOverlayCorner: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case topLeft = "TopLeft"
    case topRight = "TopRight"
    case bottomLeft = "BottomLeft"
    case bottomRight = "BottomRight"
    case topCenter = "TopCenter"
    case bottomCenter = "BottomCenter"

    enum HorizontalAnchor: Equatable, Sendable { case left, center, right }

    var id: String { rawValue }
    var titleKey: String {
        switch self {
        case .topLeft: "Top Left"
        case .topCenter: "Top Center"
        case .topRight: "Top Right"
        case .bottomLeft: "Bottom Left"
        case .bottomCenter: "Bottom Center"
        case .bottomRight: "Bottom Right"
        }
    }
    var horizontalAnchor: HorizontalAnchor {
        switch self {
        case .topLeft, .bottomLeft: .left
        case .topCenter, .bottomCenter: .center
        case .topRight, .bottomRight: .right
        }
    }
    var isTop: Bool { self == .topLeft || self == .topCenter || self == .topRight }
    var alignment: Alignment {
        switch self {
        case .topLeft: .topLeading
        case .topCenter: .top
        case .topRight: .topTrailing
        case .bottomLeft: .bottomLeading
        case .bottomCenter: .bottom
        case .bottomRight: .bottomTrailing
        }
    }

    static func from(horizontal: HorizontalAnchor, isTop: Bool) -> Self {
        switch (horizontal, isTop) {
        case (.left, true): .topLeft
        case (.center, true): .topCenter
        case (.right, true): .topRight
        case (.left, false): .bottomLeft
        case (.center, false): .bottomCenter
        case (.right, false): .bottomRight
        }
    }
}

struct MapFloatingOverlay<Content: View>: View {
    let title: String
    let symbol: String
    let minimumSize: CGSize
    let maximumSize: CGSize
    let isResizable: Bool
    let zIndex: Int
    private let content: (CGSize) -> Content
    private let initialCorner: MapOverlayCorner
    private let adaptiveDefaultCorner: MapOverlayCorner?
    private let serializationKey: String?
    private let initialStackOrder: Int
    private let defaultContentSize: CGSize
    private let peerGeometry: [MapOverlayGeometryInput]
    @State private var placement: MapOverlayPlacement
    @State private var hasUserPlacement: Bool
    @GestureState private var drag = CGSize.zero
    @GestureState private var resize = CGSize.zero

    init(title: String, symbol: String, corner: MapOverlayCorner, size: CGSize,
         minimumSize: CGSize, maximumSize: CGSize,
         adaptiveDefaultCorner: MapOverlayCorner? = nil,
         serializationKey: String? = nil, stackOrder: Int = 0,
         zIndex: Int = 0, isResizable: Bool = true,
         peerGeometry: [MapOverlayGeometryInput] = [],
         @ViewBuilder content: @escaping (CGSize) -> Content) {
        self.title = title; self.symbol = symbol; self.minimumSize = minimumSize
        self.maximumSize = maximumSize; self.content = content
        self.serializationKey = serializationKey; self.initialStackOrder = stackOrder
        self.zIndex = zIndex; self.isResizable = isResizable
        self.initialCorner = corner; self.adaptiveDefaultCorner = adaptiveDefaultCorner
        self.peerGeometry = peerGeometry.filter { $0.id != (serializationKey ?? title) }
        defaultContentSize = size
        let savedPlacement = serializationKey.flatMap { MapOverlayPlacementStore.load($0) }
        _placement = State(initialValue: savedPlacement ?? MapOverlayPlacement(
            corner: adaptiveDefaultCorner ?? corner, stackOrder: stackOrder))
        _hasUserPlacement = State(initialValue: savedPlacement != nil)
    }

    private static var chromeHeight: CGFloat { 34 }
    private var defaultOuterSize: CGSize {
        CGSize(width: defaultContentSize.width, height: defaultContentSize.height + Self.chromeHeight)
    }

    private var outerMinimumSize: CGSize {
        CGSize(width: minimumSize.width, height: minimumSize.height + Self.chromeHeight)
    }

    private var outerMaximumSize: CGSize {
        CGSize(width: maximumSize.width, height: maximumSize.height + Self.chromeHeight)
    }

    private var baseOuterSize: CGSize {
        guard isResizable, let pinned = placement.pinnedSize else { return defaultOuterSize }
        return pinned
    }

    private var currentOuterSize: CGSize {
        MapOverlayPlacementSolver.resized(baseOuterSize, by: resize,
            minimum: outerMinimumSize, maximum: outerMaximumSize)
    }

    private var currentContentSize: CGSize {
        CGSize(width: currentOuterSize.width,
               height: max(currentOuterSize.height - Self.chromeHeight, 0))
    }

    private var geometryInput: MapOverlayGeometryInput {
        var visiblePlacement = placement
        if isResizable, resize != .zero {
            visiblePlacement.width = Double(currentOuterSize.width)
            visiblePlacement.height = Double(currentOuterSize.height)
        }
        return MapOverlayGeometryInput(id: serializationKey ?? title, placement: visiblePlacement,
            desiredSize: currentOuterSize, minimumSize: outerMinimumSize,
            maximumSize: outerMaximumSize, isResizable: isResizable, zIndex: zIndex)
    }

    var body: some View {
        GeometryReader { canvas in
            let frame = MapOverlayPlacementSolver.previewFrame(for: geometryInput,
                by: drag, in: canvas.size, peers: peerGeometry)
                ?? MapOverlayPlacementSolver.arrange([geometryInput] + peerGeometry, in: canvas.size)
                    .first(where: { $0.id == geometryInput.id })?.frame
                ?? .zero
            if placement.isCollapsed {
                collapsedButton(canvasSize: canvas.size)
                    .frame(width: frame.width, height: frame.height)
                    .position(x: frame.midX, y: frame.midY)
                    .zIndex(Double(zIndex))
            } else {
                panel(canvasSize: canvas.size)
                    .frame(width: frame.width, height: frame.height)
                    .position(x: frame.midX, y: frame.midY)
                    .zIndex(Double(zIndex))
            }
        }
        .onChange(of: adaptiveDefaultCorner) { _, newCorner in
            guard !hasUserPlacement else { return }
            placement.corner = newCorner ?? initialCorner
        }
    }

    private func panel(canvasSize: CGSize) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button { toggleCollapsed(canvasSize: canvasSize) } label: {
                    Label("Collapse Overlay", systemImage: "chevron.up")
                }
                .labelStyle(.iconOnly)
                Label(LocalizedStringKey(title), systemImage: symbol)
                    .font(.caption.weight(.semibold)).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .gesture(DragGesture().updating($drag) { value, state, _ in
                        state = value.translation
                    }.onEnded { value in moveOverlay(by: value.translation, canvasSize: canvasSize) })
                Menu { overlayOptions(canvasSize: canvasSize) } label: {
                    Label("Overlay Options", systemImage: "ellipsis")
                }.labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless).controlSize(.small).padding(8)
            Divider()
            content(currentContentSize)
                .frame(width: currentContentSize.width, height: currentContentSize.height)
                .overlay(alignment: .bottomTrailing) {
                    if isResizable {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.caption2).padding(5)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
                            .contentShape(Rectangle()).help("Resize Overlay")
                            .gesture(DragGesture().updating($resize) { value, state, _ in
                                state = value.translation
                            }.onEnded { value in resizeOverlay(by: value.translation) })
                            .accessibilityLabel("Resize Overlay")
                            .accessibilityAdjustableAction { direction in
                                let delta: CGFloat = direction == .increment ? 20 : -20
                                resizeOverlay(by: CGSize(width: delta, height: delta))
                            }
                    }
                }
            Spacer(minLength: 0)
        }
        .frame(width: currentOuterSize.width, height: currentOuterSize.height, alignment: .topLeading)
        .workspaceGlass()
    }

    private func collapsedButton(canvasSize: CGSize) -> some View {
        Button {
            var updated = placement
            updated.isCollapsed = false
            updatePlacement(updated)
        } label: {
            Image(systemName: symbol)
                .frame(width: MapOverlayPlacementSolver.collapsedPillSize.width,
                       height: MapOverlayPlacementSolver.collapsedPillSize.height)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .workspaceGlass()
        .help(L10n.format("Expand %@", L10n.text(title)))
        .contextMenu { overlayOptions(canvasSize: canvasSize) }
        .simultaneousGesture(DragGesture(minimumDistance: 4).updating($drag) { value, state, _ in
            state = value.translation
        }.onEnded { value in moveOverlay(by: value.translation, canvasSize: canvasSize) })
    }

    @ViewBuilder
    private func overlayOptions(canvasSize: CGSize) -> some View {
        Picker("Overlay Position", selection: Binding(get: { placement.corner }, set: setCorner)) {
            ForEach(MapOverlayCorner.allCases) { corner in
                Text(LocalizedStringKey(corner.titleKey)).tag(corner)
            }
        }
        if !placement.isCollapsed {
            Button("Collapse Overlay") { toggleCollapsed(canvasSize: canvasSize) }
        } else {
            Button("Expand Overlay") {
                var updated = placement
                updated.isCollapsed = false
                updatePlacement(updated)
            }
        }
        Button("Reset Overlay", action: resetPlacement)
    }

    private func setCorner(_ corner: MapOverlayCorner) {
        if placement.corner == corner && placement.isDocked { return }
        let next = stackPeers(in: corner).count
        let updated = MapOverlayPlacementSolver.docked(placement, at: corner, nextStackOrder: next)
        updateStackPlacement(updated)
    }

    private func toggleCollapsed(canvasSize: CGSize) {
        var updated = placement
        if !updated.isCollapsed {
            let currentFrame = MapOverlayPlacementSolver.previewFrame(for: geometryInput,
                by: drag, in: canvasSize, peers: peerGeometry)
                ?? MapOverlayPlacementSolver.arrange([geometryInput] + peerGeometry, in: canvasSize)
                    .first(where: { $0.id == geometryInput.id })?.frame
            if let currentFrame {
                let corner = MapOverlayPlacementSolver.nearestCorner(for: currentFrame,
                    in: canvasSize, current: placement.corner)
                if !placement.isDocked || placement.corner != corner {
                    updated = MapOverlayPlacementSolver.docked(updated, at: corner,
                        nextStackOrder: stackPeers(in: corner).count)
                }
            }
            updated.isCollapsed = true
        } else {
            updated.isCollapsed = false
        }
        if updated.isDocked && (updated.corner != placement.corner || !placement.isDocked) {
            updateStackPlacement(updated)
        } else {
            updatePlacement(updated)
        }
    }

    private func moveOverlay(by delta: CGSize, canvasSize: CGSize) {
        let updated = MapOverlayPlacementSolver.moved(geometryInput, by: delta,
            in: canvasSize, peers: peerGeometry)
        if updated.isDocked {
            updateStackPlacement(updated)
        } else {
            updatePlacement(updated)
        }
    }

    private func resizeOverlay(by delta: CGSize) {
        guard isResizable else { return }
        let size = MapOverlayPlacementSolver.resized(baseOuterSize, by: delta,
            minimum: outerMinimumSize, maximum: outerMaximumSize)
        var updated = placement
        updated.width = Double(size.width)
        updated.height = Double(size.height)
        updatePlacement(updated)
    }

    private func updatePlacement(_ value: MapOverlayPlacement) {
        guard value.isValid else { return }
        placement = value
        hasUserPlacement = true
        if let serializationKey { MapOverlayPlacementStore.save(value, for: serializationKey) }
    }

    private func stackPeers(in corner: MapOverlayCorner) -> [MapOverlayGeometryInput] {
        peerGeometry.filter {
            $0.isVisible && $0.placement.corner == corner && $0.placement.isDocked
        }.sorted {
            if $0.placement.stackOrder != $1.placement.stackOrder {
                return $0.placement.stackOrder < $1.placement.stackOrder
            }
            return $0.id < $1.id
        }
    }

    private func updateStackPlacement(_ value: MapOverlayPlacement) {
        guard value.isValid else { return }
        // A missing stable serialization key is also the first-launch/preview
        // opt-out: do not persist this overlay or any peer stack changes.
        guard let serializationKey else {
            updatePlacement(value)
            return
        }
        let item = MapOverlayGeometryInput(id: serializationKey,
            placement: value, desiredSize: currentOuterSize,
            minimumSize: outerMinimumSize, maximumSize: outerMaximumSize,
            isResizable: isResizable, zIndex: zIndex)
        let changes = MapOverlayPlacementSolver.insertingIntoStack(item,
            at: value.stackOrder, corner: value.corner, peers: peerGeometry)
        for change in changes {
            MapOverlayPlacementStore.save(change.placement,
                for: change.id == item.id ? serializationKey : change.id)
        }
        updatePlacement(value)
    }

    private func resetPlacement() {
        if let serializationKey { MapOverlayPlacementStore.remove(serializationKey) }
        placement = MapOverlayPlacement(corner: adaptiveDefaultCorner ?? initialCorner,
                                        stackOrder: initialStackOrder)
        hasUserPlacement = false
    }
}
