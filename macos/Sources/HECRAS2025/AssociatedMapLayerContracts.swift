import Foundation
import RASWorkspaceCore

/// Exact source-tree identity for one related Terrain, NValue, or
/// Classification row on a saved map. The asset path is resolved from the
/// locator by WorkspaceStore; display names are never used as identity.
struct AssociatedMapLayerCapture: Hashable, Sendable {
    let projectSessionID: UUID
    let mapID: UUID
    let mapWorkflowIdentity: String
    let map: MapTreeMapIdentity
    let geometryNodes: [CatalogTreeNodeLocator]
    let planNodes: [CatalogTreeNodeLocator]
    let resultOwners: [MapResultGeometryOwner]
    let associationNode: CatalogTreeNodeLocator
    let assetPath: String
    let isChecked: Bool
    let effectiveVisible: Bool

    init(projectSessionID: UUID, mapID: UUID, mapWorkflowIdentity: String,
         map: MapTreeMapIdentity, geometryNodes: [CatalogTreeNodeLocator] = [],
         planNodes: [CatalogTreeNodeLocator] = [],
         resultOwners: [MapResultGeometryOwner] = [],
         associationNode: CatalogTreeNodeLocator, assetPath: String,
         isChecked: Bool, effectiveVisible: Bool) throws {
        guard map.mapID == mapID.uuidString,
              ["Project", "Buildable", "Geometry", "Plan"].contains(map.mapType),
              !mapWorkflowIdentity.isEmpty,
              geometryNodes.allSatisfy(Self.isGeometryLocator),
              Set(geometryNodes).count == geometryNodes.count,
              planNodes.allSatisfy(Self.isPlanLocator),
              Set(planNodes).count == planNodes.count,
              Set(resultOwners.map(\.identity)).count == resultOwners.count,
              resultOwners.allSatisfy({ Self.isResultOwner($0, map: map) }),
              planNodes.isEmpty || map.mapType == "Plan",
              Self.supportedKind(associationNode.associationKind) != nil,
              associationNode.nodeType == associationNode.associationKind,
              let associationAssetID = associationNode.associationAssetID,
              !associationAssetID.isEmpty,
              Self.validPlanScope(associationNode, map: map, planNodes: planNodes),
              Self.parentsMatch(associationNode, geometryNodes: geometryNodes,
                                planNodes: planNodes, resultOwners: resultOwners),
              !geometryNodes.isEmpty || !planNodes.isEmpty || !resultOwners.isEmpty,
              !assetPath.isEmpty,
              SourceFilePaths.canonical(URL(fileURLWithPath: associationAssetID))
                == SourceFilePaths.canonical(URL(fileURLWithPath: assetPath)),
              !effectiveVisible || isChecked else {
            throw AssociatedMapLayerCaptureError.incompleteIdentity
        }
        self.projectSessionID = projectSessionID
        self.mapID = mapID
        self.mapWorkflowIdentity = mapWorkflowIdentity
        self.map = map
        self.geometryNodes = geometryNodes
        self.planNodes = planNodes
        self.resultOwners = resultOwners
        self.associationNode = associationNode
        self.assetPath = SourceFilePaths.canonical(URL(fileURLWithPath: assetPath))
        self.isChecked = isChecked
        self.effectiveVisible = effectiveVisible
    }

    var identity: String {
        let geometryIdentity = geometryNodes.map(Self.locatorIdentity).joined(separator: "\n")
        let planIdentity = planNodes.map(Self.locatorIdentity).joined(separator: "\n")
        let resultIdentity = resultOwners.map(\.identity).joined(separator: "\n")
        return [projectSessionID.uuidString, mapWorkflowIdentity, mapID.uuidString,
            map.mapIndex.description, map.mapName, map.mapType, map.projectPath,
            map.projectXmlSHA, map.expectedVisualizationRevision,
            Self.locatorIdentity(associationNode), assetPath,
            isChecked ? "checked" : "unchecked", effectiveVisible ? "visible" : "hidden",
            geometryIdentity, planIdentity, resultIdentity].joined(separator: "|")
    }

