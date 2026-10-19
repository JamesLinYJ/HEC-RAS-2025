import Foundation
import RASWorkspaceCore
import SwiftUI
import Testing
@testable import HECRAS2025

struct MapVectorStyleRenderingTests {
    @Test
    func genericMapLayerDefinitionIDsAndSourceDefaultsAreUsed() throws {
        #expect(MapVectorStyleDefinitionIDs.point == "Point_Map_Layer_Symbology")
        #expect(MapVectorStyleDefinitionIDs.polylineLine == "Polyline_Line_Symbology")
        #expect(MapVectorStyleDefinitionIDs.polylineVertex == "Polyline_Vertex_Symbology")
        #expect(MapVectorStyleDefinitionIDs.polygonShape == "Polygon_Map_Layer_Shape_Symbology")
        #expect(MapVectorStyleDefinitionIDs.polygonVertex == "Polygon_Map_Layer_Vertex_Symbology")
        #expect(MapVectorStyleDefinitionIDs.primaryDefinition(for: .point) == MapVectorStyleDefinitionIDs.point)
        #expect(MapVectorStyleDefinitionIDs.primaryDefinition(for: .line) == MapVectorStyleDefinitionIDs.polylineLine)
        #expect(MapVectorStyleDefinitionIDs.primaryDefinition(for: .polygon) == MapVectorStyleDefinitionIDs.polygonShape)
        #expect(MapVectorStyleDefinitionIDs.vertexDefinition(for: .point) == nil)
        #expect(MapVectorStyleDefinitionIDs.vertexDefinition(for: .line) == MapVectorStyleDefinitionIDs.polylineVertex)
        #expect(MapVectorStyleDefinitionIDs.vertexDefinition(for: .polygon) == MapVectorStyleDefinitionIDs.polygonVertex)

        let defaults = MapVectorStylePresentation.sourceMapLayerDefaults
        #expect(Set(defaults.base.keys) == Set(MapVectorStyleDefinitionIDs.mapLayerDefinitions))
        for id in MapVectorStyleDefinitionIDs.mapLayerDefinitions {
            #expect(defaults.base[id] == SourceVectorStyleCatalog.definition(for: id)?.defaultStyle)
        }
    }

