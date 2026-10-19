import Foundation
import SwiftUI

struct UnitCalculatorUnitChoice: Identifiable, Sendable, Hashable {
    let id: String
    let name: String
    let unitTypeName: String

    @MainActor var sourcePickerTitle: String { L10n.text(unitTypeName) + " · " + name }
}

/// NumberBox-like input for the source calculator's G8 format. The raw string
/// stays in the editor draft while focused; formatting never rounds the value
/// sent to the C# converter.
struct UnitCalculatorNumberField: View {
    let title: String
    @Binding var value: String
    let isEditable: Bool
    let onDraftChange: (String) -> Void

    @FocusState private var isFocused: Bool
    @State private var editText = ""
    @State private var validation: String?

    private var displayText: String {
        guard let number = UnitCalculatorNumberFormat.number(from: value) else { return value }
        return UnitCalculatorNumberFormat.g8(number)
    }

    private var textBinding: Binding<String> {
        Binding(
            get: { isFocused ? editText : displayText },
            set: { next in
                editText = next
                value = next
                onDraftChange(next)
                validation = nil
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            TextField(LocalizedStringKey(title), text: textBinding)
                .textFieldStyle(.roundedBorder)
                .focused($isFocused)
                .onSubmit(validate)
                .accessibilityLabel(LocalizedStringKey(title))
                .disabled(!isEditable)
            if let validation {
                Text(verbatim: validation)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .onChange(of: isFocused) { _, focused in
            if focused {
                editText = value
            } else {
                validate()
            }
        }
        .onChange(of: value) { _, _ in
            if !isFocused, validation != nil { validate() }
        }
    }

    private func validate() {
        guard !value.isEmpty else { validation = nil; return }
        guard UnitCalculatorNumberFormat.number(from: value) != nil else {
            validation = L10n.text("Enter a finite number.")
            return
        }
        validation = nil
    }
}

enum UnitCalculatorNumberFormat {
    static func g8(_ value: Double) -> String {
        String(format: "%.8G", locale: Locale.current, arguments: [value])
    }

    static func number(from string: String) -> Double? {
        let formatter = NumberFormatter()
        formatter.locale = .current
        formatter.numberStyle = .decimal
        formatter.isLenient = false
        if let number = formatter.number(from: string)?.doubleValue, number.isFinite { return number }
        guard let number = Double(string), number.isFinite else { return nil }
        return number
    }
}
