import AppKit
import Foundation
import RASWorkspaceCore
import SwiftUI

/// Owner of an interaction is captured from the current map and exact active
/// source row. Reused layer IDs across map/source rows never transfer a live
/// drag or measurement to another context.
struct MapSelectionMeasurementOwner: Equatable, Sendable {
    let projectSessionID: UUID
    let mapID: UUID
    let sourceContextIdentity: String?
    let selectionOwner: MapVectorSelectionOwner?

    @MainActor static func context(projectSessionID: UUID, mapState: MapState) -> Self? {
        let contextIdentity: String?
        if let selected = mapState.selectedSourceContextIdentity {
            let matches = mapState.sourceMapRenderRows.filter {
                $0.mapID == mapState.id && $0.contextIdentity == selected && $0.isActiveAndVisible
            }
            guard matches.count == 1 else { return nil }
            contextIdentity = selected
        } else if let selectedLayerID = mapState.selectedLayerID {
            let rows = mapState.sourceMapRenderRows.filter {
                $0.mapID == mapState.id && $0.isActiveAndVisible && $0.payloadLayerIDs.contains(selectedLayerID)
            }
            contextIdentity = rows.count == 1 ? rows[0].contextIdentity : nil
        } else {
            let rows = mapState.sourceMapRenderRows.filter { $0.mapID == mapState.id && $0.isActiveAndVisible }
            contextIdentity = rows.count == 1 ? rows[0].contextIdentity : nil
        }
        return Self(projectSessionID: projectSessionID, mapID: mapState.id,
                    sourceContextIdentity: contextIdentity, selectionOwner: nil)
    }

    @MainActor static func selection(projectSessionID: UUID, mapState: MapState,
                          layer: MapVectorLayer) -> Self? {
        guard layer.isSourceVisible, !mapState.hiddenLayers.contains(layer.id),
              layer.sourceMapID == nil || layer.sourceMapID == mapState.id else { return nil }
        let rows = mapState.sourceMapRenderRows.filter {
            $0.mapID == mapState.id && $0.isActiveAndVisible && $0.payloadLayerIDs.contains(layer.id)
        }
        let contextIdentity: String?
        if let selected = mapState.selectedSourceContextIdentity {
            let exact = rows.filter { $0.contextIdentity == selected }
            guard exact.count == 1 else { return nil }
            contextIdentity = selected
        } else if rows.count == 1 {
            contextIdentity = rows[0].contextIdentity
        } else if rows.isEmpty && layer.sourceMapID == nil {
            contextIdentity = nil
        } else {
            return nil
        }
        return Self(projectSessionID: projectSessionID, mapID: mapState.id,
                    sourceContextIdentity: contextIdentity,
                    selectionOwner: MapVectorSelectionOwner(layer))
    }
}

enum MapSelectionMeasurementOwnerResolver {
    @MainActor static func activeVector(projectSessionID: UUID, mapState: MapState,
                             visibleLayers: [MapVectorLayer]) -> (owner: MapSelectionMeasurementOwner, layer: MapVectorLayer)? {
        let layers = visibleLayers.filter {
            $0.isSourceVisible && !mapState.hiddenLayers.contains($0.id)
                && ($0.sourceMapID == nil || $0.sourceMapID == mapState.id)
        }
        let layer: MapVectorLayer?
        if let selectedContext = mapState.selectedSourceContextIdentity {
            let rows = mapState.sourceMapRenderRows.filter {
                $0.mapID == mapState.id && $0.contextIdentity == selectedContext && $0.isActiveAndVisible
            }
            guard rows.count == 1, let row = rows.first else { return nil }
            let contextLayers = layers.filter { row.payloadLayerIDs.contains($0.id) }
            if let selectedLayerID = mapState.selectedLayerID,
               let selected = contextLayers.first(where: { $0.id == selectedLayerID }) {
                layer = selected
            } else if contextLayers.count == 1 {
                layer = contextLayers.first
            } else {
                return nil
            }
        } else if let selectedLayerID = mapState.selectedLayerID {
            let matches = layers.filter { $0.id == selectedLayerID }
            guard matches.count == 1 else { return nil }
            layer = matches.first
        } else if layers.count == 1 {
            layer = layers.first
        } else {
            return nil
        }
        guard let layer,
              let owner = MapSelectionMeasurementOwner.selection(projectSessionID: projectSessionID,
                  mapState: mapState, layer: layer) else { return nil }
        return (owner, layer)
    }

    @MainActor static func activeTool(projectSessionID: UUID, mapState: MapState,
                           visibleLayers: [MapVectorLayer], toolID: String) -> (owner: MapSelectionMeasurementOwner, layer: MapVectorLayer?)? {
        if MapSelectionMeasurementTool.selectors.contains(toolID) {
            guard let active = activeVector(projectSessionID: projectSessionID,
                                           mapState: mapState, visibleLayers: visibleLayers) else { return nil }
            return (active.owner, active.layer)
        }
        guard MapSelectionMeasurementTool.measurements.contains(toolID),
              let owner = MapSelectionMeasurementOwner.context(projectSessionID: projectSessionID,
                                                               mapState: mapState) else { return nil }
        return (owner, nil)
    }
}

enum MapSelectionMeasurementTool {
    static let selectors: Set<String> = ["Map.SelectExtent", "Map.SelectPath", "Map.SelectLasso"]
    static let measurements: Set<String> = ["Map.MeasureLength", "Map.MeasureArea"]
    static let all = selectors.union(measurements)
    static func contains(_ toolID: String) -> Bool { all.contains(toolID) }
}

struct MapSelectionMeasurementPersistentOverlay: Equatable, Sendable {
    let owner: MapSelectionMeasurementOwner
    var lengthPath: [MapPoint]?
    var areaPath: [MapPoint]?
    var label: String?
    var slopeLabel: String?
    var labelPoint: MapPoint?
}

struct MapSelectionMeasurementDisplay: Equatable, Sendable {
    let toolID: String
    let dragPoints: [MapPoint]
    let measurementPoints: [MapPoint]
    let pointer: MapPoint?
    let persistent: MapSelectionMeasurementPersistentOverlay?
}

