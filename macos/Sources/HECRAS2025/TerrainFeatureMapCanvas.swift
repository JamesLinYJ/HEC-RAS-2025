import RASWorkspaceCore
import SwiftUI

struct TerrainMapPolygon: Identifiable, Sendable {
    let id: String
    let tableId: String
    let rings: [[TerrainMapCoordinate]]

    var selectionFeature: TerrainMapFeature {
        TerrainMapFeature(id: id, tableId: tableId, points: rings.first ?? [], kind: "region")
    }
}

struct TerrainFeatureMapCanvas: View {
    let rasters: [MapRasterLayer]
    let features: [TerrainMapFeature]
    var polygons: [TerrainMapPolygon] = []
    let selectedRowIDs: Set<String>
    let loading: Bool
    let onSelect: (TerrainMapFeature) -> Void
    var onMapClick: ((TerrainMapCoordinate, Double) -> Void)? = nil
    @State private var scale: CGFloat = 1
    @State private var offset = CGSize.zero
    @GestureState private var drag = CGSize.zero

    private var points: [MapPoint] {
        rasters.flatMap(\.points)
            + features.flatMap { $0.points.map { MapPoint(x: $0.x, y: $0.y) } }
            + polygons.flatMap(\.rings).flatMap { $0.map { MapPoint(x: $0.x, y: $0.y) } }
    }

