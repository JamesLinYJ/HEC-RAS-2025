import RASWorkspaceCore
import SwiftUI

struct PointImportPresentation: Sendable {
    let points: [InterestPoint]
    let canEdit: Bool
    var backdropProgress: Double? = nil
    var backdropStatus: String? = nil
}

// PoiImporter: a named point list beside its editable map. Native gestures
// operate on the draft point set; the source adapter parses shapefiles and
// accepts the completed draft. No raster download or server write is faked.
struct PointImportContent: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var state: DataToolSession
    let importFile: @MainActor (URL) -> Void
    @State private var selected: Set<UUID> = []
    @State private var tool = "Edit POIs"
    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var panOrigin: CGSize?
    @State private var draggingPoint: InterestPoint?
    private var canEdit: Bool { state.presentation.pointImport?.canEdit == true && !state.busy }
    private var bounds: [MapPoint] {
        if let extent = state.presentation.preview.extent { return [extent.lowerLeft, extent.upperRight] }
        return state.presentation.preview.rasters.flatMap(\.points) + state.presentation.preview.vectors.flatMap { $0.layer.points }
            + (state.presentation.pointImport?.points ?? []).map { MapPoint(x: $0.x, y: $0.y) }
    }
    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                HStack {
                    Text("Points of Interest").font(.headline)
                    Spacer()
                    Button { if let file = store.system.choosePointShapefile() { importFile(file) } } label: { Image(systemName: "plus") }.help("Import Shapefile…").disabled(!canEdit)
                }.padding(14)
                List(selection: $selected) {
                    ForEach(state.interestPoints) { point in
                        VStack(alignment: .leading, spacing: 5) {
                            TextField("Name", text: Binding(get: { state.interestPoints.first { $0.id == point.id }?.name ?? point.name }, set: { state.editPoint(point.id, name: $0) }), prompt: Text("(unnamed)"))
                                .textFieldStyle(.plain).disabled(!canEdit)
                            HStack {
                                Text(point.x, format: .number.precision(.fractionLength(0...3)))
                                Text(",")
                                Text(point.y, format: .number.precision(.fractionLength(0...3)))
                                Spacer()
                                if point.serverID != nil { Text("uploaded") }
                            }.font(.caption).foregroundStyle(.secondary)
                        }.tag(point.id)
                    }
                }.onDeleteCommand { state.removePoints(selected); selected = [] }
            }.frame(minWidth: 260, idealWidth: 310, maxWidth: 430)
            map.frame(minWidth: 350)
        }
        .onChange(of: state.interestPoints.map(\.id)) { _, ids in selected.formIntersection(Set(ids)) }
    }
    private var map: some View {
        GeometryReader { geometry in
            let transform = MapTransform(points: bounds, size: geometry.size, scale: scale, offset: offset)
            ZStack {
                Color(nsColor: .textBackgroundColor)
                RasterCanvas(layers: state.presentation.preview.rasters, points: bounds, scale: scale, offset: offset, revision: state.presentation.preview.revision.hashValue)
                Canvas { drawing, _ in
                    for layer in state.presentation.preview.vectors {
                        for feature in layer.layer.features { drawing.stroke(transform.path(feature), with: .color(EditorColor.decode(layer.lineColor)), lineWidth: layer.lineWidth) }
                    }
                    for point in state.interestPoints {
                        let position = transform.screen(MapPoint(x: point.x, y: point.y))
                        drawing.fill(Path(ellipseIn: CGRect(x: position.x - 5, y: position.y - 5, width: 10, height: 10)), with: .color(selected.contains(point.id) ? .orange : .accentColor))
                        drawing.draw(Text(point.name).font(.caption), at: CGPoint(x: position.x + 9, y: position.y - 9), anchor: .leading)
                    }
                }.allowsHitTesting(false)
            }.contentShape(Rectangle()).clipped()
            .simultaneousGesture(SpatialTapGesture().onEnded { value in
                guard tool == "Edit POIs", canEdit else { return }
                if let point = nearest(value.location, transform: transform) { selected = [point.id] }
                else { state.addPoint(transform.world(value.location)) }
            })
            .gesture(DragGesture().onChanged { value in
                if tool == "Pan" {
                    if panOrigin == nil { panOrigin = offset }
                    offset = CGSize(width: (panOrigin?.width ?? 0) + value.translation.width, height: (panOrigin?.height ?? 0) + value.translation.height)
                } else if canEdit {
                    if draggingPoint == nil { draggingPoint = nearest(value.startLocation, transform: transform); if let point = draggingPoint { selected = [point.id] } }
                    if let point = draggingPoint {
                        let origin = transform.screen(MapPoint(x: point.x, y: point.y))
                        state.editPoint(point.id, location: transform.world(CGPoint(x: origin.x + value.translation.width, y: origin.y + value.translation.height)))
                    }
                }
            }.onEnded { _ in panOrigin = nil; draggingPoint = nil })
            .simultaneousGesture(MagnifyGesture().onEnded { scale = min(1e6, max(1e-6, scale * $0.magnification)) })
            .focusable().onDeleteCommand { state.removePoints(selected); selected = [] }
            .overlay(alignment: .topLeading) {
                HStack {
                    Picker("Map Tool", selection: $tool) { Text("Edit POIs").tag("Edit POIs"); Text("Pan").tag("Pan") }.pickerStyle(.segmented).frame(width: 190)
                    Button { state.removePoints(selected); selected = [] } label: { Image(systemName: "trash") }.help("Remove").disabled(!canEdit || selected.isEmpty)
                    Button { scale = 1; offset = .zero } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }.help("Zoom to Full Extent")
                }.padding(10).glassEffect(.regular, in: .capsule).padding(12)
            }
            .overlay(alignment: .bottomLeading) {
                if let status = state.presentation.pointImport?.backdropStatus {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(status).font(.caption)
                        ProgressView(value: state.presentation.pointImport?.backdropProgress)
                    }.padding(12).glassEffect(.regular, in: .rect(cornerRadius: 12)).padding(12)
                }
            }
        }
    }
    private func nearest(_ location: CGPoint, transform: MapTransform) -> InterestPoint? {
        let candidates = state.interestPoints.map { point in
            let position = transform.screen(MapPoint(x: point.x, y: point.y))
            return (point, hypot(position.x - location.x, position.y - location.y))
        }
        return candidates.filter { $0.1 < 14 }.min { $0.1 < $1.1 }?.0
    }
}
