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
        guard accepts(operationID), frame.sequence > lastSequence, isValid(frame, operationID: operationID) else { return false }
        lastSequence = frame.sequence
        mapObjects.append(StreamModeMapObject(
            id: operationID.uuidString + ":" + String(frame.sequence),
            operationID: operationID,
            source: frame))
        return true
    }

    private func isValid(_ frame: BackendStreamModeFrame, operationID: UUID) -> Bool {
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
        if frame.objectType == "Tin" {
            guard let asset = frame.tinAsset, asset.sessionID == operationID,
                  asset.sequence == frame.sequence,
                  asset.assetID.uuidString != "00000000-0000-0000-0000-000000000000",
                  asset.sha256.count == 64,
                  asset.sha256.allSatisfy({ $0.isHexDigit }) else { return false }
        } else if frame.tinAsset != nil {
            return false
        }
        return true
    }
}

@MainActor
final class StreamModeSession: ObservableObject {
    private typealias DuplexOperation = BackendDuplexOperation<StreamModeControl,
        BackendProgressUpdate, StreamModeConnectResult>

    private struct RetiringSource {
        let operation: DuplexOperation?
        let worker: Task<Void, Never>?
        let sessionIDs: Set<UUID>
    }

    @Published private(set) var state: StreamModeSessionState = .idle
    @Published private(set) var mapObjects: [StreamModeMapObject] = []
    @Published private(set) var pipeName = ""

    private let provider: any StreamModeConnecting
    let tinRenderSession: StreamModeTinRenderSession
    private var frameStore = StreamModeFrameIdentityStore()
    private var operation: DuplexOperation?
    private var worker: Task<Void, Never>?
    private var startGeneration: UInt64 = 0
    private var tinOwnerSessionIDs = Set<UUID>()

    init(provider: any StreamModeConnecting = BackendStreamModeProvider()) {
        self.provider = provider
        let tinProvider = (provider as? any StreamModeTinProviding) ?? BackendStreamModeProvider()
        tinRenderSession = StreamModeTinRenderSession(provider: tinProvider)
    }

    var currentOperationID: UUID? { frameStore.activeOperationID }
    var isActive: Bool { frameStore.activeOperationID != nil }

    func start(pipeName: String) {
        startGeneration &+= 1
        let generation = startGeneration
        let retiring = stopCurrentOperation()
        tinRenderSession.clear()
        self.pipeName = pipeName
        mapObjects = []

        guard !pipeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            state = .failed(L10n.text("Enter a named pipe to connect to stream mode."))
            Task { await retire(retiring) }
            return
        }

        let operationID = UUID()
        frameStore.begin(operationID)
        state = .connecting
        Task {
            await retire(retiring)
            guard startGeneration == generation, frameStore.accepts(operationID) else { return }
            do {
                let operation = try provider.connect(pipeName: pipeName, sessionID: operationID)
                self.operation = operation
                tinOwnerSessionIDs.insert(operationID)
                self.startWorker(operation, operationID: operationID)
            } catch {
                _ = frameStore.finish(operationID)
                state = .failed(error.localizedDescription)
            }
        }
    }

    func cancel() {
        guard let operationID = frameStore.activeOperationID else { return }
        _ = frameStore.cancel(operationID)
        operation?.cancel()
        worker?.cancel()
        worker = nil
        state = .cancelled
    }

    func close() {
        startGeneration &+= 1
        let wasActive = isActive
        let retiring = stopCurrentOperation()
        if wasActive { state = .cancelled }
        mapObjects = []
        tinRenderSession.clear()
        Task { await retire(retiring) }
    }

    /// Internal so the state transition and stale-event guard can be checked
    /// without starting a process or requiring a live named-pipe peer.
    func accept(_ frame: BackendStreamModeFrame, operationID: UUID) async {
        guard frameStore.accept(frame, operationID: operationID) else {
            if let asset = frame.tinAsset,
               !mapObjects.contains(where: { $0.source.tinAsset == asset }) {
                let reference = StreamModeTinAssetReference(sessionID: asset.sessionID,
                    sequence: asset.sequence, assetID: asset.assetID, sha256: asset.sha256)
                await tinRenderSession.release([reference])
            }
            return
        }
        mapObjects = frameStore.mapObjects
        state = .streaming
    }

    private func consume(
        _ operation: DuplexOperation,
        operationID: UUID
    ) async {
        do {
            for try await update in operation.events {
                if Task.isCancelled { throw CancellationError() }
                if let frame = update.streamMapFrame {
                    await accept(frame, operationID: operationID)
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

    private func startWorker(_ operation: DuplexOperation, operationID: UUID) {
        worker = Task { [weak self] in
            await self?.consume(operation, operationID: operationID)
        }
    }

    private func stopCurrentOperation() -> RetiringSource {
        var sessionIDs = tinOwnerSessionIDs
        sessionIDs.formUnion(mapObjects.compactMap { $0.source.tinAsset?.sessionID })
        if let operationID = frameStore.activeOperationID {
            _ = frameStore.cancel(operationID)
        }
        let retiring = RetiringSource(operation: operation, worker: worker, sessionIDs: sessionIDs)
        retiring.operation?.cancel()
        retiring.worker?.cancel()
        operation = nil
        worker = nil
        return retiring
    }

    private func retire(_ source: RetiringSource) async {
        if let operation = source.operation {
            _ = try? await operation.value()
        }
        if let worker = source.worker { await worker.value }

        for sessionID in source.sessionIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
            if await tinRenderSession.releaseSession(sessionID) {
                tinOwnerSessionIDs.remove(sessionID)
            }
        }
        await tinRenderSession.retryPendingReleases()
        for sessionID in source.sessionIDs where !tinRenderSession.hasPendingSessionRelease(sessionID) {
            tinOwnerSessionIDs.remove(sessionID)
        }
    }

}
