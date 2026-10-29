import Combine
import CoreGraphics
import Foundation

enum StreamModeTinRenderState: Equatable {
    case idle
    case loadingOptions
    case ready
    case rendering
    case failed(String)
}

struct StreamModeTinRenderTaskKey: Hashable {
    let assets: [StreamModeTinAssetReference]
    let selectedProfileIndex: Int
    let viewport: StreamModeTinViewport
    let optionsRevision: Int
}

@MainActor
final class StreamModeTinRenderSession: ObservableObject {
    @Published private(set) var state: StreamModeTinRenderState = .idle
    @Published private(set) var assets: [StreamModeTinAssetReference] = []
    @Published private(set) var selectedProfileIndex = 0
    @Published private(set) var options: [StreamModeTinOptionDescriptor] = []
    @Published private(set) var render: StreamModeTinRenderResult?
    @Published private(set) var rasterImage: CGImage?
    @Published private(set) var optionsRevision = 0
    @Published private(set) var pendingCleanupCount = 0

    private let provider: any StreamModeTinProviding
    private var operationID: UUID?
    private var optionsTask: Task<Void, Never>?
    private var latestRenderRequestID: UUID?
    private var pendingAssetReleases = Set<StreamModeTinAssetReference>()
    private var pendingSessionReleases: Set<UUID> = []
    private var releasingSessionIDs: Set<UUID> = []
    private var sessionReleaseWaiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]
    private var activeSourceRequestCount = 0
    private var sourceRequestWaiters: [CheckedContinuation<Void, Never>] = []

    init(provider: any StreamModeTinProviding) {
        self.provider = provider
    }

    var asset: StreamModeTinAssetReference? {
        assets.indices.contains(selectedProfileIndex) ? assets[selectedProfileIndex] : nil
    }

    func hasPendingSessionRelease(_ sessionID: UUID) -> Bool {
        pendingSessionReleases.contains(sessionID)
    }

    func select(assets nextAssets: [StreamModeTinAssetReference],
                selectedProfileIndex nextProfileIndex: Int, operationID nextOperationID: UUID?) {
        guard let nextOperationID, !nextAssets.isEmpty, nextAssets.count <= 512,
              nextAssets.indices.contains(nextProfileIndex),
              nextAssets.allSatisfy({
                  $0.sessionID == nextOperationID && $0.sequence >= 0 &&
                      $0.assetID.uuidString != "00000000-0000-0000-0000-000000000000" &&
                      $0.sha256.count == 64 && $0.sha256.allSatisfy(\.isHexDigit)
              }),
              zip(nextAssets, nextAssets.dropFirst()).allSatisfy({ $0.0.sequence < $0.1.sequence }),
              Set(nextAssets.map(\.assetID)).count == nextAssets.count else {
            clear()
            return
        }
        let sourceChanged = operationID != nextOperationID
        let groupChanged = assets != nextAssets
        let profileChanged = selectedProfileIndex != nextProfileIndex
        guard sourceChanged || groupChanged || profileChanged else { return }

        operationID = nextOperationID
        assets = nextAssets
        selectedProfileIndex = nextProfileIndex
        render = nil
        rasterImage = nil
        latestRenderRequestID = nil
        optionsRevision &+= 1
        if case .failed = state { state = .ready }
        if sourceChanged || options.isEmpty || (groupChanged && state == .loadingOptions) {
            loadOptions(for: nextAssets, selectedProfileIndex: nextProfileIndex,
                operationID: nextOperationID)
        }
    }

    private func loadOptions(for sourceAssets: [StreamModeTinAssetReference],
                             selectedProfileIndex: Int, operationID: UUID) {
        optionsTask?.cancel()
        optionsTask = nil
        options = []
        state = .loadingOptions

        activeSourceRequestCount += 1
        optionsTask = Task { [weak self, provider] in
            defer { self?.finishSourceRequest() }
            do {
                try Task.checkCancellation()
                let response = try await provider.loadTinOptions(assets: sourceAssets,
                    selectedProfileIndex: selectedProfileIndex)
                try Task.checkCancellation()
                guard let self, self.assets == sourceAssets, self.operationID == operationID,
                      self.selectedProfileIndex == selectedProfileIndex else { return }
                guard response.assets == sourceAssets,
                      response.selectedProfileIndex == selectedProfileIndex,
                      Set(response.options.map(\.name)).count == response.options.count else {
                    self.state = .failed(L10n.text("TIN plot options returned an invalid profile response."))
                    self.optionsTask = nil
                    return
                }
                self.options = response.options
                self.optionsRevision &+= 1
                self.state = .ready
                self.optionsTask = nil
            } catch {
                guard let self, self.assets == sourceAssets, self.operationID == operationID,
                      !(error is CancellationError) else { return }
                self.state = .failed(error.localizedDescription)
                self.optionsTask = nil
            }
        }
    }

    func clear() {
        optionsTask?.cancel()
        optionsTask = nil
        assets = []
        selectedProfileIndex = 0
        operationID = nil
        options = []
        render = nil
        rasterImage = nil
        latestRenderRequestID = nil
        optionsRevision &+= 1
        state = .idle
    }

    func setBooleanOption(_ name: String, isOn: Bool) {
        guard let index = options.firstIndex(where: { $0.name == name && $0.valueKind == "boolean" }),
              options[index].isEnabled else { return }
        if isOn, name == "PaintZ", let otherIndex = options.firstIndex(where: { $0.name == "PaintM" }) {
            options[otherIndex].currentValue = "false"
        } else if isOn, name == "PaintM", let otherIndex = options.firstIndex(where: { $0.name == "PaintZ" }) {
            options[otherIndex].currentValue = "false"
        }
        options[index].currentValue = isOn ? "true" : "false"
        render = nil
        rasterImage = nil
        optionsRevision &+= 1
        if case .failed = state { state = .ready }
    }

    func setEnumOption(_ name: String, value: String) {
        guard let index = options.firstIndex(where: { $0.name == name && $0.valueKind == "enum" }),
              options[index].isEnabled, options[index].enumValues.contains(value) else { return }
        options[index].currentValue = value
        render = nil
        rasterImage = nil
        optionsRevision &+= 1
        if case .failed = state { state = .ready }
    }

    func render(viewport: StreamModeTinViewport) async {
        guard viewport.isValid, !assets.isEmpty, let operationID,
              assets.allSatisfy({ $0.sessionID == operationID }),
              state == .ready || state == .rendering else { return }

        let requestID = UUID()
        latestRenderRequestID = requestID
        render = nil
        rasterImage = nil
        state = .rendering
        let sourceAssets = assets
        let sourceProfileIndex = selectedProfileIndex
        let request = StreamModeTinRenderRequest(assets: sourceAssets,
            selectedProfileIndex: sourceProfileIndex, requestID: requestID,
            viewport: viewport, options: orderedAssignments())
        activeSourceRequestCount += 1
        defer { finishSourceRequest() }
        do {
            let response = try await provider.renderTin(request: request)
            try Task.checkCancellation()
            guard self.assets == sourceAssets, self.selectedProfileIndex == sourceProfileIndex,
                  self.operationID == operationID,
                  latestRenderRequestID == requestID else { return }
            guard response.assets == sourceAssets,
                  response.selectedProfileIndex == sourceProfileIndex,
                  response.requestID == requestID,
                  let image = response.makeImage() else {
                state = .failed(L10n.text("TIN rendering returned an invalid profile response."))
                return
            }
            render = response
            rasterImage = image
            state = .ready
        } catch {
            guard self.assets == sourceAssets, self.selectedProfileIndex == sourceProfileIndex,
                  self.operationID == operationID,
                  latestRenderRequestID == requestID else { return }
            if error is CancellationError {
                state = .ready
                return
            }
            state = .failed(error.localizedDescription)
        }
    }

    func release(_ references: [StreamModeTinAssetReference]) async {
        for reference in references {
            pendingAssetReleases.insert(reference)
        }
        await retryPendingReleases()
    }

    @discardableResult
    func releaseSession(_ sessionID: UUID) async -> Bool {
        guard sessionID.uuidString != "00000000-0000-0000-0000-000000000000" else { return true }
        await waitForSourceRequests()
        pendingSessionReleases.insert(sessionID)
        await releaseSessionOwner(sessionID)
        await retryPendingAssetReleases()
        updatePendingCleanupCount()
        return !pendingSessionReleases.contains(sessionID)
    }

    func retryPendingReleases() async {
        for sessionID in pendingSessionReleases.sorted(by: { $0.uuidString < $1.uuidString }) {
            await releaseSessionOwner(sessionID)
        }
        await retryPendingAssetReleases()
        updatePendingCleanupCount()
    }

    private func releaseSessionOwner(_ sessionID: UUID) async {
        guard releasingSessionIDs.insert(sessionID).inserted else {
            await withCheckedContinuation { continuation in
                sessionReleaseWaiters[sessionID, default: []].append(continuation)
            }
            return
        }
        do {
            try await provider.releaseTinSession(sessionID)
            pendingSessionReleases.remove(sessionID)
            pendingAssetReleases = Set(pendingAssetReleases.filter { $0.sessionID != sessionID })
        } catch {
            // Retain the exact session ID so the same server-derived owner can be retried.
        }
        releasingSessionIDs.remove(sessionID)
        let waiters = sessionReleaseWaiters.removeValue(forKey: sessionID) ?? []
        for waiter in waiters { waiter.resume() }
    }

    private func finishSourceRequest() {
        activeSourceRequestCount = max(0, activeSourceRequestCount - 1)
        guard activeSourceRequestCount == 0 else { return }
        let waiters = sourceRequestWaiters
        sourceRequestWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private func waitForSourceRequests() async {
        guard activeSourceRequestCount > 0 else { return }
        await withCheckedContinuation { continuation in
            sourceRequestWaiters.append(continuation)
        }
    }

    private func retryPendingAssetReleases() async {
        for reference in Array(pendingAssetReleases) {
            do {
                try await provider.releaseTinAsset(reference)
                pendingAssetReleases.remove(reference)
            } catch {
                // Retain the exact owner and digest so a later retry can
                // revalidate the payload before releasing it.
            }
        }
    }

    private func updatePendingCleanupCount() {
        pendingCleanupCount = pendingSessionReleases.count + pendingAssetReleases.count
    }

    private func orderedAssignments() -> [StreamModeTinOptionAssignment] {
        var assignments: [StreamModeTinOptionAssignment] = []
        let byName = Dictionary(uniqueKeysWithValues: options.map { ($0.name, $0.currentValue) })
        if options.contains(where: { $0.name == "PaintZ" && $0.isEnabled }),
           options.contains(where: { $0.name == "PaintM" && $0.isEnabled }) {
            let paintZ = byName["PaintZ"] == "true"
            let paintM = byName["PaintM"] == "true"
            if paintZ {
                assignments.append(StreamModeTinOptionAssignment(name: "PaintM", value: "false"))
                assignments.append(StreamModeTinOptionAssignment(name: "PaintZ", value: "true"))
            } else if paintM {
                assignments.append(StreamModeTinOptionAssignment(name: "PaintZ", value: "false"))
                assignments.append(StreamModeTinOptionAssignment(name: "PaintM", value: "true"))
            } else {
                assignments.append(StreamModeTinOptionAssignment(name: "PaintZ", value: "false"))
                assignments.append(StreamModeTinOptionAssignment(name: "PaintM", value: "false"))
            }
        }
        for option in options where option.isEnabled && option.name != "PaintZ" && option.name != "PaintM" {
            assignments.append(StreamModeTinOptionAssignment(name: option.name, value: option.currentValue))
        }
        return assignments
    }
}
