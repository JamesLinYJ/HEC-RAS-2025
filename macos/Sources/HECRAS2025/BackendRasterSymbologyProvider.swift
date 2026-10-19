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
    let plotOptions: [String: String]
}

private struct RasterPlotOptionChoicePayload: Decodable, Sendable {
    let value: String
    let label: String
}

private struct RasterPlotOptionPayload: Decodable, Sendable {
    let propertyName: String
    let name: String
    let label: String
    let description: String?
    let kind: String
    let value: String
    let enumValues: [RasterPlotOptionChoicePayload]
    let isEnabled: Bool
    let enabledIf: String?
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
    let plotOptions: [RasterPlotOptionPayload]?
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
    let sourceRevision: String?

    init(layer: MapRasterLayer, rasterInfoStats: RasterImportContextSource?,
         sourceRevision: String? = nil) {
        self.layer = layer
        self.rasterInfoStats = rasterInfoStats
        self.sourceRevision = sourceRevision
    }
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
        let gdbSourceRevision: String?
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
        guard let source = currentSource(id: descriptor.id, mapID: mapID),
              sameSourceIdentity(source, descriptor), isReady(source) else {
            throw missingSource()
        }
        if source.gdbSource != nil {
            // File Geodatabase rasters retain their exact connection-string
            // route and directory manifest contract.
            let result = try await client.request("rasterMap.load",
                parameters: RasterSymbologyRequest(source: source, projectXml: try requestProjectXML(for: source)),
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

        let result = try await client.request("map.raster.layer.load",
            parameters: MapRasterLayerLoadRequest(source: source,
                projectXml: try requestProjectXML(for: source), viewport: viewport(mapID)),
            as: MapRasterLayerLoadReply.self)
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
            rasterInfoStats: rasterInfoStats, sourceRevision: result.sourceRevision)
    }

    func snapshot(_ context: RasterSymbologyContext) async throws -> RasterSymbologySnapshot? {
        guard let source = source(for: context) else { return nil }
        let result = try await client.request("rasterSymbology.inspect",
            parameters: RasterSymbologyRequest(source: source, projectXml: try requestProjectXML(for: source)),
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
            parameters: RasterSymbologySelectPaletteRequest(source: source,
                projectXml: try requestProjectXML(for: source), paletteID: id, draft: draft),
            as: RasterSymbologyDraftResult.self)
        try requireCurrent(source, allowedRevisions: [source.visualizationRevision])
        return result.draft
    }

    func histogram(count: Int, forView: Bool, context: RasterSymbologyContext) async throws -> [Double] {
        guard let source = source(for: context) else { throw missingSource() }
        let values = try await client.request("rasterSymbology.histogram",
            parameters: RasterSymbologyHistogramRequest(source: source,
                projectXml: try requestProjectXML(for: source),
                viewport: forView ? viewport(context.mapID) : nil, count: count, forView: forView),
            as: [Double].self)
        try requireCurrent(source, allowedRevisions: [source.visualizationRevision])
        return values
    }

    func apply(_ draft: RasterSymbologyDraft, additionalOptions: [RasterPlotOption],
               context: RasterSymbologyContext) async throws {
        try beginMutation()
        defer { endMutation() }
        guard let source = source(for: context) else { throw missingSource() }
        guard Set(additionalOptions.map(\.id)).count == additionalOptions.count else {
            throw BackendServiceError(code: "invalidInput", message: "Raster plot options contain duplicate source properties.")
        }
        let plotOptions = Dictionary(uniqueKeysWithValues: additionalOptions
            .filter(\.isEnabled).map { ($0.id, $0.value) })
        let result = try await client.request("rasterSymbology.apply",
            parameters: RasterSymbologyApplyRequest(source: source,
                projectXml: try requestProjectXML(for: source), draft: draft,
                plotOptions: plotOptions),
            as: RasterSymbologyApplyPayload.self)
        try requireCurrent(source, allowedRevisions: [source.visualizationRevision])
        try validateMutationRevisions(source, previous: result.previousVisualizationRevision,
                                      current: result.visualizationRevision, source: result.sourceRevision)
        try acceptVisualization(result.previousVisualizationRevision, result.visualizationRevision)
        try requireCommittedMutationSource(source, committedRevision: result.visualizationRevision)
        cache(result.previousVisualizationRevision, result.visualizationRevision, result.sourceRevision, source)
        installLayer(try result.raster.makeLayer(matching: source))
    }

