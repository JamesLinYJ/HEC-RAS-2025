import SwiftUI

// Liquid Glass is system material for floating controls, not a substitute for
// the opaque map or data-editing work surface. Older macOS uses native material.
private struct WorkspaceGlass: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: .rect(cornerRadius: 16))
        } else {
            content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
    }
}

extension View {
    func workspaceGlass() -> some View { modifier(WorkspaceGlass()) }
}
