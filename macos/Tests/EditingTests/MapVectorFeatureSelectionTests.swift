import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

@MainActor
struct MapVectorFeatureSelectionTests {
    @Test
    func selectionUsesExactLayerInstancesAndNeverLeaksAcrossMaps() {
        let firstMap = MapState(kind: .buildable, id: UUID())
        let secondMap = MapState(kind: .buildable, id: UUID())
        let features = [feature("a", 0), feature("b", 1), feature("c", 2)]
        let first = layer("one", map: firstMap.id, features: features)
        let second = layer("two", map: firstMap.id, features: features)
        #expect(firstMap.selectVectorFeature(features[0], in: first, mode: .replace))
        #expect(firstMap.selectVectorFeature(features[2], in: first, mode: .toggle))
        #expect(firstMap.selectedFeatureIdentities == ["a", "c"])
        #expect(secondMap.selectedFeatureIdentities.isEmpty)
        #expect(!secondMap.selectVectorFeature(features[0], in: first, mode: .replace))
        #expect(firstMap.selectVectorFeature(features[1], in: second, mode: .toggle))
        #expect(firstMap.selectedFeatureIdentities == ["b"])
        #expect(firstMap.selectedLayerID == "two")
        #expect(firstMap.selectVectorFeatures(["a", "c"], in: second, mode: .replace))
        #expect(firstMap.selectedFeatureIdentities == ["a", "c"])
        #expect(!firstMap.selectVectorFeatures(["missing"], in: second, mode: .replace))
        #expect(firstMap.selectedFeatureIdentities == ["a", "c"])
        #expect(!secondMap.selectVectorFeatures(["a"], in: second, mode: .replace))
        #expect(firstMap.selectVectorFeatures(["a", "b"], in: second, mode: .toggle))
        #expect(firstMap.selectedFeatureIdentities == ["a", "b", "c"])
        #expect(firstMap.selectVectorFeatures(["a", "b"], in: second, mode: .toggle))
        #expect(firstMap.selectedFeatureIdentities == ["c"])
        #expect(firstMap.selectedVectorFeatureIdentities(in: second) == ["c"])
        #expect(firstMap.selectedVectorFeatureIdentities(in: first).isEmpty)
        #expect(firstMap.selectVectorFeatures([], in: second, mode: .replace))
        #expect(firstMap.selectedFeatureIdentities.isEmpty)
        #expect(firstMap.selectedFeatureIdentity == nil)
    }

    @Test
    func revisionChangesHiddenSourcesAndAmbiguousIDsRetireTheActualSelection() {
        let map = MapState(kind: .buildable, id: UUID())
        let features = [feature("a", 0), feature("b", 1)]
        let original = layer("source", map: map.id, features: features)
        #expect(map.selectVectorFeature(features[0], in: original, mode: .replace))
        map.reconcileVectorFeatureSelection(visibleLayers: [layer("source", map: map.id,
            features: features, revision: "new-revision")])
        #expect(map.selectedFeatureIdentities.isEmpty)
        #expect(map.selectedFeatureIdentity == nil)
        #expect(map.selectVectorFeature(features[0], in: original, mode: .replace))
        map.reconcileVectorFeatureSelection(visibleLayers: [])
        #expect(map.selectedFeatureIdentities.isEmpty)
        let ambiguous = layer("source", map: map.id, features: [features[0], features[0]])
        #expect(!map.selectVectorFeature(features[0], in: ambiguous, mode: .replace))
    }

    @Test
    func filteredListRangesUseStableSourceOrderAndLegacyWritesRemainSingleSelection() {
        let map = MapState(kind: .buildable, id: UUID())
        let features = [feature("z", 0), feature("a", 1), feature("m", 2)]
        let source = layer("source", map: map.id, features: features)
        #expect(map.selectVectorFeature(features[0], in: source, mode: .replace))
        #expect(map.selectVectorFeature(features[2], in: source, mode: .range))
        #expect(map.selectedFeatureIdentities == ["z", "a", "m"])
        #expect(map.selectVectorFeature(features[1], in: source, mode: .toggle))
        #expect(map.selectedFeatureIdentities == ["z", "m"])
        map.selectedFeatureIdentity = "a"
        #expect(map.selectedFeatureIdentities == ["a"])
        map.selectedFeatureIdentity = nil
        #expect(map.selectedFeatureIdentities.isEmpty)
    }

    @Test
    func filteredRangesExcludeHiddenRowsWhileCommandExtendsTheExistingSet() {
        let map = MapState(kind: .buildable, id: UUID())
        let features = [feature("a", 0), feature("hidden", 1), feature("b", 2), feature("c", 3)]
        let source = layer("source", map: map.id, features: features)
        #expect(map.selectVectorFeature(features[1], in: source, mode: .replace))
        #expect(map.selectVectorFeature(features[0], in: source, mode: .toggle))
        #expect(map.selectVectorFeature(features[3], in: source, mode: .extendRange,
            rangeOrder: ["a", "b", "c"]))
        #expect(map.selectedFeatureIdentities == ["hidden", "a", "b", "c"])
        #expect(map.selectVectorFeature(features[0], in: source, mode: .range,
            rangeOrder: ["a", "c"]))
        #expect(map.selectedFeatureIdentities == ["a"])
        #expect(map.selectVectorFeature(features[3], in: source, mode: .range,
            rangeOrder: ["a", "c"]))
        #expect(map.selectedFeatureIdentities == ["a", "c"])
    }

    private func feature(_ identity: String, _ ordinal: Int) -> MapFeature {
        MapFeature(id: ordinal, kind: .line,
            paths: [[MapPoint(x: Double(ordinal), y: 0), MapPoint(x: Double(ordinal), y: 1)]],
            attributes: [:], stableIdentity: identity)
    }

    private func layer(_ id: String, map: UUID, features: [MapFeature],
                       revision: String = "original-revision") -> MapVectorLayer {
        MapVectorLayer(url: URL(fileURLWithPath: "/tmp/exact-multiselection/source.geojson"),
            features: features, sourceMapID: map, sourceRevision: revision, visualIdentity: id)
    }
}