@MainActor
final class MapSelectionMeasurementSession: ObservableObject {
    @Published private(set) var activeToolID = "select"
    @Published private(set) var activeOwner: MapSelectionMeasurementOwner?
    @Published private(set) var dragPoints: [MapPoint] = []
    @Published private(set) var measurementPoints: [MapPoint] = []
    @Published private(set) var pointer: MapPoint?
    @Published private(set) var persistentOverlays: [MapSelectionMeasurementPersistentOverlay] = []

    private var pathAppendedIdentities: Set<String> = []
    private var isDragging = false
    private var isMeasuring = false
    private var measurementDragStartHandled = false
    private var measurementGeneration: UInt64 = 0
    private var terrainSlopeTask: Task<Void, Never>?

    func activate(toolID: String, owner: MapSelectionMeasurementOwner?,
                  store: WorkspaceStore? = nil, mapState: MapState? = nil) {
        let nextTool = MapSelectionMeasurementTool.contains(toolID) ? toolID : "select"
        if isMeasuring && (nextTool != activeToolID || owner != activeOwner) {
            finishMeasurement(with: nil, store: store, mapState: mapState)
        }
        if isDragging && (nextTool != activeToolID || owner != activeOwner) {
            clearDrag()
        }
        if nextTool != activeToolID || owner != activeOwner { measurementDragStartHandled = false }
        guard activeToolID != nextTool || activeOwner != owner else { return }
        activeToolID = nextTool
        activeOwner = owner
        pointer = nil
    }

    func updatePointer(_ point: MapPoint?, owner: MapSelectionMeasurementOwner?) {
        guard MapSelectionMeasurementTool.measurements.contains(activeToolID),
              owner == activeOwner else { return }
        if let point, MapSelectionMeasurementGeometry.validPoint(point) { self.pointer = point }
        else { pointer = nil }
    }

    func handleClick(_ point: MapPoint, screenPoint: CGPoint,
                     modifiers: Set<MapInput.Modifier>, owner: MapSelectionMeasurementOwner?,
                     layer: MapVectorLayer?, transform: MapTransform,
                     store: WorkspaceStore, mapState: MapState) {
        guard MapSelectionMeasurementTool.contains(activeToolID), owner == activeOwner,
              MapSelectionMeasurementGeometry.validPoint(point) else { return }
        pointer = point
        if MapSelectionMeasurementTool.selectors.contains(activeToolID) {
            guard let layer, owner?.selectionOwner == MapVectorSelectionOwner(layer) else { return }
            _ = selectFeature(at: screenPoint, layer: layer, transform: transform,
                mode: MapVectorSelectionMode.pointer(modifiers: modifiers), store: store,
                mapState: mapState)
            return
        }
        if !isMeasuring {
            beginMeasurementGeneration()
            measurementPoints = [point]
            isMeasuring = true
        } else {
            measurementPoints.append(point)
        }
    }

    func handleRightClick(_ screenPoint: CGPoint, owner: MapSelectionMeasurementOwner?,
                          layer: MapVectorLayer?, transform: MapTransform,
                          store: WorkspaceStore, mapState: MapState) {
        guard MapSelectionMeasurementTool.selectors.contains(activeToolID),
              owner == activeOwner, let layer,
              owner?.selectionOwner == MapVectorSelectionOwner(layer) else { return }
        _ = selectFeature(at: screenPoint, layer: layer, transform: transform,
            mode: .ensureIncluded, store: store, mapState: mapState)
    }

    func beginDrag(start: MapPoint, modifiers: Set<MapInput.Modifier>,
                   owner: MapSelectionMeasurementOwner?, layer: MapVectorLayer?,
                   mapState: MapState) {
        guard MapSelectionMeasurementTool.selectors.contains(activeToolID),
              owner == activeOwner, let layer,
              owner?.selectionOwner == MapVectorSelectionOwner(layer),
              MapSelectionMeasurementGeometry.validPoint(start) else { return }
        if isDragging { clearDrag() }
        isDragging = true
        pathAppendedIdentities = []
        dragPoints = [start]

        if !modifiers.contains(.control) && !modifiers.contains(.command) {
            _ = mapState.selectVectorFeatures([], in: layer, mode: .replace)
        }
    }

    func dragChanged(start: MapPoint, current: MapPoint,
                     modifiers: Set<MapInput.Modifier>, owner: MapSelectionMeasurementOwner?,
                     layer: MapVectorLayer?, mapState: MapState) {
        if MapSelectionMeasurementTool.selectors.contains(activeToolID) {
            if !isDragging {
                beginDrag(start: start, modifiers: modifiers, owner: owner,
                          layer: layer, mapState: mapState)
            }
            updateDrag(to: current, owner: owner, layer: layer, mapState: mapState)
        } else if MapSelectionMeasurementTool.measurements.contains(activeToolID),
                  owner == activeOwner, !measurementDragStartHandled,
                  MapSelectionMeasurementGeometry.validPoint(start) {
            measurementDragStartHandled = true
            if isMeasuring { measurementPoints.append(start) }
            else { beginMeasurementGeneration(); measurementPoints = [start]; isMeasuring = true }
            pointer = current
        } else if MapSelectionMeasurementTool.measurements.contains(activeToolID),
                  owner == activeOwner, measurementDragStartHandled,
                  MapSelectionMeasurementGeometry.validPoint(current) {
            pointer = current
        }
    }

    func updateDrag(to point: MapPoint, owner: MapSelectionMeasurementOwner?,
                    layer: MapVectorLayer?, mapState: MapState) {
        guard isDragging, owner == activeOwner, let layer,
              owner?.selectionOwner == MapVectorSelectionOwner(layer),
              MapSelectionMeasurementGeometry.validPoint(point) else { return }
        dragPoints.append(point)
        guard activeToolID == "Map.SelectPath" else { return }
        let hits = MapSelectionMeasurementGeometry.selectedIdentities(
            in: layer, toolID: activeToolID, points: dragPoints, hitMode: .intersects)
        let newHits = hits.subtracting(pathAppendedIdentities)
        if !newHits.isEmpty {
            _ = mapState.selectVectorFeatures(newHits, in: layer, mode: .ensureIncluded)
            pathAppendedIdentities.formUnion(newHits)
        }
    }

