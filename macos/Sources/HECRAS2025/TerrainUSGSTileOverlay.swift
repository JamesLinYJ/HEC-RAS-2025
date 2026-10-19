import Combine
import Foundation
import RASWorkspaceCore
import SwiftUI

struct TerrainUSGSTileOverlayTicket: Equatable, Sendable {
    let ownerID: UUID
    let requestID: UUID
    let projectSessionID: UUID
    let editorID: UUID
    let captureID: String
    let mapID: UUID
    let mapWorkflowIdentity: String
    let terrainAssetPath: String
    let terrainSourceRevision: String
}

struct TerrainUSGSTileOverlaySnapshot: Equatable, Sendable {
    let ticket: TerrainUSGSTileOverlayTicket
    let targetProjectionWkt: String
    let extent: TerrainUSGSQueryExtent
    let products: [TerrainUSGSProduct]
    let selectedProductIDs: Set<String>

    func selecting(_ ids: Set<String>) -> Self {
        Self(ticket: ticket, targetProjectionWkt: targetProjectionWkt, extent: extent,
            products: products, selectedProductIDs: ids.intersection(Set(products.map(\.id))))
    }
}

/// Store-owned publication point for the current, source-backed USGS product
/// overlay. Tickets make late query completions and sheet teardown harmless
/// when another import view has already taken ownership.
@MainActor
final class TerrainUSGSTileOverlaySession: ObservableObject {
    @Published private(set) var snapshot: TerrainUSGSTileOverlaySnapshot?
    private var activeTicket: TerrainUSGSTileOverlayTicket?

    func begin(_ ticket: TerrainUSGSTileOverlayTicket) {
        activeTicket = ticket
        snapshot = nil
    }

    @discardableResult
    func install(_ snapshot: TerrainUSGSTileOverlaySnapshot,
                 matching ticket: TerrainUSGSTileOverlayTicket) -> Bool {
        guard activeTicket == ticket, snapshot.ticket == ticket,
              !snapshot.targetProjectionWkt.isEmpty,
              Set(snapshot.products.map(\.id)).count == snapshot.products.count else { return false }
        self.snapshot = snapshot.selecting(snapshot.selectedProductIDs)
        return true
    }

    func select(_ ids: Set<String>, matching ticket: TerrainUSGSTileOverlayTicket) {
        guard activeTicket == ticket, snapshot?.ticket == ticket else { return }
        snapshot = snapshot?.selecting(ids)
    }

    func clear(matching ticket: TerrainUSGSTileOverlayTicket) {
        guard activeTicket == ticket else { return }
        activeTicket = nil
        snapshot = nil
    }

    func clearAll() {
        activeTicket = nil
        snapshot = nil
    }

    func snapshot(projectSessionID: UUID, mapID: UUID, mapWorkflowIdentity: String,
                  terrainCapture: TerrainRasterExportCapture) -> TerrainUSGSTileOverlaySnapshot? {
        guard let snapshot,
              activeTicket == snapshot.ticket,
              snapshot.ticket.projectSessionID == projectSessionID,
              snapshot.ticket.mapID == mapID,
              snapshot.ticket.mapWorkflowIdentity == mapWorkflowIdentity,
              terrainCapture.asset.section == .terrains,
              snapshot.ticket.editorID == terrainCapture.editorID,
              snapshot.ticket.captureID == terrainCapture.id,
              let sourceRevision = terrainCapture.edits.sourceRevision,
              !sourceRevision.isEmpty else { return nil }
        let expectedPath = SourceFilePaths.canonical(URL(fileURLWithPath: snapshot.ticket.terrainAssetPath))
        guard expectedPath == SourceFilePaths.canonical(terrainCapture.asset.url),
              snapshot.ticket.terrainSourceRevision.caseInsensitiveCompare(sourceRevision) == .orderedSame else {
            return nil
        }
        return snapshot
    }
}

struct TerrainUSGSTileMapHit: Equatable, Sendable {
    let selected: TerrainUSGSProduct
    let overlaps: [TerrainUSGSProduct]
}

enum TerrainUSGSTileHitTest {
    static func hit(at point: MapPoint, products: [TerrainUSGSProduct]) -> TerrainUSGSTileMapHit? {
        guard point.x.isFinite, point.y.isFinite else { return nil }
        let hits = products.compactMap { product -> (TerrainUSGSProduct, Double)? in
            guard let boundary = product.projectedBoundary,
                  let area = polygonArea(boundary), area > 0,
                  contains(point, polygon: boundary) else { return nil }
            return (product, area)
        }.sorted {
            if $0.1 != $1.1 { return $0.1 < $1.1 }
            return $0.0.id < $1.0.id
        }
        guard let selected = hits.first?.0 else { return nil }
        return TerrainUSGSTileMapHit(selected: selected, overlaps: hits.map(\.0))
    }

    static func polygonArea(_ boundary: [TerrainUSGSMapPoint]) -> Double? {
        guard boundary.count >= 3,
              boundary.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
        var twiceArea = 0.0
        for index in boundary.indices {
            let next = boundary[(index + 1) % boundary.count]
            let current = boundary[index]
            twiceArea += current.x * next.y - next.x * current.y
        }
        let area = abs(twiceArea) / 2
        return area.isFinite ? area : nil
    }

