import Foundation
import RASWorkspaceCore
import SwiftUI

struct ClassificationVertex: Codable, Equatable, Sendable {
    var x: Double
    var y: Double
    var z: String? = nil
    var m: String? = nil
    var point: MapPoint { .init(x: x, y: y) }
}
struct ClassificationGeometryMutation: Encodable, Sendable {
    let operation: String
    var inputId: String? = nil
    var polygonIds: [String]? = nil
    var vertices: [ClassificationVertex]? = nil
    var hasZ = false
    var hasM = false
    var classification: String? = nil
    var features: [ClassificationClipboardPolygon]? = nil
}
struct ClassificationToolsState: Sendable {
    let classes: [String]
    let canUndo: Bool
    let canRedo: Bool
}
struct ClassificationMapData: Decodable, Sendable {
    struct Legend: Decodable, Identifiable, Sendable { let id: Int; let name: String; let color: String }
    let raster: SpatialGridPreview?
    let legend: [Legend]
    let selectedRaster: SpatialGridPreview?
    let selectedInputId: String?
    let projection: String?

    init(raster: SpatialGridPreview?, legend: [Legend], selectedRaster: SpatialGridPreview? = nil,
         selectedInputId: String? = nil, projection: String? = nil) {
        self.raster = raster; self.legend = legend; self.selectedRaster = selectedRaster
        self.selectedInputId = selectedInputId; self.projection = projection
    }

    func presentation() throws -> DataToolPreview {
        var preview = try raster?.presentation(name: "Classification") ?? .init()
        if let selectedRaster {
            guard let selectedInputId, !selectedInputId.isEmpty, raster != nil else {
                throw ProjectFileError.invalid("The selected classification raster has no matching source context.")
            }
            preview.rasters += try selectedRaster.presentation(name: selectedInputId).rasters
        } else if selectedInputId != nil {
            throw ProjectFileError.invalid("The selected classification raster is missing.")
        }
        return preview
    }
}
struct ClassificationMapPolygon: Identifiable, Sendable {
    let inputID: String
    let inputScope: String
    let item: PolygonClassificationItem
    var id: String { item.id }
    var points: [MapPoint] { item.vertices.map(\.point) }
    func feature(vertices: [ClassificationVertex]? = nil) -> MapFeature {
        .init(id: 0, kind: .polygon, paths: [(vertices ?? item.vertices).map(\.point)], attributes: [:])
    }
}

