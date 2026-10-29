import Foundation
import RASWorkspaceCore

struct StreamModeConnectRequest: Encodable, Sendable {
    let pipeName: String
    let sessionID: UUID
}

struct StreamModeConnectResult: Decodable, Sendable {
    let pipeName: String
    let objectsReceived: Int64
}

struct StreamModeControl: Encodable, Sendable {
    let type: String
    static let cancel = Self(type: "cancel")
}

@MainActor
protocol StreamModeConnecting {
    func connect(pipeName: String, sessionID: UUID) throws
        -> BackendDuplexOperation<StreamModeControl, BackendProgressUpdate, StreamModeConnectResult>
}

@MainActor
protocol StreamModeTinProviding {
    func loadTinOptions(assets: [StreamModeTinAssetReference], selectedProfileIndex: Int) async throws -> StreamModeTinOptionsResult
    func renderTin(request: StreamModeTinRenderRequest) async throws -> StreamModeTinRenderResult
    func releaseTinAsset(_ asset: StreamModeTinAssetReference) async throws
    func releaseTinSession(_ sessionID: UUID) async throws
}

@MainActor
final class BackendStreamModeProvider: StreamModeConnecting, StreamModeTinProviding {
    private let client: BackendProcessClient

    init(client: BackendProcessClient? = nil) {
        self.client = client ?? BackendProcessClient(executableURL: Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/Backend/HECRASBackend"))
    }

    func connect(pipeName: String, sessionID: UUID) throws
        -> BackendDuplexOperation<StreamModeControl, BackendProgressUpdate, StreamModeConnectResult> {
        try client.startDuplex("map.streamMode.connect",
            parameters: StreamModeConnectRequest(pipeName: pipeName, sessionID: sessionID),
            control: StreamModeControl.self, event: BackendProgressUpdate.self,
            as: StreamModeConnectResult.self)
    }

    func loadTinOptions(assets: [StreamModeTinAssetReference], selectedProfileIndex: Int) async throws -> StreamModeTinOptionsResult {
        try await client.request("map.streamMode.tin.options",
            parameters: StreamModeTinOptionsRequest(assets: assets, selectedProfileIndex: selectedProfileIndex),
            as: StreamModeTinOptionsResult.self)
    }

    func renderTin(request: StreamModeTinRenderRequest) async throws -> StreamModeTinRenderResult {
        try await client.request("map.streamMode.tin.render", parameters: request,
            as: StreamModeTinRenderResult.self)
    }

    func releaseTinAsset(_ asset: StreamModeTinAssetReference) async throws {
        _ = try await client.request("map.streamMode.tin.asset.release",
            parameters: StreamModeTinAssetRequest(asset: asset), as: StreamModeTinAssetReleaseResult.self)
    }

    func releaseTinSession(_ sessionID: UUID) async throws {
        let result = try await client.request("map.streamMode.tin.session.release",
            parameters: StreamModeTinSessionReleaseRequest(sessionID: sessionID),
            as: StreamModeTinSessionReleaseResult.self)
        guard result.released else { throw StreamModeTinProviderError.sessionReleaseIncomplete }
    }
}

private enum StreamModeTinProviderError: Error {
    case sessionReleaseIncomplete
}
