import Foundation
import CoreGraphics
import SwiftUI

/// User placement matches Visual.Mapping.WinUI's serialized OverlayItemSettings.
/// Z-index stays on the live layout input because the source does not persist it.
struct MapOverlayPlacement: Codable, Equatable, Sendable {
    var corner: MapOverlayCorner
    var isCollapsed: Bool
    var stackOrder: Int
    var cornerOffsetX: Double?
    var cornerOffsetY: Double?
    var width: Double?
    var height: Double?

    init(corner: MapOverlayCorner = .bottomRight, isCollapsed: Bool = false,
         stackOrder: Int = -1, cornerOffsetX: Double? = nil,
         cornerOffsetY: Double? = nil, width: Double? = nil, height: Double? = nil) {
        self.corner = corner
        self.isCollapsed = isCollapsed
        self.stackOrder = stackOrder
        if let cornerOffsetX, let cornerOffsetY,
           cornerOffsetX.isFinite, cornerOffsetY.isFinite {
            self.cornerOffsetX = cornerOffsetX
            self.cornerOffsetY = cornerOffsetY
        } else {
            self.cornerOffsetX = nil
            self.cornerOffsetY = nil
        }
        self.width = width.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        self.height = height.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
    }

    /// The source treats a placement as free only when both offsets are finite.
    var isDocked: Bool { cornerOffsetX == nil || cornerOffsetY == nil }

    var pinnedSize: CGSize? {
        guard let width, let height, width.isFinite, height.isFinite else { return nil }
        return CGSize(width: width, height: height)
    }

    var isValid: Bool {
        stackOrder >= -1
            && (cornerOffsetX.map(\.isFinite) ?? true)
            && (cornerOffsetY.map(\.isFinite) ?? true)
            && (width.map { $0.isFinite && $0 > 0 } ?? true)
            && (height.map { $0.isFinite && $0 > 0 } ?? true)
    }
}

/// Field bindings for map chrome that needs to edit individual source
/// placement values while preserving one coherent placement value.
@MainActor
struct MapOverlayPlacementBindings {
    let corner: Binding<MapOverlayCorner>
    let isCollapsed: Binding<Bool>
    let stackOrder: Binding<Int>
    let cornerOffsetX: Binding<Double?>
    let cornerOffsetY: Binding<Double?>
    let width: Binding<Double?>
    let height: Binding<Double?>

    init(_ placement: Binding<MapOverlayPlacement>) {
        corner = placement[dynamicMember: \.corner]
        isCollapsed = placement[dynamicMember: \.isCollapsed]
        stackOrder = placement[dynamicMember: \.stackOrder]
        cornerOffsetX = placement[dynamicMember: \.cornerOffsetX]
        cornerOffsetY = placement[dynamicMember: \.cornerOffsetY]
        width = placement[dynamicMember: \.width]
        height = placement[dynamicMember: \.height]
    }
}

/// App-global, per-key persistence corresponding to RasApplicationData's
/// MapOverlay entry. Each serialized item is decoded independently so one
/// stale or malformed overlay cannot erase the rest of the user's settings.
enum MapOverlayPlacementStore {
    static let defaultsKey = "MapOverlay"

    static func load(_ serializationKey: String,
                     defaults: UserDefaults = .standard) -> MapOverlayPlacement? {
        guard !serializationKey.isEmpty,
              let data = defaults.dictionary(forKey: defaultsKey)?[serializationKey] as? Data,
              let placement = try? JSONDecoder().decode(MapOverlayPlacement.self, from: data),
              placement.isValid else { return nil }
        return placement
    }

    static func save(_ placement: MapOverlayPlacement, for serializationKey: String,
                     defaults: UserDefaults = .standard) {
        guard !serializationKey.isEmpty, placement.isValid,
              let data = try? JSONEncoder().encode(placement) else { return }
        guard var entries = readEntries(defaults) else { return }
        entries[serializationKey] = data
        defaults.set(entries, forKey: defaultsKey)
    }

    static func remove(_ serializationKey: String, defaults: UserDefaults = .standard) {
        guard !serializationKey.isEmpty, var entries = readEntries(defaults) else { return }
        entries.removeValue(forKey: serializationKey)
        defaults.set(entries, forKey: defaultsKey)
    }

