import CryptoKit
import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

@MainActor
private final class SharedResultLoadProvider: MapResultChartProvider {
    private(set) var requests = 0
    private(set) var cancelledRequests = 0
    private var reply: MapResultChartSources?
    private var pending: [CheckedContinuation<MapResultChartSources, any Error>] = []

    func loadSources(map: MapResultChartMapRequest,
                     selectionOverrides: [MapResultSelectionOverride]) async throws -> MapResultChartSources {
        requests += 1
        let result: MapResultChartSources
        if let reply { result = reply }
        else { result = try await withCheckedThrowingContinuation { pending.append($0) } }
        if Task.isCancelled { cancelledRequests += 1; throw CancellationError() }
        return result
    }

    func release(_ sources: MapResultChartSources) {
        reply = sources
        let waiters = pending
        pending.removeAll()
        for waiter in waiters { waiter.resume(returning: sources) }
    }

    func selectSources(map: MapResultChartMapRequest, expectedContextToken: String,
                       currentSelectionOverrides: [MapResultSelectionOverride],
                       selectionOverrides: [MapResultSelectionOverride]) async throws -> MapResultChartSources {
        throw SharedResultLoadError.unexpectedSelection
    }

    func compute(_ request: MapResultChartSampleLineRequest,
                 progress: @escaping @Sendable (BackendProgressUpdate) -> Void) async throws -> MapResultChartSeries {
        throw SharedResultLoadError.unexpectedComputation
    }
}

private enum SharedResultLoadError: Error {
    case unexpectedSelection, unexpectedComputation, timedOut
}

struct MapResultLoadLifecycleTests {
    @Test @MainActor
    func concurrentResultSourceCallersShareTheLoadAndBothReturnWithTheAcceptedSnapshot() async throws {
        let provider = SharedResultLoadProvider()
        let session = MapResultSourcesSession(provider: provider)
        let map = makeMap()
        session.configure(map: map, identity: "same-map-workflow", selectionOverrides: [], isCurrent: { true })
        let first = Task { @MainActor in
            await session.loadSources()
            return session.snapshot
        }
        try await waitUntil { provider.requests == 1 }
        var secondStarted = false
        let second = Task { @MainActor in
            secondStarted = true
            await session.loadSources()
            return session.snapshot
        }
        try await waitUntil { secondStarted }
        // Future requests also receive this reply, so a broken duplicate-load
        // implementation fails its count assertion rather than leaking a waiter.
        provider.release(makeSources(map))
        let firstSnapshot = await first.value
        let secondSnapshot = await second.value
        #expect(provider.requests == 1)
        #expect(provider.cancelledRequests == 0)
        #expect(firstSnapshot?.sources.contextToken == "accepted-source-context")
        #expect(secondSnapshot?.sources.contextToken == "accepted-source-context")
        #expect(!session.isLoading && !session.isStale && session.errorMessage == nil)
    }

    @Test @MainActor
    func cancellingOneResultSourceWaiterDoesNotCancelTheLoadNeededByAnotherCaller() async throws {
        let provider = SharedResultLoadProvider()
        let session = MapResultSourcesSession(provider: provider)
        let map = makeMap()
        session.configure(map: map, identity: "same-map-workflow", selectionOverrides: [], isCurrent: { true })
        var departingViewReturned = false
        let departingView = Task { @MainActor in
            let accepted = await session.loadSources()
            departingViewReturned = true
            return accepted
        }
        try await waitUntil { provider.requests == 1 }
        var retainedCallerStarted = false
        let retainedCaller = Task { @MainActor in
            retainedCallerStarted = true
            await session.loadSources()
            return session.snapshot
        }
        try await waitUntil { retainedCallerStarted }
        departingView.cancel()
        try await waitUntil { departingViewReturned }
        #expect(session.isLoading && session.snapshot == nil)
        #expect(provider.cancelledRequests == 0)
        provider.release(makeSources(map))
        _ = await departingView.value
        let snapshot = await retainedCaller.value
        #expect(provider.requests == 1)
        #expect(provider.cancelledRequests == 0,
            "Cancelling one SwiftUI task cannot cancel another caller's current source load.")
        #expect(snapshot?.sources.contextToken == "accepted-source-context")
        #expect(!session.isLoading && !session.isStale && session.errorMessage == nil)
    }

    @Test @MainActor
    func refreshingLatestSourcesPublishesANewContextWithoutInventingSelectionOverrides() async {
        let provider = SharedResultLoadProvider()
        let session = MapResultSourcesSession(provider: provider)
        let map = makeMap()
        var acceptedContextUpdates = 0
        var selectionUpdates = 0
        session.configure(map: map, identity: "same-map-workflow", selectionOverrides: [],
            isCurrent: { true }, selectionOverridesDidChange: { _ in selectionUpdates += 1 },
            sourcesDidChange: { acceptedContextUpdates += 1 })
        provider.release(makeSources(map))
        #expect(await session.loadSources())
        #expect(acceptedContextUpdates == 1)
        provider.release(makeSources(map, contextToken: "new-latest-source-context"))
        #expect(await session.loadSources(force: true))
        #expect(session.snapshot?.sources.contextToken == "new-latest-source-context")
        #expect(acceptedContextUpdates == 2,
            "The map must rebuild embedded Geometry and Boundary for a newly accepted source context.")
        #expect(session.selectionOverrides.isEmpty && selectionUpdates == 0)
        #expect(await session.loadSources(force: true))
        #expect(acceptedContextUpdates == 2, "Refreshing the same context must not trigger a setup loop.")
        #expect(provider.requests == 3)
    }

    private func makeMap() -> MapResultChartMapRequest {
        let xml = "<Project />"
        let digest = SHA256.hash(data: Data(xml.utf8)).map { String(format: "%02X", $0) }.joined()
        return .init(projectPath: "/private/tmp/result-load-lifecycle/Project.ras", projectXml: xml,
            projectXmlSHA: digest, mapID: "8CF96BA3-17EB-4A9E-88A6-F58AF3138F91", mapIndex: 0,
            mapName: "Source loading", mapType: "Plan",
            expectedVisualizationRevision: String(repeating: "A", count: 64))
    }

    private func makeSources(_ map: MapResultChartMapRequest,
                             contextToken: String = "accepted-source-context") -> MapResultChartSources {
        .init(projectPath: map.projectPath, projectRevision: String(repeating: "B", count: 64),
            mapID: map.mapID, mapIndex: map.mapIndex, mapName: map.mapName, mapType: map.mapType,
            projectXmlSHA: map.projectXmlSHA, visualizationRevision: map.expectedVisualizationRevision,
            contextToken: contextToken, activeNodes: [])
    }

    @MainActor
    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !condition() {
            guard ContinuousClock.now < deadline else { throw SharedResultLoadError.timedOut }
            await Task.yield()
        }
    }
}
