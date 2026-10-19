import Foundation
import RASWorkspaceCore
import SwiftUI

struct DisplayUnitChoice: Decodable, Identifiable, Sendable {
    let id: String
    let scale: Double
    let offset: Double
    let unitTypeId: String?
    let name: String?
    init(id: String, scale: Double, offset: Double, unitTypeId: String? = nil, name: String? = nil) {
        self.id = id; self.scale = scale; self.offset = offset; self.unitTypeId = unitTypeId; self.name = name
    }
    func displayed(_ source: Double) -> Double { source * scale + offset }
    func source(_ displayed: Double) -> Double { (displayed - offset) / scale }
    func string(_ source: String) -> String {
        guard let value = Double(source), value.isFinite else { return source }
        return String(displayed(value))
    }
    func edited(_ displayed: Double?, previous: String) -> String? {
        guard let displayed else { return previous.isEmpty ? nil : "" }
        if let current = Double(previous), self.displayed(current) == displayed { return nil }
        return String(source(displayed))
    }
}
struct DisplayUnitData: Decodable, Sendable {
    let sourceId: String
    let selectionId: String
    let choices: [DisplayUnitChoice]
    let sourceUnitTypeId: String?
    init(sourceId: String, selectionId: String, choices: [DisplayUnitChoice], sourceUnitTypeId: String? = nil) {
        self.sourceId = sourceId; self.selectionId = selectionId; self.choices = choices
        self.sourceUnitTypeId = sourceUnitTypeId
    }
    func validate() throws {
        guard !selectionId.isEmpty, !sourceId.isEmpty, !choices.isEmpty,
              Set(choices.map(\.id)).count == choices.count,
              choices.allSatisfy({ !$0.id.isEmpty && $0.scale.isFinite && $0.scale > 0 && $0.offset.isFinite }),
              choices.contains(where: { $0.id == sourceId && $0.scale == 1 && $0.offset == 0 }) else {
            throw ProjectFileError.invalid("Invalid source display units.")
        }
        if let sourceUnitTypeId {
            guard !sourceUnitTypeId.isEmpty,
                  choices.allSatisfy({ $0.unitTypeId?.isEmpty == false }),
                  Set(choices.compactMap(\.unitTypeId)).count == choices.count,
                  choices.contains(where: { $0.id == sourceId && $0.unitTypeId == sourceUnitTypeId }) else {
                throw ProjectFileError.invalid("Invalid source display units.")
            }
        }
    }
}

struct DisplayUnitPicker: View {
    let units: DisplayUnitData
    @ObservedObject var session: ModelEditorSession
    var isEnabled = true

    private var selectedUnitID: Binding<String> {
        Binding(
            get: { session.displayUnitSelections[units.selectionId] ?? units.sourceId },
            set: { session.selectDisplayUnit($0, units: units) }
        )
    }

    private var canSelect: Bool {
        isEnabled && session.canEdit && !session.isBusy && !session.loadingSelection
            && !session.hasUnitNumberInputDraft(selectionID: units.selectionId)
    }

    var body: some View {
        UnitComboBox(
            label: L10n.text("Display Units"),
            choices: units.choices,
            selectedUnitID: selectedUnitID,
            isEnabled: canSelect
        )
    }
}

struct UnitNumberField: View {
    let title: String
    let owner: OriginalUnitNumberInputOwner
    let units: DisplayUnitData
    @ObservedObject var session: ModelEditorSession
    var isEnabled = true
    var titleIsLocalized = false

    @FocusState private var isFocused: Bool
    @State private var focusContext: OriginalUnitNumberInputContext?
    @State private var focusedText: String?

