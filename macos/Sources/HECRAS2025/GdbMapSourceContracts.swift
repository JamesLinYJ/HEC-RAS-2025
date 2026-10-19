import CryptoKit
import Foundation
import RASWorkspaceCore

extension GdbMapSourceIdentity {
    var fileCount: Int { files.count }

    func validate(expectedPath: URL) throws {
        let canonicalExpected = SourceFilePaths.canonical(expectedPath)
        guard SourceFilePaths.canonical(URL(fileURLWithPath: sourcePath)) == canonicalExpected,
              GdbMapSourceRevision.isSHA256(revision),
              !files.isEmpty else {
            throw GdbMapSourceError.invalidSourceIdentity
        }
        var seen = Set<String>()
        var normalizedPaths: [String] = []
        for file in files {
            let path = file.relativePath.replacingOccurrences(of: "\\", with: "/")
            guard !path.isEmpty, !path.hasPrefix("/"),
                  !path.split(separator: "/").contains(".."),
                  file.length >= 0, GdbMapSourceRevision.isSHA256(file.revision),
                  seen.insert(path).inserted else {
                throw GdbMapSourceError.invalidSourceIdentity
            }
            normalizedPaths.append(path)
        }
        guard files.allSatisfy({ !$0.relativePath.contains("\\") }),
              normalizedPaths == normalizedPaths.sorted() else {
            throw GdbMapSourceError.invalidSourceIdentity
        }
    }
}

struct GdbMapLayerDescriptor: Codable, Hashable, Sendable, Identifiable {
    let name: String
    let geometryType: String
    let geometryTypeCode: Int32
    let vectorType: String
    let featureCount: Int64
    let projectionWKT: String?

    var id: String { "\(name.utf8.count):\(name)|\(vectorType)" }

    var featureKind: MapFeature.Kind? {
        Self.featureKind(for: vectorType)
    }

    static func featureKind(for vectorType: String) -> MapFeature.Kind? {
        switch vectorType {
        case "Point", "PointCollection": .point
        case "Line", "LineCollection": .line
        case "Polygon", "PolygonCollection": .polygon
        default: nil
        }
    }

    func validate() throws {
        guard !name.isEmpty, !geometryType.isEmpty, featureCount >= 0,
              featureKind != nil,
              projectionWKT?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != true else {
            throw GdbMapSourceError.invalidLayerDescriptor
        }
    }
}

struct GdbMapCatalogRequest: Encodable, Sendable {
    let sourcePath: String
    let expectedSourceRevision: String?
}

struct GdbMapCatalogResponse: Decodable, Sendable {
    let source: GdbMapSourceIdentity
    let layers: [GdbMapLayerDescriptor]
    let rasterSubdatasets: [GdbRasterSubdatasetDescriptor]

    private enum CodingKeys: String, CodingKey { case source, layers, rasterSubdatasets }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        source = try container.decode(GdbMapSourceIdentity.self, forKey: .source)
        layers = try container.decode([GdbMapLayerDescriptor].self, forKey: .layers)
        rasterSubdatasets = try container.decodeIfPresent([GdbRasterSubdatasetDescriptor].self,
                                                            forKey: .rasterSubdatasets) ?? []
    }
}

struct GdbMapDocumentRequest: Encodable, Sendable {
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
    let newName: String?
    let initialGeometryPath: String?
    let initialGeometryRevision: String?
    let initialPlanPath: String?
    let initialPlanRevision: String?
    var coreLayerContext: CoreLayerRequestContext? = nil
}

struct GdbMapImportRequest: Encodable, Sendable {
    let map: GdbMapDocumentRequest
    let expectedProjectRevision: String
    let source: GdbMapSourceIdentity
}

struct GdbMapImportResponse: Decodable, Sendable {
    let receipt: GdbMapMutationReceipt
    let source: GdbMapSourceIdentity
    let importedLayers: [GdbMapLayerDescriptor]
    let importedRasterSubdatasets: [GdbRasterSubdatasetDescriptor]

    private enum CodingKeys: String, CodingKey { case receipt, source, importedLayers, importedRasterSubdatasets }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        receipt = try container.decode(GdbMapMutationReceipt.self, forKey: .receipt)
        source = try container.decode(GdbMapSourceIdentity.self, forKey: .source)
        importedLayers = try container.decode([GdbMapLayerDescriptor].self, forKey: .importedLayers)
        importedRasterSubdatasets = try container.decodeIfPresent([GdbRasterSubdatasetDescriptor].self,
                                                                   forKey: .importedRasterSubdatasets) ?? []
    }
}

struct GdbMapMutationReceipt: Decodable, Hashable, Sendable {
    let mapIndex: Int
    let mapName: String
    let mapType: String
    let previousVisualizationRevision: String?
    let visualizationRevision: String
}

struct GdbMapSourceLoadRequest: Encodable, Sendable {
    let map: MapTreeMapIdentity
    let node: CatalogTreeNodeLocator
    let expectedSourceRevision: String
}

struct GdbMapSourceVertex: Decodable, Hashable, Sendable {
    let x: Double
    let y: Double
    let sourceX: Double
    let sourceY: Double
    let z: Double?
    let m: Double?
}

struct GdbMapSourceRing: Decodable, Sendable {
    let role: String
    let vertices: [GdbMapSourceVertex]
}

