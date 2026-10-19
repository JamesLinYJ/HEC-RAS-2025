import Foundation
import Testing
@testable import HECRAS2025

@MainActor
struct UnitNumberInputDraftTests {
    private let tableID = "Spatial/precipitation/Gauge/gauge-1/Time Series/Values"

    private func units(selectionID: String = "UnitNumberInputDraftTests/value") -> DisplayUnitData {
        DisplayUnitData(sourceId: "m", selectionId: selectionID, choices: [
            .init(id: "m", scale: 1, offset: 0, unitTypeId: "Length::m", name: "Meter"),
            .init(id: "ft", scale: 3.280839895013123, offset: 0, unitTypeId: "Length::ft", name: "Foot")
        ], sourceUnitTypeId: "Length::m")
    }

    private func tableSession(value: String = "0") -> ModelEditorSession {
        let session = ModelEditorSession()
        session.startDraft(.init(fields: [:], rows: [tableID: [
            .init(id: "0", values: ["Time": "0", "Value": value])
        ]], samples: [:], canEdit: true, images: [:], tablePresentations: [tableID: .init(columns: [
            .init(id: "Time", title: "Time", sourceType: "double", readOnly: true),
            .init(id: "Value", title: "Value", sourceType: "double")
        ])]))
        return session
    }

    @Test
    func codecUsesLocaleAndRejectsTrailingGarbage() {
        #expect(OriginalUnitNumberInputCodec.parse("1.234,5", locale: Locale(identifier: "de_DE")) == 1234.5)
        #expect(OriginalUnitNumberInputCodec.parse("1,25", locale: Locale(identifier: "de_DE")) == 1.25)
        #expect(OriginalUnitNumberInputCodec.parse("1,25E2", locale: Locale(identifier: "de_DE")) == 125)
        #expect(OriginalUnitNumberInputCodec.parse("1,25x", locale: Locale(identifier: "de_DE")) == nil)
        #expect(OriginalUnitNumberInputCodec.parse("1.", locale: Locale(identifier: "en_US")) == 1)
        #expect(OriginalUnitNumberInputCodec.parse("1,", locale: Locale(identifier: "de_DE")) == 1)
        #expect(OriginalUnitNumberInputCodec.parse("1.0", locale: Locale(identifier: "en_US")) == 1)
    }

