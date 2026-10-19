import Foundation

/// Exact persisted `.vis` identity for a BoundaryCondition's line-rendering
/// child. Paths use the source map-tree convention: the root index followed by
/// each child index among its parent's `Node` elements.
///
/// `lineNodePath` is nil only when the source tree exposes the unique line
/// context from an already persisted BoundaryCondition row but `.vis` has not
/// materialized that child yet. Core never creates the BoundaryCondition row.
public struct BoundaryVectorVisualNodeIdentity: Hashable, Sendable {
    public let mapIndex: Int
    public let mapName: String
    public let mapType: String
    public let rootName: String
    public let boundaryNodePath: [Int]
    public let boundaryName: String
    public let lineNodePath: [Int]?
    public let lineNodeName: String

    public init(mapIndex: Int, mapName: String, mapType: String, rootName: String,
                boundaryNodePath: [Int], boundaryName: String, lineNodePath: [Int]?,
                lineNodeName: String) {
        self.mapIndex = mapIndex
        self.mapName = mapName
        self.mapType = mapType
        self.rootName = rootName
        self.boundaryNodePath = boundaryNodePath
        self.boundaryName = boundaryName
        self.lineNodePath = lineNodePath
        self.lineNodeName = lineNodeName
    }
}
