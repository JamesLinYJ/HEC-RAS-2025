import AppKit
import Combine
import RASWorkspaceCore
import SwiftUI

/// A source-ordered map row with a stable owner key for joining the row to its
/// actual raster/vector/Geometry/Boundary payload. `treeOrdinal` preserves the
/// source preorder; `familyOrder` applies the original reverse-tree category
/// ordering without reordering captures inside an owner session.
struct MapSourceRenderRecord: Identifiable, Hashable, Sendable {
    let mapID: UUID
    let nodeID: String
    let locator: CatalogTreeNodeLocator
    let familyOrder: Int
    let treeOrdinal: Int
    let activeLayerOrdinal: Int?
    let contextIdentity: String
    let payloadKind: String
    var payloadLayerIDs: [String]
    let isChecked: Bool
    let isEffectivelyVisible: Bool
    let isStatic: Bool
    let staticInsertionAfterRaster: Bool

    var id: String { contextIdentity }
    var isActiveAndVisible: Bool { isChecked && isEffectivelyVisible }
}

@MainActor
final class MapState: ObservableObject {
    static let projectMapID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
    let kind: MapDocument.Kind
    let id: UUID
    @Published var scale: CGFloat = 1
    @Published var offset = CGSize.zero
    @Published var hiddenLayers: Set<String> = [] {
        didSet { if oldValue != hiddenLayers { invalidateVectorReference() } }
    }
    @Published private(set) var includedLayerIDs: Set<String> = []
    @Published var showGrid = true
    @Published var showMinimap = true
    @Published var showLegend = true
    @Published var toolID = "select"
    let toolPaletteSession = ToolPaletteSession()
    let profiles = MapProfileSession()
    let backgroundMapSession = BackgroundMapSession()
    let resultSources: MapResultSourcesSession
    let resultMap: MapResultMapSession
    let linkedResults: MapLinkedResultContextSession
    let dynamicProfileOverlay = MapDynamicProfileOverlaySession()
    let projectGeometryMap = ProjectGeometryMapSession()
    let associatedMapLayers = AssociatedMapLayerSession()
    let terrainInputMap = TerrainInputMapSession()
    let mapSelectionMeasurement = MapSelectionMeasurementSession()
    let meshErrors = MapTreeMeshErrorSession()
    @Published var associatedRasterRuntimeOptions: [AssociatedMapLayerRasterRuntimeOption] = []
    let boundaryMap: BoundaryMapSession
    let storedCulvertProfile = StoredCulvertProfileSession()
    @Published var resultSelectionOverrides: [MapResultSelectionOverride] = []
    /// Source-map nodes can reference the same GeoJSON file more than once.
    /// Nil keeps the legacy file-only map behavior; an empty array means the
    /// persisted map currently has no vector nodes.
    @Published var sourceVectorBindings: [MapVectorInstanceBinding]? = nil {
        didSet { if oldValue != sourceVectorBindings { invalidateVectorReference() } }
    }
    @Published var sourceVectorPaths: Set<String>?
    @Published var sourceVectorKinds: [String: Set<String>]?
    @Published private(set) var resultLayers: [MapRasterLayer] = []
    @Published private(set) var persistedResultLegends: [MapLegend] = []
    var resultLegends: [MapLegend] {
        linkedResults.isActive ? linkedResults.legends : persistedResultLegends
    }
    @Published private(set) var sourceMapLayerRows: [SourceMapLayerRow] = []
    var resultSourceIdentity: String?
    var resultSourceSetupGeneration: UInt64 = 0
    /// Invalidates an in-flight Boundary capture preflight when the map or
    /// slot-zero Result context is refreshed independently of the other map
    /// layers.
    var boundaryCaptureGeneration: UInt64 = 0
    /// The source tree also depends on the currently selected Result inside a
    /// MultiResult. This identity is separate from the saved `.vis` map
    /// identity because ResultSelection itself is session state.
    var resultMapIdentity: String?
    let polylineEditor = PolylineMapEditingSession(provider: GeoJSONPolylineMapEditingProvider())
    @Published var selectedLayerID: String? {
        didSet { if oldValue != selectedLayerID { clearVectorFeatureSelection() } }
    }
    @Published var selectedFeatureIdentity: String? {
        didSet {
            if !isUpdatingVectorSelection {
                vectorFeatureSelection.replaceLegacy(selectedFeatureIdentity)
                vectorSelectionOwner = nil
            }
        }
    }
    @Published private(set) var vectorFeatureSelection = MapVectorFeatureSelection()
    var selectedFeatureIdentities: Set<String> { vectorFeatureSelection.identities }
    private var vectorSelectionOwner: MapVectorSelectionOwner?
    private var isUpdatingVectorSelection = false
    @Published var selectedLineIdentity: String?
    @Published var selectedFeatureID: Int?
    /// Exact map-scoped source context used by native legend/tool routing.
    /// Nil is meaningful; consumers must not fall back to another map.
    @Published var selectedSourceContextIdentity: String? {
        didSet {
            synchronizeResultMapSelectionFromSourceContext()
            if oldValue != selectedSourceContextIdentity { sourceContextDidChange?() }
        }
    }
    var sourceContextDidChange: (() -> Void)?
    @Published private var sourceMapRenderRowTemplates: [MapSourceRenderRecord] = [] {
        didSet {
            if selectedSourceContextIdentity.map({ identity in
                sourceMapRenderRows.contains { $0.contextIdentity == identity && $0.isActiveAndVisible }
            }) == false {
                selectedSourceContextIdentity = nil
            }
        }
    }
    var sourceMapRenderRows: [MapSourceRenderRecord] {
        let templates = linkedResults.isActive
            ? sourceMapRenderRowTemplates.filter { !["Result", "MultiResult"].contains($0.payloadKind) }
            : sourceMapRenderRowTemplates
        let sourceRows = templates.map { template in
            var row = template
            switch row.payloadKind {
            case "Result", "MultiResult":
                row.payloadLayerIDs = resultMap.layers(for: row.locator).map(\.id)
            case "Geometry", "ConceptualMesh", "FlowAreaLayer", "CulvertBarrelLayer":
                row.payloadLayerIDs = geometryPayloadIDs(for: row.locator)
            case "Terrain", "NValue", "Classification":
                row.payloadLayerIDs = associatedMapLayers.entries.filter {
                    $0.capture.associationNode == row.locator
                }.compactMap { $0.rasterLayer?.id }
            case "BoundaryCondition":
                row.payloadLayerIDs = boundaryMap.entries.filter {
                    $0.capture.boundaryNode == row.locator
                }.filter { $0.status == .available && !$0.lines.isEmpty }
                    .flatMap { $0.visibleLines.map(\.id) }
            case "WindLayer":
                // The independent Wind context feeds velocity particles and
                // never impersonates its Boundary Condition's line payload.
                row.payloadLayerIDs = []
            default:
                break // GeoJSON and standalone raster IDs are bound from the exact row during capture.
            }
            return row
        }
        guard linkedResults.isActive, let capture = linkedResults.capture else { return sourceRows }
        let identity = linkedResults.sourceContextIdentity ?? capture.id
        let linkedRow = MapSourceRenderRecord(mapID: id, nodeID: identity,
            locator: .init(rootName: "Map Result Context", nodeType: "LinkedResult",
                nodeName: "Linked Results", assetID: capture.anchorPath, mapType: "LinkedResult"),
            familyOrder: 3, treeOrdinal: Int.max, activeLayerOrdinal: 0,
            contextIdentity: identity, payloadKind: "LinkedResult",
            payloadLayerIDs: linkedResults.rasters.map(\.id),
            isChecked: true, isEffectivelyVisible: true, isStatic: false,
            staticInsertionAfterRaster: false)
        return sourceRows + [linkedRow]
    }
    @Published var showsPolylineEditor = false
    @Published var canvasPixelSize = CGSize.zero
    @Published private(set) var referencePoints: [MapPoint]?
    @Published private(set) var referenceRevision = 0
    @Published private(set) var draftVector: MapVectorLayer?
    @Published var vectorStyles: [String: MapVectorStylePresentation] = [:]
    private var polylineSubscription: AnyCancellable?
    var lineStateDidChange: (() -> Void)?
    private var lastLineStateIdentity: String?
    private var resultSourceSubscription: AnyCancellable?
    private var resultMapSubscription: AnyCancellable?
    private var linkedResultsSubscription: AnyCancellable?
    private var resultMapSelectionSubscription: AnyCancellable?
    private var linkedReturnSourceContextIdentity: String?
    private var projectGeometryMapSubscription: AnyCancellable?
    private var projectGeometryMapStateSubscription: AnyCancellable?
    private var meshErrorSubscription: AnyCancellable?
    private var associatedMapLayerSubscription: AnyCancellable?
    private var terrainInputMapSubscription: AnyCancellable?
    private var associatedMapLayerExtentSubscription: AnyCancellable?
    private var boundaryMapSubscription: AnyCancellable?
    private var storedCulvertProfileSubscription: AnyCancellable?
    @Published private(set) var profileVectors: [MapVectorLayer]?
    @Published private(set) var profileRasters: [MapRasterLayer]?
    @Published private(set) var profileRenderRevision = 0
    @Published private var profilePreview: [MapFeature] = []
    @Published var preview: [MapFeature] = []
    var allPreview: [MapFeature] { preview + profilePreview }
    @Published var viewport: ViewportRequest?
    @Published var currentExtent: ViewportRequest?
    init(kind: MapDocument.Kind = .project, id: UUID = MapState.projectMapID,
         resultSourceProvider: (any MapResultChartProvider)? = nil, resultClient: BackendProcessClient? = nil,
         boundaryMapProvider: (any BoundaryMapProvider)? = nil) {
        self.kind = kind; self.id = id
        let effectiveResultClient = resultClient ?? BackendProcessClient(executableURL: Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/Backend/HECRASBackend"))
        resultSources = MapResultSourcesSession(provider: resultSourceProvider ?? BackendMapResultChartProvider())
        resultMap = MapResultMapSession(client: effectiveResultClient)
        linkedResults = MapLinkedResultContextSession(client: effectiveResultClient)
        boundaryMap = BoundaryMapSession(provider: boundaryMapProvider ?? BackendBoundaryMapProvider(client: effectiveResultClient))
        resultSourceSubscription = resultSources.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        resultMapSubscription = resultMap.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        linkedResultsSubscription = linkedResults.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        linkedResults.didRetire = { [weak self] retiredIdentity in
            guard let self else { return }
            let returnIdentity = self.linkedReturnSourceContextIdentity
            self.linkedReturnSourceContextIdentity = nil
            if self.selectedSourceContextIdentity == retiredIdentity {
                self.selectedSourceContextIdentity = returnIdentity
            }
            self.profileRenderRevision += 1
        }
        resultMapSelectionSubscription = resultMap.$selectedNodeID.dropFirst().sink { [weak self] nodeID in
            self?.synchronizeSourceContextFromResultMap(nodeID: nodeID)
        }
        projectGeometryMapStateSubscription = projectGeometryMap.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        meshErrorSubscription = meshErrors.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        terrainInputMapSubscription = terrainInputMap.$features.dropFirst().sink { [weak self] _ in
            guard let self else { return }
            self.referencePoints = nil
            self.referenceRevision += 1
            self.objectWillChange.send()
        }
        associatedMapLayerSubscription = associatedMapLayers.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        boundaryMapSubscription = boundaryMap.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        storedCulvertProfileSubscription = storedCulvertProfile.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        associatedMapLayerExtentSubscription = associatedMapLayers.$sourceExtentRevision.dropFirst().sink { [weak self] _ in
            guard let self else { return }
            self.referencePoints = nil
            self.referenceRevision += 1
        }
        projectGeometryMapSubscription = projectGeometryMap.$cameraExtentRevision.dropFirst().sink { [weak self] _ in
            guard let self else { return }
            self.referencePoints = nil
            self.referenceRevision += 1
        }
        resultMap.didUpdate = { [weak self] layers, legends in self?.installResultLayers(layers, legends: legends) }
        polylineSubscription = polylineEditor.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        polylineEditor.didChange = { [weak self] in
            guard let self else { return }
            self.draftVector = self.polylineEditor.currentMapLayer
            let identity = self.polylineEditor.draftGeneration + "|" + (self.polylineEditor.currentSourceRevision ?? "")
            if self.lastLineStateIdentity != identity {
                self.lastLineStateIdentity = identity
                self.lineStateDidChange?()
            }
        }
    }
    func resetViewport() {
        referencePoints = nil; referenceRevision += 1
        scale = 1; offset = .zero; viewport = nil
        dynamicProfileOverlay.clear()
    }
    private func invalidateVectorReference() {
        referencePoints = nil
        referenceRevision += 1
    }
    func clearVectorFeatureSelection() {
        isUpdatingVectorSelection = true
        vectorFeatureSelection = MapVectorFeatureSelection()
        vectorSelectionOwner = nil
        selectedFeatureIdentity = nil
        selectedFeatureID = nil
        selectedLineIdentity = nil
        isUpdatingVectorSelection = false
    }
    @discardableResult
    func selectVectorFeature(_ feature: MapFeature, in layer: MapVectorLayer,
                             mode: MapVectorSelectionMode, rangeOrder: [String]? = nil) -> Bool {
        guard layer.sourceMapID == nil || layer.sourceMapID == id,
              layer.isSourceVisible, !hiddenLayers.contains(layer.id),
              feature.hasUniqueStableIdentity,
              layer.features.filter({ $0.stableIdentity == feature.stableIdentity }).count == 1 else { return false }
        let owner = MapVectorSelectionOwner(layer)
        if selectedLayerID != layer.id { selectedLayerID = layer.id }
        if let vectorSelectionOwner, vectorSelectionOwner != owner { clearVectorFeatureSelection() }
        var selection = vectorFeatureSelection
        selection.select(feature.stableIdentity, mode: mode,
            available: layer.features.filter(\.hasUniqueStableIdentity).map(\.stableIdentity),
            rangeOrder: rangeOrder)
        isUpdatingVectorSelection = true
        vectorFeatureSelection = selection
        vectorSelectionOwner = owner
        selectedFeatureIdentity = selection.primary
        selectedFeatureID = layer.features.first(where: { $0.stableIdentity == selection.primary })?.id
        selectedLineIdentity = nil
        isUpdatingVectorSelection = false
        return true
    }
    @discardableResult
    func selectVectorFeatures(_ identities: Set<String>, in layer: MapVectorLayer,
                              mode: MapVectorSelectionMode) -> Bool {
        guard layer.sourceMapID == nil || layer.sourceMapID == id,
              layer.isSourceVisible, !hiddenLayers.contains(layer.id) else { return false }
        let grouped = Dictionary(grouping: layer.features, by: \.stableIdentity)
        let ordered = layer.features.filter {
            $0.hasUniqueStableIdentity && grouped[$0.stableIdentity]?.count == 1
        }.map(\.stableIdentity)
        guard identities.isSubset(of: Set(ordered)) else { return false }
        switch mode {
        case .replace, .toggle, .ensureIncluded: break
        case .range, .extendRange: return false
        }
        let owner = MapVectorSelectionOwner(layer)
        if selectedLayerID != layer.id { selectedLayerID = layer.id }
        if let vectorSelectionOwner, vectorSelectionOwner != owner { clearVectorFeatureSelection() }
        var selection = vectorFeatureSelection
        if case .replace = mode { selection.replaceLegacy(nil) }
        let addsBatch = !identities.isSubset(of: selection.identities)
        for identity in ordered where identities.contains(identity) {
            selection.select(identity, mode: mode == .toggle && !addsBatch ? .toggle : .ensureIncluded,
                available: ordered)
        }
        isUpdatingVectorSelection = true
        vectorFeatureSelection = selection
        vectorSelectionOwner = owner
        selectedFeatureIdentity = selection.primary
        selectedFeatureID = layer.features.first(where: { $0.stableIdentity == selection.primary })?.id
        selectedLineIdentity = nil
        isUpdatingVectorSelection = false
        return true
    }

    func selectedVectorFeatureIdentities(in layer: MapVectorLayer) -> Set<String> {
        guard selectedLayerID == layer.id, vectorSelectionOwner == MapVectorSelectionOwner(layer),
              layer.sourceMapID == nil || layer.sourceMapID == id,
              layer.isSourceVisible, !hiddenLayers.contains(layer.id) else { return [] }
        let grouped = Dictionary(grouping: layer.features, by: \.stableIdentity)
        return vectorFeatureSelection.identities.filter {
            grouped[$0]?.count == 1 && grouped[$0]?.first?.hasUniqueStableIdentity == true
        }
    }

    func reconcileVectorFeatureSelection(visibleLayers: [MapVectorLayer]) {
        guard let selectedLayerID else { return }
        let matches = visibleLayers.filter { $0.id == selectedLayerID }
        guard matches.count == 1, let layer = matches.first,
              vectorSelectionOwner == nil || vectorSelectionOwner == MapVectorSelectionOwner(layer) else {
            clearVectorFeatureSelection(); return
        }
        let grouped = Dictionary(grouping: layer.features, by: \.stableIdentity)
        let available = Set(grouped.compactMap { key, features in
            features.count == 1 && features[0].hasUniqueStableIdentity ? key : nil
        })
        var selection = vectorFeatureSelection
        selection.reconcile(available: available)
        isUpdatingVectorSelection = true
        vectorFeatureSelection = selection
        vectorSelectionOwner = MapVectorSelectionOwner(layer)
        selectedFeatureIdentity = selection.primary
        selectedFeatureID = layer.features.first(where: { $0.stableIdentity == selection.primary })?.id
        if selection.identities.isEmpty { selectedLineIdentity = nil }
        isUpdatingVectorSelection = false
    }
    func transformPoints(vectors: [MapVectorLayer], rasters: [MapRasterLayer]) -> [MapPoint] {
        // Camera bounds use source extents, never viewport raster corners.
        referencePoints ?? (self.visibleVectors(vectors).flatMap(\.points)
            + self.rasters(rasters).flatMap(\.points) + projectGeometryMap.visiblePoints
            + associatedMapLayers.sourceReferencePoints + boundaryMap.visiblePoints
            + storedCulvertProfile.visiblePoints
            + terrainInputMap.features.flatMap { $0.points.map { MapPoint(x: $0.x, y: $0.y) } })
    }
    func establishReference(vectors: [MapVectorLayer], rasters: [MapRasterLayer]) {
        guard referencePoints == nil else { return }
        let points = self.visibleVectors(vectors).flatMap(\.points)
            + self.rasters(rasters).flatMap(\.points) + projectGeometryMap.visiblePoints
            + associatedMapLayers.sourceReferencePoints + boundaryMap.visiblePoints
            + storedCulvertProfile.visiblePoints
            + terrainInputMap.features.flatMap { $0.points.map { MapPoint(x: $0.x, y: $0.y) } }
        guard let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
              let minY = points.map(\.y).min(), let maxY = points.map(\.y).max() else { return }
        referencePoints = [.init(x: minX, y: minY), .init(x: maxX, y: maxY)]
    }
    func includeLayer(_ id: String) {
        guard kind == .buildable else { return }
        includedLayerIDs.insert(id)
    }
    func installSourceMapRenderRows(_ rows: [MapSourceRenderRecord]) {
        sourceMapRenderRowTemplates = rows
        if linkedResults.isActive,
           selectedSourceContextIdentity == linkedResults.sourceContextIdentity { return }
        if let selectedSourceContextIdentity,
           !rows.contains(where: { $0.contextIdentity == selectedSourceContextIdentity && $0.isActiveAndVisible }) {
            self.selectedSourceContextIdentity = nil
        }
    }
    func installSourceMapLayerRows(_ rows: [SourceMapLayerRow]) {
        sourceMapLayerRows = rows
    }
    func selectSourceContext(_ identity: String?) {
        guard let identity else { selectedSourceContextIdentity = nil; return }
        if linkedResults.isActive, identity != linkedResults.sourceContextIdentity {
            returnToOriginalMapContext()
        }
        guard let row = sourceMapRenderRows.first(where: {
            $0.contextIdentity == identity && $0.isActiveAndVisible
        }) else { selectedSourceContextIdentity = nil; return }
        selectedSourceContextIdentity = row.contextIdentity
    }
    private func synchronizeResultMapSelectionFromSourceContext() {
        if linkedResults.isActive, selectedSourceContextIdentity == linkedResults.sourceContextIdentity { return }
        guard let selectedSourceContextIdentity,
              let row = sourceMapRenderRows.first(where: { $0.contextIdentity == selectedSourceContextIdentity }),
              ["Result", "MultiResult"].contains(row.payloadKind),
              let active = resultSources.sources?.activeNodes.first(where: { $0.node == row.locator }) else {
            resultMap.clearSelection()
            return
        }
        resultMap.selectNode(active.id)
    }
    private func synchronizeSourceContextFromResultMap(nodeID: String?) {
        guard !linkedResults.isActive else { return }
        guard let nodeID else {
            if let selectedSourceContextIdentity,
               let row = sourceMapRenderRows.first(where: { $0.contextIdentity == selectedSourceContextIdentity }),
               ["Result", "MultiResult"].contains(row.payloadKind) {
                self.selectedSourceContextIdentity = nil
            }
            return
        }
        guard
              let active = resultSources.sources?.activeNodes.first(where: { $0.id == nodeID }),
              let row = sourceMapRenderRows.first(where: {
                  $0.locator == active.node && $0.isActiveAndVisible
              }) else {
            selectedSourceContextIdentity = nil
            return
        }
        if selectedSourceContextIdentity != row.contextIdentity {
            selectedSourceContextIdentity = row.contextIdentity
        }
    }
    private func geometryPayloadIDs(for locator: CatalogTreeNodeLocator) -> [String] {
        projectGeometryMap.sources.compactMap { source in
            guard let snapshot = source.snapshot else { return nil }
            if source.capture.geometryNode == locator { return source.capture.identity }
            let childLocators = [snapshot.topologyState.locator, snapshot.flowAreasState.locator,
                snapshot.culvertsState.locator].compactMap { $0 }
            return childLocators.contains(locator) ? source.capture.identity + "|" + locator.sourceIdentity : nil
        }
    }
    func removeLayer(_ id: String) {
        if selectedLayerID == id { selectedLayerID = nil }
        includedLayerIDs.remove(id); hiddenLayers.remove(id)
        profileVectors?.removeAll { $0.id == id }
        profileRasters?.removeAll { $0.id == id }
        profileRenderRevision += 1
    }
    func containsLayer(_ id: String) -> Bool {
        switch kind {
        case .project, .geometry, .plan: true
        case .buildable: includedLayerIDs.contains(id)
        case .unsupported: false
        }
    }
    func vectors(_ shared: [MapVectorLayer]) -> [MapVectorLayer] {
        let scopedSources = shared.filter { $0.sourceMapID == nil || $0.sourceMapID == id }
        var layers: [MapVectorLayer]
        if let sourceVectorBindings {
            // A binding is a visual map-node instance. Keep its node identity
            // distinct while sourcing geometry, SHA, attributes, and row
            // ordinals from the shared file layer. A pending GeoJSON edit is
            // file-scoped, so every visible instance of that same source sees
            // the same staged geometry and attributes.
            layers = sourceVectorBindings.compactMap { binding in
                let boundPath = SourceFilePaths.canonical(URL(fileURLWithPath: binding.sourcePath))
                guard binding.sourcePath == boundPath else { return nil }
                guard let source = scopedSources.first(where: { SourceFilePaths.canonical($0.url) == boundPath }) else { return nil }
                let staged = draftVector.flatMap { SourceFilePaths.canonical($0.url) == boundPath ? $0 : nil }
                return (staged ?? source).instanced(binding: binding, sourceMapID: id)
            }
        } else {
            // File-only and older map fixtures still use the original path
            // and family projection semantics.
            layers = scopedSources.filter { layer in
                sourceVectorPaths.map { $0.contains(SourceFilePaths.canonical(layer.url)) } ?? self.containsLayer(layer.id)
            }
            if let draftVector, let index = layers.firstIndex(where: { $0.id == draftVector.id }) { layers[index] = draftVector }
            if let sourceVectorKinds {
                layers = layers.map { layer in
                    let kinds = sourceVectorKinds[SourceFilePaths.canonical(layer.url)] ?? []
                    let features = layer.features.filter { feature in
                        switch feature.kind {
                        case .point: return kinds.contains("PointsVector")
                        case .line: return kinds.contains("PolylinesVector")
                        case .polygon: return kinds.contains("PolygonsVector")
                        }
                    }
                    return MapVectorLayer(url: layer.url, features: features, sourceMapID: layer.sourceMapID,
                        sourceRevision: layer.sourceRevision, visualIdentity: layer.visualIdentity,
                        visualName: layer.visualName, isSourceVisible: layer.isSourceVisible,
                        sourceProjectionWKT: layer.sourceProjectionWKT, targetProjectionWKT: layer.targetProjectionWKT)
                }
            }
        }
        let overlays = (profileVectors ?? []).filter { $0.sourceMapID == nil || $0.sourceMapID == id }
        let overlayIDs = Set(overlays.map(\.id))
        layers = layers.filter { !overlayIDs.contains($0.id) } + overlays
        return layers
    }
    /// Vectors available for drawing and spatial extent calculations. Hidden
    /// source nodes remain in `vectors(_:)` for style and layer-list editing.
    func visibleVectors(_ shared: [MapVectorLayer]) -> [MapVectorLayer] {
        vectors(shared).filter { $0.isSourceVisible && !hiddenLayers.contains($0.id) }
    }
    func rasters(_ shared: [MapRasterLayer]) -> [MapRasterLayer] {
        let sharedLayers = shared.filter {
            // Saved map types without editing support still display their
            // already-loaded rasters. Ownership remains scoped to this map;
            // source operations are guarded separately by the map kind.
            ($0.sourceMapID == nil || $0.sourceMapID == id)
                && (kind == .unsupported || self.containsLayer($0.id))
        }
        let profiles = (profileRasters ?? []).filter { $0.sourceMapID == nil || $0.sourceMapID == id }
        let profileIDs = Set(profiles.map(\.id))
        let layers = sharedLayers.filter { !profileIDs.contains($0.id) } + profiles
        let activeResults = linkedResults.isActive ? linkedResults.rasters : resultLayers
        let resultIDs = Set(resultLayers.map(\.id) + activeResults.map(\.id))
        return layers.filter { !resultIDs.contains($0.id) }
            + activeResults.filter { $0.sourceMapID == nil || $0.sourceMapID == id }
    }
    func installResultLayers(_ layers: [MapRasterLayer], legends: [MapLegend]) {
        resultLayers = layers.filter { $0.sourceMapID == id }
        persistedResultLegends = legends.filter { legend in resultLayers.contains { $0.id == legend.id } }
        profileRenderRevision += 1
    }

    @discardableResult
    func activateLinkedResults(_ selection: LinkedResultSelection, capture: MapLinkedResultCapture,
                               projectXML: String, viewport: RasterMapViewExtent?,
                               ownerIsCurrent: @escaping @MainActor () -> Bool) async throws -> Bool {
        guard capture.mapID == id else {
            throw BackendServiceError(code: "sourceChanged", message: L10n.text("The map Result context changed before the linked Results could be activated."))
        }
        let returnContext = linkedResults.isActive ? linkedReturnSourceContextIdentity : selectedSourceContextIdentity
        guard try await linkedResults.activate(selection, capture: capture, projectXML: projectXML,
                                                viewport: viewport, ownerIsCurrent: ownerIsCurrent) else { return false }
        linkedReturnSourceContextIdentity = returnContext
        selectedSourceContextIdentity = linkedResults.sourceContextIdentity
        profileRenderRevision += 1
        return true
    }

    func returnToOriginalMapContext() {
        guard linkedResults.isActive else { return }
        let identity = linkedResults.sourceContextIdentity
        linkedResults.retire()
        if selectedSourceContextIdentity == identity {
            selectedSourceContextIdentity = linkedReturnSourceContextIdentity
        }
        linkedReturnSourceContextIdentity = nil
        profileRenderRevision += 1
    }

    func retireLinkedResultsIfOwnerChanged(mapWorkflowIdentity: String? = nil,
                                           sourceIdentity: String? = nil) {
        guard linkedResults.isActive, let capture = linkedResults.capture else { return }
        if (mapWorkflowIdentity.map { $0 != capture.mapWorkflowIdentity } ?? false)
            || (sourceIdentity.map { $0 != capture.sourceIdentity } ?? false) {
            returnToOriginalMapContext()
        }
    }

    func resultViewportDidChange(_ viewport: RasterMapViewExtent?) {
        if linkedResults.isActive {
            Task { await linkedResults.renderMap(viewport: viewport) }
        } else {
            resultMap.viewportChanged()
        }
    }
    func installProfile(_ update: MapUpdate, isEditing: Bool = false) {
        if let vectorStyles = update.vectorStyles { self.vectorStyles = vectorStyles }
        // Style refreshes are presentation-only. Do not replace current map
        // inputs, previews, selection, viewport, or polyline draft state.
        guard !update.preserveInteractionState else { return }
        let visibleExtent = currentExtent
        if let vectors = update.vectors { profileVectors = vectors }
        if let rasters = update.rasters { profileRasters = rasters }
        if isEditing { preview = update.preview }
        else { profilePreview = update.preview }
        profileRenderRevision += 1
        if let visibleExtent, visibleExtent.isFiniteAndOrdered {
            viewport = ViewportRequest(lowerLeft: visibleExtent.lowerLeft, upperRight: visibleExtent.upperRight, animated: false, padding: 0)
        }
    }
    func clearProfiles() {
        profiles.invalidate(); clearProfileRender()
    }
    func clearProfileRender() {
        let visibleExtent = currentExtent
        profileVectors = nil; profileRasters = nil; profilePreview = []; profileRenderRevision += 1
        dynamicProfileOverlay.clear()
        if let visibleExtent, visibleExtent.isFiniteAndOrdered {
            viewport = .init(lowerLeft: visibleExtent.lowerLeft, upperRight: visibleExtent.upperRight, animated: false, padding: 0)
        }
    }
}

struct ViewShortcut {
    let modifier: String
    let key: String
    static let modifiers = ["None", "Command", "Control", "Option", "Shift"]
    // Retained VirtualKey names stay in .vis; macOS uses KeyEquivalent only
    // for event delivery. Do not replace the persisted names with glyphs.
    private static let namedKeys: [(String, Character)] = [
        ("Space", " "), ("Enter", "\r"), ("Tab", "\t"), ("Escape", "\u{1b}"),
        ("Back", "\u{7f}"), ("Delete", "\u{f728}"), ("Insert", "\u{f727}"),
        ("Up", "\u{f700}"), ("Down", "\u{f701}"), ("Left", "\u{f702}"), ("Right", "\u{f703}"),
        ("Home", "\u{f729}"), ("End", "\u{f72b}"), ("PageUp", "\u{f72c}"), ("PageDown", "\u{f72d}")
    ] + (1...24).map { ("F\($0)", Character(UnicodeScalar(0xf703 + $0)!)) }
    static func decode(_ value: String) -> Self? {
        let parts = value.split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        guard (1...2).contains(parts.count) else { return nil }
        let rawModifier = parts.count == 2 ? parts[0].lowercased() : "none"
        let modifier: String
        switch rawModifier {
        case "none": modifier = "None"
        case "windows", "win", "command": modifier = "Command"
        case "control", "ctrl": modifier = "Control"
        case "menu", "option", "alt": modifier = "Option"
        case "shift": modifier = "Shift"
        default: return nil
        }
        let raw = parts.last!
        let key = raw.hasPrefix("Number") ? String(raw.dropFirst(6)) : raw
        if key.count == 1, key.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) && $0.isASCII }) {
            return Self(modifier: modifier, key: key.uppercased())
        }
        guard let named = namedKeys.first(where: { $0.0.caseInsensitiveCompare(key) == .orderedSame }) else { return nil }
        return Self(modifier: modifier, key: named.0)
    }
    static func recording(_ event: NSEvent) -> Self? {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        let matches: [(NSEvent.ModifierFlags, String)] = [(.command, "Command"), (.control, "Control"), (.option, "Option"), (.shift, "Shift")]
        let modifiers = matches.filter { flags.contains($0.0) }.map(\.1)
        // The source format accepts a single modifier, not a chord of modifiers.
        guard modifiers.count <= 1, let raw = event.charactersIgnoringModifiers, raw.count == 1 else { return nil }
        let character = raw.first!
        let key = namedKeys.first(where: { $0.1 == character })?.0 ?? raw
        return decode((modifiers.first.map { $0 + "+" } ?? "") + key)
    }
    var wireValue: String {
        let originalKey = key.first?.isNumber == true ? "Number" + key : key
        let prefix: String
        switch modifier { case "Command": prefix = "Windows"; case "Option": prefix = "Menu"; case "None": prefix = ""; default: prefix = modifier }
        return prefix.isEmpty ? originalKey : prefix + "+" + originalKey
    }
    var keyboardShortcut: KeyboardShortcut {
        let flags: EventModifiers
        switch modifier { case "Command": flags = .command; case "Control": flags = .control; case "Option": flags = .option; case "Shift": flags = .shift; default: flags = [] }
        let equivalent = Self.namedKeys.first(where: { $0.0 == key })?.1 ?? Character(key.lowercased())
        return KeyboardShortcut(KeyEquivalent(equivalent), modifiers: flags)
    }
}

