import AppKit
import CryptoKit
import Foundation
import RASWorkspaceCore
import SwiftUI

/// Captures a context action against one exact persisted MapLayer instance.
/// The menu owns the values it displayed, while every action re-resolves this
/// capture before mutating or reading source data.
struct MapVectorFeatureContextSnapshot: Sendable {
    let projectSessionID: UUID
    let mapID: UUID
    let contextIdentity: String
    let mapWorkflowIdentity: String
    let layer: MapVectorLayer
    let clickedFeatureIdentity: String
    let selectedFeatureIdentities: [String]
    let selectedFeatures: [MapFeature]
    let editorCanDeleteSelectedFeatures: Bool
    let editorCanUndo: Bool
    let editorCanRedo: Bool
    let editorCanSave: Bool
    let canPasteCopiedLines: Bool

    var canonicalSourcePath: String { SourceFilePaths.canonical(layer.url) }
    var sourceRevision: String? { layer.sourceRevision }
    var focusRowID: String? {
        (selectedFeatures.first(where: { $0.stableIdentity == clickedFeatureIdentity })?.sourceFeatureIndex
            ?? selectedFeatures.compactMap(\.sourceFeatureIndex).min()).map { "feature/\($0)" }
    }
    var selectedLinePathIdentities: Set<String> {
        Set(selectedFeatures.filter { $0.kind == .line }.flatMap(\.pathStableIdentities))
    }
    var isShapefile: Bool { layer.url.pathExtension.lowercased() == "shp" }
    var hasSelectedLines: Bool { selectedFeatures.contains { $0.kind == .line } }
}

struct MapVectorFeatureHit: Equatable {
    let layerID: String
    let featureIdentity: String
    let distance: CGFloat
}

/// Geometry hit distance is measured after the current map transform, in
/// logical screen points. This keeps the eight-point target stable while the
/// user zooms and avoids selecting a nearby object just because its world-unit
/// coordinate happens to be close.
enum MapVectorFeatureHitTester {
    static func closestFeature(at location: CGPoint, transform: MapTransform,
                               layers: [MapVectorLayer], tolerance: CGFloat = 8,
                               lineWidth: (MapVectorLayer, MapFeature) -> CGFloat = { _, _ in 0 },
                               pointDiameter: (MapVectorLayer, MapFeature) -> CGFloat = { _, _ in 8 }) -> MapVectorFeatureHit? {
        guard location.x.isFinite, location.y.isFinite, tolerance.isFinite, tolerance >= 0 else { return nil }
        var best: MapVectorFeatureHit?
        // Rendering paints layers and features in source order. Reverse order
        // gives the topmost item a deterministic tie when distances match.
        for layer in layers.reversed() {
            let uniqueCounts = Dictionary(grouping: layer.features, by: \.stableIdentity)
            for feature in layer.features.reversed() {
                guard feature.hasUniqueStableIdentity,
                      uniqueCounts[feature.stableIdentity]?.count == 1 else { continue }
                let distance = distance(from: location, to: feature, transform: transform,
                    lineWidth: max(0, lineWidth(layer, feature)),
                    pointDiameter: max(0, pointDiameter(layer, feature)))
                guard distance <= tolerance else { continue }
                if let best, distance >= best.distance { continue }
                best = MapVectorFeatureHit(layerID: layer.id,
                    featureIdentity: feature.stableIdentity, distance: distance)
            }
        }
        return best
    }

    static func distance(from location: CGPoint, to feature: MapFeature,
                         transform: MapTransform, lineWidth: CGFloat = 0,
                         pointDiameter: CGFloat = 8) -> CGFloat {
        let rings = feature.paths.map { $0.map(transform.screen) }
        guard !rings.isEmpty else { return .infinity }
        if feature.kind == .polygon,
           transform.path(feature).contains(location, eoFill: true) { return 0 }
        switch feature.kind {
        case .point:
            return rings.compactMap(\.first).map {
                max(0, hypot(location.x - $0.x, location.y - $0.y) - pointDiameter / 2)
            }.min() ?? .infinity
        case .line, .polygon:
            let isPolygon = feature.kind == .polygon
            return rings.map { points in
                guard points.count >= (isPolygon ? 2 : 2) else { return CGFloat.infinity }
                var minimum = zip(points, points.dropFirst()).map {
                    segmentDistance(location, from: $0.0, to: $0.1)
                }.min() ?? .infinity
                if isPolygon, points.first != points.last,
                   let first = points.first, let last = points.last {
                    minimum = min(minimum, segmentDistance(location, from: last, to: first))
                }
                return max(0, minimum - lineWidth / 2)
            }.min() ?? .infinity
        }
    }

