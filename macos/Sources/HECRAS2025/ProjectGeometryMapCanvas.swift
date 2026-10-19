import RASWorkspaceCore
import SwiftUI

private struct GeometryPlotCanvasRequest {
    let captureIdentity: String
    let family: GeometryMeshPlotRendererFamily
    let session: GeometryMeshPlotSession
    let intent: GeometryMeshPlotRenderIntent
}

@MainActor
enum ProjectGeometryMapStyleResolver {
    static func plotPacket(for source: ProjectGeometryMapSourceState,
                          state: MapGeometryLayerState,
                          family: GeometryMeshPlotRendererFamily,
                          store: WorkspaceStore,
                          mapID: UUID) -> GeometryMeshPlotStylePacket? {
        let nodeType: String
        let ids: [String]
        switch family {
        case .mesh:
            nodeType = "FlowAreaLayer"
            ids = ["Mesh_Line_Symbology"]
        case .conceptualMesh:
            nodeType = "ConceptualMesh"
            ids = ["Arc_Line_Symbology", "Node_Symbology", "Deletable_Node_Symbology",
                   "Internal_Point_Symbology"]
        case .topologyTIN:
            // ViewTIN creates a transient TinRenderLayer with its real source
            // defaults; no saved map-tree symbology owner is attached to it.
            return .sourceDefaults
        }
        guard let childLocator = state.locator,
              let geometryPath = source.capture.geometryNode.nodePath else { return nil }
        let matchingOwners = store.vectorSymbologyContexts(mapID: mapID).filter { context in
            guard let owner = context.specializedNode else { return false }
            return context.mapID == mapID
                && context.projectSessionID == source.capture.projectSessionID
                && owner.geometryNodePath == geometryPath
                && owner.geometryName == source.capture.geometryName
                && SourceFilePaths.canonical(URL(fileURLWithPath: owner.geometryAssetID))
                    == source.capture.geometryCanonicalPath
                && owner.rootName == source.capture.geometryNode.rootName
                && owner.nodeType == nodeType
                && owner.nodePath == childLocator.nodePath
                && owner.nodeName == childLocator.nodeName
        }
        guard matchingOwners.count <= 1 else { return nil }

        let values: [String: VectorStyleValues]
        let scope: GeometryMeshPlotStylePacket.Scope
        let revision: String
        if let context = matchingOwners.first {
            do {
                guard let owner = try store.specializedVectorStyleSource(context),
                      Set(owner.settings.options.keys) == Set(ids) else { return nil }
                values = owner.settings.options.mapValues(\.values)
                scope = .localVis
                revision = owner.settings.revision ?? ""
            } catch {
                return nil
            }
        } else {
            // A map with no exact local owner inherits the current global
            // Geometry styles. Local styles from sibling maps are never used.
            values = Dictionary(uniqueKeysWithValues: ids.map {
                ($0, store.effectiveVectorStyle(definitionID: $0))
            })
            scope = .global
            revision = ""
        }
        guard Set(values.keys) == Set(ids) else { return nil }
        let canonicalValues = values.compactMapValues { $0.validatedForPersistence() }
        guard canonicalValues.count == ids.count else { return nil }
        return GeometryMeshPlotStylePacket(scope: scope, revision: revision,
            globalRevision: store.vectorStyleRevision, styles: canonicalValues)
    }

    static func values(for source: ProjectGeometryMapSourceState,
                       state: MapGeometryLayerState,
                       nodeType: String,
                       ids: [String],
                       store: WorkspaceStore,
                       mapID: UUID) -> [String: VectorStyleValues]? {
        guard let childLocator = state.locator,
              let geometryPath = source.capture.geometryNode.nodePath else { return nil }
        let matches = store.vectorSymbologyContexts(mapID: mapID).filter { context in
            guard let owner = context.specializedNode else { return false }
            return context.mapID == mapID
                && context.projectSessionID == source.capture.projectSessionID
                && owner.geometryNodePath == geometryPath
                && owner.geometryName == source.capture.geometryName
                && SourceFilePaths.canonical(URL(fileURLWithPath: owner.geometryAssetID))
                    == source.capture.geometryCanonicalPath
                && owner.rootName == source.capture.geometryNode.rootName
                && owner.nodeType == nodeType
                && owner.nodePath == childLocator.nodePath
                && owner.nodeName == childLocator.nodeName
        }
        // A persisted per-map child must resolve to exactly one .vis owner.
        // Never borrow a sibling or last-active-map style.
        guard matches.count == 1 else { return nil }
        do {
            guard let owner = try store.specializedVectorStyleSource(matches[0]),
                  Set(owner.settings.options.keys) == Set(ids) else { return nil }
            return owner.settings.options.compactMapValues(\.values)
        } catch {
            return nil
        }
    }

    static func hasUnavailableVisibleStyle(in session: ProjectGeometryMapSession,
                                           store: WorkspaceStore,
                                           mapID: UUID) -> Bool {
        for source in session.sources {
            guard let snapshot = source.snapshot, snapshot.geometryEffectiveVisible else { continue }
            if snapshot.topologyState.effectiveVisible && snapshot.topologyState.status.hasSourceData
                && values(for: source, state: snapshot.topologyState, nodeType: "ConceptualMesh",
                    ids: ["Arc_Line_Symbology", "Node_Symbology", "Deletable_Node_Symbology",
                          "Internal_Point_Symbology"], store: store, mapID: mapID) == nil {
                return true
            }
            if source.presentsFlowAreaData,
               values(for: source, state: snapshot.flowAreasState, nodeType: "FlowAreaLayer",
                    ids: ["Mesh_Line_Symbology"], store: store, mapID: mapID) == nil {
                return true
            }
            if snapshot.culvertsState.effectiveVisible && snapshot.culvertsState.status.hasSourceData
                && values(for: source, state: snapshot.culvertsState, nodeType: "CulvertBarrelLayer",
                    ids: ["Culvert_Barrel_Symbology", "Culvert_Barrel_Vertex_Symbology"],
                    store: store, mapID: mapID) == nil {
                return true
            }
        }
        return false
    }
}

/// Source-backed Geometry children rendered in Project Map's shared world
/// transform. This canvas has no independent camera and never reads an editor
/// preview or an unrelated map's specialized style owner.
struct ProjectGeometryMapCanvas: View {
    @ObservedObject private var renderScaling = WorkspaceRenderScaling.shared
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var mapState: MapState
    @ObservedObject var session: ProjectGeometryMapSession
    let mapID: UUID
    let scale: CGFloat
    let offset: CGSize
    var isInteractive = true

    private enum ChildLayerKind {
        case topology
        case flowAreas
        case culverts

        func locator(in snapshot: MapGeometrySnapshot) -> CatalogTreeNodeLocator? {
            switch self {
            case .topology: snapshot.topologyState.locator
            case .flowAreas: snapshot.flowAreasState.locator
            case .culverts: snapshot.culvertsState.locator
            }
        }
    }