struct ClassificationMapView: View {
    @ObservedObject var session: ModelEditorSession
    @ObservedObject var store: WorkspaceStore
    @State private var mode = "Select"
    @State private var map: ClassificationMapData?
    @State private var loading = false
    @State private var mapError: String?
    @State private var fitPoints: [MapPoint] = [.init(x: 0, y: 0), .init(x: 100, y: 100)]
    @State private var fitted = false
    @State private var scale: CGFloat = 1
    @State private var offset = CGSize.zero
    @State private var dragOffset = CGSize.zero
    @State private var draft: [ClassificationVertex] = []
    @State private var classification = "NoData"
    @State private var pointer: MapPoint?
    @State private var dragged: VertexDrag?
    @State private var vertexSheet: VertexRequest?
    @FocusState private var focused: Bool
    private struct VertexDrag { let polygon: ClassificationMapPolygon; let index: Int; var vertices: [ClassificationVertex] }
    private struct VertexRequest: Identifiable { let id = UUID(); let polygon: ClassificationMapPolygon? }
    private var collection: SourceCollection? { session.sourceCollections[ClassificationEditorContract.sourceField] }
    private var tools: ClassificationToolsState? { collection?.classificationTools }
    private var polygons: [ClassificationMapPolygon] {
        (collection?.items ?? []).flatMap { input in
            guard let detail = collection?.itemDetails[input.id] else { return [ClassificationMapPolygon]() }
            return (detail.polygons?.items ?? []).reversed().map { .init(inputID: input.id, inputScope: detail.scope, item: $0) }
        }
    }
    private var selectedIDs: Set<String> { Set((collection?.itemDetails.values.flatMap { $0.polygons?.selectedIDs ?? [] }) ?? []) }
    private var selectedPolygon: ClassificationMapPolygon? { polygons.first { selectedIDs.contains($0.id) } }
    private var rasterLayers: [MapRasterLayer] { (try? map?.presentation().rasters) ?? [] }
    private var allPoints: [MapPoint] { polygons.flatMap(\.points) + rasterLayers.flatMap(\.points) }
    private var editable: Bool { session.canEdit && !session.isBusy && !session.loadingSelection }
    private var geometryAdapterAvailable: Bool { tools != nil }
    var body: some View {
        VStack(spacing: 0) {
            toolbar
            if !geometryAdapterAvailable {
                Label("The original model adapter for this tool is unavailable.", systemImage: "externaldrive.badge.questionmark")
                    .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10)
            }
            if mode == "Draw Polygon" { drawingControls }
            if let mapError { Label(mapError, systemImage: "exclamationmark.triangle").foregroundStyle(.red).textSelection(.enabled).padding(8) }
            canvas.frame(minHeight: 240)
            HStack {
                if loading { ProgressView().controlSize(.small) }
                Text(L10n.format("%d polygons", polygons.count)).font(.caption)
                Spacer()
                if let pointer { Text(String(format: "X %.4f  Y %.4f", pointer.x, pointer.y)).font(.caption.monospaced()).textSelection(.enabled).help(map?.projection ?? "") }
            }.padding(8)
            ScrollView(.horizontal) {
                HStack {
                    ForEach(map?.legend ?? []) { item in
                        HStack(spacing: 5) { Circle().fill(EditorColor.decode(item.color)).frame(width: 9, height: 9); Text(item.name).font(.caption) }
                    }
                }.padding(8)
            }.frame(maxHeight: 38)
        }
        .task(id: session.classificationMapIdentity) {
            map = nil; mapError = nil; loading = false
            guard !session.isBusy else { return }
            loading = true
            do {
                let result = try await session.classificationMap(); try Task.checkCancellation()
                map = result; mapError = nil
                if !fitted { fit(); fitted = true }
            } catch {
                if !Task.isCancelled { mapError = L10n.text(error.localizedDescription) }
            }
            if !Task.isCancelled { loading = false }
        }
        .sheet(item: $vertexSheet) { request in
            PolygonVerticesSheet(polygon: request.polygon, inputID: request.polygon?.inputID ?? session.fields[ClassificationEditorContract.sourceField], session: session, store: store)
        }
        .onChange(of: session.modelAssetID) { _, _ in
            fitted = false; scale = 1; offset = .zero; dragOffset = .zero
            draft = []; dragged = nil; vertexSheet = nil; pointer = nil; mode = "Select"
        }
    }
    private var toolbar: some View {
        ViewThatFits(in: .horizontal) {
            HStack { toolPicker; geometryActions; Spacer(minLength: 0); history; zoom }
            VStack(alignment: .leading) { HStack { toolPicker; geometryActions; Spacer(minLength: 0) }; HStack { history; Spacer(); zoom } }
        }.padding(8)
    }
    private var toolPicker: some View {
        Picker("Map Tool", selection: $mode) {
            Text("Select").tag("Select"); Text("Draw Polygon").tag("Draw Polygon"); Text("Move Vertex").tag("Move Vertex"); Text("Pan").tag("Pan")
        }.labelsHidden().frame(maxWidth: 160).disabled(!editable || !geometryAdapterAvailable)
    }
    private var geometryActions: some View {
        Menu("Geometry Actions") {
            Button("Copy Selected Polygons") {
                do {
                    try ClassificationFeatureClipboard.copy(polygons.filter { selectedIDs.contains($0.id) }, session: session, system: store.system)
                    mapError = nil
                } catch { mapError = L10n.text(error.localizedDescription) }
            }.disabled(selectedIDs.isEmpty || session.hasIncompleteEditorInput)
            ClassificationPasteFeaturesButton(inputID: session.fields[ClassificationEditorContract.sourceField], session: session, store: store)
            Divider()
            Button("New Polygon…") { vertexSheet = .init(polygon: nil) }
            Button("Edit Vertices…") { if let selectedPolygon { vertexSheet = .init(polygon: selectedPolygon) } }.disabled(selectedIDs.count != 1)
            Button("Delete Selected Polygons", role: .destructive) { mutate(.init(operation: "delete", polygonIds: Array(selectedIDs).sorted())) }.disabled(selectedIDs.isEmpty)
        }.disabled(!editable || !geometryAdapterAvailable)
    }
    private var history: some View {
        ControlGroup {
            Button { mutate(.init(operation: "undo")) } label: { Label("Undo Polygon Edit", systemImage: "arrow.uturn.backward") }.disabled(!editable || tools?.canUndo != true)
            Button { mutate(.init(operation: "redo")) } label: { Label("Redo Polygon Edit", systemImage: "arrow.uturn.forward") }.disabled(!editable || tools?.canRedo != true)
        }.labelStyle(.iconOnly)
    }
    private var zoom: some View {
        ControlGroup {
            Button { scale = min(scale * 1.5, 1_000_000) } label: { Label("Zoom In", systemImage: "plus.magnifyingglass") }
            Button { scale = max(scale / 1.5, 0.000001) } label: { Label("Zoom Out", systemImage: "minus.magnifyingglass") }
            Button(action: fit) { Label("Zoom to Full Extent", systemImage: "arrow.up.left.and.arrow.down.right") }
        }.labelStyle(.iconOnly)
    }
    private var drawingControls: some View {
        HStack {
            TextField("Classification", text: $classification).textInputSuggestions { ForEach(tools?.classes ?? [], id: \.self) { Text($0).textInputCompletion($0) } }.frame(maxWidth: 180)
            Text(L10n.format("%d vertices", draft.count)).font(.caption)
            Spacer(minLength: 0)
            Button("Remove Last Vertex") { if !draft.isEmpty { draft.removeLast() } }.disabled(draft.isEmpty || !editable)
            Button("Finish Polygon") {
                let vertices = draft
                Task { if await session.perform(.editClassificationGeometry(.init(operation: "create", inputId: session.fields[ClassificationEditorContract.sourceField], vertices: vertices, classification: classification))) { draft = []; mode = "Select" } }
            }.disabled(draft.count < 3 || !editable || !geometryAdapterAvailable)
            Button("Cancel") { draft = []; mode = "Select" }.disabled(!editable)
        }.padding(8)
    }
    private var canvas: some View {
        GeometryReader { proxy in
            let translation = CGSize(width: offset.width + dragOffset.width, height: offset.height + dragOffset.height)
            let transform = MapTransform(points: fitPoints, size: proxy.size, scale: scale, offset: translation)
            ZStack {
                Color(nsColor: .textBackgroundColor)
                RasterCanvas(layers: rasterLayers, points: fitPoints, scale: scale, offset: translation,
                    revision: (map?.raster?.rgba.hashValue ?? 0) ^ (map?.selectedRaster?.rgba.hashValue ?? 0))
                Canvas { context, size in
                    drawGrid(context: context, size: size)
                    for polygon in polygons {
                        let vertices = dragged?.polygon.id == polygon.id ? dragged?.vertices : nil
                        let path = transform.path(polygon.feature(vertices: vertices))
                        let selected = selectedIDs.contains(polygon.id)
                        context.stroke(path, with: .color(selected ? .orange : .primary.opacity(0.7)), lineWidth: selected ? 2.5 : 1)
                        if selected {
                            for vertex in vertices ?? polygon.item.vertices {
                                let point = transform.screen(vertex.point)
                                context.fill(Path(ellipseIn: CGRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6)), with: .color(.orange))
                            }
                        }
                    }
                    if !draft.isEmpty {
                        let feature = MapFeature(id: 0, kind: .line, paths: [draft.map(\.point)], attributes: [:])
                        context.stroke(transform.path(feature), with: .color(.orange), style: .init(lineWidth: 2, dash: [5, 3]))
                        for vertex in draft { let p = transform.screen(vertex.point); context.fill(Path(ellipseIn: CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)), with: .color(.orange)) }
                    }
                }
            }
            .contentShape(Rectangle()).focusable().focused($focused)
            .accessibilityLabel("Classification Geometry Map")
            .gesture(SpatialTapGesture().onEnded { value in
                focused = true
                guard editable else { return }
                if mode == "Draw Polygon" { let point = transform.world(value.location); draft.append(.init(x: point.x, y: point.y)) }
                else if mode != "Pan" { select(at: value.location, transform: transform) }
            })
            .simultaneousGesture(DragGesture(minimumDistance: 3).onChanged { value in
                guard editable else { return }
                if mode == "Pan" { dragOffset = value.translation }
                else if mode == "Move Vertex" {
                    if dragged == nil { dragged = nearestVertex(value.startLocation, transform: transform) }
                    if var drag = dragged { let point = transform.world(value.location); drag.vertices[drag.index].x = point.x; drag.vertices[drag.index].y = point.y; dragged = drag }
                }
            }.onEnded { value in
                if mode == "Pan" { offset.width += value.translation.width; offset.height += value.translation.height; dragOffset = .zero }
                else if let drag = dragged { dragged = nil; mutate(.init(operation: "replace", inputId: drag.polygon.inputID, polygonIds: [drag.polygon.id], vertices: drag.vertices, hasZ: drag.polygon.item.hasZ, hasM: drag.polygon.item.hasM)) }
            })
            .onContinuousHover { phase in if case .active(let location) = phase { pointer = transform.world(location) } else { pointer = nil } }
            .onKeyPress { press in
                if press.key == .escape { draft = []; mode = "Select"; return .handled }
                if press.key == .delete, editable, !selectedIDs.isEmpty { mutate(.init(operation: "delete", polygonIds: Array(selectedIDs).sorted())); return .handled }
                if press.modifiers.contains(.command), press.characters.lowercased() == "z", editable {
                    let redo = press.modifiers.contains(.shift)
                    if redo ? tools?.canRedo == true : tools?.canUndo == true { mutate(.init(operation: redo ? "redo" : "undo")); return .handled }
                }
                return .ignored
            }
        }
    }
    private func drawGrid(context: GraphicsContext, size: CGSize) {
        var lines = Path()
        for x in stride(from: 0.0, through: size.width, by: 64) { lines.move(to: .init(x: x, y: 0)); lines.addLine(to: .init(x: x, y: size.height)) }
        for y in stride(from: 0.0, through: size.height, by: 64) { lines.move(to: .init(x: 0, y: y)); lines.addLine(to: .init(x: size.width, y: y)) }
        context.stroke(lines, with: .color(.secondary.opacity(0.1)), lineWidth: 0.5)
    }
    private func fit() {
        let points = allPoints
        fitPoints = points.isEmpty ? [.init(x: 0, y: 0), .init(x: 100, y: 100)] : points
        scale = 1; offset = .zero; dragOffset = .zero
    }
    private func mutate(_ mutation: ClassificationGeometryMutation) { Task { _ = await session.perform(.editClassificationGeometry(mutation)) } }
    private func select(at location: CGPoint, transform: MapTransform) {
        let found = polygons.first { transform.path($0.feature()).contains(location, eoFill: true) }
        Task {
            for input in collection?.items ?? [] {
                guard let detail = collection?.itemDetails[input.id], detail.polygons != nil else { continue }
                _ = await session.perform(.selectPolygonClassifications(field: ClassificationEditorContract.sourceField, scope: detail.scope, ids: found?.inputID == input.id ? [found!.id] : []))
            }
            if let found { _ = await session.perform(.selectSource(field: ClassificationEditorContract.sourceField, id: found.inputID)) }
        }
    }
    private func nearestVertex(_ location: CGPoint, transform: MapTransform) -> VertexDrag? {
        var best: VertexDrag?; var distance = 14.0
        for polygon in polygons where selectedIDs.isEmpty || selectedIDs.contains(polygon.id) {
            for (index, vertex) in polygon.item.vertices.enumerated() {
                let point = transform.screen(vertex.point), candidate = hypot(point.x - location.x, point.y - location.y)
                if candidate < distance { distance = candidate; best = .init(polygon: polygon, index: index, vertices: polygon.item.vertices) }
            }
        }
        return best
    }
}

