import Foundation
import RASWorkspaceCore

/// Stable identity captured from one exact saved map-tree association row.
/// A new context is required after every accepted .vis revision.
struct AssociatedRasterStyleContext: Hashable, Sendable {
    let projectSessionID: UUID
    let mapWorkflowIdentity: String
    let map: MapTreeMapIdentity
    let node: CatalogTreeNodeLocator
    let sourcePath: String
    let sourceRevision: String
    let geometryNodes: [CatalogTreeNodeLocator]
    let planNodes: [CatalogTreeNodeLocator]
    let resultOwner: MapResultGeometryOwner?

    init(projectSessionID: UUID, mapWorkflowIdentity: String,
         map: MapTreeMapIdentity, node: CatalogTreeNodeLocator,
         sourcePath: String, sourceRevision: String,
         geometryNodes: [CatalogTreeNodeLocator] = [],
         planNodes: [CatalogTreeNodeLocator] = [],
         resultOwner: MapResultGeometryOwner? = nil) throws {
        let canonicalPath = SourceFilePaths.canonical(URL(fileURLWithPath: sourcePath))
        guard !mapWorkflowIdentity.isEmpty,
              map.mapID.isEmpty == false,
              ["Project", "Buildable", "Geometry", "Plan"].contains(map.mapType),
              ["Terrain", "NValue"].contains(node.associationKind ?? node.nodeType),
              node.nodeType == (node.associationKind ?? node.nodeType),
              let ownerPath = node.associationAssetID ?? node.assetID,
              SourceFilePaths.canonical(URL(fileURLWithPath: ownerPath)) == canonicalPath,
              sourceRevision.count == 64,
              sourceRevision == sourceRevision.uppercased(),
              sourceRevision.allSatisfy(\.isHexDigit),
              geometryNodes.allSatisfy({ $0.nodeType == "Geometry" }),
              Set(geometryNodes).count == geometryNodes.count,
              planNodes.allSatisfy({ $0.isFocusedPlanOwner }),
              Set(planNodes).count == planNodes.count,
              planNodes.isEmpty || map.mapType == "Plan",
              Self.validOwnerScope(node, map: map, geometryNodes: geometryNodes,
                                   planNodes: planNodes, resultOwner: resultOwner) else {
            throw AssociatedRasterStyleError.incompleteIdentity
        }
        self.projectSessionID = projectSessionID
        self.mapWorkflowIdentity = mapWorkflowIdentity
        self.map = map
        self.node = node
        self.sourcePath = canonicalPath
        self.sourceRevision = sourceRevision
        self.geometryNodes = geometryNodes
        self.planNodes = planNodes
        self.resultOwner = resultOwner
    }

    var identity: String {
        [projectSessionID.uuidString, mapWorkflowIdentity, map.mapID,
         String(map.mapIndex), map.mapName, map.mapType, map.projectPath,
         map.projectXmlSHA, map.expectedVisualizationRevision,
         node.sourceIdentity, sourcePath, sourceRevision,
         geometryNodes.map(\.sourceIdentity).joined(separator: "\n"),
         planNodes.map(\.sourceIdentity).joined(separator: "\n"),
         resultOwner?.identity ?? ""]
            .map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
    }

    private static func validOwnerScope(_ node: CatalogTreeNodeLocator,
                                        map: MapTreeMapIdentity,
                                        geometryNodes: [CatalogTreeNodeLocator],
                                        planNodes: [CatalogTreeNodeLocator],
                                        resultOwner: MapResultGeometryOwner?) -> Bool {
        let hasResultParentIdentity = node.parentResultNodeType != nil
            || node.parentResultAssetID != nil || node.parentResultNodePath != nil
            || node.parentResultNodeName != nil || node.parentResultRevision != nil
        if hasResultParentIdentity && node.parentResultNodeType == nil { return false }
        if let ownerType = node.parentResultNodeType {
            guard let resultOwner, ownerType == resultOwner.resultNode.nodeType,
                  node.parentResultAssetID.map({ SourceFilePaths.canonical(URL(fileURLWithPath: $0)) })
                    == SourceFilePaths.canonical(URL(fileURLWithPath: resultOwner.selectedResultPath)),
                  node.parentResultNodeName == resultOwner.resultNode.nodeName,
                  node.parentResultNodePath == resultOwner.resultNode.nodePath,
                  node.parentResultRevision?.caseInsensitiveCompare(resultOwner.selectedResultRevision) == .orderedSame else {
                return false
            }
        } else if resultOwner != nil {
            return false
        }
        if node.parentPlanAssetID != nil || node.parentPlanNodePath != nil || node.parentPlanNodeName != nil {
            let matchesFocusedPlan = planNodes.contains(where: {
                ($0.assetID.map { SourceFilePaths.canonical(URL(fileURLWithPath: $0)) }
                    == node.parentPlanAssetID.map { SourceFilePaths.canonical(URL(fileURLWithPath: $0)) })
                    && $0.nodeName == node.parentPlanNodeName
                    && $0.nodePath == node.parentPlanNodePath
            })
            if resultOwner == nil {
                guard map.mapType == "Plan", matchesFocusedPlan else { return false }
            } else if !planNodes.isEmpty && !matchesFocusedPlan {
                return false
            }
        } else if node.rootName == "Matching Layers" {
            if map.mapType == "Plan" && planNodes.isEmpty { return false }
            if map.mapType == "Geometry" && geometryNodes.isEmpty { return false }
        }
        return true
    }
}

