import Foundation
import RASWorkspaceCore
import SwiftUI

/// Reads source FlowArea mesh cells and topology for the selected Geometry.
/// The service receives no project XML draft and never consults the active map.
@MainActor
struct CatalogGeometryMeshPreviewView: View {
    let asset: ProjectAsset
    let projectURL: URL?
    let requestIdentity: String
    let client: BackendProcessClient
    @StateObject private var session = CatalogGeometryMeshPreviewSession()
    @State private var refreshRevision = UUID()

    private var previewIdentity: String {
        [requestIdentity, refreshRevision.uuidString].joined(separator: "\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L10n.text("Geometry Mesh Preview")).font(.subheadline.weight(.medium))
                Spacer()
                Button {
                    refreshRevision = UUID()
                } label: {
                    Label(L10n.text("Refresh"), systemImage: "arrow.clockwise")
                }
                .disabled(session.isLoading || projectURL == nil)
            }
            if session.isLoading {
                ProgressView(L10n.text("Loading source geometry…")).controlSize(.small)
            } else if let map = session.map {
                CatalogGeometryMeshMapPreview(map: map, flowAreas: session.flowAreas)
                    .id(previewIdentity)
                    .frame(minHeight: 300, idealHeight: 390)
                if map.omittedCellCount > 0 {
                    Text(L10n.format("Mesh map preview shows %@ of %@ cells; %@ omitted.",
                        map.renderedCellCount.formatted(), map.totalCellCount.formatted(),
                        map.omittedCellCount.formatted()))
                        .font(.caption).foregroundStyle(.secondary)
                } else if map.renderedCellCount > 0 {
                    Text(L10n.format("%@ source cells", map.renderedCellCount.formatted()))
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else if let error = session.error {
                CatalogSummaryUnavailableNotice(title: "Geometry preview unavailable", detail: error)
            } else {
                CatalogSummaryUnavailableNotice(title: "Geometry preview unavailable",
                    detail: "The selected geometry has no renderable source FlowArea mesh or topology.")
            }
        }
        .task(id: previewIdentity) {
            guard let projectURL else {
                session.invalidate()
                return
            }
            await session.load(asset: asset, projectURL: projectURL,
                requestIdentity: previewIdentity, provider: BackendGeometryMeshProvider(client: client))
        }
        .onDisappear { session.invalidate() }
    }
}

@MainActor
final class CatalogGeometryMeshPreviewSession: ObservableObject {
    @Published private(set) var map: GeometryMeshMapData?
    @Published private(set) var flowAreas: [GeometryMeshFlowAreaRow] = []
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?

    private var generation = 0
    private var currentRequestIdentity: String?

    func load(asset: ProjectAsset, projectURL: URL,
              requestIdentity: String, provider: any GeometryMeshProvider) async {
        generation &+= 1
        let request = generation
        currentRequestIdentity = requestIdentity
        map = nil
        flowAreas = []
        error = nil
        isLoading = true
        defer { if generation == request { isLoading = false } }

        do {
            let expectedRevision = try await CatalogPreviewFileRevision.sha256(asset.url)
            let projectRevision = try await CatalogPreviewFileRevision.sha256(projectURL)
            let model = GeometryMeshModelRequest(assetPath: asset.url.path, kind: "Geometry",
                projectPath: projectURL.path, projectXml: nil)
            let snapshot = try await provider.load(model, expectedRevision: expectedRevision,
                draftState: nil, topologyDraftState: nil, selectedRegionIDs: [])
            guard snapshot.revision == expectedRevision,
                  try await CatalogPreviewFileRevision.sha256(asset.url) == expectedRevision,
                  try await CatalogPreviewFileRevision.sha256(projectURL) == projectRevision else {
                throw BackendServiceError(code: "sourceChanged", message: "The selected geometry or project changed while its preview was loading.")
            }
            guard generation == request, currentRequestIdentity == requestIdentity,
                  !Task.isCancelled else { return }
            guard let loadedMap = snapshot.map,
                  (loadedMap.extent ?? loadedMap.topology.extent) != nil,
                  !loadedMap.cells.isEmpty || !loadedMap.topology.features.isEmpty else {
                error = L10n.text("The selected geometry has no renderable source FlowArea mesh or topology.")
                return
            }
            map = loadedMap
            flowAreas = snapshot.flowAreas
        } catch {
            guard generation == request, currentRequestIdentity == requestIdentity,
                  !Task.isCancelled else { return }
            self.error = L10n.text(error.localizedDescription)
        }
    }

