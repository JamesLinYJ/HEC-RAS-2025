import SwiftUI
import RASWorkspaceCore

/// Native source-coordinate overlay for the saved conceptual topology, source
/// flow-area cell polygons, and the retained high-degree-node scan.
struct GeometryMeshMapWorkspaceView: View {
    @ObservedObject var session: GeometryMeshSession
    @ObservedObject var store: WorkspaceStore
    var navigate: ((String) -> Void)? = nil
    var selectTopologyFeatures: ((String, [String]) -> Void)? = nil
    var showDiagnostics: () -> Void = {}

    @State private var hiddenFlowAreaIDs: Set<String> = []
    @State private var showsRegions = true
    @State private var showsArcs = true
    @State private var showsArcVertices = false
    @State private var showsNodes = true
    @State private var showsMeshCells = true
    @State private var showsDegreeIssues = true

    private var map: GeometryMeshMapData { session.snapshot?.map ?? .empty }

    private var selectedTopologyFeature: GeometryTopologyMapFeature? {
        if let id = session.selectedMapTargetID,
           let feature = map.topology.features.first(where: { $0.id == id }) { return feature }
        guard !session.selectedRegionIDs.isEmpty else { return nil }
        return map.topology.features.first { feature in
            feature.featureKind == "region" && feature.selectionIDs.contains { value in
                guard value.hasPrefix("region:"), let fid = Int(value.dropFirst("region:".count)) else { return false }
                return session.selectedRegionIDs.contains(fid)
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Label(L10n.text("Geometry mesh map"), systemImage: "map")
                    .font(.headline)
                Spacer()
                Text(L10n.format("%@ source cells", map.totalCellCount.formatted()))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            HSplitView {
                layerList
                    .frame(minWidth: 210, idealWidth: 245, maxWidth: 285)
                GeometryMeshMapCanvas(map: map,
                    issues: session.degreeScan?.issues ?? [],
                    arcStyle: store.effectiveGeometryVectorStyle(definitionID: "Arc_Line_Symbology",
                        session: session, nodeType: "ConceptualMesh"),
                    internalPointStyle: store.effectiveGeometryVectorStyle(definitionID: "Internal_Point_Symbology",
                        session: session, nodeType: "ConceptualMesh"),
                    nodeStyle: store.effectiveGeometryVectorStyle(definitionID: "Node_Symbology",
                        session: session, nodeType: "ConceptualMesh"),
                    deletableNodeStyle: store.effectiveGeometryVectorStyle(definitionID: "Deletable_Node_Symbology",
                        session: session, nodeType: "ConceptualMesh"),
                    meshLineStyle: store.effectiveGeometryVectorStyle(definitionID: "Mesh_Line_Symbology",
                        session: session, nodeType: "FlowAreaLayer"),
                    visibleFlowAreaIDs: visibleFlowAreaIDs,
                    showsRegions: showsRegions, showsArcs: showsArcs, showsArcVertices: showsArcVertices,
                    showsNodes: showsNodes,
                    showsMeshCells: showsMeshCells, showsDegreeIssues: showsDegreeIssues,
                    selectedMapTargetID: session.selectedMapTargetID,
                    elementFind: session.meshElementFind,
                    selectedRegionIDs: session.selectedRegionIDs,
                    cameraIdentity: session.mapCameraIdentity,
                    selectTarget: selectTarget)
                    .frame(minWidth: 430, idealWidth: 700, maxWidth: .infinity, maxHeight: .infinity)
                selectionInspector
                    .frame(minWidth: 220, idealWidth: 270, maxWidth: 330, maxHeight: .infinity)
            }

            if map.omittedCellCount > 0 || map.invalidCandidateCount > 0 {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle").foregroundStyle(.secondary)
                    Text(L10n.format("Mesh map preview shows %@ of %@ cells; %@ omitted.",
                        map.renderedCellCount.formatted(), map.totalCellCount.formatted(), map.omittedCellCount.formatted()))
                    if map.invalidCandidateCount > 0 {
                        Text(L10n.format("%@ sampled cell polygons had invalid geometry or exceeded the preview limits.",
                            map.invalidCandidateCount.formatted()))
                    }
                    Spacer(minLength: 0)
                    Text(L10n.format("Preview limits: %@ cells and %@ vertices.",
                        map.cellLimit.formatted(), map.vertexLimit.formatted()))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.bar)
            }
        }
        .background(.background)
        .onChange(of: session.assetIdentity) { _, _ in hiddenFlowAreaIDs = [] }
    }

