import CryptoKit
import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

private struct GeometryTopologyToolFixtureManifest: Decodable {
    let fixtureVersion: String
    let projectRelativePath: String
    let projectSHA256: String
    let geometryRelativePath: String
    let geometrySHA256: String
    let geometryName: String
    let arcFIDs: [Int]
    let controlPointFIDs: [Int]
    let nodeFIDs: [Int]
    let sharedEndpointNodeFID: Int
    let sharedEndpointArcFIDs: [Int]
    let internalPointArcFID: Int
    let internalPointIndex: Int
    let filterTagNames: [String: String]
    let recipeControlPointFIDs: [Int]
}

@Suite(.serialized)
struct BackendGeometryTopologyToolWorkflowTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HECRAS_TOPOLOGY_TOOLS_ACCEPTANCE_DIRECTORY"] != nil
        && ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"] != nil)) @MainActor
    func realProviderRunsFactorRecipeArcPointAndFilterThroughParentSaveAndReopen() async throws {
        let environment = ProcessInfo.processInfo.environment
        let fixturePath = try #require(environment["HECRAS_TOPOLOGY_TOOLS_ACCEPTANCE_DIRECTORY"])
        let executable = try #require(environment["HECRAS_BACKEND_TEST_EXECUTABLE"])
        let fixture = URL(fileURLWithPath: fixturePath, isDirectory: true)
        let workingCopy = FileManager.default.temporaryDirectory
            .appendingPathComponent("topology-tools-workflow-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.copyItem(at: fixture, to: workingCopy)
        defer { try? FileManager.default.removeItem(at: workingCopy) }

        let manifest = try JSONDecoder().decode(GeometryTopologyToolFixtureManifest.self,
            from: Data(contentsOf: workingCopy.appendingPathComponent("manifest.json")))
        #expect(manifest.fixtureVersion == "round23-topology-tools-v1")
        let projectURL = workingCopy.appendingPathComponent(manifest.projectRelativePath)
        let geometryURL = workingCopy.appendingPathComponent(manifest.geometryRelativePath)
        #expect(topologyToolsSHA256(try Data(contentsOf: projectURL)) == manifest.projectSHA256.uppercased())
        #expect(topologyToolsSHA256(try Data(contentsOf: geometryURL)) == manifest.geometrySHA256.uppercased())
        #expect(!manifest.arcFIDs.isEmpty && !manifest.controlPointFIDs.isEmpty && !manifest.nodeFIDs.isEmpty)
        #expect(manifest.sharedEndpointArcFIDs.count >= 2)
        #expect(manifest.recipeControlPointFIDs.count >= 2)

        let project = try ProjectDocument(contentsOf: projectURL)
        let asset = try #require(project.assets.first {
            $0.section == .geometries && $0.url.standardizedFileURL == geometryURL.standardizedFileURL
        })
        #expect(asset.name == manifest.geometryName)
        let sourceProjectBytes = try Data(contentsOf: projectURL)
        let sourceGeometryBytes = try Data(contentsOf: geometryURL)

        let client = BackendProcessClient(executableURL: URL(fileURLWithPath: executable))
        let modelProvider = BackendModelProvider(client: client)
        modelProvider.setProject(project)
        let topologyProvider = BackendGeometryTopologyProvider(client: client, currentProject: { project })
        let editor = ModelEditorSession(provider: modelProvider, topologyProvider: topologyProvider)
        await editor.load(asset, kind: .geometry)
        #expect(editor.loaded && editor.error == nil)
        await editor.ensureGeometryTopologyLoaded()
        let topology = try #require(editor.geometryTopology)
        let initial = try #require(topology.snapshot)
        #expect(initial.revision.uppercased() == manifest.geometrySHA256.uppercased())
        #expect(Set(initial.arcs.rows.map(\.fid)) == Set(manifest.arcFIDs))
        #expect(Set(initial.regions.rows.map(\.fid)) == Set(manifest.controlPointFIDs))
        #expect(Set(initial.nodes.rows.map(\.fid)) == Set(manifest.nodeFIDs))
        #expect(try Data(contentsOf: geometryURL) == sourceGeometryBytes)

        // Factor is passed as source text; one undo and redo must restore the
        // same source-backed rows without touching the HDF before parent save.
        let firstArc = try #require(initial.arcs.rows.first)
        let sourceArcSize = try #require(Double(firstArc.values["ConstantSize"] ?? ""))
        await topology.applyFactor(factorText: "2", selectedOnly: false)
        let factoredSize = try #require(Double(topology.snapshot?.arcs.rows.first?.values["ConstantSize"] ?? ""))
        #expect(factoredSize == sourceArcSize * 2)
        #expect(topology.canUndo && topology.isDirty)
        await topology.undo()
        #expect(topology.canRedo)
        #expect(topology.snapshot?.arcs.rows.first?.values["ConstantSize"] == firstArc.values["ConstantSize"])
        await topology.redo()
        #expect(topology.canUndo)
        #expect(Double(topology.snapshot?.arcs.rows.first?.values["ConstantSize"] ?? "") == factoredSize)

        // Recipe query and explicit Force Set use the retained parser and exact
        // selected source FIDs. The source fixture's valid Smooth() is retained.
        let recipeFIDs = manifest.recipeControlPointFIDs
        await topology.loadRecipe(controlPointFIDs: recipeFIDs)
        #expect(topology.recipeEditorState?.inspection?.controlPointFIDs == recipeFIDs)
        #expect(topology.updateRecipeInput("Smooth()", controlPointFIDs: recipeFIDs))
        await topology.inspectRecipe(controlPointFIDs: recipeFIDs, rawText: "Smooth()")
        #expect(topology.recipeEditorState?.inspection?.isValid == true)
        await topology.applyRecipe(controlPointFIDs: recipeFIDs, forceSet: true)
        #expect(topology.snapshot?.canUndo == true)
        await topology.loadRecipe(controlPointFIDs: recipeFIDs)
        #expect(topology.recipeEditorState?.inspection?.selectedRecipes.allSatisfy { $0.recipe == "Smooth()" } == true)

        // The R Arc editor reports Default for a mixed Constrain Stretching or
        // Laplace BC aggregate. Choosing that displayed Default is a no-op in
        // the ordinary aggregate setter, so these commands must reach the
        // dedicated multi-row ForceSet path through the real bundled Host.
        let forceSetArcRows = Array(initial.arcs.rows.prefix(2))
        #expect(forceSetArcRows.count == 2)
        let forceSetArcIDs = forceSetArcRows.map(\.id)
        let forceSetArcFIDs = forceSetArcRows.map(\.fid)
        topology.select(Set(forceSetArcIDs), featureKind: "arc")
        await topology.setField(featureKind: "arc", fid: forceSetArcFIDs[0],
            fieldID: "ConstrainStretching", value: "Constrained")
        await topology.setField(featureKind: "arc", fid: forceSetArcFIDs[1],
            fieldID: "ConstrainStretching", value: "Floating")
        await topology.setField(featureKind: "arc", fid: forceSetArcFIDs[0], fieldID: "LaplaceBC", value: "ZeroFlux")
        await topology.setField(featureKind: "arc", fid: forceSetArcFIDs[1], fieldID: "LaplaceBC", value: "Dirichlet")
        await topology.setField(featureKind: "arc", fid: forceSetArcFIDs[0], fieldID: "Bias", value: "1.5")
        await topology.setField(featureKind: "arc", fid: forceSetArcFIDs[1], fieldID: "Bias", value: "2.5")
        #expect(topology.snapshot?.arcs.rows.first { $0.fid == forceSetArcFIDs[0] }?
            .values["ConstrainStretching"] == "Constrained")
        #expect(topology.snapshot?.arcs.rows.first { $0.fid == forceSetArcFIDs[1] }?
            .values["ConstrainStretching"] == "Floating")

        #expect(await topology.forceSetArcChoice(rowIDs: forceSetArcIDs,
            fieldID: "ConstrainStretching", value: "Default"))
        #expect(forceSetArcFIDs.allSatisfy { fid in
            topology.snapshot?.arcs.rows.first { $0.fid == fid }?.values["ConstrainStretching"] == "Default"
        })
        await topology.undo()
        #expect(topology.snapshot?.arcs.rows.first { $0.fid == forceSetArcFIDs[0] }?
            .values["ConstrainStretching"] == "Constrained")
        #expect(topology.snapshot?.arcs.rows.first { $0.fid == forceSetArcFIDs[1] }?
            .values["ConstrainStretching"] == "Floating")
        await topology.redo()

        #expect(await topology.forceSetArcChoice(rowIDs: forceSetArcIDs, fieldID: "LaplaceBC", value: "Default"))
        #expect(forceSetArcFIDs.allSatisfy { fid in
            topology.snapshot?.arcs.rows.first { $0.fid == fid }?.values["LaplaceBC"] == "Default"
        })
        await topology.undo()
        #expect(topology.snapshot?.arcs.rows.first { $0.fid == forceSetArcFIDs[0] }?.values["LaplaceBC"] == "ZeroFlux")
        #expect(topology.snapshot?.arcs.rows.first { $0.fid == forceSetArcFIDs[1] }?.values["LaplaceBC"] == "Dirichlet")
        await topology.redo()

        #expect(await topology.forceResetArcBias(rowIDs: forceSetArcIDs))
        #expect(forceSetArcFIDs.allSatisfy { fid in topology.snapshot?.arcs.rows.first { $0.fid == fid }?.values["Bias"] == "NaN" })
        await topology.undo()
        #expect(topology.snapshot?.arcs.rows.first { $0.fid == forceSetArcFIDs[0] }?.values["Bias"] == "1.5")
        #expect(topology.snapshot?.arcs.rows.first { $0.fid == forceSetArcFIDs[1] }?.values["Bias"] == "2.5")
        await topology.redo()

        // The point query is tied to the current draft. Editing X through the
        // selected arc must reload rows so a following Y edit can use it.
        let arcID = manifest.internalPointArcFID
        let arc = try #require(topology.snapshot?.arcs.rows.first { $0.fid == arcID })
        topology.select([arc.id], featureKind: "arc")
        await topology.loadArcPoints(arcFID: arcID)
        let internalPoint = try #require(topology.arcPoints?.rows.first {
            $0.pointKind == "internal" && $0.internalPointIndex == manifest.internalPointIndex
        })
        let changedX = internalPoint.x + 1.25
        #expect(topology.updateArcPointInput(arcFID: arcID, rowIndex: internalPoint.rowIndex,
            axis: .x, rawText: String(changedX)))
        await topology.applyArcPointInput()
        let reloadedPoint = try #require(topology.arcPoints?.rows.first { $0.rowIndex == internalPoint.rowIndex })
        #expect(reloadedPoint.x == changedX && reloadedPoint.y == internalPoint.y)
        #expect(topology.updateArcPointInput(arcFID: arcID, rowIndex: internalPoint.rowIndex,
            axis: .y, rawText: String(internalPoint.y + 2.5)))
        await topology.applyArcPointInput()
        let finalPoint = try #require(topology.arcPoints?.rows.first { $0.rowIndex == internalPoint.rowIndex })
        #expect(finalPoint.x == changedX && finalPoint.y == internalPoint.y + 2.5)

        // Filter metadata/IDs come from the provider. The query is read-only:
        // it cannot alter the opaque draft or undo state.
        let category = try #require(manifest.filterTagNames["category"])
        let phase = try #require(manifest.filterTagNames["phase"])
        #expect(topology.snapshot?.arcTags.contains { $0.id == category } == true)
        #expect(topology.snapshot?.arcTags.contains { $0.id == phase } == true)
        let filterQuery = GeometryTopologyTagFilterQuery(featureKind: "arc", clauses: [
            .tag(definitionID: category, operator: .equals, value: "East"),
            .tag(definitionID: phase, operator: .equals, value: "B")
        ])
        topology.updateTagFilterQuery(filterQuery)
        let draftBeforeFilter = try #require(topology.snapshot?.draftState)
        let canUndoBeforeFilter = topology.snapshot?.canUndo
        await topology.applyTagFilterQuery(featureKind: "arc")
        let filtered = try #require(topology.tagFilterResult(for: "arc"))
        let expectedFIDs = topology.snapshot?.arcs.rows.filter {
            $0.values[category] == "East" && $0.values[phase] == "B"
        }.map(\.fid) ?? []
        #expect(filtered.matchedFeatureIDs == expectedFIDs)
        #expect(topology.snapshot?.draftState == draftBeforeFilter)
        #expect(topology.snapshot?.canUndo == canUndoBeforeFilter)
        #expect(topology.isDirty && editor.modified)
        #expect(try Data(contentsOf: geometryURL) == sourceGeometryBytes)
        #expect(try Data(contentsOf: projectURL) == sourceProjectBytes)

        #expect(await editor.saveLoadedModel())
        #expect(editor.error == nil && topology.error == nil)
        #expect(!editor.modified && !topology.isDirty)
        #expect(try Data(contentsOf: projectURL) == sourceProjectBytes)
        #expect(try Data(contentsOf: geometryURL) != sourceGeometryBytes)

        let reopened = ModelEditorSession(provider: modelProvider, topologyProvider: topologyProvider)
        await reopened.load(asset, kind: .geometry)
        await reopened.ensureGeometryTopologyLoaded()
        let reopenedTopology = try #require(reopened.geometryTopology)
        #expect(reopenedTopology.snapshot?.revision == reopened.sourceFileRevision)
        let reopenedFactor = try #require(Double(reopenedTopology.snapshot?.arcs.rows.first?.values["ConstantSize"] ?? ""))
        #expect(reopenedFactor == factoredSize)
        await reopenedTopology.loadRecipe(controlPointFIDs: recipeFIDs)
        #expect(reopenedTopology.recipeEditorState?.inspection?.selectedRecipes.allSatisfy {
            $0.recipe == "Smooth()"
        } == true)
        await reopenedTopology.loadArcPoints(arcFID: arcID)
        let persistedPoint = try #require(reopenedTopology.arcPoints?.rows.first {
            $0.rowIndex == internalPoint.rowIndex
        })
        #expect(persistedPoint.x == changedX && persistedPoint.y == internalPoint.y + 2.5)
        #expect(forceSetArcFIDs.allSatisfy { fid in
            let row = reopenedTopology.snapshot?.arcs.rows.first { $0.fid == fid }
            return row?.values["ConstrainStretching"] == "Default"
                && row?.values["LaplaceBC"] == "Default" && row?.values["Bias"] == "NaN"
        })
    }
}

private func topologyToolsSHA256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02X", $0) }.joined()
}
