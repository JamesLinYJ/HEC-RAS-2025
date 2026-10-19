import AppKit
import RASWorkspaceCore
import SwiftUI

struct BoundaryLineVisualSettingsRoute: Identifiable {
    let id: String
    let context: BoundaryLineVisualContext
    let settings: BoundaryLineVisualSettings
}

struct BoundaryLineVisualSettingsEditor: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var session: ModelEditorSession
    let context: BoundaryLineVisualContext
    let globalDefaults: BoundaryLineVisualSettings
    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft: BoundaryLineVisualSettings
    @State private var saveError: String?

    init(
        store: WorkspaceStore,
        session: ModelEditorSession,
        context: BoundaryLineVisualContext,
        settings: BoundaryLineVisualSettings,
        globalDefaults: BoundaryLineVisualSettings? = nil,
        onSaved: @escaping () -> Void
    ) {
        self.store = store
        self.session = session
        self.context = context
        self.globalDefaults = globalDefaults ?? context.globalDefaults
        self.onSaved = onSaved
        _draft = State(initialValue: settings)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Boundary Line Style").font(.title2.weight(.semibold))
                    Text("\(context.mapName) — \(context.boundaryName)")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
            }.padding(18)
            Divider()
            Form {
                Section("Line") {
                    ColorPicker("Pen Color", selection: colorBinding(\.line, field: \.penColor), supportsOpacity: true)
                    widthControl(title: "Line Width", style: \.line, field: \.penWidth)
                }
                Section("Vertex") {
                    ColorPicker("Pen Color", selection: colorBinding(\.vertex, field: \.penColor), supportsOpacity: true)
                    widthControl(title: "Line Width", style: \.vertex, field: \.penWidth)
                    ColorPicker("Fill Color", selection: colorBinding(\.vertex, field: \.fillColor), supportsOpacity: true)
                    pointSizeControl
                }
                if draft.hasConditionalOverrides {
                    Section {
                        Label("Conditional style overrides are preserved, but this canvas does not evaluate them.", systemImage: "info.circle")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                if let saveError {
                    Section {
                        Label(L10n.text(saveError), systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                }
            }
            .formStyle(.grouped)
            .padding(.horizontal, 12)
            Text("Changes apply to this map when you select Apply. Cancel leaves the .vis file unchanged.")
                .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 18).padding(.bottom, 10)
            Divider()
            HStack {
                Button("Reset to Global Defaults") { resetToGlobalDefaults() }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Apply") { apply() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }.padding(16)
        }
        .frame(minWidth: 480, idealWidth: 540, maxWidth: 680, minHeight: 430, idealHeight: 520, maxHeight: 760)
    }

    private var pointSizeControl: some View {
        LabeledContent("Point Size") {
            Slider(value: Binding(
                get: { Double(draft.vertex.pointSize) },
                set: { value in
                    guard value.isFinite, (0...256).contains(value) else { return }
                    draft.vertex.pointSize = Int(value.rounded())
                }
            ), in: 0...256, step: 1)
            TextField("Point Size", value: Binding(
                get: { draft.vertex.pointSize },
                set: { value in guard (0...256).contains(value) else { return }; draft.vertex.pointSize = value }
            ), format: .number)
                .frame(width: 64)
        }
    }

    private func widthControl(
        title: String,
        style stylePath: WritableKeyPath<BoundaryLineVisualSettings, BoundaryVectorVisualStyle>,
        field fieldPath: WritableKeyPath<BoundaryVectorVisualStyle, Double>
    ) -> some View {
        LabeledContent(LocalizedStringKey(title)) {
            Slider(value: Binding(
                get: { draft[keyPath: stylePath][keyPath: fieldPath] },
                set: { value in editStyle(stylePath) { $0[keyPath: fieldPath] = value } }
            ), in: 0...256, step: 0.5)
            TextField(LocalizedStringKey(title), value: Binding(
                get: { draft[keyPath: stylePath][keyPath: fieldPath] },
                set: { value in
                    guard value.isFinite else { return }
                    guard (0...256).contains(value) else { return }
                    editStyle(stylePath) { $0[keyPath: fieldPath] = value }
                }
            ), format: .number.precision(.fractionLength(0...1)))
                .frame(width: 64)
        }
    }

    private func colorBinding(
        _ stylePath: WritableKeyPath<BoundaryLineVisualSettings, BoundaryVectorVisualStyle>,
        field fieldPath: WritableKeyPath<BoundaryVectorVisualStyle, String>
    ) -> Binding<Color> {
        Binding(
            get: { BoundaryARGBColor.decode(draft[keyPath: stylePath][keyPath: fieldPath]) ?? .clear },
            set: { color in editStyle(stylePath) { $0[keyPath: fieldPath] = BoundaryARGBColor.encode(color) } }
        )
    }

    private func editStyle(
        _ stylePath: WritableKeyPath<BoundaryLineVisualSettings, BoundaryVectorVisualStyle>,
        _ operation: (inout BoundaryVectorVisualStyle) -> Void
    ) {
        var style = draft[keyPath: stylePath]
        operation(&style)
        draft[keyPath: stylePath] = style
    }

    private func resetToGlobalDefaults() {
        // Reset style properties to the exact baseline captured for this map;
        // conditional XML remains untouched and continues to show its notice.
        draft = BoundaryLineVisualSettings(
            line: globalDefaults.line,
            vertex: globalDefaults.vertex,
            hasConditionalOverrides: draft.hasConditionalOverrides
        )
        saveError = nil
    }

    private func apply() {
        do {
            try store.saveBoundaryLineVisualSettings(draft, context: context, session: session)
            onSaved()
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }
}

enum BoundaryARGBColor {
    static func decode(_ value: String) -> Color? {
        let text = value.hasPrefix("#") ? String(value.dropFirst()) : value
        guard text.count == 8, let argb = UInt32(text, radix: 16) else { return nil }
        return Color(.sRGB,
                     red: Double((argb >> 16) & 0xFF) / 255,
                     green: Double((argb >> 8) & 0xFF) / 255,
                     blue: Double(argb & 0xFF) / 255,
                     opacity: Double((argb >> 24) & 0xFF) / 255)
    }

    static func encode(_ color: Color) -> String {
        guard let native = NSColor(color).usingColorSpace(.sRGB) else { return "#FF000000" }
        func component(_ value: CGFloat) -> UInt32 {
            let finiteValue = value.isFinite ? value : 0
            return UInt32((min(1, max(0, finiteValue)) * 255).rounded())
        }
        let alpha = component(native.alphaComponent)
        let red = component(native.redComponent)
        let green = component(native.greenComponent)
        let blue = component(native.blueComponent)
        return String(format: "#%02X%02X%02X%02X", alpha, red, green, blue)
    }
}

extension BoundaryLineMapStyle {
    init?(settings: BoundaryLineVisualSettings) {
        guard let lineColor = BoundaryARGBColor.decode(settings.line.penColor),
              let vertexPenColor = BoundaryARGBColor.decode(settings.vertex.penColor),
              let vertexFillColor = BoundaryARGBColor.decode(settings.vertex.fillColor),
              settings.line.penWidth.isFinite, settings.vertex.penWidth.isFinite
        else { return nil }

        self = .sourceDefault
        self.lineColor = lineColor
        self.lineWidth = CGFloat(settings.line.penWidth)
        self.vertexPenColor = vertexPenColor
        self.vertexPenWidth = CGFloat(settings.vertex.penWidth)
        self.vertexFillColor = vertexFillColor
        self.vertexSize = CGFloat(settings.vertex.pointSize)
        self.hasConditionalOverrides = settings.hasConditionalOverrides
    }
}
