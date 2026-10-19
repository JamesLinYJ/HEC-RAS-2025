import Combine
import Foundation
import RASWorkspaceCore

@MainActor
final class RasterRGBExportSession: ObservableObject {
    @Published private(set) var capture: RasterRGBExportCapture?
    @Published private(set) var inspection: RasterRGBExportInspection?
    @Published private(set) var preview: RasterRGBExportPreview?
    @Published private(set) var output: RasterRGBExportExecutionResult?
    @Published private(set) var inspecting = false
    @Published private(set) var loadingPreview = false
    @Published private(set) var exporting = false
    @Published private(set) var progress: BackendProgressUpdate?
    @Published var selectedSourceID: String?
    @Published var region: RasterRGBExportRegion = .currentView {
        didSet { preview = nil; output = nil }
    }
    @Published var cellSize = 1.0 {
        didSet { preview = nil; output = nil }
    }
    @Published var plotOptionValues: [String: String] = [:]
    @Published var errorMessage: String?

    private var provider: BackendResultExportProvider?
    private var generation = 0

    var previewKey: String {
        let options = plotOptionValues.keys.sorted().map { "\($0)=\(plotOptionValues[$0] ?? "")" }
            .joined(separator: "&")
        return [capture?.source.id ?? "", capture?.mapWorkflowIdentity ?? "",
                capture.map { String(describing: $0.currentView) } ?? "", region.rawValue,
                String(cellSize), options].joined(separator: "|")
    }

    var previewIsStale: Bool { capture == nil || inspection == nil || preview == nil }

    func availablePlotOption(_ option: RasterRGBExportPlotOption) -> Bool {
        guard let gate = option.enabledIf, !gate.isEmpty else { return option.isEnabled }
        return plotOptionValues[gate]?.lowercased() == "true"
    }

    func selectSource(_ sourceID: String?, store: WorkspaceStore) async {
        generation &+= 1
        let expected = generation
        selectedSourceID = sourceID
        capture = nil
        inspection = nil
        preview = nil
        output = nil
        progress = nil
        plotOptionValues = [:]
        guard let sourceID,
              let source = store.rasterMapSources.first(where: { $0.id == sourceID }),
              let nextCapture = Self.capture(source: source, store: store),
              let client = store.runtimeInfoClient else {
            provider = nil
            if sourceID != nil {
                errorMessage = L10n.text("The selected raster source is no longer available.")
            }
            return
        }
        capture = nextCapture
        provider = BackendResultExportProvider(client: client)
        inspecting = true
        errorMessage = nil
        defer { if generation == expected { inspecting = false } }
        do {
            let reply = try await provider?.inspectRaster(nextCapture)
            guard generation == expected, let reply,
                  Self.isCurrent(nextCapture, store: store) else { return }
            try ResultExportReplyValidation.rasterInspection(reply, source: source)
            inspection = reply
            cellSize = reply.suggestedCellSize ?? 1
            plotOptionValues = Dictionary(uniqueKeysWithValues: reply.plotOptions.map {
                ($0.propertyName, $0.value)
            })
        } catch {
            guard generation == expected else { return }
            errorMessage = error.localizedDescription
        }
    }

    func refreshViewport(store: WorkspaceStore) async {
        guard let selectedSourceID else { return }
        let previousOptions = plotOptionValues
        await selectSource(selectedSourceID, store: store)
        if let inspection {
            for option in inspection.plotOptions where previousOptions[option.propertyName] != nil {
                plotOptionValues[option.propertyName] = previousOptions[option.propertyName]
            }
        }
    }

    func setPlotOption(_ name: String, value: String) {
        plotOptionValues[name] = value
        preview = nil
        output = nil
    }

    func loadPreview(store: WorkspaceStore) async {
        guard let capture, let inspection, let provider,
              Self.validCellSize(cellSize), Self.isCurrent(capture, store: store),
              region != .currentView || capture.currentView != nil else { return }
        let expected = generation
        let expectedPreviewKey = previewKey
        loadingPreview = true
        preview = nil
        errorMessage = nil
        defer { if generation == expected { loadingPreview = false } }
        do {
            let reply = try await provider.previewRaster(capture, inspection: inspection,
                region: region, cellSize: cellSize, plotOptions: activePlotOptions)
            guard generation == expected, previewKey == expectedPreviewKey,
                  Self.isCurrent(capture, store: store) else { return }
            preview = reply
        } catch {
            guard generation == expected else { return }
            preview = nil
            errorMessage = error.localizedDescription
        }
    }