    func invalidate() {
        generation &+= 1
        currentRequestIdentity = nil
        map = nil
        flowAreas = []
        error = nil
        isLoading = false
    }
}

/// Read-only source preview with local layer visibility, feature selection,
/// and camera focus. Every shape and extent comes from the selected geometry
/// response; this view never opens or changes the editor draft.
private struct CatalogGeometryMeshMapPreview: View {
    let map: GeometryMeshMapData
    let flowAreas: [GeometryMeshFlowAreaRow]

    @State private var hiddenFlowAreaIDs: Set<String> = []
    @State private var showsRegions = true
    @State private var showsArcs = true
    @State private var showsNodes = true
    @State private var showsMeshCells = true
    @State private var selectedTargetID: String?
    @State private var selectedFlowAreaID: String?
    @State private var focusExtent: GeometryTopologyExtent?
    @State private var zoom = 1.0
    @State private var pan = CGSize.zero
    @State private var panAtDragStart = CGSize.zero
    @State private var dragOffset = CGSize.zero
    @State private var draggingMap = false
    @State private var hasWideLayout = false
    @State private var showsLayerControls = false
    @State private var showsSelectionDetails = false

    private var currentPan: CGSize {
        CGSize(width: pan.width + dragOffset.width, height: pan.height + dragOffset.height)
    }

