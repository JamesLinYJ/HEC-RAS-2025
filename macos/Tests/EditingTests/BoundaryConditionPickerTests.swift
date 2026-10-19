import Testing
@testable import HECRAS2025

struct BoundaryConditionPickerTests {
    @Test
    func singleChoiceInitializationDoesNotReplaceAnExplicitNone() {
        let choiceID = "/project/Boundary Conditions/Observed.h5"

        #expect(BoundaryConditionSelectionInitialization.singleChoiceSelection(
            current: "", selectionIsUninitialized: true, choiceIDs: [choiceID], isEnabled: true
        ) == choiceID)
        #expect(BoundaryConditionSelectionInitialization.singleChoiceSelection(
            current: "", selectionIsUninitialized: false, choiceIDs: [choiceID], isEnabled: true
        ) == nil)
        #expect(BoundaryConditionSelectionInitialization.singleChoiceSelection(
            current: "", selectionIsUninitialized: true, choiceIDs: [choiceID, "/project/Boundary Conditions/Other.h5"], isEnabled: true
        ) == nil)
        #expect(BoundaryConditionSelectionInitialization.singleChoiceSelection(
            current: "", selectionIsUninitialized: true, choiceIDs: [choiceID], isEnabled: false
        ) == nil)
    }
}