    private static func readEntries(_ defaults: UserDefaults) -> [String: Any]? {
        guard defaults.object(forKey: defaultsKey) != nil else { return [:] }
        return defaults.dictionary(forKey: defaultsKey)
    }

}

/// The complete geometry input for one visible source overlay. Inputs are
/// ordered by descending z-index for collision placement; stack order is a
/// separate persistent order among docked overlays sharing a corner.
struct MapOverlayGeometryInput: Equatable, Sendable {
    let id: String
    let placement: MapOverlayPlacement
    let desiredSize: CGSize
    let minimumSize: CGSize
    let maximumSize: CGSize
    let isResizable: Bool
    let zIndex: Int
    let isVisible: Bool

    init(id: String, placement: MapOverlayPlacement, desiredSize: CGSize,
         minimumSize: CGSize = .zero, maximumSize: CGSize = CGSize(width: CGFloat.greatestFiniteMagnitude,
                                                                    height: CGFloat.greatestFiniteMagnitude),
         isResizable: Bool = true, zIndex: Int = 0, isVisible: Bool = true) {
        self.id = id
        self.placement = placement
        self.desiredSize = desiredSize
        self.minimumSize = minimumSize
        self.maximumSize = maximumSize
        self.isResizable = isResizable
        self.zIndex = zIndex
        self.isVisible = isVisible
    }
}

struct MapOverlayGeometryFrame: Equatable, Sendable {
    let id: String
    let frame: CGRect
    let zIndex: Int
    let stackOrder: Int
}

struct MapOverlayStackPlacementChange: Equatable, Sendable {
    let id: String
    let placement: MapOverlayPlacement
}

/// Source-derived corner anchoring, sizing, stack placement and collision
/// handling for map overlays. The original panel uses a 36-point collapsed
/// pill, 4-point stack spacing, 16-point stack snap tolerance and a 32/64-point
/// anchor hysteresis when deriving a corner after a drag.
enum MapOverlayPlacementSolver {
    static let collapsedPillSize = CGSize(width: 36, height: 36)
    static let stackSpacing: CGFloat = 4
    static let snapTolerance: CGFloat = 16

    static func renderingOrder(_ items: [MapOverlayGeometryInput]) -> [MapOverlayGeometryInput] {
        items.enumerated().filter { $0.element.isVisible }
            .sorted {
                if $0.element.zIndex != $1.element.zIndex {
                    return $0.element.zIndex < $1.element.zIndex
                }
                return $0.offset < $1.offset
            }.map { $0.element }
    }

    static func arrange(_ items: [MapOverlayGeometryInput], in canvasSize: CGSize) -> [MapOverlayGeometryFrame] {
        guard canvasSize.width.isFinite, canvasSize.height.isFinite,
              canvasSize.width >= 0, canvasSize.height >= 0 else { return [] }
        let live = items.enumerated().filter { $0.element.isVisible }
        let arranged = live.sorted {
            if $0.element.zIndex != $1.element.zIndex {
                return $0.element.zIndex > $1.element.zIndex
            }
            return $0.offset < $1.offset
        }
        var placed: [(MapOverlayGeometryInput, CGRect)] = []
        for (_, item) in arranged {
            guard item.placement.isValid, !item.id.isEmpty else { continue }
            let size = footprint(of: item)
            let desired = initialFrame(for: item, size: size,
                                       allItems: live.map { $0.element }, canvasSize: canvasSize)
            let clamped = clamp(desired, to: canvasSize, corner: item.placement.corner)
            let resolved = resolveOverlap(clamped, fallback: clamped, delta: .zero,
                                          occupied: placed.map { $0.1 }, canvasSize: canvasSize,
                                          corner: item.placement.corner)
            placed.append((item, resolved))
        }
        return placed.map { item, frame in
            MapOverlayGeometryFrame(id: item.id, frame: frame,
                                    zIndex: item.zIndex, stackOrder: item.placement.stackOrder)
        }
    }

    static func footprint(of item: MapOverlayGeometryInput) -> CGSize {
        if item.placement.isCollapsed { return collapsedPillSize }
        if item.isResizable, let pinned = item.placement.pinnedSize {
            return resized(pinned, by: .zero, minimum: item.minimumSize, maximum: item.maximumSize)
        }
        return finiteSize(item.desiredSize)
    }

