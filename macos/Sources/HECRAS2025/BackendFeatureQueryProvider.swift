import CryptoKit
import Foundation
import RASWorkspaceCore

struct FeatureQueryExportedSource: Decodable, Sendable {
    let path: String
    let revision: String
    let name: String
    let mapType: String
    let featureCount: Int
    let lineColor: String
    let fillColor: String
    let lineWidth: Double
    let family: MapSourceFamilyCapture?
}

/// Keeps query previews private until the user explicitly exports them. Every
/// round trip is bound to the same project bytes and saved-map identity.
@MainActor
final class BackendFeatureQueryProvider: FeatureQueryProvider {
    private struct Capture: Sendable {
        let context: FeatureQueryContext
        let map: MapTreeMapIdentity
        let projectRevision: String
    }
    private let client: BackendProcessClient
    private let mapIdentity: @MainActor (FeatureQueryContext) -> MapTreeMapIdentity?
    private let chooseOutputDirectory: @MainActor () -> URL?
    private let didExport: @MainActor ([FeatureQueryExportedSource], FeatureQueryContext, String, [String]) async throws -> MapUpdate
    private var resultCaptures: [String: Capture] = [:]

    init(client: BackendProcessClient,
         mapIdentity: @escaping @MainActor (FeatureQueryContext) -> MapTreeMapIdentity?,
         chooseOutputDirectory: @escaping @MainActor () -> URL?,
         didExport: @escaping @MainActor ([FeatureQueryExportedSource], FeatureQueryContext, String, [String]) async throws -> MapUpdate) {
        self.client = client
        self.mapIdentity = mapIdentity
        self.chooseOutputDirectory = chooseOutputDirectory
        self.didExport = didExport
    }

    func invalidate() { resultCaptures.removeAll() }

    func snapshot(_ context: FeatureQueryContext) async throws -> FeatureQuerySnapshot {
        let capture = try await capture(context)
        let response = try await client.request("featureQuery.snapshot",
            parameters: SnapshotRequest(map: capture.map), as: SnapshotResponse.self)
        try await validate(response.map, capture: capture)
        let ids = response.polygonSources.map(\.id)
        guard ids.allSatisfy({ !$0.isEmpty }), Set(ids).count == ids.count,
              response.selectedPolygonId.map({ ids.contains($0) }) ?? true else { throw mismatch() }
        resultCaptures = resultCaptures.filter { $0.value.context != context }
        return .init(polygonSources: response.polygonSources.map { .init(id: $0.id, name: $0.name) },
                     selectedPolygonID: response.selectedPolygonId)
    }

    func query(_ request: FeatureQueryRequest,
               progress: @escaping @MainActor (FeatureQueryProgress) -> Void) async throws -> FeatureQueryResult {
        let capture = try await capture(request.context)
        let extent = request.extent.map { Bounds(minX: $0.lowerLeft.x, minY: $0.lowerLeft.y,
                                                 maxX: $0.upperRight.x, maxY: $0.upperRight.y) }
        if let extent, !extent.isValid { throw BackendServiceError(code: "invalidExtent", message: "The query extent is invalid.") }
        let response = try await client.request("featureQuery.query", parameters: QueryRequest(
            map: capture.map, kind: request.context.kind.rawValue, extent: extent,
            nldLayerId: request.nldLayerID, useBoundaryPolygon: request.useBoundaryPolygon,
            polygonSourceId: request.polygonSourceID, rawQl: request.rawQL, queryLabel: request.queryLabel),
            as: QueryResponse.self, progress: { update in
                Task { @MainActor in
                    progress(.init(info: L10n.text(update.message ?? "Querying..."),
                                   percent: update.fraction.map { $0 * 100 }))
                }
            })
        try await validate(response.map, capture: capture)
        guard response.kind == request.context.kind.rawValue, !response.resultId.isEmpty else { throw mismatch() }
        var layers: [QueryPreviewLayer] = []
        for source in response.layers {
            guard source.coordinateSpace == "ProjectWorld",
                  ["PointsVector", "PolylinesVector", "PolygonsVector"].contains(source.mapType),
                  source.lineWidth.isFinite, source.lineWidth >= 0 else { throw mismatch() }
            let layer = try await Self.readPreview(source, mapID: request.context.mapID)
            layers.append(.init(layer: layer, lineColor: source.lineColor,
                                fillColor: source.fillColor, lineWidth: source.lineWidth))
        }
        try await validate(response.map, capture: capture)
        guard response.hasFeatures == layers.contains(where: { !$0.layer.features.isEmpty }),
              Set(layers.map(\.id)).count == layers.count else { throw mismatch() }
        resultCaptures = resultCaptures.filter { $0.value.context != request.context }
        resultCaptures[response.resultId] = capture
        return .init(id: response.resultId, hasFeatures: response.hasFeatures,
                     info: L10n.text(response.info), layers: layers)
    }

