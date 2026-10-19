import Foundation
import RASWorkspaceCore

/// Codable request and response for the read-only `map.geometry.load` route.
/// Pagination is independent for topology, FlowArea cells, and culvert barrels.
struct MapGeometryViewport: Codable, Hashable, Sendable {
    let minX: Double
    let minY: Double
    let maxX: Double
    let maxY: Double

    init(minX: Double, minY: Double, maxX: Double, maxY: Double) {
        self.minX = minX
        self.minY = minY
        self.maxX = maxX
        self.maxY = maxY
    }

    init?(extent: ViewportRequest) {
        guard extent.isFiniteAndOrdered else { return nil }
        minX = extent.lowerLeft.x
        minY = extent.lowerLeft.y
        maxX = extent.upperRight.x
        maxY = extent.upperRight.y
    }

    var identity: String {
        [minX, minY, maxX, maxY].map { String($0.bitPattern, radix: 16) }.joined(separator: ":")
    }
}

struct MapGeometryRequest: Encodable, Sendable {
    let map: MapTreeMapIdentity
    let geometryNode: CatalogTreeNodeLocator
    /// Exact checked/focused Plan owners are required for shared Geometry
    /// rows under a Plan map's Matching Layers root.
    let planNodes: [CatalogTreeNodeLocator]
    let viewport: MapGeometryViewport?
    let pageSize: Int
    let contextToken: String?
    let topologyCursor: String?
    let cellCursor: String?
    let culvertCursor: String?
    let skipTopologyPage: Bool
    let skipFlowAreasPage: Bool
    let skipCulvertsPage: Bool

    init(map: MapTreeMapIdentity, geometryNode: CatalogTreeNodeLocator,
         viewport: MapGeometryViewport?, contextToken: String?,
         planNodes: [CatalogTreeNodeLocator] = [],
         topologyCursor: String? = nil, cellCursor: String? = nil, culvertCursor: String? = nil,
         skipTopologyPage: Bool = false, skipFlowAreasPage: Bool = false,
         skipCulvertsPage: Bool = false, pageSize: Int = 512) {
        self.map = map
        self.geometryNode = geometryNode
        self.planNodes = planNodes
        self.viewport = viewport
        self.contextToken = contextToken
        self.topologyCursor = topologyCursor
        self.cellCursor = cellCursor
        self.culvertCursor = culvertCursor
        self.skipTopologyPage = skipTopologyPage
        self.skipFlowAreasPage = skipFlowAreasPage
        self.skipCulvertsPage = skipCulvertsPage
        self.pageSize = min(max(pageSize, 1), 512)
    }
}

/// Wire shape for `map.result.geometry.load`. The nested child paging token is
/// returned in `MapGeometrySnapshot`; the service binds cursors to this exact
/// Result owner, selected output, and Geometry locator.
struct MapResultGeometryRequest: Encodable, Sendable {
    let map: MapTreeMapIdentity
    let resultOwner: MapResultGeometryOwner
    let geometryNode: CatalogTreeNodeLocator
    /// The child paging token returned by `MapGeometrySnapshot`. It is
    /// distinct from `resultOwner.contextToken`, which identifies the current
    /// Result selection context.
    let geometryContextToken: String?
    let viewport: MapGeometryViewport?
    let pageSize: Int
    let topologyCursor: String?
    let cellCursor: String?
    let culvertCursor: String?
    let skipTopologyPage: Bool
    let skipFlowAreasPage: Bool
    let skipCulvertsPage: Bool

    init(map: MapTreeMapIdentity, resultOwner: MapResultGeometryOwner,
         geometryNode: CatalogTreeNodeLocator, request: MapGeometryRequest) {
        self.map = map
        self.resultOwner = resultOwner
        self.geometryNode = geometryNode
        geometryContextToken = request.contextToken
        viewport = request.viewport
        pageSize = request.pageSize
        topologyCursor = request.topologyCursor
        cellCursor = request.cellCursor
        culvertCursor = request.culvertCursor
        skipTopologyPage = request.skipTopologyPage
        skipFlowAreasPage = request.skipFlowAreasPage
        skipCulvertsPage = request.skipCulvertsPage
    }
}

