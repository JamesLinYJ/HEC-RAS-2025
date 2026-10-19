import Foundation
import RASWorkspaceCore

@MainActor
protocol MapHoverIdentifyProviding {
    func identify(_ request: MapHoverIdentifyRequest) async throws -> MapHoverIdentifyResult
}

@MainActor
struct BackendMapHoverIdentifyProvider: MapHoverIdentifyProviding {
    private let client: BackendProcessClient

    init(client: BackendProcessClient? = nil) {
        self.client = client ?? BackendProcessClient(executableURL: Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/Backend/HECRASBackend"))
    }

    func identify(_ request: MapHoverIdentifyRequest) async throws -> MapHoverIdentifyResult {
        try await client.request("map.hover.identify", parameters: request,
            as: MapHoverIdentifyResult.self)
    }
}