    private var layerList: some View {
        List {
            Section("Topology") {
                Toggle(L10n.text("Regions"), isOn: $showsRegions)
                Toggle(L10n.text("Arcs"), isOn: $showsArcs)
                Toggle(L10n.text("Show Arc Vertices"), isOn: $showsArcVertices)
                Toggle(L10n.text("Nodes"), isOn: $showsNodes)
            }
            Section("Mesh") {
                Toggle(L10n.text("Mesh cells"), isOn: $showsMeshCells)
                Toggle(L10n.text("Degree error nodes"), isOn: $showsDegreeIssues)
                ForEach(session.flowAreas) { row in
                    Toggle(isOn: Binding(
                        get: { !hiddenFlowAreaIDs.contains(row.id) },
                        set: { visible in
                            if visible { hiddenFlowAreaIDs.remove(row.id) }
                            else { hiddenFlowAreaIDs.insert(row.id) }
                        })) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.name.isEmpty ? L10n.format("Flow area %@", row.rowIndex.formatted()) : row.name)
                                    .lineLimit(1)
                                Text(L10n.format("%@ cells", row.cellCount.formatted()))
                                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                        .disabled(!row.hasMesh)
                }
            }
        }
        .listStyle(.sidebar)
    }

    private var visibleFlowAreaIDs: Set<String> {
        Set(session.flowAreas.map(\.id)).subtracting(hiddenFlowAreaIDs)
    }

    @ViewBuilder private var selectionInspector: some View {
        if let issue = session.degreeScan?.issues.first(where: { $0.id == session.selectedMapTargetID }) {
            Form {
                Section("Mesh error node") {
                    LabeledContent("Flow Area", value: issue.flowAreaName)
                    LabeledContent("Node", value: issue.nodeIndex.formatted())
                    LabeledContent("Connected faces", value: issue.faceCount.formatted())
                    if let x = issue.x, let y = issue.y, x.isFinite, y.isFinite {
                        LabeledContent("Source coordinates", value: "\(x.formatted()), \(y.formatted())")
                    }
                    if let extent = issue.cellsExtent {
                        LabeledContent("Affected cell extent", value: extentText(extent))
                    }
                    Button("Open Mesh Diagnostics", systemImage: "waveform.path.ecg") {
                        session.selectDegreeIssue(issue.id)
                        showDiagnostics()
                    }
                }
            }
            .formStyle(.grouped)
        } else if let find = session.meshElementFind, find.targetID == session.selectedMapTargetID {
            Form {
                Section(L10n.text("Source mesh element")) {
                    LabeledContent(L10n.text("Element type"), value: L10n.text(find.result.elementKind))
                    LabeledContent(L10n.text("Source index"), value: find.result.index.formatted())
                    LabeledContent(L10n.text("Flow Area"), value: find.result.flowAreaName)
                    LabeledContent(L10n.text("Flow Area ID"), value: find.result.flowAreaID).textSelection(.enabled)
                    LabeledContent(L10n.text("Source coordinates"),
                        value: "\(find.result.x.formatted()), \(find.result.y.formatted())")
                        .textSelection(.enabled)
                    Text(L10n.text("The highlighted shape and viewport come from the exact source mesh element, even when it is outside the sampled map preview."))
                        .font(.caption).foregroundStyle(.secondary)
                    Button(L10n.text("Clear found element"), systemImage: "xmark.circle") {
                        session.clearMeshElementFindTarget()
                    }
                }
            }
            .formStyle(.grouped)
        } else if let cell = map.cells.first(where: { $0.id == session.selectedMapTargetID }) {
            Form {
                Section("Source mesh cell") {
                    LabeledContent("Flow Area", value: cell.flowAreaName)
                    LabeledContent("Cell index", value: cell.cellIndex.formatted())
                    LabeledContent("Flow-area row", value: cell.meshIndex.formatted())
                    Text(L10n.text("Cell index is the source mesh-local ordinal; it is not an HDF feature ID."))
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Show Flow Area", systemImage: "square.grid.3x3") {
                        session.selectFlowArea(cell.flowAreaID)
                    }
                }
            }
            .formStyle(.grouped)
        } else if let feature = selectedTopologyFeature {
            Form {
                Section(L10n.text(featureTitle(feature))) {
                    if let fid = feature.fid {
                        LabeledContent("Source FID", value: fid.formatted()).textSelection(.enabled)
                    }
                    LabeledContent("Geometry", value: L10n.text(feature.geometryType))
                    LabeledContent("Selection links", value: feature.selectionIDs.joined(separator: ", "))
                        .textSelection(.enabled)
                    if feature.featureKind == "arc" {
                        Button("Open Arcs", systemImage: "point.topleft.down.curvedto.point.bottomright.up") {
                            navigate?("Arcs")
                        }
                    } else if feature.featureKind == "node" {
                        Button("Open Nodes", systemImage: "point.3.connected.trianglepath.dotted") {
                            navigate?("Nodes")
                        }
                    } else if feature.featureKind == "region" {
                        Button("Open Regions", systemImage: "point.3.filled.connected.trianglepath.dotted") {
                            navigate?("Topology")
                        }
                    }
                }
            }
            .formStyle(.grouped)
        } else {
            ContentUnavailableView("Select a map feature", systemImage: "cursorarrow.click",
                description: Text("Choose a source mesh cell, topology feature, or scanned error node."))
        }
    }

    private func selectTarget(_ target: GeometryMeshMapHit?) {
        guard let target else {
            session.selectMapTarget(nil)
            return
        }
        switch target {
        case .cell(let cell):
            session.selectFlowArea(cell.flowAreaID)
            session.selectMapTarget(cell.id)
        case .issue(let issue):
            session.selectFlowArea(issue.flowAreaID)
            session.selectDegreeIssue(issue.id)
        case .topology(let feature):
            session.selectMapTarget(feature.id)
            let linkedIDs = feature.selectionIDs.filter { $0.hasPrefix(feature.featureKind + ":") }
            if !linkedIDs.isEmpty { selectTopologyFeatures?(feature.featureKind, linkedIDs) }
            let fids = feature.selectionIDs.compactMap { value -> Int? in
                guard let separator = value.firstIndex(of: ":"), value[..<separator] == "region" else { return nil }
                return Int(value[value.index(after: separator)...])
            }
            if !fids.isEmpty { Task { await session.selectRegions(Set(fids)) } }
        }
    }

    private func featureTitle(_ feature: GeometryTopologyMapFeature) -> String {
        switch feature.featureKind {
        case "arc": "Topology arc"
        case "region": "Topology region"
        case "node": "Topology node"
        default: "Topology feature"
        }
    }

    private func extentText(_ extent: GeometryMeshExtent) -> String {
        "X \(extent.minX.formatted()) … \(extent.maxX.formatted()), Y \(extent.minY.formatted()) … \(extent.maxY.formatted())"
    }
}

