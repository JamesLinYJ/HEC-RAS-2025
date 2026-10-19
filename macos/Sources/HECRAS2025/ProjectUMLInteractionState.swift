import AppKit
import Foundation
import SwiftUI

struct ProjectUMLViewportState: Equatable {
    static let minimumZoom: CGFloat = 0.1
    static let maximumZoom: CGFloat = 10

    private(set) var zoom: CGFloat = 1
    private(set) var offset: CGSize = .zero

    func canvasPoint(fromViewport point: CGPoint) -> CGPoint {
        CGPoint(x: (point.x - offset.width) / zoom, y: (point.y - offset.height) / zoom)
    }

    func viewportPoint(fromCanvas point: CGPoint) -> CGPoint {
        CGPoint(x: point.x * zoom + offset.width, y: point.y * zoom + offset.height)
    }

    mutating func setOffset(_ value: CGSize) {
        guard value.width.isFinite, value.height.isFinite else { return }
        offset = value
    }

    mutating func pan(by delta: CGSize) {
        setOffset(CGSize(width: offset.width + delta.width, height: offset.height + delta.height))
    }

    mutating func zoom(by factor: CGFloat, anchoredAt anchor: CGPoint) {
        guard factor.isFinite, factor > 0 else { return }
        setZoom(zoom * factor, anchoredAt: anchor)
    }

    mutating func setZoom(_ requestedZoom: CGFloat, anchoredAt anchor: CGPoint) {
        guard requestedZoom.isFinite, anchor.x.isFinite, anchor.y.isFinite else { return }
        let anchorInCanvas = canvasPoint(fromViewport: anchor)
        zoom = min(max(requestedZoom, Self.minimumZoom), Self.maximumZoom)
        offset = CGSize(width: anchor.x - anchorInCanvas.x * zoom,
            height: anchor.y - anchorInCanvas.y * zoom)
    }

    mutating func fit(bounds: CGRect, in viewportSize: CGSize, margin: CGFloat = 100) {
        guard bounds.minX.isFinite, bounds.minY.isFinite, bounds.width.isFinite, bounds.height.isFinite,
              viewportSize.width.isFinite, viewportSize.height.isFinite,
              viewportSize.width > 0, viewportSize.height > 0,
              margin.isFinite, margin >= 0 else { return }
        let width = max(1, bounds.width + margin)
        let height = max(1, bounds.height + margin)
        let targetZoom = min(viewportSize.width / width, viewportSize.height / height)
        guard targetZoom.isFinite, targetZoom > 0 else { return }
        zoom = targetZoom
        offset = CGSize(width: viewportSize.width / 2 - bounds.midX * zoom,
            height: viewportSize.height / 2 - bounds.midY * zoom)
    }
}

struct ProjectUMLSelectionState: Equatable {
    private(set) var selectedNodeIDs: Set<String> = []
    private(set) var inspectorNodeID: String?

    mutating func select(_ id: String, additive: Bool) {
        if !additive, !selectedNodeIDs.contains(id) {
            selectedNodeIDs = [id]
        }
        selectedNodeIDs.insert(id)
        inspectorNodeID = id
    }

    mutating func selectBox(_ ids: Set<String>, additive: Bool, orderedIDs: [String]) {
        if additive {
            selectedNodeIDs.formUnion(ids)
        } else {
            selectedNodeIDs = ids
        }
        if let inspectorNodeID, selectedNodeIDs.contains(inspectorNodeID) { return }
        inspectorNodeID = orderedIDs.first(where: selectedNodeIDs.contains)
    }

    mutating func selectOnly(_ id: String?) {
        guard let id else {
            clear()
            return
        }
        selectedNodeIDs = [id]
        inspectorNodeID = id
    }

    mutating func clear() {
        selectedNodeIDs.removeAll()
        inspectorNodeID = nil
    }