    /// Stable identity for the physical source extent. Visibility and the
    /// currently focused Geometry set do not change a layer's own bounds.
    var sourceExtentIdentity: String {
        [projectSessionID.uuidString, mapWorkflowIdentity, mapID.uuidString,
            map.projectXmlSHA, map.expectedVisualizationRevision,
            Self.locatorIdentity(associationNode), assetPath,
            planNodes.map(Self.locatorIdentity).joined(separator: "\n"),
            resultOwners.map(\.identity).joined(separator: "\n")]
            .map { "\($0.utf8.count):\($0)" }.joined()
    }

    static func locatorIdentity(_ locator: CatalogTreeNodeLocator) -> String {
        [locator.rootName, locator.nodeType, locator.nodeName,
         (locator.nodePath ?? []).map(String.init).joined(separator: "."),
         locator.assetID ?? "", locator.mapType ?? "", locator.filename ?? "",
         locator.filenameRelative ?? "", locator.parentGeometryAssetID ?? "",
         (locator.parentGeometryNodePath ?? []).map(String.init).joined(separator: "."),
         locator.parentGeometryNodeName ?? "", locator.parentPlanAssetID ?? "",
         (locator.parentPlanNodePath ?? []).map(String.init).joined(separator: "."),
         locator.parentPlanNodeName ?? "", locator.parentResultNodeType ?? "",
         locator.parentResultAssetID ?? "",
         (locator.parentResultNodePath ?? []).map(String.init).joined(separator: "."),
         locator.parentResultNodeName ?? "", locator.parentResultRevision ?? "",
         locator.associationKind ?? "",
         locator.associationAssetID ?? ""].map { "\($0.utf8.count):\($0)" }.joined()
    }

    static func supportedKind(_ rawValue: String?) -> AssociatedMapLayerKind? {
        guard let rawValue else { return nil }
        return AssociatedMapLayerKind(rawValue: rawValue)
    }

    private static func isGeometryLocator(_ locator: CatalogTreeNodeLocator) -> Bool {
        locator.nodeType == "Geometry"
            && locator.nodePath?.isEmpty == false
            && locator.assetID?.isEmpty == false
    }

    private static func isPlanLocator(_ locator: CatalogTreeNodeLocator) -> Bool {
        locator.isFocusedPlanOwner
            && (locator.nodePath == nil || locator.nodePath?.isEmpty == false)
            && locator.assetID?.hasPrefix("/") == true
            && locator.nodeName.isEmpty == false
    }

    private static func isResultOwner(_ owner: MapResultGeometryOwner,
                                      map: MapTreeMapIdentity) -> Bool {
        ["Project", "Buildable", "Geometry", "Plan"].contains(map.mapType)
            && owner.selectionIndex == 0
            && owner.resultNode.nodePath?.isEmpty == false
            && owner.contextToken.isEmpty == false
            && owner.selectedResultPath.hasPrefix("/")
            && owner.selectedResultRevision.count == 64
            && owner.selectedResultRevision.allSatisfy(\.isHexDigit)
    }

    private static func validPlanScope(_ node: CatalogTreeNodeLocator,
                                       map: MapTreeMapIdentity,
                                       planNodes: [CatalogTreeNodeLocator]) -> Bool {
        guard !planNodes.isEmpty else {
            return node.parentPlanAssetID == nil && node.parentPlanNodePath == nil
                && node.parentPlanNodeName == nil
        }
        guard map.mapType == "Plan" else { return false }
        if node.rootName == "Matching Layers" {
            return planNodes.count >= 2 && node.parentPlanAssetID == nil
                && node.parentPlanNodePath == nil && node.parentPlanNodeName == nil
        }
        return node.rootName == "Focused Plans" && planNodes.count == 1
            && node.parentPlanAssetID != nil && node.parentPlanNodeName != nil
    }

