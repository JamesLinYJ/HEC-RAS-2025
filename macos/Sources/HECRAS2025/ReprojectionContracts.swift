import Foundation

enum ReprojectionOption: String, CaseIterable, Codable, Identifiable, Sendable {
    case project = "Project"
    case wgs84 = "WGS84"
    case webMercator = "WebMercator"
    case custom = "Custom"

    var id: String { rawValue }
}

enum ReprojectionSide: String, CaseIterable, Sendable {
    case source
    case destination
}

enum ReprojectionAxis: String, Sendable {
    case x = "X"
    case y = "Y"
}

struct ReprojectionInputRow: Codable, Identifiable, Equatable, Sendable {
    let id: String
    var xText: String
    var yText: String

    init(id: String = UUID().uuidString, xText: String = "", yText: String = "") {
        self.id = id
        self.xText = xText
        self.yText = yText
    }
}

struct ReprojectionRequest: Encodable, Equatable, Sendable {
    let sourceOption: String
    let destinationOption: String
    let projectProjection: ProjectionDefinitionDraft?
    let sourceCustomProjectionText: String
    let destinationCustomProjectionText: String
    let rows: [ReprojectionInputRow]
    var numberCulture: String? = nil
}

struct ReprojectionProjectionSummary: Codable, Equatable, Sendable {
    let option: String
    let projectionName: String?
    let validity: String?
    let unitName: String?
    let isVertical: Bool
    let isProjected: Bool
    let epsgCode: String?
    let utmZone: String?
    var areaOfUse: ProjectionAreaOfUse? = nil
}

enum ReprojectionRowStatus: String, Codable, Sendable {
    case transformed
    case blank
    case invalid
    case failed
    case unavailable

    var localizationKey: String {
        switch self {
        case .transformed: return "Transformed"
        case .blank: return "Blank"
        case .invalid: return "Invalid"
        case .failed: return "Failed"
        case .unavailable: return "Unavailable"
        }
    }
}

struct ReprojectionRowResult: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let status: ReprojectionRowStatus
    let x: Double?
    let y: Double?
}

struct ReprojectionSnapshot: Decodable, Equatable, Sendable {
    let sourceSummary: String
    let destinationSummary: String
    let errorCode: String?
    let errorMessage: String?
    let rows: [ReprojectionRowResult]
    let sourceProjectionSummary: ReprojectionProjectionSummary?
    let destinationProjectionSummary: ReprojectionProjectionSummary?

    enum CodingKeys: String, CodingKey {
        case sourceSummary
        case destinationSummary
        case errorCode
        case errorMessage
        case rows
        case sourceProjectionSummary
        case destinationProjectionSummary
    }
}

struct ReprojectionIdentifyRequest: Encodable, Sendable {
    let paths: [String]
}

struct ReprojectionIdentifySnapshot: Decodable, Equatable, Sendable {
    let recognizedPath: String?
    let wkt: String?
    let projectionSummary: ReprojectionProjectionSummary?
    let errorMessage: String?
}

enum ReprojectionProviderError: Error, LocalizedError, Sendable {
    case invalidRowResponse
    case invalidProjectionFileResponse

    var errorDescription: String? {
        switch self {
        case .invalidRowResponse:
            return "The reprojection service returned an invalid row response."
        case .invalidProjectionFileResponse:
            return "The reprojection service returned an invalid projection file response."
        }
    }
}