    var body: some View {
        GeometryReader { proxy in
            let currentOffset = CGSize(width: offset.width + drag.width, height: offset.height + drag.height)
            let transform = MapTransform(points: points, size: proxy.size, scale: scale, offset: currentOffset)
            ZStack {
                Color(nsColor: .textBackgroundColor)
                RasterCanvas(layers: rasters, points: points, scale: scale, offset: currentOffset,
                    revision: stableRevision)
                Canvas { context, _ in
                    for polygon in polygons {
                        let path = transform.path(MapFeature(id: 0, kind: .polygon,
                            paths: polygon.rings.map { $0.map { MapPoint(x: $0.x, y: $0.y) } }, attributes: [:]))
                        let selected = selectedRowIDs.contains(polygon.id)
                        context.fill(path, with: .color(selected ? Color.orange.opacity(0.24) : Color.purple.opacity(0.12)),
                                     style: FillStyle(eoFill: true))
                        context.stroke(path, with: .color(selected ? .orange : .purple),
                                       style: StrokeStyle(lineWidth: selected ? 3 : 1.5))
                    }
                    for (index, feature) in features.enumerated() {
                        let selected = selectedRowIDs.contains(feature.id)
                        if feature.kind == "node" || feature.kind == "controlPoint"
                            || feature.kind == "draft" && feature.points.count == 1 {
                            guard let point = feature.points.first else { continue }
                            let center = transform.screen(MapPoint(x: point.x, y: point.y))
                            let radius: CGFloat = feature.kind == "node" ? 5.5 : feature.kind == "draft" ? 4.5 : 4
                            let marker = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius,
                                                              width: radius * 2, height: radius * 2))
                            let color: Color = feature.kind == "draft" ? .orange : selected ? .orange : .blue
                            context.fill(marker, with: .color(selected ? .orange : .white))
                            context.stroke(marker, with: .color(color), lineWidth: 1.5)
                        } else if feature.points.count >= 2 {
                            let mapFeature = MapFeature(id: index, kind: .line,
                                paths: [feature.points.map { MapPoint(x: $0.x, y: $0.y) }], attributes: [:])
                            let path = transform.path(mapFeature)
                            context.stroke(path,
                                with: .color(feature.kind == "draft" ? .orange : selected ? .orange : .blue),
                                style: StrokeStyle(lineWidth: selected || feature.kind == "draft" ? 4 : 2,
                                                   lineCap: .round, lineJoin: .round,
                                                   dash: feature.kind == "draft" ? [6, 4] : []))
                            for point in [feature.points.first, feature.points.last].compactMap({ $0 }) {
                                let center = transform.screen(MapPoint(x: point.x, y: point.y))
                                let marker = Path(ellipseIn: CGRect(x: center.x - 3.5, y: center.y - 3.5,
                                                                  width: 7, height: 7))
                                context.fill(marker, with: .color(selected ? .orange : .white))
                                context.stroke(marker, with: .color(selected ? .orange : .blue), lineWidth: 1.5)
                            }
                        }
                    }
                }
                .allowsHitTesting(false)
                if rasters.isEmpty && features.isEmpty && polygons.isEmpty && !loading {
                    ContentUnavailableView("No terrain preview available", systemImage: "map")
                }
                if loading { ProgressView().controlSize(.large) }
            }
            .contentShape(Rectangle())
            .clipped()
            .simultaneousGesture(SpatialTapGesture().onEnded { value in
                if let onMapClick {
                    if let feature = feature(at: value.location, transform: transform) { onSelect(feature) }
                    let world = transform.world(value.location)
                    let cellSize = 1 / Double(transform.factor)
                    guard world.x.isFinite, world.y.isFinite, cellSize.isFinite, cellSize > 0 else { return }
                    onMapClick(.init(x: world.x, y: world.y), cellSize)
                } else {
                    selectFeature(at: value.location, transform: transform)
                }
            })
            .simultaneousGesture(DragGesture().updating($drag) { value, state, _ in
                state = value.translation
            }.onEnded { value in
                offset.width += value.translation.width
                offset.height += value.translation.height
            })
            .simultaneousGesture(MagnifyGesture().onEnded { value in
                scale = min(1_000_000, max(0.000_001, scale * value.magnification))
            })
            .overlay(alignment: .topTrailing) {
                HStack(spacing: 14) {
                    Button { scale = min(1_000_000, scale * 1.3) } label: {
                        Image(systemName: "plus.magnifyingglass")
                    }.help("Zoom In")
                    Button { scale = max(0.000_001, scale / 1.3) } label: {
                        Image(systemName: "minus.magnifyingglass")
                    }.help("Zoom Out")
                    Button { scale = 1; offset = .zero } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                    }.help("Zoom to Full Extent")
                }
                .buttonStyle(.borderless)
                .padding(12)
                .glassEffect(.regular, in: .capsule)
                .padding(12)
                .disabled(points.isEmpty)
            }
            .overlay(alignment: .bottomLeading) {
                if !features.isEmpty || !polygons.isEmpty {
                    HStack(spacing: 12) {
                        Label("Terrain Feature", systemImage: "point.3.connected.trianglepath.dotted")
                            .foregroundStyle(.blue)
                        Label("Selected", systemImage: "line.diagonal")
                            .foregroundStyle(.orange)
                    }
                    .font(.caption)
                    .padding(9)
                    .glassEffect(.regular, in: .rect(cornerRadius: 9))
                    .padding(10)
                }
            }
        }
        .onChange(of: stableRevision) { _, _ in
            scale = 1
            offset = .zero
        }
    }

    private var stableRevision: Int {
        var hasher = Hasher()
        for raster in rasters {
            hasher.combine(raster.id)
            hasher.combine(raster.rgba.count)
            for point in raster.points {
                hasher.combine(point.x)
                hasher.combine(point.y)
            }
        }
        for feature in features {
            hasher.combine(feature.id)
            hasher.combine(feature.kind)
            hasher.combine(feature.points.count)
            for point in feature.points {
                hasher.combine(point.x)
                hasher.combine(point.y)
            }
        }
        for polygon in polygons {
            hasher.combine(polygon.id)
            for ring in polygon.rings {
                hasher.combine(ring.count)
                for point in ring {
                    hasher.combine(point.x)
                    hasher.combine(point.y)
                }
            }
        }
        return hasher.finalize()
    }

    private func selectFeature(at location: CGPoint, transform: MapTransform) {
        guard let feature = feature(at: location, transform: transform) else { return }
        onSelect(feature)
    }

    private func feature(at location: CGPoint, transform: MapTransform) -> TerrainMapFeature? {
        for feature in features.reversed() {
            if feature.kind == "node" || feature.kind == "controlPoint" {
                guard let point = feature.points.first else { continue }
                let center = transform.screen(MapPoint(x: point.x, y: point.y))
                if hypot(location.x - center.x, location.y - center.y) <= (feature.kind == "node" ? 10 : 8) {
                    return feature
                }
                continue
            }
            guard feature.points.count >= 2 else { continue }
            let mapFeature = MapFeature(id: 0, kind: .line,
                paths: [feature.points.map { MapPoint(x: $0.x, y: $0.y) }], attributes: [:])
            let hitPath = transform.path(mapFeature).strokedPath(
                StrokeStyle(lineWidth: 12, lineCap: .round, lineJoin: .round))
            if hitPath.contains(location) {
                return feature
            }
        }
        // Topology.HitTestRegion walks the source spatial-index candidates in
        // ascending region order. Keep this order when completed regions
        // overlap; even-odd fill excludes every source inner ring.
        for polygon in polygons {
            let path = transform.path(MapFeature(id: 0, kind: .polygon,
                paths: polygon.rings.map { $0.map { MapPoint(x: $0.x, y: $0.y) } }, attributes: [:]))
            if path.contains(location, eoFill: true) { return polygon.selectionFeature }
        }
        return nil
    }
}
