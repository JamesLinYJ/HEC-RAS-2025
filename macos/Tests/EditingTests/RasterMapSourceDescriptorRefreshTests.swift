import Foundation
import Testing
import RASWorkspaceCore

struct RasterMapSourceDescriptorRefreshTests {
    private struct Fixture {
        let placeholder: RasterMapSourceDescriptor
        let hydrated: RasterMapSourceDescriptor
        let currentMap: GdbRasterSymbologyMapCapture
        let sourceIdentity: GdbMapSourceIdentity
        let node: GdbRasterSymbologyNodeCapture
        let projectXML: String
    }

    private func makeFixture() -> Fixture {
        let projectXML = "<Ras><Plans/></Ras>"
        let mapID = UUID(uuidString: "88E67D4D-306F-43C5-89FD-14D52BB8A4D1")!
        let sourcePath = "/tmp/RasterProject/terrain.gdb"
        let sourceIdentity = GdbMapSourceIdentity(sourcePath: sourcePath, revision: "GDB-REV-1", files: [
            .init(relativePath: "a00000001.gdbtable", length: 128, revision: "FILE-REV-1")
        ])
        let node = GdbRasterSymbologyNodeCapture(rootName: "Map Layers", nodeType: "MapLayer",
            nodeName: "Depth display", nodePath: [0, 2], assetID: sourcePath,
            mapType: "SingleBandRasterMapLayer", filename: "GDB:terrain.gdb:Depth",
            filenameRelative: "terrain.gdb")
        let overrides = [GdbRasterMapTreeResultSelectionOverride(planAssetID: "/tmp/RasterProject/Plan01.p##",
            planName: "Plan 01", selectedResultPath: "/tmp/RasterProject/Plan01.hdf",
            selectedResultRevision: "RESULT-REV-1")]
        let readLease = GdbRasterComputeReadLease(projectSessionID: UUID().uuidString,
            runID: UUID().uuidString, projectPath: "/tmp/RasterProject/Project.ras",
            protectedSourcePaths: ["/tmp/RasterProject/Plan01.hdf"],
            callbackResultPath: "/tmp/RasterProject/Plan01.hdf")
        let oldMap = GdbRasterSymbologyMapCapture(projectPath: "/tmp/RasterProject/Project.ras",
            projectXml: projectXML, projectXmlSHA: "PROJECT-XML-SHA", mapID: mapID.uuidString,
            mapIndex: 0, mapName: "Project map", mapType: "Project",
            expectedVisualizationRevision: "VIS-REV-OLD", resultSelectionOverrides: overrides,
            computeReadLease: readLease)
        let currentMap = GdbRasterSymbologyMapCapture(projectPath: oldMap.projectPath,
            projectXml: oldMap.projectXml, projectXmlSHA: oldMap.projectXmlSHA, mapID: oldMap.mapID,
            mapIndex: oldMap.mapIndex, mapName: oldMap.mapName, mapType: oldMap.mapType,
            expectedVisualizationRevision: "VIS-REV-NEW", resultSelectionOverrides: overrides,
            computeReadLease: readLease)
        let placeholderMap = GdbRasterSymbologyMapCapture(projectPath: oldMap.projectPath,
            projectXml: nil, projectXmlSHA: nil, mapID: oldMap.mapID, mapIndex: oldMap.mapIndex,
            mapName: oldMap.mapName, mapType: oldMap.mapType,
            expectedVisualizationRevision: "VIS-REV-NEW")
        let mapIDValue = mapID
        let hydrated = RasterMapSourceDescriptor(id: "vis-map-0-node-0.2",
            projectPath: "/tmp/RasterProject/Project.ras", visualizationPath: "/tmp/RasterProject/Project.vis",
            visualizationRevision: "VIS-REV-OLD", mapIndex: 0, mapName: "Project map", mapType: "Project",
            nodePath: [0, 2], nodeName: "Depth display", mapLayerType: "SingleBandRasterMapLayer",
            filename: "GDB:terrain.gdb:Depth", filenameRelative: "terrain.gdb", sourcePath: sourcePath,
            sourceMapID: mapIDValue, sourceRevision: sourceIdentity.revision,
            gdbSourceContext: .init(map: oldMap, node: node),
            gdbSource: .init(map: oldMap, node: node, source: sourceIdentity))
        let placeholder = RasterMapSourceDescriptor(id: hydrated.id,
            projectPath: hydrated.projectPath, visualizationPath: hydrated.visualizationPath,
            visualizationRevision: "VIS-REV-NEW", mapIndex: hydrated.mapIndex, mapName: hydrated.mapName,
            mapType: hydrated.mapType, nodePath: hydrated.nodePath, nodeName: hydrated.nodeName,
            mapLayerType: hydrated.mapLayerType, filename: hydrated.filename,
            filenameRelative: hydrated.filenameRelative, sourcePath: hydrated.sourcePath,
            sourceMapID: mapIDValue, gdbSourceContext: .init(map: placeholderMap, node: node))
        return Fixture(placeholder: placeholder, hydrated: hydrated, currentMap: currentMap,
            sourceIdentity: sourceIdentity, node: node, projectXML: projectXML)
    }

