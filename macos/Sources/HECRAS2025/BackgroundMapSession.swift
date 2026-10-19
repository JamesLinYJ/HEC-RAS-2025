import Foundation
import Combine
import RASWorkspaceCore

struct BackgroundMapSettings: Codable, Equatable, Sendable {
    var areBackgroundMapsOn = false
    var isOpenStreetMapOn = true
    var isSatelliteImageryOn = false
    var isShadedReliefOn = false
    var osmStyle = "basic"
    var density = 1
    var showLabels = true
    var satelliteOpacity = 1.0
}

struct BackgroundMapCoordinate: Codable, Equatable, Sendable {
    let x: Double
    let y: Double
}

struct BackgroundMapViewport: Codable, Equatable, Sendable {
    let minX: Double
    let minY: Double
    let maxX: Double
    let maxY: Double
    let pixelWidth: Int
    let pixelHeight: Int
}

struct BackgroundMapRenderRequest: Codable, Equatable, Sendable {
    let requestID: String
    let mapID: String
    let projectSessionID: String
    let projectionType: String
    let projectionValue: String
    let viewport: BackgroundMapViewport
    let worldUnitsPerPixel: Double
    let settings: BackgroundMapSettings
}

struct BackgroundMapStyle: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let description: String
    let previewContentType: String?
    let preview: Data?
    let warning: String?
}

struct BackgroundMapStylesRequest: Codable, Sendable {
    let requestID: String
}

struct BackgroundMapStylesResult: Codable, Sendable {
    let requestID: String
    let styles: [BackgroundMapStyle]
    let warning: String?
}

struct BackgroundMapCacheRequest: Codable, Sendable {
    let clear: Bool
}

struct BackgroundMapCacheResult: Codable, Sendable {
    let directory: String
    let bytes: Int64
    let canClear: Bool
    let cleared: Bool
}

struct BackgroundMapRaster: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let source: String
    let width: Int
    let height: Int
    let rgba: Data
    let minX: Double
    let minY: Double
    let maxX: Double
    let maxY: Double
    let opacity: Double
}

struct BackgroundMapPathPart: Codable, Equatable, Sendable {
    let points: [BackgroundMapCoordinate]
    let isClosed: Bool
}

struct BackgroundMapFeature: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let sourceLayer: String
    let styleLayer: String
    let geometryType: String
    let parts: [BackgroundMapPathPart]
    let strokeColor: String?
    let fillColor: String?
    let strokeOpacity: Double
    let fillOpacity: Double
    let strokeWidth: Double
    let lineWidth: Double
    let lineGapWidth: Double
    let isDashed: Bool
    let dash: [Double]
    let zIndex: Int
    let clipPolygon: [BackgroundMapCoordinate]
    let isTranslated: Bool
    let translationX: Double
    let translationY: Double
}

struct BackgroundMapLabel: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let text: String
    let point: BackgroundMapCoordinate?
    let line: [BackgroundMapCoordinate]
    let fontFamily: String?
    let fontSize: Double
    let rotation: Double
    let textColor: String?
    let haloColor: String?
    let haloWidth: Double
    let zIndex: Int
    let bold: Bool
    let italic: Bool
    let maximumWidth: Int
}

struct BackgroundMapSourceStatus: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let state: String
    let message: String?
    let attribution: String?
}

struct BackgroundMapRenderResult: Codable, Sendable {
    let requestID: String
    let mapID: String
    let projectSessionID: String
    let viewport: BackgroundMapViewport
    let rasters: [BackgroundMapRaster]
    let features: [BackgroundMapFeature]
    let labels: [BackgroundMapLabel]
    let sources: [BackgroundMapSourceStatus]
    let osmBackgroundColor: String?
}

struct BackgroundMapSnapshot: Sendable {
    let render: BackgroundMapRenderResult
    let generation: UInt64
}

@MainActor
final class BackgroundMapSession: ObservableObject {
    @Published var settings = BackgroundMapSettings() {
        didSet {
            if oldValue != settings {
                cancelHoveredTileJSON()
                scheduleRender()
            }
        }
    }
    @Published private(set) var snapshot: BackgroundMapSnapshot?
    @Published private(set) var styles: [BackgroundMapStyle] = []
    @Published private(set) var cache: BackgroundMapCacheResult?
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingStyles = false
    @Published private(set) var isClearingCache = false
    @Published private(set) var error: String?
    @Published private(set) var styleError: String?
    @Published private(set) var cacheError: String?

