import Foundation
import RASWorkspaceCore

struct StreamModeConnectRequest: Encodable, Sendable {
    let pipeName: String
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
    func connect(pipeName: String) throws
        -> BackendDuplexOperation<StreamModeControl, BackendProgressUpdate, StreamModeConnectResult>
}

@MainActor
final class BackendStreamModeProvider: StreamModeConnecting {
    private let client: BackendProcessClient

    init(client: BackendProcessClient? = nil) {
        self.client = client ?? BackendProcessClient(executableURL: Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/Backend/HECRASBackend"))
    }

    func connect(pipeName: String) throws
        -> BackendDuplexOperation<StreamModeControl, BackendProgressUpdate, StreamModeConnectResult> {
        try client.startDuplex("map.streamMode.connect",
            parameters: StreamModeConnectRequest(pipeName: pipeName),
            control: StreamModeControl.self, event: BackendProgressUpdate.self,
            as: StreamModeConnectResult.self)
    }
}
