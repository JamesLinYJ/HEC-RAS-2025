import Combine
import Foundation
import RASWorkspaceCore

@MainActor
protocol RasterCalculatorBackendProviding {
    func inspect(map: MapTreeMapIdentity) async throws -> RasterCalculatorInspectResult
    func evaluate(map: MapTreeMapIdentity, contextToken: String,
                  recipe: RasterCalculatorRecipe, layerID: String, layerName: String,
                  profileIndex: Int, viewport: RasterMapViewExtent,
                  expectedSources: [RasterCalculatorSourceChoice]) async throws
        -> (RasterCalculatorEvaluateResult, MapRasterLayer)
}

extension BackendRasterCalculatorProvider: RasterCalculatorBackendProviding {}

enum RasterCalculatorSourceRevisionPolicy {
    static func source(for input: RasterCalculatorInput,
                       in sources: [RasterCalculatorSourceChoice]) -> RasterCalculatorSourceChoice? {
        guard !input.sourceID.isEmpty,
              let source = sources.first(where: { $0.id == input.sourceID }),
              source.isAvailable, source.kind == input.kind else { return nil }
        if let mapType = input.mapType, !source.mapTypes.contains(mapType) {
            return nil
        }
        return source
    }

    static func matches(_ input: RasterCalculatorInput,
                        in sources: [RasterCalculatorSourceChoice]) -> Bool {
        source(for: input, in: sources)?.revision == input.sourceRevision
    }

    static func canAdoptCurrentVersion(of input: RasterCalculatorInput,
                                       in sources: [RasterCalculatorSourceChoice]) -> Bool {
        if input.kind == "resultMap" {
            guard let mapType = input.mapType,
                  sources.first(where: { $0.id == input.sourceID })?.mapTypes.contains(mapType) == true else {
                return false
            }
        } else if input.mapType != nil {
            return false
        }
        guard let source = source(for: input, in: sources) else { return false }
        return source.revision != input.sourceRevision
    }

    static func allInputsMatch(_ recipe: RasterCalculatorRecipe,
                               in sources: [RasterCalculatorSourceChoice]) -> Bool {
        recipe.inputs.allSatisfy { matches($0, in: sources) }
    }
}

@MainActor
final class CalculatorLayerRegistry: ObservableObject {
    @Published private(set) var entries: [String: CalculatorMapLayerEntry] = [:]
    var onReferencePointsChanged: (@MainActor (UUID, [MapPoint]) -> Void)?
    private var nextOrder = 0

    func layers(mapID: UUID, projectSessionID: UUID, workflowIdentity: String) -> [CalculatorMapLayerEntry] {
        entries.values.filter {
            $0.mapID == mapID && $0.projectSessionID == projectSessionID
                && $0.mapWorkflowIdentity == workflowIdentity && $0.isVisible
        }.sorted { $0.order < $1.order }
    }

    func allLayers(mapID: UUID, projectSessionID: UUID, workflowIdentity: String) -> [CalculatorMapLayerEntry] {
        entries.values.filter {
            $0.mapID == mapID && $0.projectSessionID == projectSessionID
                && $0.mapWorkflowIdentity == workflowIdentity
        }.sorted { $0.order < $1.order }
    }

    func allLayers(mapID: UUID, projectSessionID: UUID, mapType: String) -> [CalculatorMapLayerEntry] {
        entries.values.filter {
            $0.mapID == mapID && $0.projectSessionID == projectSessionID
                && $0.mapCapture.mapID.caseInsensitiveCompare(mapID.uuidString) == .orderedSame
                && $0.mapCapture.mapType == mapType
        }.sorted { $0.order < $1.order }
    }

    func entry(id: String, mapID: UUID, projectSessionID: UUID, workflowIdentity: String) -> CalculatorMapLayerEntry? {
        guard let value = entries[id], value.mapID == mapID,
              value.projectSessionID == projectSessionID,
              value.mapWorkflowIdentity == workflowIdentity else { return nil }
        return value
    }

    func add(_ entry: CalculatorMapLayerEntry) {
        guard entries[entry.id] == nil else { return }
        var value = entry
        value.order = nextOrder
        value.frameRevision = 1
        nextOrder += 1
        entries[value.id] = value
        publishReferencePoints(for: value.mapID)
    }

    /// Rebind transient calculator layers to a new request capture without
    /// treating ordinary project/.vis revisions as a different map owner.
    /// The project session and the persisted map id/type define ownership;
    /// the workflow identity only fences asynchronous request generations.
    func refreshMapCapture(mapID: UUID, projectSessionID: UUID,
                           mapCapture: MapTreeMapIdentity?, workflowIdentity: String,
                           viewport: RasterMapViewExtent?) {
        guard let mapCapture else {
            removeAll(mapID: mapID)
            return
        }
        guard mapCapture.mapID.caseInsensitiveCompare(mapID.uuidString) == .orderedSame else {
            removeAll(mapID: mapID)
            return
        }
        let currentEntries = allEntries(mapID: mapID)
        guard !currentEntries.isEmpty else { return }

        guard currentEntries.allSatisfy({ entry in
            entry.projectSessionID == projectSessionID
                && entry.mapID == mapID
                && Self.sameStableMapOwner(entry.mapCapture, mapCapture)
        }) else {
            removeAll(mapID: mapID)
            return
        }

        guard currentEntries.contains(where: {
            $0.mapWorkflowIdentity != workflowIdentity || $0.mapCapture != mapCapture
        }) else { return }

        for oldEntry in currentEntries {
            guard var entry = entries[oldEntry.id], entry.renderer === oldEntry.renderer else { continue }
            entry.mapCapture = mapCapture
            entry.mapWorkflowIdentity = workflowIdentity
            entry.layer = nil
            entry.sourceExtent = nil
            entry.isRendering = true
            entry.renderError = nil
            entries[entry.id] = entry
            let renderer = entry.renderer
            renderer.rebase(map: mapCapture, workflowIdentity: workflowIdentity,
                profileIndex: entry.selectedProfileIndex, viewport: viewport) { [weak self] inspection, profiles, sourcesMatch in
                    guard let self, var current = self.entry(id: entry.id, mapID: mapID,
                            projectSessionID: projectSessionID, workflowIdentity: workflowIdentity),
                          current.renderer === renderer,
                          current.mapCapture == mapCapture else { return }
                    current.contextToken = inspection.contextToken
                    current.sources = inspection.sources
                    if sourcesMatch {
                        current.profiles = profiles
                    }
                    self.entries[entry.id] = current
                } onFrame: { [weak self] layer, sourceExtent in
                    guard let self else { return }
                    self.installRenderedFrame(layer, sourceExtent: sourceExtent, id: entry.id,
                        mapID: mapID, projectSessionID: projectSessionID,
                        workflowIdentity: workflowIdentity, renderer: renderer)
                } onFailure: { [weak self] message in
                    guard let self, var current = self.entry(id: entry.id, mapID: mapID,
                            projectSessionID: projectSessionID, workflowIdentity: workflowIdentity),
                          current.renderer === renderer,
                          current.mapCapture == mapCapture else { return }
                    current.layer = nil
                    current.sourceExtent = nil
                    current.isRendering = false
                    current.renderError = message
                    self.entries[entry.id] = current
                    self.publishReferencePoints(for: mapID)
                }
        }
        publishReferencePoints(for: mapID)
    }