    private static func parentsMatch(_ locator: CatalogTreeNodeLocator,
                                     geometryNodes: [CatalogTreeNodeLocator],
                                     planNodes: [CatalogTreeNodeLocator],
                                     resultOwners: [MapResultGeometryOwner]) -> Bool {
        if locator.parentPlanAssetID != nil || locator.parentPlanNodePath != nil
            || locator.parentPlanNodeName != nil {
            guard let parentAsset = locator.parentPlanAssetID,
                  let parentName = locator.parentPlanNodeName,
                  planNodes.contains(where: { plan in
                      plan.nodePath == locator.parentPlanNodePath && plan.nodeName == parentName
                          && plan.assetID.map(canonicalPath) == canonicalPath(parentAsset)
                          && (plan.nodePath == nil || Self.isDescendant(locator.nodePath, of: plan.nodePath))
                  }) else { return false }
        }

        if let parentResultType = locator.parentResultNodeType {
            guard let parentResultPath = locator.parentResultNodePath,
                  let parentResultAsset = locator.parentResultAssetID,
                  let parentResultName = locator.parentResultNodeName,
                  let parentResultRevision = locator.parentResultRevision,
                  resultOwners.contains(where: { owner in
                      owner.resultNode.nodeType == parentResultType
                          && owner.resultNode.nodePath == parentResultPath
                          && owner.resultNode.nodeName == parentResultName
                          && canonicalPath(owner.selectedResultPath) == canonicalPath(parentResultAsset)
                          && owner.selectedResultRevision.caseInsensitiveCompare(parentResultRevision) == .orderedSame
                          && Self.isDescendant(locator.nodePath, of: owner.resultNode.nodePath)
                  }) else { return false }
        } else if locator.parentResultAssetID != nil || locator.parentResultNodePath != nil
                    || locator.parentResultNodeName != nil || locator.parentResultRevision != nil {
            return false
        }

        if locator.parentGeometryAssetID != nil || locator.parentGeometryNodePath != nil
            || locator.parentGeometryNodeName != nil {
            guard let parentPath = locator.parentGeometryNodePath,
                  let parentName = locator.parentGeometryNodeName,
                  let parentAsset = locator.parentGeometryAssetID,
                  geometryNodes.contains(where: { geometry in
                      geometry.nodePath == parentPath && geometry.nodeName == parentName
                          && geometry.assetID.map(canonicalPath) == canonicalPath(parentAsset)
                          && Self.isDescendant(locator.nodePath, of: geometry.nodePath)
                  }) else { return false }
        }
        return true
    }

    private static func isDescendant(_ child: [Int]?, of parent: [Int]?) -> Bool {
        guard let child, let parent, !parent.isEmpty, child.count > parent.count else { return false }
        return Array(child.prefix(parent.count)) == parent
    }

    private static func canonicalPath(_ path: String) -> String {
        SourceFilePaths.canonical(URL(fileURLWithPath: path))
    }
}

enum AssociatedMapLayerCaptureError: Error, LocalizedError {
    case incompleteIdentity

    var errorDescription: String? {
        "The associated map layer source identity is incomplete."
    }
}

enum AssociatedMapLayerKind: String, Codable, CaseIterable, Sendable {
    case terrain = "Terrain"
    case nValue = "NValue"
    case classification = "Classification"
}

enum AssociatedMapLayerStatus: String, Codable, Sendable {
    case available
    case hidden
    case empty
    case unavailable
    case failed
}

struct AssociatedMapLayerDependency: Decodable, Hashable, Sendable {
    let path: String
    let revision: String
    let role: String
}

struct AssociatedMapLayerLegendValue: Decodable, Hashable, Identifiable, Sendable {
    let value: String
    let label: String
    let red: Int
    let green: Int
    let blue: Int
    let alpha: Int

    var id: String { "\(value.utf8.count):\(value)|\(label.utf8.count):\(label)" }
}

