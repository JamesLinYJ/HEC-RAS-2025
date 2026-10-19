import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

@MainActor
private final class ComputeLeaseProvider: ModelEditorProvider {
    private(set) var loads: [String: Int] = [:]
    private(set) var saves = 0
    func load(_ asset: ProjectAsset, kind: ModelEditorKind) async throws -> EditorSnapshot {
        loads[asset.id, default: 0] += 1
        return .init(fields: ["LeaseTest/Value": "source"], rows: [:], samples: [:],
            canEdit: true, images: [:], sourceRevision: "source-revision")
    }
    func save(_ asset: ProjectAsset, changes: EditorEdits) async throws { saves += 1 }
    func perform(_ asset: ProjectAsset, action: EditorAction) async throws -> EditorSnapshot {
        throw CocoaError(.featureUnsupported)
    }
}

struct PlanComputeWorkspaceTests {
    @Test @MainActor
    func computeLeaseRejectsDependencyDraftsAndPreservesPlanAndUnrelatedDrafts() async throws {
        let fixture = try computeLeaseFixture()
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        let provider = ComputeLeaseProvider()
        let store = WorkspaceStore(system: SourceWorkflowFixtureServices(recoveryFolder: fixture.folder.appendingPathComponent("Trash")), modelProvider: provider)
        store.requestOpen(fixture.project)
        try await waitForComputeLease { !store.isOpeningProject }
        let plan = try #require(store.assets.first { $0.section == .plans })
        let geometry = try #require(store.assets.first { $0.section == .geometries })
        let boundary = try #require(store.assets.first { $0.section == .boundaryConditions })
        let owner = store.primaryEditorSession(.plan)
        let geometryEditor = store.primaryEditorSession(.geometry)
        let unrelatedEditor = store.primaryEditorSession(.boundaryCondition)
        await owner.load(plan, kind: .plan)
        await geometryEditor.load(geometry, kind: .geometry)
        await unrelatedEditor.load(boundary, kind: .boundaryCondition)
        owner.set("LeaseTest/Value", "unsaved plan")
        geometryEditor.set("LeaseTest/Value", "unsaved dependency")
        unrelatedEditor.set("LeaseTest/Value", "unrelated draft")
        let projectOwner = store.projectSessionID
        let capture = try computeLeaseCapture(store: store, editor: owner, plan: plan)
        #expect(!store.beginPlanCompute(editorID: owner.id, assetID: plan.id,
            dependencyPaths: [plan.id, geometry.id], writePaths: [geometry.id], projectSessionID: projectOwner, capture: capture))
        #expect(!store.isRunningPlanCompute && geometryEditor.modified)
        geometryEditor.discardEdits()
        #expect(store.beginPlanCompute(editorID: owner.id, assetID: plan.id,
            dependencyPaths: [plan.id, geometry.id], writePaths: [geometry.id], projectSessionID: projectOwner, capture: capture))
        #expect(store.isRunningProjectTool && owner.isBusy && geometryEditor.isBusy)
        owner.set("LeaseTest/Value", "must be blocked")
        geometryEditor.set("LeaseTest/Value", "must be blocked")
        await owner.save(plan)
        #expect(provider.saves == 0)
        #expect(owner.fields["LeaseTest/Value"] == "unsaved plan")
        #expect(geometryEditor.fields["LeaseTest/Value"] == "source")
        store.requestClose()
        #expect(store.projectSessionID == projectOwner && store.hasProject)
        store.endPlanCompute(editorID: UUID(), projectSessionID: projectOwner)
        #expect(store.isRunningPlanCompute)
        store.endPlanCompute(editorID: owner.id, projectSessionID: UUID())
        #expect(store.isRunningPlanCompute)
        store.endPlanCompute(editorID: owner.id, projectSessionID: projectOwner)
        try await waitForComputeLease { !store.isRunningPlanCompute }
        #expect(provider.loads[geometry.id] == 2)
        #expect(provider.loads[plan.id] == 1 && provider.loads[boundary.id] == 1)
        #expect(owner.modified && owner.fields["LeaseTest/Value"] == "unsaved plan")
        #expect(unrelatedEditor.modified && unrelatedEditor.fields["LeaseTest/Value"] == "unrelated draft")
        #expect(!geometryEditor.modified && geometryEditor.loaded)
    }

    @Test @MainActor
    func successfulComputeResumesMapReadersAndPublishesDeferredBackgroundPreferences() async throws {
        let fixture = try computeLeaseFixture()
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        let store = WorkspaceStore(system: SourceWorkflowFixtureServices(recoveryFolder: fixture.folder.appendingPathComponent("Trash")),
            modelProvider: ComputeLeaseProvider())
        store.requestOpen(fixture.project)
        try await waitForComputeLease { !store.isOpeningProject }
        let state = store.activeMapState
        var settings = state.backgroundMapSession.settings
        settings.isOpenStreetMapOn = false
        state.backgroundMapSession.settings = settings
        let visualURL = fixture.project.deletingPathExtension().appendingPathExtension("vis")
        let originalVisual = try Data(contentsOf: visualURL)
        let plan = try #require(store.assets.first { $0.section == .plans })
        let owner = store.primaryEditorSession(.plan)
        await owner.load(plan, kind: .plan)
        let capture = try computeLeaseCapture(store: store, editor: owner, plan: plan)
        #expect(store.beginPlanCompute(editorID: owner.id, assetID: plan.id,
            dependencyPaths: [plan.id], writePaths: [], projectSessionID: store.projectSessionID, capture: capture))
        #expect(state.resultMap.isSourceReadsSuspended)
        settings.areBackgroundMapsOn = true
        state.backgroundMapSession.settings = settings
        #expect(state.backgroundMapSession.settings.areBackgroundMapsOn)
        #expect(try Data(contentsOf: visualURL) == originalVisual,
            "Changing background presentation cannot invalidate the live Result's captured VIS revision.")
        store.endPlanCompute(editorID: owner.id, projectSessionID: store.projectSessionID)
        try await waitForComputeLease { !store.isRunningPlanCompute }
        #expect(!state.resultMap.isSourceReadsSuspended,
            "Successful completion must release the map readers, not only the editor write lease.")
        let visualization = try VisualizationDocument(projectURL: fixture.project)
        let map = try #require(visualization.maps.first)
        let options = try visualization.backgroundMapOptions(map: map)
        #expect(options["AreBackgroundMapsOn"] == "true")
        #expect(options["UseOSM"] == "false")
        #expect(try Data(contentsOf: visualURL) != originalVisual)
    }

    @Test @MainActor
    func missingPlanIdentityAndForeignWriteFootprintCannotAcquireComputeLease() async throws {
        let fixture = try computeLeaseFixture()
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        let store = WorkspaceStore(system: SourceWorkflowFixtureServices(recoveryFolder: fixture.folder.appendingPathComponent("Trash")), modelProvider: ComputeLeaseProvider())
        store.requestOpen(fixture.project)
        try await waitForComputeLease { !store.isOpeningProject }
        let plan = try #require(store.assets.first { $0.section == .plans })
        let owner = store.primaryEditorSession(.plan)
        await owner.load(plan, kind: .plan)
        let capture = try computeLeaseCapture(store: store, editor: owner, plan: plan)
        #expect(!store.beginPlanCompute(editorID: owner.id, assetID: plan.id,
            dependencyPaths: [], writePaths: [], projectSessionID: store.projectSessionID, capture: capture))
        #expect(!store.beginPlanCompute(editorID: owner.id, assetID: plan.id,
            dependencyPaths: [plan.id], writePaths: [fixture.folder.appendingPathComponent("foreign.h5").path],
            projectSessionID: store.projectSessionID, capture: capture))
        #expect(!store.beginPlanCompute(editorID: owner.id, assetID: plan.id,
            dependencyPaths: [plan.id], writePaths: [], projectSessionID: UUID(), capture: capture))
        #expect(!store.isRunningPlanCompute)
    }
}