// ViewViewer/ViewEditor: save the screen extent, rename, delete and jump.
struct SavedViewsSheet: View {
    @ObservedObject var store: WorkspaceStore
    @State private var selection: UUID?
    @State private var name = ""
    @State private var modifier = "Command"
    @State private var key = ""
    private var proposedShortcut: ViewShortcut? { ViewShortcut.decode((modifier == "None" ? "" : modifier + "+") + key) }
    private var selected: SavedMapView? { store.savedViews.first { $0.id == selection } }
    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                VStack(spacing: 0) {
                    List(store.savedViews, selection: $selection) { view in
                        Label(view.name, systemImage: "viewfinder").tag(view.id)
                            .onTapGesture(count: 2) { store.jumpToView(view) }
                            .contextMenu { Button("Zoom") { store.jumpToView(view) }; Button("Delete", role: .destructive) { store.removeSavedView(view.id) } }
                    }.listStyle(.sidebar)
                    HStack {
                        Button(action: store.saveCurrentView) { Label("Save Current View", systemImage: "plus") }.disabled(store.activeMapState.currentExtent == nil || !store.canEditSavedViews)
                        Button(role: .destructive) { if let selection { store.removeSavedView(selection); self.selection = nil } } label: { Label("Delete", systemImage: "minus") }.disabled(selected == nil)
                    }.labelStyle(.iconOnly).padding(10)
                }.frame(minWidth: 180, idealWidth: 220)
                VStack(spacing: 8) {
                    Form {
                        if let selected {
                            Section("Saved View") {
                                TextField("Name", text: $name)
                                LabeledContent("Extent", value: "\(selected.lowerLeft.x.formatted()), \(selected.lowerLeft.y.formatted()) → \(selected.upperRight.x.formatted()), \(selected.upperRight.y.formatted())").textSelection(.enabled)
                                if !selected.shortcut.isEmpty { LabeledContent("Key Bind", value: selected.shortcut).textSelection(.enabled) }
                                Button("Rename") { store.renameSavedView(selected, name: name) }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name == selected.name)
                                Button("Replace with Current Extent") { store.resetSavedView(selected) }.disabled(store.activeMapState.currentExtent == nil)
                                Button("Zoom") { store.jumpToView(selected) }.keyboardShortcut(.defaultAction)
                            }
                            Section("Key Bind") {
                                SavedViewShortcutRecorder(modifier: $modifier, key: $key)
                                    .id(selected.id)
                                Picker("Modifier", selection: $modifier) { ForEach(ViewShortcut.modifiers, id: \.self) { Text(LocalizedStringKey($0)).tag($0) } }
                                TextField("Key", text: $key)
                                HStack {
                                    Button("Set Key Bind") { if let proposedShortcut { store.setViewShortcut(selected, shortcut: proposedShortcut.wireValue) } }.disabled(proposedShortcut == nil)
                                    Button("Clear Key Bind") { store.setViewShortcut(selected, shortcut: "None") }.disabled(selected.shortcut.isEmpty || selected.shortcut == "None")
                                }
                            }
                        } else { ContentUnavailableView("No View Selected", systemImage: "viewfinder", description: Text("Save the current map extent to return to it later.")) }
                    }.formStyle(.grouped).frame(minWidth: 310, maxHeight: .infinity)
                    SavedViewLayerSources(store: store)
                        .frame(height: 150)
                }.frame(minWidth: 310)
            }
            Divider(); HStack { Spacer(); Button("Done") { store.showSavedViews = false }.keyboardShortcut(.cancelAction) }.padding(16)
        }.frame(width: 690, height: 590)
            .onChange(of: selection) { _, _ in loadSelection() }
            .onChange(of: store.savedViews) { _, _ in loadSelection() }
    }
    private func loadSelection() {
        name = selected?.name ?? ""
        let shortcut = selected.flatMap { ViewShortcut.decode($0.shortcut) }
        modifier = shortcut?.modifier ?? "Command"; key = shortcut?.key ?? ""
    }
}

