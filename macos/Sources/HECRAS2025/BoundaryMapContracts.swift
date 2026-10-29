import Foundation
import RASWorkspaceCore

/// A Boundary Condition source row captured from one exact saved-map tree.
/// The boundary file path is checked against the persisted locator; neither
/// a display name nor a same-named model is a valid substitute.
struct BoundaryMapCapture: Hashable, Sendable {
    let projectSessionID: UUID
    let mapWorkflowIdentity: String
    let map: MapTreeMapIdentity
    let boundaryNode: CatalogTreeNodeLocator
    let sourcePath: String
    let sourceRevision: String
    let boundarySourceState: String?
    let resultOwner: MapResultOwnerSelection?
    let isChecked: Bool
    let effectiveVisible: Bool

    init(projectSessionID: UUID, mapWorkflowIdentity: String, map: MapTreeMapIdentity,
         boundaryNode: CatalogTreeNodeLocator, sourcePath: String, sourceRevision: String,
         boundarySourceState: String? = nil, resultOwner: MapResultOwnerSelection? = nil,
         isChecked: Bool, effectiveVisible: Bool) throws {
        let sourcePath = SourceFilePaths.canonical(URL(fileURLWithPath: sourcePath))
        // A Result child can also carry the base Result/MultiResult asset as
        // its ordinary AssetID. Its selected slot-zero HDF is identified by
        // ParentResultAssetID instead, so do not mistake the parent's file for
        // the active child source.
        let locatorSourcePath = resultOwner == nil
            ? (boundaryNode.associationAssetID ?? boundaryNode.assetID)
            : boundaryNode.parentResultAssetID
        let locatorPathMatches: Bool
        if let locatorSourcePath {
            locatorPathMatches = locatorSourcePath.hasPrefix("/")
                && SourceFilePaths.canonical(URL(fileURLWithPath: locatorSourcePath)) == sourcePath
        } else {
            locatorPathMatches = resultOwner != nil
        }
        guard UUID(uuidString: map.mapID) != nil,
              !mapWorkflowIdentity.isEmpty,
              boundaryNode.nodeType == "BoundaryCondition",
              !boundaryNode.nodeName.isEmpty,
              let nodePath = boundaryNode.nodePath, !nodePath.isEmpty,
              !sourcePath.isEmpty,
              Self.isSHA256(sourceRevision),
              !effectiveVisible || isChecked,
              locatorPathMatches,
              Self.validOwner(boundaryNode, mapType: map.mapType, resultOwner: resultOwner,
                              sourcePath: sourcePath, sourceRevision: sourceRevision) else {
            throw BoundaryMapError.incompleteIdentity
        }
        self.projectSessionID = projectSessionID
        self.mapWorkflowIdentity = mapWorkflowIdentity
        self.map = map
        self.boundaryNode = boundaryNode
        self.sourcePath = sourcePath
        self.sourceRevision = sourceRevision.uppercased()
        self.boundarySourceState = boundarySourceState
        self.resultOwner = resultOwner
        self.isChecked = isChecked
        self.effectiveVisible = effectiveVisible
    }

    /// The boundary editor state contains the stable line identities. Reuse
    /// it only for the same physical file and exact input bytes.
    var sourceIdentity: String {
        [sourcePath, sourceRevision, boundaryNode.sourceIdentity,
         resultOwner?.identity ?? "direct"].map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
    }

    /// Exact context identity for response/token validation. It includes the
    /// saved-map identity and locator as well as visibility and revisions.
    var identity: String {
        let planPath = (boundaryNode.parentPlanNodePath ?? []).map(String.init).joined(separator: ".")
        return [projectSessionID.uuidString, mapWorkflowIdentity, map.mapID,
            String(map.mapIndex), map.mapName, map.mapType, map.projectPath,
            map.projectXmlSHA, map.expectedVisualizationRevision,
            boundaryNode.rootName, boundaryNode.nodeType, boundaryNode.nodeName,
            (boundaryNode.nodePath ?? []).map(String.init).joined(separator: "."),
            boundaryNode.assetID ?? "", boundaryNode.associationKind ?? "",
            boundaryNode.associationAssetID ?? "", boundaryNode.parentPlanAssetID ?? "",
            planPath, boundaryNode.parentPlanNodeName ?? "", sourceIdentity,
            isChecked ? "checked" : "unchecked", effectiveVisible ? "visible" : "hidden"]
            .map { "\($0.utf8.count):\($0)" }.joined()
    }

