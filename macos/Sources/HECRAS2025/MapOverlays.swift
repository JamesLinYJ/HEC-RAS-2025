import RASWorkspaceCore
import SwiftUI

struct MapLegend: Identifiable, Sendable {
    struct Stop: Identifiable, Sendable {
        let id: String
        let position: Double
        let color: String
        let label: String
    }
    let id: String // Original layer identity, not a translated label.
    let title: String
    let units: String
    let stops: [Stop] // Adapter supplies actual palette stops and formatted values.
}

// RasMapLegend's palette, tick labels and context units, using system glass.
struct MapLegendView: View {
    let legend: MapLegend
    var size = CGSize(width: 164, height: 190)
    private var stops: [MapLegend.Stop] {
        legend.stops.filter { $0.position.isFinite && (0...1).contains($0.position) }.sorted { $0.position < $1.position }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(legend.title).font(.headline).lineLimit(2)
            if !legend.units.isEmpty { Text("(\(legend.units))").font(.caption).foregroundStyle(.secondary) }
            GeometryReader { geometry in
                HStack(spacing: 8) {
                    Rectangle().fill(LinearGradient(stops: stops.map { .init(color: EditorColor.decode($0.color), location: $0.position) }, startPoint: .bottom, endPoint: .top)).frame(width: 18)
                    ZStack(alignment: .topLeading) {
                        ForEach(stops) { stop in
                            Text(stop.label).font(.caption).monospacedDigit().offset(y: (1 - stop.position) * max(geometry.size.height - 14, 1))
                        }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }.frame(maxHeight: .infinity)
        }.padding(12).frame(width: size.width, height: size.height).accessibilityElement(children: .contain).accessibilityLabel("Map Legend")
    }
}

// RasMapMinimap: true layer extents, current viewport, and click/drag recenter.
struct MapMinimap: View {
    @ObservedObject private var renderScaling = WorkspaceRenderScaling.shared
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var mapState: MapState
    var size = CGSize(width: 180, height: 120)
    private var points: [MapPoint] { mapState.transformPoints(vectors: store.mapLayers, rasters: store.rasterLayers) }
    var body: some View {
        GeometryReader { geometry in
            let renderScale = renderScaling.factor
            let transform = MapTransform(points: points, size: geometry.size, scale: 1, offset: .zero)
            ZStack {
                Color(nsColor: .textBackgroundColor)
                RasterMapCanvas(store: store, mapState: mapState, scale: 1, offset: .zero)
                ProjectGeometryMapCanvas(store: store, mapState: mapState,
                    session: mapState.projectGeometryMap, mapID: mapState.id,
                    scale: 1, offset: .zero, isInteractive: false)
                Canvas { context, _ in
                    for layer in mapState.visibleVectors(store.mapLayers) {
                        for feature in layer.features {
                            let definitionID = MapVectorStyleDefinitionIDs.primaryDefinition(for: feature.kind)
                            let style = MapVectorStyleResolver.values(layerID: layer.id, feature: feature,
                                definitionID: definitionID, presentations: mapState.vectorStyles)
                            let pointDiameter = WorkspaceRenderScaling.metric(
                                Double(VectorMapCanvas.safePointDiameter(style.pointSize)), factor: renderScale)
                            let path = transform.path(feature, pointDiameter: pointDiameter)
                            let pen = MapVectorStyleResolver.penColor(style, definitionID: definitionID)
                            let fill = MapVectorStyleResolver.fillColor(style, definitionID: definitionID)
                            if feature.kind == .polygon { context.fill(path, with: .color(fill), style: FillStyle(eoFill: true)) }
                            if feature.kind == .point { context.fill(path, with: .color(fill)) }
                            context.stroke(path, with: .color(pen), lineWidth: WorkspaceRenderScaling.metric(
                                Double(VectorMapCanvas.safeLineWidth(style.penWidth)), factor: renderScale))

                            if let vertexDefinitionID = MapVectorStyleDefinitionIDs.vertexDefinition(for: feature.kind) {
                                let vertexStyle = MapVectorStyleResolver.values(layerID: layer.id, feature: feature,
                                    definitionID: vertexDefinitionID, presentations: mapState.vectorStyles)
                                let vertexPaths = feature.kind == .polygon
                                    ? feature.paths.map { points in points.first == points.last ? Array(points.dropLast()) : points }
                                    : feature.paths
                                let vertices = transform.verticesPath(vertexPaths,
                                    diameter: WorkspaceRenderScaling.metric(
                                        Double(VectorMapCanvas.safePointDiameter(vertexStyle.pointSize)), factor: renderScale))
                                context.fill(vertices, with: .color(MapVectorStyleResolver.fillColor(vertexStyle, definitionID: vertexDefinitionID)))
                                context.stroke(vertices, with: .color(MapVectorStyleResolver.penColor(vertexStyle, definitionID: vertexDefinitionID)),
                                    lineWidth: WorkspaceRenderScaling.metric(
                                        Double(VectorMapCanvas.safeLineWidth(vertexStyle.penWidth)), factor: renderScale))
                            }
                        }
                    }
                    if let extent = mapState.currentExtent {
                        let upperLeft = transform.screen(MapPoint(x: extent.lowerLeft.x, y: extent.upperRight.y))
                        let lowerRight = transform.screen(MapPoint(x: extent.upperRight.x, y: extent.lowerLeft.y))
                        let rect = CGRect(x: upperLeft.x, y: upperLeft.y, width: lowerRight.x - upperLeft.x, height: lowerRight.y - upperLeft.y)
                        let path = Path(rect)
                        context.fill(path, with: .color(.accentColor.opacity(0.12)))
                        context.stroke(path, with: .color(.accentColor), lineWidth: 2)
                    }
                }
            }.clipped().contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { value in recenter(value.location, transform: transform) })
                .accessibilityLabel("Map Overview").help("Click or drag to move the map")
        }.frame(width: size.width, height: size.height).clipShape(RoundedRectangle(cornerRadius: 8))
    }
    private func recenter(_ location: CGPoint, transform: MapTransform) {
        guard let extent = mapState.currentExtent else { return }
        let dataLower = MapPoint(x: points.map(\.x).min() ?? 0, y: points.map(\.y).min() ?? 0)
        let dataUpper = MapPoint(x: points.map(\.x).max() ?? 1, y: points.map(\.y).max() ?? 1)
        let width = extent.upperRight.x - extent.lowerLeft.x, height = extent.upperRight.y - extent.lowerLeft.y
        if width * height >= (dataUpper.x - dataLower.x) * (dataUpper.y - dataLower.y) {
            mapState.resetViewport(); return
        }
        let center = transform.world(location)
        mapState.viewport = ViewportRequest(lowerLeft: MapPoint(x: center.x - width / 2, y: center.y - height / 2), upperRight: MapPoint(x: center.x + width / 2, y: center.y + height / 2))
    }
}

enum VectorStyle {
    static func color(_ index: Int) -> Color { [.blue, .green, .purple, .orange, .teal][index % 5] }
}
