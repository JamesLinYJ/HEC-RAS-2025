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
    /// Exact `.vis` child and map request for a GDB raster. `gdbSource` is
    /// populated only after the backend returns the current directory manifest.
    public let gdbSourceContext: GdbRasterSymbologyContext?
    public let gdbSource: GdbRasterSymbologyIdentity?

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
        sourceRevision: String? = nil,
        gdbSourceContext: GdbRasterSymbologyContext? = nil,
        gdbSource: GdbRasterSymbologyIdentity? = nil
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
        self.gdbSourceContext = gdbSourceContext
        self.gdbSource = gdbSource
    }

    public func assigning(mapID: UUID) -> Self {
        let mapIDString = mapID.uuidString
        let assignedContext = gdbSourceContext.map { context in
            GdbRasterSymbologyContext(map: Self.map(context.map, mapID: mapIDString), node: context.node)
        }
        let assignedSource = gdbSource.map { source in
            GdbRasterSymbologyIdentity(map: Self.map(source.map, mapID: mapIDString),
                                       node: source.node, source: source.source)
        }
        return Self(id: id, projectPath: projectPath, visualizationPath: visualizationPath,
             visualizationRevision: visualizationRevision, mapIndex: mapIndex, mapName: mapName,
             mapType: mapType, nodePath: nodePath, nodeName: nodeName,
             mapLayerType: mapLayerType, filename: filename, filenameRelative: filenameRelative,
             sourcePath: sourcePath, sourceMapID: mapID, sourceRevision: sourceRevision,
             gdbSourceContext: assignedContext, gdbSource: assignedSource)
    }

    public func updating(visualizationRevision: String? = nil, sourceRevision: String? = nil) -> Self {
        let nextVisualizationRevision = visualizationRevision ?? self.visualizationRevision
        let context = gdbSourceContext.map { value in
            GdbRasterSymbologyContext(map: Self.map(value.map, visualizationRevision: nextVisualizationRevision),
                                      node: value.node)
        }
        let source = gdbSource.map { value in
            GdbRasterSymbologyIdentity(map: Self.map(value.map, visualizationRevision: nextVisualizationRevision),
                                       node: value.node, source: value.source)
        }
        return Self(id: id, projectPath: projectPath, visualizationPath: visualizationPath,
             visualizationRevision: nextVisualizationRevision,
             mapIndex: mapIndex, mapName: mapName, mapType: mapType, nodePath: nodePath,
             nodeName: nodeName, mapLayerType: mapLayerType, filename: filename,
             filenameRelative: filenameRelative, sourcePath: sourcePath, sourceMapID: sourceMapID,
             sourceRevision: sourceRevision ?? self.sourceRevision,
             gdbSourceContext: context, gdbSource: source)
    }

    /// Reuses an already hydrated GDB identity after a `.vis` mutation when
    /// the refreshed XML still describes the same exact project/map/node and
    /// the only changed map-capture field is the accepted visualization
    /// revision. The source manifest and all non-revision capture fields are
    /// retained verbatim. Ambiguous prior matches are rejected.
    public func reusingUniqueHydratedGdbIdentity(
        from previousSources: [Self],
        matching currentMap: GdbRasterSymbologyMapCapture
    ) -> Self? {
        guard let sourceMapID,
              let context = gdbSourceContext,
              gdbSource == nil,
              context.map.projectXml == nil,
              context.map.projectXmlSHA == nil,
              context.map.resultSelectionOverrides == nil,
              context.map.computeReadLease == nil,
              Self.matchesMapOwner(context.map, currentMap),
              context.map.expectedVisualizationRevision == visualizationRevision,
              context.map.mapIndex == mapIndex,
              context.map.mapName == mapName,
              context.map.mapType == mapType,
              context.map.mapID.caseInsensitiveCompare(sourceMapID.uuidString) == .orderedSame,
              Self.samePath(context.map.projectPath, projectPath) else { return nil }

        let matches = previousSources.compactMap { previous -> Self? in
            guard previous.id == id,
                  previous.projectPath == projectPath,
                  previous.visualizationPath == visualizationPath,
                  previous.mapIndex == mapIndex,
                  previous.mapName == mapName,
                  previous.mapType == mapType,
                  previous.nodePath == nodePath,
                  previous.nodeName == nodeName,
                  previous.mapLayerType == mapLayerType,
                  previous.filename == filename,
                  previous.filenameRelative == filenameRelative,
                  previous.sourcePath == sourcePath,
                  previous.sourceMapID == sourceMapID,
                  let previousContext = previous.gdbSourceContext,
                  let previousIdentity = previous.gdbSource,
                  previousIdentity.map == previousContext.map,
                  previousIdentity.node == previousContext.node,
                  previousIdentity.node == context.node,
                  previousContext.map.expectedVisualizationRevision == previous.visualizationRevision,
                  previousIdentity.map.mapID.caseInsensitiveCompare(sourceMapID.uuidString) == .orderedSame,
                  previousIdentity.map.mapIndex == previous.mapIndex,
                  previousIdentity.map.mapName == previous.mapName,
                  previousIdentity.map.mapType == previous.mapType,
                  previousIdentity.source.revision.caseInsensitiveCompare(previous.sourceRevision ?? "") == .orderedSame,
                  Self.samePath(previousIdentity.source.sourcePath, previous.sourcePath),
                  Self.samePath(previousIdentity.source.sourcePath, sourcePath),
                  context.node.assetID.map({ Self.samePath($0, sourcePath) }) == true,
                  previousIdentity.node.assetID.map({ Self.samePath($0, previous.sourcePath) }) == true,
                  Self.matchesMapOwner(previousIdentity.map, currentMap),
                  Self.matchesDescriptorMap(context.map, currentMap),
                  previousIdentity.map.projectXml == currentMap.projectXml,
                  previousIdentity.map.projectXmlSHA?.caseInsensitiveCompare(currentMap.projectXmlSHA ?? "") == .orderedSame,
                  Self.rebasing(previousIdentity.map, to: currentMap.expectedVisualizationRevision) == currentMap else {
                return nil
            }

            let rebasedMap = Self.rebasing(previousIdentity.map, to: currentMap.expectedVisualizationRevision)
            let rebasedContext = GdbRasterSymbologyContext(map: rebasedMap, node: previousIdentity.node)
            let rebasedIdentity = GdbRasterSymbologyIdentity(map: rebasedMap,
                node: previousIdentity.node, source: previousIdentity.source)
            return Self(id: id, projectPath: projectPath, visualizationPath: visualizationPath,
                visualizationRevision: visualizationRevision, mapIndex: mapIndex, mapName: mapName,
                mapType: mapType, nodePath: nodePath, nodeName: nodeName,
                mapLayerType: mapLayerType, filename: filename, filenameRelative: filenameRelative,
                sourcePath: sourcePath, sourceMapID: sourceMapID,
                sourceRevision: previousIdentity.source.revision,
                gdbSourceContext: rebasedContext, gdbSource: rebasedIdentity)
        }
        guard matches.count == 1 else { return nil }
        return matches[0]
    }

    private static func matchesMapOwner(_ captured: GdbRasterSymbologyMapCapture,
                                        _ current: GdbRasterSymbologyMapCapture) -> Bool {
        samePath(captured.projectPath, current.projectPath)
            && captured.mapID.caseInsensitiveCompare(current.mapID) == .orderedSame
            && captured.mapIndex == current.mapIndex
            && captured.mapName == current.mapName
            && captured.mapType == current.mapType
    }

    private static func matchesDescriptorMap(_ captured: GdbRasterSymbologyMapCapture,
                                             _ current: GdbRasterSymbologyMapCapture) -> Bool {
        matchesMapOwner(captured, current)
            && captured.expectedVisualizationRevision?.caseInsensitiveCompare(current.expectedVisualizationRevision ?? "") == .orderedSame
    }

    private static func rebasing(_ captured: GdbRasterSymbologyMapCapture,
                                 to visualizationRevision: String?) -> GdbRasterSymbologyMapCapture {
        map(captured, visualizationRevision: visualizationRevision)
    }

    private static func samePath(_ lhs: String, _ rhs: String) -> Bool {
        SourceFilePaths.canonical(URL(fileURLWithPath: lhs))
            == SourceFilePaths.canonical(URL(fileURLWithPath: rhs))
    }

    public func assigning(gdbSource: GdbRasterSymbologyIdentity) -> Self {
        Self(id: id, projectPath: projectPath, visualizationPath: visualizationPath,
             visualizationRevision: visualizationRevision, mapIndex: mapIndex, mapName: mapName,
             mapType: mapType, nodePath: nodePath, nodeName: nodeName,
             mapLayerType: mapLayerType, filename: filename, filenameRelative: filenameRelative,
             sourcePath: sourcePath, sourceMapID: sourceMapID,
             sourceRevision: gdbSource.source.revision,
             gdbSourceContext: gdbSourceContext, gdbSource: gdbSource)
    }

    public func assigning(gdbSourceContext: GdbRasterSymbologyContext,
                          source: GdbMapSourceIdentity) -> Self {
        assigning(gdbSource: GdbRasterSymbologyIdentity(map: gdbSourceContext.map,
            node: gdbSourceContext.node, source: source))
    }

    public func assigning(gdbSourceContext: GdbRasterSymbologyContext) -> Self {
        Self(id: id, projectPath: projectPath, visualizationPath: visualizationPath,
             visualizationRevision: visualizationRevision, mapIndex: mapIndex, mapName: mapName,
             mapType: mapType, nodePath: nodePath, nodeName: nodeName,
             mapLayerType: mapLayerType, filename: filename, filenameRelative: filenameRelative,
             sourcePath: sourcePath, sourceMapID: sourceMapID, sourceRevision: sourceRevision,
             gdbSourceContext: gdbSourceContext, gdbSource: nil)
    }

    private static func map(_ map: GdbRasterSymbologyMapCapture, mapID: String? = nil,
                            visualizationRevision: String? = nil) -> GdbRasterSymbologyMapCapture {
        GdbRasterSymbologyMapCapture(projectPath: map.projectPath, projectXml: map.projectXml,
            projectXmlSHA: map.projectXmlSHA, mapID: mapID ?? map.mapID, mapIndex: map.mapIndex,
            mapName: map.mapName, mapType: map.mapType,
            expectedVisualizationRevision: visualizationRevision ?? map.expectedVisualizationRevision,
            resultSelectionOverrides: map.resultSelectionOverrides,
            computeReadLease: map.computeReadLease)
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