    static func resized(_ size: CGSize, by delta: CGSize,
                        minimum: CGSize, maximum: CGSize) -> CGSize {
        CGSize(width: clampExtent(size.width + delta.width, minimum: minimum.width, maximum: maximum.width),
               height: clampExtent(size.height + delta.height, minimum: minimum.height, maximum: maximum.height))
    }

    /// Converts a drag into the source's corner plus two anchored offsets.
    /// Peers are the currently visible overlay items, not all saved settings.
    static func moved(_ item: MapOverlayGeometryInput, by delta: CGSize,
                      in canvasSize: CGSize, peers: [MapOverlayGeometryInput] = []) -> MapOverlayPlacement {
        guard delta.width.isFinite, delta.height.isFinite,
              canvasSize.width.isFinite, canvasSize.height.isFinite else { return item.placement }
        let size = footprint(of: item)
        let start = arrange([item] + peers, in: canvasSize)
            .first(where: { $0.id == item.id })?.frame
            ?? initialFrame(for: item, size: size, allItems: [item] + peers,
                            canvasSize: canvasSize)
        let desired = clamp(start.offsetBy(dx: delta.width, dy: delta.height),
                            to: canvasSize, corner: item.placement.corner)
        let occupiedFrames = arrange(peers, in: canvasSize).map { $0.frame }
        let resolved = resolveOverlap(desired, fallback: clamp(start, to: canvasSize, corner: item.placement.corner),
                                      delta: delta, occupied: occupiedFrames,
                                      canvasSize: canvasSize, corner: item.placement.corner)
        let corner = deriveCorner(resolved, canvasSize: canvasSize, current: item.placement.corner)
        var result = item.placement
        result.corner = corner
        let offset = anchorOffset(resolved, corner: corner, canvasSize: canvasSize)
        let dropOffset = anchorOffset(desired, corner: corner, canvasSize: canvasSize)

        let dropSlot = nearestStackSlotIndex(for: item, corner: corner, dropOffset: dropOffset.y,
                                             peers: peers)
        let finalSlot = nearestStackSlotIndex(for: item, corner: corner, dropOffset: offset.y,
                                              peers: peers)
        if (abs(dropOffset.x) <= snapTolerance || abs(offset.x) <= snapTolerance),
           let slot = dropSlot ?? finalSlot {
            result.cornerOffsetX = nil
            result.cornerOffsetY = nil
            result.stackOrder = slot
        } else {
            result.cornerOffsetX = Double(offset.x)
            result.cornerOffsetY = Double(offset.y)
        }
        return result
    }

    static func previewFrame(for item: MapOverlayGeometryInput, by delta: CGSize,
                             in canvasSize: CGSize,
                             peers: [MapOverlayGeometryInput] = []) -> CGRect? {
        guard delta.width.isFinite, delta.height.isFinite,
              let start = arrange([item] + peers, in: canvasSize).first(where: { $0.id == item.id })?.frame
        else { return nil }
        let desired = clamp(start.offsetBy(dx: delta.width, dy: delta.height),
                            to: canvasSize, corner: item.placement.corner)
        return resolveOverlap(desired, fallback: clamp(start, to: canvasSize, corner: item.placement.corner),
                              delta: delta, occupied: arrange(peers, in: canvasSize).map { $0.frame },
                              canvasSize: canvasSize, corner: item.placement.corner)
    }

    static func nearestCorner(for frame: CGRect, in canvasSize: CGSize,
                              current: MapOverlayCorner) -> MapOverlayCorner {
        deriveCorner(frame, canvasSize: canvasSize, current: current)
    }

    static func docked(_ placement: MapOverlayPlacement, at corner: MapOverlayCorner,
                       nextStackOrder: Int) -> MapOverlayPlacement {
        var result = placement
        result.corner = corner
        result.cornerOffsetX = nil
        result.cornerOffsetY = nil
        result.stackOrder = max(nextStackOrder, 0)
        return result
    }

