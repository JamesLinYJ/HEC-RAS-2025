import SwiftUI

struct MapLineChartMenu: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var mapState: MapState
    var editingSelection = false
    @Environment(\.openWindow) private var openWindow
    private var hasLine: Bool { (try? store.mapLineContext(mapID: mapState.id, editingSelection: editingSelection)) != nil }
    private var hasSourceContext: Bool { mapState.resultSources.snapshot != nil }
    private var hasActiveResults: Bool { mapState.resultSources.sources?.activeNodes.isEmpty == false }
    var body: some View {
        Menu {
            ForEach(MapResultChartMode.allCases) { mode in
                Button(L10n.text(mode.titleKey)) {
                    if let route = store.openMapLineChart(mapID: mapState.id, mode: mode, editingSelection: editingSelection) {
                        openWindow(value: route)
                    }
                }.disabled(!hasLine || !hasSourceContext || !hasActiveResults || store.isRunningPlanCompute)
            }
            Divider()
            Button(L10n.text("Terrain Profile"), systemImage: "chart.xyaxis.line") {
                if let route = store.openMapDynamicProfileWindow(mapID: mapState.id,
                    mode: .terrain, editingSelection: editingSelection) {
                    openWindow(value: route)
                }
            }.disabled(!hasLine || !hasSourceContext || store.isRunningPlanCompute)
            Button(L10n.text("Results Profile"), systemImage: "chart.xyaxis.line") {
                if let route = store.openMapDynamicProfileWindow(mapID: mapState.id,
                    mode: .results, editingSelection: editingSelection) {
                    openWindow(value: route)
                }
            }.disabled(!hasLine || !hasSourceContext || !hasActiveResults || store.isRunningPlanCompute)
        } label: { Label("Line Chart", systemImage: "chart.xyaxis.line") }
    }
}

struct MapResultsPopover: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var mapState: MapState
    @State private var isPresented = false
    var body: some View {
        Button { isPresented.toggle() } label: { Label("Map Result Sources", systemImage: "square.stack.3d.up") }
            .disabled(store.mapResultRequest(for: mapState.id) == nil)
            .popover(isPresented: $isPresented) {
                VStack(spacing: 12) {
                    MapResultTypePicker(store: store, mapState: mapState)
                    MapResultSourcePanel(session: mapState.resultSources, store: store)
                    Button("Reset Result Selections") { Task { await store.resetMapResultSelections(mapState.id) } }
                        .disabled(store.isRunningProjectTool || mapState.resultSources.isLoading || mapState.resultSources.isSelecting)
                    MapLinkedResultsSection(store: store, mapState: mapState)
                    if !mapState.linkedResults.isActive {
                        MapResultMapControls(session: mapState.resultMap)
                    }
                }.frame(width: 520).padding(12)
                    .task { await store.configureMapResultSources(mapState.id) }
            }
    }
}

private struct MapResultTypePicker: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var mapState: MapState
    @State private var busy = false
    private let types = ["WaterSurfaceElevation", "Depth", "Velocity", "DepthTimesVelocity"]
    private func title(_ type: String) -> String {
        switch type { case "WaterSurfaceElevation": "Water Surface"; case "DepthTimesVelocity": "D*V"; default: type }
    }
    private var current: String {
        let selected = Set((mapState.resultSources.sources?.activeNodes ?? []).map { node in
            let raw = node.selectedMapType ?? "Depth"
            switch raw { case "Water Surface": return "WaterSurfaceElevation"; case "D*V": return "DepthTimesVelocity"; default: return raw }
        })
        return selected.count == 1 ? selected.first! : ""
    }
    var body: some View {
        Picker("Result Map Type", selection: Binding(get: { current }, set: { type in
            guard types.contains(type), !busy else { return }; busy = true
            Task { _ = await store.setSourceResultMapType(type, mapID: mapState.id); busy = false }
        })) {
            if current.isEmpty { Text("Multiple Values").tag("") }
            ForEach(types, id: \.self) { Text(L10n.text(title($0))).tag($0) }
        }.pickerStyle(.menu)
            .disabled(busy || mapState.resultSources.sources?.activeNodes.isEmpty != false || store.isRunningProjectTool)
    }
}
