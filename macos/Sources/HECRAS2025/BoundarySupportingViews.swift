import SwiftUI

enum BoundaryMeteorologicalSummaryPresentation {
    // SmallBoundaryConditionsSummary emits only these known display strings.
    // Any other value may be user-provided or come from a newer source enum,
    // so keep it verbatim instead of guessing at a translation.
    @MainActor
    static func text(sourceValue: String) -> String {
        if sourceValue == "(No Meteorological Data)" {
            return L10n.format("(%@)", L10n.text("No Meteorological Data"))
        }

        let prefix = "Precipitation: "
        guard sourceValue.hasPrefix(prefix), sourceValue.hasSuffix(")") else { return sourceValue }
        let body = sourceValue.dropFirst(prefix.count)
        guard let openingParen = body.lastIndex(of: "(") else { return sourceValue }

        let statusPart = String(body[..<openingParen]).trimmingCharacters(in: .whitespaces)
        guard let status = ["Enabled", "Disabled"].first(where: { $0 == statusPart }) else { return sourceValue }
        let type = String(body[body.index(after: openingParen)..<body.index(before: body.endIndex)])
        guard ["Constant", "Point", "Gridded"].contains(type) else { return sourceValue }

        return L10n.format("Precipitation: %@ (%@)", L10n.text(status), L10n.text(type))
    }
}

// AirPressureHeader is a GridView of SpatialDataTypePickerOption cards. The
// source option initializes HasData to true and displays a marker for it; the
// spatial type descriptions are the exact source converter's enum labels.
struct AirPressureHeaderView: View {
    let choices: [EditorChoice]
    @Binding var selectedType: String
    let isEnabled: Bool

    private let columns = [GridItem(.adaptive(minimum: 112, maximum: 180), spacing: 8)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            ForEach(choices) { choice in
                let selected = selectedType == choice.id
                Button {
                    selectedType = choice.id
                } label: {
                    VStack(spacing: 7) {
                        Image(systemName: symbol(for: choice.id))
                            .font(.title3)
                            .frame(height: 22)
                            .accessibilityHidden(true)
                        Text(choice.titleIsUserData == true ? choice.title : L10n.text(choice.title))
                            .font(.callout)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity, minHeight: 34)
                        if let description = description(for: choice.id) {
                            Text(L10n.text(description))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, minHeight: 30, alignment: .top)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 10)
                    .background(selected ? Color.accentColor.opacity(0.14) : Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
                    .overlay(alignment: .topTrailing) {
                        if selected {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(Color.accentColor)
                                .padding(5)
                                .accessibilityHidden(true)
                        }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        // SpatialDataTypePickerOption.HasData defaults to true
                        // in the retained control and is never reassigned there.
                        Circle()
                            .fill(Color.green)
                            .frame(width: 6, height: 6)
                            .padding(6)
                            .accessibilityHidden(true)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 9)
                            .strokeBorder(selected ? Color.accentColor : Color.secondary.opacity(0.24), lineWidth: selected ? 1.5 : 1)
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 9))
                }
                .buttonStyle(.plain)
                .disabled(!isEnabled)
                .accessibilityLabel(choice.titleIsUserData == true ? choice.title : L10n.text(choice.title))
                .accessibilityValue(L10n.text("Data available"))
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .accessibilityIdentifier("air-pressure-data-type-selector")
    }

    private func symbol(for type: String) -> String {
        switch type {
        case "Constant": "equal"
        case "Gridded": "square.grid.3x3"
        case "Point": "mappin.and.ellipse"
        default: "square.dashed"
        }
    }

    private func description(for type: String) -> String? {
        switch type {
        case "Constant": "A single value for all locations."
        case "Gridded": "Tiled data, from DSS or other raster."
        case "Point": "Use measurements taken from meteorology stations."
        default: nil
        }
    }
}

// The retained WindForcesControl pins both FromSelectedUnit values to m/s.
// Only the two constants are persisted model fields; the typed wind metadata
// supplies their shared display family without inventing editable unit fields.
struct WindConstantControlView: View {
    @ObservedObject var session: ModelEditorSession
    @ObservedObject var store: WorkspaceStore
    let layer: SpatialBoundaryLayer