    private var locale: Locale { .autoupdatingCurrent }
    private var context: OriginalUnitNumberInputContext? {
        session.unitNumberInputContext(for: owner, units: units, locale: locale)
    }
    private var draft: OriginalUnitNumberInputDraft? {
        session.unitNumberInputDraft(for: owner, units: units, locale: locale)
    }
    private var unit: DisplayUnitChoice? {
        guard let context else { return nil }
        return units.choices.first { $0.id == context.unitID }
    }
    private var text: Binding<String> {
        Binding(get: {
            if let draft, !draft.isStale { return draft.rawDisplayText }
            guard let context, let unit else { return "" }
            return OriginalUnitNumberInputCodec.fieldText(sourceValue: context.sourceValue, unit: unit,
                locale: locale, focusedText: isFocused ? focusedText : nil)
        }, set: { rawText in
            focusedText = rawText
            if let nextContext = session.updateUnitNumberInput(rawText: rawText, owner: owner,
                units: units, locale: locale, expectedContext: focusContext) {
                focusContext = nextContext
            }
        })
    }
    private var isStale: Bool { draft?.isStale == true }
    private var canEdit: Bool {
        isEnabled && session.loaded && session.canEdit && !session.isBusy && !session.loadingSelection
            && !session.workspaceWriteLocked() && !isReadOnly
    }
    private var isReadOnly: Bool {
        switch owner {
        case .field(let fieldID):
            session.readOnlyFieldIDs.contains(fieldID) || SourceEditorLibrary.shared.field(storageID: fieldID)?.readOnly == true
        case .tableCell(let tableID, _, let columnID):
            session.tablePresentations[tableID]?.columns.first(where: { $0.id == columnID })?.readOnly == true
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if isStale, let draft {
                HStack(spacing: 6) {
                    Text(draft.rawDisplayText).textSelection(.enabled).foregroundStyle(.secondary)
                    Button(L10n.text("Discard")) {
                        session.clearUnitNumberInputDraft(for: owner)
                        focusContext = nil
                        focusedText = nil
                        isFocused = false
                    }
                    .buttonStyle(.link)
                    .disabled(session.workspaceWriteLocked())
                }
                Text(L10n.text(OriginalUnitNumberInputIssue.staleNumber))
                    .font(.caption).foregroundStyle(.red)
            } else {
                TextField(text: text) {
                    titleIsLocalized ? Text(verbatim: title) : Text(LocalizedStringKey(title))
                }
                    .focused($isFocused)
                    .disabled(!canEdit || context == nil)
                if let issue = draft?.issueKey {
                    Text(L10n.text(issue)).font(.caption).foregroundStyle(.red)
                }
            }
        }
        .task(id: context) {
            session.reconcileUnitNumberInputDraft(for: owner, units: units, locale: locale,
                focusedContext: isFocused ? focusContext : nil,
                focusedRawText: isFocused ? focusedText : nil)
        }
        .onChange(of: isFocused) { _, focused in
            if focused {
                focusContext = draft?.context ?? context
                focusedText = draft?.isStale == false ? draft?.rawDisplayText : nil
            } else {
                session.reconcileUnitNumberInputDraft(for: owner, units: units, locale: locale,
                    focusedContext: focusContext, focusedRawText: focusedText)
                let remainingDraft = session.unitNumberInputDraft(for: owner)
                focusContext = remainingDraft?.context
                focusedText = nil
            }
        }
    }
}

struct SpatialValueField: View {
    let title: String
    let field: String
    let units: DisplayUnitData
    @ObservedObject var session: ModelEditorSession
    var showUnitPicker = true
    var unitPickerEnabled = true
    var minimum: Double? = nil
    var maximum: Double? = nil
    var sourceFieldCanEdit: (() -> Bool)? = nil
    var onSubmit: (@MainActor () -> Void)? = nil

    private var isEditable: Bool {
        (sourceFieldCanEdit?() ?? true) && session.canEdit && !session.isBusy && !session.loadingSelection
            && !session.readOnlyFieldIDs.contains(field) && session.fields[field] != nil
    }
    private var numericOwner: OriginalUnitNumberInputOwner { .field(field) }
    private var canUseCalculator: Bool {
        isEditable && !session.hasUnitNumberInputDraft(selectionID: units.selectionId)
    }