/// Focus belongs to this small native responder only while recording. Command
/// combinations are consumed here rather than invoking the application's menus.
private struct SavedViewShortcutCapture: NSViewRepresentable {
    let receive: (NSEvent) -> Void
    func makeNSView(context: Context) -> CaptureView { CaptureView(receive: receive) }
    func updateNSView(_ view: CaptureView, context: Context) { view.receive = receive }
    final class CaptureView: NSView {
        var receive: (NSEvent) -> Void
        init(receive: @escaping (NSEvent) -> Void) {
            self.receive = receive
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { return nil }
        override var acceptsFirstResponder: Bool { true }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.makeFirstResponder(self)
        }
        override func keyDown(with event: NSEvent) { if !event.isARepeat { receive(event) } }
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard window?.firstResponder === self else { return false }
            keyDown(with: event)
            return true
        }
    }
}

private struct SavedViewShortcutRecorder: View {
    @Binding var modifier: String
    @Binding var key: String
    @State private var recording = false
    @State private var invalidCombination = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button(recording ? "Cancel Recording" : "Record Key Bind") {
                    invalidCombination = false
                    recording.toggle()
                }
                if recording {
                    Label("Press a key combination…", systemImage: "keyboard")
                        .foregroundStyle(.secondary)
                    SavedViewShortcutCapture { event in
                        if event.keyCode == 53 { recording = false; return }
                        guard let shortcut = ViewShortcut.recording(event) else {
                            invalidCombination = true
                            return
                        }
                        modifier = shortcut.modifier
                        key = shortcut.key
                        invalidCombination = false
                        recording = false
                    }
                    .frame(width: 1, height: 1)
                    .accessibilityHidden(true)
                }
            }
            if invalidCombination {
                Label("Use a supported key with one modifier or no modifier.", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }
}