    private var sourceExtent: GeometryTopologyExtent? { map.extent ?? map.topology.extent }
    private var extent: GeometryTopologyExtent? { focusExtent ?? sourceExtent }
    private var visibleFlowAreaIDs: Set<String> {
        Set(flowAreas.map(\.id)).subtracting(hiddenFlowAreaIDs)
    }
    private var selectedCell: GeometryMeshMapCell? {
        map.cells.first { $0.id == selectedTargetID }
    }
    private var selectedFeature: GeometryTopologyMapFeature? {
        map.topology.features.first { $0.id == selectedTargetID }
    }
    private var selectedFlowArea: GeometryMeshFlowAreaRow? {
        flowAreas.first { $0.id == (selectedCell?.flowAreaID ?? selectedFlowAreaID) }
    }
    private var canFocusSelection: Bool {
        CatalogGeometryPreviewExtent.enclosing(selectionCoordinates, sourceExtent: sourceExtent) != nil
            || selectedFlowArea?.extent != nil
    }
    private var selectionCoordinates: [GeometryTopologyCoordinate] {
        if let selectedCell { return selectedCell.coordinates }
        if let selectedFeature { return selectedFeature.paths.flatMap { $0 } }
        if let selectedFlowArea {
            return map.cells.filter { $0.flowAreaID == selectedFlowArea.id }
                .flatMap(\.coordinates)
        }
        return []
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button { zoom = max(0.5, zoom / 1.25) } label: { Image(systemName: "minus.magnifyingglass") }
                    .help(L10n.text("Zoom out")).disabled(zoom <= 0.5)
                Button { zoom = min(6, zoom * 1.25) } label: { Image(systemName: "plus.magnifyingglass") }
                    .help(L10n.text("Zoom in")).disabled(zoom >= 6)
                Button { fitExtent() } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                    .help(L10n.text("Fit extent"))
                Button { focusSelection() } label: { Image(systemName: "scope") }
                    .help(L10n.text("Locate selection")).disabled(!canFocusSelection)
                Spacer()
                Text(L10n.text("Drag to pan; click to select."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless).controlSize(.small)
            .padding(.horizontal, 8).padding(.vertical, 6)

            if hasWideLayout {
                HSplitView {
                    layerControls.frame(minWidth: 160, idealWidth: 190, maxWidth: 230)
                    mapCanvas.frame(minWidth: 260, maxWidth: .infinity, maxHeight: .infinity)
                    selectionDetails.frame(minWidth: 170, idealWidth: 210, maxWidth: 250, maxHeight: .infinity)
                }
                .frame(minHeight: 250)
            } else {
                VStack(spacing: 8) {
                    mapCanvas.frame(minHeight: 220, idealHeight: 260)
                    DisclosureGroup(L10n.text("Layers"), isExpanded: $showsLayerControls) {
                        layerControls.frame(height: 220)
                    }
                    .accessibilityIdentifier("geometry-preview-layers")
                    DisclosureGroup(L10n.text("Selection"), isExpanded: $showsSelectionDetails) {
                        selectionDetails.frame(minHeight: 200, idealHeight: 240)
                    }
                    .accessibilityIdentifier("geometry-preview-selection")
                }
                .padding(.horizontal, 8)
            }

            HStack(spacing: 8) {
                Label(L10n.text("Source extent"), systemImage: "arrow.up.left.and.arrow.down.right")
                    .foregroundStyle(.secondary)
                if let sourceExtent {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("X  \(coord(sourceExtent.minX)) … \(coord(sourceExtent.maxX))")
                        Text("Y  \(coord(sourceExtent.minY)) … \(coord(sourceExtent.maxY))")
                    }
                    .textSelection(.enabled)
                } else {
                    Text(L10n.text("Extent unavailable")).foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }
            .font(.caption.monospacedDigit()).padding(.horizontal, 9).padding(.vertical, 6)
        }
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary, lineWidth: 1))
        .onGeometryChange(for: Bool.self) { geometry in
            geometry.size.width >= 700
        } action: { hasWideLayout = $0 }
        .onChange(of: selectedTargetID) { _, selection in
            if selection != nil && !hasWideLayout { showsSelectionDetails = true }
        }
        .onChange(of: selectedFlowAreaID) { _, selection in
            if selection != nil && !hasWideLayout { showsSelectionDetails = true }
        }
    }

    private var layerControls: some View {
        List {
            Section("Topology") {
                Toggle(L10n.text("Regions"), isOn: $showsRegions)
                Toggle(L10n.text("Arcs"), isOn: $showsArcs)
                Toggle(L10n.text("Nodes"), isOn: $showsNodes)
            }
            Section("Mesh") {
                Toggle(L10n.text("Mesh cells"), isOn: $showsMeshCells)
                ForEach(flowAreas) { row in
                    HStack(spacing: 5) {
                        Button {
                            selectedTargetID = nil
                            selectedFlowAreaID = row.id
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.name.isEmpty ? L10n.format("Flow area %@", row.rowIndex.formatted()) : row.name)
                                    .lineLimit(1)
                                Text(L10n.format("%@ cells", row.cellCount.formatted()))
                                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityLabel(L10n.format("Flow area %@",
                            row.name.isEmpty ? row.rowIndex.formatted() : row.name))
                        Toggle(isOn: Binding(
                            get: { !hiddenFlowAreaIDs.contains(row.id) },
                            set: { visible in
                                if visible { hiddenFlowAreaIDs.remove(row.id) }
                                else { hiddenFlowAreaIDs.insert(row.id) }
                            })) { EmptyView() }
                            .labelsHidden()
                            .accessibilityLabel(L10n.text("Layer visibility"))
                            .disabled(!row.hasMesh)
                    }
                    .padding(.horizontal, 4)
                    .background(selectedFlowArea?.id == row.id ? Color.accentColor.opacity(0.1) : .clear)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                }
            }
        }
        .listStyle(.sidebar)
    }

    private var mapCanvas: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                guard let projection = GeometryMeshMapProjection(extent: extent, size: size,
                    zoom: zoom, pan: currentPan) else { return }
                drawCells(in: &context, projection: projection)
                drawTopology(in: &context, projection: projection)
            }
            .background(Color(nsColor: .textBackgroundColor).opacity(0.55))
            .overlay {
                if sourceExtent == nil || (map.cells.isEmpty && map.topology.features.isEmpty) {
                    ContentUnavailableView("No source mesh or topology coordinates are available.",
                        systemImage: "map", description: Text("The map only draws coordinates supplied by this geometry source."))
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
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
                    } else {
                        select(at: value.location, size: geometry.size)
                    }
                })
            .frame(minHeight: 220)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var selectionDetails: some View {
        if let cell = selectedCell {
            Form {
                Section("Source mesh cell") {
                    LabeledContent(L10n.text("Flow Area"), value: cell.flowAreaName)
                    LabeledContent(L10n.text("Cell index"), value: cell.cellIndex.formatted())
                    LabeledContent(L10n.text("Flow-area row"), value: cell.meshIndex.formatted())
                    Text(L10n.text("Cell index is the source mesh-local ordinal; it is not an HDF feature ID."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped)
        } else if let feature = selectedFeature {
            Form {
                Section(L10n.text(featureTitle(feature))) {
                    if let fid = feature.fid {
                        LabeledContent(L10n.text("Source FID"), value: fid.formatted()).textSelection(.enabled)
                    }
                    LabeledContent(L10n.text("Geometry"), value: L10n.text(feature.geometryType))
                    LabeledContent(L10n.text("Selection links"), value: feature.selectionIDs.joined(separator: ", "))
                        .textSelection(.enabled)
                }
            }.formStyle(.grouped)
        } else if let selectedFlowArea {
            Form {
                Section(L10n.text("Flow Area")) {
                    LabeledContent(L10n.text("Name"), value: selectedFlowArea.name)
                    LabeledContent(L10n.text("Cells"), value: selectedFlowArea.cellCount.formatted())
                }
            }.formStyle(.grouped)
        } else {
            ContentUnavailableView(L10n.text("Select a map feature"), systemImage: "cursorarrow.click",
                description: Text(L10n.text("Choose a source mesh cell, topology feature, or flow area.")))
        }
    }

    private func drawCells(in context: inout GraphicsContext, projection: GeometryMeshMapProjection) {
        guard showsMeshCells else { return }
        let palette: [Color] = [.teal, .blue, .purple, .orange, .green, .pink]
        for cell in map.cells where visibleFlowAreaIDs.contains(cell.flowAreaID) {
            let path = GeometryMeshMapPath.make(paths: [cell.coordinates], projection: projection, close: true)
            guard !path.isEmpty else { continue }
            let selected = cell.id == selectedTargetID
            let color = palette[abs(cell.meshIndex) % palette.count]
            context.fill(path, with: .color(color.opacity(selected ? 0.2 : 0.035)), style: FillStyle(eoFill: true))
            context.stroke(path, with: .color(selected ? .accentColor : color.opacity(0.72)),
                style: StrokeStyle(lineWidth: selected ? 2.4 : 0.65, lineJoin: .round))
        }
    }

    private func drawTopology(in context: inout GraphicsContext, projection: GeometryMeshMapProjection) {
        for feature in map.topology.features where isVisible(feature) {
            let selected = feature.id == selectedTargetID
            switch feature.geometryType {
            case "polygon":
                let path = GeometryMeshMapPath.make(paths: feature.paths, projection: projection, close: true)
                context.fill(path, with: .color(selected ? Color.accentColor.opacity(0.22) : Color.indigo.opacity(0.08)),
                    style: FillStyle(eoFill: true))
                context.stroke(path, with: .color(selected ? .accentColor : .indigo.opacity(0.78)),
                    style: StrokeStyle(lineWidth: selected ? 2.4 : 1.1, lineJoin: .round))
            case "line":
                let path = GeometryMeshMapPath.make(paths: feature.paths, projection: projection, close: false)
                context.stroke(path, with: .color(selected ? .accentColor : .cyan.opacity(0.9)),
                    style: StrokeStyle(lineWidth: selected ? 3 : 1.5, lineCap: .round, lineJoin: .round))
            case "point":
                for coordinate in feature.paths.flatMap({ $0 }) {
                    let center = projection.project(coordinate)
                    let radius: CGFloat = selected ? 4.5 : 3
                    context.fill(Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius,
                        width: radius * 2, height: radius * 2)), with: .color(selected ? .accentColor : .orange))
                }
            default: continue
            }
        }
    }

    private func isVisible(_ feature: GeometryTopologyMapFeature) -> Bool {
        switch feature.featureKind {
        case "region": showsRegions
        case "arc": showsArcs
        case "node": showsNodes
        default: false
        }
    }

    private func select(at point: CGPoint, size: CGSize) {
        guard let projection = GeometryMeshMapProjection(extent: extent, size: size, zoom: zoom, pan: currentPan) else { return }
        if let feature = map.topology.features.reversed().first(where: { feature in
            isVisible(feature) && hit(feature, point: point, projection: projection)
        }) {
            selectedTargetID = feature.id
            selectedFlowAreaID = nil
            return
        }
        if showsMeshCells,
           let cell = map.cells.reversed().first(where: { cell in
               visibleFlowAreaIDs.contains(cell.flowAreaID)
                   && GeometryMeshMapPath.make(paths: [cell.coordinates], projection: projection, close: true).contains(point)
           }) {
            selectedTargetID = cell.id
            selectedFlowAreaID = cell.flowAreaID
            return
        }
        selectedTargetID = nil
        selectedFlowAreaID = nil
    }

    private func hit(_ feature: GeometryTopologyMapFeature, point: CGPoint,
                     projection: GeometryMeshMapProjection) -> Bool {
        switch feature.geometryType {
        case "polygon":
            return GeometryMeshMapPath.make(paths: feature.paths, projection: projection, close: true).contains(point)
        case "point":
            return feature.paths.flatMap { $0 }.contains { coordinate in
                let projected = projection.project(coordinate)
                return hypot(projected.x - point.x, projected.y - point.y) <= 8
            }
        case "line":
            return feature.paths.contains { path in
                let points = path.map(projection.project)
                return zip(points, points.dropFirst()).contains { segmentDistance(point, $0.0, $0.1) <= 7 }
            }
        default: return false
        }
    }

    private func segmentDistance(_ point: CGPoint, _ start: CGPoint, _ end: CGPoint) -> CGFloat {
        let dx = end.x - start.x, dy = end.y - start.y
        let denominator = dx * dx + dy * dy
        guard denominator > 0 else { return hypot(point.x - start.x, point.y - start.y) }
        let t = min(1, max(0, ((point.x - start.x) * dx + (point.y - start.y) * dy) / denominator))
        return hypot(point.x - (start.x + t * dx), point.y - (start.y + t * dy))
    }

    private func focusSelection() {
        let coordinates = selectionCoordinates
        if !coordinates.isEmpty,
           let selection = CatalogGeometryPreviewExtent.enclosing(coordinates, sourceExtent: sourceExtent) {
            focusExtent = selection
            zoom = 1
            pan = .zero
        } else if let extent = selectedFlowArea?.extent {
            focusExtent = .init(minX: extent.minX, minY: extent.minY, maxX: extent.maxX, maxY: extent.maxY)
            zoom = 1
            pan = .zero
        }
    }

    private func fitExtent() {
        focusExtent = nil
        zoom = 1
        pan = .zero
    }

    private func featureTitle(_ feature: GeometryTopologyMapFeature) -> String {
        switch feature.featureKind {
        case "arc": "Topology arc"
        case "region": "Topology region"
        case "node": "Topology node"
        default: "Topology feature"
        }
    }

    private func coord(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(2...5))) }
}