    func export(to outputPath: String, store: WorkspaceStore) async {
        guard let capture, let inspection, let provider,
              Self.validCellSize(cellSize), Self.isCurrent(capture, store: store) else {
            errorMessage = L10n.text("The selected map or raster changed. Refresh the export preview before saving.")
            return
        }
        generation &+= 1
        let expected = generation
        exporting = true
        progress = nil
        output = nil
        errorMessage = nil
        defer { if generation == expected { exporting = false } }
        do {
            let reply = try await provider.exportRaster(capture, inspection: inspection,
                region: region, cellSize: cellSize, outputPath: outputPath,
                plotOptions: activePlotOptions) { [weak self] update in
                    self?.progress = update
                }
            // The backend publishes the output only after an atomic no-clobber
            // commit. Retain its receipt before any subsequent UI work.
            output = reply
            if reply.state == "cancelled" { errorMessage = L10n.text("Export cancelled.") }
            else { preview = nil }
        } catch {
            if generation == expected { errorMessage = error.localizedDescription }
        }
    }

    func cancel() { provider?.cancelActiveExport() }

    func invalidate() {
        generation &+= 1
        provider?.cancelActiveExport()
        provider = nil
        capture = nil
        inspection = nil
        preview = nil
        progress = nil
    }

    private var activePlotOptions: [String: String] {
        guard let inspection else { return [:] }
        return Dictionary(uniqueKeysWithValues: inspection.plotOptions.compactMap { option in
            availablePlotOption(option) ? (option.propertyName, plotOptionValues[option.propertyName] ?? option.value) : nil
        })
    }

    private static func capture(source: RasterMapSourceDescriptor,
                                store: WorkspaceStore) -> RasterRGBExportCapture? {
        guard let mapID = source.sourceMapID,
              let map = store.mapIdentityRequest(for: mapID),
              map.mapID.caseInsensitiveCompare(mapID.uuidString) == .orderedSame,
              map.mapIndex == source.mapIndex, map.mapName == source.mapName,
              map.mapType == source.mapType,
              map.expectedVisualizationRevision.caseInsensitiveCompare(source.visualizationRevision) == .orderedSame else {
            return nil
        }
        let viewport = store.existingMapState(for: mapID).flatMap { ExportMapViewport.make($0.currentExtent) }
        return RasterRGBExportCapture(projectSessionID: store.projectSessionID, mapID: mapID,
            mapWorkflowIdentity: store.mapWorkflowIdentity(mapID), source: source,
            projectXml: map.projectXml, currentView: viewport)
    }

    private static func isCurrent(_ capture: RasterRGBExportCapture,
                                  store: WorkspaceStore) -> Bool {
        guard store.projectSessionID == capture.projectSessionID,
              store.mapWorkflowIdentity(capture.mapID) == capture.mapWorkflowIdentity,
              store.rasterMapSources.contains(capture.source),
              let currentMap = store.mapIdentityRequest(for: capture.mapID),
              currentMap.projectXml == capture.projectXml,
              currentMap.expectedVisualizationRevision.caseInsensitiveCompare(
                capture.source.visualizationRevision) == .orderedSame else { return false }
        let viewport = store.existingMapState(for: capture.mapID).flatMap {
            ExportMapViewport.make($0.currentExtent)
        }
        return viewport == capture.currentView
    }

    private static func validCellSize(_ value: Double) -> Bool { value.isFinite && value > 0 }
}

@MainActor
final class DepthShapefileExportSession: ObservableObject {
    @Published private(set) var capture: DepthShapefileExportCapture?
    @Published private(set) var inspection: DepthShapefileExportInspection?
    @Published private(set) var preview: DepthShapefileExportPreview?
    @Published private(set) var output: DepthShapefileExportExecutionResult?
    @Published private(set) var inspecting = false
    @Published private(set) var loadingPreview = false
    @Published private(set) var exporting = false
    @Published private(set) var progress: BackendProgressUpdate?
    @Published private(set) var selection = DepthShapefileExportSelection()
    @Published var cellSize = 100.0 { didSet { preview = nil; output = nil } }
    @Published var simplifyDistance = 0.05 { didSet { preview = nil; output = nil } }
    @Published var errorMessage: String?