/// The immutable Result-side owner used by the saved Result geometry route.
/// The chart context token and selected output identity are separate from the
/// nested geometry paging token carried by `MapGeometrySnapshot`.
struct MapResultGeometryOwner: Codable, Hashable, Sendable {
    let resultNode: CatalogTreeNodeLocator
    let contextToken: String
    let selectionOverrides: [MapResultSelectionOverride]?
    let selectionIndex: Int
    let selectedResultPath: String
    let selectedResultRevision: String

    init(resultNode: CatalogTreeNodeLocator, contextToken: String,
         selectionOverrides: [MapResultSelectionOverride]?, selectionIndex: Int,
         selectedResultPath: String, selectedResultRevision: String) throws {
        guard (resultNode.nodeType == "Result" || resultNode.nodeType == "MultiResult"),
              !resultNode.nodeName.isEmpty,
              resultNode.nodePath?.isEmpty == false,
              !contextToken.isEmpty,
              selectionIndex == 0,
              selectedResultPath.hasPrefix("/"),
              Self.isSHA256(selectedResultRevision),
              Self.overrideMatches(selectionOverrides, resultNode: resultNode,
                                   selectedPath: selectedResultPath,
                                   selectedRevision: selectedResultRevision) else {
            throw ProjectGeometryMapCaptureError.incompleteResultOwner
        }
        self.resultNode = resultNode
        self.contextToken = contextToken
        self.selectionOverrides = selectionOverrides
        self.selectionIndex = selectionIndex
        self.selectedResultPath = SourceFilePaths.canonical(URL(fileURLWithPath: selectedResultPath))
        self.selectedResultRevision = selectedResultRevision.uppercased()
    }

    var identity: String {
        let overrides = (selectionOverrides ?? []).map { override in
            [override.nodeIdentity, String(override.selectionIndex), override.mode.rawValue,
             override.resultPath.map { SourceFilePaths.canonical(URL(fileURLWithPath: $0)) } ?? "",
             override.resultRevision?.uppercased() ?? ""].joined(separator: "|")
        }.joined(separator: "||")
        return [resultNode.sourceIdentity, contextToken, String(selectionIndex), selectedResultPath,
                selectedResultRevision, overrides].map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
    }

    private static func overrideMatches(_ overrides: [MapResultSelectionOverride]?,
                                        resultNode: CatalogTreeNodeLocator,
                                        selectedPath: String,
                                        selectedRevision: String) -> Bool {
        guard let overrides else { return true }
        let exact = overrides.filter { $0.node == resultNode && $0.selectionIndex == 0 }
        guard exact.count <= 1 else { return false }
        guard let override = exact.first else { return true }
        switch override.mode {
        case .explicit:
            guard let path = override.resultPath, let revision = override.resultRevision else { return false }
            return SourceFilePaths.canonical(URL(fileURLWithPath: path))
                    == SourceFilePaths.canonical(URL(fileURLWithPath: selectedPath))
                && revision.caseInsensitiveCompare(selectedRevision) == .orderedSame
        case .latest, .previous:
            // The selected path and revision come from the actual source
            // snapshot. Non-explicit selection overrides carry no path; the
            // backend resolves them under the exact chart context token.
            return override.resultPath == nil && override.resultRevision == nil
        }
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy(\.isHexDigit)
    }
}

/// Exact envelope for the `map.result.geometry.load` route. Only its nested
/// geometry snapshot is fed into the shared geometry paging state machine.
struct MapResultGeometrySnapshot: Decodable, Sendable {
    let projectCanonicalPath: String
    let projectRevision: String
    let projectXmlSHA: String
    let visualizationRevision: String
    let mapID: String
    let mapIndex: Int
    let mapName: String
    let mapType: String
    let contextToken: String
    let resultNode: CatalogTreeNodeLocator
    let selectionIndex: Int
    let selectedResultPath: String
    let selectedResultRevision: String
    let geometryNode: CatalogTreeNodeLocator
    let geometryPath: String
    let geometryRevision: String
    let geometry: MapGeometrySnapshot
}