enum CatalogGeometryPreviewExtent {
    static func enclosing(_ coordinates: [GeometryTopologyCoordinate],
                          sourceExtent: GeometryTopologyExtent? = nil) -> GeometryTopologyExtent? {
        let finite = coordinates.filter { $0.x.isFinite && $0.y.isFinite }
        guard !finite.isEmpty else { return nil }
        let minX = finite.map(\.x).min()!, maxX = finite.map(\.x).max()!
        let minY = finite.map(\.y).min()!, maxY = finite.map(\.y).max()!
        let spanX = maxX - minX, spanY = maxY - minY
        guard spanX.isFinite, spanY.isFinite else { return nil }
        let sourceSpanX = sourceExtent.map { $0.maxX - $0.minX }.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let sourceSpanY = sourceExtent.map { $0.maxY - $0.minY }.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let padX = spanX > 0 ? spanX * 0.12 : max((sourceSpanX ?? 1) * 0.02, 1e-6)
        let padY = spanY > 0 ? spanY * 0.12 : max((sourceSpanY ?? 1) * 0.02, 1e-6)
        let result = GeometryTopologyExtent(minX: minX - padX, minY: minY - padY,
            maxX: maxX + padX, maxY: maxY + padY)
        return [result.minX, result.minY, result.maxX, result.maxY].allSatisfy(\.isFinite) ? result : nil
    }
}

