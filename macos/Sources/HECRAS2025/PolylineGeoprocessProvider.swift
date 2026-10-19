import Foundation
import RASWorkspaceCore

enum PolylineGeoprocessOperation: String, CaseIterable, Identifiable, Sendable {
    case filter
    case smooth
    var id: String { rawValue }
}

struct PolylineGeoprocessRequest: Encodable, Sendable {
    let operation: String
    let coordinates: [[Double]]
    let epsilon: Double?
    let windowSize: Int?
    let iterations: Int?

    init(operation: PolylineGeoprocessOperation, coordinates: [[Double]],
         epsilon: Double? = nil, windowSize: Int? = nil, iterations: Int? = nil) {
        self.operation = operation.rawValue
        self.coordinates = coordinates
        self.epsilon = epsilon
        self.windowSize = windowSize
        self.iterations = iterations
    }
}

struct PolylineGeoprocessResult: Decodable, Sendable {
    let coordinates: [[Double]]
}

@MainActor
protocol PolylineGeoprocessProvider {
    func transform(_ request: PolylineGeoprocessRequest) async throws -> PolylineGeoprocessResult
}

@MainActor
struct BackendPolylineGeoprocessProvider: PolylineGeoprocessProvider {
    let client: BackendProcessClient

    init(client: BackendProcessClient? = nil) {
        self.client = client ?? BackendProcessClient(executableURL: Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/Backend/HECRASBackend"))
    }

    func transform(_ request: PolylineGeoprocessRequest) async throws -> PolylineGeoprocessResult {
        try await client.request("map.polyline.geoprocess", parameters: request, as: PolylineGeoprocessResult.self)
    }
}