    @discardableResult
    func replace(id: String, with entry: CalculatorMapLayerEntry) -> Bool {
        guard var current = entries[id], current.mapID == entry.mapID,
              current.projectSessionID == entry.projectSessionID,
              current.mapWorkflowIdentity == entry.mapWorkflowIdentity,
              current.isDynamic == entry.isDynamic else { return false }
        current.name = entry.name
        current.recipe = entry.recipe
        current.layer = entry.layer
        current.profiles = entry.profiles
        current.selectedProfileIndex = entry.selectedProfileIndex
        current.contextToken = entry.contextToken
        current.sources = entry.sources
        current.sourceExtent = entry.sourceExtent
        current.mapCapture = entry.mapCapture
        current.mapWorkflowIdentity = entry.mapWorkflowIdentity
        current.renderer.replace(map: entry.mapCapture,
            workflowIdentity: entry.mapWorkflowIdentity, recipe: entry.recipe, layerName: entry.name,
            contextToken: entry.contextToken, sources: entry.sources,
            profiles: entry.profiles, isDynamic: entry.isDynamic)
        current.isRendering = false
        current.renderError = nil
        current.frameRevision += 1
        entries[id] = current
        publishReferencePoints(for: current.mapID)
        return true
    }

    func setVisible(_ visible: Bool, id: String, mapID: UUID,
                    projectSessionID: UUID, workflowIdentity: String) {
        guard var entry = entry(id: id, mapID: mapID, projectSessionID: projectSessionID,
                                workflowIdentity: workflowIdentity) else { return }
        guard entry.isVisible != visible else { return }
        entry.isVisible = visible
        entries[id] = entry
        publishReferencePoints(for: mapID)
    }

    func remove(id: String, mapID: UUID, projectSessionID: UUID, workflowIdentity: String) {
        guard let entry = entry(id: id, mapID: mapID, projectSessionID: projectSessionID,
                                workflowIdentity: workflowIdentity) else { return }
        entry.renderer.invalidate()
        entries.removeValue(forKey: id)
        publishReferencePoints(for: mapID)
    }

    @discardableResult
    func installRenderedFrame(_ layer: MapRasterLayer, sourceExtent: MapSourceRasterBounds,
                              id: String, mapID: UUID, projectSessionID: UUID,
                              workflowIdentity: String,
                              renderer: CalculatorLayerRenderCoordinator) -> Bool {
        guard sourceExtent.isFiniteAndOrdered,
              var current = entry(id: id, mapID: mapID, projectSessionID: projectSessionID,
                  workflowIdentity: workflowIdentity),
              current.renderer === renderer,
              current.mapCapture == renderer.mapCapture,
              current.mapWorkflowIdentity == renderer.captureWorkflowIdentity else { return false }
        current.layer = layer
        current.sourceExtent = sourceExtent
        current.isRendering = false
        current.renderError = nil
        current.frameRevision += 1
        entries[id] = current
        publishReferencePoints(for: mapID)
        return true
    }

    func selectProfile(_ index: Int, id: String, viewport: RasterMapViewExtent,
                       mapID: UUID, projectSessionID: UUID, workflowIdentity: String) {
        guard var entry = entry(id: id, mapID: mapID, projectSessionID: projectSessionID,
                                workflowIdentity: workflowIdentity),
              entry.isDynamic, entry.profiles.indices.contains(index) else { return }
        entry.selectedProfileIndex = index
        entry.isRendering = true
        entry.renderError = nil
        entry.layer = nil
        entries[id] = entry
        let renderer = entry.renderer
        renderer.render(profileIndex: index, viewport: viewport) { [weak self] layer, sourceExtent in
            guard let self else { return }
            self.installRenderedFrame(layer, sourceExtent: sourceExtent, id: id,
                mapID: mapID, projectSessionID: projectSessionID,
                workflowIdentity: workflowIdentity, renderer: renderer)
        } onFailure: { [weak self] in
            guard let self, var current = self.entry(id: id, mapID: mapID,
                    projectSessionID: projectSessionID, workflowIdentity: workflowIdentity),
                  current.renderer === renderer else { return }
            current.isRendering = false
            current.layer = nil
            current.renderError = L10n.text("Could not render this calculator layer for the current map view.")
            self.entries[id] = current
        }
    }

    func updateViewport(_ viewport: RasterMapViewExtent, mapID: UUID,
                        projectSessionID: UUID, workflowIdentity: String) {
        for entry in allLayers(mapID: mapID, projectSessionID: projectSessionID,
                               workflowIdentity: workflowIdentity) {
            guard var pending = self.entry(id: entry.id, mapID: mapID,
                    projectSessionID: projectSessionID, workflowIdentity: workflowIdentity) else { continue }
            pending.isRendering = true
            pending.renderError = nil
            pending.layer = nil
            entries[entry.id] = pending
            entry.renderer.render(profileIndex: entry.selectedProfileIndex, viewport: viewport) { [weak self] layer, sourceExtent in
                guard let self else { return }
                self.installRenderedFrame(layer, sourceExtent: sourceExtent, id: entry.id,
                    mapID: mapID, projectSessionID: projectSessionID,
                    workflowIdentity: workflowIdentity, renderer: entry.renderer)
            } onFailure: { [weak self] in
                guard let self, var current = self.entry(id: entry.id, mapID: mapID,
                        projectSessionID: projectSessionID, workflowIdentity: workflowIdentity),
                      current.renderer === entry.renderer else { return }
                current.isRendering = false
                current.layer = nil
                current.renderError = L10n.text("Could not render this calculator layer for the current map view.")
                self.entries[entry.id] = current
            }
        }
    }

