import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

struct VisualizationMapRoutingTests {
    @Test @MainActor
    func openedVisualizationMapsKeepDuplicateNamesAndRouteToTheCorrectTabs() async throws {
        let fixture = try makeProjectWithVisualizationMaps()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        // Read the fixture through the native .vis adapter before exercising the store.
        let visualization = try VisualizationDocument(projectURL: fixture.projectURL)
        #expect(visualization.maps == [
            VisualizationMapIdentity(index: 0, name: "Repeated Map", type: "Project"),
            VisualizationMapIdentity(index: 1, name: "Repeated Map", type: "Plan"),
            VisualizationMapIdentity(index: 2, name: "Repeated Map", type: "Buildable")
        ])

        let store = WorkspaceStore(system: MapRoutingFixtureServices())
        store.requestOpen(fixture.projectURL)
        try await waitForOpen(store)

        let projectMap = try #require(store.mapDocument(for: MapState.projectMapID))
        let planMap = try #require(store.mapDocuments.first { $0.sourceType == "Plan" })
        let buildableMap = try #require(store.mapDocuments.first { $0.sourceType == "Buildable" })
        #expect(projectMap.id == MapState.projectMapID)
        #expect(projectMap.name == "Repeated Map" && projectMap.sourceType == "Project")
        #expect(projectMap.kind == .project)
        #expect(planMap.id != MapState.projectMapID && planMap.name == "Repeated Map")
        #expect(planMap.sourceType == "Plan" && planMap.kind == .plan)
        #expect(buildableMap.id != MapState.projectMapID && buildableMap.id != planMap.id)
        #expect(buildableMap.name == "Repeated Map")
        #expect(buildableMap.sourceType == "Buildable" && buildableMap.kind == .buildable)
        #expect(store.mapDocuments.count == 2)
        #expect(!store.mapDocuments.contains { $0.id == MapState.projectMapID })
        #expect(store.activeTab == .page(.map))
        #expect(store.lastActiveMapID == MapState.projectMapID)

        store.openMapDocument(planMap)
        #expect(store.activeTab == .map(planMap.id))
        #expect(store.lastActiveMapID == planMap.id)
        store.openMapDocument(buildableMap)
        #expect(store.activeTab == .map(buildableMap.id))
        #expect(store.lastActiveMapID == buildableMap.id)

        // The zero-UUID source Project map is represented by the existing Map page,
        // so opening it cannot add a duplicate map tab/document.
        store.openMapDocument(projectMap)
        #expect(store.activeTab == .page(.map))
        #expect(store.lastActiveMapID == MapState.projectMapID)
        #expect(store.mapDocuments.count == 2)
        #expect(store.mapDocuments.map(\.id) == [planMap.id, buildableMap.id])
    }

    @Test @MainActor
    func rasterPixelsAndCoordinatesAreScopedToTheirSourceMapAndBuildableMembership() async throws {
        let fixture = try makeProjectWithVisualizationMaps()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let store = WorkspaceStore(system: MapRoutingFixtureServices())
        store.requestOpen(fixture.projectURL)
        try await waitForOpen(store)

        let projectID = MapState.projectMapID
        let planID = try #require(store.mapDocuments.first { $0.sourceType == "Plan" }?.id)
        let buildableID = try #require(store.mapDocuments.first { $0.sourceType == "Buildable" }?.id)
        let projectState = store.mapState(for: projectID)
        let planState = store.mapState(for: planID)
        let buildableState = store.mapState(for: buildableID)

        let sharedPreview = try raster("legacy-preview", rgba: [8, 8, 8, 255],
            lowerLeft: MapPoint(x: -1, y: -1), upperRight: MapPoint(x: 1, y: 1))
        let projectRaster = try raster("project-raster", sourceMapID: projectID, rgba: [255, 0, 0, 255],
            lowerLeft: MapPoint(x: 10, y: 20), upperRight: MapPoint(x: 30, y: 40))
        let planRaster = try raster("plan-raster", sourceMapID: planID, rgba: [0, 0, 255, 255],
            lowerLeft: MapPoint(x: 100, y: 200), upperRight: MapPoint(x: 300, y: 400))
        let buildableRaster = try raster("buildable-raster", sourceMapID: buildableID, rgba: [0, 255, 0, 255],
            lowerLeft: MapPoint(x: 1000, y: 2000), upperRight: MapPoint(x: 3000, y: 4000))
        let sharedLayers = [sharedPreview, projectRaster, planRaster, buildableRaster]

        let projectRasters = projectState.rasters(sharedLayers)
        let planRasters = planState.rasters(sharedLayers)
        #expect(projectRasters.map(\.id) == [sharedPreview.id, projectRaster.id])
        #expect(planRasters.map(\.id) == [sharedPreview.id, planRaster.id])
        #expect(projectRasters.last?.rgba == Data([255, 0, 0, 255]))
        #expect(projectRasters.last?.lowerLeft == MapPoint(x: 10, y: 20))
        #expect(projectRasters.last?.upperRight == MapPoint(x: 30, y: 40))
        #expect(planRasters.last?.rgba == Data([0, 0, 255, 255]))
        #expect(planRasters.last?.lowerLeft == MapPoint(x: 100, y: 200))
        #expect(planRasters.last?.upperRight == MapPoint(x: 300, y: 400))

        #expect(buildableState.rasters(sharedLayers).isEmpty)
        store.includeMapLayer(buildableRaster.id, in: buildableID)
        store.includeMapLayer(planRaster.id, in: buildableID)
        let buildableRasters = buildableState.rasters(sharedLayers)
        #expect(buildableRasters.map(\.id) == [buildableRaster.id])
        #expect(buildableRasters.first?.rgba == Data([0, 255, 0, 255]))
        #expect(buildableRasters.first?.lowerLeft == MapPoint(x: 1000, y: 2000))
        #expect(buildableRasters.first?.upperRight == MapPoint(x: 3000, y: 4000))
        #expect(projectState.includedLayerIDs.isEmpty && planState.includedLayerIDs.isEmpty)
        #expect(buildableState.includedLayerIDs == [buildableRaster.id, planRaster.id])
    }

    @MainActor
    private func waitForOpen(_ store: WorkspaceStore) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while store.isOpeningProject && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(!store.isOpeningProject)
        #expect(store.document != nil)
    }

    private func makeProjectWithVisualizationMaps() throws -> (directory: URL, projectURL: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VisualizationMapRouting-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let projectURL = directory.appendingPathComponent("Routing.ras")
        let project = try ProjectDocument(name: "Routing", units: "SI")
        try project.save(to: projectURL)

        let visualXML = """
        <Ras>
          <Maps Maps="Routing">
            <Map Name="Repeated Map" Type="Project"><Tree><Nodes/></Tree></Map>
            <Map Name="Repeated Map" Type="Plan"><Tree><Nodes/></Tree></Map>
            <Map Name="Repeated Map" Type="Buildable"><Tree><Nodes/></Tree></Map>
          </Maps>
          <Symbology/>
          <Views/>
        </Ras>
        """
        try Data(visualXML.utf8).write(to: directory.appendingPathComponent("Routing.vis"))
        return (directory, projectURL)
    }

    private func raster(_ id: String, sourceMapID: UUID? = nil, rgba: [UInt8],
                        lowerLeft: MapPoint, upperRight: MapPoint) throws -> MapRasterLayer {
        try MapRasterLayer(id: id, name: id, width: 1, height: 1, rgba: Data(rgba),
            lowerLeft: lowerLeft, upperRight: upperRight, sourceMapID: sourceMapID)
    }
}

@MainActor
private final class MapRoutingFixtureServices: WorkspaceSystemServices {
    func chooseProject() -> URL? { nil }
    func authorizeProjectFolder(for input: URL) -> URL? { input }
    func chooseProjectDestination(name: String) -> URL? { nil }
    func chooseFolder(title: String) -> URL? { nil }
    func chooseVectorLayer() -> URL? { nil }
    func chooseConnectionFile() -> URL? { nil }
    func chooseInputFiles() -> [URL] { [] }
    func chooseImageFiles() -> [URL] { [] }
    func chooseProjectionFile() -> URL? { nil }
    func reveal(_ url: URL) {}
    func copy(_ text: String) {}
    func openWebsite(_ url: URL) {}
}
