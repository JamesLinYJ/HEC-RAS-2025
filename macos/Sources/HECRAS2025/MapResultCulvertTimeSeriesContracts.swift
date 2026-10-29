import Foundation
import RASWorkspaceCore

/// Exact Result-owned request for the stored culvert time-series arrays.
/// Barrel IDs are source ordinals, never display names or current map frames.
struct MapResultCulvertTimeSeriesRequest: Codable, Hashable, Sendable {
    let map: MapResultChartMapRequest
    let resultOwner: MapResultGeometryOwner
    let barrelIDs: [String]
    let variable: String
}

struct MapResultCulvertTimeSeriesBarrelIdentity: Codable, Hashable, Sendable {
    let id: String
    let sourceOrdinal: Int
    let name: String
}

/// Immutable value passed to the dedicated time-series WindowGroup. It keeps
/// the Result slot, selected HDF revision, Core context, and UI generations
/// captured by the map entry point.
struct MapResultCulvertTimeSeriesWindowRoute: Codable, Hashable, Sendable {
    let request: MapResultCulvertTimeSeriesRequest
    let expectedProjectRevision: String
    let expectedBarrels: [MapResultCulvertTimeSeriesBarrelIdentity]
    let projectSessionID: UUID
    let mapWorkflowIdentity: String
    let mapSourceWorkflowIdentity: String
    let profileCaptureIdentity: String
    let sourceContextIdentity: String

    init(request: MapResultCulvertTimeSeriesRequest,
         expectedProjectRevision: String,
         expectedBarrels: [MapResultCulvertTimeSeriesBarrelIdentity],
         projectSessionID: UUID,
         mapWorkflowIdentity: String,
         mapSourceWorkflowIdentity: String,
         profileCaptureIdentity: String,
         sourceContextIdentity: String) throws {
        let identities = expectedBarrels.map(\.id)
        guard request.resultOwner.selectionIndex == 0,
              request.resultOwner.resultNode.nodeType == "Result"
                || request.resultOwner.resultNode.nodeType == "MultiResult",
              request.resultOwner.resultNode.nodePath?.isEmpty == false,
              !request.resultOwner.contextToken.isEmpty,
              !request.resultOwner.selectedResultPath.isEmpty,
              Self.isSHA256(request.resultOwner.selectedResultRevision),
              Self.isSHA256(expectedProjectRevision),
              request.variable == "Flow" || request.variable == "Velocity",
              !request.barrelIDs.isEmpty,
              Set(request.barrelIDs).count == request.barrelIDs.count,
              identities == request.barrelIDs,
              Set(identities).count == identities.count,
              expectedBarrels.allSatisfy({ item in
                  item.sourceOrdinal >= 0
                      && item.id == "barrel:source:\(item.sourceOrdinal)"
              }),
              UUID(uuidString: request.map.mapID) != nil,
              request.map.coreLayerContext?.identityToken.isEmpty != true,
              !mapWorkflowIdentity.isEmpty,
              !mapSourceWorkflowIdentity.isEmpty,
              !profileCaptureIdentity.isEmpty,
              !sourceContextIdentity.isEmpty else {
            throw MapResultCulvertTimeSeriesError.incompleteIdentity
        }
        self.request = request
        self.expectedProjectRevision = expectedProjectRevision.uppercased()
        self.expectedBarrels = expectedBarrels
        self.projectSessionID = projectSessionID
        self.mapWorkflowIdentity = mapWorkflowIdentity
        self.mapSourceWorkflowIdentity = mapSourceWorkflowIdentity
        self.profileCaptureIdentity = profileCaptureIdentity
        self.sourceContextIdentity = sourceContextIdentity
    }

    var mapID: UUID? { UUID(uuidString: request.map.mapID) }

    var identity: String {
        let map = request.map
        let lease = map.computeReadLease.map { value in
            [value.projectSessionID, value.runID, value.projectPath,
             value.protectedSourcePaths.sorted().joined(separator: "\u{1e}"),
             value.callbackResultPath ?? ""].joined(separator: ":")
        } ?? ""
        return [projectSessionID.uuidString, mapWorkflowIdentity,
                mapSourceWorkflowIdentity, profileCaptureIdentity,
                sourceContextIdentity, map.projectPath, map.projectXmlSHA,
                map.mapID, String(map.mapIndex), map.mapName, map.mapType,
                map.expectedVisualizationRevision,
                map.coreLayerContext?.identityToken ?? "", lease,
                request.resultOwner.identity, request.variable,
                expectedProjectRevision,
                expectedBarrels.map { "\($0.id):\($0.sourceOrdinal):\($0.name)" }
                    .joined(separator: "\u{1e}")].joined(separator: "|")
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy(\.isHexDigit)
    }
}

struct MapResultCulvertTimeSeriesDataset: Decodable, Sendable {
    let id: String
    let name: String
    let sourceOrdinal: Int
    let colorRGBA: String
    let strokeWidth: Double
    let values: [Double]
}

struct MapResultCulvertTimeSeriesSnapshot: Decodable, Sendable {
    let projectCanonicalPath: String
    let projectRevision: String
    let projectXmlSHA: String
    let visualizationRevision: String
    let coreLayerContextIdentity: String
    let mapID: String
    let mapIndex: Int
    let mapName: String
    let mapType: String
    let contextToken: String
    let resultNode: CatalogTreeNodeLocator
    let selectionIndex: Int
    let selectedResultPath: String
    let selectedResultRevision: String
    let variable: String
    let units: String
    let times: [String]
    let noDataValue: Double
    let datasets: [MapResultCulvertTimeSeriesDataset]
}

enum MapResultCulvertTimeSeriesError: LocalizedError, Equatable {
    case incompleteIdentity
    case staleContext
    case sourceChanged
    case mismatchedReply
    case invalidReply

    var errorDescription: String? {
        switch self {
        case .incompleteIdentity:
            "The selected Result culvert time-series identity is incomplete."
        case .staleContext:
            "The selected Result or map context changed before the culvert time series opened."
        case .sourceChanged:
            "The selected Result or project changed while the culvert time series was loading."
        case .mismatchedReply:
            "The culvert time-series reply no longer matches the selected Result and barrels."
        case .invalidReply:
            "The stored culvert time-series data is empty or invalid."
        }
    }
}