    @Test func refreshRebasesOnlyTheAcceptedVisualizationRevision() throws {
        let fixture = makeFixture()
        let refreshed = try #require(fixture.placeholder.reusingUniqueHydratedGdbIdentity(
            from: [fixture.hydrated], matching: fixture.currentMap))

        #expect(refreshed.visualizationRevision == "VIS-REV-NEW")
        #expect(refreshed.sourceRevision == fixture.sourceIdentity.revision)
        #expect(refreshed.gdbSourceContext?.map.expectedVisualizationRevision == "VIS-REV-NEW")
        #expect(refreshed.gdbSource?.map == fixture.currentMap)
        #expect(refreshed.gdbSource?.node == fixture.node)
        #expect(refreshed.gdbSource?.source == fixture.sourceIdentity)
        #expect(refreshed.gdbSourceContext?.map.projectXml == fixture.projectXML)
        #expect(refreshed.gdbSourceContext?.map.resultSelectionOverrides == fixture.currentMap.resultSelectionOverrides)
        #expect(refreshed.gdbSourceContext?.map.computeReadLease == fixture.currentMap.computeReadLease)
    }

    @Test func refreshRejectsAmbiguousOrChangedOwners() throws {
        let fixture = makeFixture()
        #expect(fixture.placeholder.reusingUniqueHydratedGdbIdentity(
            from: [fixture.hydrated, fixture.hydrated], matching: fixture.currentMap) == nil)

        let differentNode = GdbRasterSymbologyNodeCapture(rootName: "Map Layers", nodeType: "MapLayer",
            nodeName: "Other raster", nodePath: [0, 3], assetID: fixture.hydrated.sourcePath,
            mapType: "SingleBandRasterMapLayer", filename: fixture.hydrated.filename,
            filenameRelative: fixture.hydrated.filenameRelative)
        let hydratedIdentity = try #require(fixture.hydrated.gdbSource)
        let hydratedContext = try #require(fixture.hydrated.gdbSourceContext)
        let wrongNodeIdentity = GdbRasterSymbologyIdentity(map: hydratedIdentity.map,
            node: differentNode, source: fixture.sourceIdentity)
        let wrongNode = RasterMapSourceDescriptor(id: fixture.hydrated.id,
            projectPath: fixture.hydrated.projectPath, visualizationPath: fixture.hydrated.visualizationPath,
            visualizationRevision: fixture.hydrated.visualizationRevision,
            mapIndex: fixture.hydrated.mapIndex, mapName: fixture.hydrated.mapName,
            mapType: fixture.hydrated.mapType, nodePath: fixture.hydrated.nodePath,
            nodeName: fixture.hydrated.nodeName, mapLayerType: fixture.hydrated.mapLayerType,
            filename: fixture.hydrated.filename, filenameRelative: fixture.hydrated.filenameRelative,
            sourcePath: fixture.hydrated.sourcePath, sourceMapID: fixture.hydrated.sourceMapID,
            sourceRevision: fixture.hydrated.sourceRevision,
            gdbSourceContext: .init(map: hydratedContext.map, node: differentNode),
            gdbSource: wrongNodeIdentity)
        #expect(fixture.placeholder.reusingUniqueHydratedGdbIdentity(
            from: [wrongNode], matching: fixture.currentMap) == nil)

        let wrongProjectXML = GdbRasterSymbologyMapCapture(projectPath: fixture.currentMap.projectPath,
            projectXml: "<Ras><Changed/></Ras>", projectXmlSHA: "OTHER-SHA",
            mapID: fixture.currentMap.mapID, mapIndex: fixture.currentMap.mapIndex,
            mapName: fixture.currentMap.mapName, mapType: fixture.currentMap.mapType,
            expectedVisualizationRevision: fixture.currentMap.expectedVisualizationRevision,
            resultSelectionOverrides: fixture.currentMap.resultSelectionOverrides,
            computeReadLease: fixture.currentMap.computeReadLease)
        #expect(fixture.placeholder.reusingUniqueHydratedGdbIdentity(
            from: [fixture.hydrated], matching: wrongProjectXML) == nil)

        let changedMapID = GdbRasterSymbologyMapCapture(projectPath: fixture.currentMap.projectPath,
            projectXml: fixture.currentMap.projectXml, projectXmlSHA: fixture.currentMap.projectXmlSHA,
            mapID: UUID().uuidString, mapIndex: fixture.currentMap.mapIndex,
            mapName: fixture.currentMap.mapName, mapType: fixture.currentMap.mapType,
            expectedVisualizationRevision: fixture.currentMap.expectedVisualizationRevision,
            resultSelectionOverrides: fixture.currentMap.resultSelectionOverrides,
            computeReadLease: fixture.currentMap.computeReadLease)
        #expect(fixture.placeholder.reusingUniqueHydratedGdbIdentity(
            from: [fixture.hydrated], matching: changedMapID) == nil)

        let changedOverrides = [GdbRasterMapTreeResultSelectionOverride(
            planAssetID: "/tmp/RasterProject/Plan01.p##", planName: "Plan 01",
            selectedResultPath: "/tmp/RasterProject/Plan02.hdf", selectedResultRevision: "RESULT-REV-2")]
        let changedResultContext = GdbRasterSymbologyMapCapture(projectPath: fixture.currentMap.projectPath,
            projectXml: fixture.currentMap.projectXml, projectXmlSHA: fixture.currentMap.projectXmlSHA,
            mapID: fixture.currentMap.mapID, mapIndex: fixture.currentMap.mapIndex,
            mapName: fixture.currentMap.mapName, mapType: fixture.currentMap.mapType,
            expectedVisualizationRevision: fixture.currentMap.expectedVisualizationRevision,
            resultSelectionOverrides: changedOverrides,
            computeReadLease: fixture.currentMap.computeReadLease)
        #expect(fixture.placeholder.reusingUniqueHydratedGdbIdentity(
            from: [fixture.hydrated], matching: changedResultContext) == nil)
    }
}
