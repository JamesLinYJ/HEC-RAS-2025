import Foundation
import RASWorkspaceCore

/// One exact Result-owned culvert-profile read. Result/MultiResult selection
/// overrides are session state; the request never resolves a result by name.
struct MapResultCulvertProfileRequest: Encodable, Sendable {
    let map: MapTreeMapIdentity
    let contextToken: String
    let selectionOverrides: [MapResultSelectionOverride]
    let resultNode: CatalogTreeNodeLocator
    let selectionIndex: Int
    let profileIndex: Int

    init(capture: StoredCulvertProfileCapture, profileIndex: Int) {
        map = capture.map
        contextToken = capture.resultOwner.contextToken
        selectionOverrides = capture.resultOwner.selectionOverrides ?? []
        resultNode = capture.resultOwner.resultNode
        selectionIndex = capture.resultOwner.selectionIndex
        self.profileIndex = profileIndex
    }
}

struct MapResultCulvertCoordinate: Decodable, Hashable, Sendable {
    let x: Double
    let y: Double
}

struct MapResultCulvertBarrel: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let sourceOrdinal: Int
    let name: String
    let coordinates: [MapResultCulvertCoordinate]
}

/// The host returns arrays only when `OutputBlock.TryReadCulvertData` succeeds.
/// `outsideDepth` has two source values per barrel; it is never inferred from
/// flow or geometry.
struct MapResultCulvertProfileSnapshot: Decodable, Sendable {
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
    let selectionMode: String
    let selectedResultPath: String
    let selectedResultRevision: String
    let selectedMapType: String?
    let profileIndex: Int
    let profileCount: Int
    let profileNames: [String]
    let geometryName: String?
    let geometryPath: String
    let geometryRevision: String
    let geometryOwnerNode: CatalogTreeNodeLocator?
    let geometryAvailable: Bool
    let outputAvailable: Bool
    let diagnostic: String?
    let barrels: [MapResultCulvertBarrel]
    let flow: [Double]
    let outsideDepth: [Double]
    let outletVelocity: [Double]
}

/// Immutable owner for the exact current slot-zero Result geometry. The map
/// and selected result are captured from the same chart snapshot so later
/// timeline replies cannot silently adopt a new result or map revision.
struct StoredCulvertProfileCapture: Hashable, Sendable {
    let projectSessionID: UUID
    let mapID: UUID
    let workflowIdentity: String
    let map: MapTreeMapIdentity
    let projectRevision: String
    let resultOwner: MapResultGeometryOwner
    let resultNodeID: String
    let selectionMode: MapResultSelectionMode
    let selectedMapType: String?
    let initialProfileIndex: Int

    init(projectSessionID: UUID, workflowIdentity: String,
         map: MapTreeMapIdentity, snapshot: MapResultSourcesSnapshot,
         resultNodeID: String, profileIndex: Int? = nil) throws {
        guard !workflowIdentity.isEmpty,
              let mapID = UUID(uuidString: map.mapID),
              snapshot.map.mapID == map.mapID,
              snapshot.map.mapIndex == map.mapIndex,
              snapshot.map.mapName == map.mapName,
              snapshot.map.mapType == map.mapType,
              snapshot.map.projectPath == map.projectPath,
              snapshot.map.projectXmlSHA.caseInsensitiveCompare(map.projectXmlSHA) == .orderedSame,
              snapshot.map.expectedVisualizationRevision.caseInsensitiveCompare(map.expectedVisualizationRevision) == .orderedSame,
              snapshot.sources.mapID == map.mapID,
              snapshot.sources.mapIndex == map.mapIndex,
              snapshot.sources.mapName == map.mapName,
              snapshot.sources.mapType == map.mapType,
              snapshot.sources.projectXmlSHA.caseInsensitiveCompare(map.projectXmlSHA) == .orderedSame,
              snapshot.sources.visualizationRevision.caseInsensitiveCompare(map.expectedVisualizationRevision) == .orderedSame,
              !snapshot.sources.contextToken.isEmpty,
              let node = snapshot.sources.activeNodes.first(where: { $0.id == resultNodeID }),
              node.id == resultNodeID,
              node.node.nodeType == "Result" || node.node.nodeType == "MultiResult",
              let slot = node.selections.first(where: { $0.selectionIndex == 0 }),
              let selected = slot.selectedResult,
              selected.resultPath.hasPrefix("/"),
              Self.isSHA256(selected.revision),
              let profileIndex = profileIndex ?? node.profileIndex,
              profileIndex >= 0 else {
            throw StoredCulvertProfileError.incompleteIdentity
        }

        let owner = try MapResultGeometryOwner(resultNode: node.node,
            contextToken: snapshot.sources.contextToken,
            selectionOverrides: snapshot.selectionOverrides,
            selectionIndex: slot.selectionIndex,
            selectedResultPath: selected.resultPath,
            selectedResultRevision: selected.revision)

        self.projectSessionID = projectSessionID
        self.mapID = mapID
        self.workflowIdentity = workflowIdentity
        self.map = map
        projectRevision = snapshot.sources.projectRevision
        resultOwner = owner
        self.resultNodeID = node.id
        selectionMode = slot.selectionMode
        selectedMapType = node.selectedMapType
        initialProfileIndex = profileIndex
    }

    /// Profile index is intentionally excluded: changing the timeline frame
    /// changes data, not the Result owner or its source identity.
    var identity: String {
        [projectSessionID.uuidString, mapID.uuidString, workflowIdentity,
         map.mapID, String(map.mapIndex), map.mapName, map.mapType,
         map.projectPath, map.projectXmlSHA, map.expectedVisualizationRevision,
         projectRevision, resultOwner.identity, resultNodeID,
         selectionMode.rawValue, selectedMapType ?? ""].joined(separator: "|")
    }

    /// Matches the selected Result row's per-map source context key. The
    /// context is exact locator identity, not the row label or selected HDF
    /// display name.
    var sourceContextIdentity: String {
        "\(mapID.uuidString)|\(resultOwner.resultNode.sourceIdentity)"
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy(\.isHexDigit)
    }
}

enum StoredCulvertProfileError: LocalizedError, Equatable {
    case incompleteIdentity
    case staleContext
    case mismatchedReply
    case sourceChanged
    case invalidReply

    var errorDescription: String? {
        switch self {
        case .incompleteIdentity:
            "The selected Result culvert profile identity is incomplete."
        case .staleContext:
            "The selected Result culvert profile context changed. Refresh the map."
        case .mismatchedReply:
            "The culvert profile reply no longer matches the selected Result and profile."
        case .sourceChanged:
            "The selected Result changed while its culvert profile was loading. Refresh the map."
        case .invalidReply:
            "The culvert profile service returned invalid source data."
        }
    }
}
