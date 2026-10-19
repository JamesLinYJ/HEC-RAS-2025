import Foundation
import RASWorkspaceCore

enum MapHoverModelVectorRendererKind: String, Codable, Sendable {
    case culvertBarrel
    case boundaryConditionLine
}

enum MapHoverModelVectorOwnerMode: String, Codable, Sendable {
    case savedSource
    case parentDraft
    case resultSource
}

/// Wire-compatible subset of the backend's ModelRequest. Keeping it typed
/// prevents the hover path from rebuilding a request from mutable store state.
struct MapHoverModelVectorModelRequest: Codable, Sendable {
    let assetPath: String
    let kind: String
    let projectPath: String?
    let projectXml: String?
    let sourceState: String?
    let coreLayerContext: CoreLayerRequestContext?
}

struct MapHoverModelVectorLine: Encodable, Sendable {
    let id: String
    let name: String
    let sourceOrdinal: Int
    let coordinates: [MapHoverCoordinate]
}

/// Exact captured source and owner information needed to rerun the source
/// renderer's vector hit test on the backend.
struct MapHoverModelVectorCapture: Encodable, Sendable {
    let node: CatalogTreeNodeLocator
    let rendererKind: MapHoverModelVectorRendererKind
    let sourcePath: String
    let sourceRevision: String
    let ownerMode: MapHoverModelVectorOwnerMode
    let geometryNode: CatalogTreeNodeLocator?
    let geometryContextToken: String?
    let planNodes: [CatalogTreeNodeLocator]?
    let resultOwner: MapResultGeometryOwner?
    let model: MapHoverModelVectorModelRequest?
    let culvertDraftState: String?
    let culvertDraftSHA256: String?
    let boundarySourceState: String?
    let boundaryContextToken: String?
    let boundaryLines: [MapHoverModelVectorLine]?
}
