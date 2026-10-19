import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

struct MapGeometryIdentityTests {
    @Test @MainActor
    func geometryMapTypeStaysDistinctFromSidebarGeometryModeAndDuplicateNamesRemainIsolated() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GeometryMapIdentity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let projectURL = directory.appendingPathComponent("Identity.ras")
        let project = try ProjectDocument(name: "Identity", units: "SI")
        try project.save(to: projectURL)
        let visualXML = """
        <Ras>
          <Maps Maps="Identity">
            <Map Name="Shared" Type="Project"><Tree><Nodes/></Tree></Map>
            <Map Name="Shared" Type="Geometry"><Tree><Nodes/></Tree></Map>
            <Map Name="Shared" Type="Buildable"><Tree><Nodes/></Tree></Map>
            <Map Name="Shared" Type="Geometry"><Tree><Nodes/></Tree></Map>
          </Maps>
          <Symbology><VendorExtension Keep="true"/></Symbology>
          <Views/>
          <VendorRoot Keep="true"/>
        </Ras>
        """
        let visualURL = projectURL.deletingPathExtension().appendingPathExtension("vis")
        try Data(visualXML.utf8).write(to: visualURL)

        let parsed = try VisualizationDocument(projectURL: projectURL)
        #expect(parsed.maps == [
            VisualizationMapIdentity(index: 0, name: "Shared", type: "Project"),
            VisualizationMapIdentity(index: 1, name: "Shared", type: "Geometry"),
            VisualizationMapIdentity(index: 2, name: "Shared", type: "Buildable"),
            VisualizationMapIdentity(index: 3, name: "Shared", type: "Geometry")
        ])

        let store = WorkspaceStore(system: GeometryMapIdentityFixtureServices())
        store.requestOpen(projectURL)
        try await waitForOpen(store)

        let maps = store.catalogMapDocuments.sorted { ($0.sourceIndex ?? -1) < ($1.sourceIndex ?? -1) }
        #expect(maps.map(\.kind) == ["Project", "Geometry", "Buildable", "Geometry"])
        #expect(maps.map(\.name) == Array(repeating: "Shared", count: 4))
        #expect(maps.map(\.sourceIndex) == [0, 1, 2, 3])
        #expect(Set(maps.map(\.id)).count == 4)

        let projectMap = try #require(store.mapDocument(for: MapState.projectMapID))
        let firstGeometryMap = try #require(store.mapDocuments.first { $0.sourceType == "Geometry" })
        let buildableMap = try #require(store.mapDocuments.first { $0.sourceType == "Buildable" })
        let lastGeometryMap = try #require(store.mapDocuments.last { $0.sourceType == "Geometry" })
        #expect(projectMap.kind == .project && projectMap.sourceType == "Project")
        #expect(firstGeometryMap.kind == .geometry && firstGeometryMap.sourceType == "Geometry")
        #expect(buildableMap.kind == .buildable && buildableMap.sourceType == "Buildable")
        #expect(lastGeometryMap.kind == .geometry && lastGeometryMap.sourceType == "Geometry")
        #expect(firstGeometryMap.id != lastGeometryMap.id)

        // The sidebar filter and a saved Geometry map are separate concepts.
        #expect(store.treeMode == .project)
        store.treeMode = .geometry
        #expect(store.treeMode == .geometry)
        #expect(store.mapDocument(for: firstGeometryMap.id)?.kind == .geometry)

        let firstState = store.mapState(for: firstGeometryMap.id)
        let lastState = store.mapState(for: lastGeometryMap.id)
        firstState.currentExtent = .init(lowerLeft: .init(x: 1, y: 2), upperRight: .init(x: 5, y: 8))
        firstState.hiddenLayers = ["source-vector/first-map/node-a"]
        firstState.selectedFeatureIdentity = "feature:first"
        lastState.currentExtent = .init(lowerLeft: .init(x: 20, y: 30), upperRight: .init(x: 40, y: 60))
        lastState.hiddenLayers = ["source-vector/second-map/node-a"]
        lastState.selectedFeatureIdentity = "feature:second"

        #expect(firstState.id != lastState.id)
        #expect(firstState.currentExtent?.lowerLeft == MapPoint(x: 1, y: 2))
        #expect(lastState.currentExtent?.lowerLeft == MapPoint(x: 20, y: 30))
        #expect(firstState.hiddenLayers != lastState.hiddenLayers)
        #expect(firstState.selectedFeatureIdentity == "feature:first")
        #expect(lastState.selectedFeatureIdentity == "feature:second")
        #expect(store.mapState(for: MapState.projectMapID).currentExtent == nil)
        #expect(store.mapState(for: buildableMap.id).currentExtent == nil)
    }

    @MainActor
    private func waitForOpen(_ store: WorkspaceStore) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while (store.document == nil || store.isOpeningProject) && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!store.isOpeningProject)
        #expect(store.document != nil)
    }
}

@MainActor
private final class GeometryMapIdentityFixtureServices: WorkspaceSystemServices {
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