struct AssociatedMapLayerPayload: Decodable, Sendable {
    let locator: CatalogTreeNodeLocator
    let geometryNodes: [CatalogTreeNodeLocator]
    let planNodes: [CatalogTreeNodeLocator]
    let resultOwners: [MapResultGeometryOwner]
    let kind: AssociatedMapLayerKind
    let assetPath: String
    let revision: String
    let dependencies: [AssociatedMapLayerDependency]
    let status: AssociatedMapLayerStatus
    let diagnostic: String?
    let isChecked: Bool
    let effectiveVisible: Bool
    /// Actual finite source bounds from the retained associated object. This
    /// is independent of `AssociatedMapLayersSnapshot.viewport`, which only
    /// describes the pixels returned for the current camera.
    let sourceExtent: MapGeometryViewport?
    let width: Int
    let height: Int
    /// System.Text.Json encodes the Host's byte[] as base64. This mirrors the
    /// existing raster rendering contracts and keeps pixel bytes lossless.
    let rgba: Data
    let legend: [AssociatedMapLayerLegendValue]
    /// Runtime renderer state reported for the exact associated raster row.
    /// Non-raster association kinds return nil.
    let plotRasterTileOutlines: Bool?

    private enum CodingKeys: String, CodingKey {
        case locator, geometryNodes, planNodes, resultOwners, kind, assetPath, revision
        case dependencies, status, diagnostic, isChecked, effectiveVisible, sourceExtent
        case width, height, rgba, legend, plotRasterTileOutlines
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        locator = try values.decode(CatalogTreeNodeLocator.self, forKey: .locator)
        geometryNodes = try values.decodeIfPresent([CatalogTreeNodeLocator].self, forKey: .geometryNodes) ?? []
        planNodes = try values.decodeIfPresent([CatalogTreeNodeLocator].self, forKey: .planNodes) ?? []
        resultOwners = try values.decodeIfPresent([MapResultGeometryOwner].self, forKey: .resultOwners) ?? []
        kind = try values.decode(AssociatedMapLayerKind.self, forKey: .kind)
        assetPath = try values.decode(String.self, forKey: .assetPath)
        revision = try values.decode(String.self, forKey: .revision)
        dependencies = try values.decode([AssociatedMapLayerDependency].self, forKey: .dependencies)
        status = try values.decode(AssociatedMapLayerStatus.self, forKey: .status)
        diagnostic = try values.decodeIfPresent(String.self, forKey: .diagnostic)
        isChecked = try values.decode(Bool.self, forKey: .isChecked)
        effectiveVisible = try values.decode(Bool.self, forKey: .effectiveVisible)
        sourceExtent = try values.decodeIfPresent(MapGeometryViewport.self, forKey: .sourceExtent)
        width = try values.decode(Int.self, forKey: .width)
        height = try values.decode(Int.self, forKey: .height)
        rgba = try values.decode(Data.self, forKey: .rgba)
        legend = try values.decode([AssociatedMapLayerLegendValue].self, forKey: .legend)
        plotRasterTileOutlines = try values.decodeIfPresent(Bool.self, forKey: .plotRasterTileOutlines)
    }
}

/// Runtime-only option for one exact Terrain or N-value association. It is
/// deliberately keyed by the source-tree locator and source HDF path so a
/// same-named row cannot inherit another row's renderer state.
struct AssociatedMapLayerRasterRuntimeOption: Encodable, Hashable, Sendable {
    let locator: CatalogTreeNodeLocator
    let assetPath: String
    let plotRasterTileOutlines: Bool

    func matches(_ capture: AssociatedMapLayerCapture) -> Bool {
        guard locator == capture.associationNode,
              let kind = locator.associationKind,
              kind == "Terrain" || kind == "NValue",
              capture.isChecked, capture.effectiveVisible else { return false }
        return SourceFilePaths.canonical(URL(fileURLWithPath: assetPath)) == capture.assetPath
    }
}

struct AssociatedMapLayersRequest: Encodable, Sendable {
    let map: MapTreeMapIdentity
    let geometryNodes: [CatalogTreeNodeLocator]
    let planNodes: [CatalogTreeNodeLocator]
    let resultOwners: [MapResultGeometryOwner]
    let associationNodes: [CatalogTreeNodeLocator]
    let viewport: MapGeometryViewport
    let width: Int
    let height: Int
    let contextToken: String?
    let rasterRuntimeOptions: [AssociatedMapLayerRasterRuntimeOption]

