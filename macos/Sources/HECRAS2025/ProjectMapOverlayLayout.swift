import RASWorkspaceCore
import SwiftUI

/// Reserves a responsive header for the map toolbar and source actions. The
/// map gesture surface starts below this view, so menus remain reachable
/// without competing with pan, zoom, or selection gestures.
struct ProjectMapTopChrome: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var mapState: MapState
    let mapID: UUID
    @Binding var showScaleBar: Bool
    @Binding var showMapOverlays: Bool
    @Binding var overlayOpacity: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            toolbar
            ScrollView(.horizontal) {
                sourceControls.fixedSize(horizontal: true, vertical: false)
            }
            .scrollIndicators(.hidden)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(alignment: .bottom) { Rectangle().fill(.quaternary).frame(height: 0.5) }
    }

    private var toolbar: some View {
        MapChromeToolbar(store: store, mapState: mapState, mapID: mapID,
            showScaleBar: $showScaleBar, showMapOverlays: $showMapOverlays,
            overlayOpacity: $overlayOpacity)
    }

    private var sourceControls: some View {
        HStack(spacing: 6) {
            MapSourceContextPicker(mapState: mapState)
            CalculatorMapLayerMenu(store: store, mapID: mapID, viewport: mapState.resultViewport)
            if showMapOverlays { MapSourceLegendButton(store: store, mapState: mapState) }
            StoredCulvertParticleSettingsButton(session: mapState.storedCulvertProfile)
            MapSourceStatusControl(geometry: mapState.projectGeometryMap,
                associated: mapState.associatedMapLayers, store: store, mapID: mapID,
                refreshGeometry: {
                    if mapState.projectGeometryMap.canRefreshSources {
                        Task { await mapState.projectGeometryMap.refresh() }
                    } else {
                        Task { await store.configureProjectGeometryMap(mapID) }
                    }
                })
        }
    }
}

