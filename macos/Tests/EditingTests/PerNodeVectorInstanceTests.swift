import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

struct PerNodeVectorInstanceTests {
    @Test @MainActor
    func duplicateSourceNodesKeepIndependentStylesAndVisibilityAcrossMixedFamilies() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("vector-node-instances-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let sourceURL = folder.appendingPathComponent("mixed.geojson")
        try Data(#"{"type":"FeatureCollection","features":[{"type":"Feature","id":"pt","properties":{"Class":"point"},"geometry":{"type":"Point","coordinates":[0,0]}},{"type":"Feature","id":"ln","properties":{"Class":"line"},"geometry":{"type":"LineString","coordinates":[[1,1],[2,2]]}},{"type":"Feature","id":"pg","properties":{"Class":"polygon"},"geometry":{"type":"Polygon","coordinates":[[[3,3],[5,3],[5,5],[3,5],[3,3]]]}}]}"#.utf8)
            .write(to: sourceURL)
        let source = try MapVectorLayer(contentsOf: sourceURL)
        let state = MapState(id: UUID())
        let sourcePath = SourceFilePaths.canonical(sourceURL)
        state.sourceVectorBindings = [
            .init(id: "map-node/line-a", sourcePath: sourcePath, name: "Line A", kind: .line, isVisible: true),
            .init(id: "map-node/line-b", sourcePath: sourcePath, name: "Line B", kind: .line, isVisible: true),
            .init(id: "map-node/point-hidden", sourcePath: sourcePath, name: "Points", kind: .point, isVisible: false),
            .init(id: "map-node/polygon", sourcePath: sourcePath, name: "Polygons", kind: .polygon, isVisible: true)
        ]

        let instances = state.vectors([source])
        #expect(instances.map(\.id) == ["map-node/line-a", "map-node/line-b", "map-node/point-hidden", "map-node/polygon"])
        #expect(Set(instances.map(\.id)).count == instances.count)
        #expect(instances.allSatisfy { SourceFilePaths.canonical($0.url) == sourcePath })
        #expect(instances.map(\.name) == ["Line A", "Line B", "Points", "Polygons"])
        #expect(instances.map(\.isSourceVisible) == [true, true, false, true])

        let lineA = try #require(instances.first { $0.id == "map-node/line-a" })
        let lineB = try #require(instances.first { $0.id == "map-node/line-b" })
        let point = try #require(instances.first { $0.id == "map-node/point-hidden" })
        let polygon = try #require(instances.first { $0.id == "map-node/polygon" })
        #expect(lineA.features.map(\.kind) == [.line])
        #expect(lineB.features.map(\.kind) == [.line])
        #expect(point.features.map(\.kind) == [.point])
        #expect(polygon.features.map(\.kind) == [.polygon])
        #expect(lineA.features.first?.sourceFeatureIndex == 1)
        #expect(lineB.features.first?.sourceFeatureIndex == 1)
        #expect(lineA.features.first?.stableIdentity == lineB.features.first?.stableIdentity)
        #expect(lineA.features.first?.attributes["Class"] == "line")

        var styleA = try #require(SourceVectorStyleCatalog.definition(for: MapVectorStyleDefinitionIDs.polylineLine)?.defaultStyle)
        var styleB = styleA
        styleA.penWidth = 2
        styleB.penWidth = 9
        state.vectorStyles[lineA.id] = MapVectorStylePresentation(base: [MapVectorStyleDefinitionIDs.polylineLine: styleA])
        state.vectorStyles[lineB.id] = MapVectorStylePresentation(base: [MapVectorStyleDefinitionIDs.polylineLine: styleB])
        #expect(MapVectorStyleResolver.values(layerID: lineA.id, feature: lineA.features[0],
            definitionID: MapVectorStyleDefinitionIDs.polylineLine, presentations: state.vectorStyles).penWidth == 2)
        #expect(MapVectorStyleResolver.values(layerID: lineB.id, feature: lineB.features[0],
            definitionID: MapVectorStyleDefinitionIDs.polylineLine, presentations: state.vectorStyles).penWidth == 9)

        state.establishReference(vectors: [source], rasters: [])
        #expect(state.referencePoints != nil)
        state.hiddenLayers.insert(lineB.id)
        #expect(state.referencePoints == nil)
        let visible = state.visibleVectors([source])
        #expect(visible.map(\.id) == [lineA.id, polygon.id])
        #expect(state.vectors([source]).contains { $0.id == lineB.id })
        #expect(state.vectorStyles[lineB.id]?.base[MapVectorStyleDefinitionIDs.polylineLine]?.penWidth == 9)
        #expect(!visible.contains { $0.id == point.id })

        let profileOverlay = MapVectorLayer(url: folder.appendingPathComponent("profile.geojson"), features: [
            MapFeature(id: 9, kind: .point, paths: [[MapPoint(x: 7, y: 8)]], attributes: [:])
        ], sourceMapID: state.id)
        state.installProfile(.init(vectors: [profileOverlay], rasters: [], preview: [],
            selectedLayerID: nil, selectedFeatureID: nil))
        #expect(state.vectors([source]).contains { $0.id == profileOverlay.id })
        let otherMap = MapState(id: UUID())
        otherMap.sourceVectorBindings = [
            .init(id: "other-map/line", sourcePath: sourcePath, name: "Other map line", kind: .line, isVisible: true)
        ]
        let otherInstances = otherMap.vectors([source])
        #expect(otherInstances.map(\.id) == ["other-map/line"])
        #expect(otherInstances[0].sourceMapID == otherMap.id)
        #expect(otherMap.vectorStyles.isEmpty)
        #expect(!otherInstances.contains { $0.id == profileOverlay.id })
    }

    @Test @MainActor
    func stagedGeometryDraftFlowsIntoEveryBoundNodeWithoutChangingSourceOrdinals() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("vector-node-draft-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let sourceURL = folder.appendingPathComponent("lines.geojson")
        try Data(#"{"type":"FeatureCollection","features":[{"type":"Feature","id":"line-1","properties":{"Class":"main"},"geometry":{"type":"LineString","coordinates":[[0,0],[1,1],[2,2]]}}]}"#.utf8)
            .write(to: sourceURL)
        let source = try MapVectorLayer(contentsOf: sourceURL)
        let state = MapState(id: UUID())
        let sourcePath = SourceFilePaths.canonical(sourceURL)
        state.sourceVectorBindings = [
            .init(id: "map-node/first", sourcePath: sourcePath, name: "First", kind: .line, isVisible: true),
            .init(id: "map-node/second", sourcePath: sourcePath, name: "Second", kind: .line, isVisible: true)
        ]
        let rawInstances = state.vectors([source])
        let rawLineA = try #require(rawInstances.first { $0.id == "map-node/first" })
        let rawLineB = try #require(rawInstances.first { $0.id == "map-node/second" })
        let scope = PolylineMapEditingScope(projectSessionID: UUID(), mapID: state.id,
            layerID: "map-node/first", canonicalPath: sourcePath)
        #expect(await state.polylineEditor.ensureLoaded(scope: scope))
        let line = try #require(state.polylineEditor.lines.first)
        let movedPoint = MapPoint(x: 4, y: 6)
        #expect(await state.polylineEditor.moveVertex(lineID: line.id, vertexIndex: 1, to: movedPoint))
        let draft = try #require(state.draftVector)

        let sourceComponentIdentity = try #require(source.features.first?.pathStableIdentities.first)
        #expect(state.polylineEditor.selectMapComponent(sourceComponentIdentity, in: rawLineA))
        #expect(state.polylineEditor.selectedLineID == line.id)
        #expect(!state.polylineEditor.selectMapComponent(sourceComponentIdentity, in: rawLineB))
        #expect(state.polylineEditor.selectMapComponent(line.id, in: rawLineA))

        let instances = state.vectors([source])
        #expect(instances.count == 2)
        for instance in instances {
            let feature = try #require(instance.features.first)
            #expect(feature.stableIdentity == source.features.first?.stableIdentity)
            #expect(feature.pathStableIdentities == [line.id])
            #expect(feature.sourceFeatureIndex == 0)
            #expect(feature.geometryPath == source.features.first?.geometryPath)
            #expect(feature.attributes == source.features.first?.attributes)
            #expect(feature.paths.first?[1] == movedPoint)
            #expect(instance.sourceRevision == draft.sourceRevision)
            #expect(SourceFilePaths.canonical(instance.url) == sourcePath)
        }
        #expect(state.draftVector?.features.first?.paths.first?[1] == movedPoint)
        #expect(source.features.first?.paths.first?[1] == MapPoint(x: 1, y: 1))
        #expect(instances[0].features.first?.pathStableIdentities == instances[1].features.first?.pathStableIdentities)
        #expect(instances[0].features.first?.stableIdentity == instances[1].features.first?.stableIdentity)
    }
}
