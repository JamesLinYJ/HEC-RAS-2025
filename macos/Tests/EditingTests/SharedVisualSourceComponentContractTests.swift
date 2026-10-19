import Testing
import SwiftUI
@testable import HECRAS2025

struct SharedVisualSourceComponentContractTests {
    @MainActor
    @Test
    func indexedRepeaterPreservesSourceIndexFlagsAndSkipMembership() {
        let items = SharedVisualIndexedRepeater<EmptyView>.sourceItems(
            start: -1,
            count: 3,
            skippedIndexes: [-1, 1]
        )

        #expect(items.map(\.index) == [-1, 0, 2])
        #expect(items.map(\.isFirstIndex) == [false, true, false])
        #expect(items.map(\.isLastIndex) == [true, false, false])
    }

    @MainActor
    @Test
    func indexedRepeaterCountZeroKeepsTheExistingCollection() {
        let previous = SharedVisualIndexedRepeater<EmptyView>.sourceItems(start: 0, count: 2, skippedIndexes: [])
        let rebuilt = SharedVisualIndexedRepeater<EmptyView>.rebuiltItems(
            previous: previous,
            start: 5,
            count: 0,
            skippedIndexes: []
        )

        #expect(rebuilt == previous)
    }

    @Test
    func betterComboBoxSelectsOnlyTheFirstAvailableItemWhenConfiguredToDoSo() {
        let items = [(id: "disabled", isSelectable: false), (id: "ready", isSelectable: true)]
        #expect(SharedVisualBetterComboBoxSelection.firstSelectableID(
            selectedID: nil,
            items: items,
            selectsFirstWhenUnselected: true
        ) == "ready")
        #expect(SharedVisualBetterComboBoxSelection.firstSelectableID(
            selectedID: "existing",
            items: items,
            selectsFirstWhenUnselected: true
        ) == nil)
        #expect(SharedVisualBetterComboBoxSelection.firstSelectableID(
            selectedID: nil,
            items: items,
            selectsFirstWhenUnselected: false
        ) == nil)
    }

    @Test
    func comboBoxRunsPlaceholderForceSetBeforeSelectionAndValueChangedCallbacks() {
        var events: [String] = []
        var selectedID: String?

        SharedVisualComboBoxSelectionTransition.perform(
            "choice",
            beforeSelection: { events.append("force:\($0)") },
            setSelection: { selectedID = $0; events.append("select:\($0)") },
            selectionChanged: { events.append("changed:\($0)") }
        )

        #expect(selectedID == "choice")
        #expect(events == ["force:choice", "select:choice", "changed:choice"])
    }

    @Test
    func extendedListSelectionDropsRemovedItemsAndStaleAnchors() {
        var selection = SharedVisualExtendedSelectionState(selectedIDs: ["a", "removed"], anchorID: "removed")
        selection.retainAvailableItems(["a", "b"])
        #expect(selection.selectedIDs == ["a"])
        #expect(selection.anchorID == nil)
    }

    @Test
    func slidePickerPreservesIndexWhenItemsReorderAndClampsWhenTheyShrink() {
        #expect(SharedVisualSlidePickerSelection.normalizedIndex(2, itemCount: 3) == 2)
        #expect(SharedVisualSlidePickerSelection.normalizedIndex(2, itemCount: 2) == 1)
        #expect(SharedVisualSlidePickerSelection.normalizedIndex(0, itemCount: 0) == -1)
        #expect(SharedVisualSlidePickerSelection.nextIndex(2, itemCount: 3) == 0)
        #expect(SharedVisualSlidePickerSelection.nextIndex(0, itemCount: 0) == nil)
    }

    @Test
    func slidePickerRemovesRepeatedStableItemsWithoutReorderingTheRest() {
        let items = [
            SlidePickerItemPresentation(id: "a", title: "First"),
            SlidePickerItemPresentation(id: "a", title: "Duplicate"),
            SlidePickerItemPresentation(id: "b", title: "Second")
        ]

        #expect(SharedVisualSlidePickerSelection.orderedUniqueItems(items).map(\.title) == ["First", "Second"])
    }

    @Test
    func sliderNumberBoxAppliesTheSourceIncrementAndRejectsNonFiniteValues() {
        #expect(SharedVisualSliderNumberBoxState.value(current: 12, horizontalDelta: 2.5, increment: 0.2) == 12.5)
        #expect(SharedVisualSliderNumberBoxState.value(current: 12, horizontalDelta: -1, increment: -0.5) == 12.5)
        #expect(SharedVisualSliderNumberBoxState.value(current: .infinity, horizontalDelta: 1, increment: 1) == nil)
        #expect(SharedVisualSliderNumberBoxState.value(current: 1, horizontalDelta: .nan, increment: 1) == nil)
        #expect(SharedVisualSliderNumberBoxState.parse("1,234.5", locale: Locale(identifier: "en_US")) == 1234.5)
        #expect(SharedVisualSliderNumberBoxState.parse("NaN", locale: Locale(identifier: "en_US"))?.isNaN == true)
        #expect(SharedVisualSliderNumberBoxState.parse("not a number", locale: Locale(identifier: "en_US")) == nil)
        #expect(SharedVisualSliderNumberBoxState.invalidInputMessage("", locale: Locale(identifier: "en_US")) == nil)
        #expect(SharedVisualSliderNumberBoxState.invalidInputMessage("not a number", locale: Locale(identifier: "en_US")) == "The current input is not a valid number.")
    }

    @Test
    func dualPanelRebalancesMeasuredHeightsAndHonorsTheMeasurementThreshold() {
        let columns = SharedVisualDualPanelRebalancer.rebalance(items: ["a", "b"]) { _ in 20 }
        #expect(columns.0 == ["a"])
        #expect(columns.1 == ["b"])

        let rebalanced = SharedVisualDualPanelRebalancer.rebalance(items: [10, 10, 10, 10]) { CGFloat($0) }
        #expect(rebalanced.0 == [10, 10])
        #expect(rebalanced.1 == [10, 10])

        #expect(SharedVisualDualPanelRebalancer.shouldAcceptMeasurement(previousHeight: 100, proposedHeight: 109) == false)
        #expect(SharedVisualDualPanelRebalancer.shouldAcceptMeasurement(previousHeight: 100, proposedHeight: 110) == true)
        #expect(SharedVisualDualPanelRebalancer.shouldAcceptMeasurement(previousHeight: nil, proposedHeight: 4) == true)
        #expect(SharedVisualDualPanelRebalancer.shouldAcceptMeasurement(previousHeight: nil, proposedHeight: 0) == false)
    }

    @Test
    func dualPanelRebalancerMovesOnlyItemsThatReduceTheMeasuredHeightDifference() {
        let heights = [10, 9, 1]
        let columns = SharedVisualDualPanelRebalancer.rebalance(items: heights) { CGFloat($0) }

        #expect(columns.0 == [10])
        #expect(columns.1 == [9, 1])
    }

    @Test
    func christmasTreeResolverUsesTheFirstAssignableNodeOrContextTemplate() {
        #expect(SharedVisualChristmasTreeTemplateResolver.matchingTypeName(
            candidates: ["BaseNode", "ContextBase"],
            nodeTypeName: "ConcreteNode",
            contextTypeName: "Context",
            nodeHierarchy: ["BaseNode"],
            contextHierarchy: ["ContextBase"]
        ) == "BaseNode")
        #expect(SharedVisualChristmasTreeTemplateResolver.matchingTypeName(
            candidates: ["Missing"],
            nodeTypeName: "ConcreteNode",
            contextTypeName: nil,
            nodeHierarchy: [],
            contextHierarchy: []
        ) == nil)
    }

    @Test
    func christmasTreeModeSelectionPreservesSourceNilAndNormalizesLegacyBinding() {
        let modeIDs = ["geometry", "terrain"]
        #expect(SharedVisualChristmasTreeSelection.normalizedModeID(
            selectedID: nil,
            modeIDs: modeIDs,
            selectsFirstWhenUnselected: false
        ) == nil)
        #expect(SharedVisualChristmasTreeSelection.normalizedModeID(
            selectedID: nil,
            modeIDs: modeIDs,
            selectsFirstWhenUnselected: true
        ) == "geometry")
        #expect(SharedVisualChristmasTreeSelection.normalizedModeID(
            selectedID: "removed",
            modeIDs: modeIDs,
            selectsFirstWhenUnselected: false
        ) == nil)
        #expect(SharedVisualChristmasTreeSelection.normalizedModeID(
            selectedID: "removed",
            modeIDs: modeIDs,
            selectsFirstWhenUnselected: true
        ) == "geometry")
    }

    @Test
    func christmasTreeSelectionPersistsPerModeIncludingAnExplicitClearedSelection() {
        var overrides: [String: String?] = [:]
        overrides = SharedVisualChristmasTreeSelection.settingSelectedNodeID("g1", for: "geometry", in: overrides)
        overrides = SharedVisualChristmasTreeSelection.settingSelectedNodeID("t2", for: "terrain", in: overrides)
        overrides = SharedVisualChristmasTreeSelection.settingSelectedNodeID(nil, for: "geometry", in: overrides)

        #expect(SharedVisualChristmasTreeSelection.selectedNodeID(modeID: "geometry", defaultNodeID: "g-default", overrides: overrides) == nil)
        #expect(SharedVisualChristmasTreeSelection.selectedNodeID(modeID: "terrain", defaultNodeID: "t-default", overrides: overrides) == "t2")
        #expect(SharedVisualChristmasTreeSelection.selectedNodeID(modeID: "plan", defaultNodeID: "p-default", overrides: overrides) == "p-default")
    }

    @Test
    func christmasTreeResolverMatchesContextAndItsSuppliedBaseTypeOrder() {
        #expect(SharedVisualChristmasTreeTemplateResolver.matchingTypeName(
            candidates: ["ConcreteContext", "ContextBase", "NodeBase"],
            nodeTypeName: "ConcreteNode",
            contextTypeName: "ConcreteContext",
            nodeHierarchy: ["NodeBase"],
            contextHierarchy: ["ContextBase"]
        ) == "ConcreteContext")
        #expect(SharedVisualChristmasTreeTemplateResolver.matchingTypeName(
            candidates: ["ContextBase", "NodeBase"],
            nodeTypeName: "ConcreteNode",
            contextTypeName: nil,
            nodeHierarchy: ["NodeBase"],
            contextHierarchy: ["ContextBase"]
        ) == "ContextBase")
    }

    @Test
    func triStateToggleCyclesNullThenOnThenOffAndClearsIndeterminate() {
        let on = SharedVisualTriStateState.cycledState(isChecked: nil, isIndeterminate: false)
        let off = SharedVisualTriStateState.cycledState(isChecked: on.isChecked, isIndeterminate: on.isIndeterminate)
        let resetOn = SharedVisualTriStateState.cycledState(isChecked: off.isChecked, isIndeterminate: off.isIndeterminate)

        #expect(on.isChecked && !on.isIndeterminate)
        #expect(!off.isChecked && !off.isIndeterminate)
        #expect(resetOn.isChecked && !resetOn.isIndeterminate)
        #expect(SharedVisualTriStateState.cycledState(isChecked: false, isIndeterminate: true).isChecked)
    }

    @Test
    func linkableComboBoxKeepsAnUnsetSelectionAndClearsAStaleSourceItem() {
        #expect(SharedVisualLinkableSelection.normalizedID(nil as String?, optionIDs: ["a", "b"]) == nil)
        #expect(SharedVisualLinkableSelection.normalizedID("stale", optionIDs: ["a", "b"]) == nil)
        #expect(SharedVisualLinkableSelection.normalizedID("b", optionIDs: ["a", "b"]) == "b")
    }

    @Test
    func alertBoxResponseOnlyAcceptsTheConfiguredPrimaryButton() {
        #expect(SharedVisualAlertBoxResponse.isAccepted(hasPrimaryButton: true, response: .alertFirstButtonReturn))
        #expect(!SharedVisualAlertBoxResponse.isAccepted(hasPrimaryButton: false, response: .alertFirstButtonReturn))
        #expect(!SharedVisualAlertBoxResponse.isAccepted(hasPrimaryButton: true, response: .alertSecondButtonReturn))
    }

    @Test
    func reflectionHighlightsRemainStickyUntilReset() {
        #expect(SharedVisualReflectionHighlightState.hasChanged(currentValue: "2", baselineValue: "1", wasChanged: false))
        #expect(SharedVisualReflectionHighlightState.hasChanged(currentValue: "1", baselineValue: "1", wasChanged: true))
        #expect(!SharedVisualReflectionHighlightState.hasChanged(currentValue: "1", baselineValue: "1", wasChanged: false))
    }

    @MainActor
    @Test
    func reflectionTreeTracksCurrentProviderValuesAndResetMovesTheBaseline() {
        final class MutableSource {
            var number = 1
        }

        let source = MutableSource()
        let tree = SharedVisualReflectionTreeState(provider: { source }, rootTitle: "Root", maxDepth: 1)
        tree.refresh()
        source.number = 2
        tree.startTracking("root/number")

        source.number = 3
        tree.refresh()
        let changedValue = tree.roots[0].children.first { $0.propertyName == "number" }
        #expect(changedValue?.isTracking == true)
        #expect(changedValue?.hasChanged == true)
        #expect(changedValue?.originalValue == "1")

        tree.resetAllHighlights()
        let resetValue = tree.roots[0].children.first { $0.propertyName == "number" }
        #expect(resetValue?.hasChanged == false)
        #expect(resetValue?.originalValue == "3")
    }

    @MainActor
    @Test
    func reflectionTreeClearsTrackingWhenTheLiveRootObjectChanges() {
        final class MutableSource {
            var number: Int

            init(number: Int) { self.number = number }
        }

        let first = MutableSource(number: 1)
        let second = MutableSource(number: 7)
        var current: Any? = first
        let tree = SharedVisualReflectionTreeState(provider: { current }, rootTitle: "Root", maxDepth: 1)
        tree.refresh()
        tree.startTracking("root/number")
        first.number = 2
        tree.refresh()
        #expect(tree.trackingIDs.contains("root/number"))

        current = second
        tree.refresh()
        let replacedValue = tree.roots[0].children.first { $0.propertyName == "number" }
        #expect(tree.trackingIDs.isEmpty)
        #expect(tree.changedIDs.isEmpty)
        #expect(replacedValue?.value == "7")
        #expect(replacedValue?.originalValue == "7")
    }
}
