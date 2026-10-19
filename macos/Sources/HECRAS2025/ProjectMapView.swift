import AppKit
import RASWorkspaceCore
import SwiftUI

// Native map work surface in the position of RasContent.BackgroundMapPanel.
// Imported vector rendering and HDF-backed contexts are wired incrementally;
// an empty project displays an empty map rather than invented hydraulic data.
struct ProjectMapView: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject private var mapState: MapState
    @ObservedObject private var calculatorRegistry: CalculatorLayerRegistry
    let mapID: UUID
    init(store: WorkspaceStore, mapID: UUID = MapState.projectMapID) {
        self.store = store; self.mapID = mapID; self.mapState = store.mapState(for: mapID)
        self.calculatorRegistry = store.calculatorLayerRegistry
    }
    private var scale: CGFloat { get { mapState.scale } nonmutating set { mapState.scale = newValue } }
    private var offset: CGSize { get { mapState.offset } nonmutating set { mapState.offset = newValue } }
    @GestureState private var dragOffset = CGSize.zero
    @State private var pointer: MapPoint?
    @State private var screenPointer: CGPoint?
    @State private var mapModifierFlags: NSEvent.ModifierFlags = []
    @GestureState private var isDragging = false
    @StateObject private var projectionPresentation = MapProjectionPresentation()
    @StateObject private var linkedFeatureSelectionSession = MapLinkedFeatureSelectionSession()
    @State private var showScaleBar = true
    @State private var showMapOverlays = true
    @State private var overlayOpacity = 1.0
    private var visibleLayers: [MapVectorLayer] {
        MapRenderComposition.vectorLayers(records: mapState.sourceMapRenderRows,
            candidates: mapState.visibleVectors(store.mapLayers))
    }
    @ViewBuilder
    private func vectorSurface(offset: CGSize) -> some View {
        if let provider = store.vectorSymbologyProvider as? WorkspaceVectorSymbologyProvider {
            MapVectorPlotSurface(store: store, mapState: mapState, provider: provider,
                mapID: mapID, scale: scale, offset: offset, pointer: $pointer,
                orderedLayers: visibleLayers)
        } else {
            VectorMapCanvas(store: store, mapState: mapState, mapID: mapID,
                scale: scale, offset: offset, pointer: $pointer, orderedLayers: visibleLayers)
        }
    }

    private var orderedRasterLayers: [MapRasterLayer] {
        let candidates = mapState.rasters(store.rasterLayers) + mapState.associatedMapLayers.visibleLayers
        return MapRenderComposition.rasterLayers(records: mapState.sourceMapRenderRows,
            candidates: candidates, hiddenLayerIDs: mapState.hiddenLayers)
    }
    private var liveScreenRasterCellSize: Double? {
        // TiledMap.SetWindow derives LiveScreenRaster.CellSize as the current
        // world extent width divided by Canvas.ActualWidth. MapTransform.factor
        // is the inverse mapping (screen points per world unit), and SwiftUI's
        // GeometryReader size uses the same logical-point coordinate space.
        // This is camera state, not a selected/visible Result raster property.
        let points = mapState.transformPoints(vectors: store.mapLayers, rasters: store.rasterLayers)
        guard mapState.canvasPixelSize.width > 0, mapState.canvasPixelSize.height > 0 else { return nil }
        let transform = MapTransform(points: points, size: mapState.canvasPixelSize,
            scale: scale, offset: offset)
        let factor = Double(transform.factor)
        guard factor.isFinite, factor > 0 else { return nil }
        let cellSize = 1 / factor
        return cellSize.isFinite && cellSize > 0 ? cellSize : nil
    }
    private var mapToolIsActive: Bool {
        isDragging || !mapState.preview.isEmpty || mapState.polylineEditor.isBusy
            || !mapState.polylineEditor.previewPoints.isEmpty
            || mapState.polylineEditor.endpointAttachDraft != nil
            || !["select", "Map.Pan"].contains(mapState.toolID)
    }
    private var visibleLayerCount: Int {
        visibleLayers.count
            + orderedRasterLayers.count
            + calculatorRegistry.layers(mapID: mapID, projectSessionID: store.projectSessionID,
                workflowIdentity: store.mapWorkflowIdentity(mapID)).count
            + mapState.projectGeometryMap.visibleChildLayerCount
            + mapState.boundaryMap.visibleLines.count
            + Set(mapState.terrainInputMap.features.map(\.inputNodeID)).count
    }
    private var vectorSelectionReconciliationKey: [String] {
        guard let selectedLayer = mapState.selectedLayerID else { return [] }
        return visibleLayers.filter { $0.id == selectedLayer }.flatMap { layer in
            [layer.id, SourceFilePaths.canonical(layer.url), layer.sourceRevision ?? ""]
                + layer.features.filter { mapState.selectedFeatureIdentities.contains($0.stableIdentity) }
                    .map { $0.stableIdentity + ":" + String($0.hasUniqueStableIdentity) }
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            ProjectMapTopChrome(store: store, mapState: mapState, mapID: mapID,
                showScaleBar: $showScaleBar, showMapOverlays: $showMapOverlays,
                overlayOpacity: $overlayOpacity)

            GeometryReader { proxy in
                ZStack {
                    Color(nsColor: .textBackgroundColor)
                    BackgroundMapCanvas(session: mapState.backgroundMapSession,
                        points: mapState.transformPoints(vectors: store.mapLayers, rasters: store.rasterLayers),
                        scale: scale,
                        offset: CGSize(width: offset.width + dragOffset.width,
                                       height: offset.height + dragOffset.height))
                    Canvas { context, size in
                        if mapState.showGrid {
                            let spacing: CGFloat = 64 * scale
                            let translation = CGSize(width: offset.width + dragOffset.width, height: offset.height + dragOffset.height)
                            var grid = Path()
                            for column in 0...Int(size.width / max(spacing, 8)) + 2 {
                                let x = CGFloat(column) * max(spacing, 8) + translation.width.truncatingRemainder(dividingBy: max(spacing, 8))
                                grid.move(to: CGPoint(x: x, y: 0)); grid.addLine(to: CGPoint(x: x, y: size.height))
                            }
                            for row in 0...Int(size.height / max(spacing, 8)) + 2 {
                                let y = CGFloat(row) * max(spacing, 8) + translation.height.truncatingRemainder(dividingBy: max(spacing, 8))
                                grid.move(to: CGPoint(x: 0, y: y)); grid.addLine(to: CGPoint(x: size.width, y: y))
                            }
                            context.stroke(grid, with: .color(.secondary.opacity(0.10)), lineWidth: 0.5)
                        }
                    }
                    RasterMapCanvas(store: store, mapState: mapState, scale: scale,
                        offset: CGSize(width: offset.width + dragOffset.width, height: offset.height + dragOffset.height),
                        orderedLayers: orderedRasterLayers)
                    CalculatorMapLayerCanvas(store: store, mapID: mapID,
                        points: mapState.transformPoints(vectors: store.mapLayers, rasters: store.rasterLayers),
                        scale: scale,
                        offset: CGSize(width: offset.width + dragOffset.width,
                                       height: offset.height + dragOffset.height),
                        viewport: mapState.resultViewport)
                    MapResultDiagnosticCanvas(session: mapState.resultMap,
                        points: mapState.transformPoints(vectors: store.mapLayers, rasters: store.rasterLayers),
                        scale: scale,
                        offset: CGSize(width: offset.width + dragOffset.width,
                                       height: offset.height + dragOffset.height),
                        visibleLayerIDs: Set(orderedRasterLayers.map(\.id)))
                    ProjectGeometryMapCanvas(store: store, mapState: mapState,
                        session: mapState.projectGeometryMap, mapID: mapID, scale: scale,
                        offset: CGSize(width: offset.width + dragOffset.width,
                                       height: offset.height + dragOffset.height), isInteractive: false)
                    MapTreeMeshErrorOverlayCanvas(session: mapState.meshErrors, mapState: mapState,
                        points: mapState.transformPoints(vectors: store.mapLayers, rasters: store.rasterLayers),
                        scale: scale,
                        offset: CGSize(width: offset.width + dragOffset.width,
                                       height: offset.height + dragOffset.height))
                    BoundaryMapCanvas(session: mapState.boundaryMap, mapState: mapState,
                        points: mapState.transformPoints(vectors: store.mapLayers, rasters: store.rasterLayers),
                        scale: scale,
                        offset: CGSize(width: offset.width + dragOffset.width,
                                       height: offset.height + dragOffset.height), isInteractive: false)
                    TerrainInputMapCanvas(session: mapState.terrainInputMap,
                        features: mapState.terrainInputMap.features,
                        points: mapState.transformPoints(vectors: store.mapLayers, rasters: store.rasterLayers),
                        scale: scale,
                        offset: CGSize(width: offset.width + dragOffset.width,
                                       height: offset.height + dragOffset.height))
                    vectorSurface(offset: CGSize(width: offset.width + dragOffset.width,
                                                 height: offset.height + dragOffset.height))
                    MapResultVelocityParticlesCanvas(session: mapState.resultMap.velocityParticles,
                        points: mapState.transformPoints(vectors: store.mapLayers, rasters: store.rasterLayers),
                        scale: scale,
                        offset: CGSize(width: offset.width + dragOffset.width,
                                       height: offset.height + dragOffset.height))
                    MapDynamicProfileOverlayCanvas(session: mapState.dynamicProfileOverlay,
                        mapState: mapState,
                        points: mapState.transformPoints(vectors: store.mapLayers, rasters: store.rasterLayers),
                        scale: scale,
                        offset: CGSize(width: offset.width + dragOffset.width,
                                       height: offset.height + dragOffset.height))
                    StoredCulvertParticleCanvas(session: mapState.storedCulvertProfile,
                        points: mapState.transformPoints(vectors: store.mapLayers, rasters: store.rasterLayers),
                        scale: scale,
                        offset: CGSize(width: offset.width + dragOffset.width,
                                       height: offset.height + dragOffset.height),
                        cellSize: liveScreenRasterCellSize,
                        isActive: mapState.selectedSourceContextIdentity
                            == mapState.storedCulvertProfile.sourceContextIdentity)
                    SourceMapVectorLoadProgressView(store: store, mapID: mapID)
                    if store.isMapLoading || store.isRasterMapLoading {
                        VStack(spacing: 12) { ProgressView(); Text("Loading Map Layers…"); Button("Cancel", action: store.cancelMapLoading) }
                            .padding(20).workspaceGlass()
                    } else if visibleLayerCount == 0 { VStack(spacing: 12) {
                        Image(systemName: "map").font(.system(size: 38, weight: .light)).foregroundStyle(.tertiary)
                        Text(mapTitle).font(.headline)
                        if mapState.kind != .unsupported {
                            Button("Add Map Layer…") { store.addMapLayer(for: mapID) }.disabled(!store.hasProject)
                        }
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    }
                    MapPointerInteraction(onModifiersChanged: { mapModifierFlags = $0 }) { location, delta in
                        let toolIsActive = isDragging || !mapState.preview.isEmpty
                            || mapState.polylineEditor.isBusy
                            || !mapState.polylineEditor.previewPoints.isEmpty
                            || mapState.polylineEditor.endpointAttachDraft != nil
                        guard MapCanvasNavigation.allowsWheelZoom(toolIsActive: toolIsActive),
                              let camera = MapPointerCamera.wheelZoom(scale: scale, offset: offset,
                                canvasSize: proxy.size, pointer: location, delta: delta) else { return }
                        store.activateMap(mapID)
                        scale = camera.scale
                        offset = camera.offset
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)
                    MapSelectionMeasurementRightClickInteraction { location in
                        guard MapSelectionMeasurementTool.selectors.contains(mapState.toolID),
                              let active = MapSelectionMeasurementOwnerResolver.activeVector(
                                projectSessionID: store.projectSessionID, mapState: mapState,
                                visibleLayers: visibleLayers) else { return }
                        let transform = mapTransform(size: proxy.size, scale: scale,
                            offset: CGSize(width: offset.width + dragOffset.width,
                                           height: offset.height + dragOffset.height))
                        mapState.mapSelectionMeasurement.activate(toolID: mapState.toolID, owner: active.owner,
                            store: store, mapState: mapState)
                        mapState.mapSelectionMeasurement.handleRightClick(location,
                            owner: active.owner, layer: active.layer, transform: transform,
                            store: store, mapState: mapState)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)
                    MapSourceAnnotations(store: store, mapState: mapState,
                        terrainOverlay: store.terrainUSGSTileOverlay,
                        points: mapState.transformPoints(vectors: store.mapLayers, rasters: store.rasterLayers),
                        scale: scale,
                        offset: CGSize(width: offset.width + dragOffset.width,
                                       height: offset.height + dragOffset.height), pointer: screenPointer,
                        allowsTerrainHover: !mapToolIsActive && !mapModifierFlags.contains(.shift))
                    MapSelectionMeasurementCanvas(session: mapState.mapSelectionMeasurement,
                        owner: activeMapToolOwner?.owner,
                        transform: mapTransform(size: proxy.size, scale: scale,
                            offset: CGSize(width: offset.width + dragOffset.width,
                                           height: offset.height + dragOffset.height)))
                }
                .contentShape(Rectangle())
                .gesture(DragGesture().updating($isDragging) { _, state, _ in state = true }
                    .updating($dragOffset) { value, state, _ in
                    if ["Map.Pan", "select"].contains(mapState.toolID) { state = value.translation }
                }.onEnded { value in
                    if ["Map.Pan", "select"].contains(mapState.toolID),
                       let moved = MapPointerCamera.pan(offset: offset, by: value.translation) { offset = moved }
                })
                .simultaneousGesture(MagnifyGesture().onEnded { value in scale = min(max(scale * value.magnification, 0.125), 256) })
                .simultaneousGesture(SpatialTapGesture().onEnded { value in
                    routeTap(value.location, size: proxy.size, scale: scale,
                             offset: CGSize(width: offset.width + dragOffset.width,
                                            height: offset.height + dragOffset.height))
                })
                .simultaneousGesture(SpatialTapGesture(count: 2).onEnded { value in
                    guard !["select", "Map.Pan"].contains(mapState.toolID) else { return }
                    if MapSelectionMeasurementTool.measurements.contains(mapState.toolID) {
                        let owner = MapSelectionMeasurementOwnerResolver.activeTool(
                            projectSessionID: store.projectSessionID, mapState: mapState,
                            visibleLayers: visibleLayers, toolID: mapState.toolID)?.owner
                        let transform = mapTransform(size: proxy.size, scale: scale,
                            offset: CGSize(width: offset.width + dragOffset.width,
                                           height: offset.height + dragOffset.height))
                        mapState.mapSelectionMeasurement.activate(toolID: mapState.toolID, owner: owner,
                            store: store, mapState: mapState)
                        mapState.mapSelectionMeasurement.handleDoubleClick(at: transform.world(value.location),
                            owner: owner, store: store, mapState: mapState)
                    } else if !MapSelectionMeasurementTool.selectors.contains(mapState.toolID) {
                        enqueueInput(.doubleClick, at: value.location, size: proxy.size)
                    }
                })
                .simultaneousGesture(DragGesture().onChanged { value in
                    if MapSelectionMeasurementTool.contains(mapState.toolID) {
                        routeNativeDragChanged(value, size: proxy.size)
                    } else if !["select", "Map.Pan"].contains(mapState.toolID) {
                        enqueueInput(.drag, at: value.location, size: proxy.size)
                    }
                }.onEnded { value in
                    if MapSelectionMeasurementTool.selectors.contains(mapState.toolID) {
                        routeNativeDragEnded(value, size: proxy.size)
                    } else if MapSelectionMeasurementTool.measurements.contains(mapState.toolID) {
                        mapState.mapSelectionMeasurement.finishMeasureDrag()
                    } else if !["select", "Map.Pan"].contains(mapState.toolID) {
                        enqueueInput(.dragEnded, at: value.location, size: proxy.size)
                    }
                })
                .dropDestination(for: String.self) { ids, _ in
                    guard mapState.kind != .unsupported else { return false }
                    let assets = ids.compactMap { id in store.assets.first { $0.id == id } }
                    let availableLayerIDs = Set(store.mapLayers.map(\.id) + store.rasterLayers.map(\.id))
                    let sources = assets.filter { $0.section == .results || availableLayerIDs.contains($0.id) || ["geojson", "json", "shp", "tif", "tiff"].contains($0.url.pathExtension.lowercased()) }
                    guard !sources.isEmpty else { return false }
                    Task { await store.addAssetsToMap(sources, mapID: mapID) }
                    return true
                }
                .dropDestination(for: URL.self) { files, _ in
                    guard store.hasProject, mapState.kind != .unsupported else { return false }
                    let mapFiles = files.filter { $0.isFileURL && ["json", "geojson", "shp", "tif", "tiff"].contains($0.pathExtension.lowercased()) }
                    let project = store.projectSessionID
                    Task {
                        for file in mapFiles {
                            guard store.projectSessionID == project else { return }
                            _ = await store.connectMapSource(file, for: mapID)
                        }
                    }
                    return !mapFiles.isEmpty
                }
                .overlay(alignment: .bottom) {
                    let bottomChromePoints = mapState.transformPoints(
                        vectors: store.mapLayers, rasters: store.rasterLayers)
                    let bottomChromeOffset = CGSize(
                        width: offset.width + dragOffset.width,
                        height: offset.height + dragOffset.height)
                    ProjectMapCanvasBottomChrome(store: store, mapState: mapState,
                        linkedSession: linkedFeatureSelectionSession,
                        canvasSize: proxy.size, visibleLayerCount: visibleLayerCount,
                        vectorLayers: visibleLayers, mapPoints: bottomChromePoints,
                        scale: scale, offset: bottomChromeOffset,
                        showMapOverlays: showMapOverlays, showScaleBar: showScaleBar,
                        overlayOpacity: overlayOpacity, units: projectionPresentation.units)
                }
                .onAppear {
                    synchronizeMapSelectionMeasurementTool()
                    applyPendingViewport(size: proxy.size); updateExtent(size: proxy.size)
                }
                .onChange(of: mapState.toolID) { _, _ in synchronizeMapSelectionMeasurementTool() }
                .onChange(of: mapState.selectedLayerID) { _, _ in synchronizeMapSelectionMeasurementTool() }
                .onChange(of: mapState.selectedSourceContextIdentity) { _, _ in synchronizeMapSelectionMeasurementTool() }
                .onChange(of: proxy.size) { _, _ in applyPendingViewport(size: proxy.size); updateExtent(size: proxy.size) }
                .onChange(of: dragOffset) { _, _ in updateBackgroundViewport(size: proxy.size) }
                .onChange(of: scale) { _, _ in updateExtent(size: proxy.size) }
                .onChange(of: offset) { _, _ in updateExtent(size: proxy.size) }
                .onChange(of: store.mapRevision) { _, _ in updateExtent(size: proxy.size) }
                .onChange(of: store.projectSessionID) { _, _ in
                    synchronizeMapSelectionMeasurementTool()
                    updateExtent(size: proxy.size)
                }
                .onChange(of: store.document?.projectionType) { _, _ in updateExtent(size: proxy.size) }
                .onChange(of: store.document?.projectionValue) { _, _ in updateExtent(size: proxy.size) }
                .onChange(of: mapState.profileRenderRevision) { _, _ in updateExtent(size: proxy.size) }
                .onChange(of: mapState.referenceRevision) { _, _ in updateExtent(size: proxy.size) }
                .onChange(of: mapState.currentExtent?.id) { _, _ in
                    Task { await mapState.projectGeometryMap.updateViewport(mapState.currentExtent) }
                }
                .onChange(of: mapState.resultViewport) { _, viewport in
                    Task { await mapState.associatedMapLayers.updateViewport(viewport) }
                }
                .onChange(of: mapState.boundaryMap.renderRevision) { _, _ in updateExtent(size: proxy.size) }
                .onChange(of: mapState.storedCulvertProfile.renderRevision) { _, _ in updateExtent(size: proxy.size) }
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        mapModifierFlags = NSEvent.modifierFlags
                        screenPointer = location
                        store.activateMap(mapID)
                        let transform = mapTransform(size: proxy.size, scale: scale,
                            offset: CGSize(width: offset.width + dragOffset.width,
                                           height: offset.height + dragOffset.height))
                        pointer = visibleLayerCount == 0 ? nil : transform.world(location)
                        if !["select", "Map.Pan"].contains(mapState.toolID) {
                            enqueueInput(.pointerMoved, at: location, size: proxy.size)
                        }
                    case .ended:
                        pointer = nil
                        screenPointer = nil
                        let owner = MapSelectionMeasurementOwnerResolver.activeTool(
                            projectSessionID: store.projectSessionID, mapState: mapState,
                            visibleLayers: visibleLayers, toolID: mapState.toolID)?.owner
                        mapState.mapSelectionMeasurement.updatePointer(nil, owner: owner)
                    }
                }
                .onChange(of: mapState.viewport?.id) { _, _ in applyPendingViewport(size: proxy.size) }

            }
            if showMapOverlays {
                MapResultProfileControls(mapState: mapState)
                    .frame(maxWidth: .infinity)
                    .opacity(overlayOpacity)
            }
            Divider()
            HStack {
                if pointer != nil { MapPositionIndicator(point: pointer, units: projectionPresentation.units) }
                else { Text("Drag to pan · Pinch to zoom") }
                Spacer(); Text(L10n.format("%d layers", visibleLayerCount)); Text("\(Int(scale * 100))%").monospacedDigit()
            }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 10).frame(height: 26)
        }
        .task(id: store.mapWorkflowIdentity(mapID)) { await store.configureMapResultSources(mapID) }
        .modifier(GdbMapImportPresentation(store: store, mapID: mapID))
        .task(id: [store.projectSessionID.uuidString, store.document?.projectionType ?? "",
            store.document?.projectionValue ?? ""]) {
            await projectionPresentation.resolve(type: store.document?.projectionType ?? "",
                value: store.document?.projectionValue ?? "", provider: store.projectionProvider)
        }
        .onDisappear {
            mapState.mapSelectionMeasurement.close(store: store, mapState: mapState)
            mapState.projectGeometryMap.cancel(); mapState.backgroundMapSession.cancelRendering()
        }
        .onChange(of: mapState.resultSources.sources?.contextToken) { _, _ in store.configureMapResultRendering(mapID) }
        .onChange(of: mapState.resultViewport) { _, viewport in mapState.resultViewportDidChange(viewport) }
        .onChange(of: store.mapWorkflowIdentity(mapID)) { _, identity in
            mapState.retireLinkedResultsIfOwnerChanged(mapWorkflowIdentity: identity)
        }
        .onChange(of: mapState.linkedResultSourceIdentity) { _, identity in
            mapState.retireLinkedResultsIfOwnerChanged(sourceIdentity: identity)
        }
        .onChange(of: mapState.selectedLineIdentity) { _, _ in store.invalidateMapCharts(mapID: mapID) }
        .onChange(of: vectorSelectionReconciliationKey) { _, _ in
            mapState.reconcileVectorFeatureSelection(visibleLayers: visibleLayers)
        }
        .onChange(of: store.mapRevision) { _, _ in
            // A reload must not move the map while a line draft is being edited.
            if !mapState.polylineEditor.hasUnsavedChanges { mapState.resetViewport() }
        }
    }
    private func applyPendingViewport(size: CGSize) {
        guard let request = mapState.viewport else { return }
        let points = mapState.transformPoints(vectors: store.mapLayers, rasters: store.rasterLayers)
        guard let fit = MapViewportFit(request: request, points: points, size: size) else { return }
        if request.animated {
            withAnimation(.easeInOut(duration: 0.25)) { scale = fit.scale; offset = fit.offset }
        } else { scale = fit.scale; offset = fit.offset }
        if mapState.viewport?.id == request.id { mapState.viewport = nil }
    }
    private func updateExtent(size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        mapState.canvasPixelSize = size
        mapState.establishReference(vectors: store.mapLayers, rasters: store.rasterLayers)
        let transform = MapTransform(points: mapState.transformPoints(vectors: store.mapLayers, rasters: store.rasterLayers), size: size, scale: scale, offset: offset)
        let lowerLeft = transform.world(CGPoint(x: 0, y: size.height))
        let upperRight = transform.world(CGPoint(x: size.width, y: 0))
        mapState.currentExtent = ViewportRequest(lowerLeft: lowerLeft, upperRight: upperRight)
        mapState.backgroundMapSession.updateViewport(mapID: mapID,
            projectSessionID: store.projectSessionID,
            projectionType: store.document?.projectionType ?? "",
            projectionValue: store.document?.projectionValue ?? "",
            viewport: BackgroundMapViewport(minX: lowerLeft.x, minY: lowerLeft.y,
                maxX: upperRight.x, maxY: upperRight.y,
                pixelWidth: max(Int(size.width.rounded()), 1),
                pixelHeight: max(Int(size.height.rounded()), 1)),
            worldUnitsPerPixel: 1 / Double(transform.factor))
    }

    private func updateBackgroundViewport(size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        let points = mapState.transformPoints(vectors: store.mapLayers, rasters: store.rasterLayers)
        let liveOffset = CGSize(width: offset.width + dragOffset.width,
                                height: offset.height + dragOffset.height)
        let transform = MapTransform(points: points, size: size, scale: scale, offset: liveOffset)
        let lowerLeft = transform.world(CGPoint(x: 0, y: size.height))
        let upperRight = transform.world(CGPoint(x: size.width, y: 0))
        mapState.backgroundMapSession.updateViewport(mapID: mapID,
            projectSessionID: store.projectSessionID,
            projectionType: store.document?.projectionType ?? "",
            projectionValue: store.document?.projectionValue ?? "",
            viewport: BackgroundMapViewport(minX: lowerLeft.x, minY: lowerLeft.y,
                maxX: upperRight.x, maxY: upperRight.y,
                pixelWidth: max(Int(size.width.rounded()), 1),
                pixelHeight: max(Int(size.height.rounded()), 1)),
            worldUnitsPerPixel: 1 / Double(transform.factor))
    }

    private func mapTransform(size: CGSize, scale: CGFloat, offset: CGSize) -> MapTransform {
        MapTransform(points: mapState.transformPoints(vectors: store.mapLayers, rasters: store.rasterLayers),
                     size: size, scale: scale, offset: offset)
    }

    private func enqueueInput(_ kind: MapInput.Kind, at location: CGPoint, size: CGSize) {
        let transform = mapTransform(size: size, scale: scale, offset: offset)
        if case .pointerMoved = kind, MapSelectionMeasurementTool.measurements.contains(mapState.toolID) {
            let owner = MapSelectionMeasurementOwnerResolver.activeTool(
                projectSessionID: store.projectSessionID, mapState: mapState,
                visibleLayers: visibleLayers, toolID: mapState.toolID)?.owner
            mapState.mapSelectionMeasurement.activate(toolID: mapState.toolID, owner: owner,
                store: store, mapState: mapState)
            mapState.mapSelectionMeasurement.updatePointer(transform.world(location), owner: owner)
            return
        }
        store.enqueueMapInput(MapInput(kind: kind, toolID: mapState.toolID, mapID: mapID,
            point: transform.world(location), screenX: location.x, screenY: location.y,
            modifiers: MapInput.currentModifiers()))
    }

    private func routeTap(_ location: CGPoint, size: CGSize, scale: CGFloat, offset: CGSize) {
        if MapSelectionMeasurementTool.contains(mapState.toolID) {
            guard let active = MapSelectionMeasurementOwnerResolver.activeTool(
                projectSessionID: store.projectSessionID, mapState: mapState,
                visibleLayers: visibleLayers, toolID: mapState.toolID) else { return }
            let transform = mapTransform(size: size, scale: scale, offset: offset)
            mapState.mapSelectionMeasurement.activate(toolID: mapState.toolID, owner: active.owner,
                store: store, mapState: mapState)
            store.activateMap(mapID)
            mapState.mapSelectionMeasurement.handleClick(transform.world(location),
                screenPoint: location, modifiers: MapInput.currentModifiers(), owner: active.owner,
                layer: active.layer, transform: transform, store: store, mapState: mapState)
            return
        }
        guard ["select", "Map.Pan"].contains(mapState.toolID) else {
            let transform = mapTransform(size: size, scale: scale, offset: offset)
            store.enqueueMapInput(MapInput(kind: .click, toolID: mapState.toolID, mapID: mapID,
                point: transform.world(location), screenX: location.x, screenY: location.y,
                modifiers: MapInput.currentModifiers()))
            return
        }

        let transform = mapTransform(size: size, scale: scale, offset: offset)
        let vectorCanvas = VectorMapCanvas(store: store, mapState: mapState, mapID: mapID,
            scale: scale, offset: offset, pointer: $pointer, orderedLayers: visibleLayers)
        let modifiers = MapInput.currentModifiers()
        if vectorCanvas.selectFeature(at: location, transform: transform, modifiers: modifiers) {
            mapState.projectGeometryMap.select(nil)
            mapState.boundaryMap.selectLine(nil)
            return
        }

        if mapState.boundaryMap.selectLine(at: location, transform: transform) {
            mapState.projectGeometryMap.select(nil)
            mapState.clearVectorFeatureSelection()
            return
        }

        // Source Ctrl-click outside a feature keeps its SelectedSet. Native
        // Command has the same behavior; a normal click clears selection.
        if modifiers.contains(.command) || modifiers.contains(.control) { return }
        mapState.clearVectorFeatureSelection()
        let geometryCanvas = ProjectGeometryMapCanvas(store: store, mapState: mapState,
            session: mapState.projectGeometryMap, mapID: mapID,
            scale: scale, offset: offset, isInteractive: false)
        if geometryCanvas.selectFeature(at: location, transform: transform) {
            mapState.boundaryMap.selectLine(nil)
            return
        }

        mapState.projectGeometryMap.select(nil)
        mapState.boundaryMap.selectLine(nil)
    }

    private var activeMapToolOwner: (owner: MapSelectionMeasurementOwner, layer: MapVectorLayer?)? {
        MapSelectionMeasurementOwnerResolver.activeTool(projectSessionID: store.projectSessionID,
            mapState: mapState, visibleLayers: visibleLayers, toolID: mapState.toolID)
    }

    private func synchronizeMapSelectionMeasurementTool() {
        let owner = activeMapToolOwner?.owner
        mapState.mapSelectionMeasurement.activate(toolID: mapState.toolID, owner: owner,
            store: store, mapState: mapState)
    }

    private func routeNativeDragChanged(_ value: DragGesture.Value, size: CGSize) {
        guard let active = activeMapToolOwner else { return }
        let transform = mapTransform(size: size, scale: scale, offset: offset)
        mapState.mapSelectionMeasurement.activate(toolID: mapState.toolID, owner: active.owner,
            store: store, mapState: mapState)
        mapState.mapSelectionMeasurement.dragChanged(start: transform.world(value.startLocation),
            current: transform.world(value.location), modifiers: MapInput.currentModifiers(),
            owner: active.owner, layer: active.layer, mapState: mapState)
    }

    private func routeNativeDragEnded(_ value: DragGesture.Value, size: CGSize) {
        guard let active = activeMapToolOwner else {
            mapState.mapSelectionMeasurement.cancel()
            return
        }
        let transform = mapTransform(size: size, scale: scale, offset: offset)
        mapState.mapSelectionMeasurement.finishDrag(at: transform.world(value.location),
            modifiers: MapInput.currentModifiers(), owner: active.owner,
            layer: active.layer, mapState: mapState)
    }

    private var mapTitle: String {
        switch mapState.kind {
        case .project: return L10n.text("Project Map")
        case .buildable: return L10n.text("Blank Map")
        case .plan: return L10n.text("Plan Map")
        case .geometry: return L10n.text("Geometry Map")
        case .unsupported:
            guard let sourceType = store.mapDocument(for: mapID)?.sourceType, !sourceType.isEmpty else {
                return L10n.text("Map Type")
            }
            return "\(L10n.text("Map Type")): \(sourceType)"
        }
    }
}