enum MapGeometrySourceStatus: String, Decodable, Sendable {
    case available
    case empty
    case unavailable
    case failed
    case partial

    var hasSourceData: Bool { self == .available || self == .partial }
}

struct MapGeometryLayerState: Decodable, Sendable {
    /// Optional source child nodes stay absent in the source tree. They are
    /// never represented by a fabricated ID or locator.
    let nodeID: String?
    let locator: CatalogTreeNodeLocator?
    let isChecked: Bool
    let effectiveVisible: Bool
    let status: MapGeometrySourceStatus
    let diagnostic: String?

    var hasNodeIdentity: Bool { nodeID?.isEmpty == false && locator != nil }
}

struct MapGeometryTopologyPage: Decodable, Sendable {
    let sourceExtent: GeometryTopologyExtent?
    let sourceFeatureCount: Int
    let scannedFeatureCount: Int
    let returnedFeatureCount: Int
    let invalidFeatureCount: Int
    let omittedSourceFeatureCount: Int
    let features: [GeometryTopologyMapFeature]
    let complete: Bool
    let nextCursor: String?
}

struct MapGeometryFlowAreaSource: Decodable, Identifiable, Sendable {
    let id: String
    let rowIndex: Int
    let name: String
    let targetedCellSpacing: Double?
    let hasMesh: Bool
    let cellCount: Int
    let faceCount: Int
    let nodeCount: Int
    let extent: GeometryMeshExtent?
    let hasMeshErrors: Bool
    let hasPropertyTables: Bool
    let propertyTablesPinned: Bool
    let metadata: [GeometryMeshMetadataItem]
}

struct MapGeometryFlowAreasPage: Decodable, Sendable {
    let sourceExtent: GeometryTopologyExtent?
    let areas: [MapGeometryFlowAreaSource]
    let sourceCellCount: Int
    let scannedSourceCellCount: Int
    let returnedCellCount: Int
    let invalidCellCount: Int
    let cells: [GeometryMeshMapCell]
    let complete: Bool
    let nextCursor: String?
}

struct MapGeometryCulvertsPage: Decodable, Sendable {
    let sourceExtent: GeometryTopologyExtent?
    let sourceBarrelCount: Int
    let scannedSourceBarrelCount: Int
    let returnedBarrelCount: Int
    let invalidFeatureCount: Int
    let features: [GeometryCulvertFeatureRow]
    let complete: Bool
    let nextCursor: String?
}

struct MapGeometrySnapshot: Decodable, Sendable {
    let mapID: String
    let mapIndex: Int
    let mapName: String
    let mapType: String
    let projectCanonicalPath: String
    let projectRevision: String
    let projectXmlSHA: String?
    let visualizationRevision: String
    let contextToken: String
    let geometryNode: CatalogTreeNodeLocator
    let geometryName: String
    let geometryCanonicalPath: String
    let geometryRevision: String
    let geometryChecked: Bool
    let geometryEffectiveVisible: Bool
    let extent: GeometryTopologyExtent?
    /// Echoed only when a Plan map's shared Matching Layers Geometry is
    /// resolved against the exact focused Plan owners. Older/non-Plan routes
    /// decode this as nil and are treated as an empty owner list.
    let planNodes: [CatalogTreeNodeLocator]?

    // State is always returned. A skipped page is nil and must not reset an
    // already loaded page or be misread as an empty source.
    let topologyState: MapGeometryLayerState
    let flowAreasState: MapGeometryLayerState
    let culvertsState: MapGeometryLayerState
    let topology: MapGeometryTopologyPage?
    let flowAreas: MapGeometryFlowAreasPage?
    let culverts: MapGeometryCulvertsPage?
}

