import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

struct MapDynamicProfileStateTests {
    @Test func scrubberUsesSourceStationDistanceAndDoesNotClampShorterLines() {
        let points = [GeometryTopologyCoordinate(x: 0, y: 0), .init(x: 3, y: 0), .init(x: 3, y: 4)]
        #expect(MapDynamicProfileLineGeometry.point(on: points, distance: 5) == MapPoint(x: 3, y: 2))
        #expect(MapDynamicProfileLineGeometry.point(on: points, distance: 7) == MapPoint(x: 3, y: 4))
        #expect(MapDynamicProfileLineGeometry.point(on: points, distance: 8) == nil)
        #expect(MapDynamicProfileLineGeometry.point(on: points, distance: -1) == nil)
        #expect(MapDynamicProfileLineGeometry.point(on: points, distance: .nan) == nil)
    }

    @Test @MainActor func closingAnOlderPlotCannotClearOrMoveAnotherPlotsMapMarkers() {
        let overlay = MapDynamicProfileOverlaySession()
        let first = UUID(), second = UUID()
        let line = MapDynamicProfileLine(id: "arc:7", points: [.init(x: 0, y: 0), .init(x: 10, y: 0)])
        overlay.install(owner: first, lines: [line])
        overlay.move(owner: first, distance: 2)
        #expect(overlay.markers.first?.point == MapPoint(x: 2, y: 0))
        overlay.install(owner: second, lines: [line])
        overlay.move(owner: second, distance: 6)
        overlay.clear(owner: first)
        overlay.move(owner: first, distance: 1)
        #expect(overlay.markers.first?.point == MapPoint(x: 6, y: 0))
        overlay.clear(owner: second)
        #expect(overlay.markers.isEmpty)
    }

    @Test @MainActor func scrubberUsesReturnedDensifiedStationsAndNeverFallsBackAfterTheirEndpoint() {
        let owner = UUID(), overlay = MapDynamicProfileOverlaySession()
        let line = MapDynamicProfileLine(id: "arc:7", points: [.init(x: 0, y: 0), .init(x: 10, y: 0)])
        overlay.install(owner: owner, lines: [line], distancesByID: [line.id: [0, 5]])
        overlay.move(owner: owner, distance: 2)
        #expect(overlay.markers.first?.point == MapPoint(x: 4, y: 0))
        overlay.move(owner: owner, distance: 6)
        #expect(overlay.markers.isEmpty)
    }