    func finishDrag(at point: MapPoint?, modifiers: Set<MapInput.Modifier>,
                    owner: MapSelectionMeasurementOwner?, layer: MapVectorLayer?,
                    mapState: MapState) {
        guard isDragging else { return }
        if let point, MapSelectionMeasurementGeometry.validPoint(point), dragPoints.last != point {
            dragPoints.append(point)
        }
        guard owner == activeOwner, let layer,
              owner?.selectionOwner == MapVectorSelectionOwner(layer) else {
            clearDrag(); return
        }
        let points = dragPoints
        let tool = activeToolID
        let ctrl = modifiers.contains(.control) || modifiers.contains(.command)
        clearDrag()
        let hitMode = hitMode(for: mapState)
        let hits = MapSelectionMeasurementGeometry.selectedIdentities(
            in: layer, toolID: tool, points: points, hitMode: hitMode)
        switch tool {
        case "Map.SelectExtent":
            // The source extent handler clears at begin unless Ctrl is held,
            // then always applies the ending selection with Toggle.
            _ = mapState.selectVectorFeatures(hits, in: layer, mode: .toggle)
        case "Map.SelectPath":
            _ = mapState.selectVectorFeatures(hits, in: layer,
                mode: ctrl ? .toggle : .replace)
        case "Map.SelectLasso":
            guard points.count >= 3,
                  MapSelectionMeasurementGeometry.isValidLasso(points) else { return }
            _ = mapState.selectVectorFeatures(hits, in: layer,
                mode: ctrl ? .toggle : .replace)
        default:
            break
        }
    }

    func finishMeasureDrag() { measurementDragStartHandled = false }

    func handleDoubleClick(at point: MapPoint, owner: MapSelectionMeasurementOwner?) {
        guard MapSelectionMeasurementTool.measurements.contains(activeToolID),
              owner == activeOwner else { return }
        pointer = point
        finishMeasurement(with: point, store: nil, mapState: nil)
    }

    func handleDoubleClick(at point: MapPoint, owner: MapSelectionMeasurementOwner?,
                           store: WorkspaceStore, mapState: MapState) {
        guard MapSelectionMeasurementTool.measurements.contains(activeToolID),
              owner == activeOwner else { return }
        pointer = point
        finishMeasurement(with: point, store: store, mapState: mapState)
    }

    func cancel() {
        invalidateTerrainSlope()
        clearDrag()
        measurementPoints = []
        isMeasuring = false
        measurementDragStartHandled = false
        pointer = nil
    }

    func invalidate() {
        cancel()
        activeToolID = "select"
        activeOwner = nil
        persistentOverlays = []
    }

    func close() {
        if isMeasuring { finishMeasurement(with: nil, store: nil, mapState: nil) }
        clearDrag()
        measurementDragStartHandled = false
        pointer = nil
    }

    func close(store: WorkspaceStore, mapState: MapState) {
        if isMeasuring { finishMeasurement(with: nil, store: store, mapState: mapState) }
        clearDrag()
        measurementDragStartHandled = false
        pointer = nil
    }

    func display(for owner: MapSelectionMeasurementOwner?) -> MapSelectionMeasurementDisplay {
        let matches = owner == activeOwner
        let persistent = owner.flatMap { requested in
            persistentOverlays.last(where: { Self.sameVisualContext($0.owner, requested) })
        }
        return MapSelectionMeasurementDisplay(
            toolID: matches ? activeToolID : "select",
            dragPoints: matches ? dragPoints : [],
            measurementPoints: matches && isMeasuring ? measurementPoints : [],
            pointer: matches ? pointer : nil,
            persistent: persistent)
    }

    private func selectFeature(at location: CGPoint, layer: MapVectorLayer,
                               transform: MapTransform, mode: MapVectorSelectionMode,
                               store: WorkspaceStore, mapState: MapState) -> Bool {
        for feature in layer.features.reversed() {
            guard feature.hasUniqueStableIdentity,
                  layer.features.filter({ $0.stableIdentity == feature.stableIdentity }).count == 1 else { continue }
            let definitionID = MapVectorStyleDefinitionIDs.primaryDefinition(for: feature.kind)
            let style = MapVectorStyleResolver.values(layerID: layer.id, feature: feature,
                definitionID: definitionID, presentations: mapState.vectorStyles)
            let path = transform.path(feature,
                pointDiameter: VectorMapCanvas.safePointDiameter(style.pointSize))
            let hitWidth = max(VectorMapCanvas.safeLineWidth(style.penWidth), 10)
            guard path.contains(location, eoFill: true)
                    || path.strokedPath(StrokeStyle(lineWidth: hitWidth)).contains(location) else { continue }
            let sourcePath = SourceFilePaths.canonical(layer.url)
            if let asset = store.assets.first(where: { SourceFilePaths.canonical($0.url) == sourcePath }) {
                store.select(asset)
            }
            guard mapState.selectVectorFeature(feature, in: layer, mode: mode) else { continue }
            if feature.kind == .line, mapState.selectedFeatureIdentities.contains(feature.stableIdentity) {
                for (index, points) in feature.paths.enumerated().reversed() {
                    let component = MapFeature(id: feature.id, kind: .line, paths: [points], attributes: feature.attributes)
                    if transform.path(component).strokedPath(StrokeStyle(lineWidth: hitWidth)).contains(location),
                       feature.pathStableIdentities.indices.contains(index) {
                        mapState.selectedLineIdentity = feature.pathStableIdentities[index]
                        break
                    }
                }
            }
            store.activateMap(mapState.id)
            store.selectedFeatureID = mapState.selectedFeatureID
            store.inspectorMode = .components
            store.showInspector = true
            return true
        }
        return false
    }

