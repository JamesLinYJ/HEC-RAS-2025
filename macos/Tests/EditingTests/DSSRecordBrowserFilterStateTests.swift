import Testing
@testable import HECRAS2025

struct DSSRecordBrowserFilterStateTests {
    @Test func typeFilterDistinguishesAllNoneUnknownAndEmptyValues() {
        var state = DSSRecordBrowserFilterState()
        state.updateRecordTypeOptions(["Regular Time Series", "Unknown", "Future Record Type", ""])

        #expect(state.allRecordTypesSelected)
        #expect(state.selectedRecordTypeCount == 4)
        #expect(state.includesRecordType("Unknown"))
        #expect(state.includesRecordType("Future Record Type"))
        #expect(state.includesRecordType(""))
        #expect(state.recordTypeOptions == ["Regular Time Series", "Unknown", "Future Record Type", ""])

        state.setRecordType("Unknown", selected: false)
        #expect(!state.allRecordTypesSelected)
        #expect(!state.includesRecordType("Unknown"))
        state.toggleAllRecordTypes()
        #expect(state.allRecordTypesSelected)

        state.toggleAllRecordTypes()
        #expect(state.selectedRecordTypeCount == 0)
        #expect(!state.includesRecordType("Regular Time Series"))
        #expect(!state.allRecordTypesSelected)
    }

    @Test func incrementalTypeChangesRetainSurvivorsAndSelectNewTypesButReloadResets() {
        var state = DSSRecordBrowserFilterState()
        state.updateRecordTypeOptions(["A", "B"])
        state.setRecordType("B", selected: false)

        state.updateRecordTypeOptions(["B", "C"])
        #expect(!state.includesRecordType("B"))
        #expect(state.includesRecordType("C"))
        #expect(state.recordTypeOptions == ["B", "C"])

        state.setPartSelection(.value("River"), at: 0)
        state.resetForCatalogLoad()
        state.updateRecordTypeOptions(["B", "C"])
        #expect(state.allRecordTypesSelected)
        #expect(state.partSelections == Array(repeating: .all, count: DSSRecordBrowserFilterState.partCount))
    }

    @Test func sixPartFiltersAreAndedAndBlankIsDistinctFromAll() {
        var state = DSSRecordBrowserFilterState()
        state.setPartSelection(.blank, at: 0)
        state.setPartSelection(.value("Stage"), at: 2)

        #expect(state.matchesParts(["", "River", "Stage", "Flow", "01JAN2000", "1HOUR"]))
        #expect(!state.matchesParts(["A", "River", "Stage", "Flow", "01JAN2000", "1HOUR"]))
        #expect(!state.matchesParts(["", "River", "Flow", "Flow", "01JAN2000", "1HOUR"]))

        state.setPartSelection(.all, at: 0)
        #expect(state.matchesParts(["A", "River", "Stage", "Flow", "01JAN2000", "1HOUR"]))
    }
}
