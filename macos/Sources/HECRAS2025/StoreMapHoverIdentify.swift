import CryptoKit
import Foundation
import RASWorkspaceCore

private struct MapHoverIdentifySourceIdentity: Encodable {
    let map: MapResultChartMapRequest
    let contextToken: String
    let selectionOverrides: [MapResultSelectionOverride]
    let profileSelections: [MapDynamicProfileSelection]
    let layers: [MapHoverLayerCapture]
    let vectors: [MapHoverIdentifyVectorSource]
    let selectedLayerID: String?
    let selectedContextIdentity: String?
}

private struct MapHoverIdentifySources {
    let map: MapResultChartMapRequest
    let contextToken: String
    let selectionOverrides: [MapResultSelectionOverride]
    let profiles: [MapDynamicProfileSelection]
    let layers: [MapHoverLayerCapture]
    let vectors: [MapHoverIdentifyVectorSource]
    let selectedLayerID: String?
    let selectedContextIdentity: String?
}

@MainActor
extension WorkspaceStore {
    func captureMapHoverIdentify(mapID: UUID, point: MapPoint,
                                 worldUnitsPerScreenPoint: Double,
                                 screenPoint: CGPoint,
                                 localEntries: [MapHoverIdentifyEntry]) -> MapHoverIdentifyFlight? {
        guard point.x.isFinite, point.y.isFinite,
              worldUnitsPerScreenPoint.isFinite, worldUnitsPerScreenPoint > 0,
              screenPoint.x.isFinite, screenPoint.y.isFinite,
              let sources = mapHoverIdentifySources(mapID: mapID) else { return nil }
        let probe = Self.mapHoverProbe(from: point, delta: worldUnitsPerScreenPoint)
        guard let probe else { return nil }
        let request = MapHoverIdentifyRequest(map: sources.map, contextToken: sources.contextToken,
            selectionOverrides: sources.selectionOverrides, requestID: UUID().uuidString,
            point: MapHoverCoordinate(x: point.x, y: point.y),
            probePoint: MapHoverCoordinate(x: probe.x, y: probe.y),
            worldUnitsPerScreenPoint: worldUnitsPerScreenPoint,
            profileSelections: sources.profiles, layers: sources.layers)
        let identity = Self.mapHoverSourceIdentity(sources)
        return MapHoverIdentifyFlight(request: request, sourceIdentity: identity,
            screenX: screenPoint.x, screenY: screenPoint.y, localEntries: localEntries)
    }

    func currentMapHoverIdentifySourceIdentity(mapID: UUID) -> String? {
        guard let sources = mapHoverIdentifySources(mapID: mapID) else { return nil }
        return Self.mapHoverSourceIdentity(sources)
    }

