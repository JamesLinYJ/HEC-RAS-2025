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
    @StateObject private var hoverIdentifySession = MapHoverIdentifySession()
    @State private var showScaleBar = true
    @State private var showMapOverlays = true
    @State private var overlayOpacity = 1.0
    private var canvasOffset: CGSize {
        CGSize(width: offset.width + dragOffset.width, height: offset.height + dragOffset.height)
    }
    private var canvasTransformPoints: [MapPoint] {
        mapState.transformPoints(vectors: store.mapLayers, rasters: store.rasterLayers)
    }
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
    private var mapCanPan: Bool {
        mapState.toolID == "Map.Pan" || mapState.toolID == "select"
    }
    private var mapPanGesture: some Gesture {
        DragGesture()
            .updating($isDragging) { _, state, _ in state = true }
            .updating($dragOffset) { value, state, _ in
                if mapCanPan { state = value.translation }
            }
            .onEnded { value in
                if mapCanPan,
                   let moved = MapPointerCamera.pan(offset: offset, by: value.translation) { offset = moved }
            }
    }
    private var mapMagnificationGesture: some Gesture {
        MagnifyGesture().onEnded { value in
            scale = min(max(scale * value.magnification, 0.125), 256)
        }
    }
    private func mapTapGesture(size: CGSize) -> some Gesture {
        SpatialTapGesture().onEnded { value in
            routeTap(value.location, size: size, scale: scale, offset: canvasOffset)
        }
    }
    private func mapDoubleTapGesture(size: CGSize) -> some Gesture {
        SpatialTapGesture(count: 2).onEnded { value in
            guard !mapCanPan else { return }
            if MapSelectionMeasurementTool.measurements.contains(mapState.toolID) {
                let owner = MapSelectionMeasurementOwnerResolver.activeTool(
                    projectSessionID: store.projectSessionID, mapState: mapState,
                    visibleLayers: visibleLayers, toolID: mapState.toolID)?.owner
                let transform = mapTransform(size: size, scale: scale, offset: canvasOffset)
                mapState.mapSelectionMeasurement.activate(toolID: mapState.toolID, owner: owner,
                    store: store, mapState: mapState)
                mapState.mapSelectionMeasurement.handleDoubleClick(at: transform.world(value.location),
                    owner: owner, store: store, mapState: mapState)
            } else if !MapSelectionMeasurementTool.selectors.contains(mapState.toolID) {
                enqueueInput(.doubleClick, at: value.location, size: size)
            }
        }
    }
    private func mapToolDragGesture(size: CGSize) -> some Gesture {
        DragGesture().onChanged { value in
            if MapSelectionMeasurementTool.contains(mapState.toolID) {
                routeNativeDragChanged(value, size: size)
            } else if !mapCanPan {
                enqueueInput(.drag, at: value.location, size: size)
            }
        }.onEnded { value in
            if MapSelectionMeasurementTool.selectors.contains(mapState.toolID) {
                routeNativeDragEnded(value, size: size)
            } else if MapSelectionMeasurementTool.measurements.contains(mapState.toolID) {
                mapState.mapSelectionMeasurement.finishMeasureDrag()
            } else if !mapCanPan {
                enqueueInput(.dragEnded, at: value.location, size: size)
            }
        }
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
    private var hoverVectorSourceIdentity: [String] {
        visibleLayers.flatMap { layer in
            [layer.id, SourceFilePaths.canonical(layer.url), layer.sourceRevision ?? "",
             layer.sourceMapID?.uuidString ?? "", String(layer.features.count)]
        } + [mapState.polylineEditor.draftGeneration]
    }
    private func mapCanvasInteractions(size: CGSize) -> some View {
        ZStack {
            ProjectMapBaseCanvasLayers(store: store, mapState: mapState, mapID: mapID,
                points: canvasTransformPoints,
                scale: scale, offset: canvasOffset, orderedRasterLayers: orderedRasterLayers,
                liveScreenRasterCellSize: liveScreenRasterCellSize,
                vectorSurface: vectorSurface(offset: canvasOffset))
            ProjectMapCanvasStatusOverlays(store: store, mapState: mapState, mapID: mapID,
                hoverSession: hoverIdentifySession, visibleLayerCount: visibleLayerCount,
                mapTitle: mapTitle, canvasSize: size)
            MapPointerInteraction(onModifiersChanged: { mapModifierFlags = $0 }) { location, delta in
                let toolIsActive = isDragging || !mapState.preview.isEmpty
                    || mapState.polylineEditor.isBusy
                    || !mapState.polylineEditor.previewPoints.isEmpty
                    || mapState.polylineEditor.endpointAttachDraft != nil
                guard MapCanvasNavigation.allowsWheelZoom(toolIsActive: toolIsActive),
                      let camera = MapPointerCamera.wheelZoom(scale: scale, offset: offset,
                        canvasSize: size, pointer: location, delta: delta) else { return }
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
                let transform = mapTransform(size: size, scale: scale,
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
                transform: mapTransform(size: size, scale: scale,
                    offset: CGSize(width: offset.width + dragOffset.width,
                                   height: offset.height + dragOffset.height)))
        }
        .contentShape(Rectangle())
        .gesture(mapPanGesture)
        .simultaneousGesture(mapMagnificationGesture)
        .simultaneousGesture(mapTapGesture(size: size))
        .simultaneousGesture(mapDoubleTapGesture(size: size))
        .simultaneousGesture(mapToolDragGesture(size: size))
        .dropDestination(for: String.self) { (ids: [String], _: CGPoint) -> Bool in
            return acceptDroppedAssetIDs(ids)
        }
        .dropDestination(for: URL.self) { (files: [URL], _: CGPoint) -> Bool in
            return acceptDroppedFiles(files)
        }
        .overlay(alignment: .bottom) {
            let bottomChromePoints = mapState.transformPoints(
                vectors: store.mapLayers, rasters: store.rasterLayers)
            let bottomChromeOffset = CGSize(
                width: offset.width + dragOffset.width,
                height: offset.height + dragOffset.height)
            ProjectMapCanvasBottomChrome(store: store, mapState: mapState,
                linkedSession: linkedFeatureSelectionSession,
                canvasSize: size, visibleLayerCount: visibleLayerCount,
                vectorLayers: visibleLayers, mapPoints: bottomChromePoints,
                scale: scale, offset: bottomChromeOffset,
                showMapOverlays: showMapOverlays, showScaleBar: showScaleBar,
                overlayOpacity: overlayOpacity, units: projectionPresentation.units)
        }
    }
    private func mapCanvasCameraEvents(size: CGSize) -> some View {
        mapCanvasInteractions(size: size)
        .onAppear {
            synchronizeMapSelectionMeasurementTool()
            applyPendingViewport(size: size); updateExtent(size: size)
        }
        .onChange(of: mapState.toolID) { _, _ in
            synchronizeMapSelectionMeasurementTool()
            refreshHoverIdentify(size: size)
        }
        .onChange(of: mapState.selectedLayerID) { _, _ in synchronizeMapSelectionMeasurementTool() }
        .onChange(of: mapState.selectedSourceContextIdentity) { _, _ in synchronizeMapSelectionMeasurementTool() }
        .onChange(of: size) { _, _ in applyPendingViewport(size: size); updateExtent(size: size) }
        .onChange(of: dragOffset) { _, _ in
            updateBackgroundViewport(size: size)
            refreshHoverIdentify(size: size)
        }
        .onChange(of: scale) { _, _ in
            updateExtent(size: size)
            refreshHoverIdentify(size: size)
        }
        .onChange(of: offset) { _, _ in
            updateExtent(size: size)
            refreshHoverIdentify(size: size)
        }
        .onChange(of: store.mapRevision) { _, _ in updateExtent(size: size) }
    }
    private var hoverRasterSourceIdentity: [String] {
        store.rasterMapSources.map { source in
            [source.id, source.sourceRevision ?? ""].joined(separator: "|")
        }.sorted()
    }
    private var hoverResultSourceIdentity: [String] {
        mapState.resultMap.nodes.map { node in
            let profile = node.profileIndex.map(String.init) ?? "-1"
            return [node.id, node.selectedMapType ?? "", profile].joined(separator: "|")
        }
    }
    private func mapCanvasSourceEvents(size: CGSize) -> some View {
        mapCanvasCameraEvents(size: size)
        .onChange(of: hoverRasterSourceIdentity) { _, _ in
            refreshHoverIdentify(size: size)
        }
        .onChange(of: mapState.sourceMapRenderRows) { _, _ in
            refreshHoverIdentify(size: size)
        }
        .onChange(of: hoverResultSourceIdentity) { _, _ in
            refreshHoverIdentify(size: size)
        }
        .onChange(of: mapState.associatedMapLayers.renderRevision) { _, _ in
            refreshHoverIdentify(size: size)
        }
        .onChange(of: mapState.projectGeometryMap.renderRevision) { _, _ in
            refreshHoverIdentify(size: size)
        }
    }
    private func mapCanvasVisibilityEvents(size: CGSize) -> some View {
        mapCanvasSourceEvents(size: size)
        .onChange(of: mapState.hiddenLayers) { _, _ in
            refreshHoverIdentify(size: size)
        }
        .onChange(of: mapState.selectedLayerID) { _, _ in
            refreshHoverIdentify(size: size)
        }
        .onChange(of: mapState.selectedSourceContextIdentity) { _, _ in
            refreshHoverIdentify(size: size)
        }
        .onChange(of: mapModifierFlags) { _, _ in
            refreshHoverIdentify(size: size)
        }
        .onChange(of: isDragging) { _, _ in
            refreshHoverIdentify(size: size)
        }
    }
    private func mapCanvasLifecycleEvents(size: CGSize) -> some View {
        mapCanvasVisibilityEvents(size: size)
        .onChange(of: store.projectSessionID) { _, _ in
            synchronizeMapSelectionMeasurementTool()
            updateExtent(size: size)
            refreshHoverIdentify(size: size)
        }
        .onChange(of: store.document?.projectionType) { _, _ in updateExtent(size: size) }
        .onChange(of: store.document?.projectionValue) { _, _ in updateExtent(size: size) }
        .onChange(of: mapState.profileRenderRevision) { _, _ in updateExtent(size: size) }
        .onChange(of: hoverVectorSourceIdentity) { _, _ in
            refreshHoverIdentify(size: size)
        }
        .onChange(of: mapState.referenceRevision) { _, _ in updateExtent(size: size) }
        .onChange(of: mapState.currentExtent?.id) { _, _ in
            Task { await mapState.projectGeometryMap.updateViewport(mapState.currentExtent) }
        }
        .onChange(of: mapState.resultViewport) { _, viewport in
            Task { await mapState.associatedMapLayers.updateViewport(viewport) }
        }
        .onChange(of: mapState.boundaryMap.renderRevision) { _, _ in updateExtent(size: size) }
        .onChange(of: mapState.storedCulvertProfile.renderRevision) { _, _ in updateExtent(size: size) }
    }
    private func mapCanvasSurface(size: CGSize) -> some View {
        mapCanvasLifecycleEvents(size: size)
        .onContinuousHover { phase in
            switch phase {
            case .active(let location):
                mapModifierFlags = NSEvent.modifierFlags
                screenPointer = location
                store.activateMap(mapID)
                let transform = mapTransform(size: size, scale: scale,
                    offset: CGSize(width: offset.width + dragOffset.width,
                                   height: offset.height + dragOffset.height))
                pointer = visibleLayerCount == 0 ? nil : transform.world(location)
                if !["select", "Map.Pan"].contains(mapState.toolID) {
                    enqueueInput(.pointerMoved, at: location, size: size)
                }
                updateHoverIdentify(at: location, size: size)
            case .ended:
                pointer = nil
                screenPointer = nil
                hoverIdentifySession.cancel()
                let owner = MapSelectionMeasurementOwnerResolver.activeTool(
                    projectSessionID: store.projectSessionID, mapState: mapState,
                    visibleLayers: visibleLayers, toolID: mapState.toolID)?.owner
                mapState.mapSelectionMeasurement.updatePointer(nil, owner: owner)
            }
        }
        .onChange(of: mapState.viewport?.id) { _, _ in applyPendingViewport(size: size) }
    }
    var body: some View {
        VStack(spacing: 0) {
            ProjectMapTopChrome(store: store, mapState: mapState, mapID: mapID,
                showScaleBar: $showScaleBar, showMapOverlays: $showMapOverlays,
                overlayOpacity: $overlayOpacity)

            GeometryReader { proxy in
                mapCanvasSurface(size: proxy.size)

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
            hoverIdentifySession.cancel()
            mapState.mapSelectionMeasurement.close(store: store, mapState: mapState)
            mapState.projectGeometryMap.cancel(); mapState.backgroundMapSession.cancelRendering()
        }
        .onChange(of: mapState.resultSources.sources?.contextToken) { _, _ in store.configureMapResultRendering(mapID) }
        .onChange(of: mapState.resultViewport) { _, viewport in mapState.resultViewportDidChange(viewport) }
        .onChange(of: store.mapWorkflowIdentity(mapID)) { _, identity in
            mapState.retireLinkedResultsIfOwnerChanged(mapWorkflowIdentity: identity)
            hoverIdentifySession.cancel()
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

    private func acceptDroppedAssetIDs(_ identifiers: [String]) -> Bool {
        guard mapState.kind != .unsupported else { return false }
        let assets = identifiers.compactMap { identifier in
            store.assets.first { $0.id == identifier }
        }
        let availableLayerIDs = Set(store.mapLayers.map(\.id) + store.rasterLayers.map(\.id))
        let supportedExtensions: Set<String> = ["geojson", "json", "shp", "tif", "tiff"]
        let sources = assets.filter { asset in
            asset.section == .results || availableLayerIDs.contains(asset.id)
                || supportedExtensions.contains(asset.url.pathExtension.lowercased())
        }
        guard !sources.isEmpty else { return false }
        Task { await store.addAssetsToMap(sources, mapID: mapID) }
        return true
    }

    private func acceptDroppedFiles(_ files: [URL]) -> Bool {
        guard store.hasProject, mapState.kind != .unsupported else { return false }
        let supportedExtensions: Set<String> = ["json", "geojson", "shp", "tif", "tiff"]
        let mapFiles = files.filter { file in
            file.isFileURL && supportedExtensions.contains(file.pathExtension.lowercased())
        }
        guard !mapFiles.isEmpty else { return false }
        let projectSessionID = store.projectSessionID
        Task {
            for file in mapFiles {
                guard store.projectSessionID == projectSessionID else { return }
                _ = await store.connectMapSource(file, for: mapID)
            }
        }
        return true
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

    private func refreshHoverIdentify(size: CGSize) {
        guard let screenPointer else {
            hoverIdentifySession.cancel()
            return
        }
        updateHoverIdentify(at: screenPointer, size: size)
    }

    private func updateHoverIdentify(at location: CGPoint, size: CGSize) {
        guard !mapToolIsActive, !mapModifierFlags.contains(.shift),
              visibleLayerCount > 0, size.width > 0, size.height > 0 else {
            hoverIdentifySession.cancel()
            return
        }
        let transform = mapTransform(size: size, scale: scale,
            offset: CGSize(width: offset.width + dragOffset.width,
                           height: offset.height + dragOffset.height))
        let worldUnitsPerScreenPoint = 1 / Double(transform.factor)
        let vectorEntries = MapHoverIdentifyVector.entries(at: location, transform: transform,
            mapID: mapID, records: mapState.sourceMapRenderRows, candidates: visibleLayers,
            selectedLayerID: mapState.selectedLayerID,
            selectedContextIdentity: mapState.selectedSourceContextIdentity,
            vectorStyles: mapState.vectorStyles)
        guard let flight = store.captureMapHoverIdentify(mapID: mapID,
            point: transform.world(location),
            worldUnitsPerScreenPoint: worldUnitsPerScreenPoint,
            screenPoint: location, localEntries: vectorEntries) else {
            hoverIdentifySession.cancel()
            return
        }
        hoverIdentifySession.update(flight) {
            store.currentMapHoverIdentifySourceIdentity(mapID: mapID)
        }
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

/// Keeps the map's rendering stack out of the interaction modifier expression.
/// The visual order is intentional: source rasters and project overlays precede
/// vectors, with transient result and culvert marks above their source layers.
private struct ProjectMapBaseCanvasLayers<VectorSurface: View>: View {
    let store: WorkspaceStore
    let mapState: MapState
    let mapID: UUID
    let points: [MapPoint]
    let scale: CGFloat
    let offset: CGSize
    let orderedRasterLayers: [MapRasterLayer]
    let liveScreenRasterCellSize: Double?
    let vectorSurface: VectorSurface

    var body: some View {
        ZStack {
            Color(nsColor: .textBackgroundColor)
            BackgroundMapCanvas(session: mapState.backgroundMapSession,
                points: points, scale: scale, offset: offset)
            gridCanvas
            RasterMapCanvas(store: store, mapState: mapState, scale: scale,
                offset: offset, orderedLayers: orderedRasterLayers)
            CalculatorMapLayerCanvas(store: store, mapID: mapID,
                points: points, scale: scale, offset: offset,
                viewport: mapState.resultViewport)
            MapResultDiagnosticCanvas(session: mapState.resultMap,
                points: points, scale: scale, offset: offset,
                visibleLayerIDs: Set(orderedRasterLayers.map(\.id)))
            ProjectGeometryMapCanvas(store: store, mapState: mapState,
                session: mapState.projectGeometryMap, mapID: mapID, scale: scale,
                offset: offset, isInteractive: false)
            MapTreeMeshErrorOverlayCanvas(session: mapState.meshErrors, mapState: mapState,
                points: points, scale: scale, offset: offset)
            BoundaryMapCanvas(session: mapState.boundaryMap, mapState: mapState,
                points: points, scale: scale, offset: offset, isInteractive: false)
            TerrainInputMapCanvas(session: mapState.terrainInputMap,
                features: mapState.terrainInputMap.features,
                points: points, scale: scale, offset: offset)
            vectorSurface
            MapResultVelocityParticlesCanvas(session: mapState.resultMap.velocityParticles,
                points: points, scale: scale, offset: offset)
            MapDynamicProfileOverlayCanvas(session: mapState.dynamicProfileOverlay,
                mapState: mapState, points: points, scale: scale, offset: offset)
            StoredCulvertParticleCanvas(session: mapState.storedCulvertProfile,
                points: points, scale: scale, offset: offset,
                cellSize: liveScreenRasterCellSize,
                isActive: mapState.selectedSourceContextIdentity
                    == mapState.storedCulvertProfile.sourceContextIdentity)
        }
    }

    private var gridCanvas: some View {
        Canvas { context, size in
            guard mapState.showGrid else { return }
            let spacing = max(64 * scale, 8)
            var grid = Path()
            for column in 0...Int(size.width / spacing) + 2 {
                let x = CGFloat(column) * spacing + offset.width.truncatingRemainder(dividingBy: spacing)
                grid.move(to: CGPoint(x: x, y: 0))
                grid.addLine(to: CGPoint(x: x, y: size.height))
            }
            for row in 0...Int(size.height / spacing) + 2 {
                let y = CGFloat(row) * spacing + offset.height.truncatingRemainder(dividingBy: spacing)
                grid.move(to: CGPoint(x: 0, y: y))
                grid.addLine(to: CGPoint(x: size.width, y: y))
            }
            context.stroke(grid, with: .color(.secondary.opacity(0.10)), lineWidth: 0.5)
        }
    }
}

/// Transient status and identify visuals are separate from source rendering so
/// the large map stack does not share SwiftUI's type-inference workload with it.
private struct ProjectMapCanvasStatusOverlays: View {
    let store: WorkspaceStore
    let mapState: MapState
    let mapID: UUID
    let hoverSession: MapHoverIdentifySession
    let visibleLayerCount: Int
    let mapTitle: String
    let canvasSize: CGSize

    var body: some View {
        ZStack {
            MapHoverIdentifyOverlay(session: hoverSession)
            SourceMapVectorLoadProgressView(store: store, mapID: mapID)
            if store.isMapLoading || store.isRasterMapLoading {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Loading Map Layers…")
                    Button("Cancel", action: store.cancelMapLoading)
                }
                .padding(20)
                .workspaceGlass()
            } else if visibleLayerCount == 0 {
                VStack(spacing: 12) {
                    Image(systemName: "map")
                        .font(.system(size: 38, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text(mapTitle).font(.headline)
                    if mapState.kind != .unsupported {
                        Button("Add Map Layer…") { store.addMapLayer(for: mapID) }
                            .disabled(!store.hasProject)
                    }
                }
                .frame(width: canvasSize.width, height: canvasSize.height)
            }
        }
    }
}
