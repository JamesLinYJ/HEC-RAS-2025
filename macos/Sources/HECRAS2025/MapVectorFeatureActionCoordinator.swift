import Foundation
import RASWorkspaceCore
import SwiftUI

/// Owns the source validation and dispatch shared by map-canvas and feature-row
/// context menus. It retains the workspace models only; it never retains a View.
@MainActor
final class MapVectorFeatureActionCoordinator {
    private let store: WorkspaceStore
    private let mapState: MapState
    private let mapID: UUID

    init(store: WorkspaceStore, mapState: MapState, mapID: UUID) {
        self.store = store
        self.mapState = mapState
        self.mapID = mapID
    }

    static func visibleVectorLayers(store: WorkspaceStore, mapState: MapState) -> [MapVectorLayer] {
        MapRenderComposition.vectorLayers(records: mapState.sourceMapRenderRows,
            candidates: mapState.visibleVectors(store.mapLayers))
    }

    /// Opens the same source-scoped selection that a canvas right-click opens,
    /// then freezes its stable identities for the lifetime of the menu.
    func captureListFeature(row: MapSourceRenderRecord, displayedLayer: MapVectorLayer,
                            featureIdentity: String,
                            modifiers: Set<MapInput.Modifier>) -> MapVectorFeatureContextSnapshot? {
        guard store.existingMapState(for: mapID) === mapState,
              mapState.kind != .unsupported,
              ["select", "Map.Pan"].contains(mapState.toolID) else { return nil }
        let rows = MapContextComponentResolver.visibleRows(mapState.sourceMapRenderRows, mapID: mapID)
        let layers = Self.visibleVectorLayers(store: store, mapState: mapState)
        guard let target = MapContextComponentFeatureTargetResolver.exactTarget(
            row: row, displayedLayer: displayedLayer, featureIdentity: featureIdentity,
            mapID: mapID, rows: rows, candidates: layers) else { return nil }
        return captureSelectionContext(row: target.row, layer: target.layer,
            feature: target.feature, modifiers: modifiers)
    }

    func captureCanvasFeature(at location: CGPoint,
                              transform: MapTransform,
                              modifiers: Set<MapInput.Modifier>,
                              visibleLayers: [MapVectorLayer]) -> MapVectorFeatureContextSnapshot? {
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
        let renderFactor = WorkspaceRenderScaling.shared.factor
        let hit = MapVectorFeatureHitTester.closestFeature(at: location, transform: transform,
            layers: exactLayers, tolerance: 8,
            lineWidth: { layer, feature in
                let style = MapVectorStyleResolver.values(layerID: layer.id, feature: feature,
                    definitionID: MapVectorStyleDefinitionIDs.primaryDefinition(for: feature.kind),
                    presentations: mapState.vectorStyles)
                return WorkspaceRenderScaling.metric(
                    Double(VectorMapCanvas.safeLineWidth(style.penWidth)), factor: renderFactor)
            },
            pointDiameter: { layer, feature in
                let style = MapVectorStyleResolver.values(layerID: layer.id, feature: feature,
                    definitionID: MapVectorStyleDefinitionIDs.primaryDefinition(for: feature.kind),
                    presentations: mapState.vectorStyles)
                return WorkspaceRenderScaling.metric(
                    Double(VectorMapCanvas.safePointDiameter(style.pointSize)), factor: renderFactor)
            })
        guard let hit else { return nil }
        let layerMatches = exactLayers.filter { $0.id == hit.layerID }
        guard layerMatches.count == 1, let layer = layerMatches.first else { return nil }
        let featureMatches = layer.features.filter {
            $0.stableIdentity == hit.featureIdentity && $0.hasUniqueStableIdentity
        }
        guard featureMatches.count == 1, let feature = featureMatches.first else { return nil }
        let rowMatches = rows.filter {
            $0.payloadKind == "MapLayer" && $0.payloadLayerIDs == [layer.id]
        }
        guard rowMatches.count == 1, let row = rowMatches.first else { return nil }
        let pathIdentity = feature.kind == .line
            ? nearestPathIdentity(feature, at: location, transform: transform) : nil
        return captureSelectionContext(row: row, layer: layer, feature: feature,
            modifiers: modifiers, selectedLineIdentity: pathIdentity)
    }