    init(map: MapTreeMapIdentity, geometryNodes: [CatalogTreeNodeLocator] = [],
         planNodes: [CatalogTreeNodeLocator] = [],
         resultOwners: [MapResultGeometryOwner] = [],
         associationNodes: [CatalogTreeNodeLocator], viewport: MapGeometryViewport,
         width: Int, height: Int, contextToken: String?,
         rasterRuntimeOptions: [AssociatedMapLayerRasterRuntimeOption] = []) {
        self.map = map
        self.geometryNodes = geometryNodes
        self.planNodes = planNodes
        self.resultOwners = resultOwners
        self.associationNodes = associationNodes
        self.viewport = viewport
        self.width = width
        self.height = height
        self.contextToken = contextToken
        self.rasterRuntimeOptions = rasterRuntimeOptions
    }
}

struct AssociatedMapLayersSnapshot: Decodable, Sendable {
    let mapID: String
    let mapIndex: Int
    let mapName: String
    let mapType: String
    let projectCanonicalPath: String
    let projectRevision: String
    let projectXmlSHA: String
    let visualizationRevision: String
    let contextToken: String
    let viewport: MapGeometryViewport
    let layers: [AssociatedMapLayerPayload]
}

struct AssociatedMapLayerState: Identifiable, Sendable {
    let capture: AssociatedMapLayerCapture
    var payload: AssociatedMapLayerPayload?
    var viewport: MapGeometryViewport?

    var id: String { capture.identity }
    var status: AssociatedMapLayerStatus? { payload?.status }
    var diagnostic: String? { payload?.diagnostic }
    var kind: AssociatedMapLayerKind? { payload?.kind }

    var rasterLayer: MapRasterLayer? {
        guard let payload, payload.status == .available,
              payload.isChecked, payload.effectiveVisible,
              let viewport,
              payload.width > 0, payload.height > 0,
              let pixelCount = Self.product(payload.width, payload.height),
              let byteCount = Self.product(pixelCount, 4),
              payload.rgba.count == byteCount else { return nil }
        return try? MapRasterLayer(id: capture.identity, name: capture.associationNode.nodeName,
            width: payload.width, height: payload.height, rgba: payload.rgba,
            lowerLeft: MapPoint(x: viewport.minX, y: viewport.minY),
            upperRight: MapPoint(x: viewport.maxX, y: viewport.maxY),
            sourceMapID: capture.mapID)
    }

    private static func product(_ lhs: Int, _ rhs: Int) -> Int? {
        let result = lhs.multipliedReportingOverflow(by: rhs)
        return result.overflow ? nil : result.partialValue
    }
}

struct AssociatedMapLayerLegend: Identifiable, Sendable {
    let id: String
    let name: String
    let kind: AssociatedMapLayerKind
    let values: [AssociatedMapLayerLegendValue]
}

extension MapGeometryViewport {
    init?(rasterExtent: RasterMapViewExtent) {
        guard [rasterExtent.minX, rasterExtent.minY, rasterExtent.maxX, rasterExtent.maxY]
            .allSatisfy(\.isFinite),
              rasterExtent.minX < rasterExtent.maxX,
              rasterExtent.minY < rasterExtent.maxY,
              rasterExtent.pixelWidth > 0, rasterExtent.pixelHeight > 0 else { return nil }
        minX = rasterExtent.minX
        minY = rasterExtent.minY
        maxX = rasterExtent.maxX
        maxY = rasterExtent.maxY
    }

    var isFiniteAndOrdered: Bool {
        [minX, minY, maxX, maxY].allSatisfy(\.isFinite)
            && minX < maxX && minY < maxY
    }

    /// Source bounds must have finite spans as well as finite endpoints;
    /// subtracting two individually finite extremes can still overflow.
    var hasFinitePositiveArea: Bool {
        guard isFiniteAndOrdered else { return false }
        let width = maxX - minX
        let height = maxY - minY
        return width.isFinite && height.isFinite && width > 0 && height > 0
    }
}
