import CryptoKit
import Foundation
import RASWorkspaceCore

enum MapHoverModelVectorCaptureBuilder {
    static func culvertBarrel(row: MapSourceRenderRecord,
                              source: ProjectGeometryMapSourceState,
                              model: GeometryCulvertModelRequest?,
                              culvertSnapshot: GeometryCulvertSnapshot? = nil)
        -> MapHoverModelVectorCapture? {
        guard row.payloadKind == "CulvertBarrelLayer", row.isActiveAndVisible,
              row.mapID == source.capture.mapID,
              source.capture.map.mapID.caseInsensitiveCompare(row.mapID.uuidString) == .orderedSame,
              !source.capture.mapWorkflowIdentity.isEmpty,
              let snapshot = source.snapshot,
              snapshot.geometryNode == source.capture.geometryNode,
              snapshot.geometryEffectiveVisible,
              snapshot.culvertsState.locator == row.locator,
              row.locator.parentGeometryNodePath == source.capture.geometryNode.nodePath,
              row.locator.parentGeometryNodeName == source.capture.geometryNode.nodeName,
              samePath(row.locator.parentGeometryAssetID ?? "",
                       source.capture.geometryCanonicalPath),
              snapshot.culvertsState.isChecked, snapshot.culvertsState.effectiveVisible,
              snapshot.culvertsState.status.hasSourceData,
              let sourceRevision = source.geometryRevision, isSHA256(sourceRevision),
              let geometryContextToken = source.contextToken, !geometryContextToken.isEmpty,
              row.payloadLayerIDs.contains(source.capture.identity + "|" + row.locator.sourceIdentity) else {
            return nil
        }

        let ownerMode: MapHoverModelVectorOwnerMode
        let resultOwner: MapResultGeometryOwner?
        let modelRequest: MapHoverModelVectorModelRequest?
        let draftState: String?
        let draftSHA: String?

        if let owner = source.capture.resultOwner {
            guard model == nil, culvertSnapshot == nil,
                  owner.selectionIndex == 0,
                  samePath(owner.selectedResultPath, source.capture.geometryCanonicalPath),
                  owner.selectedResultRevision.caseInsensitiveCompare(sourceRevision) == .orderedSame,
                  row.locator.parentResultNodeType == owner.resultNode.nodeType,
                  row.locator.parentResultNodePath == owner.resultNode.nodePath,
                  row.locator.parentResultNodeName == owner.resultNode.nodeName,
                  samePath(row.locator.parentResultAssetID ?? "", owner.selectedResultPath),
                  row.locator.parentResultRevision?.caseInsensitiveCompare(owner.selectedResultRevision)
                    == .orderedSame,
                  let exactOwner = try? MapResultGeometryOwner(
                    resultNode: owner.resultNode, contextToken: owner.contextToken,
                    selectionOverrides: owner.selectionOverrides,
                    selectionIndex: owner.selectionIndex,
                    selectedResultPath: owner.selectedResultPath,
                    selectedResultRevision: owner.selectedResultRevision) else { return nil }
            ownerMode = .resultSource
            resultOwner = exactOwner
            modelRequest = nil
            draftState = nil
            draftSHA = nil
        } else {
            guard let model, model.kind == "Geometry",
                  model.projectPath.map({ samePath($0, source.capture.map.projectPath) }) == true,
                  samePath(model.assetPath, source.capture.geometryCanonicalPath),
                  let projectXml = model.projectXml,
                  sha256(projectXml).caseInsensitiveCompare(source.capture.map.projectXmlSHA) == .orderedSame,
                  model.coreLayerContext?.identityToken == source.capture.map.coreLayerContext?.identityToken,
                  (model.coreLayerContext == nil) == (source.capture.map.coreLayerContext == nil) else {
                return nil
            }
            resultOwner = nil
            modelRequest = MapHoverModelVectorModelRequest(assetPath: model.assetPath,
                kind: model.kind, projectPath: model.projectPath, projectXml: model.projectXml,
                sourceState: nil, coreLayerContext: model.coreLayerContext)
            if let culvertSnapshot, culvertSnapshot.revision.caseInsensitiveCompare(sourceRevision) != .orderedSame {
                return nil
            }
            if let culvertSnapshot, culvertSnapshot.isDirty {
                guard culvertSnapshot.canEdit, !culvertSnapshot.draftState.isEmpty else { return nil }
                ownerMode = .parentDraft
                draftState = culvertSnapshot.draftState
                draftSHA = sha256(culvertSnapshot.draftState)
            } else {
                ownerMode = .savedSource
                draftState = nil
                draftSHA = nil
            }
        }

        return MapHoverModelVectorCapture(node: row.locator, rendererKind: .culvertBarrel,
            sourcePath: SourceFilePaths.canonical(URL(fileURLWithPath: source.capture.geometryCanonicalPath)),
            sourceRevision: sourceRevision.uppercased(), ownerMode: ownerMode,
            geometryNode: source.capture.geometryNode, geometryContextToken: geometryContextToken,
            planNodes: source.capture.planNodes, resultOwner: resultOwner, model: modelRequest,
            culvertDraftState: draftState, culvertDraftSHA256: draftSHA,
            boundarySourceState: nil, boundaryContextToken: nil, boundaryLines: nil)
    }

