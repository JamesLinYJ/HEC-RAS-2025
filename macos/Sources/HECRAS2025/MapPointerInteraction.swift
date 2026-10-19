import AppKit
import SwiftUI

/// Observes wheel events over the map without taking the map's SwiftUI gesture
/// surface away from taps, drags, drop targets, or controls.
struct MapPointerInteraction: NSViewRepresentable {
    let onModifiersChanged: ((NSEvent.ModifierFlags) -> Void)?
    let onScrollWheel: (CGPoint, Double) -> Void

    init(onModifiersChanged: ((NSEvent.ModifierFlags) -> Void)? = nil,
         onScrollWheel: @escaping (CGPoint, Double) -> Void) {
        self.onModifiersChanged = onModifiersChanged
        self.onScrollWheel = onScrollWheel
    }

    func makeNSView(context: Context) -> MapPointerMonitorView {
        let view = MapPointerMonitorView()
        view.onScrollWheel = onScrollWheel
        view.onModifiersChanged = onModifiersChanged
        return view
    }

    func updateNSView(_ view: MapPointerMonitorView, context: Context) {
        view.onScrollWheel = onScrollWheel
        view.onModifiersChanged = onModifiersChanged
        view.installMonitorIfNeeded()
    }

    static func dismantleNSView(_ view: MapPointerMonitorView, coordinator: ()) {
        view.removeMonitor()
    }
}

@MainActor
final class MapPointerMonitorView: NSView {
    var onScrollWheel: ((CGPoint, Double) -> Void)?
    var onModifiersChanged: ((NSEvent.ModifierFlags) -> Void)?
    private var monitor: Any?
    private weak var monitoredWindow: NSWindow?

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // A local event monitor observes wheel input; this transparent view
        // never intercepts the map's normal SwiftUI input.
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        installMonitorIfNeeded()
    }

    func installMonitorIfNeeded() {
        guard let window else {
            removeMonitor()
            return
        }
        guard monitor == nil || monitoredWindow !== window else { return }
        removeMonitor()
        monitoredWindow = window
        onModifiersChanged?(NSEvent.modifierFlags)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .flagsChanged]) { [weak self] event in
            guard let self, let window = self.window,
                  event.window === window || (event.type == .flagsChanged && event.window == nil && window.isKeyWindow)
            else { return event }
            if event.type == .flagsChanged {
                self.onModifiersChanged?(event.modifierFlags)
                return event
            }
            let location = self.convert(event.locationInWindow, from: nil)
            guard self.bounds.contains(location) else { return event }
            let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.deltaY * 120
            guard delta.isFinite, delta != 0 else { return event }
            self.onScrollWheel?(CGPoint(x: location.x, y: location.y), delta)
            return event
        }
    }

    func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        monitoredWindow = nil
    }

}

struct MapCameraUpdate: Equatable {
    let scale: CGFloat
    let offset: CGSize
}

/// Camera math follows TiledMap.Zoom: a wheel delta of +120 scales by 1.25,
/// and negative deltas are limited to -120 (a minimum 0.75 factor). The world
/// point under the actual cursor remains fixed while the view zooms.
enum MapPointerCamera {
    static let minimumScale: CGFloat = 0.125
    static let maximumScale: CGFloat = 256

    static func wheelZoom(scale: CGFloat, offset: CGSize, canvasSize: CGSize,
                          pointer: CGPoint, delta: Double) -> MapCameraUpdate? {
        guard delta.isFinite, delta != 0 else { return nil }
        let boundedDelta = max(delta, -120)
        let factor = 1 + 0.25 * boundedDelta / 120
        return zoom(scale: scale, offset: offset, canvasSize: canvasSize,
                    pointer: pointer, by: CGFloat(factor))
    }

    static func zoom(scale: CGFloat, offset: CGSize, canvasSize: CGSize,
                     pointer: CGPoint, by factor: CGFloat) -> MapCameraUpdate? {
        guard scale.isFinite, scale > 0, factor.isFinite, factor > 0,
              offset.width.isFinite, offset.height.isFinite,
              canvasSize.width.isFinite, canvasSize.height.isFinite,
              canvasSize.width > 0, canvasSize.height > 0,
              pointer.x.isFinite, pointer.y.isFinite else { return nil }
        let nextScale = min(max(scale * factor, minimumScale), maximumScale)
        guard nextScale.isFinite, nextScale != scale else { return nil }
        let effectiveFactor = nextScale / scale
        let centerX = canvasSize.width / 2
        let centerY = canvasSize.height / 2
        let nextOffset = CGSize(
            width: pointer.x - centerX - (pointer.x - centerX - offset.width) * effectiveFactor,
            height: pointer.y - centerY - (pointer.y - centerY - offset.height) * effectiveFactor)
        guard nextOffset.width.isFinite, nextOffset.height.isFinite else { return nil }
        return MapCameraUpdate(scale: nextScale, offset: nextOffset)
    }

    static func pan(offset: CGSize, by translation: CGSize) -> CGSize? {
        guard offset.width.isFinite, offset.height.isFinite,
              translation.width.isFinite, translation.height.isFinite else { return nil }
        let result = CGSize(width: offset.width + translation.width,
                            height: offset.height + translation.height)
        return result.width.isFinite && result.height.isFinite ? result : nil
    }
}