    private static func validOwner(_ node: CatalogTreeNodeLocator, mapType: String,
                                   resultOwner: MapResultOwnerSelection?, sourcePath: String,
                                   sourceRevision: String) -> Bool {
        guard let path = node.nodePath, !path.isEmpty, !node.rootName.isEmpty else { return false }
        if let resultOwner {
            guard resultOwner.isValid,
                  resultOwner.selectedResultPath == sourcePath,
                  resultOwner.selectedResultRevision.caseInsensitiveCompare(sourceRevision) == .orderedSame,
                  let resultPath = resultOwner.resultNode.nodePath,
                  path.count == resultPath.count + 1,
                  Array(path.prefix(resultPath.count)) == resultPath,
                  resultOwner.resultNode.rootName == node.rootName,
                  node.parentResultNodeType == resultOwner.resultNode.nodeType,
                  node.parentResultNodePath == resultPath,
                  node.parentResultNodeName == resultOwner.resultNode.nodeName,
                  node.parentResultRevision?.caseInsensitiveCompare(sourceRevision) == .orderedSame,
                  let parentResultAssetID = node.parentResultAssetID,
                  canonicalPath(parentResultAssetID) == sourcePath
            else { return false }
            return mapType == "Plan" || mapType == "Buildable"
                || mapType == "Project" || mapType == "Geometry"
        }
        // Partial result-owner locators must never fall back to a direct
        // project/Plan source row. The Host requires the exact selected
        // Result owner for every serialized embedded child.
        guard node.parentResultNodeType == nil, node.parentResultAssetID == nil,
              node.parentResultNodePath == nil, node.parentResultNodeName == nil,
              node.parentResultRevision == nil else { return false }
        switch (mapType, node.rootName) {
        case ("Project", "Boundary Conditions"):
            return node.associationKind == nil && node.parentPlanAssetID == nil
                && node.parentPlanNodePath == nil && node.parentPlanNodeName == nil
        case ("Plan", "Matching Layers"):
            // This row is shared by all focused Plans with the same
            // object-identity BoundaryCondition association. It is not a
            // child of one particular Plan, so the source locator correctly
            // has no ParentPlan* owner fields.
            guard node.associationKind == "BoundaryCondition",
                  node.associationAssetID?.hasPrefix("/") == true,
                  node.parentPlanAssetID == nil,
                  node.parentPlanNodePath == nil,
                  node.parentPlanNodeName == nil,
                  path.count >= 2, path.first == 1 else { return false }
            return true
        case ("Plan", "Focused Plans"):
            // Retained Plan children expose their BoundaryCondition through
            // both the model AssetID and the typed association locator. Keep
            // the older direct locator valid, but never accept a partial or
            // different-file association as that Plan's Boundary source.
            let associationMatches: Bool
            if node.associationKind == nil {
                associationMatches = node.associationAssetID == nil
            } else if node.associationKind == "BoundaryCondition",
                      let associationAsset = node.associationAssetID,
                      associationAsset.hasPrefix("/"),
                      let asset = node.assetID, asset.hasPrefix("/") {
                associationMatches = canonicalPath(associationAsset) == sourcePath
                    && canonicalPath(asset) == sourcePath
            } else {
                associationMatches = false
            }
            guard let ownerPath = node.parentPlanNodePath,
                  ownerPath.count == 2, ownerPath.first == 0,
                  node.parentPlanAssetID?.hasPrefix("/") == true,
                  node.parentPlanNodeName?.isEmpty == false,
                  associationMatches,
                  path.count == ownerPath.count + 1,
                  Array(path.prefix(ownerPath.count)) == ownerPath else { return false }
            return true
        case ("Buildable", "Layers"), ("Geometry", "Layers"):
            // Retained BuildableRasProjectTreeBase places project-owned
            // BoundaryCondition rows in Layers. Geometry maps inherit that
            // layer root. These rows are exact source-tree entries, not
            // focused Geometry children or Plan associations.
            return path.count >= 2 && node.parentPlanAssetID == nil
                && node.parentPlanNodePath == nil && node.parentPlanNodeName == nil
                && node.associationKind == nil && node.associationAssetID == nil
        default:
            return false
        }
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy(\.isHexDigit)
    }

    private static func canonicalPath(_ path: String) -> String {
        SourceFilePaths.canonical(URL(fileURLWithPath: path))
    }
}

/// The selected Result HDF that owns an embedded BoundaryCondition row. The
/// chart context and exact slot-zero source choice travel together so the
/// backend never resolves the embedded file by a display name.
struct MapResultOwnerSelection: Codable, Hashable, Sendable {
    let resultNode: CatalogTreeNodeLocator
    let contextToken: String
    let selectionOverrides: [MapResultSelectionOverride]
    let selectionIndex: Int
    let selectedResultPath: String
    let selectedResultRevision: String