    @Test func summarySentinelsKeepMissingTimeAndUnavailableMinimumWithoutMasqueradingAsAProfile() throws {
        let request = Self.request()
        try Self.response(request, kind: "Result", profileIndex: Int(Int32.max))
            .validate(for: request)
        try Self.response(request, samples: [NSNull(), NSNull(), NSNull()],
            kind: "Result", profileIndex: Int(Int32.min),
            unavailableReason: "The retained source does not read Minimum summaries.")
            .validate(for: request)
        #expect(throws: BackendServiceError.self) {
            try Self.response(request, kind: "Result", profileIndex: Int(Int32.min))
                .validate(for: request)
        }
        #expect(throws: BackendServiceError.self) {
            try Self.response(request, kind: "Result", profileIndex: 2).validate(for: request)
        }
    }

    @Test func responsePreservesMissingSamplesAndRejectsWrongLinesOwnerAndDistances() throws {
        let request = Self.request()
        let value = try Self.response(request)
        try value.validate(for: request, expectedProjectRevision: "project-sha")
        #expect(value.lines[0].series[0].samples[1] == nil)
        #expect(throws: BackendServiceError.self) {
            try Self.response(request, linesToken: "old-line-selection").validate(for: request)
        }
        #expect(throws: BackendServiceError.self) {
            try value.validate(for: request, expectedProjectRevision: "another-project-sha")
        }
        #expect(throws: BackendServiceError.self) {
            try Self.response(request, distances: [0, 7, 3]).validate(for: request)
        }
        #expect(throws: BackendServiceError.self) {
            try Self.response(request, samples: [1]).validate(for: request)
        }
        #expect(throws: BackendServiceError.self) {
            try Self.response(request, distanceUnits: "yd").validate(for: request)
        }
    }

    @Test func savedMapLineFeatureUsesTheBackendWireNamesAndDraftsOmitIt() throws {
        let identity = MapResultFeatureIdentity(vectorPath: "/tmp/line.geojson",
            vectorRevision: "vector-sha", featureID: "feature:7", coordinateSHA: "coordinate-sha")
        let saved = MapDynamicProfileLine(id: "feature:7",
            points: [.init(x: 0, y: 0), .init(x: 1, y: 1)], feature: identity)
        let encodedSaved = try JSONEncoder().encode(saved)
        let savedObject = try #require(JSONSerialization.jsonObject(with: encodedSaved) as? [String: Any])
        let feature = try #require(savedObject["feature"] as? [String: String])
        #expect(feature["vectorPath"] == "/tmp/line.geojson")
        #expect(feature["vectorRevision"] == "vector-sha")
        #expect(feature["featureID"] == "feature:7")
        #expect(feature["coordinateSHA"] == "coordinate-sha")
        #expect(try JSONDecoder().decode(MapDynamicProfileLine.self, from: encodedSaved) == saved)

        let draft = MapDynamicProfileLine(id: "arc:7",
            points: [.init(x: 0, y: 0), .init(x: 1, y: 1)])
        let encodedDraft = try JSONEncoder().encode(draft)
        let draftObject = try #require(JSONSerialization.jsonObject(with: encodedDraft) as? [String: Any])
        #expect(draftObject["feature"] == nil)
    }

    @Test @MainActor func cancelledPlotDoesNotInstallItsLateSampleOrRestoreBusyState() async throws {
        let provider = ControlledDynamicProfileProvider()
        let session = MapDynamicProfileSession(provider: provider)
        let request = Self.request()
        let task = Task { await session.load(request, isCurrent: { true }) }
        try await waitFor(provider, pending: 1)
        session.invalidate()
        provider.complete(try Self.response(request))
        await task.value
        #expect(session.snapshot == nil && session.acceptedRequestIdentity == nil && !session.isLoading)
    }

    @Test @MainActor func newerMapRequestWinsEvenWhenTheOlderProviderFinishesLast() async throws {
        let provider = ControlledDynamicProfileProvider()
        let session = MapDynamicProfileSession(provider: provider)
        let old = Self.request(token: "old-lines"), new = Self.request(token: "new-lines")
        let first = Task { await session.load(old, isCurrent: { true }) }
        try await waitFor(provider, pending: 1)
        let second = Task { await session.load(new, isCurrent: { true }) }
        try await waitFor(provider, pending: 2)
        provider.complete(try Self.response(new), at: 1)
        await second.value
        provider.complete(try Self.response(old))
        await first.value
        #expect(session.snapshot?.linesToken == "new-lines")
        #expect(session.acceptedRequestIdentity == new.identity && !session.isLoading)
    }

    @Test @MainActor func switchedMapOwnerDiscardsAReplyEvenWithoutANewerRequest() async throws {
        let provider = ControlledDynamicProfileProvider()
        let session = MapDynamicProfileSession(provider: provider)
        let request = Self.request()
        let owner = DynamicProfileTestOwner()
        let task = Task { await session.load(request, isCurrent: { owner.isCurrent }) }
        try await waitFor(provider, pending: 1)
        owner.isCurrent = false
        provider.complete(try Self.response(request))
        await task.value
        #expect(session.snapshot == nil && !session.isLoading && session.error == nil)
    }

    @MainActor private func waitFor(_ provider: ControlledDynamicProfileProvider, pending: Int) async throws {
        for _ in 0..<200 where provider.pending.count < pending { await Task.yield() }
        try #require(provider.pending.count == pending)
    }

    private static func request(token: String = "source-lines") -> MapDynamicProfileRequest {
        let map = MapResultChartMapRequest(projectPath: "/tmp/dynamic-profile.ras", projectXml: "<Ras />",
            projectXmlSHA: "xml-sha", mapID: "A2BCE020-00AC-4B88-AD36-265206772301", mapIndex: 0, mapName: "Repeated map name",
            mapType: "Project", expectedVisualizationRevision: "vis-sha")
        return MapDynamicProfileRequest(map: map, contextToken: "actual-map-context", selectionOverrides: [],
            lines: [.init(id: "arc:7", points: [.init(x: 0, y: 0), .init(x: 3, y: 0), .init(x: 3, y: 4)])],
            linesToken: token, targetSampleCount: 256, plotTerrains: true, plotResults: true,
            terrainRequiresElevationResult: true, mapType: "WaterSurfaceElevation", profileSelections: [])
    }

    private static func response(_ request: MapDynamicProfileRequest, linesToken: String? = nil,
                                 distances: [Double] = [0, 3, 7],
                                 samples: [Any] = [10.0, NSNull(), 20.0], kind: String = "Terrain",
                                 profileIndex: Int? = nil,
                                 unavailableReason: String? = nil,
                                 distanceUnits: String = "m") throws -> MapDynamicProfileResult {
        let points = request.lines[0].points.map { ["x": $0.x, "y": $0.y] }
        var series: [String: Any] = ["id": "arc:7:terrain", "lineId": "arc:7", "sourceKind": kind,
            "sourcePath": "/tmp/source-terrain.h5", "sourceRevision": "terrain-sha", "name": "Real source name",
            "mapType": NSNull(), "profileIndex": NSNull(), "time": NSNull(), "units": "m", "samples": samples]
        if let profileIndex { series["profileIndex"] = profileIndex }
        if let unavailableReason { series["unavailableReason"] = unavailableReason }
        let json: [String: Any] = ["projectPath": request.map.projectPath, "projectRevision": "project-sha",
            "projectXmlSHA": request.map.projectXmlSHA, "visualizationRevision": request.map.expectedVisualizationRevision,
            "mapID": request.map.mapID, "mapIndex": request.map.mapIndex, "mapName": request.map.mapName,
            "mapType": request.map.mapType, "contextToken": request.contextToken, "distanceUnits": distanceUnits,
            "linesToken": linesToken ?? request.linesToken, "targetSampleCount": request.targetSampleCount,
            "lines": [["id": "arc:7", "points": points, "samplePoints": points,
                "distances": distances, "series": [series]]]]
        return try JSONDecoder().decode(MapDynamicProfileResult.self, from: JSONSerialization.data(withJSONObject: json))
    }
}

@MainActor private final class DynamicProfileTestOwner {
    var isCurrent = true
}

@MainActor private final class ControlledDynamicProfileProvider: MapDynamicProfileProviding {
    var pending: [CheckedContinuation<MapDynamicProfileResult, any Error>] = []
    func sample(_ request: MapDynamicProfileRequest) async throws -> MapDynamicProfileResult {
        try await withCheckedThrowingContinuation { pending.append($0) }
    }
    func complete(_ result: MapDynamicProfileResult, at index: Int = 0) {
        pending.remove(at: index).resume(returning: result)
    }
}