    func removeAll(mapID: UUID? = nil, projectSessionID: UUID? = nil) {
        let removed = entries.values.filter { entry in
            (mapID == nil || entry.mapID == mapID)
                && (projectSessionID == nil || entry.projectSessionID == projectSessionID)
        }
        for entry in removed { entry.renderer.invalidate() }
        let affectedMapIDs = Set(removed.map(\.mapID))
        for entry in removed { entries.removeValue(forKey: entry.id) }
        for mapID in affectedMapIDs { publishReferencePoints(for: mapID) }
    }

    func synchronizeOwners(projectSessionID: UUID, mapTypes: [UUID: String]) {
        let stale = entries.values.filter { entry in
            guard entry.projectSessionID == projectSessionID,
                  mapTypes[entry.mapID] == entry.mapCapture.mapType,
                  entry.mapCapture.mapID.caseInsensitiveCompare(entry.mapID.uuidString) == .orderedSame else {
                return true
            }
            return false
        }
        for entry in stale { entry.renderer.invalidate() }
        let affectedMapIDs = Set(stale.map(\.mapID))
        for entry in stale { entries.removeValue(forKey: entry.id) }
        for mapID in affectedMapIDs { publishReferencePoints(for: mapID) }
    }

    private func publishReferencePoints(for mapID: UUID) {
        let points = entries.values
            .filter { $0.mapID == mapID && $0.isVisible && ($0.sourceExtent?.isFiniteAndOrdered ?? false) }
            .sorted { $0.order < $1.order }
            .flatMap(\.referencePoints)
        onReferencePointsChanged?(mapID, points)
    }

    private func allEntries(mapID: UUID) -> [CalculatorMapLayerEntry] {
        entries.values.filter { $0.mapID == mapID }.sorted { $0.order < $1.order }
    }

    private static func sameStableMapOwner(_ lhs: MapTreeMapIdentity, _ rhs: MapTreeMapIdentity) -> Bool {
        lhs.mapID.caseInsensitiveCompare(rhs.mapID) == .orderedSame
            && lhs.mapType == rhs.mapType
    }
}

@MainActor
struct CalculatorMapLayerEntry: Identifiable {
    let id: String
    let mapID: UUID
    let projectSessionID: UUID
    var mapWorkflowIdentity: String
    var mapCapture: MapTreeMapIdentity
    var name: String
    var recipe: RasterCalculatorRecipe
    var layer: MapRasterLayer?
    var sourceExtent: MapSourceRasterBounds?
    var profiles: [RasterCalculatorProfile]
    var selectedProfileIndex: Int
    var isDynamic: Bool
    var isVisible: Bool
    var isRendering = false
    var renderError: String?
    var frameRevision = 0
    var order = 0
    var contextToken: String
    var sources: [RasterCalculatorSourceChoice]
    let renderer: CalculatorLayerRenderCoordinator
}

@MainActor
final class CalculatorLayerRenderCoordinator {
    private weak var store: WorkspaceStore?
    private let provider: any RasterCalculatorBackendProviding
    private var map: MapTreeMapIdentity
    private let mapID: UUID
    private let projectSessionID: UUID
    private var mapWorkflowIdentity: String
    private let layerID: String
    private var layerName: String
    private var recipe: RasterCalculatorRecipe
    private var contextToken: String
    private var sources: [RasterCalculatorSourceChoice]
    private var profiles: [RasterCalculatorProfile]
    private var isDynamic: Bool
    private var generation = 0
    private var task: Task<Void, Never>?
    private var captureInspected = true
    private var pendingViewport: RasterMapViewExtent?

    init(store: WorkspaceStore, provider: any RasterCalculatorBackendProviding,
         map: MapTreeMapIdentity, mapID: UUID, projectSessionID: UUID,
         mapWorkflowIdentity: String, layerID: String, layerName: String,
         recipe: RasterCalculatorRecipe, contextToken: String,
         sources: [RasterCalculatorSourceChoice], profiles: [RasterCalculatorProfile],
         isDynamic: Bool) {
        self.store = store
        self.provider = provider
        self.map = map
        self.mapID = mapID
        self.projectSessionID = projectSessionID
        self.mapWorkflowIdentity = mapWorkflowIdentity
        self.layerID = layerID
        self.layerName = layerName
        self.recipe = recipe
        self.contextToken = contextToken
        self.sources = sources
        self.profiles = profiles
        self.isDynamic = isDynamic
    }

    var mapCapture: MapTreeMapIdentity { map }
    var captureWorkflowIdentity: String { mapWorkflowIdentity }

    func replace(map: MapTreeMapIdentity, workflowIdentity: String,
                 recipe: RasterCalculatorRecipe, layerName: String,
                 contextToken: String, sources: [RasterCalculatorSourceChoice],
                 profiles: [RasterCalculatorProfile], isDynamic: Bool) {
        generation += 1
        task?.cancel()
        self.map = map
        self.mapWorkflowIdentity = workflowIdentity
        captureInspected = true
        self.recipe = recipe
        self.layerName = layerName
        self.contextToken = contextToken
        self.sources = sources
        self.profiles = profiles
        self.isDynamic = isDynamic
    }

    func invalidate() {
        generation += 1
        task?.cancel()
        task = nil
    }

    func render(profileIndex: Int, viewport: RasterMapViewExtent,
                onFrame: @escaping @MainActor (MapRasterLayer, MapSourceRasterBounds) -> Void,
                onFailure: @escaping @MainActor () -> Void) {
        guard captureInspected else {
            pendingViewport = viewport
            return
        }
        guard inputsMatchCurrentSources(),
              profileIndex >= 0, profileIndex < max(1, profiles.count), ownerIsCurrent() else {
            onFailure()
            return
        }
        generation += 1
        let requestGeneration = generation
        task?.cancel()
        task = Task { [weak self] in
            guard let self else { return }
            await renderCaptured(profileIndex: profileIndex, viewport: viewport,
                requestGeneration: requestGeneration, onFrame: onFrame, onFailure: onFailure)
        }
    }

