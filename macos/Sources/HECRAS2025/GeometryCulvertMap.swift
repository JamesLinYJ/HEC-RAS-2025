import AppKit
import RASWorkspaceCore
import SwiftUI

/// A native map for the real barrel coordinates and associated terrain extent.
/// Drawing and reshaping stay local until Apply submits a typed mutation to the
/// parent's opaque culvert ledger; only the parent model save writes the HDF.
struct GeometryCulvertMapView: View {
    @ObservedObject var child: GeometryCulvertSession
    let lineStyle: VectorStyleValues
    let vertexStyle: VectorStyleValues

    @State private var tool: CulvertMapTool = .select
    @State private var zoom = 1.0
    @State private var pan = CGSize.zero
    @State private var dragOffset = CGSize.zero
    @State private var panAtDragStart = CGSize.zero
    @State private var draggingMap = false
    @State private var focusExtent: GeometryCulvertExtent?
    @State private var sketchPoints: [GeometryCulvertCoordinate] = []
    @State private var reshapeID: String?
    @State private var reshapePoints: [GeometryCulvertCoordinate] = []
    @State private var selectedVertexIndex: Int?
    @State private var previewContext: String?
    @State private var moveContext: String?
    @State private var moveIDs: Set<String> = []
    @State private var moveStart: GeometryCulvertCoordinate?
    @State private var moveDelta: GeometryCulvertCoordinate?
    @State private var moveHitID: String?
    @State private var draggingFeature = false
    @State private var lassoRect: CGRect?
    @State private var mapMessage: String?
    @State private var geoprocessingSheet: CulvertPolylineOperationSheetState?
    @State private var mapCommand: CulvertMapCommandMode?
    @State private var splitMode: GeometryCulvertSplitMode = .anywhere
    @State private var mergeTolerance = 5.0
    @State private var offsetDistance = 10.0
    @State private var offsetSides: GeometryCulvertOffsetSides = .both
    @State private var offsetIncludesEndpoints = false
    @State private var offsetKeepsOriginal = false
    @State private var mergePickedIDs: [String] = []
    @State private var commandGeneration = 0
    @State private var showSmartAddSettings = false
    @State private var smartAddPreviewTask: Task<Void, Never>?
    @State private var hoveredMapPoint: GeometryCulvertCoordinate?
    @State private var smartAddPreviewTarget: GeometryCulvertCoordinate?
    @State private var smartAddPreviewWindow: GeometryCulvertSmartAddWindow?
    @State private var smartAddPreviewLocation: CGPoint?

    private var rows: [GeometryCulvertFeatureRow] { child.table(for: "barrel").rows }
    private var selectedIDs: Set<String> { child.selectedFeatureIDs["barrel", default: []] }
    private var selectedRow: GeometryCulvertFeatureRow? {
        guard selectedIDs.count == 1, let id = selectedIDs.first else { return nil }
        return rows.first { $0.id == id }
    }
    private var isPreviewActive: Bool {
        previewContext != nil || moveContext != nil || !sketchPoints.isEmpty || reshapeID != nil || lassoRect != nil
            || mapCommand != nil || child.mapCommandPreview != nil || !child.smartAddSketchPoints.isEmpty
    }
    private var isPreviewStale: Bool {
        if let context = moveContext ?? previewContext, context != currentPreviewContext { return true }
        return commandPreviewIsStale
    }
    private var currentPreviewContext: String? {
        guard let snapshot = child.snapshot else { return nil }
        return child.geometryCulvertIdentity + "|" + snapshot.revision + "|" + snapshot.draftState
    }
    private var mapExtent: GeometryCulvertExtent? {
        if let focusExtent { return focusExtent }
        let terrainExtent = child.snapshot?.associatedTerrainExtent
        let lineExtent = extent(for: rows.flatMap(\.polyline))
        if let terrainExtent, let lineExtent { return union(terrainExtent, lineExtent) }
        return lineExtent ?? terrainExtent
    }
    private var canDraw: Bool { child.canEdit && child.snapshot?.associatedTerrainExtent != nil }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            GeometryReader { geometry in
                ZStack {
                    Canvas { context, size in
                        guard let projection = projection(for: size) else { return }
                        if let preview = child.terrainPreview, let image = terrainImage(preview),
                           let imageExtent = preview.renderedExtent {
                            let northwest = projection.project(.init(x: imageExtent.minX, y: imageExtent.maxY))
                            let southeast = projection.project(.init(x: imageExtent.maxX, y: imageExtent.minY))
                            let rect = CGRect(x: northwest.x, y: northwest.y,
                                width: southeast.x - northwest.x, height: southeast.y - northwest.y)
                            context.draw(Image(decorative: image, scale: 1), in: rect)
                        }
                        for row in rows {
                            let points = displayPoints(for: row)
                            let path = linePath(points, projection: projection)
                            guard !path.isEmpty else { continue }
                            let selected = (moveContext == nil ? selectedIDs : moveIDs).contains(row.id)
                                || mergePickedIDs.contains(row.id)
                            let sourceLineColor = BoundaryARGBColor.decode(lineStyle.penColor) ?? .blue.opacity(0.82)
                            let sourceLineWidth = max(0, CGFloat(lineStyle.penWidth))
                            context.stroke(path, with: .color(sourceLineColor),
                                style: StrokeStyle(lineWidth: sourceLineWidth,
                                    lineCap: .round, lineJoin: .round))
                            if selected {
                                // Keep the editor's selection halo while drawing the
                                // current source/global base style underneath it.
                                context.stroke(path, with: .color(Color.accentColor.opacity(0.55)),
                                    style: StrokeStyle(lineWidth: max(3.2, sourceLineWidth + 2.2),
                                        lineCap: .round, lineJoin: .round))
                                context.stroke(path, with: .color(sourceLineColor),
                                    style: StrokeStyle(lineWidth: sourceLineWidth,
                                        lineCap: .round, lineJoin: .round))
                            }
                            drawStyledVertices(points, in: &context, projection: projection, selected: selected)
                            if selected, !row.polyline.isEmpty {
                                let center = row.polyline[row.polyline.count / 2]
                                let label = row.values["Name"] ?? row.id
                                let labelPosition = projection.project(center)
                                context.draw(Text(verbatim: label).font(.caption).foregroundColor(.primary),
                                    at: CGPoint(x: labelPosition.x, y: labelPosition.y - 12))
                            }
                        }

                        if let preview = child.mapCommandPreview, !commandPreviewIsStale {
                            for row in rows where preview.removedFeatureIDs.contains(row.id) {
                                let path = linePath(row.polyline, projection: projection)
                                context.stroke(path, with: .color(.red.opacity(0.85)),
                                    style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round,
                                        dash: [5, 3]))
                            }
                            for output in preview.outputs {
                                let path = linePath(output.polyline, projection: projection)
                                context.stroke(path, with: .color(.purple),
                                    style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round,
                                        dash: [7, 3]))
                                drawVertices(output.polyline, in: &context, projection: projection, color: .purple)
                            }
                        }

                        if !child.smartAddSketchPoints.isEmpty {
                            let path = linePath(child.smartAddSketchPoints, projection: projection)
                            context.stroke(path, with: .color(.orange),
                                style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
                            drawVertices(child.smartAddSketchPoints, in: &context, projection: projection, color: .orange)
                        }
                        if let pathPoints = child.smartAddPathPreview,
                           let previewTarget = smartAddPreviewTarget,
                           previewTarget == hoveredMapPoint,
                           smartAddPreviewWindow == smartAddWindow(size: size),
                           !child.isLoadingSmartAddPreview, pathPoints.count >= 2 {
                            let path = linePath(pathPoints, projection: projection)
                            context.stroke(path, with: .color(.cyan),
                                style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round,
                                    dash: [6, 4]))
                            drawVertices(pathPoints, in: &context, projection: projection, color: .cyan)
                        }

                        if !sketchPoints.isEmpty {
                            let path = linePath(sketchPoints, projection: projection)
                            context.stroke(path, with: .color(.orange),
                                style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round,
                                    dash: [6, 4]))
                            drawVertices(sketchPoints, in: &context, projection: projection, color: .orange)
                        }

                        if reshapeID != nil {
                            let path = linePath(reshapePoints, projection: projection)
                            context.stroke(path, with: .color(.orange),
                                style: StrokeStyle(lineWidth: 3.4, lineCap: .round, lineJoin: .round))
                            drawVertices(reshapePoints, in: &context, projection: projection, color: .orange)
                        }

