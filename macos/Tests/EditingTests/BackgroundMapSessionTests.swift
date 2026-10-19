import Foundation
import Testing
@testable import HECRAS2025

struct BackgroundMapSessionTests {
    @Test @MainActor
    func cancelledFirstRenderRestartsForSameViewportAndCannotReplaceTheNewSnapshot() async throws {
        let provider = ControlledBackgroundMapRenderProvider()
        let session = BackgroundMapSession(renderRequest: { request in
            try await provider.render(request)
        })
        var settings = session.settings
        settings.areBackgroundMapsOn = true
        session.settings = settings

        let mapID = UUID()
        let projectSessionID = UUID()
        let viewport = BackgroundMapViewport(minX: 0, minY: 0, maxX: 100, maxY: 80,
            pixelWidth: 400, pixelHeight: 320)
        session.updateViewport(mapID: mapID, projectSessionID: projectSessionID,
            projectionType: "Projected", projectionValue: "EPSG:26910",
            viewport: viewport, worldUnitsPerPixel: 0.25)
        try await waitFor(provider, requests: 1)
        let oldRequestID = try #require(provider.requestIDs.first)

        session.cancelRendering()
        session.updateViewport(mapID: mapID, projectSessionID: projectSessionID,
            projectionType: "Projected", projectionValue: "EPSG:26910",
            viewport: viewport, worldUnitsPerPixel: 0.25)
        try await waitFor(provider, requests: 2)
        let newRequestID = try #require(provider.requestIDs.last)
        #expect(oldRequestID != newRequestID)

        provider.complete(oldRequestID)
        try await Task.sleep(for: .milliseconds(20))
        #expect(session.snapshot.map(\.generation) == nil)
        #expect(session.isLoading)

        provider.complete(newRequestID)
        for _ in 0..<100 where session.snapshot.map(\.generation) == nil { await Task.yield() }
        let snapshot = try #require(session.snapshot)
        #expect(snapshot.render.requestID == newRequestID)
        #expect(snapshot.render.mapID == mapID.uuidString)
        #expect(!session.isLoading)
    }

    @MainActor
    private func waitFor(_ provider: ControlledBackgroundMapRenderProvider, requests: Int) async throws {
        for _ in 0..<300 where provider.requestIDs.count < requests {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(provider.requestIDs.count == requests)
    }
}

@MainActor
private final class ControlledBackgroundMapRenderProvider {
    private var pending: [(BackgroundMapRenderRequest, CheckedContinuation<BackgroundMapRenderResult, any Error>)] = []
    var requestIDs: [String] { pending.map { $0.0.requestID } }

    func render(_ request: BackgroundMapRenderRequest) async throws -> BackgroundMapRenderResult {
        try await withCheckedThrowingContinuation { continuation in
            pending.append((request, continuation))
        }
    }

    func complete(_ requestID: String) {
        guard let index = pending.firstIndex(where: { $0.0.requestID == requestID }) else {
            fatalError("No pending background render request with identity \(requestID)")
        }
        let (request, continuation) = pending.remove(at: index)
        continuation.resume(returning: BackgroundMapRenderResult(requestID: request.requestID,
            mapID: request.mapID, projectSessionID: request.projectSessionID,
            viewport: request.viewport, rasters: [], features: [], labels: [], sources: [],
            osmBackgroundColor: nil))
    }
}
