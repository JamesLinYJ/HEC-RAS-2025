import Foundation
import Testing
@testable import HECRAS2025

@MainActor
struct StreamModeTinRenderSessionTests {
    @Test
    func newerProfileRenderSupersedesLateResponseFromPreviousProfile() async {
        let sessionID = UUID()
        let assets = [asset(sessionID: sessionID, sequence: 2), asset(sessionID: sessionID, sequence: 5)]
        let provider = StreamModeTinProviderFake()
        let session = StreamModeTinRenderSession(provider: provider)
        session.select(assets: assets, selectedProfileIndex: 0, operationID: sessionID)
        await waitUntil { session.state == .ready }

        let viewport = StreamModeTinViewport(minX: 0, minY: 0, maxX: 10, maxY: 10,
            pixelWidth: 1, pixelHeight: 1)
        let firstRender = Task { await session.render(viewport: viewport) }
        await waitUntil { provider.requests.count == 1 }

        session.select(assets: assets, selectedProfileIndex: 1, operationID: sessionID)
        let secondRender = Task { await session.render(viewport: viewport) }
        await waitUntil { provider.requests.count == 2 }

        let firstRequest = provider.requests[0]
        let secondRequest = provider.requests[1]
        provider.complete(firstRequest, result: renderResult(for: firstRequest, selectedIndex: 0))
        await firstRender.value
        #expect(session.render == nil)
        #expect(session.state == .rendering)

        provider.complete(secondRequest, result: renderResult(for: secondRequest, selectedIndex: 1))
        await secondRender.value
        #expect(session.state == .ready)
        #expect(session.render?.selectedProfileIndex == 1)
        #expect(session.render?.requestID == secondRequest.requestID)
        #expect(session.rasterImage.map { $0.alphaInfo == .last } == true)
    }

    @Test
    func cancelledCurrentRenderReturnsToReadyForTheNextViewport() async {
        let sessionID = UUID()
        let assets = [asset(sessionID: sessionID, sequence: 0)]
        let provider = StreamModeTinProviderFake()
        let session = StreamModeTinRenderSession(provider: provider)
        session.select(assets: assets, selectedProfileIndex: 0, operationID: sessionID)
        await waitUntil { session.state == .ready }

        let viewport = StreamModeTinViewport(minX: 0, minY: 0, maxX: 10, maxY: 10,
            pixelWidth: 1, pixelHeight: 1)
        let render = Task { await session.render(viewport: viewport) }
        await waitUntil { provider.requests.count == 1 }
        let request = provider.requests[0]
        render.cancel()
        provider.complete(request, result: renderResult(for: request, selectedIndex: 0))
        await render.value

        #expect(session.state == .ready)
        #expect(session.render == nil)
    }

    @Test
    func failedAssetReleaseRemainsOwnedUntilTheExactReferenceCanBeReleased() async {
        let sessionID = UUID()
        let reference = asset(sessionID: sessionID, sequence: 4)
        let provider = StreamModeTinProviderFake(releaseFailuresRemaining: 1)
        let session = StreamModeTinRenderSession(provider: provider)

        await session.release([reference])
        #expect(session.pendingCleanupCount == 1)
        #expect(provider.releasedAssetIDs.isEmpty)

        await session.retryPendingReleases()
        #expect(session.pendingCleanupCount == 0)
        #expect(provider.releasedAssetIDs == [reference.assetID])
    }

    @Test
    func failedSessionReleaseRetainsTheExactOwnerForRetry() async {
        let sessionID = UUID()
        let provider = StreamModeTinProviderFake(sessionReleaseFailuresRemaining: 1)
        let session = StreamModeTinRenderSession(provider: provider)

        let firstRelease = await session.releaseSession(sessionID)
        #expect(!firstRelease)
        #expect(session.pendingCleanupCount == 1)
        #expect(provider.sessionReleaseRequests == [sessionID])
        #expect(provider.releasedSessionIDs.isEmpty)

        await session.retryPendingReleases()
        #expect(session.pendingCleanupCount == 0)
        #expect(provider.sessionReleaseRequests == [sessionID, sessionID])
        #expect(provider.releasedSessionIDs == [sessionID])
    }

    private func asset(sessionID: UUID, sequence: Int64) -> StreamModeTinAssetReference {
        StreamModeTinAssetReference(sessionID: sessionID, sequence: sequence,
            assetID: UUID(), sha256: String(repeating: "a", count: 64))
    }

    private func renderResult(for request: StreamModeTinRenderRequest,
                              selectedIndex: Int) -> StreamModeTinRenderResult {
        StreamModeTinRenderResult(assets: request.assets, selectedProfileIndex: selectedIndex,
            requestID: request.requestID, width: 1, height: 1,
            minX: request.viewport.minX, minY: request.viewport.minY,
            maxX: request.viewport.maxX, maxY: request.viewport.maxY,
            rgbaBase64: Data([0, 0, 0, 0]).base64EncodedString(), labels: [])
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<100 where !condition() {
            await Task.yield()
        }
        #expect(condition())
    }
}

@MainActor
private final class StreamModeTinProviderFake: StreamModeTinProviding {
    private(set) var requests: [StreamModeTinRenderRequest] = []
    private(set) var releasedAssetIDs: [UUID] = []
    private(set) var releasedSessionIDs: [UUID] = []
    private(set) var sessionReleaseRequests: [UUID] = []
    private var pending: [UUID: CheckedContinuation<StreamModeTinRenderResult, Error>] = [:]
    private var releaseFailuresRemaining: Int
    private var sessionReleaseFailuresRemaining: Int

    init(releaseFailuresRemaining: Int = 0, sessionReleaseFailuresRemaining: Int = 0) {
        self.releaseFailuresRemaining = releaseFailuresRemaining
        self.sessionReleaseFailuresRemaining = sessionReleaseFailuresRemaining
    }

    func loadTinOptions(assets: [StreamModeTinAssetReference],
                        selectedProfileIndex: Int) async throws -> StreamModeTinOptionsResult {
        StreamModeTinOptionsResult(assets: assets, selectedProfileIndex: selectedProfileIndex, options: [])
    }

    func renderTin(request: StreamModeTinRenderRequest) async throws -> StreamModeTinRenderResult {
        requests.append(request)
        return try await withCheckedThrowingContinuation { continuation in
            pending[request.requestID] = continuation
        }
    }

    func releaseTinAsset(_ asset: StreamModeTinAssetReference) async throws {
        if releaseFailuresRemaining > 0 {
            releaseFailuresRemaining -= 1
            throw FakeProviderError.releaseUnavailable
        }
        releasedAssetIDs.append(asset.assetID)
    }

    func releaseTinSession(_ sessionID: UUID) async throws {
        sessionReleaseRequests.append(sessionID)
        if sessionReleaseFailuresRemaining > 0 {
            sessionReleaseFailuresRemaining -= 1
            throw FakeProviderError.releaseUnavailable
        }
        releasedSessionIDs.append(sessionID)
    }

    func complete(_ request: StreamModeTinRenderRequest, result: StreamModeTinRenderResult) {
        pending.removeValue(forKey: request.requestID)?.resume(returning: result)
    }
}

private enum FakeProviderError: Error {
    case releaseUnavailable
}
