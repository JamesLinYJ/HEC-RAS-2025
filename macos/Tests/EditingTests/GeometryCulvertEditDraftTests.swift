import Testing
@testable import HECRAS2025

struct GeometryCulvertEditDraftTests {
    @Test
    func resettingMixedCoefficientRebasesOnlyThatFieldAndRetainsOtherPendingEdits() {
        var drafts = GeometryCulvertEditDraftState(
            values: ["KIn": "0.5", "UpstreamInvert": "41.25", "Name": "Pending name"],
            editedMixedCoefficientFields: ["KIn"], clearCommandFieldIDs: ["KIn"])

        drafts.acceptCoefficientReset(fieldID: "KIn", baselineValue: "")

        #expect(drafts.values["KIn"] == "")
        #expect(drafts.values["UpstreamInvert"] == "41.25")
        #expect(drafts.values["Name"] == "Pending name")
        #expect(drafts.editedMixedCoefficientFields.isEmpty)
        #expect(drafts.clearCommandFieldIDs.isEmpty)
    }

    @Test
    func acceptingForcedMixedChoiceRebasesOnlyCommandedFieldAndRetainsOtherPendingEdits() {
        var drafts = GeometryCulvertEditDraftState(
            values: ["OpeningType": "ConcretePipeCulvert_SquareEdgeWithHeadwall",
                "UpstreamInvert": "41.25", "Name": "Pending name"],
            forceSetCommandFieldIDs: ["OpeningType"])

        drafts.acceptSourceCommand(fieldID: "OpeningType", value: "ConcretePipeCulvert_GrooveEndWithHeadwall")

        #expect(drafts.values["OpeningType"] == "ConcretePipeCulvert_GrooveEndWithHeadwall")
        #expect(drafts.values["UpstreamInvert"] == "41.25")
        #expect(drafts.values["Name"] == "Pending name")
        #expect(drafts.forceSetCommandFieldIDs.isEmpty)
    }

    @Test
    func stagingSourceCommandsDoesNotReplaceOtherUnsubmittedFields() {
        var drafts = GeometryCulvertEditDraftState(
            values: ["KIn": "0.5", "OpeningType": "ConcretePipeCulvert_SquareEdgeWithHeadwall",
                "UpstreamInvert": "41.25", "Name": "Pending name"])

        drafts.stageClearCommand(fieldID: "KIn")
        drafts.stageForceSetCommand(fieldID: "OpeningType", value: "ConcretePipeCulvert_GrooveEndWithHeadwall")

        #expect(drafts.clearCommandFieldIDs == ["KIn"])
        #expect(drafts.forceSetCommandFieldIDs == ["OpeningType"])
        #expect(drafts.values["KIn"] == "")
        #expect(drafts.values["OpeningType"] == "ConcretePipeCulvert_GrooveEndWithHeadwall")
        #expect(drafts.values["UpstreamInvert"] == "41.25")
        #expect(drafts.values["Name"] == "Pending name")
    }
}
