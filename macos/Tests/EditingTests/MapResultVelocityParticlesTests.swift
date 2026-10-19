import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

@MainActor
private final class DeferredVelocityFieldSamples {
    private(set) var requestIDs: [String] = []
    private var continuations: [String: CheckedContinuation<MapResultVelocityGrid, any Error>] = [:]

    func sample(requestID: String, profileIndex: Int,
                viewport: RasterMapViewExtent) async throws -> MapResultVelocityGrid {
        requestIDs.append(requestID)
        return try await withCheckedThrowingContinuation { continuation in
            continuations[requestID] = continuation
        }
    }

    func resume(_ requestID: String, with grid: MapResultVelocityGrid) {
        continuations.removeValue(forKey: requestID)?.resume(returning: grid)
    }
}

@Suite(.serialized)
struct MapResultVelocityParticlesTests {
    @Test @MainActor
    func particlesAdvanceFromSampledVelocityAndRespectDistanceMode() async throws {
        let session = MapResultVelocityParticleSession(random: InteriorParticleRandomNumberGenerator())
        session.settings.maxParticles = 1
        session.settings.velocityMode = .perDistance
        session.settings.velocityScalar = 25
        session.setEnabled(true)

        let identity = targetIdentity(revision: String(repeating: "a", count: 64),
            profileIndex: 2, cellSize: 2)
        let viewport = identity.viewport
        let resultRevision = try #require(identity.resultRevision)
        session.setTarget(MapResultVelocityParticleTarget(identity: identity, sample: { _, _, _, _ in
            grid(cellSize: 2, resultRevision: resultRevision, profileIndex: 2)
        }))
        try await waitUntil { session.grid != nil }

        let frame = session.advance(at: Date())
        let trace = try #require(frame.first)
        let sampledGrid = try #require(session.grid)
        let worldDeltaX = trace.position.x - trace.lastPosition.x
        let worldDeltaY = trace.position.y - trace.lastPosition.y
        let rasterDeltaX = worldDeltaX / sampledGrid.cellSize
        let rasterDeltaY = -worldDeltaY / sampledGrid.cellSize
        #expect(trace.position.x > trace.lastPosition.x)
        #expect(trace.position.y > trace.lastPosition.y)
        #expect(abs(worldDeltaX - 25.0 / 60.0) < 1e-9)
        #expect(abs(worldDeltaY - 25.0 / 60.0) < 1e-9)
        #expect(abs(rasterDeltaX - 25.0 / 120.0) < 1e-9)
        #expect(abs(rasterDeltaY + 25.0 / 120.0) < 1e-9)
        #expect(session.grid?.width == viewport.pixelWidth)
    }

    @Test @MainActor
    func supersededViewportOrResultSampleCannotInstallItsOldField() async throws {
        let samples = DeferredVelocityFieldSamples()
        let session = MapResultVelocityParticleSession()
        session.settings.maxParticles = 1
        session.setEnabled(true)

        let firstIdentity = targetIdentity(revision: String(repeating: "a", count: 64), profileIndex: 0)
        let secondIdentity = targetIdentity(revision: String(repeating: "b", count: 64), profileIndex: 1)
        let firstRevision = try #require(firstIdentity.resultRevision)
        let secondRevision = try #require(secondIdentity.resultRevision)
        session.setTarget(MapResultVelocityParticleTarget(identity: firstIdentity, sample: { id, index, _, extent in
            try await samples.sample(requestID: id, profileIndex: index, viewport: extent)
        }))
        try await waitUntil { samples.requestIDs.count == 1 }
        let oldRequest = try #require(samples.requestIDs.first)

        session.setTarget(MapResultVelocityParticleTarget(identity: secondIdentity, sample: { id, index, _, extent in
            try await samples.sample(requestID: id, profileIndex: index, viewport: extent)
        }))
        try await waitUntil { samples.requestIDs.count == 2 }
        let currentRequest = try #require(samples.requestIDs.last)
        #expect(session.grid == nil)

        samples.resume(oldRequest, with: grid(cellSize: 1,
            resultRevision: firstRevision, profileIndex: 0))
        await Task.yield()
        #expect(session.grid == nil, "A late reply from the previous Result source must not become visible.")

        samples.resume(currentRequest, with: grid(cellSize: 1,
            resultRevision: secondRevision, profileIndex: 1))
        try await waitUntil { session.grid?.revision == secondIdentity.resultRevision }
        #expect(session.grid?.profileIndex == 1)

        session.setEnabled(false)
        #expect(session.grid == nil, "Disabling particles cancels their active field and clears its visible traces.")
    }