    func rebase(map: MapTreeMapIdentity, workflowIdentity: String, profileIndex: Int,
                viewport: RasterMapViewExtent?,
                onInspection: @escaping @MainActor (RasterCalculatorInspectResult, [RasterCalculatorProfile], Bool) -> Void,
                onFrame: @escaping @MainActor (MapRasterLayer, MapSourceRasterBounds) -> Void,
                onFailure: @escaping @MainActor (String) -> Void) {
        generation += 1
        let requestGeneration = generation
        task?.cancel()
        self.map = map
        self.mapWorkflowIdentity = workflowIdentity
        captureInspected = false
        pendingViewport = viewport
        guard ownerIsCurrent() else {
            task = nil
            onFailure(L10n.text("The selected map or project changed. Close Raster Calculator and reopen it for the current map."))
            return
        }
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let inspection = try await provider.inspect(map: map)
                guard isCurrent(requestGeneration) else { return }
                let sourcesMatch = inputsMatch(inspection.sources)
                let refreshedProfiles = Self.profiles(for: recipe, sources: inspection.sources)
                self.contextToken = inspection.contextToken
                self.sources = inspection.sources
                self.captureInspected = true
                onInspection(inspection, refreshedProfiles, sourcesMatch)
                guard sourcesMatch else {
                    onFailure(L10n.text("A source used by this Calculator layer changed. Review the selected inputs before saving."))
                    return
                }
                guard let renderViewport = pendingViewport ?? viewport else {
                    onFailure(L10n.text("Could not render this calculator layer for the current map view."))
                    return
                }
                pendingViewport = nil
                guard profileIndex >= 0, profileIndex < max(1, refreshedProfiles.count),
                      (!isDynamic || refreshedProfiles.indices.contains(profileIndex)) else {
                    onFailure(L10n.text("A source used by this Calculator layer changed. Review the selected inputs before saving."))
                    return
                }
                self.profiles = refreshedProfiles
                await renderCaptured(profileIndex: profileIndex, viewport: renderViewport,
                    requestGeneration: requestGeneration, onFrame: onFrame) { onFailure(L10n.text("Could not render this calculator layer for the current map view.")) }
            } catch {
                guard isCurrent(requestGeneration) else { return }
                captureInspected = false
                onFailure(RasterCalculatorErrorPresentation.text(error.localizedDescription))
            }
        }
    }

    private func renderCaptured(profileIndex: Int, viewport: RasterMapViewExtent,
                                requestGeneration: Int,
                                onFrame: @escaping @MainActor (MapRasterLayer, MapSourceRasterBounds) -> Void,
                                onFailure: @escaping @MainActor () -> Void) async {
        let requestMap = map
        let requestWorkflow = mapWorkflowIdentity
        let requestRecipe = recipe
        let requestContextToken = contextToken
        let requestLayerName = layerName
        let requestSources = sources
        do {
            let (result, layer) = try await provider.evaluate(map: requestMap,
                contextToken: requestContextToken, recipe: requestRecipe, layerID: layerID,
                layerName: requestLayerName, profileIndex: profileIndex,
                viewport: viewport, expectedSources: requestSources)
            guard isCurrent(requestGeneration), map == requestMap,
                  mapWorkflowIdentity == requestWorkflow else { return }
            guard let sourceExtent = result.validatedSourceExtent else {
                onFailure()
                return
            }
            onFrame(layer, sourceExtent)
        } catch {
            guard isCurrent(requestGeneration), map == requestMap,
                  mapWorkflowIdentity == requestWorkflow else { return }
            onFailure()
        }
    }

    private func isCurrent(_ requestGeneration: Int) -> Bool {
        !Task.isCancelled && generation == requestGeneration && ownerIsCurrent()
    }

    private func inputsMatchCurrentSources() -> Bool { inputsMatch(sources) }

    private func inputsMatch(_ candidateSources: [RasterCalculatorSourceChoice]) -> Bool {
        RasterCalculatorSourceRevisionPolicy.allInputsMatch(recipe, in: candidateSources)
    }

    private static func profiles(for recipe: RasterCalculatorRecipe,
                                 sources: [RasterCalculatorSourceChoice]) -> [RasterCalculatorProfile] {
        guard let keyFrame = recipe.inputs.first(where: \.isKeyFrame),
              let source = sources.first(where: { $0.id == keyFrame.sourceID }) else { return [] }
        return source.profileTimes.enumerated().map { RasterCalculatorProfile(index: $0.offset, time: $0.element) }
    }

    private func ownerIsCurrent() -> Bool {
        guard let store else { return false }
        return store.projectSessionID == projectSessionID
            && store.mapIdentityRequest(for: mapID) == map
            && store.mapWorkflowIdentity(mapID) == mapWorkflowIdentity
    }
}

@MainActor
final class RasterCalculatorSession: ObservableObject {
    @Published var recipe = RasterCalculatorRecipe() {
        didSet { if oldValue != recipe { draftRevision += 1 } }
    }
    @Published var layerName = "Calc: " {
        didSet { if oldValue != layerName { draftRevision += 1 } }
    }
    @Published private(set) var inspection: RasterCalculatorInspectResult?
    @Published private(set) var previewLayer: MapRasterLayer?
    @Published private(set) var previewSourceExtent: MapSourceRasterBounds?
    @Published private(set) var profiles: [RasterCalculatorProfile] = []
    @Published private(set) var selectedProfileIndex = 0
    @Published private(set) var isLoading = false
    @Published private(set) var isEvaluating = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var loadErrorMessage: String?
    @Published private(set) var isOutOfDate = false
    @Published private(set) var hasSourceRevisionMismatch = false
    @Published private(set) var isEditingExisting = false
    @Published private(set) var isDynamic = false

    let mapID: UUID
    private weak var store: WorkspaceStore?
    private let provider: any RasterCalculatorBackendProviding
    private let viewportProvider: @MainActor () -> RasterMapViewExtent?
    private let projectSessionID: UUID
    private var mapWorkflowIdentity: String
    private var map: MapTreeMapIdentity
    private let editingLayerID: String?
    private var didLoad = false
    private var operationGeneration = 0
    private var draftRevision = 0
    private var renderedDraftRevision: Int?
    private var renderedProfileIndex: Int?
    private var renderedViewport: RasterMapViewExtent?
    private var layerID = UUID().uuidString.lowercased()

