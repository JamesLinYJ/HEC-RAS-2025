import AppKit
import RASWorkspaceCore
import SwiftUI

struct BoundaryMapStyleEditor: View {
    @ObservedObject var session: BoundaryMapStyleSession
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if session.isLoading && session.snapshot == nil {
                ProgressView(L10n.text("Loading Boundary map styles"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let context = session.context, session.snapshot != nil, session.draft != nil {
                form(context)
            } else {
                ContentUnavailableView(L10n.text("Boundary map styles unavailable"),
                    systemImage: "slider.horizontal.3",
                    description: Text(session.errorMessage
                        ?? L10n.text("Refresh the selected Boundary source and try again.")))
            }
        }
        .frame(minWidth: 470, idealWidth: 520, maxWidth: 640, minHeight: 420, idealHeight: 500)
        .task { await session.load() }
        .onDisappear { session.cancelPendingLoad() }
    }

    private func form(_ context: BoundaryMapStyleContext) -> some View {
        Form {
            Section {
                LabeledContent(L10n.text("Map"), value: context.capture.map.mapName)
                LabeledContent(L10n.text("Boundary Condition"), value: context.capture.boundaryNode.nodeName)
            }

            Section(L10n.text("Boundary Line")) {
                ColorPicker(L10n.text("Pen Color"), selection: colorBinding(
                    definitionID: BoundaryMapRenderStyle.lineDefinitionID, keyPath: \.penColor),
                    supportsOpacity: true)
                widthControl(L10n.text("Line Width"), definitionID: BoundaryMapRenderStyle.lineDefinitionID)
            }

            Section(L10n.text("Boundary Vertices")) {
                ColorPicker(L10n.text("Pen Color"), selection: colorBinding(
                    definitionID: BoundaryMapRenderStyle.vertexDefinitionID, keyPath: \.penColor),
                    supportsOpacity: true)
                widthControl(L10n.text("Line Width"), definitionID: BoundaryMapRenderStyle.vertexDefinitionID)
                ColorPicker(L10n.text("Fill Color"), selection: colorBinding(
                    definitionID: BoundaryMapRenderStyle.vertexDefinitionID, keyPath: \.fillColor),
                    supportsOpacity: true)
                pointSizeControl
            }

            if session.hasConditionalOverrides {
                Section {
                    Label(L10n.text("Saved conditional styles are preserved but are not evaluated for boundary lines."),
                        systemImage: "info.circle")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }

            if let error = session.errorMessage {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red).textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .disabled(session.isApplying || session.isInvalidated)
        .toolbar {
            ToolbarItemGroup(placement: .confirmationAction) {
                Button(L10n.text("Reset to Global Defaults"), action: session.resetToDefaults)
                    .disabled(session.isApplying || session.isLoading)
                Button(L10n.text("Cancel"), role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(L10n.text("Apply")) { Task { _ = await session.apply() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(session.isApplying || session.isLoading || session.isInvalidated || !session.hasChanges)
            }
        }
    }

    private var pointSizeControl: some View {
        LabeledContent(L10n.text("Point Size")) {
            Slider(value: Binding(
                get: { Double(value(BoundaryMapRenderStyle.vertexDefinitionID, \.pointSize, default: 3)) },
                set: { session.setPointSize(Int($0.rounded()), definitionID: BoundaryMapRenderStyle.vertexDefinitionID) }
            ), in: 0...256, step: 1)
            TextField(L10n.text("Point Size"), value: Binding(
                get: { value(BoundaryMapRenderStyle.vertexDefinitionID, \.pointSize, default: 3) },
                set: { session.setPointSize($0, definitionID: BoundaryMapRenderStyle.vertexDefinitionID) }
            ), format: .number)
                .frame(width: 64)
        }
    }

    private func widthControl(_ title: String, definitionID: String) -> some View {
        LabeledContent(title) {
            Slider(value: Binding(
                get: { value(definitionID, \.penWidth, default: 1) },
                set: { session.setPenWidth($0, definitionID: definitionID) }
            ), in: 0...256, step: 0.5)
            TextField(title, value: Binding(
                get: { value(definitionID, \.penWidth, default: 1) },
                set: { session.setPenWidth($0, definitionID: definitionID) }
            ), format: .number.precision(.fractionLength(0...1)))
                .frame(width: 64)
        }
    }

    private func colorBinding(definitionID: String,
                              keyPath: WritableKeyPath<VectorStyleValues, String>) -> Binding<Color> {
        Binding(get: {
            BoundaryARGBColor.decode(value(definitionID, keyPath, default: "#FF000000")) ?? .black
        }, set: { color in
            let encoded = BoundaryARGBColor.encode(color)
            if keyPath == \.penColor {
                session.setPenColor(encoded, definitionID: definitionID)
            } else {
                session.setFillColor(encoded, definitionID: definitionID)
            }
        })
    }

    private func value<Value>(_ definitionID: String,
                              _ keyPath: KeyPath<VectorStyleValues, Value>,
                              default fallback: Value) -> Value {
        session.draft?[definitionID]?.values[keyPath: keyPath] ?? fallback
    }
}