    @Test
    func focusedDecimalTextIsNotNormalizedUntilFocusEnds() {
        let unit = DisplayUnitChoice(id: "m", scale: 1, offset: 0)
        #expect(OriginalUnitNumberInputCodec.fieldText(sourceValue: "1", unit: unit,
            locale: Locale(identifier: "en_US"), focusedText: "1.") == "1.")
        #expect(OriginalUnitNumberInputCodec.fieldText(sourceValue: "1", unit: unit,
            locale: Locale(identifier: "en_US"), focusedText: "1.0") == "1.0")
        #expect(OriginalUnitNumberInputCodec.fieldText(sourceValue: "1", unit: unit,
            locale: Locale(identifier: "en_US"), focusedText: nil) == "1")
    }

    @Test
    func unresolvedFieldTextStaysOutsideBusinessValuesAndBlocksSaveUntilDiscard() async {
        let fieldID = "UnitNumberInputDraftTests/Value"
        let session = ModelEditorSession()
        session.startDraft(.init(fields: [fieldID: "4.5"], rows: [:], samples: [:], canEdit: true, images: [:]))
        let owner = OriginalUnitNumberInputOwner.field(fieldID)
        let units = units()

        let context = session.updateUnitNumberInput(rawText: "1,25x", owner: owner, units: units,
            locale: Locale(identifier: "de_DE"))
        #expect(context != nil)
        #expect(session.fields[fieldID] == "4.5")
        #expect(session.unitNumberInputDraft(for: owner)?.rawDisplayText == "1,25x")
        #expect(session.hasIncompleteEditorInput)
        #expect(session.hasUnsavedEditorChanges)
        #expect(session.incompleteEditorInputIssue == L10n.text(OriginalUnitNumberInputIssue.invalidNumber))
        #expect(!(await session.saveLoadedModel()))
        #expect(session.error == L10n.text(OriginalUnitNumberInputIssue.blockedBeforeSave))

        session.discardEdits()
        #expect(!session.hasIncompleteEditorInput)
        #expect(session.fields[fieldID] == "4.5")
    }

    @Test
    func tableDraftUsesExactTypedCellAndAffineUnitConversion() throws {
        let session = tableSession()
        let units = units(selectionID: "\(tableID)/Value")
        let owner = OriginalUnitNumberInputOwner.tableCell(tableID: tableID, rowID: "0", columnID: "Value")
        let context = try #require(session.unitNumberInputContext(for: owner, units: units))
        #expect(context.sourceType == "double")
        #expect(context.fieldBindingID == nil)

        session.selectDisplayUnit("ft", units: units)
        #expect(session.hasUnitNumberInputDraft(selectionID: units.selectionId) == false)
        _ = session.updateUnitNumberInput(rawText: "10", owner: owner, units: units, locale: Locale(identifier: "en_US"))
        let stored = try #require(Double(session.rows[tableID]?.first?.values["Value"] ?? ""))
        #expect(abs(stored - 3.048) < 1e-12)
        #expect(session.unitNumberInputDraft(for: owner) == nil)
        #expect(session.modified)
    }

    @Test
    func staleCellDraftCannotOverwriteANewSourceValueAndUnitChoiceIsLocked() throws {
        let session = tableSession()
        let units = units(selectionID: "(tableID)/Value")
        let owner = OriginalUnitNumberInputOwner.tableCell(tableID: tableID, rowID: "0", columnID: "Value")
        let context = try #require(session.unitNumberInputContext(for: owner, units: units))

        _ = session.updateUnitNumberInput(rawText: "unfinished", owner: owner, units: units,
            locale: Locale(identifier: "en_US"), expectedContext: context)
        session.selectDisplayUnit("ft", units: units)
        #expect(session.displayUnitSelections[units.selectionId] == nil)

        session.rows[tableID] = [.init(id: "0", values: ["Time": "0", "Value": "6"])]
        session.reconcileUnitNumberInputDraft(for: owner, units: units)
        let draft = try #require(session.unitNumberInputDraft(for: owner, units: units))
        #expect(draft.isStale)
        #expect(draft.rawDisplayText == "unfinished")
        #expect(draft.issueKey == OriginalUnitNumberInputIssue.staleNumber)
        #expect(session.incompleteEditorInputIssue == L10n.text(OriginalUnitNumberInputIssue.staleNumber))

        _ = session.updateUnitNumberInput(rawText: "7", owner: owner, units: units,
            locale: Locale(identifier: "en_US"), expectedContext: context)
        #expect(session.rows[tableID]?.first?.values["Value"] == "6")
        #expect(session.unitNumberInputDraft(for: owner)?.isStale == true)

        session.clearUnitNumberInputDraft(for: owner)
        #expect(!session.hasIncompleteEditorInput)
    }

    @Test
    func focusedValidTextBecomesStaleInsteadOfVanishingAfterSourceChanges() throws {
        let session = tableSession()
        let units = units(selectionID: "(tableID)/Value")
        let owner = OriginalUnitNumberInputOwner.tableCell(tableID: tableID, rowID: "0", columnID: "Value")
        let focusContext = try #require(session.updateUnitNumberInput(rawText: "5.0", owner: owner, units: units,
            locale: Locale(identifier: "en_US")))
        #expect(Double(session.rows[tableID]?.first?.values["Value"] ?? "") == 5)
        session.rows[tableID] = [.init(id: "0", values: ["Time": "0", "Value": "8"])]

        session.reconcileUnitNumberInputDraft(for: owner, units: units, locale: Locale(identifier: "en_US"),
            focusedContext: focusContext, focusedRawText: "5.0")
        let stale = try #require(session.unitNumberInputDraft(for: owner, units: units, locale: Locale(identifier: "en_US")))
        #expect(stale.isStale)
        #expect(stale.rawDisplayText == "5.0")
        #expect(session.rows[tableID]?.first?.values["Value"] == "8")
        #expect(session.hasIncompleteEditorInput)
    }
}