    private func mapHoverIdentifySources(mapID: UUID) -> MapHoverIdentifySources? {
        guard !isOpeningProject, !isClosingTab, hasProject,
              let state = existingMapState(for: mapID), state.kind != .unsupported,
              let map = mapResultRequest(for: mapID),
              let snapshot = state.resultSources.snapshot,
              let currentMap = mapIdentityRequest(for: mapID),
              map.mapID == currentMap.mapID,
              map.projectXmlSHA.caseInsensitiveCompare(currentMap.projectXmlSHA) == .orderedSame,
              map.expectedVisualizationRevision.caseInsensitiveCompare(currentMap.expectedVisualizationRevision) == .orderedSame,
              snapshot.sources.mapID.caseInsensitiveCompare(map.mapID) == .orderedSame,
              snapshot.sources.mapIndex == map.mapIndex,
              snapshot.sources.mapName == map.mapName,
              snapshot.sources.mapType == map.mapType,
              snapshot.sources.projectXmlSHA.caseInsensitiveCompare(map.projectXmlSHA) == .orderedSame,
              snapshot.sources.visualizationRevision.caseInsensitiveCompare(map.expectedVisualizationRevision) == .orderedSame,
              !snapshot.sources.contextToken.isEmpty else { return nil }

        let records = MapRenderComposition.orderedRecords(state.sourceMapRenderRows)
            .filter { $0.mapID == mapID }
        guard !records.isEmpty else { return nil }
        let visibleVectors = MapRenderComposition.vectorLayers(records: state.sourceMapRenderRows,
            candidates: state.visibleVectors(mapLayers))
        let vectorSources = MapHoverIdentifyVector.sources(mapID: mapID,
            records: state.sourceMapRenderRows, candidates: visibleVectors,
            selectedLayerID: state.selectedLayerID,
            selectedContextIdentity: state.selectedSourceContextIdentity)
        var paintPriority = Array(records.reversed())

        // The focused tree context and selected rendered payload sit above
        // paint-order priority, matching the user's current map-source focus.
        if let selectedLayerID = state.selectedLayerID,
           let index = paintPriority.firstIndex(where: { $0.payloadLayerIDs.contains(selectedLayerID) }) {
            let row = paintPriority.remove(at: index)
            paintPriority.insert(row, at: 0)
        }
        if let selectedContext = state.selectedSourceContextIdentity,
           let index = paintPriority.firstIndex(where: { $0.contextIdentity == selectedContext }) {
            let row = paintPriority.remove(at: index)
            paintPriority.insert(row, at: min(1, paintPriority.count))
        }

        var captures: [MapHoverLayerCapture] = []
        var profiles: [MapDynamicProfileSelection] = []
        for row in paintPriority {
            let visiblePayloads = row.payloadLayerIDs.filter { !state.hiddenLayers.contains($0) }
            guard !visiblePayloads.isEmpty else { continue }

            switch row.payloadKind {
            case "Result", "MultiResult":
                let activeNodes = snapshot.sources.activeNodes.filter { $0.node == row.locator }
                guard activeNodes.count == 1, let active = activeNodes.first,
                      let resultNode = state.resultMap.nodes.first(where: { $0.id == active.id }),
                      let mapType = resultNode.selectedMapType,
                      let profileIndex = resultNode.profileIndex,
                      !state.resultMap.layers(for: row.locator).filter({ !state.hiddenLayers.contains($0.id) }).isEmpty else {
                    continue
                }
                let selections = active.selections.compactMap { slot -> MapHoverResultSelectionCapture? in
                    guard let selected = slot.selectedResult else { return nil }
                    return MapHoverResultSelectionCapture(selectionIndex: slot.selectionIndex,
                        resultPath: selected.resultPath, resultRevision: selected.revision)
                }
                guard !selections.isEmpty else { continue }
                profiles.append(MapDynamicProfileSelection(node: row.locator, profileIndex: profileIndex))
                captures.append(MapHoverLayerCapture(node: row.locator, kind: "result",
                    mapType: mapType, profileIndex: profileIndex, resultSelections: selections))

            case "Terrain":
                guard let associated = currentAssociatedLayer(for: row, state: state, map: currentMap),
                      let payload = associated.payload,
                      let sourcePath = nonempty(associated.capture.assetPath),
                      !payload.revision.isEmpty else { continue }
                captures.append(MapHoverLayerCapture(node: row.locator, kind: "terrain",
                    sourcePath: sourcePath, sourceRevision: payload.revision))

            case "NValue", "Classification":
                guard let associated = currentAssociatedLayer(for: row, state: state, map: currentMap),
                      let payload = associated.payload,
                      !payload.revision.isEmpty else { continue }
                captures.append(MapHoverLayerCapture(node: row.locator,
                    kind: row.payloadKind == "NValue" ? "nvalue" : "classification",
                    sourcePath: associated.capture.assetPath, sourceRevision: payload.revision,
                    associated: MapHoverAssociatedCapture(
                        geometryNodes: associated.capture.geometryNodes,
                        planNodes: associated.capture.planNodes,
                        resultOwners: associated.capture.resultOwners,
                        dependencies: payload.dependencies.map {
                            MapHoverAssociatedDependency(path: $0.path, revision: $0.revision, role: $0.role)
                        })))

            case "MapLayer":
                guard let descriptor = rasterMapSources.first(where: { source in
                    source.sourceMapID == mapID && source.nodePath == row.locator.nodePath
                        && source.nodeName == row.locator.nodeName
                        && source.mapLayerType == row.locator.mapType
                        && visiblePayloads.contains(source.id)
                        && source.sourceRevision?.isEmpty == false
                }), descriptor.gdbSource == nil else { continue }
                captures.append(MapHoverLayerCapture(node: row.locator, kind: "raster",
                    sourcePath: descriptor.sourcePath, sourceRevision: descriptor.sourceRevision,
                    mapType: descriptor.mapLayerType, rasterSource: descriptor))

            case "FlowAreaLayer":
                guard let mesh = currentFlowAreaMeshCapture(for: row, state: state,
                    map: currentMap, mapID: mapID) else { continue }
                captures.append(MapHoverLayerCapture(node: row.locator, kind: "mesh", mesh: mesh))

            default:
                // Vector FID/action hover and live solver annotations use
                // separate renderer semantics and are intentionally not
                // synthesized from the displayed canvas pixels.
                continue
            }
            if captures.count >= 256 { break }
        }
        guard !captures.isEmpty || !vectorSources.isEmpty else { return nil }
        return MapHoverIdentifySources(map: map, contextToken: snapshot.sources.contextToken,
            selectionOverrides: snapshot.selectionOverrides, profiles: profiles, layers: captures,
            vectors: vectorSources, selectedLayerID: state.selectedLayerID,
            selectedContextIdentity: state.selectedSourceContextIdentity)
    }