    private func hitMode(for mapState: MapState) -> MapSelectionMeasurementHitMode {
        guard let definition = mapState.toolPaletteSession.option("Lasso.HitMode") else { return .intersects }
        return mapState.toolPaletteSession.value(definition) == "Contained" ? .contained : .intersects
    }

    private func finishMeasurement(with closePoint: MapPoint?, store: WorkspaceStore?, mapState: MapState?) {
        guard isMeasuring, let owner = activeOwner else { return }
        let isArea = activeToolID == "Map.MeasureArea"
        let slopeEndpoints: [MapPoint]?
        if !isArea, let closePoint, let last = measurementPoints.last {
            slopeEndpoints = [last, closePoint]
        } else if !isArea, closePoint == nil, measurementPoints.count > 1 {
            slopeEndpoints = [measurementPoints[measurementPoints.count - 2], measurementPoints[measurementPoints.count - 1]]
        } else {
            slopeEndpoints = nil
        }
        var points = measurementPoints
        if points.count == 1 {
            guard let closePoint else {
                measurementPoints = []; isMeasuring = false; return
            }
            points.append(closePoint)
        } else if let closePoint {
            points.append(closePoint)
        }
        let value = isArea ? abs(MapSelectionMeasurementGeometry.area(points))
            : MapSelectionMeasurementGeometry.length(points)
        let label = (isArea ? "Area " : "Length ") + MapSelectionMeasurementGeometry.threeSignificantFigures(value)
        var persistent = persistentOverlays.last(where: { Self.sameVisualContext($0.owner, owner) })
            ?? MapSelectionMeasurementPersistentOverlay(owner: owner, lengthPath: nil,
                areaPath: nil, label: nil, slopeLabel: nil, labelPoint: nil)
        if isArea {
            if points.count > 2 { persistent.areaPath = MapSelectionMeasurementGeometry.closed(points) }
            persistent.labelPoint = MapSelectionMeasurementGeometry.bestLabelPoint(points) ?? points.last
        } else {
            persistent.lengthPath = points
            persistent.labelPoint = points.last
        }
        persistent.label = label
        persistent.slopeLabel = nil
        if let index = persistentOverlays.firstIndex(where: { Self.sameVisualContext($0.owner, owner) }) {
            persistentOverlays[index] = persistent
        } else {
            persistentOverlays.append(persistent)
        }
        measurementPoints = []
        isMeasuring = false
        if let slopeEndpoints, let store, let mapState {
            sampleTerrainSlope(slopeEndpoints, owner: owner, store: store, mapState: mapState,
                measurementGeneration: measurementGeneration)
        }
    }

    private func beginMeasurementGeneration() {
        measurementGeneration &+= 1
        terrainSlopeTask?.cancel()
        terrainSlopeTask = nil
    }

    private func invalidateTerrainSlope() {
        measurementGeneration &+= 1
        terrainSlopeTask?.cancel()
        terrainSlopeTask = nil
    }

    private func sampleTerrainSlope(_ endpoints: [MapPoint], owner: MapSelectionMeasurementOwner,
                                    store: WorkspaceStore, mapState: MapState,
                                    measurementGeneration: UInt64) {
        guard endpoints.count == 2,
              let capture = activeTerrainCapture(owner: owner, store: store, mapState: mapState),
              let mapRequest = store.mapResultRequest(for: mapState.id),
              let client = store.dynamicProfileBackendClient,
              let request = try? MapTerrainElevationRequest(map: mapRequest, capture: capture.capture,
                  payload: capture.payload, endpoints: endpoints) else { return }
        let workflowIdentity = store.mapWorkflowIdentity(mapState.id)
        let sessionID = owner.projectSessionID
        terrainSlopeTask?.cancel()
        terrainSlopeTask = Task { @MainActor [weak self, weak store, weak mapState] in
            do {
                let response = try await BackendMapTerrainElevationProvider(client: client).sample(request)
                guard !Task.isCancelled, let self, let store, let mapState,
                      self.measurementGeneration == measurementGeneration,
                      self.activeOwner == owner, owner.projectSessionID == store.projectSessionID,
                      owner.projectSessionID == sessionID,
                      store.mapWorkflowIdentity(mapState.id) == workflowIdentity,
                      response.elevations.count == 2,
                      let first = response.elevations[0],
                      let last = response.elevations[1],
                      first.isFinite, last.isFinite else { return }
                let length = MapSelectionMeasurementGeometry.length(endpoints)
                guard length.isFinite, length > 0 else { return }
                let slope = (last - first) / length
                guard slope.isFinite,
                      let index = self.persistentOverlays.firstIndex(where: {
                          Self.sameVisualContext($0.owner, owner)
                      }) else { return }
                self.persistentOverlays[index].slopeLabel =
                    MapSelectionMeasurementGeometry.threeSignificantFigures(slope)
            } catch {
                // The retained map tool omits slope when the active Terrain
                // context cannot provide finite endpoint samples.
            }
        }
    }

    private func activeTerrainCapture(owner: MapSelectionMeasurementOwner,
                                      store: WorkspaceStore, mapState: MapState)
        -> (capture: AssociatedMapLayerCapture, payload: AssociatedMapLayerPayload)? {
        guard owner.mapID == mapState.id,
              owner.projectSessionID == store.projectSessionID,
              let contextIdentity = owner.sourceContextIdentity,
              let row = mapState.sourceMapRenderRows.first(where: {
                  $0.mapID == mapState.id && $0.contextIdentity == contextIdentity
                      && $0.payloadKind == "Terrain" && $0.isActiveAndVisible
              }),
              mapState.selectedSourceContextIdentity == nil
                || mapState.selectedSourceContextIdentity == contextIdentity,
              let state = mapState.associatedMapLayers.entries.first(where: {
                  $0.capture.projectSessionID == owner.projectSessionID
                      && $0.capture.mapID == owner.mapID
                      && $0.capture.associationNode == row.locator
              }),
              state.capture.isChecked, state.capture.effectiveVisible,
              let payload = state.payload, payload.status == .available,
              payload.isChecked, payload.effectiveVisible else { return nil }
        return (state.capture, payload)
    }

