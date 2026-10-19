import AppKit
import RASWorkspaceCore
import SwiftUI

enum MapVectorPlotFrameBinding {
    static func visibleWorldViewport(transform: MapTransform,
                                     size: CGSize) -> MapVectorPlotViewport? {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
              transform.factor.isFinite, transform.factor > 0 else { return nil }
        let first = transform.world(.zero)
        let second = transform.world(CGPoint(x: size.width, y: size.height))
        let viewport = MapVectorPlotViewport(minX: min(first.x, second.x),
            minY: min(first.y, second.y), maxX: max(first.x, second.x),
            maxY: max(first.y, second.y))
        return viewport.isFiniteAndOrdered ? viewport : nil
    }

    static func currentFrame(_ frame: VectorPlotRenderedLayer,
                             mapID: UUID, layerID: String,
                             sourceRevision: String?,
                             expectedVisualizationRevision: String,
                             requestedViewport: RasterMapViewExtent?,
                             liveViewport: MapVectorPlotViewport?) -> VectorPlotRenderedLayer? {
        guard let sourceRevision, !sourceRevision.isEmpty,
              !expectedVisualizationRevision.isEmpty,
              let requestedViewport, let liveViewport,
              requestedViewport.minX.isFinite, requestedViewport.minY.isFinite,
              requestedViewport.maxX.isFinite, requestedViewport.maxY.isFinite,
              requestedViewport.minX < requestedViewport.maxX,
              requestedViewport.minY < requestedViewport.maxY,
              requestedViewport.pixelWidth > 0, requestedViewport.pixelHeight > 0 else { return nil }
        let requestedWorld = MapVectorPlotViewport(minX: requestedViewport.minX,
            minY: requestedViewport.minY, maxX: requestedViewport.maxX,
            maxY: requestedViewport.maxY)
        guard requestedWorld.matches(liveViewport),
              frame.matches(mapID: mapID, layerID: layerID,
                  sourceRevision: sourceRevision,
                  visualizationRevision: expectedVisualizationRevision,
                  viewport: requestedWorld,
                  pixelWidth: requestedViewport.pixelWidth,
                  pixelHeight: requestedViewport.pixelHeight) else { return nil }
        return frame
    }
}

struct MapViewportFit {
    let scale: CGFloat
    let offset: CGSize
    init?(request: ViewportRequest, points: [MapPoint], size: CGSize) {
        guard request.isFiniteAndOrdered, request.padding.isFinite, request.padding >= 0, size.width > 0, size.height > 0 else { return nil }
        let base = MapTransform(points: points, size: size, scale: 1, offset: .zero)
        guard base.factor.isFinite, base.factor > 0 else { return nil }
        let width = request.upperRight.x - request.lowerLeft.x, height = request.upperRight.y - request.lowerLeft.y
        let desired = min(max(Double(size.width) - request.padding * 2, 1) / width, max(Double(size.height) - request.padding * 2, 1) / height)
        scale = min(max(CGFloat(desired) / base.factor, 0.000001), 1_000_000)
        let fitted = MapTransform(points: points, size: size, scale: scale, offset: .zero)
        let center = fitted.screen(.init(x: request.lowerLeft.x / 2 + request.upperRight.x / 2, y: request.lowerLeft.y / 2 + request.upperRight.y / 2))
        offset = CGSize(width: size.width / 2 - center.x, height: size.height / 2 - center.y)
        guard offset.width.isFinite, offset.height.isFinite else { return nil }
    }
}