    private static func segmentDistance(_ point: CGPoint, from start: CGPoint, to end: CGPoint) -> CGFloat {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared.isFinite else { return .infinity }
        guard lengthSquared > 0 else { return hypot(point.x - start.x, point.y - start.y) }
        let projection = min(1, max(0, ((point.x - start.x) * dx + (point.y - start.y) * dy) / lengthSquared))
        return hypot(point.x - (start.x + projection * dx), point.y - (start.y + projection * dy))
    }
}

enum MapVectorFeatureContextAction: Int {
    case zoomTo
    case copySelection
    case viewAttributes
    case exportSelectedFeatures
    case editLines
    case pasteCopiedLines
    case deleteSelectedFeatures
    case undoMapEdit
    case redoMapEdit
    case saveMapEdits
}

enum MapVectorFeatureContextSelection {
    static func mode(clickedFeatureIdentity: String,
                     selectedFeatureIdentities: Set<String>,
                     modifiers: Set<MapInput.Modifier>) -> MapVectorSelectionMode {
        selectedFeatureIdentities.contains(clickedFeatureIdentity) || modifiers.contains(.control)
            ? .ensureIncluded : .replace
    }
}

enum MapVectorFeatureContextCurrentness {
    static func matches(_ captured: MapVectorFeatureContextSnapshot,
                        projectSessionID: UUID,
                        mapID: UUID,
                        contextIdentity: String,
                        mapWorkflowIdentity: String,
                        layer: MapVectorLayer,
                        selectedFeatureIdentities: Set<String>) -> Bool {
        captured.projectSessionID == projectSessionID
            && captured.mapID == mapID
            && captured.contextIdentity == contextIdentity
            && captured.mapWorkflowIdentity == mapWorkflowIdentity
            && captured.layer.id == layer.id
            && captured.canonicalSourcePath == SourceFilePaths.canonical(layer.url)
            && captured.sourceRevision == layer.sourceRevision
            && Set(captured.selectedFeatureIdentities).count == captured.selectedFeatureIdentities.count
            && selectedFeatureIdentities == Set(captured.selectedFeatureIdentities)
    }
}

struct MapVectorFeatureContextMenuInteraction: NSViewRepresentable {
    let isEnabled: Bool
    let contextAt: (CGPoint, Set<MapInput.Modifier>) -> MapVectorFeatureContextSnapshot?
    let perform: (MapVectorFeatureContextAction, MapVectorFeatureContextSnapshot) -> Void
    var captureIdentity: String? = nil
    var blankContextAt: ((CGPoint) -> MapBlankContextCapture?)? = nil
    var performBlank: ((MapBlankContextMenuAction, MapBlankContextCapture) -> Void)? = nil

    func makeNSView(context: Context) -> MapVectorFeatureContextMenuMonitorView {
        let view = MapVectorFeatureContextMenuMonitorView()
        view.updateCaptureIdentity(captureIdentity)
        view.contextAt = contextAt
        view.perform = perform
        view.blankContextAt = blankContextAt
        view.performBlank = performBlank
        view.isEnabled = isEnabled
        return view
    }

    func updateNSView(_ view: MapVectorFeatureContextMenuMonitorView, context: Context) {
        view.updateCaptureIdentity(captureIdentity)
        view.contextAt = contextAt
        view.perform = perform
        view.blankContextAt = blankContextAt
        view.performBlank = performBlank
        view.isEnabled = isEnabled
        view.installMonitorIfNeeded()
    }

    static func dismantleNSView(_ view: MapVectorFeatureContextMenuMonitorView, coordinator: ()) {
        view.removeMonitor()
    }
}

