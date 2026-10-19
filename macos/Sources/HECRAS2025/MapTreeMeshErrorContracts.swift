import Foundation
import RASWorkspaceCore

struct MapTreeMeshErrorMapRequest: Encodable, Sendable {
    let projectPath: String
    let projectXml: String
    let projectXmlSHA: String
    let mapID: String
    let mapIndex: Int
    let mapName: String
    let mapType: String
    let expectedVisualizationRevision: String
    let resultSelectionOverrides: [MapTreeResultSelectionOverride]
    let computeReadLease: MapResultComputeReadLease?

    init(map: MapTreeMapIdentity, resultOwner: MapResultGeometryOwner?,
         computeReadLease: MapResultComputeReadLease?) {
        projectPath = map.projectPath
        projectXml = map.projectXml
        projectXmlSHA = map.projectXmlSHA
        mapID = map.mapID
        mapIndex = map.mapIndex
        mapName = map.mapName
        mapType = map.mapType
        expectedVisualizationRevision = map.expectedVisualizationRevision
        if let resultOwner, resultOwner.resultNode.nodeType == "MultiResult",
           let planAsset = resultOwner.resultNode.assetID {
            resultSelectionOverrides = [MapTreeResultSelectionOverride(
                planAssetID: planAsset, planName: resultOwner.resultNode.nodeName,
                selectedResultPath: resultOwner.selectedResultPath,
                selectedResultRevision: resultOwner.selectedResultRevision)]
        } else {
            resultSelectionOverrides = []
        }
        self.computeReadLease = computeReadLease
    }
}

struct MapTreeMeshErrorRequest: Encodable, Sendable {
    let map: MapTreeMeshErrorMapRequest
    let flowAreaNode: CatalogTreeNodeLocator
    let projectSessionID: String
    let mapWorkflowIdentity: String
    let contextToken: String
    let sourcePath: String
    let sourceRevision: String
    let resultOwner: MapResultGeometryOwner?
    let action: String
    var readSettingsOnly: Bool = false
    var checkMeshErrors: Bool? = nil
    var maxFacesPerNodeEntry: Double? = nil
}

struct MapTreeMeshErrorCoordinate: Codable, Hashable, Sendable {
    let x: Double
    let y: Double
}

struct MapTreeMeshErrorCell: Codable, Identifiable, Sendable {
    let cellIndex: Int
    let coordinates: [MapTreeMeshErrorCoordinate]
    var id: Int { cellIndex }
}

struct MapTreeMeshErrorIssue: Codable, Identifiable, Sendable {
    let id: String
    let meshIndex: Int
    let nodeIndex: Int
    let faceCount: Int
    let node: MapTreeMeshErrorCoordinate
    let cellsMinX: Double?
    let cellsMinY: Double?
    let cellsMaxX: Double?
    let cellsMaxY: Double?
    let cells: [MapTreeMeshErrorCell]

    var extent: GeometryTopologyExtent? {
        guard let cellsMinX, let cellsMinY, let cellsMaxX, let cellsMaxY,
              cellsMinX.isFinite, cellsMinY.isFinite, cellsMaxX.isFinite, cellsMaxY.isFinite,
              cellsMinX <= cellsMaxX, cellsMinY <= cellsMaxY else { return nil }
        return GeometryTopologyExtent(minX: cellsMinX, minY: cellsMinY,
            maxX: cellsMaxX, maxY: cellsMaxY)
    }
}

struct MapTreeMeshErrorSnapshot: Decodable, Sendable {
    let projectSessionID: String
    let mapWorkflowIdentity: String
    let contextToken: String
    let projectCanonicalPath: String
    let projectRevision: String
    let projectXmlSHA: String
    let visualizationRevision: String
    let mapID: String
    let mapIndex: Int
    let mapName: String
    let mapType: String
    let flowAreaNode: CatalogTreeNodeLocator
    let sourcePath: String
    let sourceRevision: String
    let checkMeshErrors: Bool
    let maxFacesPerNode: Int
    let isChecked: Bool?
    let isEffectivelyVisible: Bool?
    var status: String
    var diagnostic: String?
    var issues: [MapTreeMeshErrorIssue]
    var totalIssueCount: Int
    var omittedIssueCount: Int
    let previousVisualizationRevision: String?
    var geometryMeshDraftIdentity: String? = nil
}

struct MapTreeMeshErrorContext: Hashable, Sendable {
    let projectSessionID: UUID
    let mapID: UUID
    let mapWorkflowIdentity: String
    let map: MapTreeMapIdentity
    let flowAreaNode: CatalogTreeNodeLocator
    let sourcePath: String
    let sourceRevision: String
    let resultOwner: MapResultGeometryOwner?
    let contextToken: String
    let geometryMeshDraftIdentity: String?

