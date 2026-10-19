import Foundation
import Testing
@testable import HECRAS2025

@Suite
struct GeometryVectorImportContractTests {
    @Test
    func importMutationRetainsActualProjectedLinesAndSourceFamily() throws {
        let family = MapSourceFamilyCapture(family: "shapefile", sourcePath: "/tmp/lines.shp",
            revision: String(repeating: "A", count: 64), files: [])
        let payload = GeometryTopologyImportPayload(mode: "Merge", mergeContiguousArcs: true,
            removeExternalArcs: false,
            sources: [GeometryTopologyImportSource(path: family.sourcePath, family: family)],
            features: [GeometryTopologyImportFeature(geometryType: "polyline", points: [
                GeometryTopologyCoordinate(x: 100, y: 200),
                GeometryTopologyCoordinate(x: 300, y: 400)
            ])])
        let mutation = GeometryTopologyMutation(operation: "importLines", featureKind: "geometry",
            featureIDs: [], importPayload: payload)

        let data = try JSONEncoder().encode(mutation)
        let decoded = try JSONDecoder().decode(GeometryTopologyMutation.self, from: data)
        #expect(decoded.operation == "importLines")
        #expect(decoded.importPayload?.sources.first?.family.revision == family.revision)
        #expect(decoded.importPayload?.features.first?.geometryType == "polyline")
        #expect(decoded.importPayload?.features.first?.points == payload.features.first?.points)
    }

    @Test
    func olderTopologyMutationsDecodeWithoutImportPayload() throws {
        let data = Data("""
        {"operation":"setField","featureKind":"arc","featureIDs":[4],"fieldID":"ConstantSize","value":"12"}
        """.utf8)
        let decoded = try JSONDecoder().decode(GeometryTopologyMutation.self, from: data)
        #expect(decoded.operation == "setField")
        #expect(decoded.importPayload == nil)
    }

    @Test
    func genericSpatialImportRequiresAnExplicitSupportedLayer() {
        #expect(SpatialBoundaryImportLayerRoute.resolve(layerID: nil, selectedLayer: nil) == nil)
        #expect(SpatialBoundaryImportLayerRoute.resolve(layerID: nil, selectedLayer: .evapotranspiration) == nil)
        #expect(SpatialBoundaryImportLayerRoute.resolve(layerID: "evapotranspiration", selectedLayer: .wind) == nil)

        let supported = ["precipitation", "wind", "airPressure", "airDensity"]
        #expect(SpatialBoundaryImportLayerRoute.supportedLayers.map(\.rawValue) == supported)
        for layerID in supported {
            #expect(SpatialBoundaryImportLayerRoute.resolve(layerID: layerID, selectedLayer: nil)?.rawValue == layerID)
        }

        // A stale generic route cannot inherit a previously selected layer.
        #expect(SpatialBoundaryImportLayerRoute.resolve(layerID: "unknown", selectedLayer: .precipitation) == nil)
    }
}