    @Test @MainActor
    func veryLargeFiniteScalarKillsOutOfGridParticlesBeforeNextIntegerConversion() async throws {
        let session = MapResultVelocityParticleSession()
        session.settings.maxParticles = 1
        session.settings.velocityMode = .perPixel
        session.setVelocityScalar(1e25)
        session.setEnabled(true)

        let identity = targetIdentity(revision: String(repeating: "a", count: 64), profileIndex: 0)
        let resultRevision = try #require(identity.resultRevision)
        session.setTarget(MapResultVelocityParticleTarget(identity: identity, sample: { _, _, _, _ in
            grid(cellSize: 1, resultRevision: resultRevision, profileIndex: 0)
        }))
        try await waitUntil { session.grid != nil }

        let first = Date()
        #expect(session.advance(at: first).isEmpty)
        #expect(session.advance(at: first.addingTimeInterval(1.0 / 30.0)).isEmpty)
        #expect(session.grid != nil)
        #expect(session.settings.velocityScalar == 1e25,
            "Every finite positive scalar remains accepted; out-of-grid motion retires the particle safely.")
    }

    @Test @MainActor
    func responseRejectsBoundsThatDoNotMatchSquareCellNormalizedViewport() throws {
        let mapID = UUID(uuidString: "CA5DB39A-1D3C-4804-A1FA-5F85FD7AC9A1")!
        let node = CatalogTreeNodeLocator(rootName: "Results", nodeType: "Result",
            nodeName: "Result", nodePath: [0], assetID: "/tmp/result.hdf", mapType: "Velocity")
        let viewport = RasterMapViewExtent(minX: 5, minY: 7, maxX: 6, maxY: 8,
            pixelWidth: 31, pixelHeight: 32)
        let cellSize = max(1.0 / Double(viewport.pixelWidth), 1.0 / Double(viewport.pixelHeight))
        let expected = MapResultVelocityFieldExpectation(requestID: "request",
            contextToken: "context", sourceID: "source", mapID: mapID.uuidString,
            node: node, resultPath: "/tmp/result.hdf", resultRevision: String(repeating: "a", count: 64),
            profileIndex: 0, profileName: "Profile 0", time: "2025-01-01T00:00:00",
            viewport: viewport)
        let response = MapResultVelocityFieldResponse(requestID: "request",
            contextToken: "context", sourceID: "source", sourceMapID: mapID.uuidString,
            node: node, resultPath: "/tmp/result.hdf", revision: expected.resultRevision,
            resultName: "Result", terrainPath: "/tmp/terrain.tif",
            terrainRevision: String(repeating: "b", count: 64), mapType: "Velocity",
            selectionIndex: 0, profileIndex: 0, profileName: "Profile 0", time: expected.time,
            width: viewport.pixelWidth, height: viewport.pixelHeight, cellSize: cellSize,
            minX: viewport.minX, minY: viewport.minY,
            maxX: viewport.maxX, maxY: viewport.maxY, noDataValue: -9999,
            interleavedVelocity: Data(repeating: 0,
                count: viewport.pixelWidth * viewport.pixelHeight * 3 * MemoryLayout<Float>.size))

        #expect(throws: BackendServiceError.self) { try response.makeGrid(expected: expected) }
    }

    @Test @MainActor
    func windProfileSelectionRetainsExactSourceAndSendsReturnedTimeOnResample() async throws {
        let source = windSource()
        let options = [
            MapVelocityParticleProfile(index: 0, time: "2026-10-16T00:00:00.0000000"),
            MapVelocityParticleProfile(index: 1, time: "2026-10-16T00:01:00.0000000"),
            MapVelocityParticleProfile(index: 2, time: "2026-10-16T00:02:00.0000000")
        ]
        let viewport = RasterMapViewExtent(minX: 10, minY: 20, maxX: 14, maxY: 24,
            pixelWidth: 4, pixelHeight: 4)
        let identity = MapResultVelocityParticleTargetIdentity(sourceKind: .wind,
            sourceGeneration: 7, projectSessionID: source.projectSessionID,
            mapID: UUID(uuidString: source.map.mapID)!, contextToken: source.contextToken,
            nodeID: source.selectionIdentity, node: source.windNode,
            resultPath: source.boundaryPath, resultRevision: source.boundaryRevision,
            profileIndex: 0, profileName: "", time: "", viewport: viewport)
        var requests: [(index: Int, time: String?)] = []
        let session = MapResultVelocityParticleSession()
        session.settings.maxParticles = 1
        session.setEnabled(true)
        session.setTarget(MapResultVelocityParticleTarget(identity: identity, sample: { _, index, time, _ in
            requests.append((index, time))
            let profile = try #require(options.first(where: { $0.index == index }))
            return MapResultVelocityGrid(width: 4, height: 4, cellSize: 1,
                minX: 10, minY: 20, maxX: 14, maxY: 24, noDataValue: -9999,
                velocityX: Array(repeating: 1, count: 16), velocityY: Array(repeating: 1, count: 16),
                magnitude: Array(repeating: 1.414, count: 16), resultPath: nil, revision: nil,
                terrainPath: nil, terrainRevision: nil, sourceID: source.selectionIdentity,
                profileIndex: index, profileName: profile.time, time: profile.time,
                sourceKind: .wind, spatialDataType: "Constant", profileOptions: options)
        }))
        try await waitUntil { session.grid?.profileIndex == 0 && session.profileOptions.count == 3 }

        let restored = try #require(session.selectedWindProfile(matching: source))
        #expect(restored.index == 0)
        #expect(restored.time == options[0].time)
        let changedRevision = MapWindVelocityParticleSource(projectSessionID: source.projectSessionID,
            mapWorkflowIdentity: source.mapWorkflowIdentity, map: source.map,
            contextToken: source.contextToken, selectionIdentity: source.selectionIdentity,
            boundaryNode: source.boundaryNode, windNode: source.windNode,
            boundaryPath: source.boundaryPath, boundaryRevision: String(repeating: "b", count: 64),
            profileIndex: 0, profileTime: nil)
        #expect(session.selectedWindProfile(matching: changedRevision)?.index == nil,
            "A profile from an older Boundary Condition revision must not carry forward.")

        session.selectWindProfile(2)
        try await waitUntil { session.grid?.profileIndex == 2 }
        #expect(requests.last?.index == 2)
        #expect(requests.last?.time == options[2].time,
            "The resample must bind the selected profile index to the exact time returned by the source profile list.")
        let selected = try #require(session.selectedWindProfile(matching: source))
        #expect(selected.index == 2)
        #expect(selected.time == options[2].time)
    }

    private func targetIdentity(revision: String, profileIndex: Int,
                                cellSize: Double = 1) -> MapResultVelocityParticleTargetIdentity {
        let mapID = UUID(uuidString: "CA5DB39A-1D3C-4804-A1FA-5F85FD7AC9A1")!
        let viewport = RasterMapViewExtent(minX: 10, minY: 20,
            maxX: 10 + 4 * cellSize, maxY: 20 + 4 * cellSize,
            pixelWidth: 4, pixelHeight: 4)
        return MapResultVelocityParticleTargetIdentity(sourceGeneration: 3,
            projectSessionID: UUID(uuidString: "1E29D408-4055-4B77-8B89-7A6E2413B8E0")!,
            mapID: mapID, contextToken: "context", nodeID: "result-node",
            node: CatalogTreeNodeLocator(rootName: "Results", nodeType: "Result",
                nodeName: "Result", nodePath: [0], assetID: "/tmp/result.hdf", mapType: "Velocity"),
            resultPath: "/tmp/result.hdf", resultRevision: revision,
            profileIndex: profileIndex, profileName: "Profile \(profileIndex)",
            time: "2025-01-01T00:00:00", viewport: viewport)
    }

    private func windSource() -> MapWindVelocityParticleSource {
        let projectSessionID = UUID(uuidString: "1E29D408-4055-4B77-8B89-7A6E2413B8E0")!
        let mapID = "CA5DB39A-1D3C-4804-A1FA-5F85FD7AC9A1"
        let boundaryPath = "/tmp/Wind Boundary.bci"
        let boundaryNode = CatalogTreeNodeLocator(rootName: "Boundary Conditions",
            nodeType: "BoundaryCondition", nodeName: "BC", nodePath: [1], assetID: boundaryPath)
        let windNode = CatalogTreeNodeLocator(rootName: "Boundary Conditions",
            nodeType: "WindLayer", nodeName: "Wind", nodePath: [1, 0], assetID: boundaryPath,
            parentBoundaryConditionAssetID: boundaryPath,
            parentBoundaryConditionNodePath: [1], parentBoundaryConditionNodeName: "BC")
        let map = MapWindVelocityMapRequest(projectPath: "/tmp/Wind Project.ras",
            projectXml: "<Project />", projectXmlSHA: String(repeating: "a", count: 64),
            mapID: mapID, mapIndex: 0, mapName: "Map", mapType: "Project",
            expectedVisualizationRevision: String(repeating: "c", count: 64),
            resultSelectionOverrides: [])
        return MapWindVelocityParticleSource(projectSessionID: projectSessionID,
            mapWorkflowIdentity: "wind-workflow", map: map, contextToken: "wind-context",
            selectionIdentity: windNode.sourceIdentity, boundaryNode: boundaryNode,
            windNode: windNode, boundaryPath: boundaryPath,
            boundaryRevision: String(repeating: "a", count: 64), profileIndex: 0, profileTime: nil)
    }

    private func grid(cellSize: Double, resultRevision: String,
                      profileIndex: Int) -> MapResultVelocityGrid {
        let width = 4, height = 4
        return MapResultVelocityGrid(width: width, height: height, cellSize: cellSize,
            minX: 10, minY: 20, maxX: 10 + Double(width) * cellSize,
            maxY: 20 + Double(height) * cellSize, noDataValue: -9999,
            velocityX: Array(repeating: 1, count: width * height),
            velocityY: Array(repeating: 1, count: width * height),
            magnitude: Array(repeating: 1.414, count: width * height),
            resultPath: "/tmp/result.hdf", revision: resultRevision,
            terrainPath: "/tmp/terrain.tif", terrainRevision: String(repeating: "c", count: 64),
            sourceID: "result-node", profileIndex: profileIndex,
            profileName: "Profile \(profileIndex)", time: "2025-01-01T00:00:00")
    }

    @MainActor private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<2_000 {
            if condition() { return }
            await Task.yield()
        }
        Issue.record("The velocity particle state did not reach the expected state.")
        throw CancellationError()
    }
}

private struct InteriorParticleRandomNumberGenerator: RandomNumberGenerator {
    mutating func next() -> UInt64 { 0x5555_5555_5555_5555 }
}
