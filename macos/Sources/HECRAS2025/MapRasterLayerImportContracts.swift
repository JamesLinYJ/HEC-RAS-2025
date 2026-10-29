import Foundation
import RASWorkspaceCore

struct MapRasterLayerInspectRequest: Encodable, Sendable {
    let sourcePath: String
}

struct MapRasterLayerInspectResult: Decodable, Sendable {
    let sourcePath: String
    let sourceCanonicalPath: String
    let sourceRevision: String
    let driver: String
    let dataType: String
    let width: Int
    let height: Int
    let bandCount: Int
    let mapLayerType: String
    let supportedMapLayerTypes: [String]
    let projectionWKT: String?
    let unitSystem: String?
    let cellSizeX: Double
    let canRenderPreview: Bool
    let info: RasterImportContextInfo
    let stats: RasterImportContextStats
}

struct MapRasterLayerPreviewRequest: Encodable, Sendable {
    let sourcePath: String
    let sourceRevision: String
    let mapLayerType: String
    let projectPath: String
    let projectXml: String?
    let projectXmlSHA: String?
    let viewport: RasterMapViewExtent?
    var coreLayerContext: CoreLayerRequestContext? = nil
}

struct MapRasterLayerPreviewResult: Decodable, Sendable {
    let raster: MapRasterLayerImagePayload
}

struct MapRasterLayerImagePayload: Decodable, Sendable {
    let id: String
    let sourceMapID: String?
    let name: String
    let width: Int
    let height: Int
    let rgba: Data
    let minX: Double
    let minY: Double
    let maxX: Double
    let maxY: Double

    func makeLayer(matching source: RasterMapSourceDescriptor) throws -> MapRasterLayer {
        guard id == source.id,
              let mapID = sourceMapID.flatMap(UUID.init(uuidString:)),
              mapID == source.sourceMapID else {
            throw BackendServiceError(code: "sourceChanged", message: "The raster response no longer belongs to the selected map layer.")
        }
        return try MapRasterLayer(id: id, name: name, width: width, height: height, rgba: rgba,
            lowerLeft: MapPoint(x: minX, y: minY), upperRight: MapPoint(x: maxX, y: maxY), sourceMapID: mapID)
    }
}

struct MapRasterLayerImportIdentity: Encodable, Sendable {
    let map: MapRasterLayerMapRequest
    let sourcePath: String
    let sourceRevision: String
    let mapLayerType: String
    let expectedProjectRevision: String
    let expectedSourceCanonicalPath: String
}

struct MapRasterLayerMapRequest: Encodable, Sendable {
    let projectPath: String
    let projectXml: String?
    let projectXmlSHA: String?
    let expectedVisualizationRevision: String?
    let kind: String
    let name: String?
    let mapID: String?
    let mapIndex: Int?
    let mapName: String?
    let mapType: String?
    var coreLayerContext: CoreLayerRequestContext? = nil
}

struct MapRasterLayerLoadRequest: Encodable, Sendable {
    let source: RasterMapSourceDescriptor
    let projectXml: String?
    let viewport: RasterMapViewExtent?
}

struct MapRasterLayerLoadReply: Decodable, Sendable {
    let previousVisualizationRevision: String
    let visualizationRevision: String
    let sourceRevision: String
    let raster: MapRasterLayerImagePayload
    let rasterInfoStats: RasterImportContextSource?
}