    private struct CulvertMapPresentation {
        let features: [GeometryCulvertFeatureRow]
        let identity: String
        let draftExtent: GeometryTopologyExtent?
        /// Selection belongs either to the saved feature set or to the active
        /// parent draft. Keeping that scope in the selection ID prevents a
        /// stale saved/result selection from highlighting an editor draft.
        let selectionOwner: String
    }

    /// Resolve only the exact parent Geometry row. Captures and page state
    /// remain in source order; the lookup controls canvas paint order only.
    private var sourcesInPaintOrder: [ProjectGeometryMapSourceState] {
        let exactRows = MapRenderComposition.orderedRecords(mapState.sourceMapRenderRows)
            .filter { $0.locator.nodeType == "Geometry" }
        let ranks = Dictionary(exactRows.enumerated().map { ($0.element.locator, $0.offset) },
                              uniquingKeysWith: { first, _ in first })
        return session.sources.enumerated().sorted { lhs, rhs in
            let leftRank = ranks[lhs.element.capture.geometryNode]
            let rightRank = ranks[rhs.element.capture.geometryNode]
            switch (leftRank, rightRank) {
            case let (left?, right?): return left < right
            case (.some, .none): return true
            case (.none, .some): return false
            default: return lhs.offset > rhs.offset
            }
        }.map(\.element)
    }

    private var flowAreaGenerationPresentationUpdateIdentity: String {
        session.sources.map { source in
            let mesh = store.geometryMeshSession(assetID: source.capture.geometryCanonicalPath,
                projectSessionID: source.capture.projectSessionID)
            let terminalGeneration = mesh?.meshGenerationTerminalIdentity ?? "none"
            return source.id + "=" + (flowAreaGenerationPresentation(for: source)?.identity ?? "source")
                + "|terminal:" + terminalGeneration
                + "|owner-loading:" + String(mesh?.isLoading == true && mesh?.parentSaveInProgress != true)
        }.joined(separator: "\n")
    }

    private var savedMeshMapRefreshIdentity: String? {
        let staleSources = session.sources.compactMap { source -> String? in
            guard let snapshot = source.snapshot,
                  let mesh = store.geometryMeshSession(assetID: source.capture.geometryCanonicalPath,
                      projectSessionID: source.capture.projectSessionID),
                  let currentRevision = mesh.geometryMapOverlaySourceRevision(for: source.capture.geometryCanonicalPath),
                  currentRevision != snapshot.geometryRevision,
                  mesh.meshGenerationResultIdentity != nil,
                  !mesh.isGeneratingMesh, !mesh.isLoading, !mesh.isDirty else { return nil }
            return source.id + "|" + snapshot.geometryRevision + "|" + currentRevision
        }.sorted()
        return staleSources.isEmpty ? nil : staleSources.joined(separator: "\n")
    }

    private func culvertMapLayerIsVisible(for source: ProjectGeometryMapSourceState) -> Bool {
        guard let snapshot = source.snapshot else { return false }
        return snapshot.geometryEffectiveVisible
            && snapshot.culvertsState.effectiveVisible
            && snapshot.culvertsState.status.hasSourceData
    }

    private func culvertMapModel(for source: ProjectGeometryMapSourceState) -> GeometryCulvertModelRequest? {
        guard source.capture.resultOwner == nil else { return nil }
        return GeometryCulvertModelRequest(assetPath: source.capture.geometryCanonicalPath,
            kind: "Geometry", projectPath: source.capture.map.projectPath,
            projectXml: source.capture.map.projectXml,
            coreLayerContext: source.capture.map.coreLayerContext)
    }

    /// Owner and child readiness form the retry key for the map's one-shot
    /// child preparation. Body evaluation itself remains free of I/O.
    private var culvertMapPreparationIdentity: String {
        session.sources.compactMap { source -> String? in
            guard culvertMapLayerIsVisible(for: source),
                  let model = culvertMapModel(for: source),
                  let revision = source.geometryRevision else { return nil }
            return store.geometryCulvertMapHoverPreparationIdentity(
                assetID: source.capture.geometryCanonicalPath,
                projectSessionID: source.capture.projectSessionID,
                expectedRevision: revision, model: model)
        }.joined(separator: "\n")
    }

    private var culvertDraftPresentationUpdateIdentity: String {
        session.sources.map { source in
            source.capture.identity + "=" + (culvertMapPresentation(for: source).flatMap {
                $0.selectionOwner == "parent-draft" ? $0.identity : nil
            } ?? "no-parent-draft")
        }.joined(separator: "\n")
    }

    private func culvertDraftExtent(_ features: [GeometryCulvertFeatureRow]) -> GeometryTopologyExtent? {
        let points = features.flatMap(\.polyline).filter { $0.x.isFinite && $0.y.isFinite }
        guard let minX = points.map(\.x).min(), let minY = points.map(\.y).min(),
              let maxX = points.map(\.x).max(), let maxY = points.map(\.y).max() else { return nil }
        return GeometryTopologyExtent(minX: minX, minY: minY, maxX: maxX, maxY: maxY)
    }

    private func installCulvertDraftPresentations() {
        for source in session.sources {
            let draft = culvertMapPresentation(for: source).flatMap { presentation -> ProjectGeometryMapCulvertDraftPresentation? in
                guard presentation.selectionOwner == "parent-draft",
                      let sourceRevision = source.geometryRevision else { return nil }
                return ProjectGeometryMapCulvertDraftPresentation(
                    identity: presentation.identity, captureIdentity: source.capture.identity,
                    projectSessionID: source.capture.projectSessionID, mapID: source.capture.mapID,
                    mapWorkflowIdentity: source.capture.mapWorkflowIdentity,
                    geometryCanonicalPath: source.capture.geometryCanonicalPath,
                    geometryRevision: sourceRevision, extent: presentation.draftExtent,
                    featureCount: presentation.features.count)
            }
            session.setCulvertDraftPresentation(draft, captureIdentity: source.capture.identity)
        }
    }

    private func prepareVisibleCulvertMaps() async {
        for source in session.sources {
            guard !Task.isCancelled, culvertMapLayerIsVisible(for: source),
                  let model = culvertMapModel(for: source),
                  let revision = source.geometryRevision else { continue }
            _ = await store.prepareGeometryCulvertMapHoverSnapshot(
                assetID: source.capture.geometryCanonicalPath,
                projectSessionID: source.capture.projectSessionID,
                expectedRevision: revision, model: model)
        }
    }

