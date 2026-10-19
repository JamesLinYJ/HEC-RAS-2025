import Foundation
import RASWorkspaceCore

@MainActor
protocol MapRasterSourceLoading {
    func load(_ request: MapRasterSourceLoadRequest) async throws -> MapRasterSourceLoadResult
}

@MainActor
protocol MapVectorSourceLoading {
    func load(_ request: MapVectorSourceLoadRequest) async throws -> MapVectorSourceLoadResult
}

@MainActor
final class BackendMapRasterSourceProvider: MapRasterSourceLoading {
    private let client: BackendProcessClient

    init(client: BackendProcessClient? = nil) {
        self.client = client ?? BackendProcessClient(executableURL: Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/Backend/HECRASBackend"))
    }

    func load(_ request: MapRasterSourceLoadRequest) async throws -> MapRasterSourceLoadResult {
        try await client.request("map.raster.source.load", parameters: request,
            as: MapRasterSourceLoadResult.self)
    }
}

@MainActor
final class BackendMapVectorSourceProvider: MapVectorSourceLoading {
    private let client: BackendProcessClient

    init(client: BackendProcessClient? = nil) {
        self.client = client ?? BackendProcessClient(executableURL: Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/Backend/HECRASBackend"))
    }

    func load(_ request: MapVectorSourceLoadRequest) async throws -> MapVectorSourceLoadResult {
        try await client.request("map.vector.source.load", parameters: request,
            as: MapVectorSourceLoadResult.self)
    }
}