    init(store: WorkspaceStore, mapID: UUID,
         viewport: @escaping @MainActor () -> RasterMapViewExtent?,
         editingLayerID: String? = nil,
         provider: (any RasterCalculatorBackendProviding)? = nil) {
        self.store = store
        self.mapID = mapID
        self.viewportProvider = viewport
        self.provider = provider ?? BackendRasterCalculatorProvider(
            client: (store.modelProvider as? BackendModelProvider)?.client)
        projectSessionID = store.projectSessionID
        mapWorkflowIdentity = store.mapWorkflowIdentity(mapID)
        self.editingLayerID = editingLayerID
        guard let map = store.mapIdentityRequest(for: mapID) else {
            self.map = MapTreeMapIdentity(projectPath: "", projectXml: "", projectXmlSHA: "",
                mapID: mapID.uuidString, mapIndex: -1, mapName: "", mapType: "",
                expectedVisualizationRevision: "")
            isOutOfDate = true
            loadErrorMessage = L10n.text("Open a saved map before using Raster Calculator.")
            return
        }
        self.map = map
        if let editingLayerID,
           let entry = store.calculatorLayerRegistry.entry(id: editingLayerID, mapID: mapID,
               projectSessionID: store.projectSessionID, workflowIdentity: store.mapWorkflowIdentity(mapID)) {
            isEditingExisting = true
            layerID = entry.id
            layerName = entry.name
            recipe = entry.recipe
            profiles = entry.profiles
            selectedProfileIndex = entry.selectedProfileIndex
            isDynamic = entry.isDynamic
            previewSourceExtent = entry.sourceExtent
        } else if editingLayerID != nil {
            isOutOfDate = true
            loadErrorMessage = L10n.text("The selected Calculator layer is no longer available in this map.")
        }
    }

    var sources: [RasterCalculatorSourceChoice] { inspection?.sources ?? [] }
    var noDataBehaviors: [String] { inspection?.noDataBehaviors ?? [] }
    var canEvaluate: Bool {
        inspection != nil && !isLoading && !isEvaluating && !isOutOfDate
            && !recipe.inputs.isEmpty && !recipe.expression.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && RasterCalculatorSourceRevisionPolicy.allInputsMatch(recipe, in: sources)
    }
    var isPreviewCurrent: Bool {
        previewLayer != nil && renderedDraftRevision == draftRevision
            && renderedProfileIndex == selectedProfileIndex
            && renderedViewport == requestedViewport()
            && ownerIsCurrent()
    }

    func load() async {
        guard !didLoad, !isLoading else { return }
        guard refreshForCurrentMap() else { return }
        didLoad = true
        await inspectCurrentCapture()
    }

    func retryLoad() async {
        guard !isLoading, !isEvaluating else { return }
        let captureWasCurrent = ownerIsCurrent()
        guard refreshForCurrentMap() else { return }
        if !captureWasCurrent { return }
        inspection = nil
        clearPreview()
        guard !isOutOfDate else { return }
        didLoad = true
        await inspectCurrentCapture()
    }

    /// Refreshes request identity after ordinary project, asset, or .vis changes.
    /// The stable project-session/map-id/map-type owner retains its editable draft.
    /// Returns false only when that owner no longer exists.
    @discardableResult
    func refreshForCurrentMap() -> Bool {
        guard let store, store.projectSessionID == projectSessionID,
              let currentMap = store.mapIdentityRequest(for: mapID),
              Self.sameStableOwner(currentMap, mapID: mapID, as: map) else {
            invalidateForOwnerChange()
            return false
        }
        let currentWorkflow = store.mapWorkflowIdentity(mapID)
        guard currentMap != map || currentWorkflow != mapWorkflowIdentity else { return true }

        operationGeneration += 1
        let generation = operationGeneration
        map = currentMap
        mapWorkflowIdentity = currentWorkflow
        isOutOfDate = false
        isLoading = didLoad
        isEvaluating = false
        inspection = nil
        hasSourceRevisionMismatch = false
        loadErrorMessage = nil
        errorMessage = nil
        clearPreview()
        if didLoad {
            Task { await inspectCapture(map: currentMap, workflow: currentWorkflow, generation: generation) }
        }
        return true
    }

    private func inspectCurrentCapture() async {
        guard !isOutOfDate else { return }
        operationGeneration += 1
        let generation = operationGeneration
        let capture = map
        let workflow = mapWorkflowIdentity
        isLoading = true
        loadErrorMessage = nil
        await inspectCapture(map: capture, workflow: workflow, generation: generation)
    }

    private func inspectCapture(map capture: MapTreeMapIdentity, workflow: String,
                                generation: Int) async {
        do {
            let response = try await provider.inspect(map: capture)
            guard generation == operationGeneration, map == capture,
                  mapWorkflowIdentity == workflow, ownerIsCurrent() else { return }
            inspection = response
            updateSourceRevisionStatus(using: response.sources)
            if !hasSourceRevisionMismatch, let keyFrame = recipe.inputs.first(where: \.isKeyFrame) {
                if let source = RasterCalculatorSourceRevisionPolicy.source(for: keyFrame,
                    in: response.sources) {
                    profiles = source.profileTimes.enumerated().map {
                        RasterCalculatorProfile(index: $0.offset, time: $0.element)
                    }
                }
            }
            loadErrorMessage = nil
        } catch {
            guard generation == operationGeneration, map == capture,
                  mapWorkflowIdentity == workflow, ownerIsCurrent() else { return }
            loadErrorMessage = RasterCalculatorErrorPresentation.text(error.localizedDescription)
        }
        if generation == operationGeneration { isLoading = false }
    }

    func addInput() {
        let names = Set(recipe.inputs.map { $0.variableName.lowercased() })
        let candidates = (0..<26).map { String(UnicodeScalar(97 + $0)!) }
        let name = candidates.first(where: { !names.contains($0) }) ?? "input\(recipe.inputs.count + 1)"
        recipe.inputs.append(RasterCalculatorInput(variableName: name))
    }

    func removeInput(_ id: UUID) {
        if recipe.inputs.first(where: { $0.id == id })?.isKeyFrame == true {
            selectedProfileIndex = 0
        }
        recipe.inputs.removeAll { $0.id == id }
        synchronizeKeyFrame()
        if let inspection { updateSourceRevisionStatus(using: inspection.sources) }
    }
    func addConstant() { recipe.constants.append(RasterCalculatorConstant()) }
    func removeConstant(_ id: UUID) { recipe.constants.removeAll { $0.id == id } }

    func selectSource(_ sourceID: String, for inputID: UUID) {
        guard let choice = sources.first(where: { $0.id == sourceID }) else { return }
        updateInput(inputID) { input in
            input.sourceID = choice.id
            input.sourceRevision = choice.revision
            input.kind = choice.kind
            input.mapType = choice.mapTypes.first
            input.isKeyFrame = false
            input.forceHorizontal = false
        }
        selectedProfileIndex = 0
        synchronizeKeyFrame(preferredInputID: choice.kind == "resultMap" ? inputID : nil)
    }

    func canAdoptCurrentSourceVersion(for inputID: UUID) -> Bool {
        guard let input = recipe.inputs.first(where: { $0.id == inputID }) else { return false }
        return RasterCalculatorSourceRevisionPolicy.canAdoptCurrentVersion(of: input, in: sources)
    }

