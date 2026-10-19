import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

struct WorkspaceVectorSymbologyProviderTests {
    @Test @MainActor func globalStylesPersistWithoutAnOpenProjectAndResetToSourceDefaults() async throws {
        let suite = "WorkspaceVectorSymbologyProviderTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let preferences = GlobalVectorStylePreferences(defaults: defaults)
        let store = WorkspaceStore(globalVectorStylePreferences: preferences)
        let provider = WorkspaceVectorSymbologyProvider(store: store, preferences: preferences, client: nil)
        let context = VectorSymbologyContext(
            projectSessionID: store.globalSymbologySessionID,
            mapID: MapState.projectMapID,
            assetID: nil,
            scope: .global
        )

        let snapshot = try #require(await provider.snapshot(context))
        #expect(snapshot.options.count == SourceVectorStyleCatalog.definitions.count)
        #expect(snapshot.canEdit)

        let definitionID = MapVectorStyleDefinitionIDs.point
        let index = try #require(snapshot.options.firstIndex(where: { $0.id == definitionID }))
        var options = snapshot.options
        options[index].style.penWidth = 6.25
        _ = try await provider.apply(options: options, additionalOptions: [], context: context)

        let reopenedPreferences = GlobalVectorStylePreferences(defaults: defaults)
        let reopenedStore = WorkspaceStore(globalVectorStylePreferences: reopenedPreferences)
        let reopenedProvider = WorkspaceVectorSymbologyProvider(
            store: reopenedStore,
            preferences: reopenedPreferences,
            client: nil
        )
        let reopenedContext = VectorSymbologyContext(
            projectSessionID: reopenedStore.globalSymbologySessionID,
            mapID: MapState.projectMapID,
            assetID: nil,
            scope: .global
        )
        let reopened = try #require(await reopenedProvider.snapshot(reopenedContext))
        #expect(reopened.options.first(where: { $0.id == definitionID })?.style.penWidth == 6.25)

        let reset = try await reopenedProvider.resetAllDefaults(context: reopenedContext)
        #expect(reset.options.first(where: { $0.id == definitionID })?.style ==
            SourceVectorStyleCatalog.definition(for: definitionID)?.defaultStyle)
        #expect(reopenedPreferences.loadOverrides()[definitionID] == nil)
    }

    @Test func localDefaultChangesSyncWholeOptionsAndKeepLocallyModifiedOptions() {
        let oldDefaults = VectorStyleValues(penColor: "#FF101010", penWidth: 1,
            fillColor: "#FF202020", pointSize: 3)
        let newDefaults = VectorStyleValues(penColor: "#FF303030", penWidth: 4,
            fillColor: "#FF404040", pointSize: 7)
        var unchangedLine = oldDefaults
        unchangedLine.fillColor = "#FF999999" // Not a persisted attribute of a source Line style.
        var changedPoint = oldDefaults
        changedPoint.penWidth = 2
        let rule = VectorStyleRule(column: "kind", comparison: "equals", threshold: "river", resultValue: "#FFABCDEF")
        let previous = VectorVisualSettingsSnapshot(options: [
            MapVectorStyleDefinitionIDs.polylineLine: VectorVisualSettingsOptions(values: unchangedLine),
            MapVectorStyleDefinitionIDs.point: VectorVisualSettingsOptions(values: changedPoint,
                conditionGroups: [.init(field: .penColor, rules: [rule])])
        ], revision: "vis-sha")
        var rawInheritedStyle = newDefaults
        rawInheritedStyle.penWidth = changedPoint.penWidth
        let raw = VectorVisualSettingsSnapshot(options: [
            MapVectorStyleDefinitionIDs.polylineLine: VectorVisualSettingsOptions(values: newDefaults),
            MapVectorStyleDefinitionIDs.point: VectorVisualSettingsOptions(values: rawInheritedStyle,
                conditionGroups: [.init(field: .penColor, rules: [rule])])
        ], revision: "vis-sha")

        let resolved = VectorVisualSettingsDefaultSync.resolve(
            raw: raw,
            previous: previous,
            previousDefaults: [MapVectorStyleDefinitionIDs.polylineLine: oldDefaults,
                MapVectorStyleDefinitionIDs.point: oldDefaults],
            newDefaults: [MapVectorStyleDefinitionIDs.polylineLine: newDefaults,
                MapVectorStyleDefinitionIDs.point: newDefaults]
        )

        #expect(resolved.options[MapVectorStyleDefinitionIDs.polylineLine]?.values == newDefaults)
        #expect(resolved.options[MapVectorStyleDefinitionIDs.point]?.values == changedPoint)
        #expect(resolved.options[MapVectorStyleDefinitionIDs.point]?.conditionGroups ==
            previous.options[MapVectorStyleDefinitionIDs.point]?.conditionGroups)
    }

    @Test func sourceRowBindingAllowsExpandedComponentsOnlyWithProvenSourceOrdinals() {
        let url = URL(fileURLWithPath: "/tmp/vector-ordinal-binding.geojson")
        let first = MapFeature(
            id: 0, kind: .point, paths: [[MapPoint(x: 0, y: 0)]], attributes: [:],
            stableIdentity: "feature-a", sourceFeatureIndex: 4
        )
        let second = MapFeature(
            id: 1, kind: .point, paths: [[MapPoint(x: 1, y: 1)]], attributes: [:],
            stableIdentity: "feature-b", sourceFeatureIndex: 1
        )
        let oneToOneLayer = MapVectorLayer(url: url, features: [first, second])
        #expect(VectorSymbologyOrdinalBinding.verifiedSourceIndices(
            renderedFeatures: oneToOneLayer.features,
            kind: .point,
            sourceIndices: [1, 4],
            tableRowCount: 2,
            renderFeatureCount: 2,
            ordinalBindingProven: true
        ) == [1, 4])

        let expanded = MapVectorLayer(url: url, features: [first, second, first])
        #expect(VectorSymbologyOrdinalBinding.verifiedSourceIndices(
            renderedFeatures: expanded.features,
            kind: .point,
            sourceIndices: [1, 4],
            tableRowCount: 2,
            renderFeatureCount: 2,
            ordinalBindingProven: true
        ) == [1, 4])

        let expandedPolygons = MapVectorLayer(url: url, features: [
            MapFeature(id: 0, kind: .polygon, paths: [[MapPoint(x: 0, y: 0)]], attributes: [:],
                sourceFeatureIndex: 3),
            MapFeature(id: 1, kind: .polygon, paths: [[MapPoint(x: 1, y: 1)]], attributes: [:],
                sourceFeatureIndex: 3)
        ])
        #expect(VectorSymbologyOrdinalBinding.verifiedSourceIndices(
            renderedFeatures: expandedPolygons.features,
            kind: .polygon,
            sourceIndices: [3],
            tableRowCount: 1,
            renderFeatureCount: 1,
            ordinalBindingProven: true
        ) == [3])

        let expandedLineComponents = MapVectorLayer(url: url, features: [
            MapFeature(id: 0, kind: .line, paths: [[MapPoint(x: 0, y: 0)]], attributes: [:],
                sourceFeatureIndex: 0),
            MapFeature(id: 1, kind: .line, paths: [[MapPoint(x: 1, y: 1)]], attributes: [:],
                sourceFeatureIndex: 0),
            MapFeature(id: 2, kind: .line, paths: [[MapPoint(x: 2, y: 2)]], attributes: [:],
                sourceFeatureIndex: 3)
        ])
        #expect(VectorSymbologyOrdinalBinding.verifiedSourceIndices(
            renderedFeatures: expandedLineComponents.features,
            kind: .line,
            sourceIndices: [0, 3],
            tableRowCount: 2,
            renderFeatureCount: 2,
            ordinalBindingProven: true
        ) == [0, 3])

        let outOfSet = MapVectorLayer(url: url, features: [
            MapFeature(id: 0, kind: .point, paths: [[MapPoint(x: 0, y: 0)]], attributes: [:],
                sourceFeatureIndex: 1),
            MapFeature(id: 1, kind: .point, paths: [[MapPoint(x: 1, y: 1)]], attributes: [:],
                sourceFeatureIndex: 2)
        ])
        #expect(VectorSymbologyOrdinalBinding.verifiedSourceIndices(
            renderedFeatures: outOfSet.features,
            kind: .point,
            sourceIndices: [1, 4],
            tableRowCount: 2,
            renderFeatureCount: 2,
            ordinalBindingProven: true
        ) == nil)

        #expect(VectorSymbologyOrdinalBinding.verifiedSourceIndices(
            renderedFeatures: expanded.features,
            kind: .point,
            sourceIndices: [1, 1],
            tableRowCount: 2,
            renderFeatureCount: 2,
            ordinalBindingProven: true
        ) == nil)

        let missingOrdinal = MapVectorLayer(url: url, features: [
            MapFeature(id: 0, kind: .point, paths: [[MapPoint(x: 0, y: 0)]], attributes: [:])
        ])
        #expect(VectorSymbologyOrdinalBinding.verifiedSourceIndices(
            renderedFeatures: missingOrdinal.features,
            kind: .point,
            sourceIndices: [0],
            tableRowCount: 1,
            renderFeatureCount: 1,
            ordinalBindingProven: true
        ) == nil)
    }
}