struct PolygonVerticesSheet: View {
    let polygon: ClassificationMapPolygon?
    let inputID: String?
    @ObservedObject var session: ModelEditorSession
    @ObservedObject var store: WorkspaceStore
    @Environment(\.dismiss) private var dismiss
    @State private var rows: [VertexRow]
    @State private var selection: Set<UUID> = []
    @State private var classification = "NoData"
    private struct VertexRow: Identifiable { let id = UUID(); var x: String; var y: String; var z: String; var m: String }
    init(polygon: ClassificationMapPolygon?, inputID: String?, session: ModelEditorSession, store: WorkspaceStore) {
        self.polygon = polygon; self.inputID = inputID; self.session = session; self.store = store
        _rows = State(initialValue: (polygon?.item.vertices ?? []).map { .init(x: String($0.x), y: String($0.y), z: $0.z ?? "NaN", m: $0.m ?? "NaN") })
    }
    private var vertices: [ClassificationVertex]? {
        let values = rows.compactMap { row -> ClassificationVertex? in
            guard let x = Double(row.x), x.isFinite, let y = Double(row.y), y.isFinite else { return nil }
            return .init(x: x, y: y, z: polygon?.item.hasZ == true ? row.z : nil, m: polygon?.item.hasM == true ? row.m : nil)
        }
        return values.count == rows.count && values.count >= 3 ? values : nil
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(LocalizedStringKey(polygon == nil ? "New Polygon" : "Edit Vertices")).font(.title2)
                Spacer(); Button("Cancel", role: .cancel) { dismiss() }.disabled(session.isBusy)
                Button("Apply Geometry") { apply() }.buttonStyle(.borderedProminent).disabled(vertices == nil || session.isBusy)
            }.padding(16)
            if polygon == nil { TextField("Classification", text: $classification).padding(.horizontal, 16).padding(.bottom, 10) }
            else { LabeledContent("Classification", value: polygon.map { session.fields[$0.item.fieldID] ?? $0.item.classification } ?? "").padding(.horizontal, 16).padding(.bottom, 10) }
            HStack {
                Button("Add Vertex") {
                    let index = rows.firstIndex { selection.contains($0.id) }.map { $0 + 1 } ?? rows.count
                    let row = VertexRow(x: "0", y: "0", z: "NaN", m: "NaN"); rows.insert(row, at: index); selection = [row.id]
                }
                Button("Remove Vertex") { rows.removeAll { selection.contains($0.id) }; selection = [] }.disabled(selection.isEmpty)
                Spacer(); Button("Copy Coordinates") { store.system.copy(rows.map { row in ([row.x, row.y] + (polygon?.item.hasZ == true ? [row.z] : []) + (polygon?.item.hasM == true ? [row.m] : [])).joined(separator: "\t") }.joined(separator: "\n")) }
            }.padding(12).disabled(session.isBusy)
            Table($rows, selection: $selection) {
                TableColumn("X") { row in TextField("X", text: row.x).labelsHidden() }
                TableColumn("Y") { row in TextField("Y", text: row.y).labelsHidden() }
                if polygon?.item.hasZ == true { TableColumn("Z") { row in TextField("Z", text: row.z).labelsHidden() } }
                if polygon?.item.hasM == true { TableColumn("M") { row in TextField("M", text: row.m).labelsHidden() } }
            }.disabled(session.isBusy)
            if let error = session.error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).textSelection(.enabled).padding(12) }
            Text("Geometry changes remain unsaved until you save the model.").font(.caption).foregroundStyle(.secondary).padding(12)
        }.frame(minWidth: 700, minHeight: 480).interactiveDismissDisabled(session.isBusy)
    }
    private func apply() {
        guard let vertices else { return }
        let mutation = ClassificationGeometryMutation(operation: polygon == nil ? "create" : "replace", inputId: inputID,
            polygonIds: polygon.map { [$0.id] }, vertices: vertices, hasZ: polygon?.item.hasZ ?? false, hasM: polygon?.item.hasM ?? false, classification: polygon == nil ? classification : nil)
        Task { if await session.perform(.editClassificationGeometry(mutation)) { dismiss() } }
    }
}