    private let mapID: UUID
    private var provider: BackendResultExportProvider?
    private var generation = 0

    init(mapID: UUID) { self.mapID = mapID }

    var selectedOwner: DepthShapefileExportOwner? {
        guard let ownerID = selection.ownerID else { return nil }
        return inspection?.owners.first(where: { $0.id == ownerID })
    }

    var selectedProfile: DepthShapefileExportProfile? {
        guard let selectedOwner, let profileIndex = selection.profileIndex else { return nil }
        return selectedOwner.profiles.first(where: { $0.index == profileIndex })
    }

    var previewKey: String {
        [capture?.mapWorkflowIdentity ?? "", capture?.contextToken ?? "",
         capture.map { String(describing: $0.viewport) } ?? "", selection.ownerID ?? "",
         String(selection.profileIndex ?? -1), String(cellSize), String(simplifyDistance)]
            .joined(separator: "|")
    }

    func inspect(store: WorkspaceStore) async {
        let previousSelection = selection
        generation &+= 1
        let expected = generation
        capture = nil
        inspection = nil
        preview = nil
        output = nil
        selection = DepthShapefileExportSelection()
        progress = nil
        errorMessage = nil
        guard let client = store.runtimeInfoClient else {
            errorMessage = L10n.text("The Result export service is unavailable.")
            return
        }
        provider = BackendResultExportProvider(client: client)
        inspecting = true
        defer { if generation == expected { inspecting = false } }
        do {
            var nextCapture = Self.capture(mapID: mapID, store: store)
            if nextCapture == nil {
                await store.configureMapResultSources(mapID)
                guard generation == expected else { return }
                nextCapture = Self.capture(mapID: mapID, store: store)
            }
            guard let nextCapture else {
                throw BackendServiceError(code: "sourceChanged", message: L10n.text("The active Result context is not ready. Refresh the map Result sources and try again."))
            }
            capture = nextCapture
            let reply = try await provider?.inspectDepth(nextCapture)
            guard generation == expected, let reply,
                  Self.isCurrent(nextCapture, mapID: mapID, store: store) else { return }
            inspection = reply
            var retainedSelection = previousSelection
            retainedSelection.retainExactOwner(in: reply.owners)
            selection = retainedSelection
            cellSize = reply.defaultCellSize
            simplifyDistance = reply.defaultSimplifyDistance
        } catch {
            guard generation == expected else { return }
            errorMessage = error.localizedDescription
        }
    }

    func refreshViewport(store: WorkspaceStore) async { await inspect(store: store) }

    func chooseOwner(_ id: String?) {
        let owner = id.flatMap { value in inspection?.owners.first(where: { $0.id == value }) }
        selection.selectOwner(owner)
        preview = nil
        output = nil
        errorMessage = nil
    }

    func chooseProfile(_ index: Int?) {
        selection.selectProfile(index, for: inspection?.owners ?? [])
        preview = nil
        output = nil
    }

    func loadPreview(store: WorkspaceStore) async {
        guard let capture, capture.viewport != nil, let provider,
              let selectedOwner, let selectedProfile,
              Self.validParameters(cellSize: cellSize, simplifyDistance: simplifyDistance),
              Self.isCurrent(capture, mapID: mapID, store: store) else { return }
        let expected = generation
        let expectedPreviewKey = previewKey
        loadingPreview = true
        preview = nil
        errorMessage = nil
        defer { if generation == expected { loadingPreview = false } }
        do {
            let reply = try await provider.previewDepth(capture, owner: selectedOwner,
                profile: selectedProfile, cellSize: cellSize, simplifyDistance: simplifyDistance)
            guard generation == expected, previewKey == expectedPreviewKey,
                  selection.ownerID == selectedOwner.id,
                  selection.profileIndex == selectedProfile.index,
                  Self.isCurrent(capture, mapID: mapID, store: store) else { return }
            preview = reply
        } catch {
            guard generation == expected else { return }
            preview = nil
            errorMessage = error.localizedDescription
        }
    }