@MainActor
private func computeLeaseCapture(store: WorkspaceStore, editor: ModelEditorSession,
                                 plan: ProjectAsset) throws -> WorkspaceResultComputeCapture {
    WorkspaceResultComputeCapture(projectSessionID: store.projectSessionID, editorID: editor.id,
        operationOwnerToken: "compute-lease-unit-owner", operationContextID: "compute-lease-unit-context",
        projectPath: try #require(store.document?.url).path,
        projectRevision: try #require(store.document?.sourceRevision),
        projectXmlFingerprint: "unit-lease-test-no-progress-stream",
        planPath: plan.id, planRevision: try #require(editor.sourceFileRevision))
}

private func computeLeaseFixture() throws -> (folder: URL, project: URL) {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("compute-lease-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let project = folder.appendingPathComponent("Project.ras")
    try Data("<Project><Description>Preserve project draft</Description></Project>".utf8).write(to: project)
    for (directory, name) in [("Plans", "Plan"), ("Geometries", "Geometry"), ("Boundary Conditions", "Boundary")] {
        let location = folder.appendingPathComponent(directory)
        try FileManager.default.createDirectory(at: location, withIntermediateDirectories: true)
        try Data("lease unit fixture only; not source HDF or solver input".utf8).write(to: location.appendingPathComponent(name + ".h5"))
    }
    return (folder, project)
}

@MainActor
private func waitForComputeLease(_ condition: @MainActor () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(3)
    while !condition() {
        if ContinuousClock.now >= deadline { throw ComputeLeaseTestError.timedOut }
        try await Task.sleep(for: .milliseconds(5))
    }
}

private enum ComputeLeaseTestError: Error { case timedOut }