    init(resultNode: CatalogTreeNodeLocator, contextToken: String,
         selectionOverrides: [MapResultSelectionOverride], selectionIndex: Int = 0,
         selectedResultPath: String, selectedResultRevision: String) throws {
        let path = SourceFilePaths.canonical(URL(fileURLWithPath: selectedResultPath))
        guard Self.validNode(resultNode), selectionIndex == 0, !contextToken.isEmpty,
              path.hasPrefix("/"), Self.isSHA256(selectedResultRevision),
              Self.validOverrides(selectionOverrides, resultNode: resultNode,
                                  selectedPath: path, selectedRevision: selectedResultRevision) else {
            throw BoundaryMapError.incompleteIdentity
        }
        self.resultNode = resultNode
        self.contextToken = contextToken
        self.selectionOverrides = selectionOverrides
        self.selectionIndex = selectionIndex
        self.selectedResultPath = path
        self.selectedResultRevision = selectedResultRevision.uppercased()
    }

    var identity: String {
        let overrides = selectionOverrides.map { item in
            [item.node.sourceIdentity, String(item.selectionIndex), item.mode.rawValue,
             item.resultPath ?? "", item.resultRevision ?? ""].joined(separator: "|")
        }.joined(separator: "\u{1e}")
        return [resultNode.sourceIdentity, contextToken, String(selectionIndex),
                selectedResultPath, selectedResultRevision, overrides]
            .map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
    }

    var receipt: BoundaryMapResultOwnerReceipt {
        BoundaryMapResultOwnerReceipt(resultNode: resultNode, contextToken: contextToken,
            selectionOverrides: selectionOverrides, selectionIndex: selectionIndex,
            selectedResultPath: selectedResultPath, selectedResultRevision: selectedResultRevision)
    }

    var isValid: Bool {
        Self.validNode(resultNode) && selectionIndex == 0 && !contextToken.isEmpty
            && selectedResultPath.hasPrefix("/") && Self.isSHA256(selectedResultRevision)
            && Self.validOverrides(selectionOverrides, resultNode: resultNode,
                                   selectedPath: selectedResultPath, selectedRevision: selectedResultRevision)
    }

    private static func validNode(_ node: CatalogTreeNodeLocator) -> Bool {
        (node.nodeType == "Result" || node.nodeType == "MultiResult")
            && !node.rootName.isEmpty && !node.nodeName.isEmpty
            && (node.nodePath?.isEmpty == false)
    }

    private static func validOverrides(_ overrides: [MapResultSelectionOverride],
                                       resultNode: CatalogTreeNodeLocator,
                                       selectedPath: String, selectedRevision: String) -> Bool {
        let matching = overrides.filter {
            $0.node == resultNode && $0.selectionIndex == 0
        }
        guard matching.count <= 1 else { return false }
        guard let override = matching.first else { return true }
        switch override.mode {
        case .explicit:
            guard let path = override.resultPath, let revision = override.resultRevision else { return false }
            return SourceFilePaths.canonical(URL(fileURLWithPath: path)) == selectedPath
                && revision.caseInsensitiveCompare(selectedRevision) == .orderedSame
        case .latest, .previous:
            return override.resultPath == nil && override.resultRevision == nil
        }
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy(\.isHexDigit)
    }
}

struct BoundaryMapResultOwnerReceipt: Decodable, Hashable, Sendable {
    let resultNode: CatalogTreeNodeLocator
    let contextToken: String
    let selectionOverrides: [MapResultSelectionOverride]?
    let selectionIndex: Int
    let selectedResultPath: String
    let selectedResultRevision: String

    func matches(_ owner: MapResultOwnerSelection) -> Bool {
        resultNode == owner.resultNode
            && contextToken == owner.contextToken
            && (selectionOverrides == owner.selectionOverrides
                || (selectionOverrides == nil && owner.selectionOverrides.isEmpty))
            && selectionIndex == owner.selectionIndex
            && SourceFilePaths.canonical(URL(fileURLWithPath: selectedResultPath)) == owner.selectedResultPath
            && selectedResultRevision.caseInsensitiveCompare(owner.selectedResultRevision) == .orderedSame
    }
}

