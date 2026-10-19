import Foundation
import RASWorkspaceCore
import SwiftUI

enum StreamModeSessionState: Equatable {
    case idle
    case connecting
    case streaming
    case completed(Int64)
    case cancelled
    case failed(String)
}

struct StreamModeMapObject: Identifiable, Equatable, Sendable {
    let id: String
    let operationID: UUID
    let source: BackendStreamModeFrame
}

/// Operation identity is independent of the source's per-connection sequence.
/// It prevents queued events from an older pipe connection being installed later.
struct StreamModeFrameIdentityStore {
    private(set) var activeOperationID: UUID?
    private(set) var mapObjects: [StreamModeMapObject] = []
    private var lastSequence: Int64 = -1

    mutating func begin(_ operationID: UUID) {
        activeOperationID = operationID
        mapObjects = []
        lastSequence = -1
    }

    mutating func cancel(_ operationID: UUID) -> Bool {
        guard activeOperationID == operationID else { return false }
        activeOperationID = nil
        return true
    }

    mutating func finish(_ operationID: UUID) -> Bool {
        guard activeOperationID == operationID else { return false }
        activeOperationID = nil
        return true
    }

    func accepts(_ operationID: UUID) -> Bool {
        activeOperationID == operationID
    }

    @discardableResult
    mutating func accept(_ frame: BackendStreamModeFrame, operationID: UUID) -> Bool {
        guard accepts(operationID), frame.sequence > lastSequence, isValid(frame) else { return false }
        lastSequence = frame.sequence
        mapObjects.append(StreamModeMapObject(
            id: operationID.uuidString + ":" + String(frame.sequence),
            operationID: operationID,
            source: frame))
        return true
    }

    private func isValid(_ frame: BackendStreamModeFrame) -> Bool {
        guard frame.coordinateCount == frame.coordinates.count,
              frame.coordinates.allSatisfy({ $0.x.isFinite && $0.y.isFinite }),
              frame.coordinates.allSatisfy({ ($0.z?.isFinite ?? true) && ($0.m?.isFinite ?? true) }),
              frame.zFillValue?.isFinite ?? true,
              frame.mFillValue?.isFinite ?? true,
              frame.paths.allSatisfy({ path in
                  path.allSatisfy { $0 >= 0 && $0 < frame.coordinates.count }
              }),
              frame.triangles.allSatisfy({ triangle in
                  triangle.count == 3 && triangle.allSatisfy { $0 >= 0 && $0 < frame.coordinates.count }
              }) else { return false }
        return true
    }
}

@MainActor
final class StreamModeSession: ObservableObject {
    @Published private(set) var state: StreamModeSessionState = .idle
    @Published private(set) var mapObjects: [StreamModeMapObject] = []
    @Published private(set) var pipeName = ""

    private let provider: any StreamModeConnecting
    private var frameStore = StreamModeFrameIdentityStore()
    private var operation: BackendDuplexOperation<StreamModeControl,
        BackendProgressUpdate, StreamModeConnectResult>?
    private var worker: Task<Void, Never>?

    init(provider: any StreamModeConnecting = BackendStreamModeProvider()) {
        self.provider = provider
    }

    var currentOperationID: UUID? { frameStore.activeOperationID }
    var isActive: Bool { frameStore.activeOperationID != nil }

    func start(pipeName: String) {
        stopCurrentOperation()
        self.pipeName = pipeName
        mapObjects = []

        guard !pipeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            state = .failed(L10n.text("Enter a named pipe to connect to stream mode."))
            return
        }

        let operationID = UUID()
        frameStore.begin(operationID)
        state = .connecting
        do {
            let operation = try provider.connect(pipeName: pipeName)
            self.operation = operation
            worker = Task { [weak self] in
                await self?.consume(operation, operationID: operationID)
            }
        } catch {
            _ = frameStore.finish(operationID)
            state = .failed(error.localizedDescription)
        }
    }

    func cancel() {
        guard let operationID = frameStore.activeOperationID else { return }
        _ = frameStore.cancel(operationID)
        operation?.cancel()
        operation = nil
        worker?.cancel()
        worker = nil
        state = .cancelled
    }

    /// Internal so the state transition and stale-event guard can be checked
    /// without starting a process or requiring a live named-pipe peer.
    func accept(_ frame: BackendStreamModeFrame, operationID: UUID) {
        guard frameStore.accept(frame, operationID: operationID) else { return }
        mapObjects = frameStore.mapObjects
        state = .streaming
    }

    private func consume(
        _ operation: BackendDuplexOperation<StreamModeControl,
            BackendProgressUpdate, StreamModeConnectResult>,
        operationID: UUID
    ) async {
        do {
            for try await update in operation.events {
                if Task.isCancelled { throw CancellationError() }
                if let frame = update.streamMapFrame {
                    accept(frame, operationID: operationID)
                }
            }
            let result = try await operation.value()
            guard frameStore.finish(operationID) else { return }
            self.operation = nil
            worker = nil
            state = .completed(result.objectsReceived)
        } catch {
            guard frameStore.accepts(operationID) else { return }
            _ = frameStore.cancel(operationID)
            self.operation = nil
            worker = nil
            if error is CancellationError {
                state = .cancelled
            } else {
                state = .failed(error.localizedDescription)
            }
        }
    }

    private func stopCurrentOperation() {
        if let operationID = frameStore.activeOperationID {
            _ = frameStore.cancel(operationID)
        }
        operation?.cancel()
        operation = nil
        worker?.cancel()
        worker = nil
    }

}