@MainActor
struct CatalogNValuePreviewView: View {
    let asset: ProjectAsset
    let projectURL: URL?
    let requestIdentity: String
    let client: BackendProcessClient
    @StateObject private var session = CatalogNValuePreviewSession()
    @State private var refreshRevision = UUID()

    private var previewIdentity: String {
        [requestIdentity, refreshRevision.uuidString].joined(separator: "\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L10n.text("N-Value Source Preview")).font(.subheadline.weight(.medium))
                Spacer()
                Button {
                    refreshRevision = UUID()
                } label: {
                    Label(L10n.text("Refresh"), systemImage: "arrow.clockwise")
                }
                .disabled(session.isLoading || projectURL == nil)
            }
            if session.isLoading {
                ProgressView(L10n.text("Loading source raster…")).controlSize(.small)
            } else if let preview = session.preview {
                DataToolPreviewView(preview: preview, loading: false, isCurrent: true)
                    .frame(minHeight: 190, idealHeight: 230)
                if !session.legendStops.isEmpty {
                    CatalogNValueSourceLegend(stops: session.legendStops)
                }
                if let histogram = session.histogram {
                    CatalogNValueSourceHistogram(histogram: histogram)
                }
            } else if let error = session.error {
                CatalogSummaryUnavailableNotice(title: "N-Value preview unavailable", detail: error)
            } else if session.mode == "Constant" {
                CatalogSummaryUnavailableNotice(title: "N-Value preview unavailable",
                    detail: "A constant N-value layer has no finite source extent to preview.")
            } else {
                CatalogSummaryUnavailableNotice(title: "N-Value preview unavailable",
                    detail: "The selected N-value layer has no finite renderable source extent.")
            }
        }
        .task(id: previewIdentity) {
            guard let projectURL else {
                session.invalidate()
                return
            }
            await session.load(asset: asset, projectURL: projectURL,
                requestIdentity: previewIdentity, provider: BackendCatalogNValuePreviewProvider(client: client))
        }
        .onDisappear { session.invalidate() }
    }
}

