import AppKit
import SwiftUI

// UI contract stores colors as RRGGBBAA. Model adapters translate their own
// platform color representation without exposing WinUI color types to views.
enum EditorColor {
    static func decode(_ hex: String) -> Color {
        let value = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard value.count == 8, let rgba = UInt32(value, radix: 16) else { return .clear }
        return Color(.sRGB, red: Double((rgba >> 24) & 255) / 255,
            green: Double((rgba >> 16) & 255) / 255, blue: Double((rgba >> 8) & 255) / 255,
            opacity: Double(rgba & 255) / 255)
    }
    static func encode(_ color: Color) -> String {
        guard let native = NSColor(color).usingColorSpace(.sRGB) else { return "00000000" }
        return [native.redComponent, native.greenComponent, native.blueComponent, native.alphaComponent]
            .map { String(format: "%02X", Int(($0 * 255).rounded())) }.joined()
    }
}