    private func flowAreaGenerationPresentation(for source: ProjectGeometryMapSourceState)
        -> ProjectGeometryMapFlowAreaGenerationPresentation? {
        guard let snapshot = source.snapshot,
              let mesh = store.geometryMeshSession(assetID: source.capture.geometryCanonicalPath,
                  projectSessionID: source.capture.projectSessionID),
              let currentRevision = mesh.geometryMapOverlaySourceRevision(for: source.capture.geometryCanonicalPath) else {
            return nil
        }

        let captureID = source.capture.identity
        if mesh.isGeneratingMesh,
           mesh.meshGenerationSourceRevision == snapshot.geometryRevision,
           currentRevision == snapshot.geometryRevision,
           let operationID = mesh.meshGenerationOperationID {
            return ProjectGeometryMapFlowAreaGenerationPresentation(
                identity: captureID + "|generating|" + operationID.uuidString + "|" + snapshot.geometryRevision,
                phase: .generating, map: nil)
        }
        if currentRevision != snapshot.geometryRevision,
           mesh.meshGenerationResultIdentity != nil {
            let operation = mesh.meshGenerationOperationID?.uuidString
                ?? mesh.meshGenerationResultIdentity ?? "generation"
            return ProjectGeometryMapFlowAreaGenerationPresentation(
                identity: captureID + "|awaiting|" + operation + "|"
                    + snapshot.geometryRevision + "|" + currentRevision,
                phase: .awaitingSavedSource, map: nil)
        }
        guard currentRevision == snapshot.geometryRevision,
              let resultIdentity = mesh.meshGenerationResultIdentity,
              let meshSnapshot = mesh.snapshot,
              meshSnapshot.generationReport?.meshWasReplaced == true,
              meshSnapshot.isDirty else { return nil }
        let extentIdentity = meshSnapshot.map?.extent.map { extent in
            [extent.minX, extent.minY, extent.maxX, extent.maxY]
                .map { String($0.bitPattern, radix: 16) }.joined(separator: ":")
        } ?? "missing"
        let rowIdentity = meshSnapshot.flowAreas.map {
            $0.id + ":" + $0.name + ":" + String($0.cellCount)
        }.joined(separator: "|")
        let mapIdentity = meshSnapshot.map.map {
            "\($0.totalCellCount):\($0.renderedCellCount):\($0.omittedCellCount):\($0.invalidCandidateCount)"
        } ?? "missing"
        return ProjectGeometryMapFlowAreaGenerationPresentation(
            identity: captureID + "|draft|" + resultIdentity + "|" + currentRevision
                + "|" + meshSnapshot.draftState
                + "|" + rowIdentity + "|" + extentIdentity + "|" + mapIdentity,
            phase: .childDraft, map: meshSnapshot.map)
    }

    /// Uses the one exact Geometry editor's dirty culvert child for every map
    /// interaction. An ambiguous or not-yet-ready editor hides this layer
    /// rather than quietly painting saved geometry under a draft owner. Result
    /// maps always retain their embedded, saved geometry.
    private func culvertMapPresentation(for source: ProjectGeometryMapSourceState)
        -> CulvertMapPresentation? {
        guard culvertMapLayerIsVisible(for: source) else { return nil }
        if source.capture.resultOwner != nil {
            return CulvertMapPresentation(features: source.culvertFeatures,
                identity: source.capture.identity + "|saved|result",
                draftExtent: nil, selectionOwner: "saved")
        }

        let assetID = source.capture.geometryCanonicalPath
        let editorCount = store.geometryMeshEditorCount(for: assetID)
        guard editorCount <= 1 else { return nil }
        guard editorCount == 1 else {
            return CulvertMapPresentation(features: source.culvertFeatures,
                identity: source.capture.identity + "|saved|source",
                draftExtent: nil, selectionOwner: "saved")
        }
        guard let revision = source.geometryRevision else { return nil }
        guard let model = culvertMapModel(for: source) else { return nil }
        guard let snapshot = store.geometryCulvertMapHoverSnapshot(
            assetID: assetID, projectSessionID: source.capture.projectSessionID,
            expectedRevision: revision, model: model) else { return nil }
        guard snapshot.isDirty else {
            return CulvertMapPresentation(features: source.culvertFeatures,
                identity: source.capture.identity + "|saved|clean-child|" + snapshot.revision,
                draftExtent: nil, selectionOwner: "saved")
        }
        let draftFeatures = snapshot.barrels.rows
        let draftExtent = culvertDraftExtent(draftFeatures)
        let ownerIdentity = store.geometryCulvertMapHoverPreparationIdentity(
            assetID: assetID, projectSessionID: source.capture.projectSessionID,
            expectedRevision: revision, model: model)
        let extentIdentity = draftExtent.map { extent in
            [extent.minX, extent.minY, extent.maxX, extent.maxY]
                .map { String($0.bitPattern, radix: 16) }.joined(separator: ":")
        } ?? "empty"
        return CulvertMapPresentation(
            features: draftFeatures,
            identity: source.capture.identity + "|parent-draft|" + ownerIdentity
                + "|" + snapshot.draftState + "|count:" + String(draftFeatures.count)
                + "|" + extentIdentity,
            draftExtent: draftExtent, selectionOwner: "parent-draft")
    }

    private func installFlowAreaGenerationPresentations() {
        for source in session.sources {
            session.setFlowAreaGenerationPresentation(flowAreaGenerationPresentation(for: source),
                captureIdentity: source.capture.identity)
            let mesh = store.geometryMeshSession(assetID: source.capture.geometryCanonicalPath,
                projectSessionID: source.capture.projectSessionID)
            let flowAreaLocator = flowAreaVisibilityLocator(for: source)
            if let mesh, mesh.isLoading, !mesh.parentSaveInProgress,
               let terminalIdentity = mesh.meshGenerationTerminalIdentity,
               let flowAreaLocator {
                _ = session.suppressFlowAreaGenerationVisibilityOverride(locator: flowAreaLocator,
                    captureIdentity: source.capture.identity,
                    generationResultIdentity: terminalIdentity)
                session.clearFlowAreaGenerationVisibilityOverride(captureIdentity: source.capture.identity)
            }
            guard let mesh,
                  mesh.geometryMapOverlaySourceRevision(for: source.capture.geometryCanonicalPath) != nil,
                  let terminalIdentity = mesh.meshGenerationTerminalIdentity else {
                session.clearFlowAreaGenerationVisibilityState(capture: source.capture)
                continue
            }
            guard let flowAreaLocator else { continue }
            if session.isFlowAreaGenerationVisibilitySuppressed(locator: flowAreaLocator,
                captureIdentity: source.capture.identity,
                generationResultIdentity: terminalIdentity) {
                session.clearFlowAreaGenerationVisibilityOverride(captureIdentity: source.capture.identity)
            } else {
                session.setFlowAreaGenerationVisibilityOverride(flowAreaLocator,
                    captureIdentity: source.capture.identity)
            }
        }
    }