struct BoundaryMapRequest: Encodable, Sendable {
    let map: MapTreeMapIdentity
    let boundaryNode: CatalogTreeNodeLocator
    let expectedBoundaryRevision: String
    let boundarySourceState: String?
    let expectedContextToken: String?
    let resultOwner: MapResultOwnerSelection?
    let attachedFacesViewport: RasterMapViewExtent?
    let renderScale: Double

    init(map: MapTreeMapIdentity, boundaryNode: CatalogTreeNodeLocator,
         expectedBoundaryRevision: String, boundarySourceState: String?,
         expectedContextToken: String?, resultOwner: MapResultOwnerSelection?,
         attachedFacesViewport: RasterMapViewExtent? = nil, renderScale: Double = 1.0) {
        self.map = map
        self.boundaryNode = boundaryNode
        self.expectedBoundaryRevision = expectedBoundaryRevision
        self.boundarySourceState = boundarySourceState
        self.expectedContextToken = expectedContextToken
        self.resultOwner = resultOwner
        self.attachedFacesViewport = attachedFacesViewport
        self.renderScale = renderScale
    }
}

struct BoundaryMapCoordinateData: Decodable, Sendable {
    let x: Double
    let y: Double
}

struct BoundaryMapLine: Identifiable, Sendable {
    /// Opaque editor identity scoped to the exact boundary file revision and
    /// source state. It is never synthesized from a row ordinal.
    let id: String
    let sourceOrdinal: Int
    let name: String
    /// Invalid/missing geometry yields an empty path; it is never repaired by
    /// adding coordinates or joining separate source lines.
    let coordinates: [MapPoint]
}

struct BoundaryMapLinePresentation: Identifiable, Sendable {
    let sourceIdentity: String
    let line: BoundaryMapLine
    var id: String { "\(sourceIdentity)|\(line.id)" }
}

enum BoundaryMapSourceStatus: String, Sendable {
    case loading
    case available
    case hidden
    case empty
    case failed
}

struct BoundaryMapSourceState: Sendable {
    let capture: BoundaryMapCapture
    let contextToken: String?
    let boundarySourceState: String?
    let lines: [BoundaryMapLine]
    let status: BoundaryMapSourceStatus
    let diagnostic: String?
    let attachedFaces: MapSourceRasterFrame?

    init(capture: BoundaryMapCapture, contextToken: String?, boundarySourceState: String?,
         lines: [BoundaryMapLine], status: BoundaryMapSourceStatus, diagnostic: String?,
         attachedFaces: MapSourceRasterFrame? = nil) {
        self.capture = capture
        self.contextToken = contextToken
        self.boundarySourceState = boundarySourceState
        self.lines = lines
        self.status = status
        self.diagnostic = diagnostic
        self.attachedFaces = attachedFaces
    }

    var visibleLines: [BoundaryMapLine] {
        guard capture.effectiveVisible, status == .available else { return [] }
        return lines.filter { $0.coordinates.count >= 2 }
    }

    var visiblePoints: [MapPoint] { visibleLines.flatMap(\.coordinates) }
}

struct BoundaryMapSnapshot: Decodable, Sendable {
    let projectCanonicalPath: String
    let projectRevision: String
    let projectXmlSHA: String
    let visualizationRevision: String
    let mapID: String
    let mapIndex: Int
    let mapName: String
    let mapType: String
    let contextToken: String
    let boundaryNode: CatalogTreeNodeLocator
    let boundaryPath: String
    let boundaryRevision: String
    let boundarySourceState: String
    let boundaryChecked: Bool
    let boundaryEffectiveVisible: Bool
    let lines: [BoundaryMapLineData]
    var resultOwner: BoundaryMapResultOwnerReceipt? = nil
    var status: String? = nil
    var diagnostic: String? = nil
    var attachedFaces: MapSourceRasterFrame? = nil
}

struct BoundaryMapLineData: Decodable, Sendable {
    let id: String
    let sourceOrdinal: Int
    let name: String
    let coordinates: [BoundaryMapCoordinateData]?
}

enum BoundaryMapError: Error, LocalizedError {
    case unavailable
    case incompleteIdentity
    case mismatchedReply
    case staleContext
    case sourceChanged
    case invalidGeometry

    var errorDescription: String? {
        switch self {
        case .unavailable: "The Boundary map service is unavailable."
        case .incompleteIdentity: "The Boundary Condition map source identity is incomplete."
        case .mismatchedReply: "The Boundary Condition map returned a mismatched source identity."
        case .staleContext: "The saved map changed before Boundary Condition lines could be loaded."
        case .sourceChanged: "The Boundary Condition source changed while it was being read."
        case .invalidGeometry: "The Boundary Condition map returned invalid line geometry."
        }
    }
}