    func export(to outputPath: String, store: WorkspaceStore) async {
        guard let capture, let provider, let selectedOwner, let selectedProfile,
              Self.validParameters(cellSize: cellSize, simplifyDistance: simplifyDistance),
              Self.isCurrent(capture, mapID: mapID, store: store) else {
            errorMessage = L10n.text("The active map Result, profile, or viewport changed. Refresh the preview before saving.")
            return
        }
        generation &+= 1
        let expected = generation
        exporting = true
        output = nil
        progress = nil
        errorMessage = nil
        defer { if generation == expected { exporting = false } }
        do {
            let reply = try await provider.exportDepth(capture, owner: selectedOwner,
                profile: selectedProfile, cellSize: cellSize,
                simplifyDistance: simplifyDistance, outputPath: outputPath) { [weak self] update in
                    self?.progress = update
                }
            // Preserve the atomic publication receipt even if the map changes
            // while the UI is receiving the terminal duplex frame.
            output = reply
            if reply.state == "cancelled" { errorMessage = L10n.text("Export cancelled.") }
            else { preview = nil }
        } catch {
            if generation == expected { errorMessage = error.localizedDescription }
        }
    }

    func cancel() { provider?.cancelActiveExport() }

    func invalidate() {
        generation &+= 1
        provider?.cancelActiveExport()
        provider = nil
        capture = nil
        inspection = nil
        preview = nil
        progress = nil
    }

    static func capture(mapID: UUID, store: WorkspaceStore) -> DepthShapefileExportCapture? {
        guard let state = store.existingMapState(for: mapID),
              let snapshot = state.resultSources.snapshot,
              let map = store.mapResultRequest(for: mapID),
              snapshot.map == map,
              snapshot.sources.mapID.caseInsensitiveCompare(map.mapID) == .orderedSame,
              snapshot.identity == store.mapWorkflowIdentity(mapID),
              !snapshot.sources.contextToken.isEmpty else { return nil }
        let treeContext = store.sourceMapTreeContext(mapID)
        guard treeContext.projectSessionID == store.projectSessionID,
              treeContext.mapID == mapID, treeContext.resultSelectionError == nil else { return nil }
        let viewport = ExportMapViewport.make(state.currentExtent)
        let treeRequest = ResultExportMapTreeRequest(map: map, treeContext: treeContext)
        return DepthShapefileExportCapture(projectSessionID: store.projectSessionID,
            mapID: mapID, mapWorkflowIdentity: snapshot.identity, map: map,
            mapTree: treeRequest, resultSnapshot: snapshot,
            selectionOverrides: snapshot.selectionOverrides,
            contextToken: snapshot.sources.contextToken, viewport: viewport)
    }

    static func isCurrent(_ capture: DepthShapefileExportCapture,
                          mapID: UUID, store: WorkspaceStore) -> Bool {
        guard mapID == capture.mapID, store.projectSessionID == capture.projectSessionID,
              store.mapWorkflowIdentity(mapID) == capture.mapWorkflowIdentity,
              store.mapResultRequest(for: mapID) == capture.map,
              let state = store.existingMapState(for: mapID),
              let snapshot = state.resultSources.snapshot,
              snapshot.identity == capture.mapWorkflowIdentity,
              snapshot == capture.resultSnapshot,
              snapshot.map == capture.map,
              snapshot.selectionOverrides == capture.selectionOverrides,
              snapshot.sources.contextToken == capture.contextToken,
              ExportMapViewport.make(state.currentExtent) == capture.viewport else { return false }
        let context = store.sourceMapTreeContext(mapID)
        return context.projectSessionID == capture.projectSessionID
            && context.mapID == mapID && context.resultSelectionError == nil
            && ResultExportMapTreeRequest(map: capture.map, treeContext: context) == capture.mapTree
    }

    private static func validParameters(cellSize: Double, simplifyDistance: Double) -> Bool {
        cellSize.isFinite && cellSize > 0 && simplifyDistance.isFinite && simplifyDistance >= 0
    }
}