    private var fields: [SourceEditorField] {
        SourceEditorLibrary.shared.schema("WindConstantControl")?.fields ?? []
    }
    private var valueUnits: DisplayUnitData? {
        session.spatialPresentations[layer.id]?.pointData?.valueUnits
    }
    var body: some View {
        ForEach(fields) { field in
            let componentTitle: String? = switch field.id {
            case "Constant1": "Vx"
            case "Constant2": "Vy"
            default: nil
            }
            if let componentTitle, let valueUnits {
                SpatialValueField(title: componentTitle, field: field.storageID, units: valueUnits, session: session,
                    minimum: field.minimum, maximum: field.maximum,
                    sourceFieldCanEdit: { field.canEditDraft(in: session) && !store.isSavingAll })
                    .disabled(store.isSavingAll)
            } else {
                // The source schema exposes only the two persisted constants.
                // Preserve their editable source fields if typed unit metadata
                // is unavailable; unit choices are never synthesized here.
                SourceField(field: componentTitle.map { field.titled($0) } ?? field, session: session, store: store)
            }
        }
    }
}

// The original header shows the selected BoundaryCondition.Name and exposes
// the source context action that opens that boundary condition's editor.
struct DetailedBoundaryConditionHeaderView: View {
    let boundaryConditionName: String?
    var openEditor: (() -> Void)? = nil

    @ViewBuilder
    var body: some View {
        if let boundaryConditionName, !boundaryConditionName.isEmpty {
            Text(boundaryConditionName)
                .font(.headline)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contextMenu {
                    if let openEditor {
                        Button("Open Editor", systemImage: "pencil", action: openEditor)
                    }
                }
                .accessibilityIdentifier("detailed-boundary-condition-header")
        }
    }
}

enum BoundaryConditionSelectionInitialization {
    static func singleChoiceSelection(current: String, selectionIsUninitialized: Bool,
                                      choiceIDs: [String], isEnabled: Bool) -> String? {
        guard selectionIsUninitialized, isEnabled, choiceIDs.count == 1,
              current != choiceIDs[0] else { return nil }
        return choiceIDs[0]
    }
}

// BoundaryConditionPicker's source collection is supplied by its caller. The
// one-item default is applied only while the binding has no source value yet;
// an explicit empty value represents the user's None choice and is preserved.
struct BoundaryConditionPickerControl: View {
    let choices: [EditorChoice]
    @Binding var selection: String
    let selectionIsUninitialized: Bool
    var isEnabled = true
    var emptySelectionTitle = "Select a Boundary Condition"
    var openEditor: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker(LocalizedStringKey("Boundary Condition"), selection: $selection) {
                Text(LocalizedStringKey(emptySelectionTitle)).tag("")
                ForEach(choices) { choice in
                    Text(choice.titleIsUserData == true ? choice.title : L10n.text(choice.title)).tag(choice.id)
                }
            }
            .disabled(!isEnabled || choices.isEmpty)
            .onAppear(perform: autoSelectSingleChoice)
            .onChange(of: choices.map(\.id)) { _, _ in autoSelectSingleChoice() }
            .onChange(of: selectionIsUninitialized) { _, _ in autoSelectSingleChoice() }

            if choices.isEmpty {
                Label(L10n.text("Boundary condition options are unavailable."), systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            DetailedBoundaryConditionHeaderView(
                boundaryConditionName: selectedChoice?.titleIsUserData == true
                    ? selectedChoice?.title
                    : selectedChoice.map { L10n.text($0.title) },
                openEditor: selectedChoice == nil ? nil : openEditor
            )
        }
        .accessibilityIdentifier("boundary-condition-picker")
    }

    private var selectedChoice: EditorChoice? { choices.first { $0.id == selection } }

    private func autoSelectSingleChoice() {
        guard let initialSelection = BoundaryConditionSelectionInitialization.singleChoiceSelection(
            current: selection,
            selectionIsUninitialized: selectionIsUninitialized,
            choiceIDs: choices.map(\.id),
            isEnabled: isEnabled
        ) else { return }
        selection = initialSelection
    }
}

// EquationDropDown exposes the two source actions and writes the selected
// BankEquation through the supplied binding. It is enabled only when the
// caller has a real model binding.
struct TractiveForceEquationDropDown: View {
    @Binding var equation: String
    var isEnabled = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ForEach(TractiveForceEquationChoice.allCases, id: \.rawValue) { choice in
                    equationButton(choice)
                }
            }
        }
        .accessibilityIdentifier("tractive-force-equation-selector")
    }

    private func equationButton(_ choice: TractiveForceEquationChoice) -> some View {
        Button {
            equation = choice.rawValue
        } label: {
            Label(L10n.text(choice.rawValue), systemImage: equation == choice.rawValue ? "largecircle.fill.circle" : "circle")
        }
        .buttonStyle(.bordered)
        .disabled(!isEnabled)
        .accessibilityAddTraits(equation == choice.rawValue ? .isSelected : [])
    }
}

private enum TractiveForceEquationChoice: String, CaseIterable {
    case strickler = "Strickler"
    case manning = "Manning"
}
