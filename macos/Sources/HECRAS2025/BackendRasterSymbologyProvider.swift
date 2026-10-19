import Foundation
import RASWorkspaceCore

private struct RasterSymbologyRequest: Encodable, Sendable {
    let source: RasterMapSourceDescriptor
    let projectXml: String?
}

private struct RasterSymbologyHistogramRequest: Encodable, Sendable {
    let source: RasterMapSourceDescriptor
    let projectXml: String?
    let viewport: RasterMapViewExtent?
    let count: Int
    let forView: Bool
}

private struct RasterSymbologySelectPaletteRequest: Encodable, Sendable {
    let source: RasterMapSourceDescriptor
    let projectXml: String?
    let paletteID: String
    let draft: RasterSymbologyDraft
}

private struct RasterSymbologyApplyRequest: Encodable, Sendable {
    let source: RasterMapSourceDescriptor
    let projectXml: String?
    let draft: RasterSymbologyDraft
}

private struct RasterSymbologySavePaletteRequest: Encodable, Sendable {
    let source: RasterMapSourceDescriptor
    let projectXml: String?
    let draft: RasterSymbologyDraft
    let name: String
}

private struct RasterSymbologyDeletePaletteRequest: Encodable, Sendable {
    let source: RasterMapSourceDescriptor
    let projectXml: String?
    let paletteID: String
}

private struct RasterSymbologySnapshotPayload: Decodable, Sendable {
    let draft: RasterSymbologyDraft
    let palettes: [RasterPalette]
    let surfaceFillValues: [Double]?
}

private struct RasterSymbologyInspectPayload: Decodable, Sendable {
    let previousVisualizationRevision: String
    let visualizationRevision: String
    let sourceRevision: String
    let snapshot: RasterSymbologySnapshotPayload
    let raster: RasterMapLayerPayload
    let rasterInfoStats: RasterImportContextSource?
}

struct RasterMapLayerLoadResult: Sendable {
    let layer: MapRasterLayer
    let rasterInfoStats: RasterImportContextSource?
}

private struct RasterSymbologySnapshotResult: Decodable, Sendable {
    let previousVisualizationRevision: String
    let visualizationRevision: String
    let sourceRevision: String
    let snapshot: RasterSymbologySnapshotPayload
}

private struct RasterSymbologyDraftResult: Decodable, Sendable {
    let draft: RasterSymbologyDraft
}

private struct RasterSymbologyApplyPayload: Decodable, Sendable {
    let previousVisualizationRevision: String
    let visualizationRevision: String
    let sourceRevision: String
    let raster: RasterMapLayerPayload
}

private struct RasterSymbologyPalettesPayload: Decodable, Sendable {
    let previousVisualizationRevision: String
    let visualizationRevision: String
    let sourceRevision: String
    let palettes: [RasterPalette]
}

private struct RasterMapLayerPayload: Decodable, Sendable {
    let id: String
    let sourceMapID: String?
    let name: String
    let width: Int
    let height: Int
    let rgba: Data
    let minX: Double
    let minY: Double
    let maxX: Double
    let maxY: Double

    func makeLayer(matching source: RasterMapSourceDescriptor) throws -> MapRasterLayer {
        guard id == source.id,
              let mapID = sourceMapID.flatMap(UUID.init(uuidString:)),
              mapID == source.sourceMapID else {
            throw BackendServiceError(code: "sourceChanged", message: "The raster response no longer belongs to the selected map layer.")
        }
        return try MapRasterLayer(id: id, name: name, width: width, height: height, rgba: rgba,
            lowerLeft: MapPoint(x: minX, y: minY), upperRight: MapPoint(x: maxX, y: maxY), sourceMapID: mapID)
    }
}

@MainActor
final class BackendRasterSymbologyProvider: RasterSymbologyProvider {
    typealias SourceList = @MainActor () -> [RasterMapSourceDescriptor]
    typealias ViewportLookup = @MainActor (UUID) -> RasterMapViewExtent?
    typealias ProjectXMLLookup = @MainActor () -> String?
    typealias LayerInstaller = @MainActor (MapRasterLayer) -> Void
    typealias VisualizationAcceptor = @MainActor (_ expectedPreviousRevision: String, _ newRevision: String) throws -> Void