    var stableIdentity: String {
        [projectSessionID.uuidString, mapWorkflowIdentity, mapID.uuidString,
         SourceFilePaths.canonical(URL(fileURLWithPath: map.projectPath)),
         map.expectedVisualizationRevision, flowAreaNode.sourceIdentity,
         sourcePath, sourceRevision, resultOwner?.identity ?? "", contextToken,
         geometryMeshDraftIdentity ?? "saved-source"]
            .map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
    }

    private init(projectSessionID: UUID, mapID: UUID, mapWorkflowIdentity: String,
                 map: MapTreeMapIdentity, flowAreaNode: CatalogTreeNodeLocator,
                 sourcePath: String, sourceRevision: String,
                 resultOwner: MapResultGeometryOwner?, contextToken: String,
                 geometryMeshDraftIdentity: String? = nil) {
        self.projectSessionID = projectSessionID
        self.mapID = mapID
        self.mapWorkflowIdentity = mapWorkflowIdentity
        self.map = map
        self.flowAreaNode = flowAreaNode
        self.sourcePath = sourcePath
        self.sourceRevision = sourceRevision
        self.resultOwner = resultOwner
        self.contextToken = contextToken
        self.geometryMeshDraftIdentity = geometryMeshDraftIdentity
    }

    init(capture: ProjectGeometryMapCapture, flowAreaNode: CatalogTreeNodeLocator,
         sourceRevision: String, contextToken: String,
         geometryMeshDraftIdentity: String? = nil) throws {
        let sourcePath = capture.geometryCanonicalPath
        guard flowAreaNode.nodeType == "FlowAreaLayer",
              !contextToken.isEmpty, sourceRevision.count == 64,
              sourceRevision.allSatisfy(\.isHexDigit),
              flowAreaNode.parentGeometryAssetID.map(Self.canonical) == sourcePath,
              Self.sameParentIdentity(flowAreaNode, capture: capture) else {
            throw MapTreeMeshErrorError.incompleteContext
        }
        projectSessionID = capture.projectSessionID
        mapID = capture.mapID
        mapWorkflowIdentity = capture.mapWorkflowIdentity
        map = capture.map
        self.flowAreaNode = flowAreaNode
        self.sourcePath = sourcePath
        self.sourceRevision = sourceRevision.uppercased()
        resultOwner = capture.resultOwner
        self.contextToken = contextToken
        self.geometryMeshDraftIdentity = geometryMeshDraftIdentity
        if let owner = capture.resultOwner,
           sourcePath != owner.selectedResultPath ||
            self.sourceRevision.caseInsensitiveCompare(owner.selectedResultRevision) != .orderedSame {
            throw MapTreeMeshErrorError.incompleteContext
        }
    }

    func replacingMap(_ map: MapTreeMapIdentity) throws -> MapTreeMeshErrorContext {
        guard map.mapID.caseInsensitiveCompare(mapID.uuidString) == .orderedSame,
              map.mapIndex == self.map.mapIndex, map.mapName == self.map.mapName,
              map.mapType == self.map.mapType,
              Self.canonical(map.projectPath) == Self.canonical(self.map.projectPath),
              map.projectXmlSHA.caseInsensitiveCompare(self.map.projectXmlSHA) == .orderedSame,
              !map.expectedVisualizationRevision.isEmpty else {
            throw MapTreeMeshErrorError.staleContext
        }
        return MapTreeMeshErrorContext(projectSessionID: projectSessionID, mapID: mapID,
            mapWorkflowIdentity: mapWorkflowIdentity, map: map,
            flowAreaNode: flowAreaNode, sourcePath: sourcePath,
            sourceRevision: sourceRevision, resultOwner: resultOwner,
            contextToken: contextToken, geometryMeshDraftIdentity: geometryMeshDraftIdentity)
    }