    @Test
    func conditionalStylesResolveOnlyForTheBoundSourceFeatureOrdinal() throws {
        let definitionID = MapVectorStyleDefinitionIDs.point
        let base = try #require(SourceVectorStyleCatalog.definition(for: definitionID)?.defaultStyle)
        var conditional = base
        conditional.penColor = "#FF10A0F0"
        conditional.pointSize = 11
        let presentation = MapVectorStylePresentation(
            base: [definitionID: base],
            perSourceFeatureOverrides: [7: [definitionID: conditional]])
        let verifiedPresentation = MapVectorStylePresentation(
            base: [definitionID: base],
            perSourceFeatureOverrides: [7: [definitionID: conditional]],
            sourceFeatureOrdinalBindingVerified: true)
        let feature = MapFeature(id: 100, kind: .point, paths: [[MapPoint(x: 1, y: 2)]],
            attributes: [:], sourceFeatureIndex: 7)

        #expect(presentation.values(for: definitionID, sourceFeatureIndex: feature.sourceFeatureIndex) == base)
        #expect(verifiedPresentation.values(for: definitionID, sourceFeatureIndex: feature.sourceFeatureIndex) == conditional)
        #expect(verifiedPresentation.values(for: definitionID, sourceFeatureIndex: 8) == base)
        #expect(verifiedPresentation.values(for: definitionID, sourceFeatureIndex: nil) == base)
        #expect(presentation.values(for: "unknown-source-definition", sourceFeatureIndex: 7) == nil)
        #expect(MapVectorStyleResolver.values(layerID: "/layer/point.geojson", feature: feature,
            definitionID: definitionID, presentations: ["/layer/point.geojson": verifiedPresentation]) == conditional)
        let transform = MapTransform(points: feature.paths.flatMap { $0 }, size: CGSize(width: 100, height: 100), scale: 1, offset: .zero)
        let pointPath = transform.path(feature,
            pointDiameter: CGFloat(MapVectorStyleResolver.values(layerID: "/layer/point.geojson", feature: feature,
                definitionID: definitionID, presentations: ["/layer/point.geojson": verifiedPresentation]).pointSize))
        #expect(pointPath.boundingRect.width == 11 && pointPath.boundingRect.height == 11)
    }

    @Test
    func sourceARGBDecoderUsesAlphaRedGreenBlueOrderAndRejectsMalformedColors() throws {
        let value = try #require(SourceARGBColor.components("#80402010"))
        #expect(value.alpha == 0x80)
        #expect(value.red == 0x40)
        #expect(value.green == 0x20)
        #expect(value.blue == 0x10)
        #expect(SourceARGBColor.components("#112233") == nil)
        #expect(SourceARGBColor.components("11223344") == nil)
        #expect(SourceARGBColor.components("#GG223344") == nil)
    }

    @Test @MainActor
    func styleOnlyUpdatePreservesMapInteractionAndPolylineDraftsWithoutCrossMapLeakage() async throws {
        let mapID = UUID(), projectSessionID = UUID()
        let state = MapState(id: mapID)
        let otherState = MapState(id: UUID())
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("map-style-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("lines.geojson")
        try Data(#"{"type":"FeatureCollection","features":[{"type":"Feature","id":"line","properties":{},"geometry":{"type":"LineString","coordinates":[[0,0],[1,1]]}}]}"#.utf8).write(to: sourceURL)
        let scope = PolylineMapEditingScope(projectSessionID: projectSessionID, mapID: mapID,
            layerID: sourceURL.path, canonicalPath: sourceURL.path)
        #expect(await state.polylineEditor.ensureLoaded(scope: scope))
        let line = try #require(state.polylineEditor.lines.first)
        #expect(await state.polylineEditor.moveVertex(lineID: line.id, vertexIndex: 1, to: MapPoint(x: 4, y: 5)))
        let draftBefore = try #require(state.draftVector)

        let selectedLayer = MapVectorLayer(url: sourceURL, features: draftBefore.features, sourceMapID: mapID)
        let preview = MapFeature(id: 5, kind: .line, paths: [[MapPoint(x: 2, y: 2), MapPoint(x: 3, y: 3)]], attributes: [:])
        state.installProfile(.init(vectors: [selectedLayer], rasters: [], preview: [preview],
            selectedLayerID: selectedLayer.id, selectedFeatureID: 0), isEditing: true)
        state.selectedLayerID = selectedLayer.id
        state.selectedFeatureID = 0
        state.selectedFeatureIdentity = draftBefore.features.first?.stableIdentity
        state.selectedLineIdentity = draftBefore.features.first?.pathStableIdentities.first
        state.viewport = .init(lowerLeft: .init(x: -1, y: -1), upperRight: .init(x: 8, y: 8), animated: false, padding: 0)

        var style = try #require(SourceVectorStyleCatalog.definition(for: MapVectorStyleDefinitionIDs.polylineLine)?.defaultStyle)
        style.penColor = "#FF22AA66"
        let presentation = MapVectorStylePresentation(base: [MapVectorStyleDefinitionIDs.polylineLine: style])
        state.installProfile(.init(vectors: nil, rasters: nil, preview: [], selectedLayerID: nil,
            selectedFeatureID: nil, vectorStyles: [selectedLayer.id: presentation],
            preserveInteractionState: true), isEditing: true)

        #expect(state.vectorStyles[selectedLayer.id] == presentation)
        #expect(otherState.vectorStyles.isEmpty)
        #expect(state.profileVectors?.map(\.id) == [selectedLayer.id])
        #expect(state.preview.map(\.stableIdentity) == [preview.stableIdentity])
        #expect(state.selectedLayerID == selectedLayer.id)
        #expect(state.selectedFeatureID == 0)
        #expect(state.selectedFeatureIdentity == draftBefore.features.first?.stableIdentity)
        #expect(state.selectedLineIdentity == draftBefore.features.first?.pathStableIdentities.first)
        #expect(state.viewport?.lowerLeft == MapPoint(x: -1, y: -1))
        #expect(state.draftVector?.features.first?.paths.first?.last == MapPoint(x: 4, y: 5))
    }

    @Test
    func polygonRenderPathKeepsInteriorRingsAsEvenOddHoles() throws {
        let outer = [MapPoint(x: 0, y: 0), MapPoint(x: 10, y: 0), MapPoint(x: 10, y: 10),
                     MapPoint(x: 0, y: 10), MapPoint(x: 0, y: 0)]
        let hole = [MapPoint(x: 3, y: 3), MapPoint(x: 7, y: 3), MapPoint(x: 7, y: 7),
                    MapPoint(x: 3, y: 7), MapPoint(x: 3, y: 3)]
        let feature = MapFeature(id: 0, kind: .polygon, paths: [outer, hole], attributes: [:])
        let transform = MapTransform(points: outer + hole, size: CGSize(width: 300, height: 300), scale: 1, offset: .zero)
        let path = transform.path(feature)

        #expect(path.contains(transform.screen(MapPoint(x: 1, y: 1)), eoFill: true))
        #expect(!path.contains(transform.screen(MapPoint(x: 5, y: 5)), eoFill: true))
    }
}