    /// Reindexes a docked corner after a menu move or stack snap. The caller
    /// persists each returned placement under the corresponding stable source
    /// serialization key, matching MapElementsOverlay.InsertIntoStack.
    static func insertingIntoStack(_ item: MapOverlayGeometryInput, at index: Int,
                                   corner: MapOverlayCorner,
                                   peers: [MapOverlayGeometryInput]) -> [MapOverlayStackPlacementChange] {
        let stackedPeers = peers.enumerated().filter {
            $0.element.id != item.id && $0.element.isVisible
                && $0.element.placement.corner == corner && $0.element.placement.isDocked
        }.sorted {
            if $0.element.placement.stackOrder != $1.element.placement.stackOrder {
                return $0.element.placement.stackOrder < $1.element.placement.stackOrder
            }
            return $0.offset < $1.offset
        }.map(\.element)
        var ordered = stackedPeers
        ordered.insert(item, at: min(max(index, 0), ordered.count))
        return ordered.enumerated().compactMap { order, value in
            var placement = value.id == item.id ? item.placement : value.placement
            placement.corner = corner
            placement.cornerOffsetX = nil
            placement.cornerOffsetY = nil
            placement.stackOrder = order
            return placement.isValid
                ? MapOverlayStackPlacementChange(id: value.id, placement: placement) : nil
        }
    }