    private func flowAreaVisibilityLocator(for source: ProjectGeometryMapSourceState)
        -> CatalogTreeNodeLocator? {
        let matches = mapState.sourceMapLayerRows.compactMap { row -> CatalogTreeNodeLocator? in
            guard row.node.sourceClass == "FlowAreaLayerVisualContext",
                  let locator = row.node.sourceLocator,
                  locator.nodeType == "FlowAreaLayer",
                  locator.rootName == source.capture.geometryNode.rootName,
                  let parentPath = locator.parentGeometryAssetID,
                  SourceFilePaths.canonical(URL(fileURLWithPath: parentPath))
                    == source.capture.geometryCanonicalPath,
                  locator.parentGeometryNodePath == source.capture.geometryNode.nodePath,
                  locator.parentGeometryNodeName == source.capture.geometryNode.nodeName,
                  locator.parentPlanAssetID == source.capture.geometryNode.parentPlanAssetID,
                  locator.parentPlanNodePath == source.capture.geometryNode.parentPlanNodePath,
                  locator.parentPlanNodeName == source.capture.geometryNode.parentPlanNodeName,
                  locator.parentResultNodeType == source.capture.geometryNode.parentResultNodeType,
                  locator.parentResultAssetID.map({
                      SourceFilePaths.canonical(URL(fileURLWithPath: $0))
                  }) == source.capture.geometryNode.parentResultAssetID.map({
                      SourceFilePaths.canonical(URL(fileURLWithPath: $0))
                  }),
                  locator.parentResultNodePath == source.capture.geometryNode.parentResultNodePath,
                  locator.parentResultNodeName == source.capture.geometryNode.parentResultNodeName,
                  locator.parentResultRevision == source.capture.geometryNode.parentResultRevision else {
                return nil
            }
            return locator
        }
        return matches.count == 1 ? matches.first : nil
    }

    private func geometryPlotRequests(transform: MapTransform,
                                      size: CGSize,
                                      renderScale: Double) -> [GeometryPlotCanvasRequest] {
        // The 180x120 minimap uses the same source owner but a different
        // camera. Keep source rendering on the primary canvas so two views do
        // not race the map-scoped renderer session for different viewports.
        guard size.width.isFinite, size.height.isFinite, size.width >= 320, size.height >= 240,
              transform.factor.isFinite, transform.factor > 0 else { return [] }
        let geometryRows = MapRenderComposition.orderedRecords(mapState.sourceMapRenderRows)
            .filter { $0.mapID == mapID && $0.payloadKind == "Geometry" && $0.isActiveAndVisible }
        let visibleGeometryOwners = Set(geometryRows.map(\.locator))
        let upperLeft = transform.world(.zero)
        let lowerRight = transform.world(CGPoint(x: size.width, y: size.height))
        let viewport = GeometryMeshPlotViewport(minX: min(upperLeft.x, lowerRight.x),
            minY: min(upperLeft.y, lowerRight.y), maxX: max(upperLeft.x, lowerRight.x),
            maxY: max(upperLeft.y, lowerRight.y))
        guard viewport.isFiniteAndOrdered else { return [] }

        let width = Double(size.width)
        let height = Double(size.height)
        let requestedScale = renderScale.isFinite && renderScale > 0 ? min(renderScale, 4) : 1
        let maxDimensionScale = min(4096 / width, 4096 / height)
        let maxPixelScale = sqrt(2_097_152 / (width * height))
        let pixelScale = min(requestedScale, maxDimensionScale, maxPixelScale)
        let pixelWidth = max(1, Int((width * pixelScale).rounded(.down)))
        let pixelHeight = max(1, Int((height * pixelScale).rounded(.down)))
        guard pixelWidth <= 4096, pixelHeight <= 4096,
              pixelWidth * pixelHeight <= 2_097_152 else { return [] }
        // Integer raster dimensions can differ slightly by axis after
        // flooring. The lower actual pixels-per-point ratio keeps source
        // pens/markers from looking thicker on either axis after resampling.
        let pixelSamplingScale = min(Double(pixelWidth) / width, Double(pixelHeight) / height)
        guard pixelSamplingScale.isFinite, pixelSamplingScale > 0,
              renderScale * pixelSamplingScale <= 64 else { return [] }

        return sourcesInPaintOrder.compactMap { source in
            guard let snapshot = source.snapshot, snapshot.geometryEffectiveVisible,
                  visibleGeometryOwners.contains(source.capture.geometryNode) else { return nil }
            let familySession = session.geometryPlotSession(for: source.capture.identity)
            let family = familySession.rendererFamily
            let layerIsVisible: Bool
            switch family {
            case .mesh:
                layerIsVisible = source.presentsFlowAreaData
            case .conceptualMesh:
                layerIsVisible = snapshot.topologyState.effectiveVisible
                    && snapshot.topologyState.status.hasSourceData
            case .topologyTIN:
                layerIsVisible = snapshot.topologyState.effectiveVisible
                    && snapshot.topologyState.status.hasSourceData
            }
            let styleState: MapGeometryLayerState
            switch family {
            case .mesh: styleState = snapshot.flowAreasState
            case .conceptualMesh, .topologyTIN: styleState = snapshot.topologyState
            }
            guard layerIsVisible,
                  let stylePacket = ProjectGeometryMapStyleResolver.plotPacket(for: source,
                    state: styleState, family: family, store: store, mapID: mapID),
                  let intent = familySession.renderIntent(source: source, mapState: mapState,
                      store: store, viewport: viewport, pixelWidth: pixelWidth,
                      pixelHeight: pixelHeight, renderScale: renderScale,
                      pixelSamplingScale: pixelSamplingScale,
                      stylePacket: stylePacket) else { return nil }
            return GeometryPlotCanvasRequest(captureIdentity: source.capture.identity,
                family: family, session: familySession, intent: intent)
        }
    }

    private func plotRequestIdentity(_ requests: [GeometryPlotCanvasRequest]) -> String {
        requests.map { $0.captureIdentity + "|" + $0.intent.identity }
            .joined(separator: "\n")
    }

    private func drawSourcePlot(_ output: GeometryMeshPlotRenderedOutput,
                                in context: inout GraphicsContext,
                                transform: MapTransform,
                                renderScale: Double) {
        let response = output.response
        let topLeft = transform.screen(MapPoint(x: response.rasterExtent.minX,
            y: response.rasterExtent.maxY))
        let bottomRight = transform.screen(MapPoint(x: response.rasterExtent.maxX,
            y: response.rasterExtent.minY))
        var plotContext = context
        plotContext.clip(to: Path(CGRect(origin: .zero, size: transform.size)))
        plotContext.draw(Image(decorative: output.image, scale: 1), in: CGRect(
            x: topLeft.x, y: topLeft.y,
            width: bottomRight.x - topLeft.x, height: bottomRight.y - topLeft.y))
        for label in response.labels {
            let location = transform.screen(MapPoint(x: label.point.x, y: label.point.y))
            guard location.x.isFinite, location.y.isFinite,
                  location.x >= 0, location.y >= 0,
                  location.x <= transform.size.width, location.y <= transform.size.height else { continue }
            let text = Text(label.text)
                .font(.system(size: max(8, 10 * renderScale)))
                .foregroundColor(.primary)
            context.draw(text, at: location, anchor: .center)
        }
    }

