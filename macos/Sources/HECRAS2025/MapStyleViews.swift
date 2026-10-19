import SwiftUI

struct MapStylePresentation: Sendable {
    var canModifyTopology = false
    var layerName: String? = nil
}

struct MapStyleContent: View {
    @ObservedObject var store: WorkspaceStore
    let kind: ToolKind
    @ObservedObject var state: DataToolSession
    @ObservedObject var editor: ModelEditorSession
    let perform: @MainActor (DataToolOperation, String?) -> Void
    private var contoursOn: Bool { editor.fields["ContourSettingsGroup/IsContourEnabled"] == "true" }
    private var hillshadeOn: Bool { editor.fields["HillshadeSettingsGroup/IsHillshadeEnabled"] == "true" }
    var body: some View {
        Form {
            if let name = state.presentation.mapStyle?.layerName { Section { Text(name).font(.headline).textSelection(.enabled) } }
            switch kind {
            case .topology: topology
            case .contours: contours
            case .hillshade: hillshade
            case .vectorLabels: labels
            default: EmptyView()
            }
        }.formStyle(.grouped).disabled(!editor.canEdit)
    }
    private var topology: some View {
        Section("Cell Size Modification") {
            Picker("Features", selection: Binding(get: { editor.fields["TopologyProperties/ViewModel_ApplyToSelectedOnly"] == "true" }, set: { editor.set("TopologyProperties/ViewModel_ApplyToSelectedOnly", String($0)) })) {
                Text("All Features").tag(false); Text("Selected Features").tag(true)
            }.pickerStyle(.segmented)
            HStack {
                Button("Finer (0.5x)") { perform(.refineTopology, nil) }
                Button("Coarser (2x)") { perform(.coarsenTopology, nil) }
            }.disabled(state.presentation.mapStyle?.canModifyTopology != true || state.busy)
            TextField("Amount Coarser", text: text("TopologyProperties/ViewModel_GlobalModificationFactor"))
        }
    }
    private var contours: some View {
        Section("Contours") {
            Toggle("Draw elevation contour lines", isOn: toggle("ContourSettingsGroup/IsContourEnabled"))
            Group {
                row("Automatic Intervals", "ContourSettingsGroup", "IsAutoInterval")
                row("Fixed Interval", "ContourSettingsGroup", "ContourInterval").disabled(editor.fields["ContourSettingsGroup/IsAutoInterval"] == "true")
                row("Major Contour Interval #", "ContourSettingsGroup", "IndexEvery")
                row("Density", "ContourSettingsGroup", "Density")
                row("Color", "ContourSettingsGroup", "ContourColor")
                LabeledContent("Opacity") {
                    HStack(spacing: 12) {
                        Slider(value: contourOpacity, in: 0...100, step: 1)
                        Text(contourOpacityLabel).monospacedDigit().frame(minWidth: 48, alignment: .trailing)
                    }
                }
                row("Label Contours", "ContourSettingsGroup", "ShowLabels")
            }.disabled(!contoursOn)
        }
    }
    private var hillshade: some View {
        Section("Hillshade") {
            Toggle("Hillshade", isOn: toggle("HillshadeSettingsGroup/IsHillshadeEnabled"))
            Group {
                row("Z Factor", "HillshadeSettingsGroup", "ZFactor")
                row("Azimuth", "HillshadeSettingsGroup", "Azimuth")
                row("Zenith", "HillshadeSettingsGroup", "Zenith")
            }.disabled(!hillshadeOn)
        }
    }
    private var labels: some View {
        Section("Vector Labels") {
            row("Text Color", "VectorTextEditor", "Symbology_FillColor")
            row("Font Size", "VectorTextEditor", "Symbology_PenWidth")
            row("Halo Color", "VectorTextEditor", "Symbology_HaloColor")
            row("Halo Thickness", "VectorTextEditor", "Symbology_HaloThickness")
            Picker("Text Emphasis", selection: text("VectorTextEditor/Symbology_TextEmphasis", fallback: "0")) {
                Text("Normal").tag("0"); Text("Bold").tag("1"); Text("Italic").tag("2")
            }
        }
    }
    private func row(_ title: String, _ schema: String, _ id: String) -> some View {
        LabeledContent(LocalizedStringKey(title)) { DataToolField(schema: schema, id: id, editor: editor, store: store).labelsHidden() }
    }
    private var contourOpacity: Binding<Double> {
        Binding(get: {
            min(100, max(0, Double(editor.fields["ContourSettingsGroup/ContourOpacity"] ?? "") ?? 0))
        }, set: { value in
            editor.set("ContourSettingsGroup/ContourOpacity", String(Int(value.rounded())))
        })
    }
    private var contourOpacityLabel: String {
        let raw = editor.fields["ContourSettingsGroup/ContourOpacity"] ?? "0"
        guard let value = Double(raw), value.isFinite else { return raw }
        return "\(Int(min(100, max(0, value)).rounded()))%"
    }
    private func text(_ key: String, fallback: String = "") -> Binding<String> { Binding(get: { editor.fields[key] ?? fallback }, set: { editor.set(key, $0) }) }
    private func toggle(_ key: String) -> Binding<Bool> { Binding(get: { editor.fields[key] == "true" }, set: { editor.set(key, String($0)) }) }
}
