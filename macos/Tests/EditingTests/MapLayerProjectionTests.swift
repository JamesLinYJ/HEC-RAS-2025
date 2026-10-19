import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

struct MapLayerProjectionTests {
    @Test @MainActor
    func profileFramesPreserveImportedLayersAndStayInTheirOwningMap() throws {
        let first = MapState(), second = MapState(id: UUID())
        let imported = MapVectorLayer(url: URL(fileURLWithPath: "/tmp/import.geojson"), features: [
            MapFeature(id: 0, kind: .line, paths: [[.init(x: 0, y: 0), .init(x: 1, y: 1)]], attributes: [:])
        ])
        let model = MapVectorLayer(url: URL(fileURLWithPath: "/tmp/model-profile"), features: [
            MapFeature(id: 1, kind: .point, paths: [[.init(x: 0.5, y: 0.5)]], attributes: [:])
        ], sourceMapID: first.id)
        let terrain = try raster("terrain", mapID: nil)
        let frame = try raster("profile", mapID: first.id)
        first.installProfile(.init(vectors: [model], rasters: [frame], preview: [], selectedLayerID: nil, selectedFeatureID: nil))
        #expect(first.vectors([imported]).map(\.id) == [imported.id, model.id])
        #expect(first.rasters([terrain]).map(\.id) == [terrain.id, frame.id])
        #expect(second.vectors([imported]).map(\.id) == [imported.id])
        #expect(second.rasters([terrain]).map(\.id) == [terrain.id])
        first.clearProfileRender()
        #expect(first.vectors([imported]).map(\.id) == [imported.id])
        #expect(first.rasters([terrain]).map(\.id) == [terrain.id])
    }

    @Test @MainActor
    func sourceBucketVisibilityAndViewportReferenceDoNotChangeWithSampledFrameBounds() throws {
        let state = MapState()
        let url = URL(fileURLWithPath: "/tmp/mixed.geojson")
        let shared = MapVectorLayer(url: url, features: [
            .init(id: 0, kind: .point, paths: [[.init(x: 2, y: 2)]], attributes: [:]),
            .init(id: 1, kind: .line, paths: [[.init(x: 0, y: 0), .init(x: 10, y: 10)]], attributes: [:])
        ])
        state.sourceVectorPaths = [SourceFilePaths.canonical(url)]
        state.sourceVectorKinds = [SourceFilePaths.canonical(url): ["PolylinesVector"]]
        #expect(state.vectors([shared]).first?.features.map(\.id) == [1])
        state.establishReference(vectors: [shared], rasters: [])
        let reference = state.referencePoints
        let frame = try MapRasterLayer(id: "viewport-frame", name: "Depth", width: 1, height: 1,
            rgba: Data([1, 2, 3, 255]), lowerLeft: .init(x: -100, y: -100), upperRight: .init(x: 100, y: 100), sourceMapID: state.id)
        state.installResultLayers([frame], legends: [])
        #expect(state.transformPoints(vectors: [shared], rasters: []) == reference)
        #expect(state.rasters([]).map(\.id) == [frame.id])
    }

    private func raster(_ id: String, mapID: UUID?) throws -> MapRasterLayer {
        try MapRasterLayer(id: id, name: id, width: 1, height: 1, rgba: Data([0, 0, 0, 255]),
            lowerLeft: .init(x: 0, y: 0), upperRight: .init(x: 1, y: 1), sourceMapID: mapID)
    }
}
