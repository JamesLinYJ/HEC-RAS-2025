import Foundation
import Testing
@testable import HECRAS2025
@testable import RASWorkspaceCore

struct BackendCulvertWorkflowTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HECRAS_CULVERT_ACCEPTANCE_DIRECTORY"] != nil)) @MainActor
    func sourceCulvertProfileAndPropertyDraftUseTheParentHDFSave() async throws {
        let executable = try #require(ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"])
        let fixture = try #require(ProcessInfo.processInfo.environment["HECRAS_CULVERT_ACCEPTANCE_DIRECTORY"])
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("culvert-workflow-" + UUID().uuidString)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: fixture), to: folder)
        defer { try? FileManager.default.removeItem(at: folder) }
        let projectURL = folder.appendingPathComponent("Culvert source.ras")
        let project = try ProjectDocument(contentsOf: projectURL)
        let asset = try #require(project.assets.first { $0.section == .geometries })
        let originalProject = try Data(contentsOf: projectURL)
        let originalGeometry = try Data(contentsOf: asset.url)
        let rasterURL = folder.appendingPathComponent("terrain-a.tif")
        let originalRaster = try Data(contentsOf: rasterURL)
        let client = BackendProcessClient(executableURL: URL(fileURLWithPath: executable))
        let provider = BackendModelProvider(client: client)
        provider.setProject(project)
        let parent = ModelEditorSession(provider: provider)
        await parent.load(asset, kind: .geometry)
        #expect(parent.loaded && parent.error == nil)
        await parent.ensureGeometryCulvertLoaded()
        let child = try #require(parent.geometryCulvert)
        let barrel = try #require(child.snapshot?.barrels.rows.first)
        await child.select([barrel.id], featureKind: "barrel")
        let profile = try #require(child.snapshot?.profiles.first)
        #expect(profile.samples.count > 1)
        #expect(profile.samples.allSatisfy { abs($0.elevation - 42) < 0.0001 })
        #expect(child.snapshot?.associatedTerrainName == "Culvert Terrain A")
        #expect(!parent.modified && !child.isDirty)

        await child.setField(featureKind: "barrel", fieldID: "Name", value: "Swift 涵洞")
        let reshaped: [GeometryCulvertCoordinate] = [.init(x: 1, y: 1), .init(x: 8, y: 10), .init(x: 15, y: 1)]
        #expect(await child.setPolyline(id: barrel.id, points: reshaped))
        #expect(child.snapshot?.barrels.rows.first?.polyline == reshaped)
        let reshapedProfile = try #require(child.snapshot?.profiles.first)
        #expect(reshapedProfile.length > profile.length)
        #expect(reshapedProfile.samples.contains { $0.y > 9.9 })
        #expect(reshapedProfile.samples.allSatisfy { abs($0.elevation - 42) < 0.0001 })
        let drawn: [GeometryCulvertCoordinate] = [.init(x: 2, y: 2), .init(x: 10, y: 2)]
        let temporaryBarrelID = try #require(await child.addBarrel(points: drawn))
        #expect(child.snapshot?.barrels.rows.contains { $0.id == temporaryBarrelID } == true)
        #expect(await child.undoLastEdit())
        #expect(child.snapshot?.barrels.rows.contains { $0.id == temporaryBarrelID } == false)
        let persistentBarrelID = try #require(await child.addBarrel(points: drawn))
        #expect(child.snapshot?.profiles.first?.barrelID == persistentBarrelID)
        await child.addPropertySet(featureKind: "barrelProperties")
        let added = try #require(child.snapshot?.barrelProperties.rows.first { $0.id.contains(":draft:") })
        await child.select([added.id], featureKind: "barrelProperties")
        await child.setField(featureKind: "barrelProperties", fieldID: "Name", value: "Swift barrel type")
        let description = "GeometrySummaryPage/ViewModel_SelectedGeometryVisualContext_Context_Description"
        parent.set(description, "Culvert and ordinary draft together")
        #expect(parent.modified && child.isDirty && child.error == nil)
        #expect(try Data(contentsOf: asset.url) == originalGeometry)
        #expect(try Data(contentsOf: projectURL) == originalProject)
        #expect(try Data(contentsOf: rasterURL) == originalRaster)

        #expect(await parent.saveLoadedModel())
        #expect(parent.error == nil && child.error == nil)
        #expect(!parent.modified && !child.isDirty)
        let saved = try await provider.load(asset, kind: .geometry)
        #expect(saved.fields[description] == "Culvert and ordinary draft together")
        let independent = BackendGeometryCulvertProvider(client: client, currentProject: { project })
        let reread = try await independent.load(independent.modelRequest(for: asset),
            expectedRevision: saved.sourceRevision, draftState: nil, selectedBarrelIDs: [])
        #expect(reread.barrels.rows.first?.values["Name"] == "Swift 涵洞")
        #expect(reread.barrels.rows.count == 2)
        #expect(reread.barrels.rows.first?.polyline == reshaped)
        #expect(reread.barrels.rows.last?.polyline == drawn)
        #expect(reread.barrelProperties.rows.contains { $0.values["Name"] == "Swift barrel type" })
        #expect(try Data(contentsOf: asset.url) != originalGeometry)
        #expect(try Data(contentsOf: projectURL) == originalProject)
        #expect(try Data(contentsOf: rasterURL) == originalRaster)
    }
}
