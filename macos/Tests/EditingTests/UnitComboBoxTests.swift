import Foundation
import Testing
@testable import HECRAS2025

@MainActor
struct UnitComboBoxTests {
    @Test func unitNameDecodesOptionallyForLegacyPayloads() throws {
        let legacy = try JSONDecoder().decode(DisplayUnitChoice.self, from: Data(#"{"id":"ft","scale":1,"offset":0}"#.utf8))
        let named = try JSONDecoder().decode(DisplayUnitChoice.self, from: Data(#"{"id":"ft","scale":1,"offset":0,"name":"Foot"}"#.utf8))

        #expect(legacy.name == nil)
        #expect(named.id == "ft")
        #expect(named.name == "Foot")
    }

    @Test func pickerUsesSourceNamesInOrderAndRetainsMissingSelectionIdentity() {
        let choices = [
            DisplayUnitChoice(id: "m", scale: 1, offset: 0, unitTypeId: "Length", name: "Meter"),
            DisplayUnitChoice(id: "ft", scale: 0.3048, offset: 0, unitTypeId: "Length")
        ]

        let displayed = UnitComboBox.presentationChoices(from: choices, preserving: "legacy-unit")
        #expect(displayed.map(\.id) == ["legacy-unit", "m", "ft"])
        #expect(displayed.map(\.title) == ["legacy-unit", "Meter", "ft"])

        let availableSelection = UnitComboBox.presentationChoices(from: choices, preserving: "ft")
        #expect(availableSelection.map(\.id) == ["m", "ft"])
        #expect(availableSelection.last?.title == "ft")
    }
}