    private static func initialFrame(for item: MapOverlayGeometryInput, size: CGSize,
                                     allItems: [MapOverlayGeometryInput], canvasSize: CGSize) -> CGRect {
        let placement = item.placement
        let xOffset: CGFloat
        let yOffset: CGFloat
        if !placement.isDocked, let x = placement.cornerOffsetX, let y = placement.cornerOffsetY {
            xOffset = CGFloat(x)
            yOffset = CGFloat(y)
        } else {
            xOffset = 0
            yOffset = stackOffset(for: item, allItems: allItems)
        }
        let x: CGFloat
        switch placement.corner.horizontalAnchor {
        case .left: x = xOffset
        case .center: x = (canvasSize.width - size.width) / 2 + xOffset
        case .right: x = canvasSize.width - xOffset - size.width
        }
        let y = placement.corner.isTop ? yOffset : canvasSize.height - yOffset - size.height
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    private static func stackOffset(for item: MapOverlayGeometryInput,
                                    allItems: [MapOverlayGeometryInput]) -> CGFloat {
        allItems.filter {
            $0.id != item.id && $0.isVisible && $0.placement.corner == item.placement.corner
                && $0.placement.isDocked && precedes($0, item, in: allItems)
        }.reduce(0) { $0 + footprint(of: $1).height + stackSpacing }
    }

    private static func precedes(_ lhs: MapOverlayGeometryInput, _ rhs: MapOverlayGeometryInput,
                                 in items: [MapOverlayGeometryInput]) -> Bool {
        let left = lhs.placement.stackOrder
        let right = rhs.placement.stackOrder
        if left != right { return left < right }
        guard let lhsIndex = items.firstIndex(where: { $0.id == lhs.id }),
              let rhsIndex = items.firstIndex(where: { $0.id == rhs.id }) else { return false }
        return lhsIndex < rhsIndex
    }

    private static func nearestStackSlotIndex(for item: MapOverlayGeometryInput,
                                              corner: MapOverlayCorner, dropOffset: CGFloat,
                                              peers: [MapOverlayGeometryInput]) -> Int? {
        let stacked = peers.filter {
            $0.isVisible && $0.id != item.id && $0.placement.corner == corner && $0.placement.isDocked
        }.sorted {
            if $0.placement.stackOrder != $1.placement.stackOrder {
                return $0.placement.stackOrder < $1.placement.stackOrder
            }
            return $0.id < $1.id
        }
        var offsets: [CGFloat] = [0]
        for peer in stacked { offsets.append(offsets[offsets.count - 1] + footprint(of: peer).height + stackSpacing) }
        guard let nearest = offsets.indices.min(by: {
            abs(offsets[$0] - dropOffset) < abs(offsets[$1] - dropOffset)
        }), abs(offsets[nearest] - dropOffset) <= snapTolerance else { return nil }
        return nearest
    }

    private static func anchorOffset(_ frame: CGRect, corner: MapOverlayCorner,
                                     canvasSize: CGSize) -> CGPoint {
        let x: CGFloat
        switch corner.horizontalAnchor {
        case .left: x = max(0, frame.minX)
        case .center: x = frame.minX - (canvasSize.width - frame.width) / 2
        case .right: x = max(0, canvasSize.width - frame.maxX)
        }
        let y = max(0, corner.isTop ? frame.minY : canvasSize.height - frame.maxY)
        return CGPoint(x: x, y: y)
    }

    private static func deriveCorner(_ frame: CGRect, canvasSize: CGSize,
                                     current: MapOverlayCorner) -> MapOverlayCorner {
        let leading = frame.minX
        let trailing = canvasSize.width - frame.maxX
        let horizontalSlack: CGFloat = current.horizontalAnchor == .center ? 64 : 32
        let horizontal: MapOverlayCorner.HorizontalAnchor
        if abs(leading - trailing) <= horizontalSlack { horizontal = .center }
        else { horizontal = leading < trailing ? .left : .right }
        let topGap = frame.minY
        let bottomGap = canvasSize.height - frame.maxY
        let isTop = abs(topGap - bottomGap) <= 32 ? current.isTop : topGap < bottomGap
        return MapOverlayCorner.from(horizontal: horizontal, isTop: isTop)
    }

    private static func resolveOverlap(_ target: CGRect, fallback: CGRect, delta: CGSize,
                                       occupied: [CGRect], canvasSize: CGSize,
                                       corner: MapOverlayCorner) -> CGRect {
        guard let overlap = occupied.first(where: { strictlyIntersects(target, $0) }) else { return target }
        let left = CGRect(x: overlap.minX - target.width, y: target.minY,
                          width: target.width, height: target.height)
        let right = CGRect(x: overlap.maxX, y: target.minY,
                           width: target.width, height: target.height)
        let above = CGRect(x: target.minX, y: overlap.minY - target.height,
                           width: target.width, height: target.height)
        let below = CGRect(x: target.minX, y: overlap.maxY,
                           width: target.width, height: target.height)
        let horizontalFirst = abs(delta.width) >= abs(delta.height)
        let candidates: [CGRect] = [
            horizontalFirst ? (delta.width >= 0 ? left : right) : (delta.height >= 0 ? above : below),
            horizontalFirst ? (delta.height >= 0 ? above : below) : (delta.width >= 0 ? left : right),
            horizontalFirst ? (delta.width >= 0 ? right : left) : (delta.height >= 0 ? below : above),
            horizontalFirst ? (delta.height >= 0 ? below : above) : (delta.width >= 0 ? right : left)
        ]
        let available = candidates.map { clamp($0, to: canvasSize, corner: corner) }
            .filter { candidate in !occupied.contains(where: { strictlyIntersects(candidate, $0) }) }
        return available.min {
            originDistanceSquared(target, $0) < originDistanceSquared(target, $1)
        } ?? fallback
    }

    private static func clamp(_ frame: CGRect, to canvasSize: CGSize,
                              corner: MapOverlayCorner) -> CGRect {
        CGRect(x: clampAxis(frame.minX, extent: frame.width, available: canvasSize.width,
                            isLeading: corner.horizontalAnchor == .left,
                            isCentered: corner.horizontalAnchor == .center),
               y: clampAxis(frame.minY, extent: frame.height, available: canvasSize.height,
                            isLeading: corner.isTop, isCentered: false),
               width: frame.width, height: frame.height)
    }

    private static func clampAxis(_ position: CGFloat, extent: CGFloat, available: CGFloat,
                                  isLeading: Bool, isCentered: Bool) -> CGFloat {
        let availableAboveExtent = available - extent
        if isCentered {
            return availableAboveExtent < 0 ? availableAboveExtent / 2
                : min(max(position, 0), availableAboveExtent)
        }
        let minimum = isLeading ? 0 : min(0, availableAboveExtent)
        let maximum = isLeading ? max(0, availableAboveExtent) : availableAboveExtent
        return min(max(position, minimum), maximum)
    }

    private static func clampExtent(_ value: CGFloat, minimum: CGFloat, maximum: CGFloat) -> CGFloat {
        let low = minimum.isFinite ? max(minimum, 0) : 0
        let high = maximum.isFinite ? max(maximum, low) : .greatestFiniteMagnitude
        return min(max(value.isFinite ? value : low, low), high)
    }

    private static func finiteSize(_ size: CGSize) -> CGSize {
        CGSize(width: size.width.isFinite ? max(size.width, 0) : 0,
               height: size.height.isFinite ? max(size.height, 0) : 0)
    }

    private static func strictlyIntersects(_ a: CGRect, _ b: CGRect) -> Bool {
        max(a.minX, b.minX) < min(a.maxX, b.maxX)
            && max(a.minY, b.minY) < min(a.maxY, b.maxY)
    }

    private static func originDistanceSquared(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let x = a.minX - b.minX, y = a.minY - b.minY
        return x * x + y * y
    }
}