private enum GeometryMeshMapHit {
    case cell(GeometryMeshMapCell)
    case issue(GeometryMeshDegreeIssue)
    case topology(GeometryTopologyMapFeature)
}

private struct GeometryMeshMapCanvas: View {
    @ObservedObject private var renderScaling = WorkspaceRenderScaling.shared
    let map: GeometryMeshMapData
    let issues: [GeometryMeshDegreeIssue]
    let arcStyle: VectorStyleValues
    let internalPointStyle: VectorStyleValues
    let nodeStyle: VectorStyleValues
    let deletableNodeStyle: VectorStyleValues
    let meshLineStyle: VectorStyleValues
    let visibleFlowAreaIDs: Set<String>
    let showsRegions: Bool
    let showsArcs: Bool
    let showsArcVertices: Bool
    let showsNodes: Bool
    let showsMeshCells: Bool
    let showsDegreeIssues: Bool
    let selectedMapTargetID: String?
    let elementFind: GeometryMeshElementFindPresentation?
    let selectedRegionIDs: Set<Int>
    let cameraIdentity: String
    let selectTarget: (GeometryMeshMapHit?) -> Void

    @State private var zoom = 1.0
    @State private var pan = CGSize.zero
    @State private var dragOffset = CGSize.zero
    @State private var panAtDragStart = CGSize.zero
    @State private var draggingMap = false
    @State private var didFitExtent = false
    @State private var zoomAtMagnifyStart = 1.0
    @State private var focusedFindIdentity: String?