    func reset(_ context: RasterSymbologyContext) async throws -> RasterSymbologySnapshot {
        guard let source = source(for: context) else { throw missingSource() }
        let result = try await client.request("rasterSymbology.reset",
            parameters: RasterSymbologyRequest(source: source, projectXml: try requestProjectXML(for: source)),
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
            parameters: RasterSymbologySavePaletteRequest(source: source,
                projectXml: try requestProjectXML(for: source), draft: draft, name: name),
            as: RasterSymbologyPalettesPayload.self)
        try requireCurrent(source, allowedRevisions: [source.visualizationRevision])
        try validateMutationRevisions(source, previous: result.previousVisualizationRevision,
                                      current: result.visualizationRevision, source: result.sourceRevision)
        try acceptVisualization(result.previousVisualizationRevision, result.visualizationRevision)
        try requireCommittedMutationSource(source, committedRevision: result.visualizationRevision)
        cache(result.previousVisualizationRevision, result.visualizationRevision, result.sourceRevision, source)
        return result.palettes
    }

    func deletePalette(_ id: String, context: RasterSymbologyContext) async throws -> [RasterPalette] {
        try beginMutation()
        defer { endMutation() }
        guard let source = source(for: context) else { throw missingSource() }
        let result = try await client.request("rasterSymbology.deletePalette",
            parameters: RasterSymbologyDeletePaletteRequest(source: source,
                projectXml: try requestProjectXML(for: source), paletteID: id),
            as: RasterSymbologyPalettesPayload.self)
        try requireCurrent(source, allowedRevisions: [source.visualizationRevision])
        try validateMutationRevisions(source, previous: result.previousVisualizationRevision,
                                      current: result.visualizationRevision, source: result.sourceRevision)
        try acceptVisualization(result.previousVisualizationRevision, result.visualizationRevision)
        try requireCommittedMutationSource(source, committedRevision: result.visualizationRevision)
        cache(result.previousVisualizationRevision, result.visualizationRevision, result.sourceRevision, source)
        return result.palettes
    }

    private func source(for context: RasterSymbologyContext) -> RasterMapSourceDescriptor? {
        guard let id = context.assetID else { return nil }
        guard let source = currentSource(id: id, mapID: context.mapID), isReady(source) else { return nil }
        return source
    }

    private func isReady(_ source: RasterMapSourceDescriptor) -> Bool {
        source.gdbSourceContext == nil || source.gdbSource != nil
    }

    private func requestProjectXML(for source: RasterMapSourceDescriptor) throws -> String? {
        let current = projectXML()
        guard source.gdbSourceContext == nil || source.gdbSource != nil else { throw changedSource() }
        guard let gdbSource = source.gdbSource else { return current }
        guard gdbSource.map.projectXml == current else { throw changedSource() }
        return gdbSource.map.projectXml
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

    /// A successful visualization mutation intentionally advances the `.vis`
    /// revision inside the captured GDB map identity as well as on the outer
    /// descriptor. Compare after rebasing only that revision; every map, node,
    /// project, manifest, and source field must still match the request.
    private func requireCommittedMutationSource(_ source: RasterMapSourceDescriptor,
                                                committedRevision: String) throws {
        guard let mapID = source.sourceMapID,
              let current = sources().first(where: { $0.id == source.id && $0.sourceMapID == mapID }),
              sameRevision(current.visualizationRevision, committedRevision),
              sameSourceIdentity(source.updating(visualizationRevision: current.visualizationRevision), current) else {
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
        first.sourceMapID == second.sourceMapID &&
        first.gdbSourceContext == second.gdbSourceContext && first.gdbSource == second.gdbSource
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
                       visualizationPath: source.visualizationPath, sourcePath: source.sourcePath,
                       gdbSourceRevision: source.gdbSource?.source.revision)
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
        let options = (payload.plotOptions ?? []).map { option in
            RasterPlotOption(id: option.propertyName, title: option.label,
                isBoolean: option.kind == "bool", value: option.value,
                choices: option.enumValues.map { RasterPlotOptionChoice(id: $0.value, title: $0.label) },
                isEnabled: option.isEnabled, description: option.description)
        }
        return .init(draft: payload.draft, palettes: payload.palettes,
              interpolatedSurfaceFillContext: payload.surfaceFillValues.map(InterpolatedSurfaceFillContext.init(colorValues:)),
              additionalOptions: options)
    }

    private func missingSource() -> BackendServiceError {
        BackendServiceError(code: "notFound", message: "The selected raster layer is no longer available in this map.")
    }

    private func changedSource() -> BackendServiceError {
        BackendServiceError(code: "sourceChanged", message: "The visualization or raster source changed. Refresh the project before editing this layer.")
    }
}