    private func clearDrag() {
        isDragging = false
        dragPoints = []
        pathAppendedIdentities = []
    }

    private static func sameVisualContext(_ lhs: MapSelectionMeasurementOwner,
                                          _ rhs: MapSelectionMeasurementOwner) -> Bool {
        lhs.projectSessionID == rhs.projectSessionID && lhs.mapID == rhs.mapID
            && lhs.sourceContextIdentity == rhs.sourceContextIdentity
    }
}

enum MapSelectionMeasurementHitMode: Sendable {
    case intersects, contained
}

enum MapSelectionMeasurementGeometry {
    static func validPoint(_ point: MapPoint) -> Bool { point.x.isFinite && point.y.isFinite }

    static func selectedIdentities(in layer: MapVectorLayer, toolID: String,
                                   points: [MapPoint], hitMode: MapSelectionMeasurementHitMode) -> Set<String> {
        guard points.allSatisfy(validPoint), !points.isEmpty else { return [] }
        let unique = Dictionary(grouping: layer.features, by: \.stableIdentity)
        return Set(layer.features.compactMap { feature in
            guard feature.hasUniqueStableIdentity, unique[feature.stableIdentity]?.count == 1,
                  intersects(feature, toolID: toolID, points: points, hitMode: hitMode) else { return nil }
            return feature.stableIdentity
        })
    }

    static func intersects(_ feature: MapFeature, toolID: String, points: [MapPoint],
                           hitMode: MapSelectionMeasurementHitMode) -> Bool {
        guard !feature.paths.isEmpty, feature.paths.flatMap({ $0 }).allSatisfy(validPoint) else { return false }
        switch toolID {
        case "Map.SelectExtent":
            guard let first = points.first, let last = points.last else { return false }
            let l = min(first.x, last.x), r = max(first.x, last.x)
            let b = min(first.y, last.y), t = max(first.y, last.y)
            return extentSelection(feature, minX: l, minY: b, maxX: r, maxY: t, hitMode: hitMode)
        case "Map.SelectPath":
            return pathSelection(feature, path: points)
        case "Map.SelectLasso":
            guard isValidLasso(points) else { return false }
            return polygonSelection(feature, polygon: closed(points), hitMode: hitMode)
        default:
            return false
        }
    }

    static func isValidLasso(_ points: [MapPoint]) -> Bool {
        // Polygon.IsValidPolygon in the source checks only that the closed
        // lasso has at least three points. Self-intersections and repeated
        // samples are passed to the layer's native geometric hit tests.
        points.count >= 3 && points.allSatisfy(validPoint)
    }

    static func length(_ points: [MapPoint]) -> Double {
        guard points.count > 1 else { return 0 }
        var sum = 0.0
        for index in 1..<points.count {
            let dx = points[index - 1].x - points[index].x
            let dy = points[index - 1].y - points[index].y
            sum += sqrt(dx * dx + dy * dy)
        }
        return sum.isFinite ? sum : 0
    }

    static func area(_ points: [MapPoint]) -> Double {
        guard points.count >= 3 else { return 0 }
        return signedArea(closed(points))
    }

    static func closed(_ points: [MapPoint]) -> [MapPoint] {
        guard let first = points.first, let last = points.last else { return [] }
        return first == last ? points : points + [first]
    }

    static func centroid(_ points: [MapPoint]) -> MapPoint? {
        let ring = closed(points)
        guard ring.count >= 4 else { return nil }
        let twiceArea = ring.dropLast().indices.reduce(0.0) { partial, index in
            let a = ring[index], b = ring[index + 1]
            return partial + a.x * b.y - b.x * a.y
        }
        guard twiceArea.isFinite, twiceArea != 0 else { return nil }
        var x = 0.0, y = 0.0
        for index in 0..<(ring.count - 1) {
            let a = ring[index], b = ring[index + 1]
            let cross = a.x * b.y - b.x * a.y
            x += (a.x + b.x) * cross
            y += (a.y + b.y) * cross
        }
        let point = MapPoint(x: x / (3 * twiceArea), y: y / (3 * twiceArea))
        return validPoint(point) ? point : nil
    }