/// Keeps scale and overview controls inside the map viewport while separating
/// them from the profile timeline. On narrow canvases the controls stack
/// vertically instead of covering one another.
struct ProjectMapCanvasBottomChrome: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var mapState: MapState
    @ObservedObject var linkedSession: MapLinkedFeatureSelectionSession
    let canvasSize: CGSize
    let visibleLayerCount: Int
    let vectorLayers: [MapVectorLayer]
    let mapPoints: [MapPoint]
    let scale: CGFloat
    let offset: CGSize
    let showMapOverlays: Bool
    let showScaleBar: Bool
    let overlayOpacity: Double
    var units: MapProjectionUnits? = nil
    @State private var quickEditorReferenceIdentity: String?

    private static let overviewSerializationKey = "RasMapElementsOverlay.MapOverview"
    private static let linkedFeatureSerializationKey = "RasMapElementsOverlay.LinkedFeature"
    private let linkedPanelContentSize = CGSize(width: 500, height: 76)
    private let linkedPanelMinimumSize = CGSize(width: 360, height: 58)
    private let linkedPanelMaximumSize = CGSize(width: 740, height: 136)

    private var projectSessionID: UUID { store.projectSessionID }
    private var workflowIdentity: String { store.mapWorkflowIdentity(mapState.id) }
    private var boundaryEditor: ModelEditorSession { store.primaryEditorSession(.boundaryCondition) }

    private var minimumOverviewSize: CGSize {
        CGSize(width: min(150, max(80, canvasSize.width - 24)),
               height: min(100, max(64, canvasSize.height - 64)))
    }

    private var maximumOverviewSize: CGSize {
        CGSize(width: max(minimumOverviewSize.width, min(450, canvasSize.width - 24)),
               height: max(minimumOverviewSize.height, min(350, canvasSize.height - 64)))
    }

    private var overviewSize: CGSize {
        let width = min(maximumOverviewSize.width,
            max(minimumOverviewSize.width, min(200, canvasSize.width * 0.34)))
        let height = min(maximumOverviewSize.height,
            max(minimumOverviewSize.height, min(140, max(64, width * 0.7))))
        return CGSize(width: width, height: height)
    }

    private var overviewDefaultCorner: MapOverlayCorner {
        guard showScaleBar, visibleLayerCount > 0 else { return .bottomRight }
        let scaleWidth = min(160, canvasSize.width * 0.25) + 20
        let overviewWidth = overviewSize.width + 24
        return canvasSize.width >= overviewWidth + scaleWidth + 32 ? .bottomRight : .topRight
    }

    private var overviewSerializationKey: String? {
        store.suppressesAppDataIO ? nil : Self.overviewSerializationKey
    }

    private var linkedFeatureSerializationKey: String? {
        store.suppressesAppDataIO ? nil : Self.linkedFeatureSerializationKey
    }

    private var overviewPlacement: MapOverlayPlacement {
        let fallback = MapOverlayPlacement(corner: overviewDefaultCorner, stackOrder: 0)
        guard let key = overviewSerializationKey else { return fallback }
        return MapOverlayPlacementStore.load(key) ?? fallback
    }

    private var linkedFeaturePlacement: MapOverlayPlacement {
        let fallback = MapOverlayPlacement(corner: .topRight, stackOrder: 1)
        guard let key = linkedFeatureSerializationKey else { return fallback }
        return MapOverlayPlacementStore.load(key) ?? fallback
    }

    /// The source overlay panel measures in its outer frame, including the
    /// 34-point title/drag chrome. Peer inputs use the same outer dimensions so
    /// the shared placement solver can reserve real panel footprints.
    private var overlayPeers: [MapOverlayGeometryInput] {
        guard showMapOverlays, !store.suppressesAppDataIO else { return [] }
        var peers: [MapOverlayGeometryInput] = []
        if mapState.showMinimap && visibleLayerCount > 0 {
            peers.append(MapOverlayGeometryInput(id: Self.overviewSerializationKey,
                placement: overviewPlacement,
                desiredSize: CGSize(width: overviewSize.width, height: overviewSize.height + 34),
                minimumSize: CGSize(width: minimumOverviewSize.width, height: minimumOverviewSize.height + 34),
                maximumSize: CGSize(width: maximumOverviewSize.width, height: maximumOverviewSize.height + 34),
                isResizable: true, zIndex: 10))
        }
        if linkedSession.context != nil {
            peers.append(MapOverlayGeometryInput(id: Self.linkedFeatureSerializationKey,
                placement: linkedFeaturePlacement,
                desiredSize: CGSize(width: linkedPanelContentSize.width, height: linkedPanelContentSize.height + 34),
                minimumSize: CGSize(width: linkedPanelMinimumSize.width, height: linkedPanelMinimumSize.height + 34),
                maximumSize: CGSize(width: linkedPanelMaximumSize.width, height: linkedPanelMaximumSize.height + 34),
                isResizable: true, zIndex: 20))
        }
        return peers
    }

    private var activeQuickEditorContext: MapQuickEditorPayloadContext? {
        guard let referenceIdentity = quickEditorReferenceIdentity,
              let linkedContext = linkedSession.context,
              linkedContext.referenceIdentity == referenceIdentity else { return nil }
        return MapQuickEditorPayloadContextResolver.resolve(mapState: mapState,
            editorSession: boundaryEditor, projectSessionID: projectSessionID,
            mapWorkflowIdentity: workflowIdentity, linkedContext: linkedContext)
    }

    private var openableQuickEditorContext: MapQuickEditorPayloadContext? {
        guard let linkedContext = linkedSession.context else { return nil }
        return MapQuickEditorPayloadContextResolver.resolve(mapState: mapState,
            editorSession: boundaryEditor, projectSessionID: projectSessionID,
            mapWorkflowIdentity: workflowIdentity, linkedContext: linkedContext)
    }

    private var quickEditorPresented: Binding<Bool> {
        Binding(get: { quickEditorReferenceIdentity != nil }, set: { isPresented in
            if !isPresented { quickEditorReferenceIdentity = nil }
        })
    }

    @ViewBuilder
    private var scaleBar: some View {
        if showScaleBar, visibleLayerCount > 0 {
            MapCoordinateScaleBar(extent: mapState.currentExtent, canvasWidth: canvasSize.width, units: units)
                .opacity(overlayOpacity)
        }
    }

    var body: some View {
        ZStack {
            MapLinkedFeatureSelectionObserver(mapState: mapState,
                vectorLayers: vectorLayers, projectSessionID: projectSessionID,
                mapWorkflowIdentity: workflowIdentity, editorSession: boundaryEditor,
                session: linkedSession)
                .frame(width: 0, height: 0)

            if showMapOverlays && (showScaleBar && visibleLayerCount > 0
                || mapState.showMinimap && visibleLayerCount > 0
                || linkedSession.context != nil) {
                GeometryReader { _ in
                    ZStack(alignment: .bottomLeading) {
                        scaleBar.padding(12)

                        if mapState.showMinimap && visibleLayerCount > 0 {
                            MapFloatingOverlay(title: "Map Overview", symbol: "map",
                                corner: overviewDefaultCorner, size: overviewSize,
                                minimumSize: minimumOverviewSize, maximumSize: maximumOverviewSize,
                                adaptiveDefaultCorner: overviewDefaultCorner,
                                serializationKey: overviewSerializationKey, stackOrder: 0,
                                zIndex: 10, peerGeometry: overlayPeers) { proposedSize in
                                MapMinimap(store: store, mapState: mapState, size: proposedSize)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .opacity(overlayOpacity)
                        }

                        if linkedSession.context != nil {
                            MapFloatingOverlay(title: "Linked Feature", symbol: "point.3.connected.trianglepath.dotted",
                                corner: .topRight, size: linkedPanelContentSize,
                                minimumSize: linkedPanelMinimumSize, maximumSize: linkedPanelMaximumSize,
                                serializationKey: linkedFeatureSerializationKey, stackOrder: 1,
                                zIndex: 20, peerGeometry: overlayPeers) { _ in
                                MapLinkedFeatureSelectionView(mapState: mapState,
                                    vectorLayers: vectorLayers, projectSessionID: projectSessionID,
                                    mapWorkflowIdentity: workflowIdentity, editorSession: boundaryEditor,
                                    synchronizesSession: false, session: linkedSession,
                                    onQuickEdit: openableQuickEditorContext == nil ? nil : { context in
                                        presentQuickEditor(for: context)
                                    })
                                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                                    .padding(6)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .opacity(overlayOpacity)
                        }

                        if let context = activeQuickEditorContext,
                           let referenceIdentity = quickEditorReferenceIdentity,
                           let anchor = quickEditorAnchor(for: context) {
                            MapQuickEditorPayloadOverlay(context: context,
                                isPresented: quickEditorPresented, anchor: anchor,
                                canvasSize: canvasSize,
                                onCreate: { line in
                                    createPayload(from: context, referenceIdentity: referenceIdentity,
                                                  lineID: line.id)
                                },
                                onViewPayload: { line, payloadID in
                                    viewPayload(from: context, referenceIdentity: referenceIdentity,
                                                lineID: line.id, payloadID: payloadID)
                                })
                                .zIndex(10_000)
                                .opacity(overlayOpacity)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: linkedSession.context) { _, context in
            guard let context, context.referenceIdentity == quickEditorReferenceIdentity else {
                quickEditorReferenceIdentity = nil
                return
            }
        }
        .onChange(of: projectSessionID) { _, _ in quickEditorReferenceIdentity = nil }
        .onChange(of: workflowIdentity) { _, _ in quickEditorReferenceIdentity = nil }
    }

    private func presentQuickEditor(for context: MapLinkedFeatureSelectionContext) {
        guard context.projectSessionID == projectSessionID,
              context.mapWorkflowIdentity == workflowIdentity,
              context.mapID == mapState.id,
              MapLinkedFeatureSelectionResolver.ownerIsValid(context,
                mapState: mapState, vectorLayers: vectorLayers,
                projectSessionID: projectSessionID, mapWorkflowIdentity: workflowIdentity),
              let resolved = MapQuickEditorPayloadContextResolver.resolve(mapState: mapState,
                editorSession: boundaryEditor, projectSessionID: projectSessionID,
                mapWorkflowIdentity: workflowIdentity, linkedContext: context),
              resolved.line.id == context.featureIdentity else { return }
        store.activateMap(mapState.id)
        quickEditorReferenceIdentity = context.referenceIdentity
    }

    private func callbackStillOwns(_ context: MapQuickEditorPayloadContext,
                                   referenceIdentity: String) -> Bool {
        guard let linked = linkedSession.context,
              linked.referenceIdentity == referenceIdentity,
              linked.projectSessionID == projectSessionID,
              linked.mapWorkflowIdentity == workflowIdentity,
              linked.mapID == mapState.id,
              linked.featureIdentity == context.line.id,
              MapLinkedFeatureSelectionResolver.ownerIsValid(linked,
                mapState: mapState, vectorLayers: vectorLayers,
                projectSessionID: projectSessionID, mapWorkflowIdentity: workflowIdentity),
              let current = MapQuickEditorPayloadContextResolver.resolve(mapState: mapState,
                editorSession: boundaryEditor, projectSessionID: projectSessionID,
                mapWorkflowIdentity: workflowIdentity, linkedContext: linked) else { return false }
        return current.identity == context.identity
    }

    private func createPayload(from context: MapQuickEditorPayloadContext,
                               referenceIdentity: String, lineID: String) {
        guard lineID == context.line.id,
              callbackStillOwns(context, referenceIdentity: referenceIdentity) else { return }
        context.editorSession.selectBoundaryLine(lineID)
        guard context.editorSession.selectedBoundaryLineID == lineID else { return }
        store.activateMap(mapState.id)
        store.activeTool = .newPayload
    }

    private func viewPayload(from context: MapQuickEditorPayloadContext,
                             referenceIdentity: String, lineID: String, payloadID: String) {
        guard lineID == context.line.id,
              let payload = context.line.payloads.first(where: { $0.id == payloadID && $0.isHydraulic }),
              callbackStillOwns(context, referenceIdentity: referenceIdentity) else { return }
        let boundarySourcePath = context.capture.sourcePath
        let boundaryAssets = store.assets.filter { $0.section == .boundaryConditions }
        guard let asset = boundaryAssets.first(where: {
            SourceFilePaths.canonical($0.url) == boundarySourcePath
        }) else { return }
        context.editorSession.selectBoundaryLine(lineID)
        context.editorSession.selectBoundaryPayload(payload.id, lineID: lineID)
        guard context.editorSession.selectedBoundaryLineID == lineID,
              context.editorSession.selectedBoundaryPayloadIDs[lineID] == payload.id else { return }
        store.activateMap(mapState.id)
        store.openEditor(.boundaryCondition, assetID: asset.id)
    }

    private func quickEditorAnchor(for context: MapQuickEditorPayloadContext) -> CGPoint? {
        let coordinates = context.mapLine.line.coordinates
        guard coordinates.count >= 2, coordinates.allSatisfy({ $0.x.isFinite && $0.y.isFinite }),
              canvasSize.width > 0, canvasSize.height > 0 else { return nil }
        let segments = zip(coordinates, coordinates.dropFirst()).map { first, second in
            let dx = second.x - first.x
            let dy = second.y - first.y
            return sqrt(dx * dx + dy * dy)
        }
        let totalLength = segments.reduce(0, +)
        guard totalLength.isFinite, totalLength > 0 else {
            let point = coordinates[coordinates.count / 2]
            return MapTransform(points: mapPoints, size: canvasSize, scale: scale, offset: offset)
                .screen(MapPoint(x: point.x, y: point.y))
        }
        var remaining = totalLength / 2
        var anchor = coordinates[0]
        for (index, length) in segments.enumerated() {
            guard length.isFinite, length > 0 else { continue }
            if remaining <= length {
                let ratio = remaining / length
                let start = coordinates[index]
                let end = coordinates[index + 1]
                anchor = MapPoint(x: start.x + (end.x - start.x) * ratio,
                                  y: start.y + (end.y - start.y) * ratio)
                break
            }
            remaining -= length
        }
        return MapTransform(points: mapPoints, size: canvasSize, scale: scale, offset: offset).screen(anchor)
    }
}

/// Keeps Linkage.CurrentContext and the same-source Boundary editor selection
/// current even when the user hides map chrome. The visible floating panel is
/// presentation only and shares this exact per-map session.
@MainActor
private struct MapLinkedFeatureSelectionObserver: View {
    @ObservedObject var mapState: MapState
    let vectorLayers: [MapVectorLayer]
    let projectSessionID: UUID
    let mapWorkflowIdentity: String
    let editorSession: ModelEditorSession
    @ObservedObject var session: MapLinkedFeatureSelectionSession

    private var selectedContext: MapLinkedFeatureSelectionContext? {
        MapLinkedFeatureSelectionResolver.resolve(mapState: mapState,
            vectorLayers: vectorLayers, projectSessionID: projectSessionID,
            mapWorkflowIdentity: mapWorkflowIdentity)
    }

    private var currentOwnerIsValid: Bool {
        guard let context = session.context else { return true }
        return MapLinkedFeatureSelectionResolver.ownerIsValid(context,
            mapState: mapState, vectorLayers: vectorLayers,
            projectSessionID: projectSessionID, mapWorkflowIdentity: mapWorkflowIdentity)
    }

    var body: some View {
        Color.clear
            .onAppear(perform: synchronize)
            .onChange(of: selectedContext) { _, _ in synchronize() }
            .onChange(of: currentOwnerIsValid) { _, _ in synchronize() }
            .onChange(of: session.context) { _, _ in session.propagateBoundaryContext(to: editorSession) }
            .onChange(of: projectSessionID) { _, _ in synchronize() }
            .onChange(of: mapWorkflowIdentity) { _, _ in synchronize() }
            .onChange(of: editorSession.modelAssetID) { _, _ in session.propagateBoundaryContext(to: editorSession) }
            .onChange(of: editorSession.sourceFileRevision) { _, _ in session.propagateBoundaryContext(to: editorSession) }
            .onChange(of: editorSession.loaded) { _, _ in session.propagateBoundaryContext(to: editorSession) }
    }

    private func synchronize() {
        session.reconcile(selectedContext: selectedContext) { context in
            MapLinkedFeatureSelectionResolver.ownerIsValid(context,
                mapState: mapState, vectorLayers: vectorLayers,
                projectSessionID: projectSessionID, mapWorkflowIdentity: mapWorkflowIdentity)
        }
        session.propagateBoundaryContext(to: editorSession)
    }
}
