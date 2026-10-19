import Combine
import CryptoKit
import Foundation
import RASWorkspaceCore

struct MapDynamicProfileLine: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let points: [GeometryTopologyCoordinate]
    /// Stable identity for a saved map vector component. Geometry/Culvert
    /// editor drafts intentionally leave this nil because they do not refer to
    /// a persisted map-vector feature.
    var feature: MapResultFeatureIdentity? = nil
}

struct MapDynamicProfileSelection: Codable, Equatable, Sendable {
    let node: CatalogTreeNodeLocator
    let profileIndex: Int
}

struct MapDynamicProfileRequest: Encodable, Sendable {
    let map: MapResultChartMapRequest
    let contextToken: String
    let selectionOverrides: [MapResultSelectionOverride]
    let lines: [MapDynamicProfileLine]
    let linesToken: String
    let targetSampleCount: Int
    let plotTerrains: Bool
    let plotResults: Bool
    let terrainRequiresElevationResult: Bool
    let mapType: String?
    let profileSelections: [MapDynamicProfileSelection]
    var linkedResults: LinkedResultProfilesRequest? = nil
    var linkedFrameMode: String = "Profile"

    var identity: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(self) else { return "invalid-profile-request" }
        return Self.digest(data)
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02X", $0) }.joined()
    }
}

struct MapDynamicProfileSeries: Decodable, Identifiable, Sendable {
    let id: String
    let lineId: String
    let sourceKind: String
    let sourcePath: String
    let sourceRevision: String
    let name: String
    let mapType: String?
    let profileIndex: Int?
    let time: String?
    let units: String
    let samples: [Double?]
    let terrainPath: String?
    let terrainRevision: String?
    let unavailableReason: String?
}

struct MapDynamicProfileLineResult: Decodable, Identifiable, Sendable {
    let id: String
    let points: [GeometryTopologyCoordinate]
    let samplePoints: [GeometryTopologyCoordinate]
    let distances: [Double]
    let series: [MapDynamicProfileSeries]
}

struct MapDynamicProfileResult: Decodable, Sendable {
    let projectPath: String
    let projectRevision: String
    let projectXmlSHA: String
    let visualizationRevision: String
    let mapID: String
    let mapIndex: Int
    let mapName: String
    let mapType: String
    let contextToken: String
    let linesToken: String
    let targetSampleCount: Int
    let distanceUnits: String
    let lines: [MapDynamicProfileLineResult]

    func validate(for request: MapDynamicProfileRequest, expectedProjectRevision: String? = nil) throws {
        let samePath = SourceFilePaths.canonical(URL(fileURLWithPath: projectPath))
            == SourceFilePaths.canonical(URL(fileURLWithPath: request.map.projectPath))
        guard samePath, !projectRevision.isEmpty,
              expectedProjectRevision.map({ $0 == projectRevision }) ?? true,
              projectXmlSHA == request.map.projectXmlSHA,
              visualizationRevision == request.map.expectedVisualizationRevision,
              Self.sameMapIdentity(mapID, request.map.mapID), mapIndex == request.map.mapIndex,
              mapName == request.map.mapName, mapType == request.map.mapType,
              contextToken == request.contextToken, linesToken == request.linesToken,
              targetSampleCount == request.targetSampleCount,
              ["ft", "m"].contains(distanceUnits),
              lines.map(\.id) == request.lines.map(\.id),
              Set(lines.map(\.id)).count == lines.count else { throw Self.invalidResponse }
        var seriesIDs = Set<String>()
        for (line, source) in zip(lines, request.lines) {
            guard line.points == source.points, line.samplePoints.count >= 2,
                  line.samplePoints.count == line.distances.count,
                  line.samplePoints.allSatisfy({ $0.x.isFinite && $0.y.isFinite }),
                  line.distances.first == 0, line.distances.allSatisfy({ $0.isFinite && $0 >= 0 }),
                  zip(line.distances, line.distances.dropFirst()).allSatisfy({ $0 <= $1 })
            else { throw Self.invalidResponse }
            for series in line.series {
                guard !series.id.isEmpty, seriesIDs.insert(series.id).inserted,
                      series.lineId == line.id, ["Terrain", "Result"].contains(series.sourceKind),
                      !series.sourcePath.isEmpty,
                      !series.sourceRevision.isEmpty || series.unavailableReason != nil,
                      series.samples.count == line.distances.count,
                      series.samples.allSatisfy({ $0?.isFinite ?? true }),
                      series.unavailableReason == nil || series.samples.allSatisfy({ $0 == nil }),
                      series.profileIndex.map({ $0 >= 0 ||
                        ($0 == Int(Int32.min) && series.unavailableReason != nil) }) ?? true,
                      series.sourceKind != "Result" || series.unavailableReason != nil ||
                        (series.profileIndex != nil &&
                         (series.time != nil || series.profileIndex == Int(Int32.max)))
                else { throw Self.invalidResponse }
            }
        }
    }

    private static var invalidResponse: BackendServiceError {
        BackendServiceError(code: "protocolFailure",
            message: "The profile response does not match the current map and sample lines.")
    }

    private static func sameMapIdentity(_ lhs: String, _ rhs: String) -> Bool {
        if let left = UUID(uuidString: lhs), let right = UUID(uuidString: rhs) { return left == right }
        return lhs == rhs
    }
}

@MainActor
protocol MapDynamicProfileProviding {
    func sample(_ request: MapDynamicProfileRequest) async throws -> MapDynamicProfileResult
}

struct BackendMapDynamicProfileProvider: MapDynamicProfileProviding {
    let client: BackendProcessClient
    func sample(_ request: MapDynamicProfileRequest) async throws -> MapDynamicProfileResult {
        let result = try await client.request("map.dynamicProfiles", parameters: request,
            as: MapDynamicProfileResult.self)
        try result.validate(for: request)
        return result
    }
}

@MainActor
final class MapDynamicProfileSession: ObservableObject {
    @Published private(set) var snapshot: MapDynamicProfileResult?
    @Published private(set) var acceptedRequestIdentity: String?
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?
    private let provider: any MapDynamicProfileProviding
    private var generation = 0
    private var requestTask: Task<MapDynamicProfileResult, any Error>?

    init(provider: any MapDynamicProfileProviding) { self.provider = provider }

    func load(_ request: MapDynamicProfileRequest, expectedProjectRevision: String? = nil,
              isCurrent: @escaping @MainActor () -> Bool) async {
        requestTask?.cancel()
        requestTask = nil
        generation &+= 1
        let current = generation
        snapshot = nil
        acceptedRequestIdentity = nil
        error = nil
        isLoading = true
        defer { if current == generation { isLoading = false } }
        guard isCurrent(), !Task.isCancelled else { return }
        let provider = self.provider
        let task = Task { try await provider.sample(request) }
        requestTask = task
        do {
            let loaded = try await task.value
            guard current == generation, !Task.isCancelled, isCurrent() else { return }
            try loaded.validate(for: request, expectedProjectRevision: expectedProjectRevision)
            snapshot = loaded
            acceptedRequestIdentity = request.identity
        } catch {
            guard current == generation, !Task.isCancelled, isCurrent() else { return }
            if !(error is CancellationError) { self.error = L10n.text(error.localizedDescription) }
        }
        if current == generation { requestTask = nil }
    }

    func invalidate() {
        generation &+= 1
        requestTask?.cancel()
        requestTask = nil
        snapshot = nil
        acceptedRequestIdentity = nil
        error = nil
        isLoading = false
    }
}