    var body: some View {
        GeometryReader { proxy in
            let renderScale = renderScaling.factor
            let points = mapState.transformPoints(vectors: store.mapLayers, rasters: store.rasterLayers)
            let transform = MapTransform(points: points, size: proxy.size, scale: scale, offset: offset)
            let plotRenderingEnabled = proxy.size.width >= 320 && proxy.size.height >= 240
            let plotRequests = geometryPlotRequests(transform: transform, size: proxy.size,
                renderScale: renderScale)
            let activePlotCaptures = Set(plotRequests.map(\.captureIdentity))
            let plotIdentity = plotRequestIdentity(plotRequests)
            ZStack {
                Canvas { context, _ in
                    // Source tree capture order is preorder. RasMap reverses
                    // enabled rows before drawing, so the same exact captures
                    // paint bottom-to-top in reverse order here.
                    for source in sourcesInPaintOrder {
                        let plotRequest = plotRequests.first(where: {
                            $0.captureIdentity == source.capture.identity
                        })
                        let acceptedOutput = plotRequest.flatMap { request in
                            request.session.output(for: request.family,
                                matching: request.intent.identity)
                        }
                        let suppressBaseFamily = GeometryMeshPlotFramePolicy.familyToSuppressBaseLayer(
                            output: acceptedOutput,
                            requestedIdentity: plotRequest?.intent.identity,
                            requestedFamily: plotRequest?.family)
                        draw(source, in: &context, transform: transform, renderScale: renderScale,
                             sourceRendererFamily: suppressBaseFamily)
                        if let acceptedOutput {
                            drawSourcePlot(acceptedOutput, in: &context, transform: transform,
                                          renderScale: renderScale)
                        }
                    }
                    // Selection is a single active feature and remains above
                    // all source-painted children, as in the source map.
                    for source in sourcesInPaintOrder.reversed() {
                        drawSelection(for: source, selection: session.selection,
                                      in: &context, transform: transform, renderScale: renderScale)
                    }
                }
            }
            .contentShape(Rectangle())
            .simultaneousGesture(SpatialTapGesture().onEnded { value in
                guard isInteractive else { return }
                session.select(hitTest(at: value.location, transform: transform))
            })
            .allowsHitTesting(isInteractive)
            .accessibilityHidden(!isInteractive)
            .task(id: flowAreaGenerationPresentationUpdateIdentity) {
                installFlowAreaGenerationPresentations()
            }
            .task(id: culvertMapPreparationIdentity) {
                await prepareVisibleCulvertMaps()
            }
            .task(id: culvertDraftPresentationUpdateIdentity) {
                installCulvertDraftPresentations()
            }
            .task(id: savedMeshMapRefreshIdentity) {
                guard savedMeshMapRefreshIdentity != nil, session.canRefreshSources else { return }
                await session.refresh()
            }
            .task(id: plotIdentity) {
                guard plotRenderingEnabled else { return }
                for request in plotRequests {
                    guard !Task.isCancelled else { return }
                    request.session.requestRender(request.intent)
                }
                for source in sourcesInPaintOrder where !activePlotCaptures.contains(source.capture.identity) {
                    session.geometryPlotSession(for: source.capture.identity).requestRender(nil)
                }
            }
        }
    }

    /// The owning map surface routes selection once, in source paint order,
    /// then asks this renderer to retain its domain-specific nearest-feature
    /// hit test for topology, FlowArea cells, and culvert barrels.
    @discardableResult
    func selectFeature(at location: CGPoint, transform: MapTransform) -> Bool {
        guard let feature = hitTest(at: location, transform: transform) else { return false }
        session.select(feature)
        return true
    }

    private func draw(_ source: ProjectGeometryMapSourceState,
                      in context: inout GraphicsContext,
                      transform: MapTransform,
                      renderScale: Double,
                      sourceRendererFamily: GeometryMeshPlotRendererFamily?) {
        guard let snapshot = source.snapshot, snapshot.geometryEffectiveVisible else { return }
        for layer in childLayers(in: snapshot, topmostFirst: false) {
            switch layer {
            case .topology:
                // The actual ConceptualMesh source renderer owns this child
                // layer's arcs and vertices; avoid painting the sampled DTO
                // a second time beneath its RGBA output.
                guard sourceRendererFamily != .conceptualMesh,
                      sourceRendererFamily != .topologyTIN else { continue }
                guard snapshot.topologyState.effectiveVisible,
                      snapshot.topologyState.status.hasSourceData,
                      let styles = resolvedStyles(for: source, state: snapshot.topologyState,
                          nodeType: "ConceptualMesh",
                          ids: ["Arc_Line_Symbology", "Node_Symbology",
                                "Deletable_Node_Symbology", "Internal_Point_Symbology"]) else { continue }
                drawTopology(source.topologyFeatures, styles: styles,
                             context: &context, transform: transform, renderScale: renderScale)
            case .flowAreas:
                // MeshRenderLayer is the source owner for these faces and
                // edges. Its pixels replace the lightweight map DTO drawing.
                guard sourceRendererFamily != .mesh else { continue }
                guard source.presentsFlowAreaData,
                      let styles = resolvedStyles(for: source, state: snapshot.flowAreasState,
                          nodeType: "FlowAreaLayer", ids: ["Mesh_Line_Symbology"]) else { continue }
                drawFlowAreas(source.presentedFlowAreaCells, style: styles["Mesh_Line_Symbology"] ?? .init(),
                              context: &context, transform: transform, renderScale: renderScale)
            case .culverts:
                guard snapshot.culvertsState.effectiveVisible,
                      snapshot.culvertsState.status.hasSourceData,
                      let styles = resolvedStyles(for: source, state: snapshot.culvertsState,
                          nodeType: "CulvertBarrelLayer",
                          ids: ["Culvert_Barrel_Symbology", "Culvert_Barrel_Vertex_Symbology"]),
                      let presentation = culvertMapPresentation(for: source) else { continue }
                drawCulverts(presentation.features,
                    lineStyle: styles["Culvert_Barrel_Symbology"] ?? .init(),
                    vertexStyle: styles["Culvert_Barrel_Vertex_Symbology"] ?? .init(),
                    context: &context, transform: transform, renderScale: renderScale)
            }
        }
    }

    /// Child source rows retain their tree path. Match the retained reverse
    /// tree paint order without changing page/capture order.
    private func childLayers(in snapshot: MapGeometrySnapshot,
                             topmostFirst: Bool) -> [ChildLayerKind] {
        let kinds: [ChildLayerKind] = [.topology, .flowAreas, .culverts]
        return kinds.enumerated().sorted { lhs, rhs in
            guard let leftPath = lhs.element.locator(in: snapshot)?.nodePath,
                  let rightPath = rhs.element.locator(in: snapshot)?.nodePath,
                  leftPath != rightPath else { return lhs.offset < rhs.offset }
            return topmostFirst
                ? leftPath.lexicographicallyPrecedes(rightPath)
                : rightPath.lexicographicallyPrecedes(leftPath)
        }.map(\.element)
    }

