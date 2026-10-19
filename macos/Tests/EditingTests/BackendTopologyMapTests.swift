import Foundation
import Testing
@testable import HECRAS2025
@testable import RASWorkspaceCore

struct BackendTopologyMapTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HECRAS_TOPOLOGY_ACCEPTANCE_DIRECTORY"] != nil)) @MainActor
    func sourceMapCoordinatesAndTagDraftUseTheSameParentSave() async throws {
        let executable = try #require(ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"])
        let fixture = try #require(ProcessInfo.processInfo.environment["HECRAS_TOPOLOGY_ACCEPTANCE_DIRECTORY"])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("topology-map-" + UUID().uuidString)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: fixture), to: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let projectURL = directory.appendingPathComponent("Topology editor.ras")
        let project = try ProjectDocument(contentsOf: projectURL)
        let asset = try #require(project.assets.first { $0.section == .geometries })
        let projectBytes = try Data(contentsOf: projectURL)
        let geometryBytes = try Data(contentsOf: asset.url)
        let client = BackendProcessClient(executableURL: URL(fileURLWithPath: executable))
        let provider = BackendModelProvider(client: client)
        provider.setProject(project)
        let session = ModelEditorSession(provider: provider)
        await session.load(asset, kind: .geometry)
        #expect(session.loaded && session.error == nil)
        await session.ensureGeometryTopologyLoaded()
        let topology = try #require(session.geometryTopology)
        let snapshot = try #require(topology.snapshot)
        let map = try #require(snapshot.map)
        #expect(snapshot.arcs.rows.count == 8 && snapshot.nodes.rows.count == 8)
        #expect(map.extent?.minX == 0 && map.extent?.maxX == 100)
        let region = try #require(map.features.first { $0.geometryType == "polygon" && $0.selectionIDs == ["region:0"] })
        #expect(region.paths.count == 2)
        #expect(region.paths[1].contains { $0.x == 20 && $0.y == 20 })
        let arc = try #require(map.features.first { $0.id == "arc:0" })
        #expect(arc.selectionIDs == ["arc:0"] && arc.fid == 0)
        #expect(arc.paths.first?.first?.x == 0)
        topology.select([arc.id], featureKind: "arc")
        #expect(topology.selectedRows(for: "arc").map(\.fid) == [0])
        let repairedRegion = try #require(snapshot.regions.rows.first { $0.fid == 1 })
        #expect(snapshot.regions.rows.count == 2 && repairedRegion.x == 30 && repairedRegion.y == 30)
        #expect(snapshot.completion?.isComplete == true)
        #expect(session.modified && topology.isDirty)
        #expect(try Data(contentsOf: asset.url) == geometryBytes)

        let description = "GeometrySummaryPage/ViewModel_SelectedGeometryVisualContext_Context_Description"
        session.set(description, "Swift topology and ordinary property draft 🌊")
        await topology.createTag(featureKind: "arc", name: "Swift tag", type: "String")
        await topology.setTag(featureKind: "arc", featureIDs: [0], name: "Swift tag", value: "Source value 中文")
        #expect(topology.error == nil && topology.isDirty && session.modified)
        #expect(try Data(contentsOf: asset.url) == geometryBytes)
        #expect(try Data(contentsOf: projectURL) == projectBytes)

        #expect(await session.saveLoadedModel())
        #expect(session.error == nil && topology.error == nil)
        #expect(!session.modified && !topology.isDirty)
        #expect(try Data(contentsOf: asset.url) != geometryBytes)
        #expect(try Data(contentsOf: projectURL) == projectBytes)
        let reread = try await provider.load(asset, kind: .geometry)
        #expect(reread.fields[description] == "Swift topology and ordinary property draft 🌊")
        let independent = BackendGeometryTopologyProvider(client: client, currentProject: { project })
        let persisted = try await independent.load(independent.modelRequest(for: asset), expectedRevision: reread.sourceRevision)
        #expect(persisted.arcs.rows.first { $0.fid == 0 }?.values["Swift tag"] == "Source value 中文")
        #expect(persisted.map?.features.first { $0.geometryType == "polygon" && $0.selectionIDs == ["region:0"] }?.paths.count == 2)
    }
}
