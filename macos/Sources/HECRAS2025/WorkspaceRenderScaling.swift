import AppKit
import Combine
import Foundation

/// Process-local equivalent of `VectorManagerOptions.RenderScaling`.
/// The source value is static runtime state; it is not a persisted project
/// property, so this native setting intentionally lasts for this app run.
@MainActor
final class WorkspaceRenderScaling: ObservableObject {
    static let shared = WorkspaceRenderScaling()

    @Published private(set) var factor = 1.0

    private init() {}

    /// Applies a captured process-local factor to a device-space drawing
    /// metric. Canvas closures use this pure helper instead of reaching back
    /// into main-actor state while rendering.
    nonisolated static func metric(_ value: Double, factor: Double) -> CGFloat {
        let base = value.isFinite ? max(value, 0) : 0
        let multiplier = factor.isFinite && factor > 0 ? factor : 1
        let scaled = base * multiplier
        return CGFloat(scaled.isFinite ? min(scaled, 1_000_000) : 1_000_000)
    }

    @discardableResult
    func setFactor(_ rawValue: String) -> Bool {
        guard let value = Double(rawValue.trimmingCharacters(in: .whitespacesAndNewlines)),
              value.isFinite, value > 0 else { return false }
        factor = value
        return true
    }

    func reset() { factor = 1.0 }
}

@MainActor
enum WorkspaceRenderScalingPrompt {
    static func present() {
        let alert = NSAlert()
        alert.messageText = L10n.text("Vector Render Scaling")
        alert.informativeText = L10n.text("Enter a positive scale factor for vector pen widths and point sizes.")
        let field = NSTextField(string: String(WorkspaceRenderScaling.shared.factor))
        field.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: L10n.text("Apply"))
        alert.addButton(withTitle: L10n.text("Reset to Default"))
        alert.addButton(withTitle: L10n.text("Cancel"))
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            guard WorkspaceRenderScaling.shared.setFactor(field.stringValue) else {
                showInvalidValue()
                return
            }
        case .alertSecondButtonReturn:
            WorkspaceRenderScaling.shared.reset()
        default:
            break
        }
    }

    private static func showInvalidValue() {
        let alert = NSAlert()
        alert.messageText = L10n.text("Enter a finite number greater than zero.")
        alert.addButton(withTitle: L10n.text("OK"))
        alert.runModal()
    }
}
