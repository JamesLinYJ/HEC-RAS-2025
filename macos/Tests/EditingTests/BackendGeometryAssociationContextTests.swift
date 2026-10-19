import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

struct BackendGeometryAssociationContextTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HECRAS_MESH_PREPARE_ACCEPTANCE_DIRECTORY"] != nil
        && ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"] != nil)) @MainActor
    func projectAssociationRefreshPreservesRealGeometryDraftAndLeavesProjectXMLUnsaved() async throws {
        let executable = try #require(ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"])
        let fixturePath = try #require(ProcessInfo.processInfo.environment["HECRAS_MESH_PREPARE_ACCEPTANCE_DIRECTORY"])
        let fixture = URL(fileURLWithPath: fixturePath, isDirectory: true).standardizedFileURL
        var isDirectory: ObjCBool = false
        let fixtureExistsAsDirectory = FileManager.default.fileExists(atPath: fixture.path, isDirectory: &isDirectory)
        #expect(fixtureExistsAsDirectory && isDirectory.boolValue)

        let fixtureProjectURL = fixture.appendingPathComponent("Prepared geometry.ras")
        let fixtureProjectBytes = try Data(contentsOf: fixtureProjectURL)
        let fixtureProject = try ProjectDocument(contentsOf: fixtureProjectURL)
        let fixtureGeometry = try #require(fixtureProject.assets.first { $0.section == .geometries })
        #expect(fixtureGeometry.url.standardizedFileURL.path.hasPrefix(fixture.path + "/"))
        let fixtureGeometryBytes = try Data(contentsOf: fixtureGeometry.url)

        // All mutations are made in a unique disposable copy. Refuse to reuse
        // an existing path so a stale test artifact can never be overwritten.
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("geometry-association-context-" + UUID().uuidString, isDirectory: true)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        try FileManager.default.copyItem(at: fixture, to: folder)
        defer { try? FileManager.default.removeItem(at: folder) }

        let projectURL = folder.appendingPathComponent("Prepared geometry.ras")
        let initialProjectBytes = try Data(contentsOf: projectURL)
        let projectBeforeOpen = try ProjectDocument(contentsOf: projectURL)
        let assetBeforeOpen = try #require(projectBeforeOpen.assets.first { $0.section == .geometries })
        #expect(assetBeforeOpen.url.standardizedFileURL.path.hasPrefix(folder.standardizedFileURL.path + "/"))
        let initialGeometryBytes = try Data(contentsOf: assetBeforeOpen.url)

        let client = BackendProcessClient(executableURL: URL(fileURLWithPath: executable))
        let backend = BackendModelProvider(client: client)
        let services = SourceWorkflowFixtureServices(recoveryFolder: folder.appendingPathComponent("Recovery"))
        let store = WorkspaceStore(system: services, modelProvider: backend)
        store.requestOpen(projectURL)
        let openDeadline = ContinuousClock.now.advanced(by: .seconds(15))
        while store.isOpeningProject && ContinuousClock.now < openDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!store.isOpeningProject)

        let document = try #require(store.document)
        #expect(document.url?.standardizedFileURL == projectURL.standardizedFileURL)
        let asset = try #require(store.assets.first { $0.section == .geometries })
        #expect(asset.url.standardizedFileURL.path.hasPrefix(folder.standardizedFileURL.path + "/"))
        #expect(try Data(contentsOf: asset.url) == initialGeometryBytes)
        #expect(try Data(contentsOf: projectURL) == initialProjectBytes)

        let parent = store.primaryEditorSession(.geometry)
        store.openEditor(.geometry, assetID: asset.id)
        await parent.load(asset, kind: .geometry)
        #expect(parent.loaded && parent.error == nil)

        // Create a real topology + mesh child draft using the same source
        // operation exercised by the mesh-prepare acceptance fixture.
        await parent.ensureGeometryTopologyLoaded()
        let topology = try #require(parent.geometryTopology)
        await topology.setField(featureKind: "region", fid: 0, fieldID: "PatchType", value: "TrianglePaver")
        await topology.setField(featureKind: "region", fid: 0, fieldID: "ConstantSize", value: "4")
        await topology.setField(featureKind: "region", fid: 0, fieldID: "SecondaryConstantSize", value: "4")
        #expect(topology.error == nil && topology.isDirty)

        await parent.ensureGeometryMeshLoaded()
        let mesh = try #require(parent.geometryMesh)
        #expect(mesh.error == nil && mesh.flowAreas.isEmpty)
        await mesh.generateMesh()
        #expect(mesh.error == nil && mesh.isDirty)
        let generatedArea = try #require(mesh.flowAreas.first)
        let draftAreaName = "Association refresh flow area 中文"
        await mesh.setFlowAreaField(generatedArea, fieldID: "Name", value: draftAreaName)
        #expect(mesh.flowAreas.first(where: { $0.id == generatedArea.id })?.name == draftAreaName)

        let descriptionField = "GeometrySummaryPage/ViewModel_SelectedGeometryVisualContext_Context_Description"
        let descriptionDraft = "Association refresh retains the ordinary geometry draft"
        parent.set(descriptionField, descriptionDraft)
        #expect(parent.modified && parent.fields[descriptionField] == descriptionDraft)

        await parent.ensureGeometryCulvertLoaded()
        let culvert = try #require(parent.geometryCulvert)
        #expect(culvert.error == nil && culvert.snapshot != nil)

        let beforeRow = try #require(document.associationRows(group: "GeometryAssociations")
            .first { $0.name == asset.name })
        let previousTerrain = beforeRow.fields["Terrain"] ?? ""
        // The source Project.Terrains collection loads HDF Terrain models;
        // TIFFs in the same directory are raster inputs, not association targets.
        let terrainAssets = store.assets.filter {
            $0.section == .terrains && $0.url.pathExtension.lowercased() == "h5"
        }
        let terrainNames = terrainAssets.map(\.name)
        #expect(terrainAssets.contains { $0.name == previousTerrain })
        #expect(terrainAssets.allSatisfy {
            $0.url.standardizedFileURL.path.hasPrefix(folder.standardizedFileURL.path + "/")
        })
        let newTerrain: String
        if let differentExistingTerrain = terrainNames.first(where: { $0 != previousTerrain }) {
            // Use a real terrain asset from this copied project.
            newTerrain = differentExistingTerrain
        } else if !previousTerrain.isEmpty {
            // An empty association is the source's explicit nil selection;
            // it must not be silently replaced with the project default.
            newTerrain = ""
        } else {
            newTerrain = try #require(terrainNames.first,
                "The mesh-prepare fixture needs a real terrain asset to exercise a changed Geometry-to-Terrain association.")
        }
        #expect(newTerrain != previousTerrain)

        let meshLedger = try #require(mesh.geometryMeshStateForParentSave)
        let topologyLedger = try #require(topology.topologyStateForParentSave)
        let originalCulvertIdentity = culvert.geometryCulvertIdentity
        let capturedFlowAreaID = generatedArea.id
        store.setAssociation(beforeRow, field: "Terrain", value: newTerrain)

        #expect(store.isModified)
        #expect(store.document?.associationRows(group: "GeometryAssociations")
            .first { $0.name == asset.name }?.fields["Terrain"] == newTerrain)
        #expect(try Data(contentsOf: asset.url) == initialGeometryBytes)
        #expect(try Data(contentsOf: projectURL) == initialProjectBytes)

        let refreshDeadline = ContinuousClock.now.advanced(by: .seconds(30))
        while parent.isPerforming && ContinuousClock.now < refreshDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!parent.isPerforming)
        #expect(parent.error == nil)
        #expect(mesh.error == nil && mesh.isDirty)
        #expect(mesh.geometryMeshStateForParentSave == meshLedger)
        #expect(mesh.flowAreas.first(where: { $0.id == capturedFlowAreaID })?.name == draftAreaName)
        #expect(topology.error == nil && topology.isDirty)
        #expect(topology.topologyStateForParentSave == topologyLedger)
        #expect(parent.modified && parent.fields[descriptionField] == descriptionDraft)
        #expect(culvert.error == nil)
        #expect(culvert.geometryCulvertIdentity != originalCulvertIdentity)
        #expect(culvert.snapshot?.associatedTerrainName == (newTerrain.isEmpty ? nil : newTerrain))

        // Before the HDF save, both original and copied source bytes must still
        // be unchanged. Then the parent's real save writes all HDF drafts once,
        // while the independent Project XML association remains only in memory.
        #expect(try Data(contentsOf: asset.url) == initialGeometryBytes)
        #expect(try Data(contentsOf: projectURL) == initialProjectBytes)
        #expect(await parent.saveLoadedModel())
        #expect(parent.error == nil && mesh.error == nil && topology.error == nil)
        #expect(!parent.modified && !mesh.isDirty && !topology.isDirty)
        #expect(store.isModified)
        #expect(try Data(contentsOf: projectURL) == initialProjectBytes)
        #expect(try Data(contentsOf: asset.url) != initialGeometryBytes)

        let savedModel = try await backend.load(asset, kind: .geometry)
        #expect(savedModel.fields[descriptionField] == descriptionDraft)
        let diskProject = try ProjectDocument(contentsOf: projectURL)
        #expect(diskProject.associationRows(group: "GeometryAssociations")
            .first { $0.name == asset.name }?.fields["Terrain"] == previousTerrain)
        let independentMeshProvider = BackendGeometryMeshProvider(client: client, currentProject: { diskProject })
        let rereadMesh = try await independentMeshProvider.load(independentMeshProvider.modelRequest(for: asset),
            expectedRevision: savedModel.sourceRevision, draftState: nil,
            topologyDraftState: nil, selectedRegionIDs: [])
        #expect(rereadMesh.flowAreas.contains { $0.name == draftAreaName })

        // The test never opens or mutates the fixture in place.
        #expect(try Data(contentsOf: fixtureProjectURL) == fixtureProjectBytes)
        #expect(try Data(contentsOf: fixtureGeometry.url) == fixtureGeometryBytes)
    }
}