    mutating func reconcile(orderedIDs: [String]) {
        selectedNodeIDs.formIntersection(Set(orderedIDs))
        if let inspectorNodeID, selectedNodeIDs.contains(inspectorNodeID) { return }
        inspectorNodeID = orderedIDs.first(where: selectedNodeIDs.contains)
    }
}

enum ProjectUMLCanvasGeometry {
    static func nodeHeight(inputCount: Int, headerHeight: CGFloat, inputRowHeight: CGFloat) -> CGFloat {
        max(90, headerHeight + CGFloat(inputCount) * inputRowHeight)
    }

    static func outputAnchor(origin: CGPoint, width: CGFloat, height: CGFloat) -> CGPoint {
        CGPoint(x: origin.x + width, y: origin.y + height / 2)
    }

    static func inputAnchor(origin: CGPoint, headerHeight: CGFloat, inputRowHeight: CGFloat,
                            inputIndex: Int) -> CGPoint {
        CGPoint(x: origin.x,
            y: origin.y + headerHeight + CGFloat(max(0, inputIndex)) * inputRowHeight + inputRowHeight / 2)
    }

    static func linkEndpoints(outputOrigin: CGPoint, inputOrigin: CGPoint, nodeWidth: CGFloat,
                              outputHeight: CGFloat, headerHeight: CGFloat, inputRowHeight: CGFloat,
                              inputIndex: Int, overrideOutput: CGPoint? = nil,
                              overrideInput: CGPoint? = nil) -> ProjectUMLLinkEndpoints {
        ProjectUMLLinkEndpoints(
            output: overrideOutput ?? outputAnchor(origin: outputOrigin, width: nodeWidth, height: outputHeight),
            input: overrideInput ?? inputAnchor(origin: inputOrigin, headerHeight: headerHeight,
                inputRowHeight: inputRowHeight, inputIndex: inputIndex))
    }

    static func shiftNegativeDiagramBounds(_ positions: [String: CGPoint],
                                           originMargin: CGFloat = 1_000) -> ProjectUMLDiagramNormalization {
        guard originMargin.isFinite, originMargin >= 0,
              positions.values.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else {
            return ProjectUMLDiagramNormalization(positions: positions, shift: .zero)
        }
        let minX = positions.values.map(\.x).min() ?? 0
        let minY = positions.values.map(\.y).min() ?? 0
        let shift = CGSize(width: minX < 0 ? originMargin - minX : 0,
            height: minY < 0 ? originMargin - minY : 0)
        guard shift != .zero else { return ProjectUMLDiagramNormalization(positions: positions, shift: .zero) }
        let updated = positions.mapValues { CGPoint(x: $0.x + shift.width, y: $0.y + shift.height) }
        return ProjectUMLDiagramNormalization(positions: updated, shift: shift)
    }

    static func intersects(_ first: CGRect, _ second: CGRect) -> Bool {
        first.standardized.intersects(second.standardized)
    }
}

struct ProjectUMLDiagramNormalization: Equatable, Sendable {
    let positions: [String: CGPoint]
    let shift: CGSize
}

struct ProjectUMLLinkEndpoints: Equatable, Sendable {
    let output: CGPoint
    let input: CGPoint
}

enum ProjectUMLLinkPort: Hashable, Sendable {
    case input(nodeID: String, index: Int, typeID: String)
    case output(nodeID: String, typeID: String)

    var nodeID: String {
        switch self {
        case .input(let nodeID, _, _), .output(let nodeID, _): nodeID
        }
    }

    var typeID: String {
        switch self {
        case .input(_, _, let typeID), .output(_, let typeID): typeID
        }
    }
}

struct ProjectUMLLinkDraft: Equatable, Sendable {
    let source: ProjectUMLLinkPort
    let anchor: CGPoint
    private(set) var cursor: CGPoint

    init(source: ProjectUMLLinkPort, anchor: CGPoint, cursor: CGPoint? = nil) {
        self.source = source
        self.anchor = anchor
        self.cursor = cursor ?? anchor
    }