struct AssociatedRasterStyleColorStop: Codable, Hashable, Identifiable, Sendable {
    /// The retained source stores ramp order, not per-stop IDs.
    let index: Int
    var color: String
    var value: Double
    var id: Int { index }
}

struct AssociatedRasterStyleDraft: Codable, Hashable, Sendable {
    var paletteID: String?
    var name: String
    var stops: [AssociatedRasterStyleColorStop]
    var valueSource: String
    var isEditing: Bool
    var isSurfaceFillEnabled: Bool
    var alpha: Int
    var interpolationMode: String
    var smoothingRadius: Double
    var resampleCellSizeRatio: Double
    var hillshadeEnabled: Bool
    var hillshadeZFactor: Double
    var hillshadeAzimuth: Double
    var hillshadeZenith: Double
    var contoursEnabled: Bool
    var contoursAuto: Bool
    var contourInterval: Double
    var contourIndexEvery: Int
    var contourColorArgb: Int
    var contourOpacity: Int
    var contourShowLabels: Bool
    var contourDensity: Double
}

struct AssociatedRasterStylePalette: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let name: String
    let colors: [String]
    let values: [Double]?
    let isCustom: Bool
    let valueSource: String
}

/// Exact source files used to derive the selected style and its value ranges.
/// Revisions are uppercase SHA-256 values, except `missing` for an absent
/// optional source that the retained layer currently does not use.
struct AssociatedRasterStyleDependency: Codable, Hashable, Sendable {
    let path: String
    let revision: String
    let role: String
}

struct AssociatedRasterStyleSnapshot: Codable, Hashable, Sendable {
    let mapID: String
    let mapIndex: Int
    let mapName: String
    let mapType: String
    let projectCanonicalPath: String
    let projectXmlSHA: String
    let node: CatalogTreeNodeLocator
    let geometryNodes: [CatalogTreeNodeLocator]
    let planNodes: [CatalogTreeNodeLocator]
    let resultOwner: MapResultGeometryOwner?
    let sourcePath: String
    let contextToken: String
    let sourceKind: String
    let sourceRevision: String
    let visualizationRevision: String
    let draft: AssociatedRasterStyleDraft
    let resetDraft: AssociatedRasterStyleDraft
    let palettes: [AssociatedRasterStylePalette]
    let canComputeHistogram: Bool
    let sourceHistogramValues: [Double]?
    let dependencies: [AssociatedRasterStyleDependency]
}

struct AssociatedRasterStylePaletteMutation: Codable, Hashable, Sendable {
    /// The backend accepts only `saveCustom` or `deleteCustom`.
    let action: String
    var paletteID: String? = nil
    var name: String? = nil
}

struct AssociatedRasterStyleLoadRequest: Encodable, Sendable {
    let map: MapTreeMapIdentity
    let node: CatalogTreeNodeLocator
    let sourcePath: String
    let sourceRevision: String
    let contextToken: String?
    let geometryNodes: [CatalogTreeNodeLocator]
    let planNodes: [CatalogTreeNodeLocator]
    let resultOwner: MapResultGeometryOwner?
}

struct AssociatedRasterStyleApplyRequest: Encodable, Sendable {
    let map: MapTreeMapIdentity
    let node: CatalogTreeNodeLocator
    let sourcePath: String
    let sourceRevision: String
    let expectedContextToken: String
    let draft: AssociatedRasterStyleDraft
    let paletteMutation: AssociatedRasterStylePaletteMutation?
    let geometryNodes: [CatalogTreeNodeLocator]
    let planNodes: [CatalogTreeNodeLocator]
    let resultOwner: MapResultGeometryOwner?
}

struct AssociatedRasterStyleApplyResult: Decodable, Sendable {
    let previousVisualizationRevision: String
    let visualizationRevision: String
    let sourceRevision: String
}

struct AssociatedRasterStyleLoadedState: Sendable {
    let context: AssociatedRasterStyleContext
    let snapshot: AssociatedRasterStyleSnapshot
}

@MainActor
protocol AssociatedRasterStyleProvider {
    func load(_ context: AssociatedRasterStyleContext,
              contextToken: String?) async throws -> AssociatedRasterStyleSnapshot
    func apply(_ context: AssociatedRasterStyleContext,
               snapshot: AssociatedRasterStyleSnapshot,
               draft: AssociatedRasterStyleDraft,
               paletteMutation: AssociatedRasterStylePaletteMutation?) async throws
        -> AssociatedRasterStyleLoadedState
}

enum AssociatedRasterStyleError: Error, LocalizedError {
    case incompleteIdentity
    case staleContext
    case sourceChanged
    case mismatchedReply
    case unsupportedStyle
    case mutationUnavailable

    var errorDescription: String? {
        switch self {
        case .incompleteIdentity:
            "The associated raster style source identity is incomplete."
        case .staleContext:
            "The selected map or source layer changed. Refresh the style editor."
        case .sourceChanged:
            "The source raster changed while its style was being edited. Refresh the style editor."
        case .mismatchedReply:
            "The raster style service returned data for a different source layer."
        case .unsupportedStyle:
            "This associated source does not support a continuous raster style."
        case .mutationUnavailable:
            "Another project operation is in progress."
        }
    }
}
