import Combine
import RASWorkspaceCore
import SwiftUI

struct MapDynamicProfileMarker: Identifiable, Equatable {
    let id: String
    let point: MapPoint
}

enum MapDynamicProfileLineGeometry {
    static func point(on points: [GeometryTopologyCoordinate], stations: [Double], distance: Double) -> MapPoint? {
        guard points.count >= 2, stations.count == points.count, stations.first == 0,
              distance.isFinite, distance >= 0, distance <= (stations.last ?? -1),
              stations.allSatisfy({ $0.isFinite && $0 >= 0 }),
              zip(stations, stations.dropFirst()).allSatisfy({ $0 <= $1 }),
              points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
        for index in 1..<points.count {
            let start = stations[index - 1], end = stations[index]
            if end > start, distance >= start, distance <= end {
                let t = (distance - start) / (end - start)
                let a = points[index - 1], b = points[index]
                return MapPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
            }
        }
        if distance == stations.last, let last = points.last { return MapPoint(x: last.x, y: last.y) }
        return nil
    }
    /// Mirrors Polyline.PointAtDistance: outside the line is a missing point,
    /// rather than a clamped endpoint or a point on another selected line.
    static func point(on points: [GeometryTopologyCoordinate], distance: Double) -> MapPoint? {
        guard points.count >= 2, distance.isFinite, distance >= 0,
              points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
        var cumulative = 0.0
        for (a, b) in zip(points, points.dropFirst()) {
            let length = hypot(b.x - a.x, b.y - a.y)
            guard length.isFinite else { return nil }
            let end = cumulative + length
            guard end.isFinite else { return nil }
            if length > 0, distance >= cumulative, distance <= end {
                let t = (distance - cumulative) / length
                return MapPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
            }
            cumulative = end
        }
        if distance == cumulative, let last = points.last { return MapPoint(x: last.x, y: last.y) }
        return nil
    }
}

@MainActor
final class MapDynamicProfileOverlaySession: ObservableObject {
    @Published private(set) var markers: [MapDynamicProfileMarker] = []
    private var owner: UUID?
    private var lines: [MapDynamicProfileLine] = []
    private var sourceStations: [String: [Double]] = [:]

    func install(owner: UUID, lines: [MapDynamicProfileLine], distancesByID: [String: [Double]] = [:]) {
        guard self.owner != owner || self.lines != lines || sourceStations != distancesByID else { return }
        self.owner = owner
        self.lines = lines
        sourceStations = distancesByID
        markers = []
    }

    func move(owner: UUID, distance: Double?) {
        guard self.owner == owner else { return }
        markers = distance.map { value in
            lines.compactMap { line in
                let point: MapPoint?
                if let stations = sourceStations[line.id] {
                    point = MapDynamicProfileLineGeometry.point(on: line.points,
                        stations: stations, distance: value)
                } else {
                    point = MapDynamicProfileLineGeometry.point(on: line.points, distance: value)
                }
                return point.map { MapDynamicProfileMarker(id: line.id, point: $0) }
            }
        } ?? []
    }

    func clear(owner: UUID? = nil) {
        guard owner == nil || self.owner == owner else { return }
        self.owner = nil
        lines = []
        sourceStations = [:]
        markers = []
    }
}

struct MapDynamicProfileOverlayCanvas: View {
    @ObservedObject var session: MapDynamicProfileOverlaySession
    @ObservedObject var mapState: MapState
    let points: [MapPoint]
    let scale: CGFloat
    let offset: CGSize

    var body: some View {
        Canvas { context, size in
            let transform = MapTransform(points: points, size: size, scale: scale, offset: offset)
            for marker in session.markers {
                let position = transform.screen(marker.point)
                guard position.x.isFinite, position.y.isFinite else { continue }
                context.fill(Path(ellipseIn: CGRect(x: position.x - 4, y: position.y - 4,
                    width: 8, height: 8)), with: .color(.red))
                context.fill(Path(ellipseIn: CGRect(x: position.x - 3, y: position.y - 3,
                    width: 6, height: 6)), with: .color(Color(red: 0.55, green: 0, blue: 0)))
            }
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}