    func saveToDisk(_ resultID: String, formatID: String, context: FeatureQueryContext) async throws -> MapUpdate {
        guard let capture = resultCaptures[resultID], capture.context == context else { throw mismatch() }
        try requireCurrent(capture)
        guard let directory = chooseOutputDirectory() else { throw CancellationError() }
        try requireCurrent(capture)
        let response = try await client.request("featureQuery.save", parameters: SaveRequest(
            map: capture.map, resultId: resultID, formatId: formatID, outputDirectory: directory.path),
            as: SaveResponse.self)
        try await validate(response.map, capture: capture)
        guard !response.sources.isEmpty else { throw mismatch() }
        for source in response.sources {
            guard source.featureCount > 0, Self.isSHA256(source.revision),
                  source.path.hasPrefix("/"),
                  source.lineWidth.isFinite, source.lineWidth >= 0 else { throw mismatch() }
            let actual = try await Self.revision(URL(fileURLWithPath: source.path))
            guard actual.caseInsensitiveCompare(source.revision) == .orderedSame else { throw mismatch() }
        }
        try requireCurrent(capture)
        return try await didExport(response.sources, context, response.info, response.warnings ?? [])
    }

    func suggest(key: String, value: String, isKey: Bool) async throws -> [String] {
        let result = try await client.request("featureQuery.suggest",
            parameters: SuggestionRequest(key: key, value: value, isKey: isKey), as: SuggestionResponse.self)
        try Task.checkCancellation()
        return result.suggestions
    }

    private func capture(_ context: FeatureQueryContext) async throws -> Capture {
        guard let map = mapIdentity(context) else {
            throw BackendServiceError(code: "unavailable", message: "The query requires an available saved map.")
        }
        let value = Capture(context: context, map: map,
                            projectRevision: try await Self.revision(URL(fileURLWithPath: map.projectPath)))
        try requireCurrent(value)
        return value
    }

    private func requireCurrent(_ capture: Capture) throws {
        try Task.checkCancellation()
        guard mapIdentity(capture.context) == capture.map else { throw CancellationError() }
    }

    private func validate(_ reply: MapSourceMapCapture, capture: Capture) async throws {
        try requireCurrent(capture)
        guard Self.matches(reply, map: capture.map, projectRevision: capture.projectRevision) else { throw mismatch() }
        let actual = try await Self.revision(URL(fileURLWithPath: capture.map.projectPath))
        try requireCurrent(capture)
        guard actual == capture.projectRevision else { throw mismatch() }
    }

    static func matches(_ reply: MapSourceMapCapture, map: MapTreeMapIdentity, projectRevision: String) -> Bool {
        reply.isPersisted && reply.mapID?.caseInsensitiveCompare(map.mapID) == .orderedSame
            && reply.mapIndex == map.mapIndex && reply.mapName == map.mapName && reply.mapType == map.mapType
            && SourceFilePaths.canonical(URL(fileURLWithPath: reply.projectPath)) == SourceFilePaths.canonical(URL(fileURLWithPath: map.projectPath))
            && reply.projectRevision.caseInsensitiveCompare(projectRevision) == .orderedSame
            && reply.projectXmlSHA?.caseInsensitiveCompare(map.projectXmlSHA) == .orderedSame
            && reply.visualizationRevision?.caseInsensitiveCompare(map.expectedVisualizationRevision) == .orderedSame
    }

