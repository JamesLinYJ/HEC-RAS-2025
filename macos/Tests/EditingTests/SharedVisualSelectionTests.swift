import Testing
@testable import HECRAS2025

struct SharedVisualSelectionTests {
    @Test
    func extendedSelectionPlainClickReplacesSelectionAndSetsAnchor() {
        var state = SharedVisualExtendedSelectionState(selectedIDs: ["hidden", "a"], anchorID: "a")

        state.select("c", orderedIDs: ["a", "b", "c"], modifiers: [])

        #expect(state.selectedIDs == ["c"])
        #expect(state.anchorID == "c")
    }

    @Test
    func extendedSelectionCommandClickTogglesWithoutLosingOtherSelections() {
        var state = SharedVisualExtendedSelectionState(selectedIDs: ["a", "b"], anchorID: "a")

        state.select("b", orderedIDs: ["a", "b", "c"], modifiers: [.command])
        #expect(state.selectedIDs == ["a"])
        #expect(state.anchorID == "b")

        state.select("c", orderedIDs: ["a", "b", "c"], modifiers: [.control])
        #expect(state.selectedIDs == ["a", "c"])
    }

    @Test
    func extendedSelectionShiftClickSelectsInclusiveRangeFromAnchor() {
        var state = SharedVisualExtendedSelectionState(selectedIDs: ["a", "outside"], anchorID: "a")

        state.select("c", orderedIDs: ["a", "b", "c", "d"], modifiers: [.shift])

        #expect(state.selectedIDs == ["a", "b", "c"])
        #expect(state.anchorID == "a")
    }

    @Test
    func extendedSelectionCommandShiftClickAddsInclusiveRange() {
        var state = SharedVisualExtendedSelectionState(selectedIDs: ["d"], anchorID: "a")

        state.select("c", orderedIDs: ["a", "b", "c", "d"], modifiers: [.command, .shift])

        #expect(state.selectedIDs == ["a", "b", "c", "d"])
        #expect(state.anchorID == "a")
    }
}