    func adoptCurrentSourceVersion(for inputID: UUID) {
        guard let input = recipe.inputs.first(where: { $0.id == inputID }),
              let source = RasterCalculatorSourceRevisionPolicy.source(for: input, in: sources),
              source.revision != input.sourceRevision else { return }
        updateInput(inputID) { $0.sourceRevision = source.revision }
        if input.isKeyFrame {
            profiles = source.profileTimes.enumerated().map {
                RasterCalculatorProfile(index: $0.offset, time: $0.element)
            }
            selectedProfileIndex = min(selectedProfileIndex, max(0, profiles.count - 1))
        }
        clearPreview()
    }

    func setKeyFrame(_ enabled: Bool, inputID: UUID) {
        guard let index = recipe.inputs.firstIndex(where: { $0.id == inputID }),
              recipe.inputs[index].kind == "resultMap", !recipe.inputs[index].sourceID.isEmpty else { return }
        selectedProfileIndex = 0
        if enabled {
            for candidate in recipe.inputs.indices {
                recipe.inputs[candidate].isKeyFrame = candidate == index
            }
        } else {
            recipe.inputs[index].isKeyFrame = false
        }
        synchronizeKeyFrame()
    }

    func updateInput(_ id: UUID, _ update: (inout RasterCalculatorInput) -> Void) {
        guard let index = recipe.inputs.firstIndex(where: { $0.id == id }) else { return }
        update(&recipe.inputs[index])
        if recipe.inputs[index].isKeyFrame {
            recipe.keyFrameVariableName = recipe.inputs[index].variableName
        }
        if let inspection { updateSourceRevisionStatus(using: inspection.sources) }
    }

    func updateConstant(_ id: UUID, _ update: (inout RasterCalculatorConstant) -> Void) {
        guard let index = recipe.constants.firstIndex(where: { $0.id == id }) else { return }
        update(&recipe.constants[index])
    }

    func selectProfile(_ index: Int) async {
        guard profiles.indices.contains(index), selectedProfileIndex != index else { return }
        selectedProfileIndex = index
        let didEvaluate = await evaluate()
        if !didEvaluate {
            // Do not leave pixels from the previous profile visible as though
            // they belonged to the newly selected profile.
            previewLayer = nil
            previewSourceExtent = nil
            renderedDraftRevision = nil
            renderedProfileIndex = nil
            renderedViewport = nil
        }
    }

    func evaluate() async -> Bool {
        guard !isLoading, !isEvaluating, refreshForCurrentMap(), ownerIsCurrent(), let inspection,
              let viewport = requestedViewport(), inspection.contextToken.count == 64 else {
            return false
        }
        guard canEvaluate else {
            errorMessage = L10n.text("Choose one or more valid raster inputs and enter an expression.")
            return false
        }
        let generation = operationGeneration
        let revision = draftRevision
        let profileIndex = selectedProfileIndex
        var wireRecipe = recipe
        wireRecipe.keyFrameVariableName = recipe.inputs.first(where: \.isKeyFrame)?.variableName
        let requestedLayerName = effectiveLayerName
        isEvaluating = true
        errorMessage = nil
        defer { if generation == operationGeneration { isEvaluating = false } }
        do {
            let (response, layer) = try await provider.evaluate(map: map,
                contextToken: inspection.contextToken, recipe: wireRecipe,
                layerID: layerID, layerName: requestedLayerName,
                profileIndex: profileIndex, viewport: viewport,
                expectedSources: inspection.sources)
            guard generation == operationGeneration, revision == draftRevision,
                  profileIndex == selectedProfileIndex, ownerIsCurrent() else { return false }
            guard let sourceExtent = response.validatedSourceExtent else {
                throw BackendServiceError(code: "protocolFailure",
                    message: L10n.text("The Raster Calculator result no longer matches the current inputs."))
            }
            previewLayer = layer
            previewSourceExtent = sourceExtent
            profiles = response.profiles
            selectedProfileIndex = response.selectedProfileIndex
            isDynamic = response.isDynamic
            if recipe.keyFrameVariableName != wireRecipe.keyFrameVariableName {
                recipe.keyFrameVariableName = wireRecipe.keyFrameVariableName
            }
            renderedDraftRevision = draftRevision
            renderedProfileIndex = response.selectedProfileIndex
            renderedViewport = viewport
            return true
        } catch {
            if generation == operationGeneration, revision == draftRevision, ownerIsCurrent() {
                clearPreview()
                errorMessage = RasterCalculatorErrorPresentation.text(error.localizedDescription)
            }
            return false
        }
    }

    func addToMap() async -> Bool {
        guard await evaluateFreshForCommit() else { return false }
        guard isPreviewCurrent, ownerIsCurrent(), let store, let inspection, let previewLayer,
              let sourceExtent = previewSourceExtent else { return false }
        let workflow = mapWorkflowIdentity
        let wireRecipe = normalizedRecipe()
        let targetLayerID = isEditingExisting ? UUID().uuidString.lowercased() : layerID
        let targetLayerName = effectiveLayerName
        guard let layer = reidentified(previewLayer, id: targetLayerID, name: targetLayerName) else {
            errorMessage = L10n.text("Could not create a map layer from the current Raster Calculator preview.")
            return false
        }
        let renderer = CalculatorLayerRenderCoordinator(store: store, provider: provider,
            map: map, mapID: mapID, projectSessionID: projectSessionID,
            mapWorkflowIdentity: workflow, layerID: targetLayerID, layerName: targetLayerName,
            recipe: wireRecipe, contextToken: inspection.contextToken,
            sources: inspection.sources, profiles: profiles,
            isDynamic: isDynamic)
        let entry = CalculatorMapLayerEntry(id: targetLayerID, mapID: mapID,
            projectSessionID: projectSessionID, mapWorkflowIdentity: workflow,
            mapCapture: map,
            name: targetLayerName, recipe: wireRecipe, layer: layer,
            sourceExtent: sourceExtent,
            profiles: profiles, selectedProfileIndex: selectedProfileIndex,
            isDynamic: isDynamic, isVisible: true,
            contextToken: inspection.contextToken, sources: inspection.sources,
            renderer: renderer)
        store.calculatorLayerRegistry.add(entry)
        if !isEditingExisting {
            layerID = UUID().uuidString.lowercased()
        }
        return true
    }

