import SwiftUI

/// Keeps the source screen visible while making an absent service explicit.
/// Individual controls still own their own enabled state and no action is
/// reported as successful when its adapter is missing.
struct ToolServiceDialog<Content: View>: View {
    let isAvailable: Bool
    let content: Content

    init(isAvailable: Bool, @ViewBuilder content: () -> Content) {
        self.isAvailable = isAvailable
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            if !isAvailable { ToolServiceUnavailableNotice() }
            content
        }
    }
}

struct ToolServiceUnavailableNotice: View {
    var body: some View {
        Label(
            L10n.text("The original model adapter for this tool is unavailable."),
            systemImage: "info.circle"
        )
        .font(.callout)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(Color.secondary.opacity(0.08))
    }
}