    private let client: BackendProcessClient
    private let sources: SourceList
    private let viewport: ViewportLookup
    private let projectXML: ProjectXMLLookup
    private let installLayer: LayerInstaller
    private let acceptVisualization: VisualizationAcceptor
    private struct SourceCacheKey: Hashable {
        let id: String
        let mapID: UUID?
        let projectPath: String
        let visualizationPath: String
        let sourcePath: String
    }
    private var sourceCache: [SourceCacheKey: RasterMapSourceDescriptor] = [:]
    private var supersededRevisions: [SourceCacheKey: String] = [:]
    private var mutationRunning = false
    var onMutationRunningChanged: (@MainActor (Bool) -> Void)?
    var canBeginMutation: @MainActor () -> Bool = { true }

    init(
        client: BackendProcessClient? = nil,
        sources: @escaping SourceList,
        viewport: @escaping ViewportLookup,
        projectXML: @escaping ProjectXMLLookup = { nil },
        installLayer: @escaping LayerInstaller,
        acceptVisualization: @escaping VisualizationAcceptor
    ) {
        self.client = client ?? BackendProcessClient(executableURL: Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/Backend/HECRASBackend"))
        self.sources = sources
        self.viewport = viewport
        self.projectXML = projectXML
        self.installLayer = installLayer
        self.acceptVisualization = acceptVisualization
    }

    func loadMapLayer(_ descriptor: RasterMapSourceDescriptor) async throws -> MapRasterLayer {
        try await loadMapLayerWithProperties(descriptor).layer
    }

    func loadMapLayerWithProperties(_ descriptor: RasterMapSourceDescriptor) async throws -> RasterMapLayerLoadResult {
        guard let mapID = descriptor.sourceMapID else {
            throw BackendServiceError(code: "invalidInput", message: "The raster source is not assigned to a map.")
        }
        guard let source = currentSource(id: descriptor.id, mapID: mapID), sameSourceIdentity(source, descriptor) else {
            throw missingSource()
        }
        let result = try await client.request("rasterMap.load",
            parameters: RasterSymbologyRequest(source: source, projectXml: projectXML()),
            as: RasterSymbologyInspectPayload.self)
        try requireCurrent(source, allowedRevisions: [source.visualizationRevision])
        try validateReadRevisions(source, previous: result.previousVisualizationRevision,
                                  current: result.visualizationRevision, source: result.sourceRevision)
        cache(result.previousVisualizationRevision, result.visualizationRevision, result.sourceRevision, source)
        let rasterInfoStats = result.rasterInfoStats
        if let rasterInfoStats {
            guard SourceFilePaths.canonical(URL(fileURLWithPath: rasterInfoStats.path))
                        == SourceFilePaths.canonical(URL(fileURLWithPath: source.sourcePath)),
                  rasterInfoStats.revision.caseInsensitiveCompare(result.sourceRevision) == .orderedSame else {
                throw BackendServiceError(code: "sourceChanged", message: "Raster statistics do not belong to the loaded source revision.")
            }
        }
        return RasterMapLayerLoadResult(layer: try result.raster.makeLayer(matching: source),
            rasterInfoStats: rasterInfoStats)
    }

    func snapshot(_ context: RasterSymbologyContext) async throws -> RasterSymbologySnapshot? {
        guard let source = source(for: context) else { return nil }
        let result = try await client.request("rasterSymbology.inspect",
            parameters: RasterSymbologyRequest(source: source, projectXml: projectXML()),
            as: RasterSymbologyInspectPayload.self)
        try requireCurrent(source, allowedRevisions: [source.visualizationRevision])
        try validateReadRevisions(source, previous: result.previousVisualizationRevision,
                                  current: result.visualizationRevision, source: result.sourceRevision)
        cache(result.previousVisualizationRevision, result.visualizationRevision, result.sourceRevision, source)
        return makeSnapshot(result.snapshot)
    }

    func selectPalette(_ id: String, draft: RasterSymbologyDraft,
                       context: RasterSymbologyContext) async throws -> RasterSymbologyDraft {
        guard let source = source(for: context) else { throw missingSource() }
        let result = try await client.request("rasterSymbology.selectPalette",
            parameters: RasterSymbologySelectPaletteRequest(source: source, projectXml: projectXML(), paletteID: id, draft: draft),
            as: RasterSymbologyDraftResult.self)
        try requireCurrent(source, allowedRevisions: [source.visualizationRevision])
        return result.draft
    }

    func histogram(count: Int, forView: Bool, context: RasterSymbologyContext) async throws -> [Double] {
        guard let source = source(for: context) else { throw missingSource() }
        let values = try await client.request("rasterSymbology.histogram",
            parameters: RasterSymbologyHistogramRequest(source: source, projectXml: projectXML(),
                viewport: forView ? viewport(context.mapID) : nil, count: count, forView: forView),
            as: [Double].self)
        try requireCurrent(source, allowedRevisions: [source.visualizationRevision])
        return values
    }

    func apply(_ draft: RasterSymbologyDraft, context: RasterSymbologyContext) async throws {
        try beginMutation()
        defer { endMutation() }
        guard let source = source(for: context) else { throw missingSource() }
        let result = try await client.request("rasterSymbology.apply",
            parameters: RasterSymbologyApplyRequest(source: source, projectXml: projectXML(), draft: draft),
            as: RasterSymbologyApplyPayload.self)
        try requireCurrent(source, allowedRevisions: [source.visualizationRevision])
        try validateMutationRevisions(source, previous: result.previousVisualizationRevision,
                                      current: result.visualizationRevision, source: result.sourceRevision)
        try acceptVisualization(result.previousVisualizationRevision, result.visualizationRevision)
        try requireCurrent(source, allowedRevisions: [source.visualizationRevision, result.visualizationRevision])
        cache(result.previousVisualizationRevision, result.visualizationRevision, result.sourceRevision, source)
        installLayer(try result.raster.makeLayer(matching: source))
    }

    func reset(_ context: RasterSymbologyContext) async throws -> RasterSymbologySnapshot {
        guard let source = source(for: context) else { throw missingSource() }
        let result = try await client.request("rasterSymbology.reset",
            parameters: RasterSymbologyRequest(source: source, projectXml: projectXML()),
            as: RasterSymbologySnapshotResult.self)
        try requireCurrent(source, allowedRevisions: [source.visualizationRevision])
        try validateReadRevisions(source, previous: result.previousVisualizationRevision,
                                  current: result.visualizationRevision, source: result.sourceRevision)
        cache(result.previousVisualizationRevision, result.visualizationRevision, result.sourceRevision, source)
        return makeSnapshot(result.snapshot)
    }

    func savePalette(_ draft: RasterSymbologyDraft, name: String,
                     context: RasterSymbologyContext) async throws -> [RasterPalette] {
        try beginMutation()
        defer { endMutation() }
        guard let source = source(for: context) else { throw missingSource() }
        let result = try await client.request("rasterSymbology.savePalette",
            parameters: RasterSymbologySavePaletteRequest(source: source, projectXml: projectXML(), draft: draft, name: name),
            as: RasterSymbologyPalettesPayload.self)
        try requireCurrent(source, allowedRevisions: [source.visualizationRevision])
        try validateMutationRevisions(source, previous: result.previousVisualizationRevision,
                                      current: result.visualizationRevision, source: result.sourceRevision)
        try acceptVisualization(result.previousVisualizationRevision, result.visualizationRevision)
        try requireCurrent(source, allowedRevisions: [source.visualizationRevision, result.visualizationRevision])
        cache(result.previousVisualizationRevision, result.visualizationRevision, result.sourceRevision, source)
        return result.palettes
    }

    func deletePalette(_ id: String, context: RasterSymbologyContext) async throws -> [RasterPalette] {
        try beginMutation()
        defer { endMutation() }
        guard let source = source(for: context) else { throw missingSource() }
        let result = try await client.request("rasterSymbology.deletePalette",
            parameters: RasterSymbologyDeletePaletteRequest(source: source, projectXml: projectXML(), paletteID: id),
            as: RasterSymbologyPalettesPayload.self)
        try requireCurrent(source, allowedRevisions: [source.visualizationRevision])
        try validateMutationRevisions(source, previous: result.previousVisualizationRevision,
                                      current: result.visualizationRevision, source: result.sourceRevision)
        try acceptVisualization(result.previousVisualizationRevision, result.visualizationRevision)
        try requireCurrent(source, allowedRevisions: [source.visualizationRevision, result.visualizationRevision])
        cache(result.previousVisualizationRevision, result.visualizationRevision, result.sourceRevision, source)
        return result.palettes
    }

    private func source(for context: RasterSymbologyContext) -> RasterMapSourceDescriptor? {
        guard let id = context.assetID else { return nil }
        return currentSource(id: id, mapID: context.mapID)
    }

    private func currentSource(id: String, mapID: UUID) -> RasterMapSourceDescriptor? {
        let stored = sources().first { $0.id == id && $0.sourceMapID == mapID }
        guard let stored else { return nil }
        let key = cacheKey(stored)
        guard let cached = sourceCache[key], sameSourceIdentity(cached, stored) else { return stored }
        if stored.visualizationRevision == cached.visualizationRevision { return stored.updating(sourceRevision: cached.sourceRevision) }
        if supersededRevisions[key] == stored.visualizationRevision { return cached }
        return stored
    }

    private func cache(_ oldRevision: String, _ newRevision: String, _ sourceRevision: String,
                       _ source: RasterMapSourceDescriptor) {
        let key = cacheKey(source)
        if oldRevision != newRevision { supersededRevisions[key] = oldRevision }
        sourceCache[key] = source.updating(visualizationRevision: newRevision, sourceRevision: sourceRevision)
    }

    private func requireCurrent(_ source: RasterMapSourceDescriptor, allowedRevisions: Set<String>) throws {
        guard let mapID = source.sourceMapID,
              let current = sources().first(where: { $0.id == source.id && $0.sourceMapID == mapID }),
              sameSourceIdentity(source, current), allowedRevisions.contains(current.visualizationRevision) else {
            throw missingSource()
        }
    }

    private func sameSourceIdentity(_ first: RasterMapSourceDescriptor, _ second: RasterMapSourceDescriptor) -> Bool {
        first.id == second.id && first.projectPath == second.projectPath &&
        first.visualizationPath == second.visualizationPath && first.mapIndex == second.mapIndex &&
        first.mapName == second.mapName && first.mapType == second.mapType &&
        first.nodePath == second.nodePath && first.nodeName == second.nodeName &&
        first.mapLayerType == second.mapLayerType && first.filename == second.filename &&
        first.filenameRelative == second.filenameRelative && first.sourcePath == second.sourcePath &&
        first.sourceMapID == second.sourceMapID
    }

    private func validateReadRevisions(_ source: RasterMapSourceDescriptor, previous: String,
                                       current: String, source sourceRevision: String) throws {
        guard sameRevision(previous, source.visualizationRevision), sameRevision(current, previous),
              source.sourceRevision.map({ sameRevision($0, sourceRevision) }) ?? true else {
            throw changedSource()
        }
    }

    private func validateMutationRevisions(_ source: RasterMapSourceDescriptor, previous: String,
                                           current: String, source sourceRevision: String) throws {
        guard sameRevision(previous, source.visualizationRevision),
              source.sourceRevision.map({ sameRevision($0, sourceRevision) }) ?? true else {
            throw changedSource()
        }
    }

    private func sameRevision(_ first: String, _ second: String) -> Bool {
        first.caseInsensitiveCompare(second) == .orderedSame
    }

    private func cacheKey(_ source: RasterMapSourceDescriptor) -> SourceCacheKey {
        SourceCacheKey(id: source.id, mapID: source.sourceMapID, projectPath: source.projectPath,
                       visualizationPath: source.visualizationPath, sourcePath: source.sourcePath)
    }

    private func beginMutation() throws {
        guard !mutationRunning, canBeginMutation() else {
            throw BackendServiceError(code: "busy", message: "A raster symbology change is already running.")
        }
        mutationRunning = true
        onMutationRunningChanged?(true)
    }

    private func endMutation() {
        guard mutationRunning else { return }
        mutationRunning = false
        onMutationRunningChanged?(false)
    }

    private func makeSnapshot(_ payload: RasterSymbologySnapshotPayload) -> RasterSymbologySnapshot {
        .init(draft: payload.draft, palettes: payload.palettes,
              interpolatedSurfaceFillContext: payload.surfaceFillValues.map(InterpolatedSurfaceFillContext.init(colorValues:)))
    }

    private func missingSource() -> BackendServiceError {
        BackendServiceError(code: "notFound", message: "The selected raster layer is no longer available in this map.")
    }

    private func changedSource() -> BackendServiceError {
        BackendServiceError(code: "sourceChanged", message: "The visualization or raster source changed. Refresh the project before editing this layer.")
    }
}
