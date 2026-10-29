import Foundation

/// One file in the stable manifest used to identify a File Geodatabase.
public struct GdbMapSourceFileRevision: Codable, Hashable, Sendable {
    public let relativePath: String
    public let length: Int64
    public let revision: String

    public init(relativePath: String, length: Int64, revision: String) {
        self.relativePath = relativePath
        self.length = length
        self.revision = revision
    }
}

/// The canonical directory and complete manifest captured by the backend.
/// The native client treats this revision as opaque and never re-hashes an open
/// geodatabase independently of the source reader.
public struct GdbMapSourceIdentity: Codable, Hashable, Sendable {
    public let sourcePath: String
    public let revision: String
    public let files: [GdbMapSourceFileRevision]

    public init(sourcePath: String, revision: String, files: [GdbMapSourceFileRevision]) {
        self.sourcePath = sourcePath
        self.revision = revision
        self.files = files
    }

    public var fileCount: Int { files.count }
}

/// Pure Codable peers for the exact nested `GdbRasterSymbologyIdentity` wire
/// contract. These live in Core so raster descriptors do not depend on the
/// application-only map-tree module.
public struct GdbRasterSymbologyIdentity: Codable, Hashable, Sendable {
    public let map: GdbRasterSymbologyMapCapture
    public let node: GdbRasterSymbologyNodeCapture
    public let source: GdbMapSourceIdentity

    public init(map: GdbRasterSymbologyMapCapture, node: GdbRasterSymbologyNodeCapture,
                source: GdbMapSourceIdentity) {
        self.map = map
        self.node = node
        self.source = source
    }
}

/// Captured map/node portion of a GDB raster identity, before the backend has
/// supplied the current directory manifest.
public struct GdbRasterSymbologyContext: Codable, Hashable, Sendable {
    public let map: GdbRasterSymbologyMapCapture
    public let node: GdbRasterSymbologyNodeCapture

    public init(map: GdbRasterSymbologyMapCapture, node: GdbRasterSymbologyNodeCapture) {
        self.map = map
        self.node = node
    }
}

public struct GdbRasterSymbologyMapCapture: Codable, Hashable, Sendable {
    public let projectPath: String
    public let projectXml: String?
    public let projectXmlSHA: String?
    public let mapID: String
    public let mapIndex: Int
    public let mapName: String
    public let mapType: String
    public let expectedVisualizationRevision: String?
    public let resultSelectionOverrides: [GdbRasterMapTreeResultSelectionOverride]?
    public let computeReadLease: GdbRasterComputeReadLease?

    public init(projectPath: String, projectXml: String?, projectXmlSHA: String?, mapID: String,
                mapIndex: Int, mapName: String, mapType: String, expectedVisualizationRevision: String?,
                resultSelectionOverrides: [GdbRasterMapTreeResultSelectionOverride]? = nil,
                computeReadLease: GdbRasterComputeReadLease? = nil) {
        self.projectPath = projectPath
        self.projectXml = projectXml
        self.projectXmlSHA = projectXmlSHA
        self.mapID = mapID
        self.mapIndex = mapIndex
        self.mapName = mapName
        self.mapType = mapType
        self.expectedVisualizationRevision = expectedVisualizationRevision
        self.resultSelectionOverrides = resultSelectionOverrides
        self.computeReadLease = computeReadLease
    }
}

public struct GdbRasterMapTreeResultSelectionOverride: Codable, Hashable, Sendable {
    public let planAssetID: String
    public let planName: String
    public let selectedResultPath: String
    public let selectedResultRevision: String

    public init(planAssetID: String, planName: String, selectedResultPath: String,
                selectedResultRevision: String) {
        self.planAssetID = planAssetID
        self.planName = planName
        self.selectedResultPath = selectedResultPath
        self.selectedResultRevision = selectedResultRevision
    }
}

public struct GdbRasterComputeReadLease: Codable, Hashable, Sendable {
    public let projectSessionID: String
    public let runID: String
    public let projectPath: String
    public let protectedSourcePaths: [String]
    public let callbackResultPath: String?

    public init(projectSessionID: String, runID: String, projectPath: String,
                protectedSourcePaths: [String], callbackResultPath: String? = nil) {
        self.projectSessionID = projectSessionID
        self.runID = runID
        self.projectPath = projectPath
        self.protectedSourcePaths = protectedSourcePaths
        self.callbackResultPath = callbackResultPath
    }
}

public struct GdbRasterSymbologyNodeCapture: Codable, Hashable, Sendable {
    public let rootName: String
    public let nodeType: String
    public let nodeName: String
    public let nodePath: [Int]?
    public let assetID: String?
    public let mapType: String?
    public let filename: String?
    public let filenameRelative: String?
    public let parentGeometryAssetID: String?
    public let parentGeometryNodePath: [Int]?
    public let parentGeometryNodeName: String?
    public let parentPlanAssetID: String?
    public let parentPlanNodePath: [Int]?
    public let parentPlanNodeName: String?
    public let parentResultNodeType: String?
    public let parentResultAssetID: String?
    public let parentResultNodePath: [Int]?
    public let parentResultNodeName: String?
    public let parentResultRevision: String?
    public let parentBoundaryConditionAssetID: String?
    public let parentBoundaryConditionNodePath: [Int]?
    public let parentBoundaryConditionNodeName: String?
    public let associationAssetID: String?
    public let associationKind: String?

    public init(rootName: String, nodeType: String, nodeName: String, nodePath: [Int]?,
                assetID: String?, mapType: String?, filename: String?, filenameRelative: String?,
                parentGeometryAssetID: String? = nil, parentGeometryNodePath: [Int]? = nil,
                parentGeometryNodeName: String? = nil, parentPlanAssetID: String? = nil,
                parentPlanNodePath: [Int]? = nil, parentPlanNodeName: String? = nil,
                parentResultNodeType: String? = nil, parentResultAssetID: String? = nil,
                parentResultNodePath: [Int]? = nil, parentResultNodeName: String? = nil,
                parentResultRevision: String? = nil, parentBoundaryConditionAssetID: String? = nil,
                parentBoundaryConditionNodePath: [Int]? = nil, parentBoundaryConditionNodeName: String? = nil,
                associationAssetID: String? = nil, associationKind: String? = nil) {
        self.rootName = rootName
        self.nodeType = nodeType
        self.nodeName = nodeName
        self.nodePath = nodePath
        self.assetID = assetID
        self.mapType = mapType
        self.filename = filename
        self.filenameRelative = filenameRelative
        self.parentGeometryAssetID = parentGeometryAssetID
        self.parentGeometryNodePath = parentGeometryNodePath
        self.parentGeometryNodeName = parentGeometryNodeName
        self.parentPlanAssetID = parentPlanAssetID
        self.parentPlanNodePath = parentPlanNodePath
        self.parentPlanNodeName = parentPlanNodeName
        self.parentResultNodeType = parentResultNodeType
        self.parentResultAssetID = parentResultAssetID
        self.parentResultNodePath = parentResultNodePath
        self.parentResultNodeName = parentResultNodeName
        self.parentResultRevision = parentResultRevision
        self.parentBoundaryConditionAssetID = parentBoundaryConditionAssetID
        self.parentBoundaryConditionNodePath = parentBoundaryConditionNodePath
        self.parentBoundaryConditionNodeName = parentBoundaryConditionNodeName
        self.associationAssetID = associationAssetID
        self.associationKind = associationKind
    }
}
