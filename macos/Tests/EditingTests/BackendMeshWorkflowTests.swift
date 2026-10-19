import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

struct BackendMeshWorkflowTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HECRAS_MESH_ACCEPTANCE_DIRECTORY"] != nil)) @MainActor
    func actualMeshPreviewIncludesTopologyDraftAndSharesTheParentSave() async throws {
        let executable = try #require(ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"])
        let fixture = try #require(ProcessInfo.processInfo.environment["HECRAS_MESH_ACCEPTANCE_DIRECTORY"])
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mesh-workflow-" + UUID().uuidString)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: fixture), to: folder)
        defer { try? FileManager.default.removeItem(at: folder) }
        let projectURL = folder.appendingPathComponent("Mesh editor.ras")
        let project = try ProjectDocument(contentsOf: projectURL)
        let asset = try #require(project.assets.first { $0.section == .geometries })
        let projectBytes = try Data(contentsOf: projectURL)
        let geometryBytes = try Data(contentsOf: asset.url)
        let client = BackendProcessClient(executableURL: URL(fileURLWithPath: executable))
        let provider = BackendModelProvider(client: client)
        provider.setProject(project)
        let parent = ModelEditorSession(provider: provider)
        await parent.load(asset, kind: .geometry)
        await parent.ensureGeometryTopologyLoaded()
        let topology = try #require(parent.geometryTopology)
        await topology.setField(featureKind: "region", fid: 0, fieldID: "PatchType", value: "TrianglePaver")
        await topology.setField(featureKind: "region", fid: 0, fieldID: "ConstantSize", value: "4")
        await topology.setField(featureKind: "region", fid: 0, fieldID: "SecondaryConstantSize", value: "4")
        #expect(topology.error == nil && topology.isDirty)
        await parent.ensureGeometryMeshLoaded()
        let mesh = try #require(parent.geometryMesh)
        #expect(mesh.flowAreas.isEmpty && mesh.error == nil)
        await mesh.generateMesh()
        let preview = try #require(mesh.snapshot)
        #expect(mesh.error == nil && preview.isDirty)
        #expect(preview.generationReport?.meshWasReplaced == true)
        let area = try #require(preview.flowAreas.first)
        #expect(area.cellCount > 0 && area.faceCount > 0)
        await mesh.setFlowAreaField(area, fieldID: "Name", value: "Swift mesh 中文")
        let description = "GeometrySummaryPage/ViewModel_SelectedGeometryVisualContext_Context_Description"
        parent.set(description, "Generated mesh and topology draft saved together")
        #expect(parent.modified && mesh.isDirty && topology.isDirty)
        #expect(try Data(contentsOf: asset.url) == geometryBytes)
        #expect(try Data(contentsOf: projectURL) == projectBytes)

        #expect(await parent.saveLoadedModel())
        #expect(parent.error == nil && mesh.error == nil && topology.error == nil)
        #expect(!parent.modified && !mesh.isDirty && !topology.isDirty)
        let saved = try await provider.load(asset, kind: .geometry)
        #expect(saved.fields[description] == "Generated mesh and topology draft saved together")
        let independent = BackendGeometryMeshProvider(client: client, currentProject: { project })
        let reread = try await independent.load(independent.modelRequest(for: asset),
            expectedRevision: saved.sourceRevision, draftState: nil,
            topologyDraftState: nil, selectedRegionIDs: [])
        #expect(reread.flowAreas.count == 1)
        #expect(reread.flowAreas.first?.name == "Swift mesh 中文")
        #expect(reread.flowAreas.first?.cellCount == area.cellCount)
        #expect(reread.flowAreas.first?.faceCount == area.faceCount)
        #expect(try Data(contentsOf: asset.url) != geometryBytes)
        #expect(try Data(contentsOf: projectURL) == projectBytes)

        let savedGeometry = try Data(contentsOf: asset.url)
        parent.set(description, "Retain this draft when source Prepare fails")
        #expect(await mesh.requestPrepare())
        #expect(mesh.preparePending && parent.modified)
        #expect(!(await parent.saveLoadedModel()))
        #expect(parent.error != nil && mesh.preparePending && mesh.isDirty && parent.modified)
        #expect(parent.fields[description] == "Retain this draft when source Prepare fails")
        #expect(try Data(contentsOf: asset.url) == savedGeometry)
        #expect(try Data(contentsOf: projectURL) == projectBytes)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HECRAS_MESH_PREPARE_ACCEPTANCE_DIRECTORY"] != nil)) @MainActor
    func actualSourcePreparePublishesPropertyTablesWithEveryGeometryDraftInOneSave() async throws {
        let executable = try #require(ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"])
        let fixture = try #require(ProcessInfo.processInfo.environment["HECRAS_MESH_PREPARE_ACCEPTANCE_DIRECTORY"])
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mesh-prepare-workflow-" + UUID().uuidString)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: fixture), to: folder)
        defer { try? FileManager.default.removeItem(at: folder) }
        let projectURL = folder.appendingPathComponent("Prepared geometry.ras")
        let project = try ProjectDocument(contentsOf: projectURL)
        let asset = try #require(project.assets.first { $0.section == .geometries })
        let projectBytes = try Data(contentsOf: projectURL)
        let originalGeometry = try Data(contentsOf: asset.url)
        let client = BackendProcessClient(executableURL: URL(fileURLWithPath: executable))
        let provider = BackendModelProvider(client: client)
        provider.setProject(project)
        let parent = ModelEditorSession(provider: provider)
        await parent.load(asset, kind: .geometry)
        await parent.ensureGeometryTopologyLoaded()
        let topology = try #require(parent.geometryTopology)
        await topology.setField(featureKind: "region", fid: 0, fieldID: "PatchType", value: "TrianglePaver")
        await topology.setField(featureKind: "region", fid: 0, fieldID: "ConstantSize", value: "4")
        await topology.setField(featureKind: "region", fid: 0, fieldID: "SecondaryConstantSize", value: "4")
        await parent.ensureGeometryMeshLoaded()
        let mesh = try #require(parent.geometryMesh)
        await mesh.generateMesh()
        let area = try #require(mesh.flowAreas.first)
        await mesh.setFlowAreaField(area, fieldID: "Name", value: "Prepared flow area 中文")
        let description = "GeometrySummaryPage/ViewModel_SelectedGeometryVisualContext_Context_Description"
        parent.set(description, "All geometry drafts reach source Prepare")
        #expect(await mesh.requestPrepare())
        #expect(mesh.preparePending && mesh.snapshot?.prepareSummary == nil)
        #expect(try Data(contentsOf: asset.url) == originalGeometry)
        #expect(await parent.saveLoadedModel())
        #expect(parent.error == nil && !parent.modified && !mesh.preparePending)
        let saved = try await provider.load(asset, kind: .geometry)
        #expect(saved.fields[description] == "All geometry drafts reach source Prepare")
        let independent = BackendGeometryMeshProvider(client: client, currentProject: { project })
        let reread = try await independent.load(independent.modelRequest(for: asset),
            expectedRevision: saved.sourceRevision, draftState: nil, topologyDraftState: nil, selectedRegionIDs: [])
        #expect(reread.prepareSummary?.succeeded == true)
        #expect(reread.flowAreas.first?.hasPropertyTables == true)
        #expect(reread.flowAreas.first?.name == "Prepared flow area 中文")
        #expect(try Data(contentsOf: asset.url) != originalGeometry)
        #expect(try Data(contentsOf: projectURL) == projectBytes)
    }
}