    private func drawSelection(for source: ProjectGeometryMapSourceState,
                               selection: ProjectGeometryMapSelection?,
                               in context: inout GraphicsContext,
                               transform: MapTransform,
                               renderScale: Double) {
        guard let snapshot = source.snapshot, snapshot.geometryEffectiveVisible,
              let selection else { return }
        for feature in source.topologyFeatures
        where selection.id == topologySelectionID(source: source, feature: feature) {
            for coordinates in feature.paths {
                if feature.geometryType == "point" {
                    guard let point = coordinates.first else { continue }
                    let center = transform.screen(MapPoint(x: point.x, y: point.y))
                    let diameter = WorkspaceRenderScaling.metric(14, factor: renderScale)
                    let marker = Path(ellipseIn: CGRect(x: center.x - diameter / 2, y: center.y - diameter / 2,
                                                        width: diameter, height: diameter))
                    context.fill(marker, with: .color(.accentColor))
                } else {
                    let path = linePath(coordinates, transform: transform)
                    context.stroke(path, with: .color(.accentColor),
                                   lineWidth: WorkspaceRenderScaling.metric(4, factor: renderScale))
                }
            }
        }
        for cell in source.presentedFlowAreaCells where selection.id == cellSelectionID(source: source, cell: cell) {
            let path = polygonPath(cell.coordinates, transform: transform)
            context.fill(path, with: .color(.accentColor.opacity(0.24)))
            context.stroke(path, with: .color(.accentColor),
                           lineWidth: WorkspaceRenderScaling.metric(3, factor: renderScale))
        }
        guard let presentation = culvertMapPresentation(for: source) else { return }
        for feature in presentation.features
        where selection.id == Self.culvertSelectionID(source: source,
            owner: presentation.selectionOwner, feature: feature) {
            let path = linePath(feature.polyline, transform: transform)
            context.stroke(path, with: .color(.accentColor),
                           style: StrokeStyle(lineWidth: WorkspaceRenderScaling.metric(4, factor: renderScale),
                                              lineCap: .round, lineJoin: .round))
        }
    }

    private func hitTest(at location: CGPoint, transform: MapTransform) -> ProjectGeometryMapSelection? {
        var nearest: (selection: ProjectGeometryMapSelection, distance: CGFloat)?
        let hitTolerance = max(WorkspaceRenderScaling.metric(10, factor: renderScaling.factor), 10)
        let worldPoint = transform.world(location)
        for source in sourcesInPaintOrder.reversed() {
            guard let snapshot = source.snapshot, snapshot.geometryEffectiveVisible else { continue }
            for layer in childLayers(in: snapshot, topmostFirst: true) {
                switch layer {
                case .topology:
                    guard snapshot.topologyState.effectiveVisible && snapshot.topologyState.status.hasSourceData else { continue }
                for feature in source.topologyFeatures {
                    let distance: CGFloat
                    if feature.geometryType == "point" {
                        distance = feature.paths.flatMap { $0 }.map { coordinate in
                            screenDistance(location, transform.screen(MapPoint(x: coordinate.x, y: coordinate.y)))
                        }.min() ?? .infinity
                    } else if feature.geometryType == "polygon" {
                        let contains = contains(worldPoint, rings: feature.paths)
                        distance = contains ? 0 : feature.paths.map {
                            polylineDistance(location, points: $0, close: true, transform: transform)
                        }.min() ?? .infinity
                    } else {
                        distance = feature.paths.map {
                            polylineDistance(location, points: $0, close: false, transform: transform)
                        }.min() ?? .infinity
                    }
                    let label = feature.selectionIDs.first
                        ?? feature.fid.map { String($0) }
                        ?? feature.id
                    consider(ProjectGeometryMapSelection(
                        id: Self.topologySelectionID(source: source, feature: feature),
                        geometryName: source.capture.geometryName, layerTitle: "Topology",
                        featureLabel: label), distance: distance, tolerance: hitTolerance, nearest: &nearest)
                }
                case .flowAreas:
                    guard source.presentsFlowAreaData else { continue }
                for cell in source.presentedFlowAreaCells {
                    let inside = contains(worldPoint, rings: [cell.coordinates])
                    let distance = inside ? 0 : polylineDistance(location, points: cell.coordinates,
                                                                 close: true, transform: transform)
                    let label = "\(cell.flowAreaName) / \(cell.cellIndex)"
                    consider(ProjectGeometryMapSelection(
                        id: Self.cellSelectionID(source: source, cell: cell),
                        geometryName: source.capture.geometryName, layerTitle: "Flow Areas",
                        featureLabel: label), distance: distance, tolerance: hitTolerance, nearest: &nearest)
                }
                case .culverts:
                    guard snapshot.culvertsState.effectiveVisible && snapshot.culvertsState.status.hasSourceData else { continue }
                guard let presentation = culvertMapPresentation(for: source) else { continue }
                for feature in presentation.features {
                    let points = feature.polyline.map { GeometryTopologyCoordinate(x: $0.x, y: $0.y) }
                    let distance = polylineDistance(location, points: points, close: false, transform: transform)
                    let label = feature.values["Name"] ?? String(feature.fid)
                    consider(ProjectGeometryMapSelection(
                        id: Self.culvertSelectionID(source: source,
                            owner: presentation.selectionOwner, feature: feature),
                        geometryName: source.capture.geometryName, layerTitle: "Culverts",
                        featureLabel: label), distance: distance, tolerance: hitTolerance, nearest: &nearest)
                }
                }
            }
        }
        guard let nearest, nearest.distance <= hitTolerance else { return nil }
        return nearest.selection
    }

    private func consider(_ selection: ProjectGeometryMapSelection, distance: CGFloat,
                          tolerance: CGFloat,
                          nearest: inout (selection: ProjectGeometryMapSelection, distance: CGFloat)?) {
        guard distance.isFinite, distance <= tolerance else { return }
        if let nearest, distance >= nearest.distance { return }
        nearest = (selection, distance)
    }

    private func polylineDistance(_ location: CGPoint, points: [GeometryTopologyCoordinate],
                                  close: Bool, transform: MapTransform) -> CGFloat {
        let screen = points.map { transform.screen(MapPoint(x: $0.x, y: $0.y)) }
        guard screen.count >= 2 else { return screen.first.map { screenDistance(location, $0) } ?? .infinity }
        var distance = zip(screen, screen.dropFirst()).map { segmentDistance(location, $0.0, $0.1) }.min() ?? .infinity
        if close, let first = screen.first, let last = screen.last, first != last {
            distance = min(distance, segmentDistance(location, last, first))
        }
        return distance
    }

