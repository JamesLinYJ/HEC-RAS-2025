import Foundation
import RASWorkspaceCore

@MainActor
protocol WilcockProvider {
    func load(numberCulture: String) async throws -> WilcockWorkspaceSnapshot
    func evaluate(_ request: WilcockEvaluateRequest) async throws -> WilcockWorkspaceSnapshot
}

@MainActor
final class BackendWilcockProvider: WilcockProvider {
    private let client: BackendProcessClient

    init(client: BackendProcessClient? = nil) {
        self.client = client ?? BackendProcessClient(executableURL: Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/Backend/HECRASBackend"))
    }

    func load(numberCulture: String) async throws -> WilcockWorkspaceSnapshot {
        let snapshot = try await client.request("wilcock.load", parameters: WilcockLoadRequest(numberCulture: numberCulture),
                                                as: WilcockWorkspaceSnapshot.self)
        try snapshot.validate()
        try Task.checkCancellation()
        return snapshot
    }

    func evaluate(_ request: WilcockEvaluateRequest) async throws -> WilcockWorkspaceSnapshot {
        let snapshot = try await client.request("wilcock.evaluate", parameters: request,
                                                as: WilcockWorkspaceSnapshot.self)
        try snapshot.validate()
        try Task.checkCancellation()
        return snapshot
    }
}

private struct WilcockLoadRequest: Encodable, Sendable {
    var numberCulture: String
}