@MainActor
final class MapVectorFeatureContextMenuMonitorView: NSView, NSMenuDelegate {
    var isEnabled = false
    private var captureIdentity: String?
    var contextAt: ((CGPoint, Set<MapInput.Modifier>) -> MapVectorFeatureContextSnapshot?)?
    var perform: ((MapVectorFeatureContextAction, MapVectorFeatureContextSnapshot) -> Void)?
    var blankContextAt: ((CGPoint) -> MapBlankContextCapture?)?
    var performBlank: ((MapBlankContextMenuAction, MapBlankContextCapture) -> Void)?
    private var monitor: Any?
    private weak var monitoredWindow: NSWindow?
    private var activeContext: MapVectorFeatureContextSnapshot?
    private var activeBlankContext: MapBlankContextCapture?

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); installMonitorIfNeeded() }
    override func layout() { super.layout(); installMonitorIfNeeded() }

    func updateCaptureIdentity(_ identity: String?) {
        guard captureIdentity != identity else { return }
        captureIdentity = identity
        activeContext = nil
        activeBlankContext = nil
    }

    func installMonitorIfNeeded() {
        guard isEnabled, let window, !bounds.isEmpty, !visibleRect.isEmpty else {
            removeMonitor()
            return
        }
        guard monitor == nil || monitoredWindow !== window else { return }
        removeMonitor()
        monitoredWindow = window
        monitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [weak self] event in
            guard let self, self.isEnabled,
                  let window = self.window, event.window === window else { return event }
            let location = self.convert(event.locationInWindow, from: nil)
            guard self.bounds.contains(location), self.visibleRect.contains(location) else { return event }
            let blankContext = self.blankContextAt?(location)
            let menu: NSMenu
            if let context = self.contextAt?(location, Self.modifiers(event.modifierFlags)) {
                self.activeContext = context
                self.activeBlankContext = blankContext
                menu = self.makeMenu(for: context, blankContext: blankContext)
            } else if let blankContext {
                self.activeContext = nil
                self.activeBlankContext = blankContext
                menu = self.makeBlankMenu()
            } else {
                return event
            }
            NSMenu.popUpContextMenu(menu, with: event, for: self)
            return nil
        }
    }

    func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        monitoredWindow = nil
        activeContext = nil
        activeBlankContext = nil
    }

    func menuDidClose(_ menu: NSMenu) { activeContext = nil; activeBlankContext = nil }

    @objc private func zoomTo(_ sender: NSMenuItem) { dispatch(.zoomTo) }
    @objc private func copySelection(_ sender: NSMenuItem) { dispatch(.copySelection) }
    @objc private func viewAttributes(_ sender: NSMenuItem) { dispatch(.viewAttributes) }
    @objc private func exportSelectedFeatures(_ sender: NSMenuItem) { dispatch(.exportSelectedFeatures) }
    @objc private func editLines(_ sender: NSMenuItem) { dispatch(.editLines) }
    @objc private func pasteCopiedLines(_ sender: NSMenuItem) { dispatch(.pasteCopiedLines) }
    @objc private func deleteSelectedFeatures(_ sender: NSMenuItem) { dispatch(.deleteSelectedFeatures) }
    @objc private func undoMapEdit(_ sender: NSMenuItem) { dispatch(.undoMapEdit) }
    @objc private func redoMapEdit(_ sender: NSMenuItem) { dispatch(.redoMapEdit) }
    @objc private func saveMapEdits(_ sender: NSMenuItem) { dispatch(.saveMapEdits) }
    @objc private func copyHoveredTileJSON(_ sender: NSMenuItem) { dispatchBlank(.copyHoveredTileJSON) }

    private func dispatch(_ action: MapVectorFeatureContextAction) {
        guard let activeContext else { return }
        perform?(action, activeContext)
    }

    private func dispatchBlank(_ action: MapBlankContextMenuAction) {
        guard let activeBlankContext else { return }
        performBlank?(action, activeBlankContext)
    }

    private func makeBlankMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        if let activeBlankContext {
            addHoveredTileJSONMenu(to: menu, capture: activeBlankContext)
        }
        return menu
    }

    private func makeMenu(for context: MapVectorFeatureContextSnapshot,
                          blankContext: MapBlankContextCapture?) -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        add("Zoom To", #selector(zoomTo(_:)), to: menu)
        add("Copy Selection", #selector(copySelection(_:)), to: menu)
        if context.isShapefile {
            add("View Attributes", #selector(viewAttributes(_:)), to: menu, enabled: context.focusRowID != nil)
            add("Export Selected Features", #selector(exportSelectedFeatures(_:)), to: menu)
        }
        if context.hasSelectedLines {
            menu.addItem(.separator())
            add("Edit Lines", #selector(editLines(_:)), to: menu)
            add("Paste Copied Lines", #selector(pasteCopiedLines(_:)), to: menu,
                enabled: context.canPasteCopiedLines)
            add("Delete Selected Features", #selector(deleteSelectedFeatures(_:)), to: menu,
                enabled: context.editorCanDeleteSelectedFeatures)
            add("Undo Map Edit", #selector(undoMapEdit(_:)), to: menu,
                enabled: context.editorCanUndo)
            add("Redo Map Edit", #selector(redoMapEdit(_:)), to: menu,
                enabled: context.editorCanRedo)
            add("Save Map Edits", #selector(saveMapEdits(_:)), to: menu,
                enabled: context.editorCanSave)
        }
        if let blankContext { addHoveredTileJSONMenu(to: menu, capture: blankContext) }
        return menu
    }

    private func addHoveredTileJSONMenu(to menu: NSMenu, capture: MapBlankContextCapture) {
        let copyGroup = NSMenuItem(title: L10n.text(MapBlankContextMenuContract.groupTitleKey),
            action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for descriptor in MapBlankContextMenuContract.items(for: capture) {
            let selector: Selector
            switch descriptor.action {
            case .copyHoveredTileJSON: selector = #selector(copyHoveredTileJSON(_:))
            }
            let item = NSMenuItem(title: L10n.text(descriptor.titleKey),
                action: selector, keyEquivalent: "")
            item.target = self
            item.isEnabled = descriptor.isEnabled
            if let helpKey = descriptor.helpKey { item.toolTip = L10n.text(helpKey) }
            submenu.addItem(item)
        }
        copyGroup.submenu = submenu
        menu.addItem(copyGroup)
    }

    private func add(_ key: String, _ action: Selector, to menu: NSMenu, enabled: Bool = true) {
        let item = NSMenuItem(title: L10n.text(key), action: action, keyEquivalent: "")
        item.target = self
        item.isEnabled = enabled
        menu.addItem(item)
    }

    private static func modifiers(_ flags: NSEvent.ModifierFlags) -> Set<MapInput.Modifier> {
        var result: Set<MapInput.Modifier> = []
        if flags.contains(.shift) { result.insert(.shift) }
        if flags.contains(.control) { result.insert(.control) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.command) { result.insert(.command) }
        return result
    }
}

struct MapVectorFeatureClipboard: Codable, Sendable {
    static let type = "org.hecras2025.map-vector-features"
    let schema: String
    let mapID: String
    let contextIdentity: String
    let layerID: String
    let sourcePath: String
    let sourceRevision: String?
    let sourceProjectionWKT: String?
    let targetProjectionWKT: String?
    let features: [Feature]

    struct Feature: Codable, Sendable {
        let stableIdentity: String
        let sourceFeatureIndex: Int?
        let geometryKind: String
        let projectedPaths: [[Coordinate]]
        let sourcePaths: [[Coordinate]]
        let attributes: [Attribute]
    }

    struct Coordinate: Codable, Sendable {
        let x: Double
        let y: Double
        let z: Double?
        let m: Double?
    }

    struct Attribute: Codable, Sendable {
        let ordinal: Int
        let name: String
        let value: AttributeValue
    }

    enum AttributeValue: Codable, Equatable, Sendable {
        case null
        case string(String)
        case integer(String)
        case number(String)
        case boolean(Bool)
        case date(String)
        case binary(String)

        private enum CodingKeys: String, CodingKey { case type, value }
        private enum ValueType: String, Codable { case null, string, integer, number, boolean, date, binary }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            switch try container.decode(ValueType.self, forKey: .type) {
            case .null: self = .null
            case .string: self = .string(try container.decode(String.self, forKey: .value))
            case .integer: self = .integer(try container.decode(String.self, forKey: .value))
            case .number: self = .number(try container.decode(String.self, forKey: .value))
            case .boolean: self = .boolean(try container.decode(Bool.self, forKey: .value))
            case .date: self = .date(try container.decode(String.self, forKey: .value))
            case .binary: self = .binary(try container.decode(String.self, forKey: .value))
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .null: try container.encode(ValueType.null, forKey: .type)
            case .string(let value): try container.encode(ValueType.string, forKey: .type); try container.encode(value, forKey: .value)
            case .integer(let value): try container.encode(ValueType.integer, forKey: .type); try container.encode(value, forKey: .value)
            case .number(let value): try container.encode(ValueType.number, forKey: .type); try container.encode(value, forKey: .value)
            case .boolean(let value): try container.encode(ValueType.boolean, forKey: .type); try container.encode(value, forKey: .value)
            case .date(let value): try container.encode(ValueType.date, forKey: .type); try container.encode(value, forKey: .value)
            case .binary(let value): try container.encode(ValueType.binary, forKey: .type); try container.encode(value, forKey: .value)
            }
        }

    init(_ source: MapSourceAttributeValue) {
        switch source {
        case .null: self = .null
        case .string(let value): self = .string(value)
        case .integer(let value): self = .integer(value)
        case .number(let value): self = .number(value)
        case .boolean(let value): self = .boolean(value)
        case .date(let value): self = .date(value)
        case .binary(let value): self = .binary(value.base64EncodedString())
        }
    }
    }

    static func make(from context: MapVectorFeatureContextSnapshot) -> Self {
        let features = context.selectedFeatures.map { feature in
            let source = feature.sourceCoordinatePaths?.map { path in
                path.map { Coordinate(x: $0.x, y: $0.y, z: $0.z, m: $0.m) }
            } ?? feature.paths.map { path in
                path.map { Coordinate(x: $0.x, y: $0.y, z: nil, m: nil) }
            }
            let projected = feature.paths.map { path in
                path.map { Coordinate(x: $0.x, y: $0.y, z: nil, m: nil) }
            }
            let attributes: [Attribute]
            if let columns = feature.sourceAttributeColumns {
                attributes = columns.map { column in
                    Attribute(ordinal: column.ordinal, name: column.name, value: AttributeValue(column.value))
                }
            } else {
                attributes = feature.attributes.sorted { $0.key < $1.key }.enumerated().map { ordinal, item in
                    Attribute(ordinal: ordinal, name: item.key, value: .string(item.value))
                }
            }
            return Feature(stableIdentity: feature.stableIdentity,
                sourceFeatureIndex: feature.sourceFeatureIndex, geometryKind: feature.kind.rawValue,
                projectedPaths: projected, sourcePaths: source, attributes: attributes)
        }
        return Self(schema: "hecras-map-vector-features-v1", mapID: context.mapID.uuidString,
            contextIdentity: context.contextIdentity, layerID: context.layer.id,
            sourcePath: context.canonicalSourcePath, sourceRevision: context.sourceRevision,
            sourceProjectionWKT: context.layer.sourceProjectionWKT,
            targetProjectionWKT: context.layer.targetProjectionWKT, features: features)
    }

    static func compatibilityPolylineClipboard(from context: MapVectorFeatureContextSnapshot) -> GeoprocessingPolylineClipboard? {
        let selectedLines = context.selectedFeatures.filter { $0.kind == .line }
        guard !selectedLines.isEmpty else { return nil }
        var lines: [GeoprocessingClipboardPolyline] = []
        for feature in selectedLines {
            let sourcePaths = feature.sourceCoordinatePaths ?? feature.paths.map { path in
                path.map { MapSourceCoordinate(x: $0.x, y: $0.y) }
            }
            guard sourcePaths.count == feature.paths.count else { continue }
            for coordinates in sourcePaths {
                guard coordinates.count >= 2 else { continue }
                let hasZ = coordinates.allSatisfy { $0.z != nil }
                let hasM = coordinates.allSatisfy { $0.m != nil }
                guard (!coordinates.contains { $0.z != nil } || hasZ),
                      (!coordinates.contains { $0.m != nil } || hasM),
                      !hasM || hasZ else { continue }
                let vertices: [GeoprocessingClipboardVertex] = coordinates.map { coordinate in
                    let z: String? = coordinate.z.map { String($0) }
                    let m: String? = coordinate.m.map { String($0) }
                    return GeoprocessingClipboardVertex(x: coordinate.x, y: coordinate.y, z: z, m: m)
                }
                lines.append(GeoprocessingClipboardPolyline(hasZ: hasZ, hasM: hasM,
                    vertices: vertices))
            }
        }
        guard !lines.isEmpty else { return nil }
        return GeoprocessingPolylineClipboard(lines: lines,
            coordinateProjectionWKT: context.layer.sourceProjectionWKT ?? context.layer.targetProjectionWKT)
    }

}

enum MapVectorFeatureContextGeometry {
    static func viewport(for features: [MapFeature], current: ViewportRequest?) -> ViewportRequest? {
        let points = features.flatMap { $0.paths.flatMap { $0 } }
        guard let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
              let minY = points.map(\.y).min(), let maxY = points.map(\.y).max(),
              [minX, maxX, minY, maxY].allSatisfy(\.isFinite) else { return nil }
        let centerX = minX / 2 + maxX / 2
        let centerY = minY / 2 + maxY / 2
        let currentWidth = current.map { max(0, $0.upperRight.x - $0.lowerLeft.x) } ?? 0
        let currentHeight = current.map { max(0, $0.upperRight.y - $0.lowerLeft.y) } ?? 0
        let span = max(maxX - minX, maxY - minY)
        let fallback = max(max(currentWidth, currentHeight) * 0.02,
                           max(max(abs(centerX), abs(centerY)), 1) * 1e-9)
        let halfWidth = max((maxX - minX) / 2, fallback)
        let halfHeight = max((maxY - minY) / 2, fallback)
        guard span.isFinite, fallback.isFinite, halfWidth.isFinite, halfHeight.isFinite else { return nil }
        return ViewportRequest(lowerLeft: .init(x: centerX - halfWidth, y: centerY - halfHeight),
            upperRight: .init(x: centerX + halfWidth, y: centerY + halfHeight), animated: true, padding: 32)
    }
}