@MainActor
final class CatalogNValuePreviewSession: ObservableObject {
    @Published private(set) var preview: DataToolPreview?
    @Published private(set) var mode: String?
    @Published private(set) var legendStops: [CatalogNValuePreviewLegendStop] = []
    @Published private(set) var histogram: CatalogNValuePreviewHistogram?
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?
    private var generation = 0
    private var currentRequestIdentity: String?

    func load(asset: ProjectAsset, projectURL: URL, requestIdentity: String,
              provider: BackendCatalogNValuePreviewProvider) async {
        generation &+= 1
        let request = generation
        currentRequestIdentity = requestIdentity
        preview = nil
        mode = nil
        legendStops = []
        histogram = nil
        error = nil
        isLoading = true
        defer { if generation == request { isLoading = false } }
        do {
            let revision = try await CatalogPreviewFileRevision.sha256(asset.url)
            let snapshot = try await provider.load(asset: asset, projectURL: projectURL, revision: revision)
            guard generation == request, currentRequestIdentity == requestIdentity, !Task.isCancelled else { return }
            mode = snapshot.mode
            legendStops = snapshot.legendStops
            histogram = snapshot.histogram
            guard let raster = snapshot.raster else { return }
            preview = try raster.presentation(name: asset.name)
        } catch {
            guard generation == request, currentRequestIdentity == requestIdentity, !Task.isCancelled else { return }
            self.error = L10n.text(error.localizedDescription)
        }
    }

    func invalidate() {
        generation &+= 1
        currentRequestIdentity = nil
        preview = nil
        mode = nil
        legendStops = []
        histogram = nil
        error = nil
        isLoading = false
    }
}

private struct CatalogNValueSourceLegend: View {
    let stops: [CatalogNValuePreviewLegendStop]

    private var orderedStops: [CatalogNValuePreviewLegendStop] {
        stops.filter { $0.value.isFinite }.sorted { $0.value < $1.value }
    }

