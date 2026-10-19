import Foundation
import RASWorkspaceCore

/// Resolves a transient Generate Mesh visibility state through the exact map
/// Geometry owner. Display names alone never borrow a sibling Geometry job.
@MainActor
enum FlowAreaMapGenerationVisibility {
    static func activeSession(node: LayerTreeNode, mapID: UUID,
                              projectSessionID: UUID, store: WorkspaceStore) -> GeometryMeshSession? {
        guard node.sourceClass == "FlowAreaLayerVisualContext",
              let locator = node.sourceLocator,
              locator.nodeType == "FlowAreaLayer",
              let geometryPath = locator.parentGeometryAssetID else { return nil }
        return activeSession(geometryPath: geometryPath, parentNodePath: locator.parentGeometryNodePath,
            parentNodeName: locator.parentGeometryNodeName, mapID: mapID,
            projectSessionID: projectSessionID, store: store)
    }

    static func activeSession(geometryPath: String, parentNodePath: [Int]? = nil,
                              parentNodeName: String? = nil, mapID: UUID,
                              projectSessionID: UUID, store: WorkspaceStore) -> GeometryMeshSession? {
        guard store.projectSessionID == projectSessionID,
              let mapState = store.existingMapState(for: mapID) else { return nil }
        let canonicalPath = SourceFilePaths.canonical(URL(fileURLWithPath: geometryPath))
        let matches = mapState.projectGeometryMap.sources.filter { source in
            let capture = source.capture
            return capture.projectSessionID == projectSessionID
                && capture.mapID == mapID
                && capture.geometryCanonicalPath == canonicalPath
                && (parentNodePath == nil || capture.geometryNode.nodePath == parentNodePath)
                && (parentNodeName == nil || capture.geometryNode.nodeName == parentNodeName)
        }
        guard matches.count == 1, let source = matches.first,
              let mesh = store.activeGeometryMeshGeneration(assetID: canonicalPath,
                  projectSessionID: projectSessionID),
              let revision = source.geometryRevision ?? mesh.meshGenerationSourceRevision,
              mesh.matchesActiveMeshGeneration(projectSessionID: projectSessionID,
                  sourcePath: canonicalPath, sourceRevision: revision) else { return nil }
        return mesh
    }

    static func hasLocalVisibilityOverride(node: LayerTreeNode, mapID: UUID,
                                           projectSessionID: UUID,
                                           store: WorkspaceStore) -> Bool {
        guard node.sourceClass == "FlowAreaLayerVisualContext",
              let locator = node.sourceLocator,
              locator.nodeType == "FlowAreaLayer",
              store.projectSessionID == projectSessionID,
              let mapState = store.existingMapState(for: mapID) else { return false }
        return mapState.projectGeometryMap.hasFlowAreaGenerationVisibilityOverride(
            locator: locator, mapID: mapID, projectSessionID: projectSessionID,
            mapWorkflowIdentity: store.mapSourceWorkflowIdentity(mapID))
    }

    @discardableResult
    static func clearLocalVisibilityOverride(node: LayerTreeNode, mapID: UUID,
                                             projectSessionID: UUID,
                                             store: WorkspaceStore) -> Bool {
        guard node.sourceClass == "FlowAreaLayerVisualContext",
              let locator = node.sourceLocator,
              locator.nodeType == "FlowAreaLayer",
              store.projectSessionID == projectSessionID,
              let mapState = store.existingMapState(for: mapID) else { return false }
        let workflowIdentity = store.mapSourceWorkflowIdentity(mapID)
        if mapState.projectGeometryMap.hasFlowAreaGenerationVisibilityOverride(
            locator: locator, mapID: mapID, projectSessionID: projectSessionID,
            mapWorkflowIdentity: workflowIdentity),
           let geometryPath = locator.parentGeometryAssetID,
           let mesh = store.geometryMeshSession(assetID: geometryPath,
               projectSessionID: projectSessionID),
           let terminalIdentity = mesh.meshGenerationTerminalIdentity {
            _ = mapState.projectGeometryMap.suppressFlowAreaGenerationVisibilityOverride(
                locator: locator, mapID: mapID, projectSessionID: projectSessionID,
                mapWorkflowIdentity: workflowIdentity, generationResultIdentity: terminalIdentity)
        }
        return mapState.projectGeometryMap.clearFlowAreaGenerationVisibilityOverride(
            locator: locator, mapID: mapID, projectSessionID: projectSessionID,
            mapWorkflowIdentity: workflowIdentity)
    }
}