                        if let lassoRect {
                            var path = Path()
                            path.addRect(lassoRect)
                            context.fill(path, with: .color(.accentColor.opacity(0.12)))
                            context.stroke(path, with: .color(.accentColor),
                                style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        }
                    }
                    .background(Color(nsColor: .textBackgroundColor).opacity(0.55))

                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(mapGesture(size: geometry.size))
                        .onContinuousHover(coordinateSpace: .local) { phase in
                            guard mapCommand == .smartAdd else { return }
                            switch phase {
                            case .active(let location):
                                handleSmartAddHover(at: location, size: geometry.size)
                            case .ended:
                                commandGeneration += 1
                                hoveredMapPoint = nil
                                smartAddPreviewTarget = nil
                                smartAddPreviewWindow = nil
                                smartAddPreviewLocation = nil
                                smartAddPreviewTask?.cancel()
                                smartAddPreviewTask = nil
                            @unknown default:
                                break
                            }
                        }

                    if reshapeID != nil, let projection = projection(for: geometry.size) {
                        ForEach(Array(reshapePoints.enumerated()), id: \.offset) { index, point in
                            Circle()
                                .fill(selectedVertexIndex == index ? Color.yellow : Color.orange)
                                .overlay(Circle().stroke(.white, lineWidth: 1.4))
                                .frame(width: selectedVertexIndex == index ? 15 : 12,
                                       height: selectedVertexIndex == index ? 15 : 12)
                                .position(projection.project(point))
                                .highPriorityGesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("culvertCanvas"))
                                    .onChanged { value in
                                        selectedVertexIndex = index
                                        guard !isPreviewStale,
                                              let newCoordinate = self.coordinate(at: value.location, in: geometry.size) else { return }
                                        reshapePoints[index] = GeometryCulvertCoordinate(x: newCoordinate.x,
                                            y: newCoordinate.y, z: reshapePoints[index].z, m: reshapePoints[index].m)
                                    })
                        }
                    }

                    if rows.isEmpty && sketchPoints.isEmpty && child.terrainPreview?.hasImage != true {
                        VStack(spacing: 7) {
                            Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                                .font(.title2).foregroundStyle(.secondary)
                            Text(L10n.text(mapExtent == nil
                                ? "No associated terrain extent is available for drawing."
                                : "No culvert barrel lines are present. Draw a line on the associated terrain extent."))
                                .font(.callout).foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .padding(14)
                        .allowsHitTesting(false)
                    }
                }
                .clipShape(Rectangle())
                .coordinateSpace(name: "culvertCanvas")
            }
            .frame(minHeight: 250, idealHeight: 360)

            Divider()
            footer
        }
        .background(.background)
        .task(id: child.terrainPreviewIdentity) {
            await child.loadTerrainPreview()
        }
        .onChange(of: child.geometryCulvertIdentity) { _, _ in
            resetCamera()
            cancelMapPreview()
        }
        .onChange(of: child.snapshot?.revision) { _, _ in
            if commandPreviewIsStale { cancelMapCommandPreviewOnly() }
        }
        .onChange(of: child.snapshot?.draftState) { _, _ in
            if commandPreviewIsStale { cancelMapCommandPreviewOnly() }
        }
        .sheet(item: $geoprocessingSheet) { state in
            GeometryCulvertPolylineOperationSheet(child: child, state: state)
        }
    }

    private var toolbar: some View {
        ScrollView(.horizontal) {
        HStack(spacing: 8) {
            Label(L10n.text("Barrel Map"), systemImage: "map")
                .font(.headline)
            Picker(L10n.text("Map tool"), selection: Binding(get: { tool }, set: changeTool)) {
                ForEach(CulvertMapTool.allCases) { option in
                    Text(L10n.text(option.title)).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 430)
            .disabled(isPreviewActive)

            Menu {
                Button(L10n.text("Split Line"), systemImage: "scissors") { beginMapCommand(.split) }
                Button(L10n.text("Merge Lines"), systemImage: "point.3.connected.trianglepath.dotted") { beginMapCommand(.merge) }
                Button(L10n.text("Offset Line"), systemImage: "arrow.left.and.right") { beginMapCommand(.offset) }
                Button(L10n.text("Smart Add"), systemImage: "point.topleft.down.to.point.bottomright.curvepath") { beginMapCommand(.smartAdd) }
            } label: {
                Label(L10n.text("Polyline Commands"), systemImage: "point.3.connected.trianglepath.dotted")
            }
            .disabled(!child.canEdit || child.hasActiveSketch || child.isEditing || mapCommand != nil)

            if let mapCommand {
                mapCommandControls(mapCommand)
            } else if tool == .draw {
                Button(L10n.text("Finish Line"), systemImage: "checkmark") {
                    Task { await finishSketch() }
                }
                .disabled(!canDraw || isPreviewStale || sketchPoints.count < 2 || child.isEditing)
                Button(L10n.text("Cancel Preview"), systemImage: "xmark") { cancelPreview() }
                    .disabled(previewContext == nil || child.isEditing)
            } else if tool == .reshape {
                Button(L10n.text("Apply Reshape"), systemImage: "checkmark") {
                    Task { await applyReshape() }
                }
                .disabled(!child.canEdit || isPreviewStale || reshapePoints.count < 2 || child.isEditing)
                Button(L10n.text("Delete Vertex"), systemImage: "minus.circle") {
                    deleteSelectedVertex()
                }
                .disabled(isPreviewStale || selectedVertexIndex == nil || reshapePoints.count <= 2)
                Button(L10n.text("Cancel Preview"), systemImage: "xmark") { cancelPreview() }
                    .disabled(child.isEditing)
            } else if tool == .move {
                Button(L10n.text("Cancel Preview"), systemImage: "xmark") { cancelMovePreview() }
                    .disabled(child.isEditing)
            } else {
                Button(L10n.text("Reshape Selected"), systemImage: "point.topleft.down.to.point.bottomright.curvepath") {
                    beginReshape()
                }
                .disabled(!child.canEdit || selectedRow == nil || child.isEditing)
            }

            Button {
                Task { await child.undoLastEdit() }
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .help(L10n.text("Undo Last Culvert Edit"))
            .accessibilityLabel(L10n.text("Undo Last Culvert Edit"))
            .disabled(!child.canEdit || !child.isDirty || isPreviewActive || child.isEditing)

            Divider().frame(height: 18)
            Button { zoom = max(0.55, zoom / 1.25) } label: { Image(systemName: "minus.magnifyingglass") }
                .help(L10n.text("Zoom out")).disabled(zoom <= 0.55 || smartAddWindowIsCaptured)
            Button { zoom = min(8, zoom * 1.25) } label: { Image(systemName: "plus.magnifyingglass") }
                .help(L10n.text("Zoom in")).disabled(zoom >= 8 || smartAddWindowIsCaptured)
            Button { focusSelected() } label: { Image(systemName: "scope") }
                .help(L10n.text("Zoom to Selected")).disabled(selectedRow == nil || smartAddWindowIsCaptured)
            Button { resetCamera() } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                .help(L10n.text("Fit extent"))
                .disabled(smartAddWindowIsCaptured)

            Divider().frame(height: 18)
            Button(L10n.text("Copy Selected"), systemImage: "doc.on.doc") { copySelected() }
                .disabled(selectedIDs.isEmpty || child.hasActiveSketch)
            Button(L10n.text("Copy All"), systemImage: "document.on.document") { copyAll() }
                .disabled(rows.isEmpty || child.hasActiveSketch)
            Button(L10n.text("Paste"), systemImage: "doc.on.clipboard") { pasteFromClipboard() }
                .disabled(!child.canEdit || !GeometryCulvertClipboard.hasPayload || child.hasActiveSketch)
            Button(L10n.text("Duplicate Selected"), systemImage: "plus.square.on.square") {
                Task {
                    let succeeded = await child.duplicateSelectedBarrels()
                    if succeeded { mapMessage = nil }
                    else if child.error == nil { mapMessage = "The selected barrel lines could not be duplicated." }
                }
            }
            .disabled(!child.canEdit || selectedIDs.isEmpty || child.hasActiveSketch)

            Menu {
                Button(L10n.text("Reverse Selected Line"), systemImage: "arrow.uturn.left") {
                    guard let row = selectedRow else { return }
                    Task {
                        if await child.reverseBarrel(id: row.id) { mapMessage = nil }
                    }
                }
                .disabled(!canEditSelectedLine)

                Divider()

                Button(L10n.text("Filter Selected Line…"), systemImage: "line.3.horizontal.decrease") {
                    guard let row = selectedRow else { return }
                    geoprocessingSheet = CulvertPolylineOperationSheetState(barrelID: row.id, operation: .filter,
                        geometryIdentity: child.geometryCulvertIdentity,
                        sourceRevision: child.snapshot?.revision ?? "",
                        draftState: child.snapshot?.draftState ?? "")
                }
                .disabled(!canEditSelectedLine || !selectedLineIsXYOnly)

                Button(L10n.text("Smooth Selected Line…"), systemImage: "waveform.path") {
                    guard let row = selectedRow else { return }
                    geoprocessingSheet = CulvertPolylineOperationSheetState(barrelID: row.id, operation: .smooth,
                        geometryIdentity: child.geometryCulvertIdentity,
                        sourceRevision: child.snapshot?.revision ?? "",
                        draftState: child.snapshot?.draftState ?? "")
                }
                .disabled(!canEditSelectedLine || !selectedLineIsXYOnly)

                if selectedRow != nil && !selectedLineIsXYOnly {
                    Divider()
                    Text(L10n.text("Filter and Smooth create XY-only output; lines with Z or M values are disabled."))
                }
            } label: {
                Label(L10n.text("Geoprocessing"), systemImage: "point.3.connected.trianglepath.dotted")
            }
            .disabled(isPreviewActive || child.hasActiveSketch)
        }
        .padding(.horizontal, 2)
        }
        .scrollIndicators(.hidden)
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let mapMessage {
                Label(L10n.text(mapMessage), systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .font(.caption)
            } else if let error = child.mapCommandError {
                Label(L10n.text(error), systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange).font(.caption)
            } else if let error = child.smartAddError {
                Label(L10n.text(error), systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange).font(.caption)
            } else if isPreviewStale {
                Label(L10n.text("The culvert draft changed while this preview was open. Cancel it before editing the new context."),
                    systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .font(.caption)
            } else if child.mapCommandPreview?.outputs.isEmpty == false || !child.smartAddSketchPoints.isEmpty {
                Label(L10n.text("New culvert barrels use source defaults only. Review their hydraulic properties and opening associations before saving."),
                    systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange).font(.caption)
            } else if let notice = child.mapCommandNotice {
                Label(L10n.text(notice), systemImage: "info.circle")
                    .foregroundStyle(.secondary).font(.caption)
            } else if let notice = child.smartAddNotice {
                Label(L10n.text(notice), systemImage: "info.circle")
                    .foregroundStyle(.secondary).font(.caption)
            }

            if let mapCommand, mapCommand == .smartAdd, !child.smartAddSketchPoints.isEmpty {
                Text(L10n.text("Move the pointer to preview a terrain-following segment, then click to append it. Finish to add the barrel to the geometry draft."))
                    .font(.caption).foregroundStyle(.secondary)
            } else if let mapCommand, mapCommand == .split {
                Text(L10n.text("Click a barrel line to preview a split. Choose Anywhere or At Vertex before applying."))
                    .font(.caption).foregroundStyle(.secondary)
            } else if let mapCommand, mapCommand == .merge {
                Text(L10n.text("Click two distinct barrel lines in order to preview the source closest-endpoint merge."))
                    .font(.caption).foregroundStyle(.secondary)
            } else if let mapCommand, mapCommand == .offset {
                Text(L10n.text("Click a barrel line to preview its offset with the selected source options."))
                    .font(.caption).foregroundStyle(.secondary)
            } else if tool == .draw {
                Text(L10n.text("Click the map to add line vertices, then finish the line."))
                    .font(.caption).foregroundStyle(.secondary)
            } else if tool == .reshape {
                Text(L10n.text("Drag a vertex to move it, click near a segment to insert, or delete the selected vertex."))
                    .font(.caption).foregroundStyle(.secondary)
            } else if tool == .move {
                Text(L10n.text("Drag a barrel to move the selected barrel lines together."))
                    .font(.caption).foregroundStyle(.secondary)
            } else if tool == .lasso {
                Text(L10n.text("Drag a rectangle around barrel lines to select several. Command adds to the current selection."))
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text(L10n.text("Click a barrel line to select it. Drag to pan."))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Label(L10n.text("Global styles shown; per-map .vis overrides are not connected."),
                systemImage: "paintbrush.pointed")
                .font(.caption2).foregroundStyle(.secondary)

            HStack(spacing: 10) {
                if let terrain = child.snapshot?.associatedTerrainName {
                    Text(L10n.text("Associated terrain") + ": " + terrain)
                } else {
                    Text(L10n.text("Associated terrain unavailable"))
                }
                if let extent = mapExtent {
                    Text("X  \(coordinateText(extent.minX)) … \(coordinateText(extent.maxX))")
                    Text("Y  \(coordinateText(extent.minY)) … \(coordinateText(extent.maxY))")
                } else {
                    Text(L10n.text("Extent unavailable"))
                }
                if child.isLoadingTerrainPreview {
                    ProgressView().controlSize(.small)
                    Text(L10n.text("Rendering terrain basemap…"))
                } else if let terrainPreviewError = child.terrainPreviewError {
                    HStack(spacing: 3) {
                        Text(L10n.text("Terrain basemap unavailable"))
                        Text(":")
                        Text(L10n.text(terrainPreviewError)).lineLimit(1)
                    }
                    .help(terrainPreviewError)
                } else if child.snapshot?.associatedTerrainName != nil && child.terrainPreview?.hasImage != true {
                    Text(L10n.text("Terrain image is unavailable for the associated terrain."))
                }
                Spacer(minLength: 0)
                Text(L10n.format("%d culvert lines", rows.count))
                    .font(.caption.monospacedDigit())
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var canEditSelectedLine: Bool {
        child.canEdit && !child.hasActiveSketch && !child.isEditing && selectedRow != nil
    }

    private var smartAddWindowIsCaptured: Bool {
        mapCommand == .smartAdd && !child.smartAddSketchPoints.isEmpty
    }

    private var selectedLineIsXYOnly: Bool {
        guard let row = selectedRow else { return false }
        return child.selectedBarrelSupportsXYOnlyGeoprocessing(id: row.id)
    }

    private var commandPreviewIsStale: Bool {
        guard let preview = child.mapCommandPreview else { return false }
        guard let snapshot = child.snapshot else { return true }
        return preview.geometryIdentity != child.geometryCulvertIdentity
            || preview.revision != snapshot.revision
            || preview.draftState != snapshot.draftState
            || preview.dependencyRevision != (snapshot.dependencyRevision ?? "")
    }

    @ViewBuilder
    private func mapCommandControls(_ mode: CulvertMapCommandMode) -> some View {
        switch mode {
        case .split:
            Picker(L10n.text("Split mode"), selection: $splitMode) {
                Text(L10n.text("Anywhere")).tag(GeometryCulvertSplitMode.anywhere)
                Text(L10n.text("At Vertex")).tag(GeometryCulvertSplitMode.atVertex)
            }
            .pickerStyle(.segmented)
            .frame(width: 190)
            .disabled(child.mapCommandPreview != nil || child.isLoadingMapCommandPreview)
            Text(L10n.text("Click a line"))
                .font(.caption).foregroundStyle(.secondary)
            commandPreviewActions

        case .merge:
            TextField(L10n.text("Tolerance (map units)"), value: $mergeTolerance,
                format: .number.precision(.fractionLength(0...6)))
                .textFieldStyle(.roundedBorder)
                .frame(width: 150)
                .disabled(child.mapCommandPreview != nil || child.isLoadingMapCommandPreview)
            Text(L10n.format("%d of 2 lines selected", min(mergePickedIDs.count, 2)))
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            commandPreviewActions

        case .offset:
            TextField(L10n.text("Distance"), value: $offsetDistance,
                format: .number.precision(.fractionLength(0...6)))
                .textFieldStyle(.roundedBorder)
                .frame(width: 100)
                .disabled(child.mapCommandPreview != nil || child.isLoadingMapCommandPreview)
            Picker(L10n.text("Sides"), selection: $offsetSides) {
                Text(L10n.text("Left")).tag(GeometryCulvertOffsetSides.left)
                Text(L10n.text("Right")).tag(GeometryCulvertOffsetSides.right)
                Text(L10n.text("Both")).tag(GeometryCulvertOffsetSides.both)
            }
            .frame(width: 145)
            .disabled(child.mapCommandPreview != nil || child.isLoadingMapCommandPreview)
            Toggle(L10n.text("Connect endpoints"), isOn: $offsetIncludesEndpoints)
                .toggleStyle(.checkbox)
                .disabled(child.mapCommandPreview != nil || child.isLoadingMapCommandPreview)
            Toggle(L10n.text("Keep original"), isOn: $offsetKeepsOriginal)
                .toggleStyle(.checkbox)
                .disabled(child.mapCommandPreview != nil || child.isLoadingMapCommandPreview)
            commandPreviewActions

        case .smartAdd:
            Button(L10n.text("Smart Add Settings"), systemImage: "slider.horizontal.3") {
                showSmartAddSettings = true
            }
            .popover(isPresented: $showSmartAddSettings) {
                smartAddSettings
            }
            .disabled(child.isLoadingSmartAddPreview || child.isFinishingSmartAdd)
            if child.smartAddSketchPoints.isEmpty {
                Text(L10n.text("Click the map to set a start point"))
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text(L10n.format("%d vertices", child.smartAddSketchPoints.count))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Button(L10n.text("Finish Smart Add"), systemImage: "checkmark") {
                    Task {
                        let id = await child.finishSmartAddSketch()
                        if id != nil {
                            mapCommand = nil
                            mapMessage = nil
                        } else if child.error == nil && child.smartAddError == nil {
                            mapMessage = "The terrain-following culvert line could not be added. The sketch remains available."
                        }
                    }
                }
                .disabled(!child.canEdit || child.smartAddSketchPoints.count < 2 || child.isEditing
                    || !child.canFinishSmartAddSketch || child.isLoadingSmartAddPreview)
            }
            if child.isLoadingSmartAddPreview || child.isFinishingSmartAdd { ProgressView().controlSize(.small) }
            Button(L10n.text("Cancel Command"), systemImage: "xmark") { cancelMapCommand() }
                .disabled(child.isEditing || child.isFinishingSmartAdd)
        }
    }

    private var smartAddSettings: some View {
        Form {
            Section(L10n.text("Algorithm")) {
                Picker(L10n.text("Algorithm"), selection: smartAddOptionBinding(\.algorithm)) {
                    Text(L10n.text("Hessian Ridgeness")).tag("HessianRidgeness")
                    Text(L10n.text("High Ground")).tag("HighGround")
                }
                .help(L10n.text("Path-finder used for smart append. HessianRidgeness is polarity-agnostic; HighGround biases toward ridges only."))
            }

            Section(L10n.text("Path Options")) {
                TextField(L10n.text("Simplify Tolerance (px)"), value: smartAddOptionBinding(\.dpTolerancePixels),
                    format: .number.precision(.fractionLength(0...6)))
                    .help(L10n.text("Douglas–Peucker tolerance applied to the walker output, in screen pixels."))
                TextField(L10n.text("Max Segment Length (px)"), value: smartAddOptionBinding(\.maxSegmentPixels),
                    format: .number.precision(.fractionLength(0...6)))
                    .help(L10n.text("Maximum straight-line A→B distance in screen pixels before the handler bails to vanilla append."))
                TextField(L10n.text("Preview Throttle (px)"), value: smartAddOptionBinding(\.previewThrottlePixels),
                    format: .number.precision(.fractionLength(0...6)))
                    .help(L10n.text("Skip A* recompute when the cursor has moved less than this many pixels since the last frame."))
            }

            Section(L10n.text("High Ground Options")) {
                TextField(L10n.text("HighGround α"), value: smartAddOptionBinding(\.highGroundAlpha),
                    format: .number.precision(.fractionLength(0...6)))
                    .help(L10n.text("Ridge preference weight. 0 = straight-line; higher values track ridges harder."))
                TextField(L10n.text("HighGround Bail Ratio"), value: smartAddOptionBinding(\.highGroundBailRatio),
                    format: .number.precision(.fractionLength(0...6)))
                    .help(L10n.text("Multiplier on straight-line distance used to gate runaway A* search."))
                TextField(L10n.text("HighGround Snap Radius (cells)"), value: smartAddOptionBinding(\.highGroundSnapRadiusCells),
                    format: .number)
                    .help(L10n.text("Radius in grid cells used to snap the cursor target to the highest nearby cell."))
            }

            Section(L10n.text("Hessian Options")) {
                TextField(L10n.text("Hessian Frangi β"), value: smartAddOptionBinding(\.hessianFrangiBeta),
                    format: .number.precision(.fractionLength(0...6)))
                    .help(L10n.text("Frangi anisotropy weight. Standard value is 0.5; lower values penalize plate-like responses harder."))
                TextField(L10n.text("Hessian Feature Penalty κ"), value: smartAddOptionBinding(\.hessianFeaturePenaltyKappa),
                    format: .number.precision(.fractionLength(0...6)))
                    .help(L10n.text("A* edge-cost multiplier for off-feature cells (cost = step·(1 + κ·(1 − V̂))). Default 3.0."))
                TextField(L10n.text("Hessian Off-Feature Bail"), value: smartAddOptionBinding(\.hessianOffFeatureBailMultiplier),
                    format: .number.precision(.fractionLength(0...6)))
                    .help(L10n.text("Multiplier on Euclidean distance used to gate off-feature meander before A* gives up. Default 100.0."))
                TextField(L10n.text("Hessian Min Expansions Budget"), value: smartAddOptionBinding(\.hessianMinExpansionsBudget),
                    format: .number)
                    .help(L10n.text("Floor on the A* expansion budget regardless of Euclidean distance. Default 250 000."))
                TextField(L10n.text("Hessian Expansions / px"), value: smartAddOptionBinding(\.hessianExpansionsPerEuclidPx),
                    format: .number)
                    .help(L10n.text("Per-pixel scale on the A* expansion budget above the floor. Default 500."))
                TextField(L10n.text("Hessian Max Distance (cells)"), value: smartAddOptionBinding(\.hessianMaxEuclidCells),
                    format: .number)
                    .help(L10n.text("Hard cap on Euclidean distance (in cells) before the Hessian walker bails without building its feature surface."))
            }

            Text(L10n.text("Changing Smart Add settings clears the current segment preview. Accepted path segments remain in the sketch."))
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .padding(10)
        .frame(width: 430, height: 590)
    }

    private func smartAddOptionBinding<Value>(_ keyPath: WritableKeyPath<GeometryCulvertSmartAddOptions, Value>) -> Binding<Value> {
        Binding(
            get: { child.smartAddOptions[keyPath: keyPath] },
            set: { child.smartAddOptions[keyPath: keyPath] = $0 }
        )
    }

    @ViewBuilder
    private var commandPreviewActions: some View {
        if child.isLoadingMapCommandPreview {
            ProgressView().controlSize(.small)
        }
        if let preview = child.mapCommandPreview {
            if !preview.hasChange {
                Label(L10n.text("The source operation produced no changes, so there is nothing to apply."),
                    systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !preview.retainedFeatureIDs.isEmpty {
                Text(L10n.format("%d original lines retained", preview.retainedFeatureIDs.count))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Button(L10n.text("Apply Preview"), systemImage: "checkmark") {
                Task {
                    let succeeded = await child.applyMapCommandPreview()
                    if succeeded {
                        mapCommand = nil
                        mergePickedIDs = []
                        mapMessage = nil
                    } else if child.mapCommandError == nil {
                        mapMessage = "The culvert command was not applied. Reopen it against the current geometry draft to create a fresh preview."
                    }
                }
            }
            .disabled(!child.canApplyMapCommandPreview || commandPreviewIsStale || !preview.hasChange
                || !preview.canApply || child.isEditing || child.isLoadingMapCommandPreview)
        }
        if child.mapCommandPreview != nil {
            Button(L10n.text("Cancel Preview"), systemImage: "xmark") { cancelMapCommandPreviewOnly() }
                .disabled(child.isEditing)
        } else {
            Button(L10n.text("Cancel Command"), systemImage: "xmark") { cancelMapCommand() }
                .disabled(child.isEditing)
        }
    }

    private func changeTool(_ newTool: CulvertMapTool) {
        guard !isPreviewActive else { return }
        mapMessage = nil
        if (newTool == .draw || newTool == .reshape || newTool == .move) && !child.canEdit {
            mapMessage = "This geometry is read-only."
            tool = .select
            return
        }
        if newTool == .draw {
            guard canDraw else {
                mapMessage = "No associated terrain extent is available for drawing."
                tool = .select
                return
            }
            focusExtent = nil
            previewContext = currentPreviewContext
            child.setSketchActive(true)
        } else if newTool == .reshape {
            guard beginReshape() else {
                tool = .select
                return
            }
        }
        tool = newTool
    }

    @discardableResult
    private func beginReshape() -> Bool {
        guard let row = selectedRow, row.polyline.count >= 2 else {
            mapMessage = "Select one barrel line with at least two vertices to reshape."
            return false
        }
        reshapeID = row.id
        reshapePoints = row.polyline
        selectedVertexIndex = nil
        previewContext = currentPreviewContext
        child.setSketchActive(true)
        mapMessage = nil
        tool = .reshape
        return true
    }

    private func finishSketch() async {
        guard !isPreviewStale, child.canEdit, sketchPoints.count >= 2 else { return }
        let points = sketchPoints
        let createdID = await child.addBarrel(points: points)
        if createdID != nil {
            cancelPreview()
            tool = .select
            mapMessage = nil
        } else if child.error == nil {
            mapMessage = "The culvert line could not be added. The preview remains available."
        }
    }

    private func applyReshape() async {
        guard !isPreviewStale, child.canEdit, let reshapeID, reshapePoints.count >= 2 else { return }
        let succeeded = await child.setPolyline(id: reshapeID, points: reshapePoints)
        if succeeded {
            cancelPreview()
            tool = .select
            mapMessage = nil
        } else if child.error == nil {
            mapMessage = "The culvert line could not be reshaped. The preview remains available."
        }
    }

    private func cancelPreview() {
        sketchPoints = []
        reshapeID = nil
        reshapePoints = []
        selectedVertexIndex = nil
        previewContext = nil
        child.setSketchActive(false)
        if tool == .draw || tool == .reshape { tool = .select }
        mapMessage = nil
    }

    private func cancelMovePreview() {
        moveContext = nil
        moveIDs = []
        moveStart = nil
        moveDelta = nil
        moveHitID = nil
        draggingFeature = false
        child.setSketchActive(false)
        tool = .select
        mapMessage = nil
    }

    private func deleteSelectedVertex() {
        guard !isPreviewStale, let index = selectedVertexIndex,
              reshapePoints.indices.contains(index), reshapePoints.count > 2 else { return }
        reshapePoints.remove(at: index)
        selectedVertexIndex = nil
    }

    private func focusSelected() {
        let selectedLines = rows.filter { selectedIDs.contains($0.id) }.flatMap(\.polyline)
        guard !selectedLines.isEmpty else { return }
        focusExtent = extent(for: selectedLines)
        zoom = 1
        pan = .zero
        dragOffset = .zero
    }

    private func resetCamera() {
        zoom = 1
        pan = .zero
        dragOffset = .zero
        focusExtent = nil
        draggingMap = false
    }

    private func cancelMapPreview() {
        cancelPreview()
        cancelMovePreview()
        lassoRect = nil
        cancelMapCommand()
    }

    private func beginMapCommand(_ mode: CulvertMapCommandMode) {
        guard child.canEdit, !child.isEditing, !child.hasActiveSketch, !isPreviewActive else { return }
        child.cancelMapCommandPreview()
        commandGeneration += 1
        smartAddPreviewTask?.cancel()
        smartAddPreviewTask = nil
        hoveredMapPoint = nil
        smartAddPreviewTarget = nil
        smartAddPreviewWindow = nil
        smartAddPreviewLocation = nil
        mergePickedIDs = []
        mapMessage = nil
        if mode == .merge { mergeTolerance = 5 }
        if mode == .offset {
            offsetDistance = 10
            offsetSides = .both
            offsetIncludesEndpoints = false
            offsetKeepsOriginal = false
        }
        tool = .select
        mapCommand = mode
    }

    private func cancelMapCommand() {
        commandGeneration += 1
        smartAddPreviewTask?.cancel()
        smartAddPreviewTask = nil
        hoveredMapPoint = nil
        smartAddPreviewTarget = nil
        smartAddPreviewWindow = nil
        smartAddPreviewLocation = nil
        if mapCommand == .smartAdd { child.cancelSmartAddSketch() }
        child.cancelMapCommandPreview()
        mergePickedIDs = []
        mapCommand = nil
        mapMessage = nil
    }

    private func cancelMapCommandPreviewOnly() {
        commandGeneration += 1
        child.cancelMapCommandPreview()
        smartAddPreviewTask?.cancel()
        smartAddPreviewTask = nil
        smartAddPreviewTarget = nil
        smartAddPreviewWindow = nil
        smartAddPreviewLocation = nil
        mergePickedIDs = []
        mapMessage = nil
    }

    private func handleMapCommandClick(at location: CGPoint, size: CGSize) {
        guard !child.isEditing, child.canEdit, let coordinate = coordinate(at: location, in: size) else { return }
        switch mapCommand {
        case .split:
            guard child.mapCommandPreview == nil, !child.isLoadingMapCommandPreview else { return }
            guard let barrelID = hitTest(location, size: size),
                  let projection = projection(for: size),
                  projection.mapUnitsPerPixel.isFinite, projection.mapUnitsPerPixel > 0 else {
                mapMessage = "Click close to a barrel line to preview a split."
                return
            }
            let identity = child.geometryCulvertIdentity
            let context = currentPreviewContext
            let mode = splitMode
            let mapCellSize = projection.mapUnitsPerPixel
            commandGeneration += 1
            let generation = commandGeneration
            mapMessage = nil
            Task {
                await child.select([barrelID], featureKind: "barrel")
                guard generation == commandGeneration, child.geometryCulvertIdentity == identity,
                      currentPreviewContext == context else { return }
                let succeeded = await child.previewMapCommand(.split(barrelID: barrelID,
                    coordinate: coordinate, mode: mode, mapCellSize: mapCellSize))
                guard generation == commandGeneration, child.geometryCulvertIdentity == identity else { return }
                if !succeeded && child.mapCommandError == nil {
                    mapMessage = "A split preview could not be created for the clicked barrel."
                }
            }

        case .merge:
            guard child.mapCommandPreview == nil, !child.isLoadingMapCommandPreview,
                  mergePickedIDs.count < 2 else { return }
            guard let barrelID = hitTest(location, size: size) else {
                mapMessage = "Click a barrel line to select it for merging."
                return
            }
            guard mergeTolerance.isFinite, mergeTolerance >= 0 else {
                mapMessage = "Merge tolerance must be a finite non-negative map distance."
                return
            }
            if !mergePickedIDs.contains(barrelID) {
                mergePickedIDs.append(barrelID)
            }
            let picked = Array(mergePickedIDs.prefix(2))
            let tolerance = mergeTolerance
            let identity = child.geometryCulvertIdentity
            let context = currentPreviewContext
            guard picked.count == 2 else {
                return
            }
            commandGeneration += 1
            let generation = commandGeneration
            mapMessage = nil
            Task {
                await child.select(Set(picked), featureKind: "barrel")
                guard generation == commandGeneration, child.geometryCulvertIdentity == identity,
                      currentPreviewContext == context else { return }
                let succeeded = await child.previewMapCommand(.merge(barrelIDs: picked, tolerance: tolerance))
                guard generation == commandGeneration, child.geometryCulvertIdentity == identity else { return }
                if !succeeded && child.mapCommandError == nil {
                    mapMessage = "The selected barrel lines could not be merged."
                }
            }

        case .offset:
            guard child.mapCommandPreview == nil, !child.isLoadingMapCommandPreview else { return }
            guard let barrelID = hitTest(location, size: size) else {
                mapMessage = "Click a barrel line to preview an offset."
                return
            }
            guard offsetDistance.isFinite, offsetDistance > 0 else {
                mapMessage = "Offset distance must be a finite positive map distance."
                return
            }
            let identity = child.geometryCulvertIdentity
            let context = currentPreviewContext
            let distance = offsetDistance
            let sides = offsetSides
            let includeEndpoints = offsetIncludesEndpoints
            let keepOriginal = offsetKeepsOriginal
            commandGeneration += 1
            let generation = commandGeneration
            mapMessage = nil
            Task {
                await child.select([barrelID], featureKind: "barrel")
                guard generation == commandGeneration, child.geometryCulvertIdentity == identity,
                      currentPreviewContext == context else { return }
                let succeeded = await child.previewMapCommand(.offset(barrelID: barrelID,
                    distance: distance, sides: sides,
                    includeEndpoints: includeEndpoints, keepOriginal: keepOriginal))
                guard generation == commandGeneration, child.geometryCulvertIdentity == identity else { return }
                if !succeeded && child.mapCommandError == nil {
                    mapMessage = "An offset preview could not be created for the clicked barrel."
                }
            }

        case .smartAdd:
            guard let window = smartAddWindow(size: size) else {
                mapMessage = "The visible map window is unavailable for terrain sampling."
                return
            }
            if child.smartAddSketchPoints.isEmpty {
                child.beginSmartAddSketch(at: coordinate)
                hoveredMapPoint = nil
                smartAddPreviewTarget = nil
                smartAddPreviewWindow = nil
                smartAddPreviewLocation = nil
                mapMessage = nil
                return
            }
            guard let start = child.smartAddSketchPoints.last else { return }
            if smartAddPreviewTarget == coordinate, hoveredMapPoint == coordinate,
               smartAddPreviewWindow == window,
               child.smartAddPathPreview != nil,
               !child.isLoadingSmartAddPreview {
                if child.acceptSmartAddSegment() {
                    hoveredMapPoint = nil
                    smartAddPreviewTarget = nil
                    smartAddPreviewWindow = nil
                    smartAddPreviewLocation = nil
                    smartAddPreviewTask?.cancel()
                    smartAddPreviewTask = nil
                    commandGeneration += 1
                    mapMessage = nil
                    return
                }
                if child.smartAddError != nil { return }
            }
            smartAddPreviewTask?.cancel()
            smartAddPreviewTask = nil
            smartAddPreviewTarget = nil
            smartAddPreviewWindow = nil
            smartAddPreviewLocation = nil
            commandGeneration += 1
            let generation = commandGeneration
            let identity = child.geometryCulvertIdentity
            let context = currentPreviewContext
            mapMessage = nil
            smartAddPreviewTask = Task {
                let succeeded = await child.previewSmartAddSegment(from: start, to: coordinate, window: window)
                guard !Task.isCancelled, generation == commandGeneration,
                      mapCommand == .smartAdd, child.geometryCulvertIdentity == identity,
                      currentPreviewContext == context else { return }
                guard succeeded, child.acceptSmartAddSegment() else {
                    if child.smartAddError == nil { mapMessage = "The terrain path could not be appended; adjust the endpoint or cancel the sketch." }
                    smartAddPreviewTarget = nil
                    smartAddPreviewWindow = nil
                    smartAddPreviewLocation = nil
                    smartAddPreviewTask = nil
                    return
                }
                hoveredMapPoint = nil
                smartAddPreviewTarget = nil
                smartAddPreviewWindow = nil
                smartAddPreviewLocation = nil
                smartAddPreviewTask = nil
            }

        case nil:
            break
        }
    }

    private func handleSmartAddHover(at location: CGPoint, size: CGSize) {
        guard mapCommand == .smartAdd, child.canEdit, !child.isEditing,
              let start = child.smartAddSketchPoints.last,
              let end = coordinate(at: location, in: size),
              let window = smartAddWindow(size: size),
              start != end, end.x.isFinite, end.y.isFinite else { return }
        let throttle = max(0, child.smartAddOptions.previewThrottlePixels)
        if smartAddPreviewTarget != nil,
           smartAddPreviewWindow == window,
           smartAddPreviewLocation.map({ Double(hypot(location.x - $0.x, location.y - $0.y)) <= throttle }) == true,
           child.smartAddPathPreview != nil, !child.isLoadingSmartAddPreview {
            return
        }
        if hoveredMapPoint == end {
            if smartAddPreviewTarget == end && child.smartAddPathPreview != nil && !child.isLoadingSmartAddPreview { return }
            if child.isLoadingSmartAddPreview || smartAddPreviewTask != nil || child.smartAddError != nil { return }
        }
        hoveredMapPoint = end
        smartAddPreviewTarget = nil
        smartAddPreviewWindow = nil
        smartAddPreviewLocation = nil
        smartAddPreviewTask?.cancel()
        smartAddPreviewTask = nil
        commandGeneration += 1
        let generation = commandGeneration
        let identity = child.geometryCulvertIdentity
        let context = currentPreviewContext
        smartAddPreviewTask = Task {
            do { try await Task.sleep(nanoseconds: 80_000_000) } catch { return }
            guard !Task.isCancelled, generation == commandGeneration else { return }
            let succeeded = await child.previewSmartAddSegment(from: start, to: end, window: window)
            guard !Task.isCancelled, generation == commandGeneration, mapCommand == .smartAdd,
                  child.geometryCulvertIdentity == identity, currentPreviewContext == context else { return }
            smartAddPreviewTask = nil
            if succeeded, child.smartAddPathPreview != nil {
                smartAddPreviewTarget = end
                smartAddPreviewWindow = window
                smartAddPreviewLocation = location
            } else {
                smartAddPreviewTarget = nil
                smartAddPreviewWindow = nil
                smartAddPreviewLocation = nil
            }
        }
    }

    private func smartAddWindow(size: CGSize) -> GeometryCulvertSmartAddWindow? {
        guard let projection = projection(for: size), size.width >= 2, size.height >= 2 else { return nil }
        let visible = [CGPoint(x: 0, y: 0), CGPoint(x: size.width, y: 0),
                       CGPoint(x: size.width, y: size.height), CGPoint(x: 0, y: size.height)]
            .map(projection.unproject)
        guard visible.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
        let minX = visible.map(\.x).min()!, maxX = visible.map(\.x).max()!
        let minY = visible.map(\.y).min()!, maxY = visible.map(\.y).max()!
        guard maxX > minX, maxY > minY else { return nil }
        return GeometryCulvertSmartAddWindow(extent: GeometryCulvertExtent(minX: minX, minY: minY,
            maxX: maxX, maxY: maxY), rows: max(2, Int(size.height.rounded())),
            columns: max(2, Int(size.width.rounded())))
    }

    private func copySelected() {
        let selected = child.copiedBarrels(for: selectedIDs)
        guard !selected.isEmpty else {
            mapMessage = "No selected source barrel lines could be copied."
            return
        }
        mapMessage = GeometryCulvertClipboard.write(selected) ? nil : "The selected culvert data is too large to copy."
    }

    private func copyAll() {
        let all = child.copiedBarrels(for: Set(rows.map(\.id)))
        mapMessage = GeometryCulvertClipboard.write(all) ? nil : "The selected culvert data is too large to copy."
    }

    private func pasteFromClipboard() {
        guard child.canEdit, let features = GeometryCulvertClipboard.read() else {
            mapMessage = "The clipboard does not contain supported culvert barrel data."
            return
        }
        Task {
            let succeeded = await child.pasteBarrels(features)
            if succeeded { mapMessage = nil }
            else if child.error == nil { mapMessage = "The copied barrel lines could not be pasted into this geometry." }
        }
    }

    private func mapGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                guard !isPreviewStale, mapCommand == nil else { return }
                switch tool {
                case .select, .pan:
                    let distance = hypot(value.translation.width, value.translation.height)
                    guard distance > 5 else { return }
                    if !draggingMap {
                        panAtDragStart = pan
                        draggingMap = true
                    }
                    dragOffset = value.translation
                case .lasso:
                    lassoRect = CGRect(origin: value.startLocation, size: .zero)
                        .union(CGRect(origin: value.location, size: .zero))
                case .move:
                    guard child.canEdit, !child.isEditing else { return }
                    if !draggingFeature {
                        guard let id = hitTest(value.startLocation, size: size),
                              let start = coordinate(at: value.startLocation, in: size) else { return }
                        moveHitID = id
                        moveIDs = selectedIDs.contains(id) ? selectedIDs : [id]
                        moveStart = start
                        moveDelta = GeometryCulvertCoordinate(x: 0, y: 0)
                        moveContext = currentPreviewContext
                        draggingFeature = true
                        child.setSketchActive(true)
                    }
                    guard let start = moveStart,
                          let current = coordinate(at: value.location, in: size) else { return }
                    moveDelta = GeometryCulvertCoordinate(x: current.x - start.x, y: current.y - start.y)
                case .draw, .reshape:
                    break
                }
            }
            .onEnded { value in
                if mapCommand != nil {
                    guard !isPreviewStale else { return }
                    handleMapCommandClick(at: value.location, size: size)
                    return
                }
                if draggingMap {
                    pan = CGSize(width: panAtDragStart.width + value.translation.width,
                                 height: panAtDragStart.height + value.translation.height)
                    dragOffset = .zero
                    draggingMap = false
                    return
                }

                switch tool {
                case .select:
                    let id = hitTest(value.location, size: size)
                    let command = NSEvent.modifierFlags.contains(.command)
                    var ids = command ? selectedIDs : Set<String>()
                    if let id {
                        if command && ids.contains(id) { ids.remove(id) }
                        else { ids.insert(id) }
                    }
                    Task { await child.select(ids, featureKind: "barrel") }
                case .lasso:
                    let rect = CGRect(origin: value.startLocation, size: .zero)
                        .union(CGRect(origin: value.location, size: .zero)).insetBy(dx: -2, dy: -2)
                    lassoRect = nil
                    let hits = Set(rows.filter { lineIntersects(rect, points: $0.polyline, size: size) }.map(\.id))
                    var ids = NSEvent.modifierFlags.contains(.command) ? selectedIDs : Set<String>()
                    ids.formUnion(hits)
                    Task { await child.select(ids, featureKind: "barrel") }
                case .move:
                    let ids = moveIDs
                    let hitID = moveHitID
                    let delta = moveDelta
                    let moved = draggingFeature && !isPreviewStale && child.canEdit
                        && delta.map { $0.x.isFinite && $0.y.isFinite && ($0.x != 0 || $0.y != 0) } == true
                    if moved, let delta {
                        Task {
                            let succeeded = await child.moveBarrels(ids: ids, deltaX: delta.x, deltaY: delta.y)
                            child.setSketchActive(false)
                            clearMoveState()
                            if !succeeded && child.error == nil {
                                mapMessage = "The selected barrel lines could not be moved."
                            }
                        }
                    } else {
                        child.setSketchActive(false)
                        clearMoveState()
                        if let hitID { Task { await child.select([hitID], featureKind: "barrel") } }
                    }
                case .draw:
                    guard !isPreviewStale, let coordinate = coordinate(at: value.location, in: size) else { return }
                    sketchPoints.append(coordinate)
                case .reshape:
                    insertVertex(at: value.location, size: size)
                case .pan:
                    break
                }
            }
    }

    private func clearMoveState() {
        moveContext = nil
        moveIDs = []
        moveStart = nil
        moveDelta = nil
        moveHitID = nil
        draggingFeature = false
    }

    private func insertVertex(at location: CGPoint, size: CGSize) {
        guard !isPreviewStale, reshapeID != nil, reshapePoints.count >= 2,
              let projection = projection(for: size) else { return }
        var closest: (index: Int, distance: CGFloat, fraction: CGFloat)?
        for index in 0..<(reshapePoints.count - 1) {
            let start = projection.project(reshapePoints[index])
            let end = projection.project(reshapePoints[index + 1])
            let (distance, fraction) = pointDistanceAndFraction(location, segmentStart: start, end: end)
            if closest == nil || distance < closest!.distance { closest = (index, distance, fraction) }
        }
        guard let closest, closest.distance <= 10,
              let coordinate = coordinate(at: location, in: size) else { return }
        let insertIndex = closest.index + 1
        let start = reshapePoints[closest.index]
        let end = reshapePoints[closest.index + 1]
        let point = GeometryCulvertCoordinate(x: coordinate.x, y: coordinate.y,
            z: interpolate(start.z, end.z, fraction: closest.fraction),
            m: interpolate(start.m, end.m, fraction: closest.fraction))
        reshapePoints.insert(point, at: insertIndex)
        selectedVertexIndex = insertIndex
    }

    private func hitTest(_ location: CGPoint, size: CGSize) -> String? {
        guard let projection = projection(for: size) else { return nil }
        var nearest: (id: String, distance: CGFloat)?
        for row in rows {
            let points = row.polyline.map(projection.project)
            guard points.count >= 2 else { continue }
            for (start, end) in zip(points, points.dropFirst()) {
                let distance = pointDistance(location, segmentStart: start, end: end)
                if nearest == nil || distance < nearest!.distance { nearest = (row.id, distance) }
            }
        }
        return nearest.flatMap { $0.distance <= 9 ? $0.id : nil }
    }

    private func pointDistance(_ point: CGPoint, segmentStart start: CGPoint, end: CGPoint) -> CGFloat {
        pointDistanceAndFraction(point, segmentStart: start, end: end).0
    }

    private func pointDistanceAndFraction(_ point: CGPoint, segmentStart start: CGPoint,
                                          end: CGPoint) -> (CGFloat, CGFloat) {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let denominator = dx * dx + dy * dy
        guard denominator > 0 else { return (hypot(point.x - start.x, point.y - start.y), 0) }
        let fraction = min(1, max(0, ((point.x - start.x) * dx + (point.y - start.y) * dy) / denominator))
        return (hypot(point.x - (start.x + fraction * dx), point.y - (start.y + fraction * dy)), fraction)
    }

    private func projection(for size: CGSize) -> CulvertMapProjection? {
        CulvertMapProjection(extent: mapExtent, size: size, zoom: zoom,
            pan: CGSize(width: pan.width + dragOffset.width, height: pan.height + dragOffset.height))
    }

    private func coordinate(at location: CGPoint, in size: CGSize) -> GeometryCulvertCoordinate? {
        projection(for: size)?.unproject(location)
    }

    private func linePath(_ points: [GeometryCulvertCoordinate], projection: CulvertMapProjection) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: projection.project(first))
        for point in points.dropFirst() { path.addLine(to: projection.project(point)) }
        return path
    }

    private func drawVertices(_ points: [GeometryCulvertCoordinate], in context: inout GraphicsContext,
                              projection: CulvertMapProjection, color: Color) {
        for coordinate in points {
            let center = projection.project(coordinate)
            let marker = Path(ellipseIn: CGRect(x: center.x - 4.2, y: center.y - 4.2,
                                                width: 8.4, height: 8.4))
            context.fill(marker, with: .color(color))
            context.stroke(marker, with: .color(.white), lineWidth: 1)
        }
    }

    private func drawStyledVertices(_ points: [GeometryCulvertCoordinate], in context: inout GraphicsContext,
                                    projection: CulvertMapProjection, selected: Bool) {
        let pointSize = max(0, CGFloat(vertexStyle.pointSize))
        guard pointSize > 0 else { return }
        let fill = BoundaryARGBColor.decode(vertexStyle.fillColor) ?? .blue.opacity(0.5)
        let outline = BoundaryARGBColor.decode(vertexStyle.penColor) ?? .black
        let outlineWidth = max(0, CGFloat(vertexStyle.penWidth))
        for coordinate in points {
            let center = projection.project(coordinate)
            let marker = Path(ellipseIn: CGRect(x: center.x - pointSize / 2,
                y: center.y - pointSize / 2, width: pointSize, height: pointSize))
            if selected {
                let haloSize = pointSize + 4
                let halo = Path(ellipseIn: CGRect(x: center.x - haloSize / 2,
                    y: center.y - haloSize / 2, width: haloSize, height: haloSize))
                context.stroke(halo, with: .color(Color.accentColor.opacity(0.7)), lineWidth: 1.5)
            }
            context.fill(marker, with: .color(fill))
            context.stroke(marker, with: .color(outline), lineWidth: outlineWidth)
        }
    }

    private func extent(for coordinates: [GeometryCulvertCoordinate]) -> GeometryCulvertExtent? {
        let finite = coordinates.filter { $0.x.isFinite && $0.y.isFinite }
        guard let first = finite.first else { return nil }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for coordinate in finite.dropFirst() {
            minX = min(minX, coordinate.x); maxX = max(maxX, coordinate.x)
            minY = min(minY, coordinate.y); maxY = max(maxY, coordinate.y)
        }
        if maxX == minX { minX -= 0.5; maxX += 0.5 }
        if maxY == minY { minY -= 0.5; maxY += 0.5 }
        return GeometryCulvertExtent(minX: minX, minY: minY, maxX: maxX, maxY: maxY)
    }

    private func coordinateText(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(2...5)))
    }

    private func displayPoints(for row: GeometryCulvertFeatureRow) -> [GeometryCulvertCoordinate] {
        guard moveContext != nil, moveIDs.contains(row.id), let delta = moveDelta else { return row.polyline }
        return row.polyline.map { point in
            GeometryCulvertCoordinate(x: point.x + delta.x, y: point.y + delta.y, z: point.z, m: point.m)
        }
    }

    private func lineIntersects(_ rect: CGRect, points: [GeometryCulvertCoordinate], size: CGSize) -> Bool {
        guard let projection = projection(for: size), points.count >= 2 else { return false }
        let projected = points.map(projection.project)
        if projected.contains(where: rect.contains) { return true }
        let corners = [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                       CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)]
        let edges = Array(zip(corners, corners.dropFirst())) + [(corners[3], corners[0])]
        return zip(projected, projected.dropFirst()).contains { segment in
            edges.contains { segmentsIntersect(segment.0, segment.1, $0.0, $0.1) }
        }
    }

    private func segmentsIntersect(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ d: CGPoint) -> Bool {
        func orientation(_ p: CGPoint, _ q: CGPoint, _ r: CGPoint) -> CGFloat {
            (q.x - p.x) * (r.y - p.y) - (q.y - p.y) * (r.x - p.x)
        }
        func onSegment(_ p: CGPoint, _ q: CGPoint, _ r: CGPoint) -> Bool {
            q.x >= min(p.x, r.x) && q.x <= max(p.x, r.x)
                && q.y >= min(p.y, r.y) && q.y <= max(p.y, r.y)
        }
        let o1 = orientation(a, b, c), o2 = orientation(a, b, d)
        let o3 = orientation(c, d, a), o4 = orientation(c, d, b)
        if o1 == 0 && onSegment(a, c, b) { return true }
        if o2 == 0 && onSegment(a, d, b) { return true }
        if o3 == 0 && onSegment(c, a, d) { return true }
        if o4 == 0 && onSegment(c, b, d) { return true }
        return (o1 > 0) != (o2 > 0) && (o3 > 0) != (o4 > 0)
    }

    private func interpolate(_ first: String?, _ second: String?, fraction: CGFloat) -> String? {
        guard let first, let second else { return nil }
        if first == second { return first }
        guard let a = Double(first), let b = Double(second), a.isFinite, b.isFinite else {
            return fraction < 0.5 ? first : second
        }
        return String(a + Double(fraction) * (b - a))
    }

    private func union(_ lhs: GeometryCulvertExtent, _ rhs: GeometryCulvertExtent) -> GeometryCulvertExtent {
        GeometryCulvertExtent(minX: min(lhs.minX, rhs.minX), minY: min(lhs.minY, rhs.minY),
            maxX: max(lhs.maxX, rhs.maxX), maxY: max(lhs.maxY, rhs.maxY))
    }

    private func terrainImage(_ preview: GeometryCulvertTerrainPreview) -> CGImage? {
        guard preview.hasImage,
              let provider = CGDataProvider(data: preview.rgba as CFData) else { return nil }
        return CGImage(width: preview.width, height: preview.height, bitsPerComponent: 8,
            bitsPerPixel: 32, bytesPerRow: preview.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

private enum CulvertMapTool: String, CaseIterable, Identifiable {
    case select
    case lasso
    case pan
    case move
    case draw
    case reshape

    var id: String { rawValue }
    var title: String {
        switch self {
        case .select: "Select"
        case .lasso: "Lasso Select"
        case .pan: "Pan"
        case .move: "Move Barrels"
        case .draw: "Draw Line"
        case .reshape: "Reshape"
        }
    }
}

private enum CulvertMapCommandMode: String, Equatable {
    case split
    case merge
    case offset
    case smartAdd
}

private enum CulvertPolylineOperation: String, Identifiable {
    case filter
    case smooth

    var id: String { rawValue }

    @MainActor var title: String {
        switch self {
        case .filter: L10n.text("Filter Selected Line")
        case .smooth: L10n.text("Smooth Selected Line")
        }
    }
}

private struct CulvertPolylineOperationSheetState: Identifiable {
    let id = UUID()
    let barrelID: String
    let operation: CulvertPolylineOperation
    let geometryIdentity: String
    let sourceRevision: String
    let draftState: String
}

private struct GeometryCulvertPolylineOperationSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var child: GeometryCulvertSession
    let state: CulvertPolylineOperationSheetState

    @State private var tolerance = 1.0
    @State private var windowSize = 3
    @State private var passes = 2

    private var row: GeometryCulvertFeatureRow? {
        child.table(for: "barrel").rows.first { $0.id == state.barrelID }
    }

    private var hasZOrM: Bool {
        row?.polyline.contains { $0.z != nil || $0.m != nil } ?? false
    }

    private var operationContextIsCurrent: Bool {
        child.geometryCulvertIdentity == state.geometryIdentity
            && child.snapshot?.revision == state.sourceRevision
            && child.snapshot?.draftState == state.draftState
            && child.selectedFeatureIDs["barrel", default: []] == [state.barrelID]
            && row != nil
    }

    private var canApply: Bool {
        guard operationContextIsCurrent, child.canEdit, !child.hasActiveSketch, !hasZOrM else { return false }
        switch state.operation {
        case .filter: return tolerance.isFinite && tolerance > 0
        case .smooth: return windowSize >= 3 && passes >= 1
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(L10n.text("These operations replace only the selected barrel line in the geometry draft. Use Undo or Discard to restore it."))
                    Text(L10n.text("This change remains in the geometry draft until you save the model."))
                        .foregroundStyle(.secondary)
                }

                if state.operation == .filter {
                    Section(L10n.text("Filter Parameters")) {
                        TextField(L10n.text("Tolerance (map units)"), value: $tolerance,
                            format: .number.precision(.fractionLength(0...6)))
                            .textFieldStyle(.roundedBorder)
                        Text(L10n.text("Filter uses the source Douglas-Peucker algorithm."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Section(L10n.text("Smooth Parameters")) {
                        Stepper(value: $windowSize, in: 3...15, step: 2) {
                            LabeledContent(L10n.text("Window size"), value: String(windowSize))
                        }
                        Stepper(value: $passes, in: 1...12) {
                            LabeledContent(L10n.text("Passes"), value: String(passes))
                        }
                        Text(L10n.text("Smooth uses the source moving-average algorithm."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                if hasZOrM {
                    Section {
                        Label(L10n.text("Filter and Smooth create XY-only output; lines with Z or M values are disabled."),
                            systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                } else if !operationContextIsCurrent {
                    Section {
                        Label(L10n.text("The selected line or source changed while this operation was open. Reopen it for the current line."),
                            systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }

                if let error = child.error {
                    Section {
                        Label(L10n.text(error), systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle(state.operation.title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.text("Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.text(state.operation == .filter ? "Apply Filter" : "Apply Smoothing")) {
                        Task {
                            let succeeded: Bool
                            switch state.operation {
                            case .filter:
                                succeeded = await child.filterBarrel(id: state.barrelID, tolerance: tolerance)
                            case .smooth:
                                succeeded = await child.smoothBarrel(id: state.barrelID,
                                    windowSize: windowSize, passes: passes)
                            }
                            if succeeded { dismiss() }
                        }
                    }
                    .disabled(!canApply || child.isEditing)
                }
            }
        }
        .frame(minWidth: 420, minHeight: 310)
    }
}

@MainActor
enum GeometryCulvertClipboard {
    private static let pasteboardType = NSPasteboard.PasteboardType("com.hecras2025.geometry.culvert-barrels")
    private static let maximumPayloadBytes = 16 * 1024 * 1024
    private static let maximumFeatureCount = 10_000
    private static let maximumVertexCount = 1_000_000

    static var hasPayload: Bool {
        guard let data = NSPasteboard.general.data(forType: pasteboardType),
              data.count <= maximumPayloadBytes,
              let features = try? JSONDecoder().decode([GeometryCulvertCopiedBarrel].self, from: data) else { return false }
        return isBounded(features)
    }

    static func write(_ features: [GeometryCulvertCopiedBarrel]) -> Bool {
        guard !features.isEmpty, isBounded(features),
              let data = try? JSONEncoder().encode(features), data.count <= maximumPayloadBytes else { return false }
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setData(data, forType: pasteboardType)
    }

    static func read() -> [GeometryCulvertCopiedBarrel]? {
        guard let data = NSPasteboard.general.data(forType: pasteboardType),
              data.count <= maximumPayloadBytes,
              let features = try? JSONDecoder().decode([GeometryCulvertCopiedBarrel].self, from: data),
              isBounded(features) else { return nil }
        return features
    }

    private static func isBounded(_ features: [GeometryCulvertCopiedBarrel]) -> Bool {
        features.count <= maximumFeatureCount
            && features.allSatisfy { $0.polyline.count >= 2 }
            && features.reduce(0) { $0 + $1.polyline.count } <= maximumVertexCount
    }
}

private struct CulvertMapProjection {
    private let minX: Double
    private let minY: Double
    private let scale: CGFloat
    private let originX: CGFloat
    private let originY: CGFloat
    private let height: CGFloat

    var mapUnitsPerPixel: Double { Double(1.0 / scale) }

    init?(extent: GeometryCulvertExtent?, size: CGSize, zoom: Double, pan: CGSize) {
        guard let extent, size.width > 1, size.height > 1 else { return nil }
        var lowX = extent.minX, highX = extent.maxX
        var lowY = extent.minY, highY = extent.maxY
        guard [lowX, highX, lowY, highY].allSatisfy(\.isFinite) else { return nil }
        if highX <= lowX { lowX -= 0.5; highX += 0.5 }
        if highY <= lowY { lowY -= 0.5; highY += 0.5 }
        let spanX = CGFloat(highX - lowX)
        let spanY = CGFloat(highY - lowY)
        let fitScale = min(max(1, size.width - 32) / spanX, max(1, size.height - 32) / spanY)
        let scaled = fitScale * CGFloat(zoom)
        let contentWidth = spanX * scaled
        let contentHeight = spanY * scaled
        minX = lowX
        minY = lowY
        scale = scaled
        originX = (size.width - contentWidth) / 2 + pan.width
        originY = (size.height - contentHeight) / 2 - pan.height
        height = size.height
    }

    func project(_ coordinate: GeometryCulvertCoordinate) -> CGPoint {
        CGPoint(x: originX + CGFloat(coordinate.x - minX) * scale,
                y: height - originY - CGFloat(coordinate.y - minY) * scale)
    }

    func unproject(_ point: CGPoint) -> GeometryCulvertCoordinate {
        GeometryCulvertCoordinate(x: minX + Double((point.x - originX) / scale),
            y: minY + Double((height - originY - point.y) / scale))
    }
}
