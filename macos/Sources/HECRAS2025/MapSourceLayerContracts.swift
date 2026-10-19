import Foundation
import RASWorkspaceCore

/// The exact map identity used by the source map-tree provider. Raster and
/// shapefile reads reuse this value instead of resolving a map by its title.
typealias MapSourceLayerMapRequest = MapTreeMapIdentity

struct MapSourceFileRevision: Codable, Hashable, Sendable {
    let inputPath: String
    let path: String
    let role: String
    let required: Bool
    let exists: Bool
    let revision: String?
}

struct MapSourceFamilyCapture: Codable, Hashable, Sendable {
    let family: String
    let sourcePath: String
    let revision: String
    let files: [MapSourceFileRevision]
}

struct MapSourceMapCapture: Codable, Hashable, Sendable {
    let projectPath: String
    let projectRevision: String
    let projectXmlSHA: String?
    let visualizationPath: String
    let visualizationRevision: String?
    let mapID: String?
    let mapIndex: Int?
    let mapName: String?
    let mapType: String
    let isPersisted: Bool
}

struct MapSourceNodeCapture: Codable, Hashable, Sendable {
    let map: MapSourceMapCapture
    let locator: CatalogTreeNodeLocator
    let family: MapSourceFamilyCapture
}

struct MapSourceRasterBounds: Codable, Hashable, Sendable {
    let minX: Double
    let minY: Double
    let maxX: Double
    let maxY: Double

    var isFiniteAndOrdered: Bool {
        minX.isFinite && minY.isFinite && maxX.isFinite && maxY.isFinite
            && maxX > minX && maxY > minY
    }
}

struct MapSourceRasterLayerPayload: Decodable, Sendable {
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
}

struct MapRasterSourceLoadRequest: Encodable, Sendable {
    let map: MapSourceLayerMapRequest
    let node: CatalogTreeNodeLocator
    let expectedFamily: MapSourceFamilyCapture?
    let viewport: RasterMapViewExtent?
}

struct MapRasterSourceLoadResult: Decodable, Sendable {
    let source: MapSourceNodeCapture
    let isSupported: Bool
    let unsupportedReason: String?
    let mapType: String
    let classification: String
    let nativeExtent: MapSourceRasterBounds
    let sourceExtent: MapSourceRasterBounds
    let summary: MapRasterSourceSummary
    let fileDetails: MapRasterSourceFileDetails
    let statistics: MapRasterSourceStatistics
    let noDataValues: [Double?]
    let pixelEncoding: String
    let previewSuppressed: Bool
    let layer: MapSourceRasterLayerPayload?
}

struct MapRasterSourceSummary: Decodable, Sendable {
    let fileName: String
    let directory: String
    let rasterProjection: String?
    let projectionStatus: String
    let overviewCount: Int
    let overviews: [String]
    let cellSizeX: Double
    let cellSizeY: Double
    let unitSystem: String?
    let noDataValues: [Double?]
}

struct MapRasterSourceFileDetails: Decodable, Sendable {
    let sizeBytes: Int64
    let uncompressedSizeBytes: Int64
    let compressionRatio: Double?
}

struct MapRasterSourceStatistics: Decodable, Sendable {
    let minimum: Double?
    let maximum: Double?
    let mean: Double?
    let standardDeviation: Double?
}

struct MapVectorSourceExtent: Codable, Hashable, Sendable {
    let minX: Double
    let minY: Double
    let maxX: Double
    let maxY: Double

    var isFiniteAndOrdered: Bool {
        minX.isFinite && minY.isFinite && maxX.isFinite && maxY.isFinite
            && maxX >= minX && maxY >= minY
    }
}

struct MapVectorSourceLoadRequest: Encodable, Sendable {
    let map: MapSourceLayerMapRequest
    let node: CatalogTreeNodeLocator
    let expectedFamily: MapSourceFamilyCapture?
}

struct MapVectorSourceVertex: Decodable, Hashable, Sendable {
    let x: Double
    let y: Double
    let sourceX: Double
    let sourceY: Double
    let z: Double?
    let m: Double?
}

struct MapVectorSourceAttribute: Decodable, Hashable, Sendable {
    let columnOrdinal: Int
    let columnName: String
    let type: String
    let value: String?
    let booleanValue: Bool?