    private let client: BackendProcessClient
    private let renderRequest: @MainActor (BackgroundMapRenderRequest) async throws -> BackgroundMapRenderResult
    private let tileJSONProvider: BackgroundMapTileJsonProvider
    private var renderTask: Task<Void, Never>?
    private var tileJSONTask: Task<BackgroundMapTileJsonResult, any Error>?
    private var generation: UInt64 = 0
    private var tileJSONGeneration: UInt64 = 0
    private var renderNeedsRefresh = false
    private var viewportContext: ViewportContext?
    private var stylesTask: Task<Void, Never>?
    private var cacheTask: Task<Void, Never>?
    private var cacheClearTask: Task<Void, Never>?
    private var stylesGeneration: UInt64 = 0
    private var cacheGeneration: UInt64 = 0

    private struct ViewportContext: Equatable, Sendable {
        let mapID: String
        let projectSessionID: String
        let projectionType: String
        let projectionValue: String
        let viewport: BackgroundMapViewport
        let worldUnitsPerPixel: Double
    }

    init(client: BackendProcessClient? = nil,
         renderRequest: (@MainActor (BackgroundMapRenderRequest) async throws -> BackgroundMapRenderResult)? = nil,
         tileJSONRequest: (@MainActor (BackgroundMapTileJsonRequest) async throws -> BackgroundMapTileJsonResult)? = nil) {
        let resolvedClient = client ?? BackendProcessClient(executableURL: Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/Backend/HECRASBackend"))
        self.client = resolvedClient
        self.renderRequest = renderRequest ?? { request in
            try await resolvedClient.request("map.background.render", parameters: request)
        }
        if let tileJSONRequest {
            self.tileJSONProvider = BackgroundMapTileJsonProvider(request: tileJSONRequest)
        } else {
            self.tileJSONProvider = BackgroundMapTileJsonProvider(client: resolvedClient)
        }
    }

    var canCopyHoveredTileJSON: Bool {
        guard settings.areBackgroundMapsOn, settings.isOpenStreetMapOn,
              let viewportContext else { return false }
        return !viewportContext.projectionType.isEmpty && !viewportContext.projectionValue.isEmpty
    }

    func matchesContext(mapID: UUID, projectSessionID: UUID, projectionType: String,
                        projectionValue: String, viewport: BackgroundMapViewport,
                        worldUnitsPerPixel: Double, settings expectedSettings: BackgroundMapSettings) -> Bool {
        guard let viewportContext else { return false }
        return viewportContext.mapID == mapID.uuidString
            && viewportContext.projectSessionID == projectSessionID.uuidString
            && viewportContext.projectionType == projectionType
            && viewportContext.projectionValue == projectionValue
            && viewportContext.viewport == viewport
            && viewportContext.worldUnitsPerPixel == worldUnitsPerPixel
            && settings == expectedSettings
    }

    /// Fetches the real hovered OSM vector tile and copies its protobuf JSON
    /// only if the map/source/viewport capture is still current on return.
    @discardableResult
    func copyHoveredTileJSON(at clickedWorldPoint: BackgroundMapCoordinate,
                             writeClipboard: @MainActor (String) -> Void) async throws
        -> BackgroundMapTileJsonResult {
        guard let capturedContext = viewportContext else {
            throw BackgroundMapTileJSONError.viewportUnavailable
        }
        guard clickedWorldPoint.x.isFinite, clickedWorldPoint.y.isFinite,
              clickedWorldPoint.x >= capturedContext.viewport.minX,
              clickedWorldPoint.x <= capturedContext.viewport.maxX,
              clickedWorldPoint.y >= capturedContext.viewport.minY,
              clickedWorldPoint.y <= capturedContext.viewport.maxY else {
            throw BackgroundMapTileJSONError.invalidClickedPoint
        }

        cancelHoveredTileJSON()
        let capturedGeneration = tileJSONGeneration
        let capturedSettings = settings
        let capture = BackgroundMapRenderRequest(requestID: UUID().uuidString,
            mapID: capturedContext.mapID, projectSessionID: capturedContext.projectSessionID,
            projectionType: capturedContext.projectionType, projectionValue: capturedContext.projectionValue,
            viewport: capturedContext.viewport, worldUnitsPerPixel: capturedContext.worldUnitsPerPixel,
            settings: capturedSettings)
        let request = BackgroundMapTileJsonRequest(capture: capture, clickedWorldPoint: clickedWorldPoint)
        let provider = tileJSONProvider
        let requestTask = Task { try await provider.load(request) }
        tileJSONTask = requestTask
        defer {
            if tileJSONGeneration == capturedGeneration { tileJSONTask = nil }
        }

        let result = try await withTaskCancellationHandler {
            try await requestTask.value
        } onCancel: {
            requestTask.cancel()
        }
        try Task.checkCancellation()
        guard tileJSONGeneration == capturedGeneration,
              viewportContext == capturedContext,
              settings == capturedSettings else {
            throw CancellationError()
        }
        guard result.capture == capture, result.clickedWorldPoint == clickedWorldPoint,
              result.sourceID == "osm" else {
            throw BackgroundMapTileJSONError.invalidResponse
        }

        switch result.status {
        case "available":
            guard let tile = result.tile, let sourceRevision = result.sourceRevision,
                  let rawJSON = result.rawJson, !rawJSON.isEmpty else {
                throw BackgroundMapTileJSONError.invalidResponse
            }
            guard (0...14).contains(tile.zoom) else {
                throw BackgroundMapTileJSONError.invalidResponse
            }
            let maximumTileIndex = (1 << tile.zoom) - 1
            let validHex = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
            guard (0...maximumTileIndex).contains(tile.column),
                  (0...maximumTileIndex).contains(tile.tmsRow), sourceRevision.count == 64,
                  sourceRevision.unicodeScalars.allSatisfy(validHex.contains),
                  let jsonData = rawJSON.data(using: .utf8),
                  (try? JSONSerialization.jsonObject(with: jsonData)) is [String: Any] else {
                throw BackgroundMapTileJSONError.invalidResponse
            }
            writeClipboard(rawJSON)
        case "disabled", "outsideCoverage":
            guard result.tile == nil, result.sourceRevision == nil, result.rawJson == nil else {
                throw BackgroundMapTileJSONError.invalidResponse
            }
        default:
            throw BackgroundMapTileJSONError.invalidResponse
        }
        return result
    }

    func updateViewport(mapID: UUID, projectSessionID: UUID, projectionType: String,
                        projectionValue: String, viewport: BackgroundMapViewport,
                        worldUnitsPerPixel: Double) {
        guard viewport.pixelWidth > 0, viewport.pixelHeight > 0,
              viewport.minX.isFinite, viewport.minY.isFinite,
              viewport.maxX.isFinite, viewport.maxY.isFinite,
              viewport.maxX > viewport.minX, viewport.maxY > viewport.minY,
              worldUnitsPerPixel.isFinite, worldUnitsPerPixel > 0 else {
            cancelRendering(clearSnapshot: true)
            error = L10n.text("The map viewport is not available for background rendering.")
            return
        }
        let next = ViewportContext(mapID: mapID.uuidString,
            projectSessionID: projectSessionID.uuidString,
            projectionType: projectionType, projectionValue: projectionValue,
            viewport: viewport, worldUnitsPerPixel: worldUnitsPerPixel)
        if next == viewportContext {
            if renderNeedsRefresh { scheduleRender() }
            return
        }
        cancelHoveredTileJSON()
        viewportContext = next
        scheduleRender()
    }

    func refreshStyles() {
        stylesTask?.cancel()
        stylesGeneration &+= 1
        let capturedGeneration = stylesGeneration
        isLoadingStyles = true
        styleError = nil
        let requestID = UUID().uuidString
        let client = self.client
        stylesTask = Task { [weak self] in
            do {
                let result: BackgroundMapStylesResult = try await client.request(
                    "map.background.styles", parameters: BackgroundMapStylesRequest(requestID: requestID))
                try Task.checkCancellation()
                guard let self, self.stylesGeneration == capturedGeneration,
                      result.requestID == requestID else { return }
                self.styles = result.styles
                self.styleError = result.warning
                self.isLoadingStyles = false
            } catch is CancellationError {
                guard let self, self.stylesGeneration == capturedGeneration else { return }
                self.isLoadingStyles = false
            } catch {
                guard let self, self.stylesGeneration == capturedGeneration else { return }
                self.isLoadingStyles = false
                self.styleError = error.localizedDescription
            }
        }
    }

    func refreshCache() {
        guard !isClearingCache else { return }
        cacheTask?.cancel()
        cacheGeneration &+= 1
        let capturedGeneration = cacheGeneration
        cacheError = nil
        let client = self.client
        cacheTask = Task { [weak self] in
            do {
                let result: BackgroundMapCacheResult = try await client.request(
                    "map.background.cache", parameters: BackgroundMapCacheRequest(clear: false))
                try Task.checkCancellation()
                guard let self, self.cacheGeneration == capturedGeneration else { return }
                self.cache = result
            } catch {
                guard let self, self.cacheGeneration == capturedGeneration,
                      !Task.isCancelled else { return }
                self.cacheError = error.localizedDescription
            }
        }
    }

    func clearCache() {
        guard !isClearingCache else { return }
        cancelRendering()
        cacheTask?.cancel()
        cacheTask = nil
        cacheGeneration &+= 1
        let capturedGeneration = cacheGeneration
        isClearingCache = true
        cacheError = nil
        let client = self.client
        cacheClearTask = Task { [weak self] in
            do {
                let result: BackgroundMapCacheResult = try await client.request(
                    "map.background.cache", parameters: BackgroundMapCacheRequest(clear: true))
                try Task.checkCancellation()
                guard let self, self.cacheGeneration == capturedGeneration else { return }
                self.cache = result
                self.isClearingCache = false
                self.cacheClearTask = nil
                if result.cleared { self.scheduleRender() }
            } catch {
                guard let self, self.cacheGeneration == capturedGeneration,
                      !Task.isCancelled else { return }
                self.isClearingCache = false
                self.cacheClearTask = nil
                self.cacheError = error.localizedDescription
            }
        }
    }

    /// Retires every request associated with this map document without
    /// discarding its persisted per-map settings or already loaded metadata.
    func invalidate() {
        cancelHoveredTileJSON()
        generation &+= 1
        stylesGeneration &+= 1
        cacheGeneration &+= 1
        renderTask?.cancel()
        stylesTask?.cancel()
        cacheTask?.cancel()
        cacheClearTask?.cancel()
        renderTask = nil
        stylesTask = nil
        cacheTask = nil
        cacheClearTask = nil
        renderNeedsRefresh = false
        viewportContext = nil
        snapshot = nil
        isLoading = false
        isLoadingStyles = false
        isClearingCache = false
        error = nil
        styleError = nil
        cacheError = nil
    }

    func cancelRendering(clearSnapshot: Bool = false) {
        cancelHoveredTileJSON()
        generation &+= 1
        renderTask?.cancel()
        renderTask = nil
        isLoading = false
        renderNeedsRefresh = true
        if clearSnapshot {
            viewportContext = nil
            snapshot = nil
        }
    }

    private func cancelHoveredTileJSON() {
        tileJSONGeneration &+= 1
        tileJSONTask?.cancel()
        tileJSONTask = nil
    }

    private func scheduleRender() {
        renderTask?.cancel()
        generation &+= 1
        let capturedGeneration = generation
        renderNeedsRefresh = false
        guard settings.areBackgroundMapsOn,
              settings.isOpenStreetMapOn || settings.isSatelliteImageryOn || settings.isShadedReliefOn else {
            isLoading = false
            snapshot = nil
            error = nil
            return
        }
        guard let viewportContext else {
            snapshot = nil
            isLoading = false
            return
        }
        guard !viewportContext.projectionType.isEmpty,
              !viewportContext.projectionValue.isEmpty else {
            snapshot = nil
            isLoading = false
            error = L10n.text("A project projection is required for background maps.")
            return
        }
        let request = BackgroundMapRenderRequest(requestID: UUID().uuidString,
            mapID: viewportContext.mapID, projectSessionID: viewportContext.projectSessionID,
            projectionType: viewportContext.projectionType, projectionValue: viewportContext.projectionValue,
            viewport: viewportContext.viewport, worldUnitsPerPixel: viewportContext.worldUnitsPerPixel,
            settings: settings)
        let renderRequest = self.renderRequest
        error = nil
        isLoading = true
        renderTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(140))
                let result = try await renderRequest(request)
                try Task.checkCancellation()
                guard let self, self.generation == capturedGeneration,
                      self.viewportContext?.mapID == request.mapID,
                      self.viewportContext?.projectSessionID == request.projectSessionID,
                      result.requestID == request.requestID,
                      result.mapID == request.mapID,
                      result.projectSessionID == request.projectSessionID,
                      result.viewport == request.viewport else { return }
                self.snapshot = BackgroundMapSnapshot(render: result, generation: capturedGeneration)
                self.error = nil
                self.isLoading = false
            } catch is CancellationError {
                guard let self, self.generation == capturedGeneration else { return }
                self.isLoading = false
            } catch {
                guard let self, self.generation == capturedGeneration, !Task.isCancelled else { return }
                self.isLoading = false
                self.error = error.localizedDescription
            }
        }
    }
}

private enum BackgroundMapTileJSONError: LocalizedError {
    case viewportUnavailable
    case invalidClickedPoint
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .viewportUnavailable:
            "The map viewport is not available for reading an OSM tile."
        case .invalidClickedPoint:
            "The clicked point is outside the current map viewport."
        case .invalidResponse:
            "The OSM tile service returned an invalid tile JSON response."
        }
    }
}