struct SavedViewLayerSources: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject private var mapState: MapState

    init(store: WorkspaceStore) {
        self.store = store
        _mapState = ObservedObject(initialValue: store.activeMapState)
    }

    private var vectors: [MapVectorLayer] { mapState.vectors(store.mapLayers) }
    private var rasters: [MapRasterLayer] { mapState.rasters(store.rasterLayers) }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Current Map Layer Sources").font(.headline)
                    Spacer()
                    Button("Add Map Layer…", action: store.addMapLayer)
                        .disabled(!store.hasProject)
                }
                if vectors.isEmpty && rasters.isEmpty {
                    Text("No map layer sources are loaded.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    List {
                        ForEach(vectors) { layer in
                            layerToggle(id: layer.id, title: layer.name, detail: layer.url.path, symbol: "point.3.connected.trianglepath.dotted", sourceVisible: layer.isSourceVisible)
                        }
                        ForEach(rasters) { layer in
                            layerToggle(id: layer.id, title: layer.name, detail: layer.id, symbol: "square.3.layers.3d")
                        }
                    }
                    .listStyle(.plain)
                }
                Text("Visibility applies to the current map and is not stored with a saved view.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
    }

    private func layerToggle(id: String, title: String, detail: String, symbol: String, sourceVisible: Bool = true) -> some View {
        Toggle(isOn: Binding(
            get: { sourceVisible && !mapState.hiddenLayers.contains(id) },
            set: { isVisible in
                if isVisible { mapState.hiddenLayers.remove(id) }
                else { mapState.hiddenLayers.insert(id) }
            }
        )) {
            HStack(spacing: 8) {
                Image(systemName: symbol).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                    Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
        }
        .toggleStyle(.checkbox)
        .disabled(!sourceVisible)
    }
}
