import Foundation
import Testing
@testable import HECRAS2025

struct BackgroundMapTileJsonSessionTests {
    @Test @MainActor
    func viewportChangeRejectsTileJSONBeforeClipboardWrite() async throws {
        let provider = ControlledBackgroundMapTileJsonProvider()
        let session = BackgroundMapSession(renderRequest: { request in
            BackgroundMapRenderResult(requestID: request.requestID, mapID: request.mapID,
                projectSessionID: request.projectSessionID, viewport: request.viewport,
                rasters: [], features: [], labels: [], sources: [], osmBackgroundColor: nil)
        }, tileJSONRequest: { request in
            try await provider.load(request)
        })
        var settings = session.settings
        settings.areBackgroundMapsOn = true
        settings.isOpenStreetMapOn = true
        session.settings = settings
        let mapID = UUID()
        let projectSessionID = UUID()
        let firstViewport = BackgroundMapViewport(minX: 0, minY: 0, maxX: 100, maxY: 80,
            pixelWidth: 400, pixelHeight: 320)
        session.updateViewport(mapID: mapID, projectSessionID: projectSessionID,
            projectionType: "Projected", projectionValue: "EPSG:26910",
            viewport: firstViewport, worldUnitsPerPixel: 0.25)
        #expect(session.canCopyHoveredTileJSON)
        #expect(session.matchesContext(mapID: mapID, projectSessionID: projectSessionID,
            projectionType: "Projected", projectionValue: "EPSG:26910",
            viewport: firstViewport, worldUnitsPerPixel: 0.25, settings: settings))
        #expect(!session.matchesContext(mapID: mapID, projectSessionID: projectSessionID,
            projectionType: "Projected", projectionValue: "EPSG:26910",
            viewport: firstViewport, worldUnitsPerPixel: 0.5, settings: settings))

        var copiedJSON: String?
        let copyTask = Task {
            try await session.copyHoveredTileJSON(at: BackgroundMapCoordinate(x: 20, y: 30)) {
                copiedJSON = $0
            }
        }
        try await waitFor(provider, requests: 1)
        let oldRequestID = try #require(provider.requestIDs.first)

        session.updateViewport(mapID: mapID, projectSessionID: projectSessionID,
            projectionType: "Projected", projectionValue: "EPSG:26910",
            viewport: BackgroundMapViewport(minX: 1, minY: 1, maxX: 101, maxY: 81,
                pixelWidth: 400, pixelHeight: 320), worldUnitsPerPixel: 0.25)
        #expect(!session.matchesContext(mapID: mapID, projectSessionID: projectSessionID,
            projectionType: "Projected", projectionValue: "EPSG:26910",
            viewport: firstViewport, worldUnitsPerPixel: 0.25, settings: settings))
        provider.complete(oldRequestID)

        var wasCancelled = false
        do {
            _ = try await copyTask.value
        } catch is CancellationError {
            wasCancelled = true
        }
        #expect(wasCancelled)
        #expect(copiedJSON == nil)
    }

    @Test @MainActor
    func sourceSettingsChangeRejectsTileJSONBeforeClipboardWrite() async throws {
        let provider = ControlledBackgroundMapTileJsonProvider()
        let session = BackgroundMapSession(renderRequest: { request in
            BackgroundMapRenderResult(requestID: request.requestID, mapID: request.mapID,
                projectSessionID: request.projectSessionID, viewport: request.viewport,
                rasters: [], features: [], labels: [], sources: [], osmBackgroundColor: nil)
        }, tileJSONRequest: { request in
            try await provider.load(request)
        })
        var settings = session.settings
        settings.areBackgroundMapsOn = true
        settings.isOpenStreetMapOn = true
        session.settings = settings
        let mapID = UUID()
        let projectSessionID = UUID()
        let viewport = BackgroundMapViewport(minX: 0, minY: 0, maxX: 100, maxY: 80,
            pixelWidth: 400, pixelHeight: 320)
        session.updateViewport(mapID: mapID, projectSessionID: projectSessionID,
            projectionType: "Projected", projectionValue: "EPSG:26910",
            viewport: viewport, worldUnitsPerPixel: 0.25)

        var copiedJSON: String?
        let copyTask = Task {
            try await session.copyHoveredTileJSON(at: BackgroundMapCoordinate(x: 20, y: 30)) {
                copiedJSON = $0
            }
        }
        try await waitFor(provider, requests: 1)
        let oldRequestID = try #require(provider.requestIDs.first)

        var changedSettings = session.settings
        changedSettings.density += 1
        session.settings = changedSettings
        provider.complete(oldRequestID)

        var wasCancelled = false
        do {
            _ = try await copyTask.value
        } catch is CancellationError {
            wasCancelled = true
        }
        #expect(wasCancelled)
        #expect(copiedJSON == nil)
    }

    @MainActor
    private func waitFor(_ provider: ControlledBackgroundMapTileJsonProvider, requests: Int) async throws {
        for _ in 0..<300 where provider.requestIDs.count < requests {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(provider.requestIDs.count == requests)
    }
}

@MainActor
private final class ControlledBackgroundMapTileJsonProvider {
    private var pending: [(BackgroundMapTileJsonRequest,
                           CheckedContinuation<BackgroundMapTileJsonResult, any Error>)] = []
    var requestIDs: [String] { pending.map { $0.0.capture.requestID } }

    func load(_ request: BackgroundMapTileJsonRequest) async throws -> BackgroundMapTileJsonResult {
        try await withCheckedThrowingContinuation { continuation in
            pending.append((request, continuation))
        }
    }

    func complete(_ requestID: String) {
        guard let index = pending.firstIndex(where: { $0.0.capture.requestID == requestID }) else {
            fatalError("No pending tile JSON request with identity \(requestID)")
        }
        let (request, continuation) = pending.remove(at: index)
        continuation.resume(returning: BackgroundMapTileJsonResult(
            capture: request.capture, clickedWorldPoint: request.clickedWorldPoint,
            sourceID: "osm", status: "available", message: nil,
            tile: BackgroundMapTileAddress(zoom: 5, column: 9, tmsRow: 17),
            sourceRevision: String(repeating: "A", count: 64), rawJson: "{\"layers\":[]}"))
    }
}