    private func currentAssociatedLayer(for row: MapSourceRenderRecord, state: MapState,
                                        map: MapTreeMapIdentity) -> AssociatedMapLayerState? {
        let matches = state.associatedMapLayers.entries.filter {
            $0.capture.associationNode == row.locator
                && $0.capture.projectSessionID == projectSessionID
                && $0.capture.mapID == state.id
                && $0.capture.map == map
                && $0.capture.mapWorkflowIdentity == mapWorkflowIdentity(state.id)
                && $0.capture.isChecked && $0.capture.effectiveVisible
                && $0.payload?.status == .available
                && $0.payload?.isChecked == true && $0.payload?.effectiveVisible == true
                && $0.payload?.revision.isEmpty == false
                && $0.rasterLayer != nil
        }
        guard matches.count == 1 else { return nil }
        return matches.first
    }

    private func currentFlowAreaMeshCapture(for row: MapSourceRenderRecord, state: MapState,
                                            map: MapTreeMapIdentity, mapID: UUID) -> MapHoverMeshCapture? {
        let matches = state.projectGeometryMap.sources.filter { source in
            source.capture.projectSessionID == projectSessionID
                && source.capture.mapID == mapID
                && source.capture.map == map
                && source.capture.mapWorkflowIdentity == mapWorkflowIdentity(mapID)
                && source.snapshot?.flowAreasState.locator == row.locator
                && source.snapshot?.geometryEffectiveVisible == true
                && source.presentsFlowAreaData
        }
        guard matches.count == 1, let source = matches.first,
              let snapshot = source.snapshot,
              let geometryContextToken = source.contextToken, !geometryContextToken.isEmpty,
              let sourceRevision = nonempty(source.geometryRevision),
              let rowPayload = source.capture.identity.nilIfEmpty.map({ $0 + "|" + row.locator.sourceIdentity }),
              row.payloadLayerIDs.contains(rowPayload), !state.hiddenLayers.contains(rowPayload) else { return nil }

        let ownerMode: String
        let model: GeometryMeshModelRequest?
        let meshDraftState: String
        let meshDraftSHA256: String
        let topologyDraftState: String?
        let topologyDraftSHA256: String
        if source.capture.resultOwner != nil {
            ownerMode = "resultSource"
            model = nil
            meshDraftState = ""
            meshDraftSHA256 = Self.sha256("")
            topologyDraftState = nil
            topologyDraftSHA256 = Self.sha256("")
        } else if geometryMeshEditorCount(for: source.capture.geometryCanonicalPath) == 1 {
            guard let meshSession = geometryMeshSession(assetID: source.capture.geometryCanonicalPath,
                    projectSessionID: projectSessionID),
                  let capture = meshSession.plotRenderingOwnerCapture(
                    for: source.capture.geometryCanonicalPath, expectedRevision: sourceRevision),
                  capture.sourceRevision.caseInsensitiveCompare(sourceRevision) == .orderedSame else { return nil }
            ownerMode = "parentDraft"
            model = capture.model
            meshDraftState = capture.meshDraftState
            meshDraftSHA256 = capture.meshDraftSHA256
            topologyDraftState = capture.topologyDraftState
            topologyDraftSHA256 = capture.topologyDraftSHA256
        } else {
            guard geometryMeshEditorCount(for: source.capture.geometryCanonicalPath) == 0 else { return nil }
            ownerMode = "savedSource"
            model = GeometryMeshModelRequest(assetPath: source.capture.geometryCanonicalPath,
                kind: "Geometry", projectPath: map.projectPath, projectXml: map.projectXml,
                coreLayerContext: map.coreLayerContext)
            meshDraftState = ""
            meshDraftSHA256 = Self.sha256("")
            topologyDraftState = nil
            topologyDraftSHA256 = Self.sha256("")
        }
        let flowAreaVisibilityOverride = source.flowAreaVisibilityOverrideLocatorIdentity
            == row.locator.sourceIdentity
        guard !flowAreaVisibilityOverride || ownerMode == "parentDraft",
              snapshot.projectXmlSHA?.caseInsensitiveCompare(map.projectXmlSHA) == .orderedSame else { return nil }

        return MapHoverMeshCapture(node: row.locator,
            geometryNode: source.capture.geometryNode,
            sourceIdentity: source.capture.identity,
            geometryContextToken: geometryContextToken,
            sourcePath: source.capture.geometryCanonicalPath,
            sourceRevision: sourceRevision,
            planNodes: source.capture.planNodes,
            resultOwner: source.capture.resultOwner,
            model: model,
            ownerMode: ownerMode,
            meshDraftState: meshDraftState,
            meshDraftSHA256: meshDraftSHA256,
            topologyDraftState: topologyDraftState,
            topologyDraftSHA256: topologyDraftSHA256,
            flowAreaVisibilityOverride: flowAreaVisibilityOverride)
    }