    private var gradient: LinearGradient {
        let values = orderedStops
        guard !values.isEmpty else {
            return LinearGradient(colors: [Color.accentColor, Color.accentColor], startPoint: .leading, endPoint: .trailing)
        }
        let first = values.first?.value ?? 0
        let last = values.last?.value ?? first
        let span = last - first
        let gradientStops = values.enumerated().map { index, stop in
            let fraction = span > 0 ? (stop.value - first) / span
                : (values.count > 1 ? Double(index) / Double(values.count - 1) : 0)
            return Gradient.Stop(color: color(stop), location: CGFloat(min(1, max(0, fraction))))
        }
        return LinearGradient(stops: gradientStops, startPoint: .leading, endPoint: .trailing)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(L10n.text("Manning’s n")).font(.caption.weight(.medium))
            Capsule().fill(gradient).frame(height: 12)
            ScrollView(.horizontal) {
                HStack(spacing: 10) {
                    ForEach(orderedStops) { stop in
                        HStack(spacing: 4) {
                            Circle().fill(color(stop)).frame(width: 8, height: 8)
                            Text(stop.value.formatted(.number.precision(.fractionLength(2...4))))
                                .font(.caption.monospacedDigit())
                        }
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L10n.text("Manning’s n"))
    }

    private func color(_ stop: CatalogNValuePreviewLegendStop) -> Color {
        Color(red: Double(stop.red) / 255, green: Double(stop.green) / 255,
              blue: Double(stop.blue) / 255, opacity: Double(stop.alpha) / 255)
    }
}

private struct CatalogNValueSourceHistogram: View {
    let histogram: CatalogNValuePreviewHistogram

    private var validAreas: [Double] {
        histogram.binArea.map { $0.isFinite && $0 > 0 ? $0 : 0 }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(L10n.text("Estimated source-area histogram"))
                .font(.caption.weight(.medium))
            Canvas { context, size in
                guard !validAreas.isEmpty else { return }
                let bucketCount = max(1, min(validAreas.count, Int(size.width / 2)))
                let groupedAreas = (0..<bucketCount).map { bucket in
                    let start = bucket * validAreas.count / bucketCount
                    let end = max(start + 1, (bucket + 1) * validAreas.count / bucketCount)
                    return validAreas[start..<min(end, validAreas.count)].reduce(0, +)
                }
                let maximumBucketArea = groupedAreas.max() ?? 0
                guard maximumBucketArea.isFinite, maximumBucketArea > 0 else { return }
                let barWidth = size.width / CGFloat(bucketCount)
                for (index, area) in groupedAreas.enumerated() where area > 0 {
                    let fraction = area.isFinite ? min(1, max(0, area / maximumBucketArea)) : 0
                    let height = max(1, size.height * CGFloat(fraction))
                    let rect = CGRect(x: CGFloat(index) * barWidth,
                        y: size.height - height, width: barWidth, height: height)
                    context.fill(Path(rect), with: .color(Color.accentColor.opacity(0.78)))
                }
            }
            .frame(height: 64)
            .accessibilityLabel(L10n.text("Estimated source-area histogram"))
            HStack {
                Text(histogram.minimum.formatted(.number.precision(.fractionLength(2...4))))
                Spacer()
                Text(histogram.maximum.formatted(.number.precision(.fractionLength(2...4))))
            }
            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        .padding(.top, 2)
    }
}

/// Renders Terrain and Classification rasters using each model's actual
/// read-only backend operation and the catalog session's independent source
/// snapshot. It does not submit or reuse an editor draft.
@MainActor
struct CatalogModelRasterSummaryPreviewView: View {
    let asset: ProjectAsset
    let kind: CatalogSummaryKind
    let snapshot: EditorSnapshot?
    let requestRevision: String
    let isSourceLoading: Bool
    let sourceError: String?
    let provider: any ModelEditorProvider
    @StateObject private var session = CatalogModelRasterSummaryPreviewSession()
    @State private var refreshRevision = UUID()

    private var previewIdentity: String {
        [requestRevision, snapshot?.sourceRevision ?? "", refreshRevision.uuidString].joined(separator: "\n")
    }
    private var previewTitle: String {
        kind == .terrain ? "Terrain Source Preview" : "Classification Map Preview"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L10n.text(previewTitle)).font(.subheadline.weight(.medium))
                Spacer()
                Button {
                    refreshRevision = UUID()
                } label: {
                    Label(L10n.text("Refresh"), systemImage: "arrow.clockwise")
                }
                .disabled(session.isLoading || isSourceLoading || snapshot == nil)
            }
            if isSourceLoading || session.isLoading {
                ProgressView(L10n.text("Loading source raster…")).controlSize(.small)
            } else if let preview = session.preview {
                DataToolPreviewView(preview: preview, loading: false, isCurrent: true)
                    .frame(minHeight: 190, idealHeight: 230)
                if !session.legend.isEmpty {
                    ScrollView(.horizontal) {
                        HStack(spacing: 10) {
                            ForEach(session.legend) { item in
                                HStack(spacing: 5) {
                                    Circle().fill(EditorColor.decode(item.color)).frame(width: 9, height: 9)
                                    Text(item.name).font(.caption)
                                }
                            }
                        }
                    }
                }
            } else if let error = session.error ?? sourceError {
                CatalogSummaryUnavailableNotice(title: "Source preview unavailable", detail: error)
            } else if snapshot == nil {
                CatalogSummaryUnavailableNotice(
                    title: "Source preview unavailable",
                    detail: "The read-only catalog source snapshot is not available for this asset."
                )
            }
        }
        .task(id: previewIdentity) {
            guard let snapshot, kind == .terrain || kind == .classification else {
                session.invalidate()
                return
            }
            await session.load(asset: asset, kind: kind, snapshot: snapshot,
                requestRevision: previewIdentity, provider: provider)
        }
        .onDisappear { session.invalidate() }
    }
}

@MainActor
final class CatalogModelRasterSummaryPreviewSession: ObservableObject {
    @Published private(set) var preview: DataToolPreview?
    @Published private(set) var legend: [ClassificationMapData.Legend] = []
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?

    private var generation = 0
    private var currentRequestRevision: String?