struct MapTransform {
    let center: MapPoint
    let factor: CGFloat
    let size: CGSize
    let offset: CGSize
    init(points: [MapPoint], size: CGSize, scale: CGFloat, offset: CGSize) {
        let minX = points.map(\.x).min() ?? 0; let maxX = points.map(\.x).max() ?? 1
        let minY = points.map(\.y).min() ?? 0; let maxY = points.map(\.y).max() ?? 1
        center = MapPoint(x: minX / 2 + maxX / 2, y: minY / 2 + maxY / 2)
        let span = max(maxX - minX, maxY - minY)
        let fallback = span > 0 && span.isFinite ? span : 1
        let width = maxX > minX ? maxX - minX : fallback
        let height = maxY > minY ? maxY - minY : fallback
        factor = min(max(size.width - 64, 1) / CGFloat(width), max(size.height - 64, 1) / CGFloat(height)) * scale
        self.size = size; self.offset = offset
    }
    func screen(_ point: MapPoint) -> CGPoint {
        CGPoint(x: size.width / 2 + CGFloat(point.x - center.x) * factor + offset.width,
                y: size.height / 2 - CGFloat(point.y - center.y) * factor + offset.height)
    }
    func world(_ point: CGPoint) -> MapPoint {
        MapPoint(x: center.x + Double((point.x - size.width / 2 - offset.width) / factor),
                 y: center.y - Double((point.y - size.height / 2 - offset.height) / factor))
    }
    func path(_ feature: MapFeature, pointDiameter: CGFloat = 8) -> Path {
        var path = Path()
        for points in feature.paths {
            guard let first = points.first else { continue }
            if feature.kind == .point { path.addPath(pointPath(first, diameter: pointDiameter)); continue }
            path.move(to: screen(first))
            for point in points.dropFirst() { path.addLine(to: screen(point)) }
            if feature.kind == .polygon { path.closeSubpath() }
        }
        return path
    }
    func pointPath(_ point: MapPoint, diameter: CGFloat) -> Path {
        let size = max(diameter.isFinite ? diameter : 0, 0)
        let center = screen(point)
        return Path(ellipseIn: CGRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size))
    }
    func verticesPath(_ paths: [[MapPoint]], diameter: CGFloat) -> Path {
        var result = Path()
        for points in paths {
            for point in points { result.addPath(pointPath(point, diameter: diameter)) }
        }
        return result
    }
}

struct SourceARGBComponents: Equatable {
    let alpha: UInt8
    let red: UInt8
    let green: UInt8
    let blue: UInt8
}

enum SourceARGBColor {
    /// Source vector colors use `#AARRGGBB`; this is deliberately distinct from
    /// EditorColor's `RRGGBBAA` editor wire format.
    static func components(_ source: String) -> SourceARGBComponents? {
        guard source.first == "#", source.count == 9,
              let value = UInt32(source.dropFirst(), radix: 16) else { return nil }
        return SourceARGBComponents(
            alpha: UInt8((value >> 24) & 0xFF), red: UInt8((value >> 16) & 0xFF),
            green: UInt8((value >> 8) & 0xFF), blue: UInt8(value & 0xFF))
    }

    static func color(_ source: String) -> Color? {
        guard let value = components(source) else { return nil }
        return Color(.sRGB, red: Double(value.red) / 255, green: Double(value.green) / 255,
                     blue: Double(value.blue) / 255, opacity: Double(value.alpha) / 255)
    }
}

enum MapVectorStyleResolver {
    private static let sourceDefaults = MapVectorStylePresentation.sourceMapLayerDefaults

    static func values(layerID: String, feature: MapFeature, definitionID: String,
                       presentations: [String: MapVectorStylePresentation]) -> VectorStyleValues {
        presentations[layerID]?.values(for: definitionID, sourceFeatureIndex: feature.sourceFeatureIndex)
            ?? sourceDefaults.values(for: definitionID, sourceFeatureIndex: feature.sourceFeatureIndex)
            ?? VectorStyleValues()
    }

    static func penColor(_ style: VectorStyleValues, definitionID: String) -> Color {
        let sourceDefault = SourceVectorStyleCatalog.definition(for: definitionID).flatMap { SourceARGBColor.color($0.defaultStyle.penColor) }
        return SourceARGBColor.color(style.penColor) ?? sourceDefault ?? .primary
    }

    static func fillColor(_ style: VectorStyleValues, definitionID: String) -> Color {
        let sourceDefault = SourceVectorStyleCatalog.definition(for: definitionID).flatMap { SourceARGBColor.color($0.defaultStyle.fillColor) }
        return SourceARGBColor.color(style.fillColor) ?? sourceDefault ?? .clear
    }
}

