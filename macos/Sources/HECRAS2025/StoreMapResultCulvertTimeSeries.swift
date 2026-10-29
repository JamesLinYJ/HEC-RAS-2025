import Foundation
import RASWorkspaceCore

@MainActor
extension WorkspaceStore {
    func mapResultCulvertTimeSeriesRoute(mapID: UUID, barrelIDs: [String],
                                        variable: String) throws
        -> MapResultCulvertTimeSeriesWindowRoute {
        guard let state = existingMapState(for: mapID),
              let capture = state.storedCulvertProfile.capture,
              let profile = state.storedCulvertProfile.snapshot,
              mapResultCulvertTimeSeriesCaptureIsCurrent(capture, profile: profile,
                                                        state: state, mapID: mapID),
              let mapRequest = mapResultRequest(for: mapID) else {
            throw MapResultCulvertTimeSeriesError.staleContext
        }
        let barrelsByID = Dictionary(uniqueKeysWithValues: profile.barrels.map { ($0.id, $0) })
        let expectedBarrels = try barrelIDs.map { id -> MapResultCulvertTimeSeriesBarrelIdentity in
            guard let barrel = barrelsByID[id],
                  barrel.id == "barrel:source:\(barrel.sourceOrdinal)" else {
                throw MapResultCulvertTimeSeriesError.incompleteIdentity
            }
            return .init(id: barrel.id, sourceOrdinal: barrel.sourceOrdinal, name: barrel.name)
        }
        let request = MapResultCulvertTimeSeriesRequest(map: mapRequest,
            resultOwner: capture.resultOwner, barrelIDs: barrelIDs, variable: variable)
        return try MapResultCulvertTimeSeriesWindowRoute(request: request,
            expectedProjectRevision: capture.projectRevision,
            expectedBarrels: expectedBarrels,
            projectSessionID: capture.projectSessionID,
            mapWorkflowIdentity: mapWorkflowIdentity(mapID),
            mapSourceWorkflowIdentity: mapSourceWorkflowIdentity(mapID),
            profileCaptureIdentity: capture.identity,
            sourceContextIdentity: capture.sourceContextIdentity)
    }

    func isCurrentMapResultCulvertTimeSeriesRoute(
        _ route: MapResultCulvertTimeSeriesWindowRoute,
        state: MapState) -> Bool {
        guard let mapID = route.mapID,
              let capture = state.storedCulvertProfile.capture,
              let profile = state.storedCulvertProfile.snapshot,
              route.projectSessionID == projectSessionID,
              existingMapState(for: mapID) === state,
              mapWorkflowIdentity(mapID) == route.mapWorkflowIdentity,
              mapSourceWorkflowIdentity(mapID) == route.mapSourceWorkflowIdentity,
              mapResultRequest(for: mapID) == route.request.map,
              capture.identity == route.profileCaptureIdentity,
              capture.resultOwner == route.request.resultOwner,
              capture.sourceContextIdentity == route.sourceContextIdentity,
              mapResultCulvertTimeSeriesCaptureIsCurrent(capture, profile: profile,
                                                        state: state, mapID: mapID) else {
            return false
        }
        let barrelsByID = Dictionary(uniqueKeysWithValues: profile.barrels.map { ($0.id, $0) })
        return route.expectedBarrels.allSatisfy { expected in
            guard let barrel = barrelsByID[expected.id] else { return false }
            return barrel.sourceOrdinal == expected.sourceOrdinal && barrel.name == expected.name
        }
    }

    func mapResultCulvertTimeSeriesCaptureIsCurrent(
        _ capture: StoredCulvertProfileCapture,
        profile: MapResultCulvertProfileSnapshot,
        state: MapState,
        mapID: UUID) -> Bool {
        guard capture.projectSessionID == projectSessionID,
              capture.mapID == mapID,
              capture.identity == state.storedCulvertProfile.capture?.identity,
              capture.workflowIdentity == mapSourceWorkflowIdentity(mapID),
              isCurrentMapState(state, mapID: mapID, projectSessionID: projectSessionID),
              let map = mapIdentityRequest(for: mapID),
              let mapRequest = mapResultRequest(for: mapID),
              capture.map == map,
              mapRequest.projectPath == map.projectPath,
              mapRequest.projectXml == map.projectXml,
              mapRequest.projectXmlSHA.caseInsensitiveCompare(map.projectXmlSHA) == .orderedSame,
              mapRequest.mapID.caseInsensitiveCompare(map.mapID) == .orderedSame,
              mapRequest.mapIndex == map.mapIndex,
              mapRequest.mapName == map.mapName,
              mapRequest.mapType == map.mapType,
              mapRequest.expectedVisualizationRevision.caseInsensitiveCompare(
                map.expectedVisualizationRevision) == .orderedSame,
              mapRequest.coreLayerContext == map.coreLayerContext,
              state.selectedSourceContextIdentity == capture.sourceContextIdentity,
              state.resultSources.snapshot?.sources.contextToken == capture.resultOwner.contextToken,
              state.resultMap.selectedNodeID == capture.resultNodeID,
              profile.projectRevision == capture.projectRevision,
              profile.projectXmlSHA.caseInsensitiveCompare(map.projectXmlSHA) == .orderedSame,
              profile.visualizationRevision.caseInsensitiveCompare(
                map.expectedVisualizationRevision) == .orderedSame,
              profile.mapID.caseInsensitiveCompare(map.mapID) == .orderedSame,
              profile.mapIndex == map.mapIndex,
              profile.mapName == map.mapName,
              profile.mapType == map.mapType,
              profile.contextToken == capture.resultOwner.contextToken,
              profile.resultNode == capture.resultOwner.resultNode,
              profile.selectionIndex == 0,
              SourceFilePaths.canonical(URL(fileURLWithPath: profile.selectedResultPath))
                == capture.resultOwner.selectedResultPath,
              profile.selectedResultRevision.caseInsensitiveCompare(
                capture.resultOwner.selectedResultRevision) == .orderedSame,
              SourceFilePaths.canonical(URL(fileURLWithPath: profile.geometryPath))
                == capture.resultOwner.selectedResultPath,
              profile.geometryRevision.caseInsensitiveCompare(
                capture.resultOwner.selectedResultRevision) == .orderedSame,
              profile.geometryAvailable,
              profile.barrels.enumerated().allSatisfy({ index, barrel in
                  barrel.sourceOrdinal == index && barrel.id == "barrel:source:\(index)"
              }) else {
            return false
        }
        return true
    }
}
