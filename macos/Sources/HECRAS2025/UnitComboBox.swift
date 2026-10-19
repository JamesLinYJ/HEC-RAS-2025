import SwiftUI

struct UnitComboBoxChoice: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
}

/// Native picker for a source unit list. Selection is the source unit's exact
/// stable identity; presentation uses the retained BaseUnitType.Name.
struct UnitComboBox: View {
    let label: String
    let choices: [DisplayUnitChoice]
    @Binding var selectedUnitID: String
    var isEnabled = true
    var minimumWidth: CGFloat = 72
    var maximumWidth: CGFloat = 135

    private var presentedChoices: [UnitComboBoxChoice] {
        Self.presentationChoices(from: choices, preserving: selectedUnitID)
    }

    var body: some View {
        Picker(selection: $selectedUnitID) {
            ForEach(presentedChoices) { choice in
                Text(verbatim: choice.title).tag(choice.id)
            }
        } label: {
            Text(verbatim: label)
        }
        .labelsHidden()
        .frame(minWidth: minimumWidth, maxWidth: maximumWidth)
        .disabled(!isEnabled)
        .accessibilityLabel(Text(verbatim: label))
    }

    static func presentationChoices(from sourceChoices: [DisplayUnitChoice], preserving selectedID: String) -> [UnitComboBoxChoice] {
        var choices = sourceChoices.map { choice in
            UnitComboBoxChoice(id: choice.id, title: choice.name.flatMap { $0.isEmpty ? nil : $0 } ?? choice.id)
        }
        if !choices.contains(where: { $0.id == selectedID }) {
            choices.insert(.init(id: selectedID, title: selectedID), at: 0)
        }
        return choices
    }
}