struct GdbMapSourceGeometry: Decodable, Sendable {
    let geometryType: String
    let geometryTypeCode: Int32
    let vertices: [GdbMapSourceVertex]
    let rings: [GdbMapSourceRing]
    let children: [GdbMapSourceGeometry]
}

struct GdbMapSourceAttribute: Decodable, Hashable, Sendable {
    let columnOrdinal: Int
    let columnName: String
    let type: String
    let value: String?
    let booleanValue: Bool?
    let isSet: Bool
    let isNull: Bool
    let timeZoneFlag: Int?
}

struct GdbMapSourceFeature: Decodable, Sendable {
    let sourceOrdinal: Int
    let sourceID: String?
    let geometry: GdbMapSourceGeometry
    let attributes: [GdbMapSourceAttribute]
}

struct GdbRasterSubdatasetDescriptor: Decodable, Hashable, Sendable, Identifiable {
    let name: String
    let connectionString: String
    let driverName: String
    let width: Int
    let height: Int
    let bandCount: Int
    let dataType: String
    let noDataValue: Double?
    let extent: MapVectorSourceExtent?
    let projectionWKT: String?
    let canRender: Bool
    let status: String
    let diagnostic: String?

    var id: String { connectionString }
    var isImportable: Bool { canRender && status == "available" }
}

struct GdbMapSourceData: Decodable, Sendable {
    let geometryType: String
    let geometryTypeCode: Int32
    let count: Int
    let sourceExtent: MapVectorSourceExtent?
    let extent: MapVectorSourceExtent?
    let projectionStatus: String
    let sourceProjectionWKT: String?
    let targetProjectionWKT: String?
    let features: [GdbMapSourceFeature]
}

struct GdbMapSourceLoadResponse: Decodable, Sendable {
    let map: MapSourceMapCapture
    let node: CatalogTreeNodeLocator
    let source: GdbMapSourceIdentity
    let layer: GdbMapLayerDescriptor
    let data: GdbMapSourceData
}

enum GdbMapSourceError: Error, LocalizedError, Sendable {
    case invalidSourceIdentity
    case invalidLayerDescriptor
    case staleContext
    case mismatchedReply
    case sourceChanged
    case invalidGeometry
    case noVectorLayers

    var errorDescription: String? {
        switch self {
        case .invalidSourceIdentity: "The File Geodatabase identity is invalid. Select it again."
        case .invalidLayerDescriptor: "The File Geodatabase returned an invalid vector layer description."
        case .staleContext: "The selected map or File Geodatabase changed while the request was running."
        case .mismatchedReply: "The File Geodatabase provider returned data for a different map layer."
        case .sourceChanged: "The File Geodatabase changed while it was being read. Select it again."
        case .invalidGeometry: "The File Geodatabase returned invalid geometry or attribute data."
        case .noVectorLayers: "The File Geodatabase contains no supported vector layers."
        }
    }
}

enum GdbMapSourceRevision {
    static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy(\.isHexDigit)
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02X", $0) }.joined()
    }
}

enum GdbFileGeodatabasePath {
    /// Returns the actual `.gdb` directory whether the open panel selected the
    /// package itself or a file inside it. No directory is inferred from a
    /// display name or from a similarly named neighboring file.
    static func root(for selection: URL, fileManager: FileManager = .default) -> URL? {
        let selected = selection.standardizedFileURL.resolvingSymlinksInPath()
        var candidate = selected
        let isSelectedDirectory = Self.isDirectory(selected, fileManager: fileManager)
        if !isSelectedDirectory { candidate.deleteLastPathComponent() }
        while candidate.path != "/" {
            if Self.isDirectory(candidate, fileManager: fileManager),
               candidate.pathExtension.caseInsensitiveCompare("gdb") == .orderedSame {
                return candidate.standardizedFileURL.resolvingSymlinksInPath()
            }
            candidate.deleteLastPathComponent()
        }
        return nil
    }

    private static func isDirectory(_ url: URL, fileManager: FileManager) -> Bool {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let type = attributes[.type] as? FileAttributeType else { return false }
        return type == .typeDirectory
    }
}

struct GdbMapVectorSourceReadRequest: Sendable {
    let mapID: UUID
    let url: URL
    let nodeID: String
    let locator: CatalogTreeNodeLocator
    let layerName: String
    let vectorType: String
    let displayName: String

    var canonicalPath: String { SourceFilePaths.canonical(url) }
}

@MainActor
protocol GdbMapSourceLoading {
    func catalog(sourcePath: String, expectedSourceRevision: String?) async throws -> GdbMapCatalogResponse
    func load(_ request: GdbMapSourceLoadRequest) async throws -> GdbMapSourceLoadResponse
}

@MainActor
final class BackendGdbMapSourceProvider: GdbMapSourceLoading {
    private let client: BackendProcessClient

    init(client: BackendProcessClient? = nil) {
        self.client = client ?? BackendProcessClient(executableURL: Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/Backend/HECRASBackend"))
    }

    func catalog(sourcePath: String, expectedSourceRevision: String? = nil) async throws -> GdbMapCatalogResponse {
        try await client.request("map.gdb.catalog", parameters: GdbMapCatalogRequest(
            sourcePath: sourcePath, expectedSourceRevision: expectedSourceRevision), as: GdbMapCatalogResponse.self)
    }

    func load(_ request: GdbMapSourceLoadRequest) async throws -> GdbMapSourceLoadResponse {
        try await client.request("map.gdb.source.load", parameters: request, as: GdbMapSourceLoadResponse.self)
    }
}