    var body: some View {
        HStack {
            if let unit = session.displayUnit(units) {
                let calculatorContext = calculatorContext(for: unit)
                UnitNumberField(title: title, owner: numericOwner, units: units, session: session,
                    isEnabled: isEditable)
                    .onSubmit { onSubmit?() }
                if let fromUnitTypeID = unit.unitTypeId,
                   let storageUnitTypeID = units.sourceUnitTypeId {
                    OriginalUnitCalculatorButton(
                        title: title,
                        rawValue: Binding(get: { session.fields[field] ?? "" }, set: { session.set(field, $0) }),
                        contextID: calculatorContext.id,
                        canCommit: calculatorContext.canCommit,
                        fromUnitTypeID: fromUnitTypeID,
                        storageUnitTypeID: storageUnitTypeID,
                        isEditable: canUseCalculator,
                        minimum: minimum,
                        maximum: maximum,
                        normalizeRawValue: normalizeSourceValue,
                        invalidRawValueMessage: L10n.text("The value does not meet the source field requirements."),
                        onCommit: onSubmit
                    )
                }
            }
            if showUnitPicker { DisplayUnitPicker(units: units, session: session, isEnabled: isEditable && unitPickerEnabled) }
        }
    }

    private func calculatorContext(for unit: DisplayUnitChoice) -> (id: String, canCommit: @MainActor () -> Bool) {
        let ownerIdentity = session.numericCalculatorIdentity
        let ownerValue = session.fields[field]
        let selectedUnitID = unit.id
        let selectedUnitTypeID = unit.unitTypeId
        let selectedScale = unit.scale
        let selectedOffset = unit.offset
        let selectedSourceID = units.sourceId
        let selectedSelectionID = units.selectionId
        let storageUnitTypeID = units.sourceUnitTypeId
        let editableAtOpen = isEditable
        let rawComponent = ownerValue.map { "set:\(String(reflecting: $0))" } ?? "missing"
        let parts = [
            ownerIdentity, field, rawComponent, selectedSelectionID, selectedSourceID,
            selectedUnitID, selectedUnitTypeID ?? "", storageUnitTypeID ?? "",
            String(selectedScale), String(selectedOffset), String(editableAtOpen)
        ]
        let id = parts.map { "\($0.utf8.count):\($0)" }.joined()
        let canCommit: @MainActor () -> Bool = {
            guard let currentUnit = session.displayUnit(units) else { return false }
            return session.numericCalculatorIdentity == ownerIdentity
                && session.fields[field] == ownerValue
                && currentUnit.id == selectedUnitID
                && currentUnit.unitTypeId == selectedUnitTypeID
                && currentUnit.scale == selectedScale
                && currentUnit.offset == selectedOffset
                && units.sourceId == selectedSourceID
                && units.selectionId == selectedSelectionID
                && units.sourceUnitTypeId == storageUnitTypeID
                && canUseCalculator
        }
        return (id, canCommit)
    }

    private var normalizeSourceValue: ((Double) -> Double?)? {
        if field.hasSuffix("/ElevationOffGround") {
            return { value in value.isFinite && Float(value).isFinite ? value : nil }
        }
        if field.hasSuffix("/Interval") {
            return SourceNumericValueNormalization.timeSpanTotalSeconds
        }
        return nil
    }
}

enum SourceNumericValueNormalization {
    /// Mirrors IntervalPicker's TimeSpan tick rounding while keeping the wire
    /// value in total seconds. Its smallest displayed unit is milliseconds,
    /// but fractional millisecond input remains valid down to a 100 ns tick.
    static func timeSpanTotalSeconds(_ seconds: Double) -> Double? {
        guard seconds.isFinite, seconds > 0 else { return nil }
        let rawTicks = seconds * 10_000_000
        guard rawTicks.isFinite, rawTicks < Double(Int64.max) else { return nil }
        let roundedTicks = rawTicks.rounded(.toNearestOrEven)
        guard roundedTicks < Double(Int64.max),
              let ticks = Int64(exactly: roundedTicks), ticks > 0 else { return nil }
        return Double(ticks) / 10_000_000
    }
}
