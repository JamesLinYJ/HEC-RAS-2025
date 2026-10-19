import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

@MainActor
struct MapVectorFeatureContextActionsTests {
    @Test
    func hitTestingUsesScreenPointToleranceNearestFeatureAndTopmostTie() throws {
        let mapID = UUID()
        let points = [
            MapFeature(id: 0, kind: .point, paths: [[.init(x: 49, y: 50)]], attributes: [:], stableIdentity: "near"),
            MapFeature(id: 1, kind: .point, paths: [[.init(x: 52, y: 50)]], attributes: [:], stableIdentity: "far")
        ]
        let layer = MapVectorLayer(url: URL(fileURLWithPath: "/tmp/context-hit.geojson"),
            features: points, sourceMapID: mapID, sourceRevision: "rev", visualIdentity: "layer")
        let transform = MapTransform(points: [.init(x: 0, y: 0), .init(x: 100, y: 100)],
            size: CGSize(width: 200, height: 200), scale: 1, offset: .zero)

        let closest = MapVectorFeatureHitTester.closestFeature(at: CGPoint(x: 100, y: 100),
            transform: transform, layers: [layer], tolerance: 8,
            pointDiameter: { _, _ in 0 })
        #expect(closest?.featureIdentity == "near")
        #expect(MapVectorFeatureHitTester.closestFeature(at: CGPoint(x: 114, y: 100),
            transform: transform, layers: [layer], tolerance: 8,
            pointDiameter: { _, _ in 0 }) == nil)

        let tied = MapVectorLayer(url: layer.url, features: [
                points[0], MapFeature(id: 2, kind: .point, paths: [[.init(x: 49, y: 50)]],
                    attributes: [:], stableIdentity: "top")
            ], sourceMapID: mapID, sourceRevision: "rev", visualIdentity: layer.id)
        #expect(MapVectorFeatureHitTester.closestFeature(at: CGPoint(x: 98.64, y: 100),
            transform: transform, layers: [tied], tolerance: 8,
            pointDiameter: { _, _ in 0 })?.featureIdentity == "top")
    }

    @Test
    func polygonHoleDoesNotBecomeAFeatureHit() {
        let polygon = MapFeature(id: 0, kind: .polygon, paths: [
            [.init(x: 0, y: 0), .init(x: 10, y: 0), .init(x: 10, y: 10),
             .init(x: 0, y: 10), .init(x: 0, y: 0)],
            [.init(x: 4, y: 4), .init(x: 4, y: 6), .init(x: 6, y: 6),
             .init(x: 6, y: 4), .init(x: 4, y: 4)]
        ], attributes: [:], stableIdentity: "polygon")
        let transform = MapTransform(points: [.init(x: 0, y: 0), .init(x: 10, y: 10)],
            size: CGSize(width: 200, height: 200), scale: 1, offset: .zero)
        #expect(MapVectorFeatureHitTester.distance(from: CGPoint(x: 100, y: 100),
            to: polygon, transform: transform) > 8)
        #expect(MapVectorFeatureHitTester.closestFeature(at: CGPoint(x: 100, y: 100),
            transform: transform,
            layers: [MapVectorLayer(url: URL(fileURLWithPath: "/tmp/hole.geojson"), features: [polygon])],
            tolerance: 8) == nil)
    }

    @Test
    func mapContextEnsureIncludedKeepsSameOwnerSelectionAndReplacesAcrossOwners() {
        let map = MapState(kind: .buildable, id: UUID())
        let features = [
            MapFeature(id: 0, kind: .line, paths: [[.init(x: 0, y: 0), .init(x: 1, y: 1)]], attributes: [:], stableIdentity: "a"),
            MapFeature(id: 1, kind: .line, paths: [[.init(x: 1, y: 1), .init(x: 2, y: 2)]], attributes: [:], stableIdentity: "b")
        ]
        let first = MapVectorLayer(url: URL(fileURLWithPath: "/tmp/context-one.geojson"), features: features,
            sourceMapID: map.id, sourceRevision: "r1", visualIdentity: "first")
        let second = MapVectorLayer(url: URL(fileURLWithPath: "/tmp/context-two.geojson"), features: features,
            sourceMapID: map.id, sourceRevision: "r2", visualIdentity: "second")

        #expect(map.selectVectorFeature(features[0], in: first, mode: .replace))
        #expect(map.selectVectorFeature(features[1], in: first, mode: .ensureIncluded))
        #expect(map.selectedVectorFeatureIdentities(in: first) == ["a", "b"])
        #expect(map.selectVectorFeature(features[1], in: second, mode: .ensureIncluded))
        #expect(map.selectedVectorFeatureIdentities(in: second) == ["b"])
        #expect(map.selectedVectorFeatureIdentities(in: first).isEmpty)
    }

    @Test
    func contextSelectionMatchesSourceRightClickRule() {
        let map = MapState(kind: .buildable, id: UUID())
        let features = ["a", "b", "c"].enumerated().map { index, identity in
            MapFeature(id: index, kind: .line,
                paths: [[.init(x: Double(index), y: 0), .init(x: Double(index + 1), y: 1)]],
                attributes: [:], stableIdentity: identity)
        }
        let layer = MapVectorLayer(url: URL(fileURLWithPath: "/tmp/context-rule.geojson"),
            features: features, sourceMapID: map.id, sourceRevision: "rule", visualIdentity: "rule-layer")

        #expect(map.selectVectorFeature(features[0], in: layer, mode: .replace))
        let plainClickOnNewFeature = MapVectorFeatureContextSelection.mode(
            clickedFeatureIdentity: "b", selectedFeatureIdentities: map.selectedVectorFeatureIdentities(in: layer),
            modifiers: [])
        #expect(plainClickOnNewFeature == .replace)
        #expect(map.selectVectorFeature(features[1], in: layer, mode: plainClickOnNewFeature))
        #expect(map.selectedVectorFeatureIdentities(in: layer) == ["b"])
        #expect(map.selectVectorFeature(features[2], in: layer, mode: .ensureIncluded))

        let selectedRowClick = MapVectorFeatureContextSelection.mode(
            clickedFeatureIdentity: "b", selectedFeatureIdentities: map.selectedVectorFeatureIdentities(in: layer),
            modifiers: [])
        #expect(selectedRowClick == .ensureIncluded)
        #expect(map.selectVectorFeature(features[1], in: layer, mode: selectedRowClick))
        #expect(map.selectedVectorFeatureIdentities(in: layer) == ["b", "c"])

        let controlClickOnNewFeature = MapVectorFeatureContextSelection.mode(
            clickedFeatureIdentity: "a", selectedFeatureIdentities: map.selectedVectorFeatureIdentities(in: layer),
            modifiers: [.control])
        #expect(controlClickOnNewFeature == .ensureIncluded)
        #expect(map.selectVectorFeature(features[0], in: layer, mode: controlClickOnNewFeature))
        #expect(map.selectedVectorFeatureIdentities(in: layer) == ["a", "b", "c"])
    }

    @Test
    func typedClipboardRetainsSourcePathDimensionsDuplicateAttributesAndNulls() throws {
        let feature = MapFeature(id: 0, kind: .line,
            paths: [[.init(x: 100, y: 200), .init(x: 110, y: 210)]],
            attributes: ["Label": "last"], stableIdentity: "road/7",
            pathStableIdentities: ["road/7|part:2"], sourceFeatureIndex: 7,
            sourceCoordinatePaths: [[
                .init(x: 10, y: 20, z: 3, m: 4), .init(x: 11, y: 21, z: 5, m: 6)
            ]], sourceAttributeColumns: [
                .init(ordinal: 0, name: "Label", value: .string("first")),
                .init(ordinal: 1, name: "Label", value: .string("last")),
                .init(ordinal: 2, name: "Missing", value: .null),
                .init(ordinal: 3, name: "Blob", value: .binary(Data([0x00, 0x7F])))
            ])
        let layer = MapVectorLayer(url: URL(fileURLWithPath: "/tmp/clipboard.shp"), features: [feature],
            sourceMapID: UUID(), sourceRevision: String(repeating: "A", count: 64),
            visualIdentity: "shp-layer", sourceProjectionWKT: "source-crs", targetProjectionWKT: "map-crs")
        let context = MapVectorFeatureContextSnapshot(projectSessionID: UUID(), mapID: UUID(),
            contextIdentity: "source-row", layer: layer, clickedFeatureIdentity: feature.stableIdentity,
            selectedFeatureIdentities: [feature.stableIdentity], selectedFeatures: [feature],
            editorCanDeleteSelectedFeatures: false, editorCanUndo: false, editorCanRedo: false,
            editorCanSave: false, canPasteCopiedLines: false)

        let clipboard = MapVectorFeatureClipboard.make(from: context)
        let bytes = try JSONEncoder().encode(clipboard)
        let decoded = try JSONDecoder().decode(MapVectorFeatureClipboard.self, from: bytes)
        #expect(decoded.sourcePath == SourceFilePaths.canonical(layer.url))
        #expect(decoded.sourceProjectionWKT == "source-crs")
        #expect(decoded.features.only?.projectedPaths.first?.first?.x == 100)
        #expect(decoded.features.only?.sourcePaths.first?.first?.z == 3)
        #expect(decoded.features.only?.attributes.map(\.ordinal) == [0, 1, 2, 3])
        #expect(decoded.features.only?.attributes.map(\.name) == ["Label", "Label", "Missing", "Blob"])
        #expect(decoded.features.only?.attributes[2].value == .null)
        #expect(decoded.features.only?.attributes[3].value == .binary("AH8="))

        let compatibility = try #require(MapVectorFeatureClipboard.compatibilityPolylineClipboard(from: context))
        try compatibility.validate()
        #expect(compatibility.coordinateProjectionWKT == "source-crs")
        #expect(compatibility.lines.only?.hasZ == true)
        #expect(compatibility.lines.only?.hasM == true)
        #expect(compatibility.lines.only?.vertices.first?.z == "3.0")
        #expect(compatibility.lines.only?.vertices.last?.m == "6.0")
    }
}

private extension Collection {
    var only: Element? { count == 1 ? first : nil }
}