    /// Source Polygon.BestLabelPoint uses a 9-cell-bounded raster search that
    /// refines the cell with the greatest signed interior distance until the
    /// source 1% precision or depth 20 limit is reached.
    static func bestLabelPoint(_ points: [MapPoint]) -> MapPoint? {
        let ring = closed(points)
        guard ring.count >= 4 else { return nil }
        let absoluteArea = abs(signedArea(ring))
        guard absoluteArea.isFinite, absoluteArea > 0 else { return nil }
        if absoluteArea < 0.01 * 0.01 { return centroid(ring) }

        guard let minX = ring.map(\.x).min(), let maxX = ring.map(\.x).max(),
              let minY = ring.map(\.y).min(), let maxY = ring.map(\.y).max() else { return nil }
        var left = minX, right = maxX, bottom = minY, top = maxY
        if right == left {
            if right == 0 { right += 0.01; left -= 0.01 }
            else if right > 0 { right *= 1.01; left *= 0.99 }
            else { right *= 0.99; left *= 1.01 }
        }
        if top == bottom {
            if top == 0 { top += 0.01; bottom -= 0.01 }
            else if top > 0 { top *= 1.01; bottom *= 0.99 }
            else { top *= 0.99; bottom *= 1.01 }
        }
        let width = right - left, height = top - bottom
        guard width.isFinite, height.isFinite, width >= 0, height >= 0 else { return nil }

        let aspect = width / height
        guard aspect.isFinite, aspect > 0 else { return MapPoint(x: (left + right) / 2, y: (bottom + top) / 2) }
        var rows = Int(floor(sqrt(9 / aspect)))
        var columns = Int(floor(sqrt(9 * aspect)))
        if rows == 0 {
            rows = 1
            columns = 9
        } else if columns == 0 {
            rows = 9
            columns = 1
        }
        let cellSize = max(height / Double(rows), width / Double(columns)) * 1.01
        guard cellSize.isFinite, cellSize > 0 else { return nil }
        let centerX = left + width / 2
        let centerY = bottom + height / 2
        let rasterLeft = centerX - Double(columns) * cellSize / 2
        let rasterTop = centerY + Double(rows) * cellSize / 2

        let precision = max(sqrt(absoluteArea) * 0.01, 0.01)
        var heap: [LabelSearchCell] = []
        for row in 0..<rows {
            for column in 0..<columns {
                let center = MapPoint(x: rasterLeft + (Double(column) + 0.5) * cellSize,
                                      y: rasterTop - (Double(row) + 0.5) * cellSize)
                let distance = signedDistance(center, ring: ring)
                push(LabelSearchCell(level: 0, row: row, column: column,
                    distance: distance, priority: distance + cellSize * 0.707106781185), into: &heap)
            }
        }

        var best: LabelSearchCell?
        while let cell = pop(from: &heap) {
            if best == nil || cell.distance > best!.distance { best = cell }
            guard cell.priority - (best?.distance ?? -.infinity) > precision,
                  cell.level + 1 < 20 else { continue }
            let level = cell.level + 1
            let childRows = rows * (1 << level)
            let childColumns = columns * (1 << level)
            let size = cellSize / Double(1 << level)
            let offsetY = cell.row * 2
            let offsetX = cell.column * 2
            for row in offsetY..<(offsetY + 2) {
                for column in offsetX..<(offsetX + 2) {
                    guard row < childRows, column < childColumns else { continue }
                    let center = MapPoint(x: rasterLeft + (Double(column) + 0.5) * size,
                                          y: rasterTop - (Double(row) + 0.5) * size)
                    let distance = signedDistance(center, ring: ring)
                    push(LabelSearchCell(level: level, row: row, column: column,
                        distance: distance, priority: distance + size * 0.707106781185), into: &heap)
                }
            }
        }
        guard let best else { return nil }
        let size = cellSize / Double(1 << best.level)
        let point = MapPoint(x: rasterLeft + (Double(best.column) + 0.5) * size,
                             y: rasterTop - (Double(best.row) + 0.5) * size)
        return validPoint(point) ? point : nil
    }

    private struct LabelSearchCell {
        let level: Int
        let row: Int
        let column: Int
        let distance: Double
        let priority: Double
    }

    private static func push(_ cell: LabelSearchCell, into heap: inout [LabelSearchCell]) {
        heap.append(cell)
        var child = heap.count - 1
        while child > 0 {
            let parent = (child - 1) / 2
            guard heap[child].priority > heap[parent].priority else { break }
            heap.swapAt(child, parent)
            child = parent
        }
    }

    private static func pop(from heap: inout [LabelSearchCell]) -> LabelSearchCell? {
        guard !heap.isEmpty else { return nil }
        if heap.count == 1 { return heap.removeLast() }
        let first = heap[0]
        heap[0] = heap.removeLast()
        var parent = 0
        while true {
            let left = parent * 2 + 1
            guard left < heap.count else { break }
            let right = left + 1
            let child = right < heap.count && heap[right].priority > heap[left].priority ? right : left
            guard heap[child].priority > heap[parent].priority else { break }
            heap.swapAt(parent, child)
            parent = child
        }
        return first
    }

    private static func signedDistance(_ point: MapPoint, ring: [MapPoint]) -> Double {
        var inside = false
        var minimumSquared = Double.greatestFiniteMagnitude
        for index in 0..<(ring.count - 1) {
            let a = ring[index], b = ring[index + 1]
            if (a.y > point.y) != (b.y > point.y),
               point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x {
                inside.toggle()
            }
            let dx = b.x - a.x, dy = b.y - a.y
            let lengthSquared = dx * dx + dy * dy
            let fraction = lengthSquared > 0
                ? min(max(((point.x - a.x) * dx + (point.y - a.y) * dy) / lengthSquared, 0), 1) : 0
            let nearestX = a.x + fraction * dx, nearestY = a.y + fraction * dy
            let distanceX = point.x - nearestX, distanceY = point.y - nearestY
            minimumSquared = min(minimumSquared, distanceX * distanceX + distanceY * distanceY)
        }
        let distance = sqrt(minimumSquared)
        return inside ? distance : -distance
    }