    func typedValue() throws -> MapSourceAttributeValue {
        switch type.lowercased() {
        case "string":
            guard booleanValue == nil else { throw MapSourceLayerError.invalidVectorSnapshot }
            guard let value else { return .null }
            return .string(value)
        case "integer":
            guard booleanValue == nil else { throw MapSourceLayerError.invalidVectorSnapshot }
            guard let value else { return .null }
            guard Int64(value) != nil else { throw MapSourceLayerError.invalidVectorSnapshot }
            return .integer(value)
        case "number":
            guard booleanValue == nil else { throw MapSourceLayerError.invalidVectorSnapshot }
            guard let value else { return .null }
            guard let number = Double(value), number.isFinite else {
                throw MapSourceLayerError.invalidVectorSnapshot
            }
            return .number(value)
        case "boolean":
            if let booleanValue {
                guard value == nil else { throw MapSourceLayerError.invalidVectorSnapshot }
                return .boolean(booleanValue)
            }
            guard value == nil else { throw MapSourceLayerError.invalidVectorSnapshot }
            return .null
        default:
            throw MapSourceLayerError.unsupportedAttributeType(type)
        }
    }

    var displayValue: String {
        switch type.lowercased() {
        case "boolean": booleanValue.map(String.init) ?? ""
        default: value ?? ""
        }
    }
}

struct MapVectorSourcePart: Decodable, Sendable {
    let partOrdinal: Int
    let vertices: [MapVectorSourceVertex]
}

struct MapVectorSourceFeature: Decodable, Sendable {
    let sourceOrdinal: Int
    let sourceID: String?
    let shapeType: String
    let parts: [MapVectorSourcePart]
    let attributes: [MapVectorSourceAttribute]
}

struct MapVectorSourceData: Decodable, Sendable {
    let shapeType: String
    let shapeTypeCode: Int32
    let count: Int
    let sourceExtent: MapVectorSourceExtent?
    let extent: MapVectorSourceExtent?
    let projectionStatus: String
    let sourceProjectionWKT: String?
    let targetProjectionWKT: String?
    let features: [MapVectorSourceFeature]
}

struct MapVectorSourceLoadResult: Decodable, Sendable {
    let source: MapSourceNodeCapture
    let data: MapVectorSourceData
}

enum MapSourceLayerError: Error, LocalizedError, Sendable {
    case staleContext
    case mismatchedReply
    case sourceChanged
    case invalidRasterPayload
    case invalidVectorSnapshot
    case unsupportedAttributeType(String)
    case unsupportedMapLayerType(String)

    var errorDescription: String? {
        if let argument { return String(format: messageKey, argument) }
        return messageKey
    }

    // Decoding runs away from the UI actor. Localization reads the selected
    // interface language only when a view presents this typed error.
    @MainActor var presentationDescription: String {
        if let argument { return L10n.format(messageKey, argument) }
        return L10n.text(messageKey)
    }

    private var argument: String? {
        switch self {
        case .unsupportedAttributeType(let value), .unsupportedMapLayerType(let value): value
        default: nil
        }
    }

    private var messageKey: String {
        switch self {
        case .staleContext:
            "The map source changed while it was loading. Refresh the map layers."
        case .mismatchedReply:
            "The map source reader returned data for a different saved map node."
        case .sourceChanged:
            "A map source file changed while it was loading. Refresh the map layers."
        case .invalidRasterPayload:
            "The map source reader returned an invalid raster image."
        case .invalidVectorSnapshot:
            "The map source reader returned invalid vector geometry or attributes."
        case .unsupportedAttributeType:
            "The map source contains an unsupported attribute type: %@."
        case .unsupportedMapLayerType:
            "This map source type is not supported: %@."
        }
    }
}

struct MapSourceLayerDiagnostic: Identifiable, Equatable, Sendable {
    let nodeIdentity: String
    let nodeName: String
    let mapLayerType: String
    let message: String

    var id: String { nodeIdentity }
}

struct MapSourceLayerRenderResult: Sendable {
    let mapID: UUID
    let mapIdentity: MapSourceLayerMapRequest
    let vectors: [MapVectorLayer]
    let rasters: [MapRasterLayer]
    let capturesByNodeIdentity: [String: MapSourceNodeCapture]
    let payloadIDsByNodeIdentity: [String: [String]]
    let diagnostics: [MapSourceLayerDiagnostic]
}
