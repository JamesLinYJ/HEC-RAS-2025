import SwiftUI

/// Native counterpart to NewMapFlyout. The owner supplies the two map creation
/// operations so each choice stays tied to a real workspace action.
struct WorkspaceNewMapFlyout: View {
    let createBlankMap: () -> Void
    let createProjectMap: () -> Void

    var body: some View {
        Menu {
            Button("Blank Map", systemImage: "map") { createBlankMap() }
            Button("Project Map", systemImage: "map.fill") { createProjectMap() }
        } label: {
            Label("New Map", systemImage: "map")
        }
    }
}

/// Standalone SwiftUI surface for the original debug animation utility.
/// Opened as a singleton window from the developer testing tools.
struct WorkspaceAnimationTestingView: View {
    @State private var side: CGFloat = 100
    @State private var offset: CGFloat = 100
    @State private var animationTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 16) {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.red.opacity(0.8))
                    .frame(width: side, height: side)
                    .offset(x: offset, y: offset)
            }
            .frame(width: 640, height: 620, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary))
            .clipShape(RoundedRectangle(cornerRadius: 10))

            Button("Test Animation") {
                testAnimation()
            }
        }
        .padding(24)
        .frame(minWidth: 700, minHeight: 680)
        .onDisappear { animationTask?.cancel() }
    }

    private func testAnimation() {
        animationTask?.cancel()
        var reset = Transaction(animation: nil)
        reset.disablesAnimations = true
        withTransaction(reset) { side = 50; offset = 100 }
        // The source repeats the same 50 -> 300 size and 100 -> 300 offset
        // spring on every click; it does not toggle back on alternate clicks.
        animationTask = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled else { return }
            withAnimation(.interpolatingSpring(stiffness: 170, damping: 18)) {
                side = 300; offset = 300
            }
        }
    }
}