    func saveToExisting() async -> Bool {
        guard isEditingExisting, await evaluateFreshForCommit() else { return false }
        guard isPreviewCurrent, ownerIsCurrent(), let store, let inspection, let previewLayer,
              let sourceExtent = previewSourceExtent,
              let existingLayerID = editingLayerID else { return false }
        let workflow = mapWorkflowIdentity
        let wireRecipe = normalizedRecipe()
        let targetLayerName = effectiveLayerName
        guard let layer = reidentified(previewLayer, id: existingLayerID, name: targetLayerName) else {
            errorMessage = L10n.text("Could not create a map layer from the current Raster Calculator preview.")
            return false
        }
        let renderer = CalculatorLayerRenderCoordinator(store: store, provider: provider,
            map: map, mapID: mapID, projectSessionID: projectSessionID,
            mapWorkflowIdentity: workflow, layerID: existingLayerID, layerName: targetLayerName,
            recipe: wireRecipe, contextToken: inspection.contextToken,
            sources: inspection.sources, profiles: profiles,
            isDynamic: isDynamic)
        let entry = CalculatorMapLayerEntry(id: existingLayerID, mapID: mapID,
            projectSessionID: projectSessionID, mapWorkflowIdentity: workflow,
            mapCapture: map,
            name: targetLayerName, recipe: wireRecipe, layer: layer,
            sourceExtent: sourceExtent,
            profiles: profiles, selectedProfileIndex: selectedProfileIndex,
            isDynamic: isDynamic, isVisible: true,
            contextToken: inspection.contextToken, sources: inspection.sources,
            renderer: renderer)
        guard store.calculatorLayerRegistry.replace(id: existingLayerID, with: entry) else {
            errorMessage = L10n.text("This edit switches between a static and temporal result, which cannot update the existing layer. Add it to the map as a new layer instead.")
            return false
        }
        return true
    }

    private func evaluateFreshForCommit() async -> Bool {
        guard refreshForCurrentMap(), ownerIsCurrent(), !isLoading, !isEvaluating,
              canEvaluate, let requestedViewport = requestedViewport() else {
            if !hasSourceRevisionMismatch, !isLoading, !isEvaluating {
                errorMessage = L10n.text("Choose one or more valid raster inputs and enter an expression.")
            }
            return false
        }

        let capture = map
        let workflow = mapWorkflowIdentity
        let revision = draftRevision
        let profileIndex = selectedProfileIndex
        let wireRecipe = normalizedRecipe()
        let requestedLayerName = effectiveLayerName
        operationGeneration += 1
        let generation = operationGeneration
        isEvaluating = true
        errorMessage = nil
        clearPreview()
        defer { if generation == operationGeneration { isEvaluating = false } }

        do {
            let freshInspection = try await provider.inspect(map: capture)
            guard commitRequestIsCurrent(generation: generation, draftRevision: revision,
                    capture: capture, workflow: workflow, profileIndex: profileIndex,
                    viewport: requestedViewport) else { return false }
            inspection = freshInspection
            updateSourceRevisionStatus(using: freshInspection.sources)
            guard RasterCalculatorSourceRevisionPolicy.allInputsMatch(wireRecipe,
                    in: freshInspection.sources) else {
                errorMessage = L10n.text("The selected source changed. Review and confirm its current version before using this layer.")
                clearPreview()
                return false
            }
            guard let freshViewport = self.requestedViewport(), freshViewport == requestedViewport,
                  freshInspection.contextToken.count == 64 else {
                errorMessage = L10n.text("Could not create a map layer from the current Raster Calculator preview.")
                return false
            }

            let (response, layer) = try await provider.evaluate(map: capture,
                contextToken: freshInspection.contextToken, recipe: wireRecipe,
                layerID: layerID, layerName: requestedLayerName,
                profileIndex: profileIndex, viewport: freshViewport,
                expectedSources: freshInspection.sources)
            guard commitRequestIsCurrent(generation: generation, draftRevision: revision,
                    capture: capture, workflow: workflow, profileIndex: profileIndex,
                    viewport: requestedViewport) else { return false }
            guard let sourceExtent = response.validatedSourceExtent else {
                throw BackendServiceError(code: "protocolFailure",
                    message: L10n.text("The Raster Calculator result no longer matches the current inputs."))
            }

            // Close the inspect/evaluate window before applying an in-memory layer.
            // The backend also verifies its source manifest during evaluation; this
            // final read catches a revision/context change before the registry commit.
            let verifiedInspection = try await provider.inspect(map: capture)
            guard commitRequestIsCurrent(generation: generation, draftRevision: revision,
                    capture: capture, workflow: workflow, profileIndex: profileIndex,
                    viewport: requestedViewport) else { return false }
            inspection = verifiedInspection
            updateSourceRevisionStatus(using: verifiedInspection.sources)
            guard verifiedInspection.contextToken == freshInspection.contextToken,
                  RasterCalculatorSourceRevisionPolicy.allInputsMatch(wireRecipe,
                      in: verifiedInspection.sources) else {
                errorMessage = L10n.text("The selected source changed. Review and confirm its current version before using this layer.")
                clearPreview()
                return false
            }

            if recipe.keyFrameVariableName != wireRecipe.keyFrameVariableName {
                recipe.keyFrameVariableName = wireRecipe.keyFrameVariableName
            }
            previewLayer = layer
            previewSourceExtent = sourceExtent
            profiles = response.profiles
            selectedProfileIndex = response.selectedProfileIndex
            isDynamic = response.isDynamic
            renderedDraftRevision = draftRevision
            renderedProfileIndex = response.selectedProfileIndex
            renderedViewport = freshViewport
            return true
        } catch {
            if commitRequestIsCurrent(generation: generation, draftRevision: revision,
                    capture: capture, workflow: workflow, profileIndex: profileIndex,
                    viewport: requestedViewport) {
                clearPreview()
                errorMessage = RasterCalculatorErrorPresentation.text(error.localizedDescription)
            }
            return false
        }
    }

    private func commitRequestIsCurrent(generation: Int, draftRevision requestedDraftRevision: Int,
                                        capture: MapTreeMapIdentity, workflow: String,
                                        profileIndex: Int, viewport: RasterMapViewExtent) -> Bool {
        !Task.isCancelled && generation == operationGeneration && draftRevision == requestedDraftRevision
            && selectedProfileIndex == profileIndex && map == capture
            && mapWorkflowIdentity == workflow && requestedViewport() == viewport && ownerIsCurrent()
    }

    func invalidate() {
        operationGeneration += 1
        isEvaluating = false
        isLoading = false
    }

