import Foundation
import RASWorkspaceCore

struct BackgroundMapTileJsonRequest: Codable, Sendable {
    let capture: BackgroundMapRenderRequest
    let clickedWorldPoint: BackgroundMapCoordinate
}

struct BackgroundMapTileAddress: Codable, Equatable, Sendable {
    let zoom: Int
    let column: Int
    let tmsRow: Int
}

struct BackgroundMapTileJsonResult: Codable, Equatable, Sendable {
    let capture: BackgroundMapRenderRequest
    let clickedWorldPoint: BackgroundMapCoordinate
    let sourceID: String
    let status: String
    let message: String?
    let tile: BackgroundMapTileAddress?
    let sourceRevision: String?
    let rawJson: String?
}

@MainActor
struct BackgroundMapTileJsonProvider {
    private let requestBody: @MainActor (BackgroundMapTileJsonRequest) async throws -> BackgroundMapTileJsonResult

    init(client: BackendProcessClient) {
        requestBody = { request in
            try await client.request("map.background.tileJson", parameters: request)
        }
    }

    init(request: @escaping @MainActor (BackgroundMapTileJsonRequest) async throws -> BackgroundMapTileJsonResult) {
        requestBody = request
    }

    func load(_ request: BackgroundMapTileJsonRequest) async throws -> BackgroundMapTileJsonResult {
        try await requestBody(request)
    }
}
