import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

struct GlobalVectorStylePreferencesTests {
    @Test @MainActor func swiftIntegersCannotPersistValuesOutsideTheRetainedInt32Contract() throws {
        let (suite, defaults) = makePreferencesSuite()
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = GlobalVectorStylePreferences(defaults: defaults)
        var point = try #require(preferences.style(for: "Point_Map_Layer_Symbology"))
        point.pointSize = Int(Int32.max)
        try preferences.set(point, for: "Point_Map_Layer_Symbology")
        let accepted = defaults.data(forKey: GlobalVectorStylePreferences.storageKey)
        point.pointSize += 1
        #expect(throws: GlobalVectorStylePreferencesError.invalidStyle) {
            try preferences.set(point, for: "Point_Map_Layer_Symbology")
        }
        var label = try #require(preferences.style(for: "Label_Text_Symbology"))
        label.textEmphasis = Int(Int32.min) - 1
        #expect(throws: GlobalVectorStylePreferencesError.invalidStyle) {
            try preferences.set(label, for: "Label_Text_Symbology")
        }
        #expect(defaults.data(forKey: GlobalVectorStylePreferences.storageKey) == accepted)
    }

    @Test func catalogPreservesUniqueIDsAndDuplicatePolylineVariants() {
        let ids = SourceVectorStyleCatalog.definitions.map(\.id)
        #expect(ids.count == 25)
        #expect(Set(ids).count == 25)
        #expect(SourceVectorStyleCatalog.byID.count == 25)

        let lineVariants = SourceVectorStyleCatalog.variants(for: "Polyline_Line_Symbology")
        #expect(lineVariants.map(\.sourceContext) == [
            "Visual.Mapping.Observables.PolylineLayerVisualContext",
            "Visual.Mapping.Observables.PolylineMapLayerVisualContext"
        ])
        #expect(SourceVectorStyleCatalog.variants(for: "Polyline_Vertex_Symbology").count == 2)
        #expect(SourceVectorStyleCatalog.definition(for: "missing") == nil)
    }

    @Test func catalogDefaultsMatchRetainedARGBAndMeasurements() throws {
        let basic = VectorStyleValues()
        let boundary = try #require(SourceVectorStyleCatalog.definition(for: "BC_Line_Symbology"))
        #expect(boundary.defaultStyle == VectorStyleValues(
            penColor: "#FF05D5FF", penWidth: 3, fillColor: "#FF05D5FF"
        ))

        let mesh = try #require(SourceVectorStyleCatalog.definition(for: "Mesh_Line_Symbology"))
        #expect(mesh.defaultStyle.penColor == "#80000000")
        #expect(mesh.defaultStyle.fillColor == "#80000000")

        let topologyNode = try #require(SourceVectorStyleCatalog.definition(for: "Node_Symbology"))
        #expect(topologyNode.defaultStyle == VectorStyleValues(
            penColor: "#FF5B379E", penWidth: 2, fillColor: "#FFC5A6FF", pointSize: 5
        ))
        #expect(!topologyNode.conditionsSupported)
        #expect(topologyNode.hasSpecializedConditionalRendering)

        let label = try #require(SourceVectorStyleCatalog.definition(for: "Label_Text_Symbology"))
        #expect(label.defaultStyle == VectorStyleValues(
            penColor: "#FFFFFFFF", penWidth: 12, fillColor: "#FFFFFFFF", pointSize: 3,
            haloColor: "#C4000000", haloThickness: 2, textEmphasis: 1
        ))
        #expect(label.textStyleSupported)
        #expect(label.conditionCapability == .globalOnly)
        #expect(SourceVectorStyleCatalog.fallbackStyle == VectorStyleValues())

        let topologyArc = VectorStyleValues(
            penColor: "#FF200040", penWidth: 2, fillColor: "#20388EFF"
        )
        let topologyNodeStyle = topologyNode.defaultStyle
        let internalPoint = VectorStyleValues(
            penColor: "#FF545353", penWidth: 1, fillColor: "#FFB3B3B3"
        )
        let labelStyle = label.defaultStyle
        let expected: [String: VectorStyleValues] = [
            "BC_Line_Symbology": VectorStyleValues(penColor: "#FF05D5FF", penWidth: 3, fillColor: "#FF05D5FF"),
            "BC_Line_Vertex_Symbology": basic,
            "Culvert_Barrel_Symbology": VectorStyleValues(penColor: "#FF0000FF", penWidth: 4, fillColor: "#FF0000FF"),
            "Culvert_Barrel_Vertex_Symbology": basic,
            "Mesh_Line_Symbology": VectorStyleValues(penColor: "#80000000", penWidth: 1, fillColor: "#80000000"),
            "Arc_Line_Symbology": topologyArc,
            "Node_Symbology": topologyNodeStyle,
            "Deletable_Node_Symbology": VectorStyleValues(penColor: "#FF5B379E", penWidth: 2, fillColor: "#FF4287F5", pointSize: 5),
            "Internal_Point_Symbology": internalPoint,
            "Graph_Arc": topologyArc,
            "Graph_Node": topologyNodeStyle,
            "Graph_InternalPoint": internalPoint,
            "Point_Symbology": basic,
            "Point_Map_Layer_Symbology": basic,
            "Polyline_Line_Symbology": basic,
            "Polyline_Vertex_Symbology": basic,
            "Polygon_Shape_Symbology": basic,
            "Polygon_Vertex_Symbology": basic,
            "Polygon_Map_Layer_Shape_Symbology": basic,
            "Polygon_Map_Layer_Vertex_Symbology": basic,
            "Gdb_Point_Symbology": basic,
            "Gdb_Line_Symbology": basic,
            "Gdb_Line_Vertex_Symbology": basic,
            "Gdb_Polygon_Symbology": basic,
            "Label_Text_Symbology": labelStyle
        ]
        #expect(Dictionary(uniqueKeysWithValues: SourceVectorStyleCatalog.definitions.map { ($0.id, $0.defaultStyle) }) == expected)
    }

    @Test @MainActor func preferencesRoundTripAcrossInstancesAndResetOnlyGlobalOverrides() throws {
        let (suite, defaults) = makePreferencesSuite()
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = GlobalVectorStylePreferences(defaults: defaults)
        var style = try #require(first.style(for: "BC_Line_Symbology"))
        style.penColor = "#ff112233"
        style.penWidth = 4.5
        try first.set(style, for: "BC_Line_Symbology")

        let reopened = GlobalVectorStylePreferences(defaults: UserDefaults(suiteName: suite)!)
        #expect(reopened.style(for: "BC_Line_Symbology")?.penColor == "#FF112233")
        #expect(reopened.style(for: "BC_Line_Symbology")?.penWidth == 4.5)
        #expect(reopened.loadOverrides().count == 1)

        try reopened.set(try #require(SourceVectorStyleCatalog.definition(for: "BC_Line_Symbology")).defaultStyle,
                         for: "BC_Line_Symbology")
        #expect(reopened.loadOverrides().isEmpty)

        try first.set(style, for: "BC_Line_Symbology")
        first.resetAll()
        #expect(first.loadOverrides().isEmpty)
        #expect(first.style(for: "BC_Line_Symbology") == SourceVectorStyleCatalog.definition(for: "BC_Line_Symbology")?.defaultStyle)
    }

    @Test @MainActor func malformedAndUnknownPreferenceEntriesAreIgnoredSafely() throws {
        let (suite, defaults) = makePreferencesSuite()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = GlobalVectorStylePreferences(defaults: defaults)
        defaults.set(Data("not-json".utf8), forKey: GlobalVectorStylePreferences.storageKey)
        #expect(store.loadOverrides().isEmpty)
        #expect(defaults.object(forKey: GlobalVectorStylePreferences.storageKey) == nil)

        let validStyle = VectorStyleValues(penColor: "#FF102030", penWidth: 2, fillColor: "#80405060")
        let encodedStyle = try JSONEncoder().encode(validStyle)
        let validObject = try #require(try JSONSerialization.jsonObject(with: encodedStyle) as? [String: Any])
        let values: [String: Any] = [
            "BC_Line_Symbology": validObject,
            "Removed_Future_Definition": validObject,
            "Culvert_Barrel_Symbology": ["penColor": "not-an-ARGB-color"]
        ]
        defaults.set(try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]),
                     forKey: GlobalVectorStylePreferences.storageKey)

        #expect(store.loadOverrides() == ["BC_Line_Symbology": validStyle])
        #expect(store.style(for: "Removed_Future_Definition") == nil)
    }

    @Test @MainActor func invalidStylesAndUnknownIDsCannotBePersistedAndLocalStyleWinsResolution() throws {
        let (suite, defaults) = makePreferencesSuite()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = GlobalVectorStylePreferences(defaults: defaults)
        let defaultStyle = try #require(store.style(for: "Polyline_Line_Symbology"))
        var localStyle = defaultStyle
        localStyle.penWidth = 6
        var globalStyle = defaultStyle
        globalStyle.penWidth = 3

        #expect(SourceVectorStyleCatalog.resolvedStyle(globalStyle: globalStyle, localStyle: localStyle) == localStyle)
        #expect(SourceVectorStyleCatalog.resolvedStyle(globalStyle: globalStyle, localStyle: nil) == globalStyle)

        var invalid = globalStyle
        invalid.penColor = "#1234"
        do {
            try store.set(invalid, for: "Polyline_Line_Symbology")
            Issue.record("Malformed color unexpectedly persisted.")
        } catch {
            #expect(error as? GlobalVectorStylePreferencesError == .invalidStyle)
        }
        do {
            try store.set(globalStyle, for: "not-a-source-id")
            Issue.record("Unknown source definition unexpectedly persisted.")
        } catch {
            #expect(error as? GlobalVectorStylePreferencesError == .unknownDefinition("not-a-source-id"))
        }
        #expect(store.loadOverrides().isEmpty)
    }

    @Test @MainActor func overrideBatchValidatesBeforeOneAtomicPreferenceReplacement() throws {
        let (suite, defaults) = makePreferencesSuite()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = GlobalVectorStylePreferences(defaults: defaults)

        var original = try #require(store.style(for: "BC_Line_Symbology"))
        original.penWidth = 8
        try store.set(original, for: "BC_Line_Symbology")
        let before = try #require(defaults.data(forKey: GlobalVectorStylePreferences.storageKey))

        var validCandidate = try #require(store.style(for: "Culvert_Barrel_Symbology"))
        validCandidate.penWidth = 9
        var invalidCandidate = try #require(store.style(for: "Polyline_Line_Symbology"))
        invalidCandidate.haloThickness = .infinity
        do {
            try store.setOverrides([
                "Culvert_Barrel_Symbology": validCandidate,
                "Polyline_Line_Symbology": invalidCandidate
            ])
            Issue.record("An invalid batch unexpectedly committed.")
        } catch {
            #expect(error as? GlobalVectorStylePreferencesError == .invalidStyle)
        }
        #expect(defaults.data(forKey: GlobalVectorStylePreferences.storageKey) == before)
        #expect(store.style(for: "BC_Line_Symbology")?.penWidth == 8)
        #expect(store.style(for: "Culvert_Barrel_Symbology")?.penWidth == 4)

        try store.setOverrides(["Culvert_Barrel_Symbology": validCandidate])
        #expect(store.loadOverrides()["BC_Line_Symbology"] == nil)
        #expect(store.style(for: "Culvert_Barrel_Symbology")?.penWidth == 9)
    }

    @MainActor
    private func makePreferencesSuite() -> (String, UserDefaults) {
        let suite = "HECRAS2025.VectorStyleTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (suite, defaults)
    }
}
