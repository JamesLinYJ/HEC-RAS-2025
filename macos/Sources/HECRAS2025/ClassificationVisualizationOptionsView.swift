import SwiftUI

/// Native route for ClassificationVisualizationOptions.EditModeOpacityForward.
/// The source XBF sets MinValue=0 and MaxValue=100. The bound context uses an
/// Int and its generated callback casts SliderPropertyItem.Value to Int, so
/// the native control uses integral steps without exposing discarded fractions.
struct ClassificationOpacityPropertyItem: View {
    let field: SourceEditorField
    let title: String
    @ObservedObject var session: ModelEditorSession
    @ObservedObject var store: WorkspaceStore

    private var isMixed: Bool { field.hasMixedDraft(in: session) }
    private var rawOpacity: String? {
        guard !isMixed else { return nil }
        return session.fields[field.storageID]
    }
    private var opacity: Double? {
        guard let rawValue = rawOpacity,
              let value = Double(rawValue),
              value.isFinite else { return nil }
        return value
    }
    private var displayedOpacity: String {
        guard let rawOpacity, !rawOpacity.isEmpty else { return "—" }
        guard let value = Double(rawOpacity), value.isFinite else { return rawOpacity }
        return "\(rawOpacity)%"
    }
    private var canEdit: Bool {
        field.canEditDraft(in: session) && !store.isSavingAll && !isMixed
    }
    private var opacityBinding: Binding<Double> {
        Binding(
            get: { min(max(opacity ?? 0, 0), 100) },
            set: { field.setDraftValue(String(Int($0)), in: session) }
        )
    }

    var body: some View {
        LabeledContent(LocalizedStringKey(title)) {
            if isMixed {
                Text("Mixed values")
                    .foregroundStyle(.secondary)
            } else if opacity != nil {
                HStack(spacing: 10) {
                    Slider(value: opacityBinding, in: 0...100, step: 1)
                        .accessibilityLabel(LocalizedStringKey(title))
                        .accessibilityValue(Text(verbatim: displayedOpacity))
                        .disabled(!canEdit)
                    Text(verbatim: displayedOpacity)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 42, alignment: .trailing)
                }
            } else {
                Text("—")
                    .foregroundStyle(.secondary)
            }
        }
    }
}