    static func boundaryConditionLine(source: BoundaryMapSourceState)
        -> MapHoverModelVectorCapture? {
        let capture = source.capture
        guard capture.isChecked, capture.effectiveVisible,
              !capture.mapWorkflowIdentity.isEmpty,
              capture.boundaryNode.nodeType == "BoundaryCondition",
              let contextToken = source.contextToken, !contextToken.isEmpty,
              let boundarySourceState = source.boundarySourceState, !boundarySourceState.isEmpty,
              isSHA256(capture.sourceRevision), source.status == .available,
              !source.visibleLines.isEmpty,
              samePath(capture.sourcePath,
                       capture.resultOwner == nil
                        ? (capture.boundaryNode.associationAssetID ?? capture.boundaryNode.assetID ?? "")
                        : (capture.boundaryNode.parentResultAssetID ?? "")) else {
            return nil
        }

        let lines = source.visibleLines.map { line in
            MapHoverModelVectorLine(id: line.id, name: line.name,
                sourceOrdinal: line.sourceOrdinal,
                coordinates: line.coordinates.map { MapHoverCoordinate(x: $0.x, y: $0.y) })
        }
        guard Set(lines.map(\.id)).count == lines.count,
              Set(lines.map(\.sourceOrdinal)).count == lines.count,
              lines.allSatisfy({ !$0.id.isEmpty && $0.sourceOrdinal >= 0
                  && $0.coordinates.count >= 2
                  && $0.coordinates.allSatisfy { $0.x.isFinite && $0.y.isFinite } }) else { return nil }

        let ownerMode: MapHoverModelVectorOwnerMode
        let resultOwner: MapResultGeometryOwner?
        let model: MapHoverModelVectorModelRequest?
        if let owner = capture.resultOwner {
            guard owner.selectedResultPath == capture.sourcePath,
                  owner.selectedResultRevision.caseInsensitiveCompare(capture.sourceRevision) == .orderedSame,
                  owner.selectionIndex == 0,
                  rowMatchesResultOwner(capture.boundaryNode, owner: owner),
                  let exactOwner = try? MapResultGeometryOwner(
                    resultNode: owner.resultNode, contextToken: owner.contextToken,
                    selectionOverrides: owner.selectionOverrides,
                    selectionIndex: owner.selectionIndex,
                    selectedResultPath: owner.selectedResultPath,
                    selectedResultRevision: owner.selectedResultRevision) else { return nil }
            ownerMode = .resultSource
            resultOwner = exactOwner
            model = nil
        } else {
            guard capture.boundaryNode.parentResultAssetID == nil,
                  capture.boundaryNode.parentResultNodePath == nil,
                  capture.boundaryNode.parentResultNodeName == nil,
                  capture.boundaryNode.parentResultNodeType == nil,
                  capture.boundaryNode.parentResultRevision == nil else { return nil }
            ownerMode = .savedSource
            resultOwner = nil
            model = MapHoverModelVectorModelRequest(assetPath: capture.sourcePath,
                kind: "Boundary Conditions", projectPath: capture.map.projectPath,
                projectXml: capture.map.projectXml, sourceState: boundarySourceState,
                coreLayerContext: capture.map.coreLayerContext)
        }

        return MapHoverModelVectorCapture(node: capture.boundaryNode,
            rendererKind: .boundaryConditionLine, sourcePath: capture.sourcePath,
            sourceRevision: capture.sourceRevision.uppercased(), ownerMode: ownerMode,
            geometryNode: nil, geometryContextToken: nil, planNodes: nil,
            resultOwner: resultOwner, model: model, culvertDraftState: nil,
            culvertDraftSHA256: nil, boundarySourceState: boundarySourceState,
            boundaryContextToken: contextToken, boundaryLines: lines)
    }

    private static func rowMatchesResultOwner(_ node: CatalogTreeNodeLocator,
                                              owner: MapResultOwnerSelection) -> Bool {
        node.parentResultNodeType == owner.resultNode.nodeType
            && node.parentResultNodePath == owner.resultNode.nodePath
            && node.parentResultNodeName == owner.resultNode.nodeName
            && node.parentResultRevision?.caseInsensitiveCompare(owner.selectedResultRevision) == .orderedSame
            && samePath(node.parentResultAssetID ?? "", owner.selectedResultPath)
    }

    private static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy(\.isHexDigit)
    }

    private static func samePath(_ left: String, _ right: String) -> Bool {
        guard !left.isEmpty, !right.isEmpty else { return false }
        return SourceFilePaths.canonical(URL(fileURLWithPath: left))
            == SourceFilePaths.canonical(URL(fileURLWithPath: right))
    }
}