struct VectorMapCanvas: View {
    @ObservedObject private var renderScaling = WorkspaceRenderScaling.shared
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var mapState: MapState
    @Environment(\.openWindow) private var openWindow
    let mapID: UUID
    let scale: CGFloat
    let offset: CGSize
    @Binding var pointer: MapPoint?
    var orderedLayers: [MapVectorLayer]? = nil
    /// Exact source renderer replacements keyed by the original visual-layer
    /// identity. They remain presentation-only and never enter map selection.
    var plotFrames: [String: VectorPlotRenderedLayer] = [:]
    /// The camera request used to produce `plotFrames`; pixel dimensions are
    /// the bounded source request dimensions, not SwiftUI logical points.
    var plotViewport: RasterMapViewExtent? = nil
    /// Fully drawn source layers can be replaced by an exact transient overlay
    /// while remaining present for source hit-testing, selection, and editing.
    var suppressedDrawingLayerIDs: Set<String> = []
    private var visibleLayers: [MapVectorLayer] { orderedLayers ?? mapState.visibleVectors(store.mapLayers) }
    var body: some View {
        GeometryReader { proxy in
            let transform = MapTransform(points: mapState.transformPoints(vectors: store.mapLayers, rasters: store.rasterLayers), size: proxy.size, scale: scale, offset: offset)
            let requestedPlotViewport = plotViewport ?? mapState.resultViewport
            let livePlotViewport = MapVectorPlotFrameBinding.visibleWorldViewport(
                transform: transform, size: proxy.size)
            let expectedVisualizationRevision = store.mapIdentityRequest(for: mapID)?.expectedVisualizationRevision
            let renderFactor = renderScaling.factor
            Canvas { context, _ in
                for layer in visibleLayers {
                    let frame: VectorPlotRenderedLayer? = plotFrames[layer.id].flatMap { candidate -> VectorPlotRenderedLayer? in
                        guard let expectedVisualizationRevision else { return nil }
                        return MapVectorPlotFrameBinding.currentFrame(candidate,
                            mapID: mapID, layerID: layer.id,
                            sourceRevision: layer.sourceRevision,
                            expectedVisualizationRevision: expectedVisualizationRevision,
                            requestedViewport: requestedPlotViewport,
                            liveViewport: livePlotViewport)
                    }
                    let drawsBaseLayer = !suppressedDrawingLayerIDs.contains(layer.id) && frame == nil
                    if let frame, let viewport = requestedPlotViewport {
                        Self.draw(frame, viewport: viewport, transform: transform, in: &context)
                    }
                    for feature in layer.features {
                        let definitionID = MapVectorStyleDefinitionIDs.primaryDefinition(for: feature.kind)
                        let style = MapVectorStyleResolver.values(layerID: layer.id, feature: feature,
                            definitionID: definitionID, presentations: mapState.vectorStyles)
                        let pointDiameter = WorkspaceRenderScaling.metric(Double(Self.safePointDiameter(style.pointSize)), factor: renderFactor)
                        let path = transform.path(feature, pointDiameter: pointDiameter)
                        let penColor = MapVectorStyleResolver.penColor(style, definitionID: definitionID)
                        let fillColor = MapVectorStyleResolver.fillColor(style, definitionID: definitionID)
                        let lineWidth = WorkspaceRenderScaling.metric(Double(Self.safeLineWidth(style.penWidth)), factor: renderFactor)
                        let selected = layer.id == mapState.selectedLayerID && mapState.selectedFeatureIdentities.contains(feature.stableIdentity)
                        if drawsBaseLayer {
                            if feature.kind == .polygon { context.fill(path, with: .color(fillColor), style: FillStyle(eoFill: true)) }
                            if feature.kind == .point { context.fill(path, with: .color(fillColor)) }
                            context.stroke(path, with: .color(penColor), lineWidth: lineWidth)

                            if let vertexDefinitionID = MapVectorStyleDefinitionIDs.vertexDefinition(for: feature.kind) {
                                let vertexStyle = MapVectorStyleResolver.values(layerID: layer.id, feature: feature,
                                    definitionID: vertexDefinitionID, presentations: mapState.vectorStyles)
                                let vertexPaths = feature.kind == .polygon
                                    ? feature.paths.map { points in points.first == points.last ? Array(points.dropLast()) : points }
                                    : feature.paths
                                let vertices = transform.verticesPath(vertexPaths, diameter: WorkspaceRenderScaling.metric(Double(Self.safePointDiameter(vertexStyle.pointSize)), factor: renderFactor))
                                context.fill(vertices, with: .color(MapVectorStyleResolver.fillColor(vertexStyle, definitionID: vertexDefinitionID)))
                                context.stroke(vertices, with: .color(MapVectorStyleResolver.penColor(vertexStyle, definitionID: vertexDefinitionID)),
                                    lineWidth: WorkspaceRenderScaling.metric(Double(Self.safeLineWidth(vertexStyle.penWidth)), factor: renderFactor))
                            }
                        }

                        // Interaction highlighting remains a separate overlay;
                        // it never replaces the source base/conditional style.
                        if selected {
                            switch feature.kind {
                            case .point:
                                for points in feature.paths {
                                    guard let point = points.first else { continue }
                                    let overlay = transform.pointPath(point, diameter: pointDiameter + 6)
                                    context.stroke(overlay, with: .color(.orange), lineWidth: 2.5)
                                }
                            case .line, .polygon:
                                context.stroke(path, with: .color(.orange), lineWidth: max(lineWidth + 2, 3))
                            }
                        }
                    }
                }
                for feature in mapState.allPreview {
                    context.stroke(transform.path(feature), with: .color(.orange), style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                }
            }
            .allowsHitTesting(false)
            .overlay {
                MapVectorFeatureContextMenuInteraction(
                    isEnabled: store.existingMapState(for: mapID) === mapState
                        && mapState.kind != .unsupported,
                    contextAt: { location, modifiers in
                        contextSnapshot(at: location, transform: transform, modifiers: modifiers)
                    },
                    perform: { action, captured in
                        performContextAction(action, captured: captured, openWindow: openWindow)
                    },
                    blankContextAt: { location in
                        blankContextSnapshot(at: location, transform: transform)
                    },
                    performBlank: { action, captured in
                        performBlankContextAction(action, captured: captured)
                    }
                )
                .allowsHitTesting(false)
            }
        }
    }

    private static func draw(_ frame: VectorPlotRenderedLayer,
                             viewport: RasterMapViewExtent,
                             transform: MapTransform,
                             in context: inout GraphicsContext) {
        let topLeft = transform.screen(MapPoint(x: viewport.minX, y: viewport.maxY))
        let bottomRight = transform.screen(MapPoint(x: viewport.maxX, y: viewport.minY))
        let rect = CGRect(x: topLeft.x, y: topLeft.y,
            width: bottomRight.x - topLeft.x, height: bottomRight.y - topLeft.y)
        guard rect.origin.x.isFinite, rect.origin.y.isFinite,
              rect.width.isFinite, rect.height.isFinite, rect.width > 0, rect.height > 0 else { return }
        context.draw(Image(decorative: frame.image, scale: 1), in: rect)
        for label in frame.labels {
            if label.polyline.count > 1 {
                var leader = Path()
                leader.move(to: transform.screen(MapPoint(x: label.polyline[0].x, y: label.polyline[0].y)))
                for point in label.polyline.dropFirst() {
                    leader.addLine(to: transform.screen(MapPoint(x: point.x, y: point.y)))
                }
                context.stroke(leader, with: .color(.secondary), lineWidth: 1)
            }
            context.draw(Text(label.text).font(.system(size: 10)).foregroundColor(.primary),
                at: transform.screen(MapPoint(x: label.point.x, y: label.point.y)), anchor: .center)
        }
    }

    /// Selection is invoked by ProjectMapView's single map-surface input
    /// router. The canvas only answers against its own visible vector rows;
    /// it never installs a second tap/hover route over geometry or raster.
    @discardableResult
    func selectFeature(at location: CGPoint, transform: MapTransform,
                       modifiers: Set<MapInput.Modifier> = []) -> Bool {
        for layer in visibleLayers.reversed() {
            for feature in layer.features.reversed() {
                let definitionID = MapVectorStyleDefinitionIDs.primaryDefinition(for: feature.kind)
                let style = MapVectorStyleResolver.values(layerID: layer.id, feature: feature,
                    definitionID: definitionID, presentations: mapState.vectorStyles)
                let path = transform.path(feature, pointDiameter: scaledMetric(Self.safePointDiameter(style.pointSize)))
                let hitWidth = max(scaledMetric(Self.safeLineWidth(style.penWidth)), 10)
                if path.contains(location, eoFill: true) || path.strokedPath(StrokeStyle(lineWidth: hitWidth)).contains(location) {
                    let sourcePath = SourceFilePaths.canonical(layer.url)
                    if let asset = store.assets.first(where: { SourceFilePaths.canonical($0.url) == sourcePath }) {
                        store.select(asset)
                    }
                    guard mapState.selectVectorFeature(feature, in: layer,
                        mode: .pointer(modifiers: modifiers)) else { continue }
                    if feature.kind == .line, mapState.selectedFeatureIdentities.contains(feature.stableIdentity) {
                        for (index, points) in feature.paths.enumerated().reversed() {
                            let component = MapFeature(id: feature.id, kind: .line, paths: [points], attributes: feature.attributes)
                            if transform.path(component).strokedPath(StrokeStyle(lineWidth: hitWidth)).contains(location), feature.pathStableIdentities.indices.contains(index) {
                                mapState.selectedLineIdentity = feature.pathStableIdentities[index]; break
                            }
                        }
                    }
                    store.activateMap(mapID)
                    store.selectedFeatureID = mapState.selectedFeatureID; store.inspectorMode = .components; store.showInspector = true
                    return true
                }
            }
        }
        return false
    }

    private func contextSnapshot(at location: CGPoint, transform: MapTransform,
                                 modifiers: Set<MapInput.Modifier>) -> MapVectorFeatureContextSnapshot? {
        guard store.existingMapState(for: mapID) === mapState,
              mapState.kind != .unsupported,
              ["select", "Map.Pan"].contains(mapState.toolID) else { return nil }
        let rows = MapContextComponentResolver.visibleRows(mapState.sourceMapRenderRows, mapID: mapID)
        let exactLayers = visibleLayers.filter { layer in
            let matches = rows.filter {
                $0.payloadKind == "MapLayer" && $0.payloadLayerIDs == [layer.id]
            }
            return matches.count == 1
                && MapContextComponentResolver.exactVectorLayers(for: matches[0], candidates: visibleLayers).count == 1
        }
        let hit = MapVectorFeatureHitTester.closestFeature(at: location, transform: transform,
            layers: exactLayers, tolerance: 8,
            lineWidth: { layer, feature in
                let style = MapVectorStyleResolver.values(layerID: layer.id, feature: feature,
                    definitionID: MapVectorStyleDefinitionIDs.primaryDefinition(for: feature.kind),
                    presentations: mapState.vectorStyles)
                return scaledMetric(Self.safeLineWidth(style.penWidth))
            },
            pointDiameter: { layer, feature in
                let style = MapVectorStyleResolver.values(layerID: layer.id, feature: feature,
                    definitionID: MapVectorStyleDefinitionIDs.primaryDefinition(for: feature.kind),
                    presentations: mapState.vectorStyles)
                return scaledMetric(Self.safePointDiameter(style.pointSize))
            })
        guard let hit, let layer = exactLayers.only(where: { $0.id == hit.layerID }),
              let feature = layer.features.only(where: {
                  $0.stableIdentity == hit.featureIdentity && $0.hasUniqueStableIdentity
              }),
              let row = rows.only(where: {
                  $0.payloadKind == "MapLayer" && $0.payloadLayerIDs == [layer.id]
              }) else { return nil }

        let selectedBeforeContextClick = mapState.selectedVectorFeatureIdentities(in: layer)
        let selectionMode = MapVectorFeatureContextSelection.mode(
            clickedFeatureIdentity: feature.stableIdentity,
            selectedFeatureIdentities: selectedBeforeContextClick,
            modifiers: modifiers)
        if let asset = store.assets.first(where: {
            SourceFilePaths.canonical($0.url) == SourceFilePaths.canonical(layer.url)
        }) {
            store.select(asset)
        }
        store.activateMap(mapID)
        mapState.selectSourceContext(row.contextIdentity)
        guard mapState.selectVectorFeature(feature, in: layer, mode: selectionMode) else { return nil }
        if feature.kind == .line, let pathID = nearestPathIdentity(feature, at: location, transform: transform) {
            mapState.selectedLineIdentity = pathID
        }
        let selectedIdentities = mapState.selectedVectorFeatureIdentities(in: layer)
        let identities = layer.features.filter { selectedIdentities.contains($0.stableIdentity) }.map(\.stableIdentity)
        guard !identities.isEmpty else { return nil }
        store.selectedFeatureID = mapState.selectedFeatureID
        store.inspectorMode = .components
        store.showInspector = true
        return makeContextSnapshot(row: row, layer: layer, clickedFeature: feature,
            identities: identities)
    }

    @MainActor
    private func blankContextSnapshot(at location: CGPoint,
                                      transform: MapTransform) -> MapBlankContextCapture? {
        guard store.existingMapState(for: mapID) === mapState,
              mapState.kind != .unsupported else { return nil }
        let session = mapState.backgroundMapSession
        return MapBlankContextCapture.make(projectSessionID: store.projectSessionID,
            mapID: mapID, mapState: mapState,
            mapIdentity: store.mapIdentityRequest(for: mapID),
            backgroundSession: session, settings: session.settings,
            projectionType: store.document?.projectionType ?? "",
            projectionValue: store.document?.projectionValue ?? "",
            location: location, transform: transform)
    }

    @MainActor
    private func performBlankContextAction(_ action: MapBlankContextMenuAction,
                                           captured: MapBlankContextCapture) {
        guard action == .copyHoveredTileJSON,
              captured.canCopyHoveredTileJSON,
              isCurrentBlankContext(captured) else { return }
        let session = mapState.backgroundMapSession
        let point = BackgroundMapCoordinate(x: captured.worldPoint.x, y: captured.worldPoint.y)
        Task { @MainActor in
            var didCopy = false
            do {
                let result = try await session.copyHoveredTileJSON(at: point) { rawJSON in
                    guard self.isCurrentBlankContext(captured) else { return }
                    self.store.system.copy(rawJSON)
                    didCopy = true
                }
                guard self.isCurrentBlankContext(captured) else { return }
                if didCopy { return }
                if result.status != "available" {
                    self.store.errorMessage = L10n.text(result.message
                        ?? (result.status == "outsideCoverage"
                            ? "The hovered tile is outside the background map coverage."
                            : "The background map tile is unavailable."))
                } else {
                    self.store.errorMessage = L10n.text("The map or camera changed before the hovered tile could be copied.")
                }
            } catch is CancellationError {
                return
            } catch {
                guard self.isCurrentBlankContext(captured) else { return }
                self.store.errorMessage = L10n.text(error.localizedDescription)
            }
        }
    }

    @MainActor
    private func isCurrentBlankContext(_ captured: MapBlankContextCapture) -> Bool {
        guard captured.mapID == mapID,
              store.projectSessionID == captured.projectSessionID,
              store.existingMapState(for: mapID) === mapState,
              mapState.kind != .unsupported else { return false }
        let points = mapState.transformPoints(vectors: store.mapLayers, rasters: store.rasterLayers)
        let currentTransform = MapTransform(points: points,
            size: mapState.canvasPixelSize, scale: mapState.scale, offset: mapState.offset)
        let currentPoint = currentTransform.world(CGPoint(x: CGFloat(captured.screenX), y: CGFloat(captured.screenY)))
        return MapBlankContextCurrentness.matches(captured,
            projectSessionID: store.projectSessionID, mapID: mapID, mapState: mapState,
            mapIdentity: store.mapIdentityRequest(for: mapID),
            backgroundSession: mapState.backgroundMapSession,
            settings: mapState.backgroundMapSession.settings,
            projectionType: store.document?.projectionType ?? "",
            projectionValue: store.document?.projectionValue ?? "",
            currentViewport: MapBlankContextCapture.viewport(transform: currentTransform),
            currentWorldPoint: currentPoint)
    }

    private func makeContextSnapshot(row: MapSourceRenderRecord, layer: MapVectorLayer,
                                     clickedFeature: MapFeature,
                                     identities: [String]) -> MapVectorFeatureContextSnapshot? {
        guard !identities.isEmpty, Set(identities).count == identities.count else { return nil }
        let selected = layer.features.filter { identities.contains($0.stableIdentity) }
        guard selected.count == identities.count,
              selected.allSatisfy({ $0.hasUniqueStableIdentity }),
              selected.allSatisfy({ feature in
                  layer.features.filter({ $0.stableIdentity == feature.stableIdentity }).count == 1
              }) else { return nil }
        let editor = mapState.polylineEditor
        let scope = editor.currentScope
        let editorOwnsLayer = scope?.projectSessionID == store.projectSessionID
            && scope?.mapID == mapID && scope?.layerID == layer.id
            && scope?.canonicalPath == SourceFilePaths.canonical(layer.url)
            && editor.currentSourceRevision?.caseInsensitiveCompare(layer.sourceRevision ?? "") == .orderedSame
        let selectedIDs = Set(identities)
        let editorCanDelete = editorOwnsLayer
            && editor.canDeleteMapFeatures(selectedIDs, in: layer)
        let editorCanUndo = editorOwnsLayer && editor.canUndo && !editor.isBusy && !editor.isSourceStale && editor.isEditAllowed
        let editorCanRedo = editorOwnsLayer && editor.canRedo && !editor.isBusy && !editor.isSourceStale && editor.isEditAllowed
        let editorCanSave = editorOwnsLayer && editor.canCommitDraft
        let canPaste = selected.contains(where: { $0.kind == .line })
            && ["geojson", "json"].contains(layer.url.pathExtension.lowercased())
            && (try? GeoprocessingPolylineClipboard.read(system: store.system))?.coordinateProjectionWKT
                == (layer.targetProjectionWKT ?? layer.sourceProjectionWKT)
        return MapVectorFeatureContextSnapshot(projectSessionID: store.projectSessionID,
            mapID: mapID, contextIdentity: row.contextIdentity, layer: layer,
            clickedFeatureIdentity: clickedFeature.stableIdentity,
            selectedFeatureIdentities: identities, selectedFeatures: selected,
            editorCanDeleteSelectedFeatures: editorCanDelete, editorCanUndo: editorCanUndo,
            editorCanRedo: editorCanRedo, editorCanSave: editorCanSave,
            canPasteCopiedLines: canPaste)
    }

    private func performContextAction(_ action: MapVectorFeatureContextAction,
                                      captured: MapVectorFeatureContextSnapshot,
                                      openWindow: OpenWindowAction) {
        guard let current = currentContext(for: captured) else { return }
        switch action {
        case .zoomTo:
            let points = current.selectedFeatures.flatMap { $0.paths.flatMap { $0 } }
            guard !points.isEmpty,
                  let viewport = MapVectorFeatureContextGeometry.viewport(
                    for: current.selectedFeatures, current: mapState.currentExtent) else {
                store.errorMessage = L10n.text("The selected feature has no mappable geometry.")
                return
            }
            mapState.viewport = viewport
            store.activateMap(mapID)
        case .copySelection:
            copySelection(current)
        case .viewAttributes:
            guard current.isShapefile, let rowID = current.focusRowID else { return }
            openWindow(value: AttributeTableRoute(path: current.canonicalSourcePath, focusRowID: rowID))
        case .exportSelectedFeatures:
            guard current.isShapefile else { return }
            let family = store.sourceMapVectorFamilyCaptures[mapID]?[current.canonicalSourcePath]
            Task { @MainActor in
                do {
                    if let url = try await MapShapefileSelectedFeatureExporter.export(
                        current, family: family, using: store.system) {
                        store.system.reveal(url)
                    }
                } catch { store.errorMessage = L10n.text(error.localizedDescription) }
            }
        case .editLines:
            openLineEditor(current)
        case .pasteCopiedLines:
            pasteLines(current)
        case .deleteSelectedFeatures:
            guard current.hasSelectedLines else { return }
            let editor = mapState.polylineEditor
            let selectedIDs = Set(current.selectedFeatureIdentities)
            guard editor.canDeleteMapFeatures(selectedIDs, in: current.layer) else { return }
            Task { @MainActor in
                guard editor.selectMapFeatures(selectedIDs, in: current.layer),
                      await editor.deleteMapFeatures(selectedIDs, in: current.layer) else {
                    if let message = editor.errorMessage { store.errorMessage = L10n.text(message) }
                    return
                }
            }
        case .undoMapEdit:
            guard editorMatches(current), mapState.polylineEditor.canUndo else { return }
            Task { @MainActor in _ = await mapState.polylineEditor.undo() }
        case .redoMapEdit:
            guard editorMatches(current), mapState.polylineEditor.canRedo else { return }
            Task { @MainActor in _ = await mapState.polylineEditor.redo() }
        case .saveMapEdits:
            guard editorMatches(current), mapState.polylineEditor.canCommitDraft else { return }
            Task { @MainActor in _ = await mapState.polylineEditor.save() }
        }
    }

    private func currentContext(for captured: MapVectorFeatureContextSnapshot) -> MapVectorFeatureContextSnapshot? {
        guard captured.mapID == mapID, captured.projectSessionID == store.projectSessionID,
              store.existingMapState(for: mapID) === mapState,
              mapState.selectedSourceContextIdentity == captured.contextIdentity,
              let row = MapContextComponentResolver.visibleRows(mapState.sourceMapRenderRows, mapID: mapID)
                .only(where: { $0.contextIdentity == captured.contextIdentity }),
              let layer = visibleLayers.only(where: {
                  $0.id == captured.layer.id
                    && SourceFilePaths.canonical($0.url) == captured.canonicalSourcePath
                    && $0.sourceRevision == captured.sourceRevision
              }),
              MapContextComponentResolver.exactVectorLayers(for: row, candidates: visibleLayers)
                .only(where: { $0.id == layer.id }) != nil,
              mapState.selectedVectorFeatureIdentities(in: layer) == Set(captured.selectedFeatureIdentities),
              let clicked = layer.features.only(where: { $0.stableIdentity == captured.clickedFeatureIdentity }) else { return nil }
        return makeContextSnapshot(row: row, layer: layer, clickedFeature: clicked,
            identities: captured.selectedFeatureIdentities)
    }

    private func editorMatches(_ context: MapVectorFeatureContextSnapshot) -> Bool {
        let scope = mapState.polylineEditor.currentScope
        return scope?.projectSessionID == context.projectSessionID
            && scope?.mapID == context.mapID && scope?.layerID == context.layer.id
            && scope?.canonicalPath == context.canonicalSourcePath
            && mapState.polylineEditor.currentSourceRevision?.caseInsensitiveCompare(context.sourceRevision ?? "") == .orderedSame
    }

    private func openLineEditor(_ context: MapVectorFeatureContextSnapshot) {
        guard context.hasSelectedLines else { return }
        let identities = Set(context.selectedFeatureIdentities)
        Task { @MainActor in
            guard await store.openPolylineEditor(context.layer, mapID: context.mapID),
                  store.projectSessionID == context.projectSessionID,
                  let layer = mapState.vectors(store.mapLayers).only(where: {
                      $0.id == context.layer.id
                        && SourceFilePaths.canonical($0.url) == context.canonicalSourcePath
                        && $0.sourceRevision == context.sourceRevision
                  }),
                  mapState.polylineEditor.selectMapFeatures(identities, in: layer) else {
                if let error = mapState.polylineEditor.errorMessage { store.errorMessage = L10n.text(error) }
                return
            }
        }
    }

    private func pasteLines(_ context: MapVectorFeatureContextSnapshot) {
        guard context.hasSelectedLines,
              ["geojson", "json"].contains(context.layer.url.pathExtension.lowercased()) else { return }
        Task { @MainActor in
            guard await store.openPolylineEditor(context.layer, mapID: context.mapID),
                  store.projectSessionID == context.projectSessionID,
                  let layer = mapState.vectors(store.mapLayers).only(where: {
                      $0.id == context.layer.id
                        && SourceFilePaths.canonical($0.url) == context.canonicalSourcePath
                        && $0.sourceRevision == context.sourceRevision
                  }),
                  mapState.polylineEditor.supportsAddingLines else { return }
            let destinationProjection = layer.targetProjectionWKT ?? layer.sourceProjectionWKT
            _ = await mapState.polylineEditor.pasteCopiedPolylines(system: store.system,
                destinationProjectionWKT: destinationProjection)
        }
    }

    private func copySelection(_ context: MapVectorFeatureContextSnapshot) {
        do {
            let payload = MapVectorFeatureClipboard.make(from: context)
            let typed = try JSONEncoder().encode(payload)
            var representations = [MapVectorFeatureClipboard.type: typed]
            if let lines = MapVectorFeatureClipboard.compatibilityPolylineClipboard(from: context) {
                try lines.validate()
                representations[GeoprocessingPolylineClipboard.type] = try JSONEncoder().encode(lines)
            }
            guard store.system.writeClipboard([ClipboardItem(representations: representations)]) else {
                throw BackendServiceError(code: "clipboardFailure", message: "The selected features could not be copied to the clipboard.")
            }
        } catch { store.errorMessage = L10n.text(error.localizedDescription) }
    }

    private func nearestPathIdentity(_ feature: MapFeature, at location: CGPoint,
                                     transform: MapTransform) -> String? {
        guard feature.pathStableIdentities.count == feature.paths.count else { return nil }
        return feature.paths.indices.compactMap { index -> (String, CGFloat)? in
            let component = MapFeature(id: feature.id, kind: .line, paths: [feature.paths[index]],
                attributes: feature.attributes)
            let distance = MapVectorFeatureHitTester.distance(from: location, to: component,
                transform: transform, lineWidth: 4)
            return distance.isFinite ? (feature.pathStableIdentities[index], distance) : nil
        }.min { $0.1 < $1.1 }?.0
    }

    private func scaledMetric(_ value: CGFloat) -> CGFloat {
        WorkspaceRenderScaling.metric(Double(value), factor: renderScaling.factor)
    }

    static func safeLineWidth(_ value: Double) -> CGFloat {
        guard value.isFinite else { return 1 }
        return CGFloat(max(value, 0))
    }

    static func safePointDiameter(_ value: Int) -> CGFloat {
        CGFloat(max(value, 0))
    }
}

private extension Collection {
    var only: Element? {
        count == 1 ? first : nil
    }

    func only(where predicate: (Element) throws -> Bool) rethrows -> Element? {
        let matches = try filter(predicate)
        return matches.count == 1 ? matches.first : nil
    }
}
