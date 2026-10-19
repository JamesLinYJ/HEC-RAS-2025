import Foundation

/// An exact source location in the maps stored by the current project's `.vis`
/// file. `nodePath` is the sequence of child-`Node` indexes below
/// `Map/Tree/Nodes`; the backend re-reads the file and verifies that location
/// before it reads or writes any raster data.
public struct RasterMapSourceDescriptor: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let projectPath: String
    public let visualizationPath: String
    public let visualizationRevision: String
    public let mapIndex: Int
    public let mapName: String
    public let mapType: String
    public let nodePath: [Int]
    public let nodeName: String
    public let mapLayerType: String
    public let filename: String?
    public let filenameRelative: String?
    public let sourcePath: String
    public let sourceMapID: UUID?
    public let sourceRevision: String?

    public init(
        id: String,
        projectPath: String,
        visualizationPath: String,
        visualizationRevision: String,
        mapIndex: Int,
        mapName: String,
        mapType: String,
        nodePath: [Int],
        nodeName: String,
        mapLayerType: String,
        filename: String?,
        filenameRelative: String?,
        sourcePath: String,
        sourceMapID: UUID? = nil,
        sourceRevision: String? = nil
    ) {
        self.id = id
        self.projectPath = projectPath
        self.visualizationPath = visualizationPath
        self.visualizationRevision = visualizationRevision
        self.mapIndex = mapIndex
        self.mapName = mapName
        self.mapType = mapType
        self.nodePath = nodePath
        self.nodeName = nodeName
        self.mapLayerType = mapLayerType
        self.filename = filename
        self.filenameRelative = filenameRelative
        self.sourcePath = sourcePath
        self.sourceMapID = sourceMapID
        self.sourceRevision = sourceRevision
    }

    public func assigning(mapID: UUID) -> Self {
        Self(id: id, projectPath: projectPath, visualizationPath: visualizationPath,
             visualizationRevision: visualizationRevision, mapIndex: mapIndex, mapName: mapName,
             mapType: mapType, nodePath: nodePath, nodeName: nodeName,
             mapLayerType: mapLayerType, filename: filename, filenameRelative: filenameRelative,
             sourcePath: sourcePath, sourceMapID: mapID, sourceRevision: sourceRevision)
    }

    public func updating(visualizationRevision: String? = nil, sourceRevision: String? = nil) -> Self {
        Self(id: id, projectPath: projectPath, visualizationPath: visualizationPath,
             visualizationRevision: visualizationRevision ?? self.visualizationRevision,
             mapIndex: mapIndex, mapName: mapName, mapType: mapType, nodePath: nodePath,
             nodeName: nodeName, mapLayerType: mapLayerType, filename: filename,
             filenameRelative: filenameRelative, sourcePath: sourcePath, sourceMapID: sourceMapID,
             sourceRevision: sourceRevision ?? self.sourceRevision)
    }
}

/// Display identity is position-aware because `.vis` permits duplicate map
/// names. Keep the original name and type for labels and exact verification.
public struct VisualizationMapIdentity: Identifiable, Hashable, Sendable {
    public let index: Int
    public let name: String
    public let type: String
    public var id: String { "\(index):\(type):\(name)" }

    public init(index: Int, name: String, type: String) {
        self.index = index
        self.name = name
        self.type = type
    }
}