struct ProjectGeometryMapCapture: Hashable, Sendable {
    let projectSessionID: UUID
    let mapID: UUID
    let mapWorkflowIdentity: String
    let map: MapTreeMapIdentity
    let geometryNode: CatalogTreeNodeLocator
    let geometryCanonicalPath: String
    let geometryName: String
    let resultOwner: MapResultGeometryOwner?
    let planNodes: [CatalogTreeNodeLocator]

    init(projectSessionID: UUID, mapID: UUID, mapWorkflowIdentity: String,
         map: MapTreeMapIdentity, geometryNode: CatalogTreeNodeLocator,
         geometryAssetPath: String, geometryName: String,
         resultOwner: MapResultGeometryOwner? = nil,
         planNodes: [CatalogTreeNodeLocator] = []) throws {
        guard map.mapID == mapID.uuidString,
              Self.hasSupportedOwner(map: map, geometryNode: geometryNode,
                                     resultOwner: resultOwner, planNodes: planNodes),
              geometryNode.nodeType == "Geometry",
              let nodePath = geometryNode.nodePath, !nodePath.isEmpty,
              !geometryAssetPath.isEmpty, !geometryName.isEmpty else {
            throw ProjectGeometryMapCaptureError.incompleteIdentity
        }
        self.projectSessionID = projectSessionID
        self.mapID = mapID
        self.mapWorkflowIdentity = mapWorkflowIdentity
        self.map = map
        self.geometryNode = geometryNode
        geometryCanonicalPath = SourceFilePaths.canonical(URL(fileURLWithPath: geometryAssetPath))
        self.geometryName = geometryName
        self.resultOwner = resultOwner
        self.planNodes = planNodes
        if let resultOwner {
            guard geometryCanonicalPath == resultOwner.selectedResultPath,
                  geometryNode.parentResultAssetID.map({
                      SourceFilePaths.canonical(URL(fileURLWithPath: $0))
                  }) == resultOwner.selectedResultPath,
                  geometryNode.parentResultRevision?.caseInsensitiveCompare(resultOwner.selectedResultRevision)
                    == .orderedSame,
                  geometryNode.parentResultNodeType == resultOwner.resultNode.nodeType,
                  geometryNode.parentResultNodePath == resultOwner.resultNode.nodePath,
                  geometryNode.parentResultNodeName == resultOwner.resultNode.nodeName else {
                throw ProjectGeometryMapCaptureError.incompleteResultOwner
            }
        }
    }

    var identity: String {
        let locatorPath = (geometryNode.nodePath ?? []).map(String.init).joined(separator: ".")
        return [projectSessionID.uuidString, mapWorkflowIdentity, mapID.uuidString,
            map.mapIndex.description, map.mapName, map.mapType, map.projectPath, map.projectXmlSHA,
            map.expectedVisualizationRevision, geometryNode.rootName, geometryNode.nodeType,
            geometryNode.nodeName, locatorPath, geometryNode.parentPlanAssetID ?? "",
            (geometryNode.parentPlanNodePath ?? []).map(String.init).joined(separator: "."),
            geometryNode.parentPlanNodeName ?? "", geometryNode.parentResultNodeType ?? "",
            geometryNode.parentResultAssetID ?? "",
            (geometryNode.parentResultNodePath ?? []).map(String.init).joined(separator: "."),
            geometryNode.parentResultNodeName ?? "", geometryNode.parentResultRevision ?? "",
            resultOwner?.identity ?? "",
            planNodes.map(AssociatedMapLayerCapture.locatorIdentity).joined(separator: "\n"),
            geometryCanonicalPath].joined(separator: "|")
    }