    private static func contains(_ point: MapPoint, polygon: [TerrainUSGSMapPoint]) -> Bool {
        var inside = false
        var previous = polygon.count - 1
        for index in polygon.indices {
            let a = polygon[previous]
            let b = polygon[index]
            if liesOnSegment(point, a, b) { return true }
            let crosses = (a.y > point.y) != (b.y > point.y)
            if crosses {
                let crossingX = (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x
                if point.x < crossingX { inside.toggle() }
            }
            previous = index
        }
        return inside
    }

    private static func liesOnSegment(_ point: MapPoint, _ a: TerrainUSGSMapPoint,
                                      _ b: TerrainUSGSMapPoint) -> Bool {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let length = hypot(dx, dy)
        guard length.isFinite else { return false }
        let tolerance = max(length * 1e-10, 1e-12)
        let cross = (point.x - a.x) * dy - (point.y - a.y) * dx
        guard abs(cross) <= tolerance * max(length, 1) else { return false }
        let dot = (point.x - a.x) * dx + (point.y - a.y) * dy
        return dot >= -tolerance && dot <= dx * dx + dy * dy + tolerance
    }
}

/// Root mounts this over the real map canvas and supplies its current world
/// transform and screen pointer. The same projected polygons drive drawing,
/// hit selection, and the overlap tooltip.
struct TerrainUSGSTileMapOverlay: View {
    let snapshot: TerrainUSGSTileOverlaySnapshot
    let points: [MapPoint]
    let scale: CGFloat
    let offset: CGSize
    let pointer: CGPoint?

    var body: some View {
        GeometryReader { proxy in
            let transform = MapTransform(points: points, size: proxy.size, scale: scale, offset: offset)
            ZStack {
                Canvas { context, _ in
                    for product in snapshot.products {
                        guard let boundary = product.projectedBoundary, boundary.count >= 3,
                              boundary.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { continue }
                        var path = Path()
                        let first = transform.screen(MapPoint(x: boundary[0].x, y: boundary[0].y))
                        path.move(to: first)
                        for point in boundary.dropFirst() {
                            path.addLine(to: transform.screen(MapPoint(x: point.x, y: point.y)))
                        }
                        path.closeSubpath()
                        if snapshot.selectedProductIDs.contains(product.id) {
                            context.fill(path, with: .color(.orange.opacity(0.12)))
                            context.stroke(path, with: .color(.orange),
                                style: StrokeStyle(lineWidth: 1.8, dash: [6, 3]))
                        } else {
                            context.stroke(path, with: .color(.cyan.opacity(0.82)), lineWidth: 1)
                        }
                    }
                }
                .allowsHitTesting(false)
                if let pointer,
                   let hit = TerrainUSGSTileHitTest.hit(at: transform.world(pointer), products: snapshot.products) {
                    TerrainUSGSTileMapHitAnnotation(hit: hit, pointer: pointer, canvasSize: proxy.size)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .contain)
    }
}

struct TerrainUSGSTileMapHitAnnotation: View {
    let hit: TerrainUSGSTileMapHit
    let pointer: CGPoint
    let canvasSize: CGSize

    private var otherOverlaps: [TerrainUSGSProduct] {
        hit.overlaps.filter { $0.id != hit.selected.id }
    }
    private var panelHeight: CGFloat { min(280, CGFloat(118 + otherOverlaps.count * 58)) }

    var body: some View {
        if let position = MapToolTipPlacement.position(pointer: pointer, canvasSize: canvasSize,
            panelSize: CGSize(width: 310, height: panelHeight), verticalOffset: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text(hit.selected.title).font(.caption.weight(.semibold)).lineLimit(2)
                LabeledContent(L10n.text("Resolution"), value: hit.selected.resolution)
                if let publicationDate = hit.selected.publicationDate {
                    LabeledContent(L10n.text("Publication Date"), value: publicationDate)
                }
                if let size = hit.selected.sizeInBytes, size >= 0 {
                    LabeledContent(L10n.text("Size"), value: ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                }
                if !otherOverlaps.isEmpty {
                    Divider()
                    Text(L10n.text("Other overlapping products")).font(.caption.weight(.semibold))
                    ScrollView {
                        VStack(alignment: .leading, spacing: 7) {
                            ForEach(otherOverlaps) { product in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(product.title).font(.caption2.weight(.medium)).lineLimit(2)
                                    HStack(spacing: 6) {
                                        Text(product.resolution)
                                        if let publicationDate = product.publicationDate { Text(publicationDate) }
                                        if let bytes = product.sizeInBytes, bytes >= 0 {
                                            Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                                        }
                                    }
                                    .font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 108)
                }
            }
            .padding(9)
            .frame(width: min(310, max(canvasSize.width - 16, 0)), alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(.quaternary, lineWidth: 0.7))
            .position(position)
            .accessibilityElement(children: .combine)
        }
    }
}