    mutating func moveCursor(to point: CGPoint) {
        guard point.x.isFinite, point.y.isFinite else { return }
        cursor = point
    }

    var hasMovedBeyondSourceThreshold: Bool {
        hypot(cursor.x - anchor.x, cursor.y - anchor.y) > 20
    }
}

struct ProjectUMLPortLayoutNode: Equatable, Sendable {
    let id: String
    let typeID: String
    let x: Double
    let y: Double
    let inputTypeIDs: [String]
}

enum ProjectUMLPortHitTesting {
    static func nearestPort(to point: CGPoint, nodes: [ProjectUMLPortLayoutNode],
                            nodeWidth: CGFloat, nodeHeight: (ProjectUMLPortLayoutNode) -> CGFloat,
                            headerHeight: CGFloat, inputRowHeight: CGFloat,
                            tolerance: CGFloat = 18) -> ProjectUMLLinkPort? {
        guard point.x.isFinite, point.y.isFinite, tolerance.isFinite, tolerance >= 0 else { return nil }
        var best: (port: ProjectUMLLinkPort, distance: CGFloat)?
        for node in nodes {
            let origin = CGPoint(x: CGFloat(node.x), y: CGFloat(node.y))
            let output = ProjectUMLCanvasGeometry.outputAnchor(origin: origin, width: nodeWidth,
                height: nodeHeight(node))
            consider(.output(nodeID: node.id, typeID: node.typeID), at: output, point: point,
                tolerance: tolerance, best: &best)
            for index in node.inputTypeIDs.indices {
                let input = ProjectUMLCanvasGeometry.inputAnchor(origin: origin,
                    headerHeight: headerHeight, inputRowHeight: inputRowHeight, inputIndex: index)
                consider(.input(nodeID: node.id, index: index, typeID: node.inputTypeIDs[index]),
                    at: input, point: point, tolerance: tolerance, best: &best)
            }
        }
        return best?.port
    }

    private static func consider(_ port: ProjectUMLLinkPort, at anchor: CGPoint,
                                 point: CGPoint, tolerance: CGFloat,
                                 best: inout (port: ProjectUMLLinkPort, distance: CGFloat)?) {
        let distance = hypot(anchor.x - point.x, anchor.y - point.y)
        guard distance <= tolerance, best == nil || distance < best!.distance else { return }
        best = (port, distance)
    }
}

struct ProjectUMLScrollWheelCapture: NSViewRepresentable {
    let onWheel: (CGPoint, CGFloat) -> Bool

    func makeNSView(context: Context) -> ProjectUMLScrollWheelRoutingView {
        let view = ProjectUMLScrollWheelRoutingView()
        view.onWheel = onWheel
        return view
    }

    func updateNSView(_ view: ProjectUMLScrollWheelRoutingView, context: Context) {
        view.onWheel = onWheel
    }

    static func dismantleNSView(_ view: ProjectUMLScrollWheelRoutingView, coordinator: ()) {
        view.removeWheelMonitor()
    }
}

@MainActor
final class ProjectUMLScrollWheelRoutingView: NSView {
    var onWheel: ((CGPoint, CGFloat) -> Bool)?
    private var wheelMonitor: Any?

    override var isOpaque: Bool { false }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { removeWheelMonitor() }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        installWheelMonitorIfNeeded()
    }

    func removeWheelMonitor() {
        if let wheelMonitor {
            NSEvent.removeMonitor(wheelMonitor)
            self.wheelMonitor = nil
        }
    }

    private func installWheelMonitorIfNeeded() {
        guard wheelMonitor == nil, window != nil else { return }
        wheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, let targetWindow = self.window, event.window === targetWindow,
                  event.scrollingDeltaY != 0 else { return event }
            let location = self.convert(event.locationInWindow, from: nil)
            guard self.bounds.contains(location) else { return event }
            let scale = event.scrollingDeltaY > 0 ? CGFloat(1.21) : CGFloat(1 / 1.21)
            return self.onWheel?(location, scale) == true ? nil : event
        }
    }
}
