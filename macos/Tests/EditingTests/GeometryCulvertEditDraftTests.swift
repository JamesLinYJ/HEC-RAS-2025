import Testing
@testable import HECRAS2025

struct GeometryCulvertEditDraftTests {
    @Test
    func explicitlyChoosingFirstRowsCurrentValueRemainsAnApplyToSelectionEdit() {
        var drafts = GeometryCulvertEditDraftState()
        drafts.load(["BarrelPropertyName": "Barrel A"], contextIdentity: "selection-a|source-1|draft-0")

        #expect(!drafts.hasPendingValue(fieldID: "BarrelPropertyName"))
        drafts.stageApplyChoiceToSelection(fieldID: "BarrelPropertyName", value: "Barrel A")

        #expect(drafts.values["BarrelPropertyName"] == "Barrel A")
        #expect(drafts.hasPendingValue(fieldID: "BarrelPropertyName"))
        #expect(drafts.canApply(currentContextIdentity: "selection-a|source-1|draft-0"))

        drafts.acceptAppliedValue(fieldID: "BarrelPropertyName", value: "Barrel A",
            contextIdentity: "selection-a|source-1|draft-1")
        #expect(!drafts.hasPendingValue(fieldID: "BarrelPropertyName"))
        #expect(drafts.canApply(currentContextIdentity: "selection-a|source-1|draft-1"))
    }

    @Test
    func staleSelectionPreservesChoiceDraftAndRejectsApplyUntilReloaded() {
        var drafts = GeometryCulvertEditDraftState()
        drafts.load(["UpstreamOpeningName": "Opening A"], contextIdentity: "selection-a|source-1|draft-0")
        drafts.stageApplyChoiceToSelection(fieldID: "UpstreamOpeningName", value: "Opening A")

        #expect(drafts.hasPendingValue(fieldID: "UpstreamOpeningName"))
        #expect(drafts.isStale(currentContextIdentity: "selection-b|source-1|draft-0"))
        #expect(!drafts.canApply(currentContextIdentity: "selection-b|source-1|draft-0"))
        #expect(drafts.isStale(currentContextIdentity: "selection-a|source-2|draft-0"))
        #expect(!drafts.canApply(currentContextIdentity: "selection-a|source-2|draft-0"))
        #expect(drafts.values["UpstreamOpeningName"] == "Opening A")
        #expect(drafts.hasPendingEdits)

        drafts.load(["UpstreamOpeningName": "Opening B"], contextIdentity: "selection-b|source-1|draft-0")
        #expect(!drafts.hasPendingEdits)
        #expect(drafts.values["UpstreamOpeningName"] == "Opening B")
    }

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
