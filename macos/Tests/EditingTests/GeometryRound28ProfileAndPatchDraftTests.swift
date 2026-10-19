import Foundation
import Testing
@testable import HECRAS2025

struct GeometryRound28ProfileAndPatchDraftTests {
    @Test
    func culvertProfilesFollowSelectedIDsAndDisambiguateDuplicateNames() {
        let first = profile(id: "barrel:7", name: "North", x: 1)
        let second = profile(id: "barrel:12", name: "North", x: 3)
        let unrelated = profile(id: "barrel:99", name: "South", x: 9)

        let selected = GeometryCulvertProfilePresentation.selectedProfiles(
            [unrelated, second, first], barrelIDs: ["barrel:12", "barrel:7"])
        #expect(selected.map(\.barrelID) == ["barrel:12", "barrel:7"])
        #expect(GeometryCulvertProfilePresentation.selectedProfiles(
            [first, second], barrelIDs: []).isEmpty)

        let labels = GeometryCulvertProfilePresentation.legendLabels(for: selected)
        #expect(labels["barrel:7"] == "North · barrel:7")
        #expect(labels["barrel:12"] == "North · barrel:12")
        let labelsWithMissingProfile = GeometryCulvertProfilePresentation.labels(
            barrelIDs: ["barrel:7", "barrel:12"], profiles: [first],
            fallbackNames: ["barrel:12": "North"])
        #expect(labelsWithMissingProfile["barrel:7"] == "North · barrel:7")
        #expect(labelsWithMissingProfile["barrel:12"] == "North · barrel:12")
        #expect(GeometryCulvertProfilePresentation.plotProfiles([first]).count == 1)
    }

    @Test
    func patchSnapshotRefreshPreservesDirtyFieldsAndRefreshesCleanFields() {
        let identity = GeometryMeshPatchDimensionEditorIdentity(assetID: "geometry-a",
            featureIDs: [4, 2], axis: "NorthSouth")
        var draft = GeometryMeshPatchDimensionDraftState(identity: identity,
            source: .init(mode: "Constant", modeHasMismatch: false, liveValue: 1.0,
                liveValueHasMismatch: false))
        draft.setValue("2.5")

        draft.synchronize(with: .init(mode: "CountWithBias", modeHasMismatch: false, liveValue: 1.25,
            liveValueHasMismatch: false))

        #expect(draft.mode == "CountWithBias")
        #expect(draft.value == "2.5")
        #expect(draft.source.valueText == "1.25")

        var pendingMode = GeometryMeshPatchDimensionDraftState(identity: identity,
            source: .init(mode: "Constant", modeHasMismatch: false, liveValue: 1.0,
                liveValueHasMismatch: false))
        pendingMode.setMode("CountWithBias")
        pendingMode.synchronize(with: .init(mode: "Constant", modeHasMismatch: false, liveValue: 2.0,
            liveValueHasMismatch: false))
        #expect(pendingMode.mode == "CountWithBias")
    }

    @Test
    func confirmedApplyRefreshesOnlyTheSubmittedValueAndIgnoresLateOtherSelectionReplies() {
        let identity = GeometryMeshPatchDimensionEditorIdentity(assetID: "geometry-a",
            featureIDs: [2, 4], axis: "EastWest")
        var draft = GeometryMeshPatchDimensionDraftState(identity: identity,
            source: .init(mode: "Constant", modeHasMismatch: false, liveValue: 1.0,
                liveValueHasMismatch: true))
        draft.setValue("3.5")
        let requestID = UUID()
        let request = draft.beginValueRequest(mode: "Constant", value: "3.5", id: requestID)

        draft.synchronize(with: .init(mode: "Constant", modeHasMismatch: false, liveValue: 3.5,
            liveValueHasMismatch: false))
        #expect(draft.value == String(Float(3.5)))
        #expect(draft.pendingRequest == nil)

        let otherIdentity = GeometryMeshPatchDimensionEditorIdentity(assetID: "geometry-a",
            featureIDs: [9], axis: "EastWest")
        var otherDraft = GeometryMeshPatchDimensionDraftState(identity: otherIdentity,
            source: .init(mode: "Constant", modeHasMismatch: false, liveValue: 8.0,
                liveValueHasMismatch: false))
        otherDraft.finish(request, returnedSource: .init(mode: "Constant", modeHasMismatch: false,
            liveValue: 3.5, liveValueHasMismatch: false))
        #expect(otherDraft.identity == otherIdentity)
        #expect(otherDraft.value == "8.0")
    }

    @Test
    func mixedValueOverrideRequiresSourcePermissionAndValidSourceTypeInput() {
        let identity = GeometryMeshPatchDimensionEditorIdentity(assetID: "geometry-a",
            featureIDs: [1, 3], axis: "NorthSouth")
        var draft = GeometryMeshPatchDimensionDraftState(identity: identity,
            source: .init(mode: "Constant", modeHasMismatch: false, liveValue: nil,
                liveValueHasMismatch: true))
        draft.setValue("0.75")
        #expect(draft.submissionValue(canEdit: true, sourceCanApply: true, arcCount: 2,
            modeHasMismatch: false) == String(Float(0.75)))
        #expect(draft.submissionValue(canEdit: true, sourceCanApply: false, arcCount: 2,
            modeHasMismatch: false) == nil)
        #expect(draft.submissionValue(canEdit: true, sourceCanApply: true, arcCount: 0,
            modeHasMismatch: false) == nil)
        #expect(GeometryMeshPatchDimensionValue.normalized("1e100", mode: "Constant") == nil)
        #expect(GeometryMeshPatchDimensionValue.normalized("nan", mode: "Constant") == nil)
        #expect(GeometryMeshPatchDimensionValue.normalized("2.5", mode: "CountWithBias") == nil)
        #expect(GeometryMeshPatchDimensionValue.normalized("12", mode: "CountWithBias") == "12")
        #expect(GeometryMeshPatchDimensionValue.normalized("2147483648", mode: "CountWithBias") == nil)

        var mixedMode = GeometryMeshPatchDimensionDraftState(identity: identity,
            source: .init(mode: "Constant", modeHasMismatch: true, liveValue: nil,
                liveValueHasMismatch: true))
        mixedMode.setMode("Constant")
        mixedMode.setValue("0.75")
        #expect(mixedMode.submissionValue(canEdit: true, sourceCanApply: true, arcCount: 2,
            modeHasMismatch: true) == nil)
    }

    @Test
    func sameAssetAndSelectionInAnotherSourceRevisionDoesNotAcceptOldPatchReply() {
        let original = GeometryMeshPatchDimensionEditorIdentity(assetID: "same-geometry", featureIDs: [5],
            axis: "NorthSouth", sourceIdentity: "revision-a")
        var oldDraft = GeometryMeshPatchDimensionDraftState(identity: original,
            source: .init(mode: "Constant", modeHasMismatch: false, liveValue: 1, liveValueHasMismatch: false))
        oldDraft.setValue("3.5")
        let oldRequest = oldDraft.beginValueRequest(mode: "Constant", value: "3.5", id: UUID())
        let reloaded = GeometryMeshPatchDimensionEditorIdentity(assetID: "same-geometry", featureIDs: [5],
            axis: "NorthSouth", sourceIdentity: "revision-b")
        var current = GeometryMeshPatchDimensionDraftState(identity: reloaded,
            source: .init(mode: "Constant", modeHasMismatch: false, liveValue: 8, liveValueHasMismatch: false))
        current.finish(oldRequest, returnedSource: .init(mode: "Constant", modeHasMismatch: false,
            liveValue: 3.5, liveValueHasMismatch: false))
        #expect(current.value == "8.0")
        #expect(current.identity != original)
    }

    @Test
    func newerUnsubmittedInputSurvivesTheEarlierRequestReply() {
        let identity = GeometryMeshPatchDimensionEditorIdentity(assetID: "geometry-a",
            featureIDs: [5], axis: "NorthSouth")
        var draft = GeometryMeshPatchDimensionDraftState(identity: identity,
            source: .init(mode: "Constant", modeHasMismatch: false, liveValue: 1.0,
                liveValueHasMismatch: true))
        draft.setValue("3.5")
        let request = draft.beginValueRequest(mode: "Constant", value: "3.5", id: UUID())
        draft.setValue("4.25")

        draft.finish(request, returnedSource: .init(mode: "Constant", modeHasMismatch: false,
            liveValue: 3.5, liveValueHasMismatch: false))

        #expect(draft.source.valueText == "3.5")
        #expect(draft.value == "4.25")
        #expect(draft.pendingRequest == nil)
    }

    @Test
    func rejectedModeRequestDoesNotPresentTheRequestedModeAsApplied() {
        let identity = GeometryMeshPatchDimensionEditorIdentity(assetID: "geometry-a",
            featureIDs: [5], axis: "EastWest")
        let source = GeometryMeshPatchDimensionDraftSource(mode: "Constant", modeHasMismatch: false,
            liveValue: 1.0, liveValueHasMismatch: false)
        var draft = GeometryMeshPatchDimensionDraftState(identity: identity, source: source)
        draft.setMode("CountWithBias")
        let request = draft.beginModeRequest("CountWithBias", id: UUID())

        draft.finish(request, returnedSource: source)

        #expect(draft.mode == "Constant")
        #expect(draft.pendingRequest == nil)
    }

    private func profile(id: String, name: String, x: Double) -> GeometryCulvertProfile {
        GeometryCulvertProfile(barrelID: id, barrelName: name, length: 10, samples: [
            GeometryCulvertProfileSample(distance: 0, x: x, y: 0, elevation: 1),
            GeometryCulvertProfileSample(distance: 10, x: x + 10, y: 0, elevation: 2)
        ])
    }
}