    func makeContextSnapshot(row: MapSourceRenderRecord, layer: MapVectorLayer,
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
            mapID: mapID, contextIdentity: row.contextIdentity,
            mapWorkflowIdentity: store.mapWorkflowIdentity(mapID), layer: layer,
            clickedFeatureIdentity: clickedFeature.stableIdentity,
            selectedFeatureIdentities: identities, selectedFeatures: selected,
            editorCanDeleteSelectedFeatures: editorCanDelete, editorCanUndo: editorCanUndo,
            editorCanRedo: editorCanRedo, editorCanSave: editorCanSave,
            canPasteCopiedLines: canPaste)
    }

    private func captureSelectionContext(row: MapSourceRenderRecord,
                                         layer: MapVectorLayer,
                                         feature: MapFeature,
                                         modifiers: Set<MapInput.Modifier>,
                                         selectedLineIdentity: String? = nil)
        -> MapVectorFeatureContextSnapshot? {
        let selectedBeforeContextClick = mapState.selectedVectorFeatureIdentities(in: layer)
        let mode = MapVectorFeatureContextSelection.mode(clickedFeatureIdentity: feature.stableIdentity,
            selectedFeatureIdentities: selectedBeforeContextClick, modifiers: modifiers)
        if let asset = store.assets.first(where: {
            SourceFilePaths.canonical($0.url) == SourceFilePaths.canonical(layer.url)
        }) {
            store.select(asset)
        }
        store.activateMap(mapID)
        mapState.selectSourceContext(row.contextIdentity)
        guard mapState.selectVectorFeature(feature, in: layer, mode: mode) else { return nil }
        if let selectedLineIdentity { mapState.selectedLineIdentity = selectedLineIdentity }

        let selectedSet = mapState.selectedVectorFeatureIdentities(in: layer)
        let identities = layer.features.filter { selectedSet.contains($0.stableIdentity) }.map(\.stableIdentity)
        guard !identities.isEmpty else { return nil }
        store.selectedFeatureID = mapState.selectedFeatureID
        store.inspectorMode = .components
        store.showInspector = true
        return makeContextSnapshot(row: row, layer: layer, clickedFeature: feature, identities: identities)
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

    func performContextAction(_ action: MapVectorFeatureContextAction,
                              captured: MapVectorFeatureContextSnapshot,
                              openAttributeTable: (AttributeTableRoute) -> Void) {
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
            openAttributeTable(AttributeTableRoute(path: current.canonicalSourcePath, focusRowID: rowID))
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
        guard store.existingMapState(for: mapID) === mapState,
              mapState.selectedSourceContextIdentity == captured.contextIdentity else { return nil }
        let rows = MapContextComponentResolver.visibleRows(mapState.sourceMapRenderRows, mapID: mapID)
        guard let row = MapContextComponentResolver.exactRow(
            contextIdentity: captured.contextIdentity, among: rows) else { return nil }
        let layers = Self.visibleVectorLayers(store: store, mapState: mapState)
        let sourceMatches = layers.filter {
            $0.id == captured.layer.id
                && SourceFilePaths.canonical($0.url) == captured.canonicalSourcePath
                && $0.sourceRevision == captured.sourceRevision
        }
        guard sourceMatches.count == 1, let layer = sourceMatches.first,
              MapContextComponentResolver.exactVectorLayers(for: row, candidates: layers)
                .contains(where: { $0.id == layer.id }),
              MapVectorFeatureContextCurrentness.matches(captured,
                projectSessionID: store.projectSessionID, mapID: mapID,
                contextIdentity: row.contextIdentity,
                mapWorkflowIdentity: store.mapWorkflowIdentity(mapID), layer: layer,
                selectedFeatureIdentities: mapState.selectedVectorFeatureIdentities(in: layer)) else {
            return nil
        }
        let clickedMatches = layer.features.filter {
            $0.stableIdentity == captured.clickedFeatureIdentity && $0.hasUniqueStableIdentity
        }
        guard clickedMatches.count == 1, let clicked = clickedMatches.first else { return nil }
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
                  store.projectSessionID == context.projectSessionID else {
                if let error = mapState.polylineEditor.errorMessage { store.errorMessage = L10n.text(error) }
                return
            }
            let matches = mapState.vectors(store.mapLayers).filter {
                $0.id == context.layer.id
                    && SourceFilePaths.canonical($0.url) == context.canonicalSourcePath
                    && $0.sourceRevision == context.sourceRevision
            }
            guard matches.count == 1, let layer = matches.first,
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
                  store.projectSessionID == context.projectSessionID else { return }
            let matches = mapState.vectors(store.mapLayers).filter {
                $0.id == context.layer.id
                    && SourceFilePaths.canonical($0.url) == context.canonicalSourcePath
                    && $0.sourceRevision == context.sourceRevision
            }
            guard matches.count == 1, let layer = matches.first,
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
}