    private static func hasSupportedOwner(map: MapTreeMapIdentity,
                                          geometryNode: CatalogTreeNodeLocator,
                                          resultOwner: MapResultGeometryOwner?,
                                          planNodes: [CatalogTreeNodeLocator]) -> Bool {
        guard Set(planNodes).count == planNodes.count,
              planNodes.allSatisfy({ $0.isFocusedPlanOwner && !$0.nodeName.isEmpty
                  && $0.assetID?.hasPrefix("/") == true
                  && ($0.nodePath.map { !$0.isEmpty } ?? true) }) else { return false }
        if let resultOwner {
            guard ["Project", "Buildable", "Plan", "Geometry"].contains(map.mapType),
                  planNodes.isEmpty,
                  geometryNode.assetID.map(canonicalPath) == resultOwner.selectedResultPath,
                  geometryNode.rootName == resultOwner.resultNode.rootName,
                  geometryNode.parentResultNodeType == resultOwner.resultNode.nodeType,
                  geometryNode.parentResultNodePath == resultOwner.resultNode.nodePath,
                  geometryNode.parentResultNodeName == resultOwner.resultNode.nodeName,
                  let resultPath = geometryNode.parentResultAssetID,
                  SourceFilePaths.canonical(URL(fileURLWithPath: resultPath)) == resultOwner.selectedResultPath,
                  geometryNode.parentResultRevision?.caseInsensitiveCompare(resultOwner.selectedResultRevision)
                    == .orderedSame,
                  let path = geometryNode.nodePath, !path.isEmpty,
                  let parentPath = resultOwner.resultNode.nodePath, !parentPath.isEmpty,
                  path.count == parentPath.count + 1,
                  Array(path.prefix(parentPath.count)) == parentPath else { return false }
            // Result owners keep the exact serialized child path as well as
            // the selected output HDF identity; neither node names nor map
            // type can substitute for that owner chain.
            return true
        }
        switch map.mapType {
        case "Project", "Buildable", "Geometry": return planNodes.isEmpty
        case "Plan":
            guard !planNodes.isEmpty else { return false }
            if geometryNode.rootName == "Matching Layers" {
                // Source places common Geometry rows here, including the
                // common rows only when at least two Plans are focused; no
                // singular ParentPlan is serialized.
                guard geometryNode.parentPlanAssetID == nil,
                      geometryNode.parentPlanNodePath == nil,
                      geometryNode.parentPlanNodeName == nil,
                      geometryNode.associationKind == "Geometry",
                      let associatedAsset = geometryNode.associationAssetID,
                      let geometryAsset = geometryNode.assetID,
                      canonicalPath(associatedAsset) == canonicalPath(geometryAsset),
                      planNodes.count >= 2 else { return false }
                return true
            }
            guard geometryNode.rootName == "Focused Plans",
                  let parentAsset = geometryNode.parentPlanAssetID,
                  let parentName = geometryNode.parentPlanNodeName,
                  planNodes.count == 1,
                  planNodes.contains(where: { plan in
                      plan.nodePath == geometryNode.parentPlanNodePath
                          && plan.nodeName == parentName
                          && plan.assetID.map(canonicalPath) == canonicalPath(parentAsset)
                          && (plan.nodePath == nil || isDescendant(geometryNode.nodePath, of: plan.nodePath))
                  }) else { return false }
            return true
        default: return false
        }
    }

    private static func isDescendant(_ child: [Int]?, of parent: [Int]?) -> Bool {
        guard let child, let parent, !parent.isEmpty, child.count > parent.count else { return false }
        return Array(child.prefix(parent.count)) == parent
    }

    private static func canonicalPath(_ path: String) -> String {
        SourceFilePaths.canonical(URL(fileURLWithPath: path))
    }
}

enum ProjectGeometryMapCaptureError: Error, LocalizedError {
    case incompleteIdentity
    case incompleteResultOwner

    var errorDescription: String? {
        switch self {
        case .incompleteIdentity:
            "The selected Geometry map source identity is incomplete."
        case .incompleteResultOwner:
            "The selected Result geometry owner identity is incomplete."
        }
    }
}
