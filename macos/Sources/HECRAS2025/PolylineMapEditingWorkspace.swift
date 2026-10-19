import AppKit
import RASWorkspaceCore
import SwiftUI

struct PolylineMapEditingWorkspace: View {
    @ObservedObject var session: PolylineMapEditingSession
    let scope: PolylineMapEditingScope
    let destinationLayer: MapVectorLayer?
    let system: any WorkspaceSystemServices
    @State private var mergeToleranceInput = "5"
    @State private var geoprocessingSheet: PolylineGeoprocessOperation?

    private var toolBinding: Binding<PolylineMapEditingTool> {
        Binding(get: { session.tool }, set: session.setTool)
    }
    private var selectionShapeBinding: Binding<PolylineSelectionShape> {
        Binding(get: { session.selectionShape }, set: session.setSelectionShape)
    }
    private var lassoModeBinding: Binding<PolylineLassoMatchMode> {
        Binding(get: { session.lassoMatchMode }, set: session.setLassoMatchMode)
    }
    private var splitModeBinding: Binding<GeoJSONPolylineSplitMode> {
        Binding(get: { session.splitMode }, set: session.setSplitMode)
    }
    private var saveTitle: String {
        URL(fileURLWithPath: scope.canonicalPath).pathExtension.lowercased() == "shp"
            ? "Save Shapefile" : "Save GeoJSON"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker(L10n.text("Polyline tool"), selection: toolBinding) {
                    Text(L10n.text("Select")).tag(PolylineMapEditingTool.select)
                    Text(L10n.text("Draw Line")).tag(PolylineMapEditingTool.drawLine).disabled(!session.supportsAddingLines)
                    Text(L10n.text("Edit Vertices")).tag(PolylineMapEditingTool.editVertices).disabled(!session.supportsNativePathEditing)
                    Text(L10n.text("Split Line")).tag(PolylineMapEditingTool.splitLine).disabled(!session.supportsNativePathEditing)
                    Text(L10n.text("Merge Lines")).tag(PolylineMapEditingTool.mergeLines).disabled(!session.supportsNativePathEditing)
                    Text(L10n.text("Attach Endpoint")).tag(PolylineMapEditingTool.attachEndpoint).disabled(!session.supportsNativePathEditing)
                }
                .pickerStyle(.menu)
                .frame(width: 190)
                if session.tool == .select || session.tool == .mergeLines {
                    Picker(L10n.text("Selection Shape"), selection: selectionShapeBinding) {
                        Text(L10n.text("Rectangle")).tag(PolylineSelectionShape.rectangle)
                        Text(L10n.text("Freehand Path")).tag(PolylineSelectionShape.freehandPath)
                        Text(L10n.text("Lasso")).tag(PolylineSelectionShape.lasso)
                    }
                    .frame(width: 150)
                    if session.selectionShape == .lasso {
                        Picker(L10n.text("Selection Rule"), selection: lassoModeBinding) {
                            Text(L10n.text("Intersects")).tag(PolylineLassoMatchMode.intersects)
                            Text(L10n.text("Contained")).tag(PolylineLassoMatchMode.contained)
                        }
                        .frame(width: 150)
                    }
                }
                if session.tool == .splitLine {
                    Picker(L10n.text("Split Mode"), selection: splitModeBinding) {
                        Text(L10n.text("Anywhere")).tag(GeoJSONPolylineSplitMode.anywhere)
                        Text(L10n.text("At Vertex")).tag(GeoJSONPolylineSplitMode.atVertex)
                    }
                    .frame(width: 130)
                }
                Divider().frame(height: 24)
                Button { Task { _ = await session.undo() } } label: { Label(L10n.text("Undo"), systemImage: "arrow.uturn.backward") }
                    .disabled(!session.canUndo || session.isBusy || !session.isEditAllowed)
                Button { Task { _ = await session.redo() } } label: { Label(L10n.text("Redo"), systemImage: "arrow.uturn.forward") }
                    .disabled(!session.canRedo || session.isBusy || !session.isEditAllowed)
                Button {
                    guard let destinationLayer else { return }
                    Task {
                        _ = await session.pasteCopiedPolylines(
                            system: system,
                            destinationProjectionWKT: destinationLayer.targetProjectionWKT
                        )
                    }
                } label: { Label(L10n.text("Paste Copied Lines"), systemImage: "doc.on.clipboard") }
                    .disabled(destinationLayer == nil || !session.supportsAddingLines || session.isBusy
                        || session.isSourceStale || !session.isEditAllowed)
                if session.tool == .drawLine {
                    Button { Task { _ = await session.finishDrawing() } } label: { Label(L10n.text("Finish Line"), systemImage: "checkmark") }
                        .disabled(session.previewPoints.count < 2 || session.isBusy || !session.isEditAllowed)
                    Button(L10n.text("Cancel Drawing"), systemImage: "xmark") { session.cancelDrawing() }
                        .disabled(session.previewPoints.isEmpty || !session.isEditAllowed)
                }
                if session.tool == .attachEndpoint, session.endpointAttachDraft != nil {
                    Button { Task { _ = await session.finishEndpointAttach() } } label: {
                        Label(L10n.text("Apply Endpoint"), systemImage: "checkmark")
                    }
                    .disabled(session.isBusy || !session.isEditAllowed)
                    Button(L10n.text("Cancel Preview"), systemImage: "xmark") { session.cancelEndpointAttach() }
                        .disabled(session.isBusy)
                }
                if session.tool == .mergeLines {
                    HStack(spacing: 4) {
                        Text(L10n.text("Merge Tolerance (world units)"))
                        TextField("5", text: $mergeToleranceInput)
                            .frame(width: 54).monospacedDigit()
                            .onSubmit {
                                if let value = Double(mergeToleranceInput), value.isFinite, value >= 0 { session.setMergeTolerance(value) }
                                mergeToleranceInput = String(session.mergeTolerance)
                            }
                    }
                    Button { Task { _ = await session.mergeSelectedLines() } } label: {
                        Label(L10n.text("Merge Selected"), systemImage: "point.3.connected.trianglepath.dotted")
                    }
                    .disabled(!session.canMergeSelectedLines)
                }
                Spacer()
                if session.isBusy { ProgressView().controlSize(.small) }
                Button { Task { _ = await session.discard() } } label: { Label(L10n.text("Discard"), systemImage: "arrow.uturn.backward.circle") }
                    .disabled(!session.hasUnsavedChanges || session.isBusy)
                Button { Task { _ = await session.save() } } label: { Label(L10n.text(saveTitle), systemImage: "square.and.arrow.down") }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!session.canCommitDraft)
            }
            .padding(10)
            .background(.bar)

            if session.tool == .attachEndpoint {
                Label(L10n.text("Raster surface snapping is unavailable for this line layer."), systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.bottom, 8)
            }

            if session.isSourceStale {
                Label(L10n.text("The line source changed on disk. Your draft is preserved; reload or discard before editing."), systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange).frame(maxWidth: .infinity, alignment: .leading).padding(10)
            }

            HStack(spacing: 0) {
                lineList
                    .frame(minWidth: 220, idealWidth: 280, maxWidth: 360)
                Divider()
                PolylineMapEditingCanvas(session: session)
                    .frame(minWidth: 460, minHeight: 360)
            }
            Divider()
            detailBar
        }
        .task(id: scope) { _ = await session.ensureLoaded(scope: scope) }
        .onKeyPress(.escape, phases: .down) { _ in
            if session.openedLineID != nil { session.closeLine(); return .handled }
            if session.endpointAttachDraft != nil { session.cancelEndpointAttach(); return .handled }
            if !session.previewPoints.isEmpty { session.cancelDrawing(); return .handled }
            session.setTool(.select); return .handled
        }
        .alert(L10n.text("Polyline editing"), isPresented: Binding(
            get: { session.errorMessage != nil },
            set: { if !$0 { session.clearError() } }
        )) {
            Button(L10n.text("OK")) { session.clearError() }
        } message: { Text(L10n.text(session.errorMessage ?? "")) }
        .sheet(item: $geoprocessingSheet) { operation in
            PolylineGeoprocessingSettingsView(session: session, operation: operation)
        }
    }

    private var lineList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(L10n.text("Source lines")).font(.headline)
                Spacer()
                Text("\(session.lines.count)").foregroundStyle(.secondary).monospacedDigit()
            }
            .padding(12)
            Divider()
            if session.lines.isEmpty {
                ContentUnavailableView(L10n.text("No line features"),
                    systemImage: "point.3.connected.trianglepath.dotted",
                    description: Text(L10n.text("This map layer contains no line components.")))
            } else {
                List(selection: Binding(get: { session.selectedLineID }, set: session.selectLine)) {
                    ForEach(session.lines) { line in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(line.name).lineLimit(1)
                                Spacer(minLength: 4)
                                if session.selectedLineIDs.contains(line.id) { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor) }
                            }
                            HStack(spacing: 8) {
                                Text(L10n.format("%lld vertices", Int64(line.points.count)))
                                if !line.canEdit { Text(L10n.text("Identity is ambiguous; read only")).foregroundStyle(.orange) }
                            }
                            .font(.caption).foregroundStyle(.secondary)
                        }
                        .tag(line.id)
                    }
                }
                .listStyle(.sidebar)
            }
            if !session.supportsAddingLines {
                Text(L10n.text("Drawing or deleting lines directly is available for GeoJSON layers."))
                    .font(.caption).foregroundStyle(.secondary).padding(10)
            }
        }
        .background(.background)
    }

    private var detailBar: some View {
        HStack(spacing: 12) {
            if let line = session.selectedLine {
                Label(line.name, systemImage: "point.3.connected.trianglepath.dotted").lineLimit(1)
                Text(L10n.format("%lld vertices", Int64(line.points.count))).foregroundStyle(.secondary)
                if let index = session.selectedVertexIndex, let point = session.selectedPoint {
                    Text(L10n.format("Vertex %@", String(index + 1))).foregroundStyle(.secondary)
                    Text(L10n.format("X %@ · Y %@", String(point.x), String(point.y)))
                        .monospacedDigit().foregroundStyle(.secondary)
                }
                if session.selectedVertexIndices.count > 1 {
                    Text(L10n.format("%lld vertices selected", Int64(session.selectedVertexIndices.count)))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if session.tool == .editVertices {
                    Button { Task { _ = await session.deleteSelectedVertices() } } label: {
                        Label(L10n.text("Delete Selected Vertices"), systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                    }
                    .disabled(session.selectedVertexIndices.isEmpty || !session.canEditSelectedLine)
                }
                if session.openedLineID == line.id {
                    Button(L10n.text("Close Line"), systemImage: "xmark.circle") { session.closeLine() }
                } else {
                    Button(L10n.text("Open Line"), systemImage: "arrow.up.right.square") { session.openLine(line.id) }
                        .disabled(!line.canEdit || !session.isEditAllowed)
                }
                Button { Task { _ = await session.reverseSelectedLine() } } label: { Label(L10n.text("Reverse Line"), systemImage: "arrow.left.arrow.right") }
                    .disabled(!session.canEditSelectedLine)
                Button(L10n.text("Filter…"), systemImage: "line.3.horizontal.decrease") {
                    geoprocessingSheet = .filter
                }
                .disabled(!session.canEditSelectedLine || !session.selectedLineSupportsXYGeoprocessing)
                Button(L10n.text("Smooth…"), systemImage: "waveform.path") {
                    geoprocessingSheet = .smooth
                }
                .disabled(!session.canEditSelectedLine || !session.selectedLineSupportsXYGeoprocessing)
                Button(role: .destructive) { Task { _ = await session.deleteSelectedLine() } } label: { Label(L10n.text("Delete Line"), systemImage: "trash") }
                    .disabled(!session.canDeleteSelectedLine)
                if !session.selectedLineSupportsXYGeoprocessing {
                    Text(L10n.text(session.selectedLineGeoprocessingRestriction ?? "Filter and Smooth require a finite, nonzero 2D line. Z/M lines are preserved unchanged."))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            } else {
                Text(L10n.text("Select a source line or choose Draw Line to create one."))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            if session.selectedLineIDs.count > 1 {
                Text(L10n.format("%lld lines selected", Int64(session.selectedLineIDs.count))).foregroundStyle(.secondary)
            }
            if session.hasUnsavedChanges { Label(L10n.text("Unsaved line edits"), systemImage: "circle.fill").font(.caption).foregroundStyle(.orange) }
        }
        .padding(10)
    }
}

private struct PolylineDragPreview {
    let lineID: String
    let vertexIndices: Set<Int>
    let start: MapPoint
    let current: MapPoint
    let duplicateTolerance: Double
    var delta: MapPoint { MapPoint(x: current.x - start.x, y: current.y - start.y) }
}

struct PolylineMapEditingCanvas: View {
    @ObservedObject var session: PolylineMapEditingSession
    @FocusState private var hasKeyboardFocus: Bool
    @State private var dragPreview: PolylineDragPreview?
    @State private var viewScale: CGFloat = 1
    @State private var viewOffset = CGSize.zero
    @State private var panTranslation = CGSize.zero
    @State private var startingScale: CGFloat?
    @State private var selectionStart: MapPoint?
    @State private var selectionPath: [MapPoint] = []
    @State private var isPointSelectionDrag = false
    @State private var isMergeLassoDrag = false
    @State private var isPanning = false

    private var allPoints: [MapPoint] {
        (session.currentMapLayer?.points ?? session.lines.flatMap(\.points))
            + session.previewPoints
            + (session.endpointAttachDraft.map { [$0.anchor, $0.point] } ?? [])
    }

    var body: some View {
        GeometryReader { proxy in
            let transform = MapTransform(points: allPoints, size: proxy.size, scale: viewScale,
                offset: CGSize(width: viewOffset.width + panTranslation.width, height: viewOffset.height + panTranslation.height))
            ZStack {
                Color(nsColor: .textBackgroundColor)
                Canvas { context, _ in
                    for feature in session.currentMapLayer?.features ?? session.currentFeatures {
                        switch feature.kind {
                        case .point:
                            for point in feature.paths.flatMap({ $0 }) {
                                let center = transform.screen(point)
                                context.fill(Path(ellipseIn: CGRect(x: center.x - 3, y: center.y - 3, width: 6, height: 6)), with: .color(.secondary))
                            }
                        case .polygon:
                            var polygon = Path()
                            for ring in feature.paths {
                                guard let first = ring.first else { continue }
                                polygon.move(to: transform.screen(first))
                                for point in ring.dropFirst() { polygon.addLine(to: transform.screen(point)) }
                                polygon.closeSubpath()
                            }
                            context.fill(polygon, with: .color(.secondary.opacity(0.12)), style: FillStyle(eoFill: true))
                            context.stroke(polygon, with: .color(.secondary.opacity(0.7)), lineWidth: 1)
                        case .line:
                            for (pathIndex, sourcePoints) in feature.paths.enumerated() {
                                let pathIdentity = feature.pathStableIdentities.indices.contains(pathIndex)
                                    ? feature.pathStableIdentities[pathIndex] : feature.stableIdentity
                                let pathPoints = session.lines.first(where: { $0.id == pathIdentity })
                                    .map(displayPoints(for:)) ?? sourcePoints
                                guard let first = pathPoints.first else { continue }
                                let selected = session.selectedLineIDs.contains(pathIdentity)
                                var path = Path(); path.move(to: transform.screen(first))
                                for point in pathPoints.dropFirst() { path.addLine(to: transform.screen(point)) }
                                context.stroke(path, with: .color(selected ? .orange : .accentColor),
                                    style: StrokeStyle(lineWidth: selected ? 3 : 1.7, lineCap: .round, lineJoin: .round))
                                if selected && session.tool == .attachEndpoint, let first = pathPoints.first, let last = pathPoints.last {
                                    for endpoint in [first, last] {
                                        let center = transform.screen(endpoint)
                                        context.fill(Path(ellipseIn: CGRect(x: center.x - 5, y: center.y - 5, width: 10, height: 10)), with: .color(.orange))
                                    }
                                }
                            }
                        }
                    }
                    if session.tool == .editVertices, let selected = session.selectedLine {
                        let points = displayPoints(for: selected)
                        for (index, point) in points.enumerated() {
                            let center = transform.screen(point)
                            let isSelected = session.selectedVertexIndices.contains(index)
                            let size: CGFloat = isSelected ? (index == session.selectedVertexIndex ? 11 : 9) : 7
                            context.fill(Path(ellipseIn: CGRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size)),
                                with: .color(isSelected ? .orange : .white))
                            context.stroke(Path(ellipseIn: CGRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size)),
                                with: .color(.accentColor), lineWidth: 1.5)
                        }
                    }
                    if session.previewPoints.count > 1 {
                        var preview = Path(); preview.move(to: transform.screen(session.previewPoints[0]))
                        for point in session.previewPoints.dropFirst() { preview.addLine(to: transform.screen(point)) }
                        context.stroke(preview, with: .color(.orange), style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    }
                    for point in session.previewPoints {
                        let center = transform.screen(point)
                        context.fill(Path(ellipseIn: CGRect(x: center.x - 4, y: center.y - 4, width: 8, height: 8)), with: .color(.orange))
                    }
                    if let draft = session.endpointAttachDraft {
                        var attach = Path(); attach.move(to: transform.screen(draft.anchor)); attach.addLine(to: transform.screen(draft.point))
                        context.stroke(attach, with: .color(.orange), style: StrokeStyle(lineWidth: 2, dash: [5, 3]))
                        let tip = transform.screen(draft.point)
                        context.fill(Path(ellipseIn: CGRect(x: tip.x - 5, y: tip.y - 5, width: 10, height: 10)), with: .color(.orange))
                    }
                    if let selectionStart {
                        var selection = Path()
                        if isPointSelectionDrag || (!isMergeLassoDrag && session.selectionShape == .rectangle) {
                            let start = transform.screen(selectionStart)
                            let end = transform.screen(selectionPath.last ?? selectionStart)
                            selection.addRect(CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                                width: abs(start.x - end.x), height: abs(start.y - end.y)))
                        } else if let first = selectionPath.first {
                            selection.move(to: transform.screen(first))
                            for point in selectionPath.dropFirst() { selection.addLine(to: transform.screen(point)) }
                            if isMergeLassoDrag || session.selectionShape == .lasso { selection.closeSubpath() }
                        }
                        context.fill(selection, with: .color(.accentColor.opacity(0.08)))
                        context.stroke(selection, with: .color(.accentColor), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    }
                }
                .contentShape(Rectangle())
                .simultaneousGesture(SpatialTapGesture().onEnded { value in handleTap(value.location, transform: transform) })
                .simultaneousGesture(SpatialTapGesture(count: 2).onEnded { value in handleDoubleTap(value.location, transform: transform) })
                .simultaneousGesture(DragGesture(minimumDistance: 2).onChanged { value in
                    hasKeyboardFocus = true
                    if !isMergeLassoDrag, (session.tool == .select || session.tool == .mergeLines),
                       NSEvent.modifierFlags.contains(.option) {
                        isPanning = true
                        panTranslation = value.translation
                        return
                    }
                    if session.tool == .select || session.tool == .mergeLines || isMergeLassoDrag {
                        isPanning = false
                        let world = transform.world(value.location)
                        if selectionStart == nil {
                            isMergeLassoDrag = session.tool == .mergeLines
                            selectionStart = transform.world(value.startLocation)
                            selectionPath = [transform.world(value.startLocation)]
                        }
                        if isMergeLassoDrag || session.selectionShape != .rectangle,
                           selectionPath.last.map({ hypot($0.x - world.x, $0.y - world.y) > 0 }) ?? true {
                            selectionPath.append(world)
                        } else if session.selectionShape == .rectangle {
                            selectionPath = [selectionStart ?? world, world]
                        }
                        return
                    }
                    if session.tool == .attachEndpoint {
                        if session.endpointAttachDraft == nil,
                           let endpoint = nearestEndpointHit(value.startLocation, transform: transform) {
                            let maximumDistance = 64.0 / max(Double(transform.factor), 1e-12)
                            session.beginEndpointAttach(lineID: endpoint.lineID,
                                anchor: transform.world(value.startLocation), maximumDistance: maximumDistance)
                        }
                        session.updateEndpointAttach(to: transform.world(value.location))
                        return
                    }
                    guard session.tool == .editVertices else { return }
                    let start = transform.world(value.startLocation)
                    let currentPoint = transform.world(value.location)
                    if dragPreview == nil && !isPointSelectionDrag {
                        if let hit = hitTest(value.startLocation, transform: transform),
                           let vertex = hit.vertexIndex, let lineID = hit.lineID {
                            if !session.selectedVertexIndices.contains(vertex) { session.selectVertex(vertex) }
                            let selected = session.selectedVertexIndices
                            guard !selected.isEmpty else { return }
                            dragPreview = PolylineDragPreview(lineID: lineID, vertexIndices: selected,
                                start: start, current: currentPoint,
                                duplicateTolerance: 5.0 / max(Double(transform.factor), 1e-12))
                        } else {
                            isPointSelectionDrag = true
                            selectionStart = start
                            selectionPath = [start, currentPoint]
                        }
                    } else if let current = dragPreview {
                        dragPreview = PolylineDragPreview(lineID: current.lineID, vertexIndices: current.vertexIndices,
                            start: current.start, current: currentPoint, duplicateTolerance: current.duplicateTolerance)
                    } else if isPointSelectionDrag {
                        selectionPath = [selectionStart ?? start, currentPoint]
                    }
                }.onEnded { value in
                    if isPanning {
                        viewOffset.width += value.translation.width; viewOffset.height += value.translation.height
                        panTranslation = .zero; isPanning = false; return
                    }
                    let mergeGesture = isMergeLassoDrag || session.tool == .mergeLines
                    if session.tool == .select || session.tool == .mergeLines || isMergeLassoDrag {
                        let start = selectionStart
                        let path = selectionPath
                        selectionStart = nil; selectionPath = []
                        isMergeLassoDrag = false
                        guard let start, path.count >= (mergeGesture ? 3 : 2) else { return }
                        let modifiers = currentModifiers()
                        Task {
                            if mergeGesture {
                                session.selectByLasso(path, additive: false, matchMode: .intersects)
                                _ = await session.mergeSelectedLines()
                            } else {
                                applySelection(shape: session.selectionShape, start: start, path: path,
                                    additive: modifiers.extendsSelection)
                            }
                        }
                        return
                    }
                    if session.tool == .editVertices, isPointSelectionDrag {
                        let start = selectionStart
                        let end = transform.world(value.location)
                        selectionStart = nil; selectionPath = []; isPointSelectionDrag = false
                        if let start {
                            session.selectVertices(inRectangleFrom: start, to: end,
                                toggle: currentModifiers().contains(.control))
                        }
                        return
                    }
                    if session.tool == .editVertices, let preview = dragPreview {
                        let end = transform.world(value.location)
                        dragPreview = nil
                        let delta = MapPoint(x: end.x - preview.start.x, y: end.y - preview.start.y)
                        Task {
                            _ = await session.moveVertices(lineID: preview.lineID, vertexIndices: preview.vertexIndices,
                                by: delta, duplicateTolerance: preview.duplicateTolerance, interactionPoint: end)
                        }
                        return
                    }
                    if session.tool == .attachEndpoint, session.endpointAttachDraft != nil {
                        Task { _ = await session.finishEndpointAttach() }
                        return
                    }
                })
                .simultaneousGesture(MagnifyGesture().onChanged { value in
                    if startingScale == nil { startingScale = viewScale }
                    viewScale = min(max((startingScale ?? viewScale) * value.magnification, 0.1), 50)
                }.onEnded { _ in startingScale = nil })
                .focusable()
                .focused($hasKeyboardFocus)
                .onKeyPress("s", phases: .down) { press in
                    session.handleTemporaryToolKey("s", isDown: true, canvasFocused: hasKeyboardFocus,
                        modifiers: canvasModifiers(press.modifiers)) ? .handled : .ignored
                }
                .onKeyPress("s", phases: .up) { press in
                    session.handleTemporaryToolKey("s", isDown: false, canvasFocused: hasKeyboardFocus,
                        modifiers: canvasModifiers(press.modifiers)) ? .handled : .ignored
                }
                .onKeyPress("m", phases: .down) { press in
                    session.handleTemporaryToolKey("m", isDown: true, canvasFocused: hasKeyboardFocus,
                        modifiers: canvasModifiers(press.modifiers)) ? .handled : .ignored
                }
                .onKeyPress("m", phases: .up) { press in
                    session.handleTemporaryToolKey("m", isDown: false, canvasFocused: hasKeyboardFocus,
                        modifiers: canvasModifiers(press.modifiers)) ? .handled : .ignored
                }
                .onChange(of: hasKeyboardFocus) { _, focused in
                    if !focused { session.releaseTemporaryTool() }
                }
                .onDisappear { session.releaseTemporaryTool() }
            }
            .overlay(alignment: .topLeading) {
                Text(canvasHint).font(.caption).padding(8).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8)).padding(10)
            }
            .overlay(alignment: .topTrailing) {
                HStack(spacing: 4) {
                    Button { viewScale = min(viewScale * 1.5, 50) } label: { Image(systemName: "plus.magnifyingglass") }
                        .help(L10n.text("Zoom In"))
                    Button { viewScale = max(viewScale / 1.5, 0.1) } label: { Image(systemName: "minus.magnifyingglass") }
                        .help(L10n.text("Zoom Out"))
                    Button { viewScale = 1; viewOffset = .zero } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                        .help(L10n.text("Fit Source Geometry"))
                }
                .buttonStyle(.borderless).padding(8).background(.regularMaterial, in: Capsule()).padding(10)
            }
            .overlay(alignment: .bottomLeading) {
                if session.lines.isEmpty && session.previewPoints.isEmpty {
                    Text(L10n.text("The map draws only coordinates supplied by this GeoJSON source."))
                        .font(.callout).foregroundStyle(.secondary).padding(12)
                }
            }
        }
    }

    private var canvasHint: String {
        switch session.tool {
        case .select: L10n.text("Drag to select; Option-drag to pan. Command-click adds or removes lines.")
        case .drawLine: L10n.text("Click to add vertices, then choose Finish Line.")
        case .editVertices: L10n.text("Click or drag to select vertices. Drag a selected vertex to move the selection.")
        case .splitLine: L10n.text("Click a line to split it. Hold Option to switch the split mode.")
        case .mergeLines: L10n.text("Drag a selection around connected components, then merge them.")
        case .attachEndpoint: L10n.text("Click near an endpoint to extend the selected line. Raster surface snapping is unavailable.")
        }
    }

    private func displayPoints(for line: GeoJSONPolylineLine) -> [MapPoint] {
        guard let preview = dragPreview, preview.lineID == line.id else { return line.points }
        var points = line.points
        for index in preview.vertexIndices where points.indices.contains(index) {
            let original = line.points[index]
            points[index] = MapPoint(x: original.x + preview.delta.x, y: original.y + preview.delta.y)
        }
        return points
    }

    private func handleTap(_ location: CGPoint, transform: MapTransform) {
        hasKeyboardFocus = true
        let point = transform.world(location)
        let modifiers = currentModifiers()
        let splitMaximumDistance = 100.0 / max(Double(transform.factor), 1e-12)
        let attachMaximumDistance = 64.0 / max(Double(transform.factor), 1e-12)
        switch session.tool {
        case .drawLine: session.appendDrawingPoint(point)
        case .select:
            session.selectLine(hitTest(location, transform: transform)?.lineID, additive: modifiers.extendsSelection)
        case .editVertices:
            guard let hit = hitTest(location, transform: transform), let lineID = hit.lineID,
                  lineID == session.selectedLineID else { return }
            if let vertex = hit.vertexIndex { session.selectVertex(vertex, toggle: modifiers.contains(.control)) }
            else if let segment = hit.segmentAfterIndex { Task { _ = await session.insertVertex(lineID: lineID, after: segment, at: point) } }
        case .splitLine:
            Task { _ = await session.splitNearestLine(near: point, maximumDistance: splitMaximumDistance,
                optionToggledMode: modifiers.contains(.option)) }
        case .mergeLines:
            session.selectLine(hitTest(location, transform: transform)?.lineID, additive: modifiers.extendsSelection)
        case .attachEndpoint:
            guard let lineID = nearestEndpointHit(location, transform: transform)?.lineID ?? session.selectedLineID else { return }
            Task { _ = await session.attachEndpoint(lineID: lineID, at: point, maximumDistance: attachMaximumDistance) }
        }
    }

    private func handleDoubleTap(_ location: CGPoint, transform: MapTransform) {
        hasKeyboardFocus = true
        let point = transform.world(location)
        switch session.tool {
        case .drawLine:
            session.appendDrawingPoint(point)
            Task { _ = await session.finishDrawing() }
        case .select:
            if let lineID = hitTest(location, transform: transform)?.lineID { session.toggleOpenLine(lineID) }
        case .editVertices:
            if session.openedLineID != nil { session.closeLine() }
        case .splitLine, .mergeLines, .attachEndpoint: break
        }
    }

    private func applySelection(shape: PolylineSelectionShape, start: MapPoint, path: [MapPoint], additive: Bool) {
        switch shape {
        case .rectangle: session.selectRectangle(from: start, to: path.last ?? start, additive: additive)
        case .freehandPath: session.selectByPath(path, additive: additive)
        case .lasso: session.selectByLasso(path, additive: additive)
        }
    }

    private func currentModifiers() -> PolylineCanvasModifiers {
        let flags = NSEvent.modifierFlags
        var result: PolylineCanvasModifiers = []
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.command) { result.insert(.command) }
        if flags.contains(.control) { result.insert(.control) }
        if flags.contains(.shift) { result.insert(.shift) }
        return result
    }

    private func canvasModifiers(_ modifiers: EventModifiers) -> PolylineCanvasModifiers {
        var result: PolylineCanvasModifiers = []
        if modifiers.contains(.option) { result.insert(.option) }
        if modifiers.contains(.command) { result.insert(.command) }
        if modifiers.contains(.control) { result.insert(.control) }
        if modifiers.contains(.shift) { result.insert(.shift) }
        return result
    }

    private func nearestEndpointHit(_ location: CGPoint, transform: MapTransform) -> (lineID: String, point: MapPoint, distance: CGFloat)? {
        var closest: (String, MapPoint, CGFloat)?
        for line in session.lines.reversed() where line.canEdit {
            guard let first = line.points.first, let last = line.points.last else { continue }
            for point in [first, last] {
                let screen = transform.screen(point)
                let distance = hypot(screen.x - location.x, screen.y - location.y)
                if distance <= 64, closest == nil || distance < closest!.2 { closest = (line.id, point, distance) }
            }
        }
        guard let closest else { return nil }
        return (closest.0, closest.1, closest.2)
    }

    private func hitTest(_ location: CGPoint, transform: MapTransform) -> (lineID: String?, vertexIndex: Int?, segmentAfterIndex: Int?)? {
        let vertexTolerance: CGFloat = 10
        var closestVertex: (String, Int, CGFloat)?
        var closestSegment: (String, Int, CGFloat)?
        var closestLine: (String, CGFloat)?
        for line in session.lines.reversed() {
            if session.tool == .editVertices && (line.id != session.selectedLineID || !line.canEdit) { continue }
            let points = displayPoints(for: line)
            for (index, point) in points.enumerated() {
                let screenPoint = transform.screen(point)
                let distance = hypot(screenPoint.x - location.x, screenPoint.y - location.y)
                if distance <= vertexTolerance, closestVertex == nil || distance < closestVertex!.2 {
                    closestVertex = (line.id, index, distance)
                }
                if index + 1 < points.count {
                    let next = transform.screen(points[index + 1])
                    let segmentDistance = distanceToSegment(location, screenPoint, next)
                    if segmentDistance <= 9, closestSegment == nil || segmentDistance < closestSegment!.2 {
                        closestSegment = (line.id, index, segmentDistance)
                    }
                    if segmentDistance <= 8, closestLine == nil || segmentDistance < closestLine!.1 {
                        closestLine = (line.id, segmentDistance)
                    }
                }
            }
        }
        if session.tool == .editVertices, let vertex = closestVertex { return (vertex.0, vertex.1, nil) }
        if session.tool == .editVertices, let segment = closestSegment { return (segment.0, nil, segment.1) }
        if let closestLine { return (closestLine.0, nil, nil) }
        return nil
    }

    private func distanceToSegment(_ point: CGPoint, _ start: CGPoint, _ end: CGPoint) -> CGFloat {
        let dx = end.x - start.x; let dy = end.y - start.y
        let length = dx * dx + dy * dy
        guard length > 0 else { return hypot(point.x - start.x, point.y - start.y) }
        let fraction = min(max(((point.x - start.x) * dx + (point.y - start.y) * dy) / length, 0), 1)
        return hypot(point.x - (start.x + fraction * dx), point.y - (start.y + fraction * dy))
    }
}