    func invalidateForOwnerChange() {
        isOutOfDate = true
        operationGeneration += 1
        isEvaluating = false
        isLoading = false
        errorMessage = nil
        hasSourceRevisionMismatch = false
        inspection = nil
        clearPreview()
        loadErrorMessage = L10n.text("The selected map or project changed. Close Raster Calculator and reopen it for the current map.")
    }

    private func updateSourceRevisionStatus(using sources: [RasterCalculatorSourceChoice]) {
        let wasMismatched = hasSourceRevisionMismatch
        let mismatch = recipe.inputs.contains { input in
            !input.sourceID.isEmpty && !RasterCalculatorSourceRevisionPolicy.matches(input, in: sources)
        }
        hasSourceRevisionMismatch = mismatch
        if mismatch {
            clearPreview()
            errorMessage = L10n.text("The selected source changed. Review and confirm its current version before using this layer.")
        } else if wasMismatched {
            errorMessage = nil
        }
    }

    private func clearPreview() {
        previewLayer = nil
        previewSourceExtent = nil
        renderedDraftRevision = nil
        renderedProfileIndex = nil
        renderedViewport = nil
    }

    private static func sameStableOwner(_ current: MapTreeMapIdentity, mapID: UUID,
                                        as previous: MapTreeMapIdentity) -> Bool {
        current.mapID.caseInsensitiveCompare(mapID.uuidString) == .orderedSame
            && previous.mapID.caseInsensitiveCompare(mapID.uuidString) == .orderedSame
            && current.mapType == previous.mapType
    }

    private func normalizedRecipe() -> RasterCalculatorRecipe {
        var value = recipe
        value.keyFrameVariableName = recipe.inputs.first(where: \.isKeyFrame)?.variableName
        return value
    }

    private func synchronizeKeyFrame(preferredInputID: UUID? = nil) {
        let existingIndex = recipe.inputs.firstIndex {
            $0.isKeyFrame && $0.kind == "resultMap" && !$0.sourceID.isEmpty
        }
        let preferredIndex = preferredInputID.flatMap { preferred in
            recipe.inputs.firstIndex { $0.id == preferred && $0.kind == "resultMap" && !$0.sourceID.isEmpty }
        }
        let selectedIndex = existingIndex ?? preferredIndex ?? recipe.inputs.firstIndex {
            $0.kind == "resultMap" && !$0.sourceID.isEmpty
        }
        for index in recipe.inputs.indices {
            let shouldBeKeyFrame = index == selectedIndex
            if recipe.inputs[index].isKeyFrame != shouldBeKeyFrame {
                recipe.inputs[index].isKeyFrame = shouldBeKeyFrame
            }
        }
        if let selectedIndex {
            let input = recipe.inputs[selectedIndex]
            recipe.keyFrameVariableName = input.variableName
            if let source = sources.first(where: { $0.id == input.sourceID }) {
                profiles = source.profileTimes.enumerated().map {
                    RasterCalculatorProfile(index: $0.offset, time: $0.element)
                }
            } else {
                profiles = []
            }
            selectedProfileIndex = min(selectedProfileIndex, max(0, profiles.count - 1))
        } else {
            recipe.keyFrameVariableName = nil
            profiles = []
            selectedProfileIndex = 0
        }
        isDynamic = selectedIndex != nil
    }

    private var effectiveLayerName: String {
        let value = layerName.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? L10n.text("Calculator Layer") : value
    }

    private func reidentified(_ layer: MapRasterLayer, id: String, name: String) -> MapRasterLayer? {
        try? MapRasterLayer(id: id, name: name, width: layer.width, height: layer.height,
            rgba: layer.rgba, lowerLeft: layer.lowerLeft, upperRight: layer.upperRight,
            opacity: layer.opacity, sourceMapID: layer.sourceMapID)
    }

    private func requestedViewport() -> RasterMapViewExtent? {
        if let viewport = viewportProvider(), isValid(viewport) { return viewport }
        guard let inspection else { return nil }
        let chosen = recipe.inputs.compactMap { input in sources.first(where: { $0.id == input.sourceID }) }
        guard let minX = chosen.map(\.minX).max(), let maxX = chosen.map(\.maxX).min(),
              let minY = chosen.map(\.minY).max(), let maxY = chosen.map(\.maxY).min(),
              minX < maxX, minY < maxY else {
            let first = inspection.sources.first(where: { $0.isAvailable })
            guard let first, first.minX < first.maxX, first.minY < first.maxY else { return nil }
            return RasterMapViewExtent(minX: first.minX, minY: first.minY,
                maxX: first.maxX, maxY: first.maxY, pixelWidth: 512, pixelHeight: 512)
        }
        return RasterMapViewExtent(minX: minX, minY: minY, maxX: maxX, maxY: maxY,
            pixelWidth: 512, pixelHeight: 512)
    }

    private func isValid(_ viewport: RasterMapViewExtent) -> Bool {
        viewport.minX.isFinite && viewport.minY.isFinite && viewport.maxX.isFinite && viewport.maxY.isFinite
            && viewport.minX < viewport.maxX && viewport.minY < viewport.maxY
            && (1...1536).contains(viewport.pixelWidth) && (1...1536).contains(viewport.pixelHeight)
            && viewport.pixelWidth * viewport.pixelHeight <= 2_097_152
    }

    private func ownerIsCurrent() -> Bool {
        guard let store else { return false }
        return store.projectSessionID == projectSessionID
            && store.mapIdentityRequest(for: mapID) == map
            && store.mapWorkflowIdentity(mapID) == mapWorkflowIdentity
    }
}

private extension RasterCalculatorEvaluateResult {
    var validatedSourceExtent: MapSourceRasterBounds? {
        let extent = MapSourceRasterBounds(minX: minX, minY: minY, maxX: maxX, maxY: maxY)
        return extent.isFiniteAndOrdered ? extent : nil
    }
}

private extension CalculatorMapLayerEntry {
    var referencePoints: [MapPoint] {
        guard let sourceExtent else { return [] }
        return [MapPoint(x: sourceExtent.minX, y: sourceExtent.minY),
         MapPoint(x: sourceExtent.maxX, y: sourceExtent.maxY)]
    }
}

@MainActor
extension WorkspaceStore {
    func makeRasterCalculatorSession(mapID: UUID,
        viewport: @escaping @MainActor () -> RasterMapViewExtent?,
        editingLayerID: String? = nil) -> RasterCalculatorSession? {
        guard mapIdentityRequest(for: mapID) != nil,
              modelProvider is BackendModelProvider else { return nil }
        return RasterCalculatorSession(store: self, mapID: mapID,
            viewport: viewport, editingLayerID: editingLayerID)
    }
}