    private func segmentDistance(_ point: CGPoint, _ first: CGPoint, _ second: CGPoint) -> CGFloat {
        let dx = second.x - first.x
        let dy = second.y - first.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return screenDistance(point, first) }
        let fraction = min(max(((point.x - first.x) * dx + (point.y - first.y) * dy) / lengthSquared, 0), 1)
        return screenDistance(point, CGPoint(x: first.x + fraction * dx, y: first.y + fraction * dy))
    }

    private func screenDistance(_ first: CGPoint, _ second: CGPoint) -> CGFloat {
        hypot(first.x - second.x, first.y - second.y)
    }

    private func contains(_ point: MapPoint, rings: [[GeometryTopologyCoordinate]]) -> Bool {
        var inside = false
        for ring in rings where ring.count >= 3 {
            var previous = ring[ring.count - 1]
            for current in ring {
                let crosses = (current.y > point.y) != (previous.y > point.y)
                    && point.x < (previous.x - current.x) * (point.y - current.y)
                        / (previous.y - current.y) + current.x
                if crosses { inside.toggle() }
                previous = current
            }
        }
        return inside
    }

    private static func topologySelectionID(source: ProjectGeometryMapSourceState,
                                            feature: GeometryTopologyMapFeature) -> String {
        source.capture.identity + "|topology|" + feature.id
    }

    private static func cellSelectionID(source: ProjectGeometryMapSourceState,
                                        cell: GeometryMeshMapCell) -> String {
        source.capture.identity + "|flow-area|" + cell.id
    }

    private static func culvertSelectionID(source: ProjectGeometryMapSourceState,
                                           owner: String,
                                           feature: GeometryCulvertFeatureRow) -> String {
        source.capture.identity + "|culvert|" + owner + "|" + feature.id
    }

    private func topologySelectionID(source: ProjectGeometryMapSourceState,
                                     feature: GeometryTopologyMapFeature) -> String {
        Self.topologySelectionID(source: source, feature: feature)
    }

    private func cellSelectionID(source: ProjectGeometryMapSourceState,
                                 cell: GeometryMeshMapCell) -> String {
        Self.cellSelectionID(source: source, cell: cell)
    }

    private func resolvedStyles(for source: ProjectGeometryMapSourceState,
                                state: MapGeometryLayerState,
                                nodeType: String,
                                ids: [String]) -> [String: VectorStyleValues]? {
        ProjectGeometryMapStyleResolver.values(for: source, state: state,
            nodeType: nodeType, ids: ids, store: store, mapID: mapID)
    }

    private func drawTopology(_ features: [GeometryTopologyMapFeature],
                              styles: [String: VectorStyleValues],
                              context: inout GraphicsContext,
                              transform: MapTransform,
                              renderScale: Double) {
        let arcStyle = styles["Arc_Line_Symbology"] ?? .init()
        let nodeStyle = styles["Node_Symbology"] ?? .init()
        let deletableStyle = styles["Deletable_Node_Symbology"] ?? .init()
        let internalStyle = styles["Internal_Point_Symbology"] ?? .init()

        // ConceptualMesh is a retained TopologyRenderLayer: arcs, topology
        // nodes, and their internal vertices are the styled map primitives.
        // Region-size labels and generated previews remain editor-only.
        for feature in features where feature.geometryType == "line" {
            for coordinates in feature.paths {
                let path = linePath(coordinates, transform: transform)
                guard !path.isEmpty else { continue }
                let width = WorkspaceRenderScaling.metric(
                    arcStyle.penWidth.isFinite ? arcStyle.penWidth : 0, factor: renderScale)
                context.stroke(path, with: .color(sourceColor(arcStyle.penColor)), lineWidth: width)
                guard feature.featureKind == "arc", coordinates.count > 2 else { continue }
                let diameter = WorkspaceRenderScaling.metric(Double(max(0, internalStyle.pointSize)), factor: renderScale)
                guard diameter > 0 else { continue }
                for coordinate in coordinates.dropFirst().dropLast() {
                    let center = transform.screen(MapPoint(x: coordinate.x, y: coordinate.y))
                    let marker = Path(ellipseIn: CGRect(x: center.x - diameter / 2,
                        y: center.y - diameter / 2, width: diameter, height: diameter))
                    context.fill(marker, with: .color(sourceColor(internalStyle.fillColor)))
                    let outline = WorkspaceRenderScaling.metric(
                        internalStyle.penWidth.isFinite ? internalStyle.penWidth : 0, factor: renderScale)
                    context.stroke(marker, with: .color(sourceColor(internalStyle.penColor)), lineWidth: outline)
                }
            }
        }

        let worldUnitsPerPoint = transform.factor > 0 ? 1.0 / Double(transform.factor) : nil
        let baseNodeSize = GeometryMapStylePresentation.sourceTopologyNodePointSize
        for feature in features where feature.featureKind == "node" && feature.geometryType == "point" {
            guard let coordinate = feature.paths.first?.first,
                  coordinate.x.isFinite, coordinate.y.isFinite else { continue }
            let appearance = GeometryMapStylePresentation.topologyNode(
                nodeStyle, deletableStyle: deletableStyle, selected: false,
                incidentArcs: feature.incidentArcs, worldUnitsPerPoint: worldUnitsPerPoint,
                sourceDefaultPointSize: baseNodeSize, renderScale: renderScale)
            let diameter = CGFloat(max(0, appearance.diameter))
            guard diameter > 0 else { continue }
            let center = transform.screen(MapPoint(x: coordinate.x, y: coordinate.y))
            let marker = Path(ellipseIn: CGRect(x: center.x - diameter / 2,
                y: center.y - diameter / 2, width: diameter, height: diameter))
            context.fill(marker, with: .color(GeometryMapStylePresentation.color(for: appearance.fill)))
            context.stroke(marker, with: .color(GeometryMapStylePresentation.color(for: appearance.outline)),
                           lineWidth: max(0, appearance.outlineWidth))
        }
    }

    private func drawFlowAreas(_ cells: [GeometryMeshMapCell], style: VectorStyleValues,
                               context: inout GraphicsContext, transform: MapTransform,
                               renderScale: Double) {
        let color = sourceColor(style.penColor)
        let width = WorkspaceRenderScaling.metric(
            style.penWidth.isFinite ? style.penWidth : 0, factor: renderScale)
        for cell in cells {
            let path = polygonPath(cell.coordinates, transform: transform)
            guard !path.isEmpty else { continue }
            // MeshRenderLayer presents cell boundaries; no inferred fill or
            // color-by-area is introduced here.
            context.stroke(path, with: .color(color),
                           style: StrokeStyle(lineWidth: width, lineJoin: .round))
        }
    }

    private func drawCulverts(_ features: [GeometryCulvertFeatureRow],
                              lineStyle: VectorStyleValues, vertexStyle: VectorStyleValues,
                              context: inout GraphicsContext, transform: MapTransform,
                              renderScale: Double) {
        let lineColor = sourceColor(lineStyle.penColor)
        let lineWidth = WorkspaceRenderScaling.metric(
            lineStyle.penWidth.isFinite ? lineStyle.penWidth : 0, factor: renderScale)
        let vertexDiameter = WorkspaceRenderScaling.metric(Double(max(0, vertexStyle.pointSize)), factor: renderScale)
        for feature in features {
            let path = linePath(feature.polyline, transform: transform)
            guard !path.isEmpty else { continue }
            context.stroke(path, with: .color(lineColor),
                           style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
            guard vertexDiameter > 0 else { continue }
            for coordinate in feature.polyline where coordinate.x.isFinite && coordinate.y.isFinite {
                let center = transform.screen(MapPoint(x: coordinate.x, y: coordinate.y))
                let marker = Path(ellipseIn: CGRect(x: center.x - vertexDiameter / 2,
                    y: center.y - vertexDiameter / 2, width: vertexDiameter, height: vertexDiameter))
                context.fill(marker, with: .color(sourceColor(vertexStyle.fillColor)))
                let outline = WorkspaceRenderScaling.metric(
                    vertexStyle.penWidth.isFinite ? vertexStyle.penWidth : 0, factor: renderScale)
                context.stroke(marker, with: .color(sourceColor(vertexStyle.penColor)), lineWidth: outline)
            }
        }
    }

    private func linePath(_ coordinates: [GeometryTopologyCoordinate], transform: MapTransform) -> Path {
        var path = Path()
        guard let first = coordinates.first,
              first.x.isFinite, first.y.isFinite else { return path }
        path.move(to: transform.screen(MapPoint(x: first.x, y: first.y)))
        for coordinate in coordinates.dropFirst() where coordinate.x.isFinite && coordinate.y.isFinite {
            path.addLine(to: transform.screen(MapPoint(x: coordinate.x, y: coordinate.y)))
        }
        return path
    }

    private func linePath(_ coordinates: [GeometryCulvertCoordinate], transform: MapTransform) -> Path {
        linePath(coordinates.map { GeometryTopologyCoordinate(x: $0.x, y: $0.y) }, transform: transform)
    }

    private func polygonPath(_ coordinates: [GeometryTopologyCoordinate], transform: MapTransform) -> Path {
        var path = linePath(coordinates, transform: transform)
        guard coordinates.count > 2 else { return Path() }
        path.closeSubpath()
        return path
    }

    private func sourceColor(_ value: String) -> Color {
        SourceARGBColor.color(value) ?? .primary
    }
}