    private var cameraExtent: GeometryTopologyExtent? {
        guard focusedFindIdentity == elementFind?.identity,
              let viewport = elementFind?.result.viewport else { return map.extent }
        return GeometryTopologyExtent(minX: viewport.minX, minY: viewport.minY,
            maxX: viewport.maxX, maxY: viewport.maxY)
    }

    private var currentPan: CGSize {
        CGSize(width: pan.width + dragOffset.width, height: pan.height + dragOffset.height)
    }

    private var visibleFeatures: [GeometryTopologyMapFeature] {
        map.topology.features.filter { feature in
            switch feature.featureKind {
            case "region": showsRegions
            case "arc": showsArcs
            case "node": showsNodes
            default: false
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button { zoom = max(0.55, zoom / 1.25) } label: { Image(systemName: "minus.magnifyingglass") }
                    .help(L10n.text("Zoom out")).disabled(zoom <= 0.55)
                Button { zoom = min(6, zoom * 1.25) } label: { Image(systemName: "plus.magnifyingglass") }
                    .help(L10n.text("Zoom in")).disabled(zoom >= 6)
                Button { fitFullExtent() } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                    .help(L10n.text("Fit extent"))
                Button { locateSelection(size: currentCanvasSize) } label: { Image(systemName: "scope") }
                    .help(L10n.text("Locate selection"))
                    .disabled(selectedMapTargetID == nil && selectedRegionIDs.isEmpty)
                Spacer()
                Text(L10n.text("Drag to pan; click to select."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .padding(.horizontal, 8)
            .padding(.vertical, 7)

            GeometryReader { geometry in
                let renderScale = renderScaling.factor
                Canvas { context, size in
                    guard let projection = GeometryMeshMapProjection(extent: cameraExtent, size: size,
                        zoom: zoom, pan: currentPan) else { return }
                    drawCells(in: &context, projection: projection, renderScale: renderScale)
                    drawTopology(in: &context, projection: projection, renderScale: renderScale)
                    drawIssues(in: &context, projection: projection, renderScale: renderScale)
                    drawFoundElement(in: &context, projection: projection, renderScale: renderScale)
                }
                .background(Color(nsColor: .textBackgroundColor).opacity(0.55))
                .overlay {
                    if cameraExtent == nil || (map.cells.isEmpty && map.topology.features.isEmpty
                        && elementFind == nil) {
                        ContentUnavailableView("No source mesh or topology coordinates are available.",
                            systemImage: "map", description: Text("The map only draws coordinates supplied by this geometry source."))
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
                            selectTarget(hit(at: value.location, canvasSize: geometry.size))
                        }
                    })
                .simultaneousGesture(MagnificationGesture()
                    .onChanged { value in
                        if zoomAtMagnifyStart == zoom { zoomAtMagnifyStart = zoom }
                        zoom = min(6, max(0.55, zoomAtMagnifyStart * value))
                    }
                    .onEnded { _ in zoomAtMagnifyStart = zoom })
                .onChange(of: map.extent) { _, _ in
                    fitIfNeeded()
                    locateSelection(size: geometry.size)
                }
                .onChange(of: elementFind?.identity) { _, identity in
                    focusedFindIdentity = identity
                    didFitExtent = false
                    fit()
                    locateSelection(size: geometry.size)
                }
                .onChange(of: cameraIdentity) { _, _ in
                    didFitExtent = false
                    fit()
                    locateSelection(size: geometry.size)
                }
                .onChange(of: selectedMapTargetID) { _, _ in locateSelection(size: geometry.size) }
                .onChange(of: selectedRegionIDs) { _, _ in locateSelection(size: geometry.size) }
                .onAppear {
                    currentCanvasSize = geometry.size
                    focusedFindIdentity = elementFind?.identity
                    fitIfNeeded()
                    locateSelection(size: geometry.size)
                }
                .onChange(of: geometry.size) { _, newSize in currentCanvasSize = newSize; fitIfNeeded() }
            }
            .frame(minHeight: 260, idealHeight: 430)

            extentFooter
        }
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(.quaternary, lineWidth: 1)
        }
    }

    @State private var currentCanvasSize = CGSize.zero

    private var extentFooter: some View {
        HStack(spacing: 8) {
            Label(L10n.text("Source extent"), systemImage: "arrow.up.left.and.arrow.down.right")
                .foregroundStyle(.secondary)
            if let extent = map.extent {
                Text("X  \(coord(extent.minX)) … \(coord(extent.maxX))")
                Text("Y  \(coord(extent.minY)) … \(coord(extent.maxY))")
            } else {
                Text(L10n.text("Extent unavailable")).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .font(.caption.monospacedDigit())
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
    }

    private func coord(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(2...5))) }

    private func fitIfNeeded() {
        guard !didFitExtent, cameraExtent != nil, currentCanvasSize.width > 1, currentCanvasSize.height > 1 else { return }
        fit()
        didFitExtent = true
    }

    private func fitFullExtent() {
        focusedFindIdentity = nil
        fit()
    }

    private func fit() {
        zoom = 1
        pan = .zero
        dragOffset = .zero
        draggingMap = false
        didFitExtent = cameraExtent != nil
    }

    private func locateSelection(size: CGSize) {
        guard size.width > 1, size.height > 1,
              let coordinate = selectedCoordinate(),
              let projection = GeometryMeshMapProjection(extent: cameraExtent, size: size,
                  zoom: zoom, pan: currentPan) else { return }
        let point = projection.project(coordinate)
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        pan.width += center.x - point.x
        pan.height += center.y - point.y
        dragOffset = .zero
        zoom = max(1.35, zoom)
    }

    private func selectedCoordinate() -> GeometryTopologyCoordinate? {
        if let elementFind, selectedMapTargetID == elementFind.targetID {
            return .init(x: elementFind.result.x, y: elementFind.result.y)
        }
        if let issue = issues.first(where: { $0.id == selectedMapTargetID }) {
            if let x = issue.x, let y = issue.y, x.isFinite, y.isFinite { return .init(x: x, y: y) }
            if let extent = issue.cellsExtent {
                guard [extent.minX, extent.minY, extent.maxX, extent.maxY].allSatisfy(\.isFinite),
                      extent.minX <= extent.maxX, extent.minY <= extent.maxY else { return nil }
                return .init(x: extent.minX / 2 + extent.maxX / 2,
                             y: extent.minY / 2 + extent.maxY / 2)
            }
        }
        if let cell = map.cells.first(where: { $0.id == selectedMapTargetID }) {
            return midpoint(cell.coordinates)
        }
        if let feature = map.topology.features.first(where: { $0.id == selectedMapTargetID }) {
            if let point = feature.paths.first?.first { return point }
            return midpoint(feature.paths.flatMap { $0 })
        }
        if !selectedRegionIDs.isEmpty,
           let feature = map.topology.features.first(where: { feature in
               feature.featureKind == "region" && feature.selectionIDs.contains { value in
                   guard value.hasPrefix("region:"), let fid = Int(value.dropFirst("region:".count)) else { return false }
                   return selectedRegionIDs.contains(fid)
               }
           }) {
            if let point = feature.paths.first?.first { return point }
            return midpoint(feature.paths.flatMap { $0 })
        }
        return nil
    }

    private func midpoint(_ points: [GeometryTopologyCoordinate]) -> GeometryTopologyCoordinate? {
        let finite = points.filter { $0.x.isFinite && $0.y.isFinite }
        guard !finite.isEmpty else { return nil }
        let minX = finite.map(\.x).min()!, maxX = finite.map(\.x).max()!
        let minY = finite.map(\.y).min()!, maxY = finite.map(\.y).max()!
        return .init(x: minX / 2 + maxX / 2, y: minY / 2 + maxY / 2)
    }

    private func drawCells(in context: inout GraphicsContext, projection: GeometryMeshMapProjection,
                           renderScale: Double) {
        guard showsMeshCells else { return }
        let palette: [Color] = [.teal, .blue, .purple, .orange, .green, .pink]
        for cell in map.cells where visibleFlowAreaIDs.contains(cell.flowAreaID) {
            let path = polygonPath(cell.coordinates, projection: projection)
            guard !path.isEmpty else { continue }
            let selected = cell.id == selectedMapTargetID
            let color = palette[abs(cell.meshIndex) % palette.count]
            let stroke = GeometryMapStylePresentation.meshCell(meshLineStyle, selected: selected,
                                                               renderScale: renderScale)
            context.fill(path, with: .color(color.opacity(selected ? 0.18 : 0.025)), style: FillStyle(eoFill: true, antialiased: true))
            context.stroke(path, with: .color(GeometryMapStylePresentation.color(for: stroke.ink)),
                style: StrokeStyle(lineWidth: CGFloat(stroke.width), lineJoin: .round))
        }
    }

    private func drawTopology(in context: inout GraphicsContext, projection: GeometryMeshMapProjection,
                              renderScale: Double) {
        for feature in visibleFeatures where feature.geometryType == "polygon" {
            let path = multiPath(feature.paths, projection: projection, close: true)
            guard !path.isEmpty else { continue }
            let selected = isSelected(feature)
            context.fill(path, with: .color(selected ? Color.accentColor.opacity(0.22) : Color.indigo.opacity(0.08)),
                style: FillStyle(eoFill: true, antialiased: true))
            context.stroke(path, with: .color(selected ? .accentColor : .indigo.opacity(0.78)),
                style: StrokeStyle(lineWidth: WorkspaceRenderScaling.metric(selected ? 2.4 : 1.15,
                                                                             factor: renderScale),
                                   lineJoin: .round))
        }
        for feature in visibleFeatures where feature.geometryType == "line" {
            let path = multiPath(feature.paths, projection: projection, close: false)
            guard !path.isEmpty else { continue }
            let appearance = GeometryMapStylePresentation.topologyArc(arcStyle, selected: isSelected(feature),
                                                                      renderScale: renderScale)
            context.stroke(path, with: .color(GeometryMapStylePresentation.color(for: appearance.ink)),
                style: StrokeStyle(lineWidth: CGFloat(appearance.width), lineCap: .round, lineJoin: .round))
        }
        if showsArcVertices { drawArcVertices(in: &context, projection: projection, renderScale: renderScale) }
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
                radius = WorkspaceRenderScaling.metric(selected ? 6 : 3.8, factor: renderScale)
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

    private func drawArcVertices(in context: inout GraphicsContext, projection: GeometryMeshMapProjection,
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

    private func drawIssues(in context: inout GraphicsContext, projection: GeometryMeshMapProjection,
                            renderScale: Double) {
        guard showsDegreeIssues else { return }
        for issue in issues where visibleFlowAreaIDs.contains(issue.flowAreaID) {
            let selected = issue.id == selectedMapTargetID
            if let x = issue.x, let y = issue.y, x.isFinite, y.isFinite {
                let center = projection.project(.init(x: x, y: y))
                let radius = WorkspaceRenderScaling.metric(selected ? 7 : 4.7, factor: renderScale)
                let marker = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius,
                    width: radius * 2, height: radius * 2))
                context.fill(marker, with: .color(.red))
                context.stroke(marker, with: .color(.white),
                    lineWidth: WorkspaceRenderScaling.metric(selected ? 1.8 : 1, factor: renderScale))
            } else if let extent = issue.cellsExtent, let path = issueExtentPath(extent, projection: projection) {
                context.stroke(path, with: .color(.red),
                    style: StrokeStyle(lineWidth: WorkspaceRenderScaling.metric(selected ? 2.8 : 1.8,
                                                                                 factor: renderScale),
                                       dash: [5, 3]))
            }
        }
    }

    private func drawFoundElement(in context: inout GraphicsContext,
                                  projection: GeometryMeshMapProjection,
                                  renderScale: Double) {
        guard let elementFind, selectedMapTargetID == elementFind.targetID else { return }
        let coordinates = elementFind.result.coordinates
        switch elementFind.result.elementKind {
        case GeometryMeshElementKind.cell.rawValue:
            let path = GeometryMeshMapPath.make(paths: [coordinates], projection: projection, close: true)
            guard !path.isEmpty else { return }
            context.fill(path, with: .color(Color.accentColor.opacity(0.3)),
                style: FillStyle(eoFill: true, antialiased: true))
            context.stroke(path, with: .color(.white),
                style: StrokeStyle(lineWidth: WorkspaceRenderScaling.metric(5, factor: renderScale),
                    lineJoin: .round))
            context.stroke(path, with: .color(.accentColor),
                style: StrokeStyle(lineWidth: WorkspaceRenderScaling.metric(3, factor: renderScale),
                    lineJoin: .round))
        case GeometryMeshElementKind.face.rawValue:
            let path = GeometryMeshMapPath.make(paths: [coordinates], projection: projection, close: false)
            guard !path.isEmpty else { return }
            context.stroke(path, with: .color(.white),
                style: StrokeStyle(lineWidth: WorkspaceRenderScaling.metric(8, factor: renderScale),
                    lineCap: .round, lineJoin: .round))
            context.stroke(path, with: .color(.accentColor),
                style: StrokeStyle(lineWidth: WorkspaceRenderScaling.metric(5, factor: renderScale),
                    lineCap: .round, lineJoin: .round))
        case GeometryMeshElementKind.node.rawValue:
            guard let coordinate = coordinates.first else { return }
            let center = projection.project(coordinate)
            let radius = WorkspaceRenderScaling.metric(7, factor: renderScale)
            let marker = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius,
                width: radius * 2, height: radius * 2))
            context.fill(marker, with: .color(.accentColor))
            context.stroke(marker, with: .color(.white),
                lineWidth: WorkspaceRenderScaling.metric(2, factor: renderScale))
        default:
            return
        }
    }

    private func hit(at location: CGPoint, canvasSize: CGSize) -> GeometryMeshMapHit? {
        let hitTolerance = max(WorkspaceRenderScaling.metric(10, factor: renderScaling.factor), 10)
        let lineTolerance = max(WorkspaceRenderScaling.metric(7, factor: renderScaling.factor), 7)
        let issueOutlineTolerance = max(WorkspaceRenderScaling.metric(8, factor: renderScaling.factor), 8)
        guard let projection = GeometryMeshMapProjection(extent: cameraExtent, size: canvasSize,
            zoom: zoom, pan: currentPan) else { return nil }

        if showsDegreeIssues {
            for issue in issues.reversed() where visibleFlowAreaIDs.contains(issue.flowAreaID) {
                if let x = issue.x, let y = issue.y, x.isFinite, y.isFinite {
                    let point = projection.project(.init(x: x, y: y))
                    if hypot(point.x - location.x, point.y - location.y) <= hitTolerance { return .issue(issue) }
                } else if let extent = issue.cellsExtent, let path = issueExtentPath(extent, projection: projection) {
                    if path.contains(location, eoFill: true) { return .issue(issue) }
                    let points = extentCorners(extent).map(projection.project)
                    let closedPoints = Array(points.dropFirst()) + [points[0]]
                    if zip(points, closedPoints).contains(where: {
                        distance(location, toSegmentFrom: $0.0, to: $0.1) <= issueOutlineTolerance
                    }) { return .issue(issue) }
                }
            }
        }
        for feature in visibleFeatures.reversed() where feature.geometryType == "point" {
            guard let coordinate = feature.paths.first?.first else { continue }
            let point = projection.project(coordinate)
            if hypot(point.x - location.x, point.y - location.y) <= hitTolerance { return .topology(feature) }
        }
        for feature in visibleFeatures.reversed() where feature.geometryType == "line" {
            for path in feature.paths {
                let points = path.map(projection.project)
                for (start, end) in zip(points, points.dropFirst()) where distance(location, toSegmentFrom: start, to: end) <= lineTolerance {
                    return .topology(feature)
                }
            }
        }
        if showsMeshCells {
            for cell in map.cells.reversed() where visibleFlowAreaIDs.contains(cell.flowAreaID) {
                if polygonPath(cell.coordinates, projection: projection).contains(location, eoFill: true) {
                    return .cell(cell)
                }
            }
        }
        for feature in visibleFeatures.reversed() where feature.geometryType == "polygon" {
            let path = multiPath(feature.paths, projection: projection, close: true)
            if path.contains(location, eoFill: true) { return .topology(feature) }
        }
        return nil
    }

    private func issueExtentPath(_ extent: GeometryMeshExtent,
                                 projection: GeometryMeshMapProjection) -> Path? {
        guard [extent.minX, extent.minY, extent.maxX, extent.maxY].allSatisfy(\.isFinite),
              extent.minX <= extent.maxX, extent.minY <= extent.maxY else { return nil }
        return GeometryMeshMapPath.make(paths: [extentCorners(extent)], projection: projection, close: true)
    }

    private func extentCorners(_ extent: GeometryMeshExtent) -> [GeometryTopologyCoordinate] {
        [
            .init(x: extent.minX, y: extent.minY), .init(x: extent.maxX, y: extent.minY),
            .init(x: extent.maxX, y: extent.maxY), .init(x: extent.minX, y: extent.maxY)
        ]
    }

    private func isSelected(_ feature: GeometryTopologyMapFeature) -> Bool {
        if feature.id == selectedMapTargetID { return true }
        guard feature.featureKind == "region" else { return false }
        return feature.selectionIDs.contains { value in
            guard value.hasPrefix("region:"), let fid = Int(value.dropFirst("region:".count)) else { return false }
            return selectedRegionIDs.contains(fid)
        }
    }

    private func polygonPath(_ coordinates: [GeometryTopologyCoordinate], projection: GeometryMeshMapProjection) -> Path {
        multiPath([coordinates], projection: projection, close: true)
    }

    private func multiPath(_ paths: [[GeometryTopologyCoordinate]], projection: GeometryMeshMapProjection,
                           close: Bool) -> Path {
        GeometryMeshMapPath.make(paths: paths, projection: projection, close: close)
    }

    private func distance(_ point: CGPoint, toSegmentFrom start: CGPoint, to end: CGPoint) -> CGFloat {
        let dx = end.x - start.x, dy = end.y - start.y
        let denominator = dx * dx + dy * dy
        guard denominator > 0 else { return hypot(point.x - start.x, point.y - start.y) }
        let fraction = min(1, max(0, ((point.x - start.x) * dx + (point.y - start.y) * dy) / denominator))
        return hypot(point.x - (start.x + fraction * dx), point.y - (start.y + fraction * dy))
    }
}