    func load(asset: ProjectAsset, kind: CatalogSummaryKind, snapshot: EditorSnapshot,
              requestRevision: String, provider: any ModelEditorProvider) async {
        generation &+= 1
        let request = generation
        currentRequestRevision = requestRevision
        preview = nil
        legend = []
        error = nil
        isLoading = true
        defer { if generation == request { isLoading = false } }

        do {
            guard let revision = snapshot.sourceRevision, !revision.isEmpty else {
                throw BackendServiceError(code: "sourceChanged", message: "Refresh the source summary before rendering its preview.")
            }
            // The catalog snapshot is read-only metadata. Send only its source
            // revision and opaque backend state so the service reopens the HDF
            // without applying read-only name/filename/property fields.
            let edits = EditorEdits(fields: [:], rows: [:], images: [:],
                sourceRevision: revision, sourceState: snapshot.sourceState)
            let raster: SpatialGridPreview?
            var loadedLegend: [ClassificationMapData.Legend] = []
            if kind == .terrain, asset.section == .terrains {
                raster = try await provider.terrainMap(asset, edits: edits, inputID: nil).raster
            } else if kind == .classification, asset.section == .surfaceLayers {
                let result = try await provider.classificationMap(asset, edits: edits)
                raster = result.raster
                loadedLegend = result.legend
            } else {
                throw BackendServiceError(code: "unsupported", message: "The selected source does not have a matching raster renderer.")
            }
            guard generation == request, currentRequestRevision == requestRevision,
                  !Task.isCancelled else { return }
            legend = loadedLegend
            guard let raster else {
                error = L10n.text("The selected source returned no renderable raster.")
                return
            }
            preview = try raster.presentation(name: asset.name)
        } catch {
            guard generation == request, currentRequestRevision == requestRevision,
                  !Task.isCancelled else { return }
            self.error = L10n.text(error.localizedDescription)
        }
    }

    func invalidate() {
        generation &+= 1
        currentRequestRevision = nil
        preview = nil
        legend = []
        error = nil
        isLoading = false
    }
}

/// Result profile selection and rendering are tied to the exact selected HDF
/// and project draft. The disclosure reuses the existing read-only profile
/// catalog, mesh preview, and chart services.
@MainActor
struct CatalogResultProfilesDisclosureView: View {
    let asset: ProjectAsset
    @ObservedObject var store: WorkspaceStore
    let client: BackendProcessClient
    @StateObject private var inspector: ResultInspectorSession
    @StateObject private var profileSession: ResultProfileSession
    @State private var isExpanded = false

    init(asset: ProjectAsset, store: WorkspaceStore, client: BackendProcessClient) {
        self.asset = asset
        self.store = store
        self.client = client
        _inspector = StateObject(wrappedValue: ResultInspectorSession(
            provider: BackendResultInspectorProvider(client: client)))
        _profileSession = StateObject(wrappedValue: ResultProfileSession(
            provider: BackendResultProfileProvider(client: client)))
    }

    private var projectXML: String? {
        store.document?.editorXML(overridingDescription: store.descriptionDraft)
    }
    private var projectPath: URL? { store.document?.url }
    private var projectContextID: String { "\(store.projectSessionID):\(store.assetsRevision)" }
    private var requestIdentity: String {
        [asset.id, SourceFilePaths.canonical(asset.url),
         projectPath.map(SourceFilePaths.canonical) ?? "",
         projectContextID, projectXML ?? ""].joined(separator: "\n")
    }
    private var profileIdentity: ResultProfileIdentity? {
        inspector.snapshot.map { .init(resultPath: $0.resultPath, revision: $0.revision) }
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                if inspector.isLoading {
                    ProgressView(L10n.text("Reading result source…")).controlSize(.small)
                }
                if let error = inspector.error {
                    CatalogSummaryUnavailableNotice(title: "Result profile preview unavailable", detail: error)
                }
                if let snapshot = inspector.snapshot {
                    if snapshot.outputBlocks.isEmpty {
                        CatalogSummaryUnavailableNotice(
                            title: "No stored result profiles",
                            detail: "The selected result does not contain a stored output profile to preview."
                        )
                    } else {
                        SharedVisualMetadataPropertiesRepeater(properties: snapshot.outputBlocks.map {
                            .init(id: "ResultProfile/\($0.name)", key: $0.name,
                                  value: L10n.format("%d profiles", $0.profileCount))
                        })
                        ResultProfilePanel(identity: profileIdentity,
                            projectPath: projectPath?.standardizedFileURL.path,
                            projectXML: projectXML, projectContextID: projectContextID,
                            session: profileSession)
                            .frame(minHeight: 360, idealHeight: 440)
                    }
                }
            }
            .task(id: "\(requestIdentity)\n\(isExpanded)") {
                guard isExpanded else {
                    inspector.invalidate()
                    profileSession.clear()
                    return
                }
                await inspector.ensureLoaded(asset: asset, projectPath: projectPath,
                    projectXML: projectXML, sourceContextRevision: projectContextID)
            }
            .onDisappear {
                inspector.invalidate()
                profileSession.clear()
            }
        } label: {
            Label(L10n.text("Result Profile Preview"), systemImage: "chart.xyaxis.line")
                .font(.subheadline.weight(.medium))
        }
    }
}