    /// Accepts only the exact FlowArea locator returned by a successful .vis
    /// mutation. Materializing an implicit Geometry subtree may assign the two
    /// corresponding node paths; every source/owner field must remain exact.
    func acceptingMutationReceipt(flowAreaNode replacement: CatalogTreeNodeLocator,
                                  contextToken replacementContextToken: String)
        throws -> MapTreeMeshErrorContext {
        var normalized = replacement
        normalized.nodePath = flowAreaNode.nodePath
        normalized.parentGeometryNodePath = flowAreaNode.parentGeometryNodePath
        guard normalized == flowAreaNode,
              Self.isUnchangedOrMaterialized(flowAreaNode.nodePath, replacement.nodePath),
              Self.isUnchangedOrMaterialized(flowAreaNode.parentGeometryNodePath,
                  replacement.parentGeometryNodePath),
              !replacementContextToken.isEmpty,
              resultOwner != nil || replacementContextToken == contextToken,
              resultOwner == nil || Self.isSHA256(replacementContextToken) else {
            throw MapTreeMeshErrorError.mismatchedReply
        }
        let updatedResultOwner: MapResultGeometryOwner?
        if let resultOwner {
            do {
                updatedResultOwner = try MapResultGeometryOwner(
                    resultNode: resultOwner.resultNode,
                    contextToken: replacementContextToken,
                    selectionOverrides: resultOwner.selectionOverrides,
                    selectionIndex: resultOwner.selectionIndex,
                    selectedResultPath: resultOwner.selectedResultPath,
                    selectedResultRevision: resultOwner.selectedResultRevision)
            } catch {
                throw MapTreeMeshErrorError.mismatchedReply
            }
        } else {
            updatedResultOwner = nil
        }
        return MapTreeMeshErrorContext(projectSessionID: projectSessionID, mapID: mapID,
            mapWorkflowIdentity: mapWorkflowIdentity, map: map,
            flowAreaNode: replacement, sourcePath: sourcePath,
            sourceRevision: sourceRevision, resultOwner: updatedResultOwner,
            contextToken: replacementContextToken,
            geometryMeshDraftIdentity: geometryMeshDraftIdentity)
    }

    private static func sameParentIdentity(_ node: CatalogTreeNodeLocator,
                                           capture: ProjectGeometryMapCapture) -> Bool {
        guard node.rootName == capture.geometryNode.rootName,
              node.parentGeometryNodeName == capture.geometryNode.nodeName,
              node.parentGeometryNodePath == capture.geometryNode.nodePath,
              node.parentGeometryAssetID.map(canonical) == capture.geometryCanonicalPath else { return false }
        if let owner = capture.resultOwner {
            return node.parentResultNodeType == owner.resultNode.nodeType
                && node.parentResultNodeName == owner.resultNode.nodeName
                && node.parentResultNodePath == owner.resultNode.nodePath
                && node.parentResultAssetID.map(canonical) == owner.selectedResultPath
                && node.parentResultRevision?.caseInsensitiveCompare(owner.selectedResultRevision) == .orderedSame
        }
        return node.parentResultNodeType == nil && node.parentResultAssetID == nil
    }

    private static func canonical(_ path: String) -> String {
        SourceFilePaths.canonical(URL(fileURLWithPath: path))
    }

    private static func isUnchangedOrMaterialized(_ previous: [Int]?, _ current: [Int]?) -> Bool {
        previous == current || previous == nil && current.map { !$0.isEmpty } == true
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy(\.isHexDigit)
    }

    static func checkedVisibleContexts(in sources: [ProjectGeometryMapSourceState]) -> [MapTreeMeshErrorContext] {
        sources.compactMap { source in
            let draftIdentity: String?
            if let presentation = source.flowAreaGenerationPresentation {
                guard presentation.phase == .childDraft, presentation.map != nil,
                      !presentation.identity.isEmpty, source.presentsFlowAreaData else { return nil }
                draftIdentity = presentation.identity
            } else {
                draftIdentity = nil
            }
            guard let snapshot = source.snapshot,
                  snapshot.geometryChecked, snapshot.geometryEffectiveVisible,
                  let locator = snapshot.flowAreasState.locator,
                  let sourceRevision = source.geometryRevision,
                  let contextToken = source.contextToken else { return nil }
            if draftIdentity == nil {
                guard snapshot.flowAreasState.isChecked, snapshot.flowAreasState.effectiveVisible,
                      snapshot.flowAreasState.status.hasSourceData else { return nil }
            }
            return try? MapTreeMeshErrorContext(capture: source.capture,
                flowAreaNode: locator, sourceRevision: sourceRevision,
                contextToken: contextToken, geometryMeshDraftIdentity: draftIdentity)
        }
    }
}

enum MapTreeMeshErrorError: LocalizedError, Equatable {
    case incompleteContext
    case staleContext
    case mismatchedReply
    case mutationUnavailable
    case sourceChanged

    var errorDescription: String? {
        switch self {
        case .incompleteContext: "The selected FlowArea mesh context is incomplete."
        case .staleContext: "The FlowArea mesh context changed before the operation completed."
        case .mismatchedReply: "The mesh error service returned a different map or source."
        case .mutationUnavailable: "Mesh error settings cannot be changed while the project is busy."
        case .sourceChanged: "The FlowArea geometry changed before the mesh error scan completed."
        }
    }
}
