import RASWorkspaceCore
import SwiftUI

struct ViewportRequest: Sendable {
    let id = UUID()
    let lowerLeft: MapPoint
    let upperRight: MapPoint
    var animated = true
    var padding: Double = 32
    var isFiniteAndOrdered: Bool {
        [lowerLeft.x, lowerLeft.y, upperRight.x, upperRight.y].allSatisfy(\.isFinite)
            && lowerLeft.x <= upperRight.x && lowerLeft.y <= upperRight.y
    }
}

// ZoomToPoint.cs uses project coordinates and Point/Extent modes.
struct ZoomLocationSheet: View {
    @ObservedObject var store: WorkspaceStore
    @State private var mode = "Point"
    @State private var x = ""
    @State private var y = ""
    @State private var x2 = ""
    @State private var y2 = ""
    @State private var error: String?
    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Zoom to Location") {
                    Picker("Mode", selection: $mode) { Text("Point").tag("Point"); Text("Extent").tag("Extent") }.pickerStyle(.segmented)
                    TextField(mode == "Point" ? "X" : "Upper-left X", text: $x)
                    TextField(mode == "Point" ? "Y" : "Upper-left Y", text: $y)
                    if mode == "Extent" {
                        TextField("Lower-right X", text: $x2)
                        TextField("Lower-right Y", text: $y2)
                    }
                    if let error { Text(error).foregroundStyle(.red) }
                }
            }.formStyle(.grouped)
            HStack { Spacer(); Button("Cancel", role: .cancel) { store.showZoomLocation = false }.keyboardShortcut(.cancelAction)
                Button("Zoom") { zoom() }.keyboardShortcut(.defaultAction)
            }.padding(16)
        }.frame(width: 430, height: mode == "Point" ? 290 : 380)
    }
    private func zoom() {
        guard let vx = Double(x), let vy = Double(y), vx.isFinite, vy.isFinite else { error = L10n.text("Enter finite coordinates."); return }
        var lower: MapPoint
        var upper: MapPoint
        if mode == "Point" {
            let state = store.activeMapState
            let points = state.transformPoints(vectors: store.mapLayers, rasters: store.rasterLayers)
            let dx = (points.map(\.x).max() ?? 1000) - (points.map(\.x).min() ?? 0)
            let dy = (points.map(\.y).max() ?? 1000) - (points.map(\.y).min() ?? 0)
            let width = max(hypot(dx, dy) * 0.0001, Double.ulpOfOne)
            lower = MapPoint(x: vx - width / 2, y: vy - width / 2)
            upper = MapPoint(x: vx + width / 2, y: vy + width / 2)
        } else {
            guard let rx = Double(x2), let ry = Double(y2), rx.isFinite, ry.isFinite else { error = L10n.text("Enter finite coordinates."); return }
            lower = MapPoint(x: min(vx, rx), y: min(vy, ry)); upper = MapPoint(x: max(vx, rx), y: max(vy, ry))
        }
        guard upper.x > lower.x, upper.y > lower.y else { error = L10n.text("Enter a nonzero extent."); return }
        store.requestedViewport = ViewportRequest(lowerLeft: lower, upperRight: upper)
        store.showZoomLocation = false
    }
}