struct ProjectGeometryMapStatusOverlay: View {
    @ObservedObject var session: ProjectGeometryMapSession
    @ObservedObject var store: WorkspaceStore
    let mapID: UUID
    let refreshConfiguration: @MainActor () -> Void

    var body: some View {
        if session.isConfigured || session.error != nil {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label(L10n.text("Project Geometry"), systemImage: "point.3.connected.trianglepath.dotted")
                        .font(.headline)
                    Spacer()
                    Button("Refresh Geometry", action: refreshConfiguration)
                        .disabled(session.isLoading)
                }
                if let error = session.error {
                    Label(L10n.text(error), systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                if ProjectGeometryMapStyleResolver.hasUnavailableVisibleStyle(
                    in: session, store: store, mapID: mapID) {
                    Label(L10n.text("The per-map Geometry style could not be resolved for one or more visible layers."),
                          systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange).font(.caption)
                }
                ForEach(session.preflightDiagnostics.indices, id: \.self) { index in
                    Label(L10n.text(session.preflightDiagnostics[index]), systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange).font(.caption)
                }
                if let selection = session.selection {
                    Label("\(selection.geometryName) · \(L10n.text(selection.layerTitle)): \(selection.featureLabel)",
                          systemImage: "scope")
                        .font(.caption).lineLimit(2)
                }
                if session.sources.isEmpty && session.error == nil {
                    Text(L10n.text("No Geometry children are available for this map."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(session.sources) { source in
                    if let snapshot = source.snapshot {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(source.capture.geometryName).font(.subheadline.weight(.semibold))
                            layerStatus("Topology", state: snapshot.topologyState,
                                progress: source.topologyProgress, noun: "Source features")
                            if let presentation = source.flowAreaGenerationPresentation {
                                switch presentation.phase {
                                case .generating:
                                    Label(L10n.text("Generating mesh; Flow Areas are temporarily hidden."),
                                          systemImage: "gearshape.2")
                                        .font(.caption).foregroundStyle(.secondary)
                                case .childDraft:
                                    Label(L10n.text("Uncommitted Geometry mesh draft preview"),
                                          systemImage: "square.dashed")
                                        .font(.caption.weight(.medium))
                                    if let map = presentation.map {
                                        Text(L10n.format("Showing %@ of %@ mesh cells; %@ omitted and %@ invalid.",
                                            map.renderedCellCount.formatted(), map.totalCellCount.formatted(),
                                            map.omittedCellCount.formatted(), map.invalidCandidateCount.formatted()))
                                            .font(.caption).foregroundStyle(.secondary)
                                    } else {
                                        Text(L10n.text("The Geometry draft has no mesh map preview."))
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                case .awaitingSavedSource:
                                    Label(L10n.text("Refreshing the saved Geometry map after mesh generation."),
                                          systemImage: "arrow.triangle.2.circlepath")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            } else {
                                layerStatus("Flow Areas", state: snapshot.flowAreasState,
                                    progress: source.cellsProgress, noun: "Source cells")
                            }
                            layerStatus("Culverts", state: snapshot.culvertsState,
                                progress: source.culvertsProgress, noun: "Source barrels")
                            if let error = source.error {
                                Text(L10n.text(error)).foregroundStyle(.orange).font(.caption)
                            }
                        }
                    } else if let error = source.error {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(source.capture.geometryName).font(.subheadline.weight(.semibold))
                            Text(L10n.text(error)).foregroundStyle(.orange).font(.caption)
                        }
                    }
                }
                if session.isLoading { ProgressView().controlSize(.small) }
                if session.isLoading || session.canContinuePaging {
                    Button(session.isPaused ? "Resume Geometry paging"
                        : session.isLoading ? "Pause Geometry paging" : "Retry Geometry paging") {
                        session.togglePaging()
                    }
                }
                if !session.isLoading && session.visibleGeometryFeatureCount == 0
                    && !session.hasFlowAreaGenerationPresentation {
                    Text(L10n.text("No visible source geometry is in the current map view."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .frame(maxWidth: 370, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .accessibilityElement(children: .contain)
        }
    }

    @ViewBuilder
    private func layerStatus(_ title: String, state: MapGeometryLayerState,
                             progress: ProjectGeometryMapPageProgress, noun: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(L10n.text(title)).font(.caption.weight(.medium))
            Text(L10n.text(state.status.rawValue.capitalized)).font(.caption)
            Text(L10n.text(state.isChecked ? "Checked" : "Not checked")).font(.caption)
            if state.effectiveVisible { Text(L10n.text("Visible")).font(.caption) }
            if progress.scannedCount > 0 || progress.returnedCount > 0 {
                Text(L10n.format("%@ of %@ %@ scanned; %@ returned for this view.",
                    progress.scannedCount.formatted(), progress.sourceCount.formatted(),
                    L10n.text(noun),
                    progress.returnedCount.formatted()))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let diagnostic = state.diagnostic {
                Text(L10n.text(diagnostic)).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