    static func threeSignificantFigures(_ value: Double) -> String {
        guard value.isFinite, value != Double.greatestFiniteMagnitude else { return "" }
        if value == 0 { return "0" }
        let magnitude = abs(value)
        let decimals: Int
        if magnitude >= 1 {
            decimals = max(0, 3 - (Int(floor(log10(magnitude))) + 1))
        } else {
            decimals = max(0, 3 - Int(floor(log10(magnitude))) - 1)
        }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = .current
        formatter.minimumFractionDigits = decimals
        formatter.maximumFractionDigits = decimals
        formatter.usesGroupingSeparator = true
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    private static func polygonSelection(_ feature: MapFeature, polygon: [MapPoint],
                                         hitMode: MapSelectionMeasurementHitMode) -> Bool {
        guard polygon.count >= 3 else { return false }
        switch hitMode {
        case .contained:
            return feature.paths.flatMap({ $0 }).allSatisfy { pointInPolygon($0, polygon) }
                && feature.paths.allSatisfy { pathEdges($0, closed: feature.kind == .polygon).allSatisfy {
                    !polygonBoundaryCrosses($0.0, $0.1, polygon)
                } }
        case .intersects:
            if feature.kind == .point {
                return feature.paths.flatMap({ $0 }).contains { pointInPolygon($0, polygon) }
            }
            for path in feature.paths {
                if path.contains(where: { pointInPolygon($0, polygon) }) { return true }
                for (a, b) in pathEdges(path, closed: feature.kind == .polygon) {
                    if polygonBoundaryCrosses(a, b, polygon) { return true }
                }
            }
            if feature.kind == .polygon {
                for point in polygon where featureContains(point, paths: feature.paths) { return true }
            }
            return false
        }
    }

    private static func extentSelection(_ feature: MapFeature, minX: Double, minY: Double,
                                        maxX: Double, maxY: Double,
                                        hitMode: MapSelectionMeasurementHitMode) -> Bool {
        let contains: (MapPoint) -> Bool = {
            $0.x >= minX && $0.x <= maxX && $0.y >= minY && $0.y <= maxY
        }
        let rectangle = [MapPoint(x: minX, y: minY), MapPoint(x: maxX, y: minY),
                         MapPoint(x: maxX, y: maxY), MapPoint(x: minX, y: maxY)]
        switch hitMode {
        case .contained:
            return feature.paths.flatMap({ $0 }).allSatisfy(contains)
        case .intersects:
            if feature.kind == .point { return feature.paths.flatMap({ $0 }).contains(where: contains) }
            for path in feature.paths {
                if path.contains(where: contains) { return true }
                for (a, b) in pathEdges(path, closed: feature.kind == .polygon) {
                    if polygonBoundaryCrosses(a, b, rectangle) { return true }
                }
            }
            if feature.kind == .polygon {
                return rectangle.contains(where: { featureContains($0, paths: feature.paths) })
            }
            return false
        }
    }

    private static func pathSelection(_ feature: MapFeature, path: [MapPoint]) -> Bool {
        guard path.count > 1 else { return false }
        if feature.kind == .point {
            return feature.paths.flatMap({ $0 }).contains { point in
                pathEdges(path, closed: false).contains { onSegment(point, $0.0, $0.1) }
            }
        }
        for featurePath in feature.paths {
            let featureEdges = pathEdges(featurePath, closed: feature.kind == .polygon)
            if path.contains(where: { feature.kind == .polygon && featureContains($0, paths: feature.paths) }) {
                return true
            }
            for a in pathEdges(path, closed: false) {
                if featureEdges.contains(where: { segmentsIntersect(a.0, a.1, $0.0, $0.1) }) { return true }
            }
        }
        return false
    }

    private static func featureContains(_ point: MapPoint, paths: [[MapPoint]]) -> Bool {
        var contained = false
        for path in paths where path.count >= 3 {
            if pointInPolygon(point, path) { contained.toggle() }
        }
        return contained
    }

    private static func pathEdges(_ points: [MapPoint], closed: Bool) -> [(MapPoint, MapPoint)] {
        guard points.count > 1 else { return [] }
        var edges = zip(points, points.dropFirst()).map { ($0.0, $0.1) }
        if closed, let first = points.first, let last = points.last, first != last {
            edges.append((last, first))
        }
        return edges
    }

    private static func polygonBoundaryCrosses(_ a: MapPoint, _ b: MapPoint,
                                               _ polygon: [MapPoint]) -> Bool {
        pathEdges(polygon, closed: true).contains { segmentsIntersect(a, b, $0.0, $0.1) }
    }

    private static func pointInPolygon(_ point: MapPoint, _ polygon: [MapPoint]) -> Bool {
        guard polygon.count >= 3 else { return false }
        var inside = false
        let edges = pathEdges(polygon, closed: true)
        for (a, b) in edges {
            if onSegment(point, a, b) { return true }
            if (a.y > point.y) != (b.y > point.y) {
                let x = (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x
                if point.x < x { inside.toggle() }
            }
        }
        return inside
    }

    private static func signedArea(_ ring: [MapPoint]) -> Double {
        guard ring.count >= 3 else { return 0 }
        var sum = 0.0
        for index in ring.indices {
            let a = ring[index], b = ring[(index + 1) % ring.count]
            sum += (a.y + b.y) * (b.x - a.x)
        }
        return sum * 0.5
    }

    private static func onSegment(_ point: MapPoint, _ a: MapPoint, _ b: MapPoint) -> Bool {
        guard abs(cross(a, b, point)) <= crossTolerance(a, b, point) else { return false }
        let tolerance = coordinateTolerance(a, b, point)
        return point.x >= min(a.x, b.x) - tolerance
            && point.x <= max(a.x, b.x) + tolerance
            && point.y >= min(a.y, b.y) - tolerance
            && point.y <= max(a.y, b.y) + tolerance
    }

    private static func segmentsIntersect(_ a: MapPoint, _ b: MapPoint,
                                          _ c: MapPoint, _ d: MapPoint) -> Bool {
        let abC = orientation(a, b, c), abD = orientation(a, b, d)
        let cdA = orientation(c, d, a), cdB = orientation(c, d, b)
        if abC != 0 && abD != 0 && cdA != 0 && cdB != 0 && abC != abD && cdA != cdB { return true }
        return (abC == 0 && onSegment(c, a, b)) || (abD == 0 && onSegment(d, a, b))
            || (cdA == 0 && onSegment(a, c, d)) || (cdB == 0 && onSegment(b, c, d))
    }

    private static func orientation(_ a: MapPoint, _ b: MapPoint, _ c: MapPoint) -> Int {
        let value = cross(a, b, c)
        if abs(value) <= crossTolerance(a, b, c) { return 0 }
        return value > 0 ? 1 : 2
    }

    private static func cross(_ a: MapPoint, _ b: MapPoint, _ c: MapPoint) -> Double {
        (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
    }

    private static func crossTolerance(_ a: MapPoint, _ b: MapPoint, _ c: MapPoint) -> Double {
        coordinateTolerance(a, b, c) * max(1, hypot(b.x - a.x, b.y - a.y)) * 16
    }

    private static func coordinateTolerance(_ points: MapPoint...) -> Double {
        let scale = points.reduce(1.0) { max($0, max(abs($1.x), abs($1.y))) }
        return scale * Double.ulpOfOne * 16
    }
}

struct MapSelectionMeasurementCanvas: View {
    @ObservedObject var session: MapSelectionMeasurementSession
    let owner: MapSelectionMeasurementOwner?
    let transform: MapTransform

    var body: some View {
        let display = session.display(for: owner)
        let lengthTitle = L10n.text("Length")
        let areaTitle = L10n.text("Area")
        let slopeTitle = L10n.text("Slope")
        Canvas { context, _ in
            if let persistent = display.persistent {
                if let area = persistent.areaPath, area.count > 2 {
                    let path = makePath(area, transform: transform, close: true)
                    context.fill(path, with: .color(Color.yellow.opacity(96.0 / 255.0)))
                    context.stroke(path, with: .color(.yellow), lineWidth: 2)
                }
                if let line = persistent.lengthPath, line.count > 1 {
                    let path = makePath(line, transform: transform, close: false)
                    context.stroke(path, with: .color(Color(red: 32.0 / 255.0, green: 0, blue: 64.0 / 255.0)), lineWidth: 2)
                }
                if let label = persistent.label, let point = persistent.labelPoint {
                    let localizedLabel: String
                    if label.hasPrefix("Length ") { localizedLabel = lengthTitle + " " + label.dropFirst(7) }
                    else if label.hasPrefix("Area ") { localizedLabel = areaTitle + " " + label.dropFirst(5) }
                    else { localizedLabel = label }
                    let completeLabel = persistent.slopeLabel.map { localizedLabel + "\n" + slopeTitle + " " + $0 } ?? localizedLabel
                    drawLabel(completeLabel, at: transform.screen(point), in: context)
                }
            }
            if !display.dragPoints.isEmpty {
                let path: Path
                if display.toolID == "Map.SelectExtent", let start = display.dragPoints.first,
                   let end = display.dragPoints.last {
                    path = makePath([MapPoint(x: start.x, y: start.y), MapPoint(x: end.x, y: start.y),
                                     MapPoint(x: end.x, y: end.y), MapPoint(x: start.x, y: end.y)],
                                    transform: transform, close: true)
                } else {
                    path = makePath(display.dragPoints, transform: transform,
                        close: display.toolID == "Map.SelectLasso" && display.dragPoints.count >= 3)
                }
                if display.toolID == "Map.SelectLasso" && display.dragPoints.count >= 3 {
                    context.fill(path, with: .color(.white.opacity(48.0 / 255.0)))
                }
                context.stroke(path, with: .color(.white), lineWidth: 2)
                context.stroke(path, with: .color(.black), style: StrokeStyle(lineWidth: 2, dash: [3, 3]))
            }
            if !display.measurementPoints.isEmpty {
                var points = display.measurementPoints
                if let pointer = display.pointer { points.append(pointer) }
                let area = display.toolID == "Map.MeasureArea"
                let path = makePath(points, transform: transform, close: area && points.count >= 3)
                if area && points.count >= 3 { context.fill(path, with: .color(.yellow.opacity(96.0 / 255.0))) }
                context.stroke(path, with: .color(.yellow), lineWidth: 2)
                if let pointer = display.pointer {
                    let value = area ? abs(MapSelectionMeasurementGeometry.area(points))
                        : MapSelectionMeasurementGeometry.length(points)
                    let label = (area ? areaTitle : lengthTitle) + " "
                        + MapSelectionMeasurementGeometry.threeSignificantFigures(value)
                    drawLabel(label, at: transform.screen(pointer), in: context)
                }
            } else if MapSelectionMeasurementTool.measurements.contains(display.toolID),
                      let pointer = display.pointer {
                let point = transform.screen(pointer)
                let marker = Path(ellipseIn: CGRect(x: point.x - 2, y: point.y - 2, width: 4, height: 4))
                context.fill(marker, with: .color(Color(red: 91.0 / 255.0, green: 204.0 / 255.0, blue: 59.0 / 255.0)))
                context.stroke(marker, with: .color(Color(red: 20.0 / 255.0, green: 77.0 / 255.0, blue: 5.0 / 255.0)), lineWidth: 1)
            }
        }
        .allowsHitTesting(false)
    }

    private func makePath(_ points: [MapPoint], transform: MapTransform, close: Bool) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: transform.screen(first))
        for point in points.dropFirst() { path.addLine(to: transform.screen(point)) }
        if close { path.closeSubpath() }
        return path
    }

    private func drawLabel(_ label: String, at point: CGPoint, in context: GraphicsContext) {
        for offset in [CGSize(width: -1, height: 0), CGSize(width: 1, height: 0),
                       CGSize(width: 0, height: -1), CGSize(width: 0, height: 1)] {
            context.draw(Text(verbatim: label).font(.system(size: 12, weight: .bold))
                .foregroundColor(.black.opacity(0.65)),
                at: CGPoint(x: point.x + offset.width, y: point.y + offset.height), anchor: .leading)
        }
        context.draw(Text(verbatim: label).font(.system(size: 12, weight: .bold)).foregroundColor(.white),
            at: point, anchor: .leading)
    }
}

struct MapSelectionMeasurementRightClickInteraction: NSViewRepresentable {
    let onRightClick: (CGPoint) -> Void
    func makeNSView(context: Context) -> MapSelectionMeasurementRightClickMonitorView {
        let view = MapSelectionMeasurementRightClickMonitorView()
        view.onRightClick = onRightClick
        return view
    }
    func updateNSView(_ view: MapSelectionMeasurementRightClickMonitorView, context: Context) {
        view.onRightClick = onRightClick
        view.installMonitorIfNeeded()
    }
    static func dismantleNSView(_ view: MapSelectionMeasurementRightClickMonitorView, coordinator: ()) {
        view.removeMonitor()
    }
}

@MainActor
final class MapSelectionMeasurementRightClickMonitorView: NSView {
    var onRightClick: ((CGPoint) -> Void)?
    private var monitor: Any?
    private weak var monitoredWindow: NSWindow?
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); installMonitorIfNeeded() }

    func installMonitorIfNeeded() {
        guard let window else { removeMonitor(); return }
        guard monitor == nil || monitoredWindow !== window else { return }
        removeMonitor()
        monitoredWindow = window
        monitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseUp) { [weak self] event in
            guard let self, let window = self.window, event.window === window else { return event }
            let location = self.convert(event.locationInWindow, from: nil)
            guard self.bounds.contains(location) else { return event }
            self.onRightClick?(location)
            return event
        }
    }

    func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        monitoredWindow = nil
    }
}