/// Aspect-preserving projection for source map coordinates. Keeping camera
/// state in the Canvas means source label/metadata refreshes don't reset view.
struct GeometryMeshMapProjection {
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
        guard let extent, size.width > 1, size.height > 1,
              [extent.minX, extent.minY, extent.maxX, extent.maxY, zoom].allSatisfy(\.isFinite), zoom > 0,
              extent.minX <= extent.maxX, extent.minY <= extent.maxY else { return nil }
        var lowX = extent.minX, highX = extent.maxX
        var lowY = extent.minY, highY = extent.maxY
        if highX <= lowX { lowX -= 0.5; highX += 0.5 }
        if highY <= lowY { lowY -= 0.5; highY += 0.5 }
        let spanX = highX - lowX, spanY = highY - lowY
        guard spanX.isFinite, spanY.isFinite, spanX > 0, spanY > 0 else { return nil }
        let fitScale = min(max(1, size.width - 32) / spanX, max(1, size.height - 32) / spanY)
        let scaled = fitScale * CGFloat(zoom)
        guard fitScale.isFinite, scaled.isFinite, scaled > 0 else { return nil }
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

    func coordinate(at point: CGPoint) -> GeometryTopologyCoordinate? {
        guard scale > 0, scale.isFinite else { return nil }
        let x = minX + Double((point.x - originX) / scale)
        let y = minY + Double((height - originY - point.y) / scale)
        guard x.isFinite, y.isFinite else { return nil }
        return GeometryTopologyCoordinate(x: x, y: y)
    }
}

enum GeometryMeshMapPath {
    static func make(paths: [[GeometryTopologyCoordinate]], projection: GeometryMeshMapProjection,
                     close: Bool) -> Path {
        var result = Path()
        for coordinates in paths where !coordinates.isEmpty {
            let points = coordinates.map(projection.project)
            guard let first = points.first else { continue }
            result.move(to: first)
            for point in points.dropFirst() { result.addLine(to: point) }
            if close { result.closeSubpath() }
        }
        return result
    }
}

extension GeometryMeshMapData {
    static let empty = GeometryMeshMapData(extent: nil, topology: .empty, cells: [],
        totalCellCount: 0, renderedCellCount: 0, omittedCellCount: 0,
        invalidCandidateCount: 0, cellLimit: 0, vertexLimit: 0)
}