    private static func readPreview(_ source: PreviewLayer, mapID: UUID) async throws -> MapVectorLayer {
        guard source.sourcePath.hasPrefix("/"), isSHA256(source.sourceRevision) else {
            throw BackendServiceError(code: "mismatchedReply", message: "The feature query returned a different source context.")
        }
        return try await Task.detached {
            try Task.checkCancellation()
            let url = URL(fileURLWithPath: source.sourcePath)
            let data = try Data(contentsOf: url)
            let revision = SHA256.hash(data: data).map { String(format: "%02X", $0) }.joined()
            guard revision.caseInsensitiveCompare(source.sourceRevision) == .orderedSame else { throw ProjectFileError.modifiedExternally }
            let parsed = try MapVectorLayer(data: data, sourceURL: url)
            let kind: MapFeature.Kind = source.mapType == "PointsVector" ? .point : source.mapType == "PolylinesVector" ? .line : .polygon
            guard parsed.features.allSatisfy({ $0.kind == kind }) else {
                throw ProjectFileError.invalid("The query preview geometry does not match its source type.")
            }
            return MapVectorLayer(url: url, features: parsed.features, sourceMapID: mapID,
                                  sourceRevision: revision, visualName: source.name)
        }.value
    }

    private static func revision(_ url: URL) async throws -> String {
        try await Task.detached {
            try Task.checkCancellation()
            return SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02X", $0) }.joined()
        }.value
    }
    private static func isSHA256(_ value: String) -> Bool { value.count == 64 && value.allSatisfy(\.isHexDigit) }
    private func mismatch() -> BackendServiceError {
        .init(code: "mismatchedReply", message: "The feature query returned a different source context.")
    }

    private struct SnapshotRequest: Encodable, Sendable { let map: MapTreeMapIdentity }
    private struct PolygonSource: Decodable, Sendable { let id: String; let name: String }
    private struct SnapshotResponse: Decodable, Sendable {
        let map: MapSourceMapCapture; let polygonSources: [PolygonSource]; let selectedPolygonId: String?
    }
    private struct Bounds: Encodable, Sendable {
        let minX: Double; let minY: Double; let maxX: Double; let maxY: Double
        var isValid: Bool { minX.isFinite && minY.isFinite && maxX.isFinite && maxY.isFinite && minX < maxX && minY < maxY }
    }
    private struct QueryRequest: Encodable, Sendable {
        let map: MapTreeMapIdentity; let kind: String; let extent: Bounds?; let nldLayerId: String
        let useBoundaryPolygon: Bool; let polygonSourceId: String?; let rawQl: String; let queryLabel: String
    }
    private struct PreviewLayer: Decodable, Sendable {
        let name: String; let sourcePath: String; let sourceRevision: String; let mapType: String
        let lineColor: String; let fillColor: String; let lineWidth: Double
        let coordinateSpace: String
    }
    private struct QueryResponse: Decodable, Sendable {
        let map: MapSourceMapCapture; let kind: String; let resultId: String; let hasFeatures: Bool
        let info: String; let layers: [PreviewLayer]
    }
    private struct SaveRequest: Encodable, Sendable {
        let map: MapTreeMapIdentity; let resultId: String; let formatId: String; let outputDirectory: String
    }
    private struct SaveResponse: Decodable, Sendable {
        let map: MapSourceMapCapture; let sources: [FeatureQueryExportedSource]; let info: String; let warnings: [String]?
    }
    private struct SuggestionRequest: Encodable, Sendable { let key: String; let value: String; let isKey: Bool }
    private struct SuggestionResponse: Decodable, Sendable { let suggestions: [String] }
}