    private static func mapHoverSourceIdentity(_ sources: MapHoverIdentifySources) -> String {
        let payload = MapHoverIdentifySourceIdentity(map: sources.map,
            contextToken: sources.contextToken,
            selectionOverrides: sources.selectionOverrides,
            profileSelections: sources.profiles,
            layers: sources.layers,
            vectors: sources.vectors,
            selectedLayerID: sources.selectedLayerID,
            selectedContextIdentity: sources.selectedContextIdentity)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = (try? encoder.encode(payload)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02X", $0) }.joined()
    }

    private static func mapHoverProbe(from point: MapPoint, delta: Double) -> MapPoint? {
        guard delta.isFinite, delta > 0 else { return nil }
        let nextX = point.x + delta
        if nextX.isFinite, nextX != point.x { return MapPoint(x: nextX, y: point.y) }
        let adjacentX = point.x.nextUp
        if adjacentX.isFinite, adjacentX != point.x { return MapPoint(x: adjacentX, y: point.y) }
        let nextY = point.y + delta
        if nextY.isFinite, nextY != point.y { return MapPoint(x: point.x, y: nextY) }
        let adjacentY = point.y.nextUp
        guard adjacentY.isFinite, adjacentY != point.y else { return nil }
        return MapPoint(x: point.x, y: adjacentY)
    }

    private static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02X", $0) }.joined()
    }

    private func nonempty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
