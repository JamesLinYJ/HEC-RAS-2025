import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

@Suite(.serialized)
struct PlanPrecomputeAssociatedDraftCaptureTests {
    fileprivate static let geometryDescription =
        "GeometrySummaryPage/ViewModel_SelectedGeometryVisualContext_Context_Description"
    fileprivate static let boundaryDescription = "BoundaryConditionsSummary/BoundaryCondition_Description"
    fileprivate static let boundaryEndTime = "BoundaryConditionsSummary/BoundaryCondition_EndTime"

    @Test @MainActor
    func capturesRealUnsavedAssociatedDraftsAndInvalidatesOnOwnerChangesWithoutWritingSource() async throws {
        let harness = try await PlanPrecomputeAssociatedDraftFixture.open()
        defer { try? FileManager.default.removeItem(at: harness.folder) }

        let originalSourceBytes = try harness.sourceBytes()
        let geometryDraftDescription = "Unsaved associated Geometry 中文"
        let boundaryDraftDescription = "Unsaved associated Boundary Condition 中文"
        harness.geometryEditor.set(Self.geometryDescription, geometryDraftDescription)
        harness.boundaryEditor.set(Self.boundaryDescription, boundaryDraftDescription)
        let originalEndTime = try #require(harness.boundaryEditor.fields[Self.boundaryEndTime])
        let changedEndTime = originalEndTime == "2026-10-01T03:00:00Z"
            ? "2026-10-01T04:00:00Z" : "2026-10-01T03:00:00Z"
        harness.boundaryEditor.set(Self.boundaryEndTime, changedEndTime)

        await harness.geometryEditor.ensureGeometryMeshLoaded()
        let mesh = try #require(harness.geometryEditor.geometryMesh)
        let flowArea = try #require(mesh.flowAreas.first,
            "The bundled Plan Compute fixture must expose its real associated Solver Mesh flow area.")
        let meshDraftName = "Unsaved mesh child draft 中文"
        await mesh.setFlowAreaField(flowArea, fieldID: "Name", value: meshDraftName)
        #expect(mesh.error == nil)
        #expect(mesh.flowAreas.first(where: { $0.id == flowArea.id })?.name == meshDraftName)
        #expect(mesh.geometryMeshStateForParentSave != nil)

        await harness.geometryEditor.ensureGeometryCulvertLoaded()
        let culvert = try #require(harness.geometryEditor.geometryCulvert)
        await culvert.addPropertySet(featureKind: "barrelProperties")
        #expect(culvert.error == nil && culvert.isDirty)
        #expect(culvert.snapshot?.barrelProperties.rows.contains { $0.id.contains(":draft:") } == true)

        let capture = try harness.capture()
        #expect(capture.projectSessionID == harness.store.projectSessionID)
        #expect(capture.planContextID == harness.planEditor.currentPlanPrecomputeContext()?.id)
        #expect(harness.store.isCurrentPlanPrecomputeAssociatedDrafts(capture))
        #expect(capture.geometry?.editorID == harness.geometryEditor.id)
        #expect(capture.geometry?.asset.id == harness.geometry.id)
        #expect(capture.geometry?.edits.sourceRevision == harness.geometryEditor.sourceFileRevision)
        #expect(capture.geometry?.edits.fields[Self.geometryDescription] == geometryDraftDescription)
        #expect(capture.geometry?.edits.geometryMeshState == mesh.geometryMeshStateForParentSave)
        #expect(capture.geometry?.edits.geometryCulvertState == culvert.geometryCulvertStateForParentSave)
        #expect(capture.geometry?.edits.geometryCulvertState != nil)
        #expect(capture.boundaryCondition?.editorID == harness.boundaryEditor.id)
        #expect(capture.boundaryCondition?.asset.id == harness.boundary.id)
        let capturedGeometry = try #require(capture.geometry)
        let capturedBoundary = try #require(capture.boundaryCondition)
        let completeGeometryDraft = try harness.geometryEditor.captureAssociatedPlanPrecomputeDraft()
        let completeBoundaryDraft = try harness.boundaryEditor.captureAssociatedPlanPrecomputeDraft()
        #expect(capturedGeometry.contextID == completeGeometryDraft.contextID)
        #expect(capturedBoundary.contextID == completeBoundaryDraft.contextID)
        expectCompleteDraft(capturedGeometry.edits, matches: completeGeometryDraft.edits)
        expectCompleteDraft(capturedBoundary.edits, matches: completeBoundaryDraft.edits)
        #expect(capturedBoundary.edits.sourceRevision == harness.boundaryEditor.sourceFileRevision)
        #expect(capturedBoundary.edits.fields[Self.boundaryDescription] == boundaryDraftDescription)
        #expect(capturedBoundary.edits.fields[Self.boundaryEndTime] == changedEndTime)
        #expect(try harness.sourceBytes() == originalSourceBytes,
            "Associated draft capture must not write the project, Plan, Geometry, Boundary Condition, or other source files.")

        harness.geometryEditor.set(Self.geometryDescription, "Geometry changed after capture")
        #expect(!harness.store.isCurrentPlanPrecomputeAssociatedDrafts(capture),
            "Changing an associated owner draft must invalidate its prior capture.")

        let geometryReloadCapture = try harness.capture()
        await harness.geometryEditor.load(harness.geometry, kind: .geometry)
        try await harness.waitUntilSettled()
        #expect(!harness.store.isCurrentPlanPrecomputeAssociatedDrafts(geometryReloadCapture),
            "Reloading the exact associated owner must invalidate a capture even when its source file is unchanged.")
        #expect(try harness.sourceBytes() == originalSourceBytes)
    }

    @Test @MainActor
    func rejectsDuplicateDirtyOwnersPendingChildWorkAndIncompleteAssociatedInput() async throws {
        let harness = try await PlanPrecomputeAssociatedDraftFixture.open()
        defer { try? FileManager.default.removeItem(at: harness.folder) }

        harness.geometryEditor.set(Self.geometryDescription, "Primary dirty owner")
        harness.boundaryEditor.set(Self.boundaryDescription, "Boundary owner draft")

        let secondGeometryEditor = ModelEditorSession(provider: harness.provider)
        harness.store.registerEditor(secondGeometryEditor)
        await secondGeometryEditor.load(harness.geometry, kind: .geometry)
        try await harness.waitUntilSettled(extra: [secondGeometryEditor])
        #expect(try harness.capture().geometry?.editorID == harness.geometryEditor.id,
            "A clean same-asset editor is not an alternate dirty owner.")

        secondGeometryEditor.set(Self.geometryDescription, "Second dirty owner")
        #expect(throws: (any Error).self) { try harness.capture() }
        secondGeometryEditor.discardEdits()
        try await harness.waitUntilSettled(extra: [secondGeometryEditor])
        harness.store.unregisterEditor(secondGeometryEditor)
        #expect(harness.store.editorSession(secondGeometryEditor.id) == nil)

        await harness.geometryEditor.ensureGeometryCulvertLoaded()
        let culvert = try #require(harness.geometryEditor.geometryCulvert)
        culvert.setSketchActive(true)
        #expect(throws: (any Error).self) { try harness.capture() }
        culvert.setSketchActive(false)
        #expect(harness.store.isCurrentPlanPrecomputeAssociatedDrafts(try harness.capture()))

        let sourceEndTime = try #require(harness.boundaryEditor.fields[Self.boundaryEndTime])
        harness.boundaryEditor.setDateTimeInputDraft(.init(sourceValue: sourceEndTime,
            dateText: "not a date", timeText: "", dateTouched: true,
            timeTouched: false, issueKey: "Improperly formatted date."), for: Self.boundaryEndTime)
        #expect(harness.boundaryEditor.hasIncompleteEditorInput)
        #expect(throws: (any Error).self) { try harness.capture() }
        harness.boundaryEditor.clearDateTimeInputDraft(for: Self.boundaryEndTime)
        #expect(harness.store.isCurrentPlanPrecomputeAssociatedDrafts(try harness.capture()))

        let beforeOwnerClose = try harness.capture()
        harness.geometryEditor.discardEdits()
        try await harness.waitUntilSettled()
        harness.store.unregisterEditor(harness.geometryEditor)
        #expect(harness.store.editorSession(harness.geometryEditor.id) == nil)
        #expect(!harness.store.isCurrentPlanPrecomputeAssociatedDrafts(beforeOwnerClose),
            "Closing an associated editor after discarding its draft must invalidate a capture that named that owner.")
    }

    @Test @MainActor
    func reloadingOrClosingThePlanOwnerInvalidatesAssociatedCapture() async throws {
        let harness = try await PlanPrecomputeAssociatedDraftFixture.open()
        defer { try? FileManager.default.removeItem(at: harness.folder) }

        harness.boundaryEditor.set(Self.boundaryDescription, "Boundary draft remains unsaved")
        let capture = try harness.capture()
        let coreCountField = "PlanComputeSettingsPage/ViewModel_SelectedPlan_CoreCount"
        let originalCoreCount = try #require(harness.planEditor.fields[coreCountField])
        let changedCoreCount = originalCoreCount == "2" ? "1" : "2"
        harness.planEditor.set(coreCountField, changedCoreCount)
        #expect(harness.planEditor.modified)
        #expect(!harness.store.isCurrentPlanPrecomputeAssociatedDrafts(capture),
            "Changing the exact Plan owner's unsaved draft must invalidate an associated-draft capture.")
        harness.planEditor.discardEdits()
        try await harness.waitUntilSettled()

        let currentCapture = try harness.capture()
        await harness.planEditor.load(harness.plan, kind: .plan)
        try await harness.waitUntilSettled()
        #expect(!harness.store.isCurrentPlanPrecomputeAssociatedDrafts(currentCapture),
            "Reloading the Plan owner must invalidate the prior Plan context identity.")

        let reopenedCapture = try harness.capture()
        harness.store.unregisterEditor(harness.planEditor)
        #expect(harness.store.editorSession(harness.planEditor.id) == nil)
        #expect(!harness.store.isCurrentPlanPrecomputeAssociatedDrafts(reopenedCapture),
            "Closing the Plan owner must prevent an old associated capture from being treated as current.")
    }
}

@MainActor
private final class PlanPrecomputeAssociatedDraftFixture {
    let folder: URL
    let store: WorkspaceStore
    let provider: BackendModelProvider
    let plan: ProjectAsset
    let geometry: ProjectAsset
    let boundary: ProjectAsset
    let planEditor: ModelEditorSession
    let geometryEditor: ModelEditorSession
    let boundaryEditor: ModelEditorSession

    private init(folder: URL, store: WorkspaceStore, provider: BackendModelProvider,
                 plan: ProjectAsset, geometry: ProjectAsset, boundary: ProjectAsset,
                 planEditor: ModelEditorSession, geometryEditor: ModelEditorSession,
                 boundaryEditor: ModelEditorSession) {
        self.folder = folder
        self.store = store
        self.provider = provider
        self.plan = plan
        self.geometry = geometry
        self.boundary = boundary
        self.planEditor = planEditor
        self.geometryEditor = geometryEditor
        self.boundaryEditor = boundaryEditor
    }

    static func open() async throws -> PlanPrecomputeAssociatedDraftFixture {
        let environment = ProcessInfo.processInfo.environment
        let executable = try #require(environment["HECRAS_BACKEND_TEST_EXECUTABLE"])
        let fixturePath = try #require(environment["HECRAS_PLAN_COMPUTE_ACCEPTANCE_DIRECTORY"])
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("plan-associated-drafts-" + UUID().uuidString, isDirectory: true)
        try #require(!FileManager.default.fileExists(atPath: folder.path))
        try FileManager.default.copyItem(at: URL(fileURLWithPath: fixturePath), to: folder)

        let projectURL = folder.appendingPathComponent("Plan Compute Acceptance.ras")
        let provider = BackendModelProvider(client: .init(executableURL: URL(fileURLWithPath: executable)))
        let store = WorkspaceStore(system: SourceWorkflowFixtureServices(
            recoveryFolder: folder.appendingPathComponent("Recovery")), modelProvider: provider)
        store.requestOpen(projectURL)
        let openDeadline = ContinuousClock.now.advanced(by: .seconds(30))
        while store.isOpeningProject && ContinuousClock.now < openDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(!store.isOpeningProject)

        let plan = try #require(store.assets.first { $0.section == .plans && $0.name == "Plan CPU" })
        let association = try #require(store.document?.associationRows(group: "PlanAssociations")
            .first { $0.name == plan.name })
        let geometryName = try #require(association.fields["Geometry"])
        let boundaryName = try #require(association.fields["BoundaryCondition"])
        let geometry = try #require(store.assets.first {
            $0.section == .geometries && $0.name == geometryName
        })
        let boundary = try #require(store.assets.first {
            $0.section == .boundaryConditions && $0.name == boundaryName
        })

        let planEditor = store.primaryEditorSession(.plan)
        let geometryEditor = store.primaryEditorSession(.geometry)
        let boundaryEditor = store.primaryEditorSession(.boundaryCondition)
        await planEditor.load(plan, kind: .plan)
        await geometryEditor.load(geometry, kind: .geometry)
        await boundaryEditor.load(boundary, kind: .boundaryCondition)
        let fixture = PlanPrecomputeAssociatedDraftFixture(folder: folder, store: store,
            provider: provider, plan: plan, geometry: geometry, boundary: boundary,
            planEditor: planEditor, geometryEditor: geometryEditor, boundaryEditor: boundaryEditor)
        try await fixture.waitUntilSettled()
        try #require(planEditor.currentPlanPrecomputeContext() != nil)
        try #require(geometryEditor.fields[PlanPrecomputeAssociatedDraftCaptureTests.geometryDescription] != nil)
        try #require(boundaryEditor.fields[PlanPrecomputeAssociatedDraftCaptureTests.boundaryDescription] != nil)
        try #require(boundaryEditor.fields[PlanPrecomputeAssociatedDraftCaptureTests.boundaryEndTime] != nil)
        return fixture
    }

    func capture() throws -> PlanPrecomputeAssociatedDraftsCapture {
        guard let context = planEditor.currentPlanPrecomputeContext() else {
            throw AssociatedDraftFixtureError.planContextUnavailable
        }
        return try store.capturePlanPrecomputeAssociatedDrafts(planEditorID: planEditor.id,
            planContextID: context.id, projectSessionID: store.projectSessionID)
    }

    func sourceBytes() throws -> [String: Data] {
        var urls = Set(([store.document?.url].compactMap { $0 }
            + store.assets.filter { $0.isModelFile }.map(\.url)))
        if let enumerator = FileManager.default.enumerator(at: folder,
            includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
            for case let url as URL in enumerator {
                guard !url.pathComponents.contains("Recovery"),
                      (try url.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else { continue }
                urls.insert(url)
            }
        }
        // Explicit model URLs and directory enumeration can spell the same
        // macOS temporary file through /var and /private/var. Compare every
        // physical source once, retaining its complete original bytes.
        let paths = Set(urls.map { SourceFilePaths.canonical($0) })
        return try Dictionary(uniqueKeysWithValues: paths.map { path in
            (path, try Data(contentsOf: URL(fileURLWithPath: path)))
        })
    }

    func waitUntilSettled(extra: [ModelEditorSession] = []) async throws {
        let sessions = [planEditor, geometryEditor, boundaryEditor] + extra
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while sessions.contains(where: { $0.isRefreshingContext || ($0.isSourcePlan && $0.currentPlanPrecomputeContext() == nil) || $0.isPerforming })
            && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        try #require(!sessions.contains(where: {
            $0.isRefreshingContext || ($0.isSourcePlan && $0.currentPlanPrecomputeContext() == nil) || $0.isPerforming
        }), "The real model owner sessions did not finish loading/refreshing before draft capture.")
    }
}

private enum AssociatedDraftFixtureError: Error {
    case planContextUnavailable
}

private func expectCompleteDraft(_ actual: EditorEdits, matches expected: EditorEdits) {
    #expect(actual.fields == expected.fields)
    #expect(canonicalRows(actual.rows) == canonicalRows(expected.rows))
    #expect(canonicalImages(actual.images) == canonicalImages(expected.images))
    #expect(canonicalSamples(actual.samples) == canonicalSamples(expected.samples))
    #expect(actual.sourceRevision == expected.sourceRevision)
    #expect(actual.sourceState == expected.sourceState)
    #expect(actual.planTimeWindowEdits == expected.planTimeWindowEdits)
    #expect(actual.geometryTopologyState == expected.geometryTopologyState)
    #expect(actual.geometryMeshState == expected.geometryMeshState)
    #expect(actual.geometryCulvertState == expected.geometryCulvertState)
    #expect(actual.tableSelections == expected.tableSelections)
    #expect(actual.changedCells == expected.changedCells)
}

private func canonicalRows(_ rows: [String: [EditorRow]]) -> [String: [[String: String]]] {
    rows.mapValues { values in
        values.map { row in
            var result = ["$id": row.id]
            for (key, value) in row.values { result["value:" + key] = value }
            for (key, value) in row.fieldBindings { result["binding:" + key] = value }
            return result
        }
    }
}

private func canonicalImages(_ images: [String: [ImageAttachment]]) -> [String: [String]] {
    images.mapValues { values in
        values.map { [$0.id, $0.name, $0.data.base64EncodedString()].joined(separator: "|") }
    }
}

private func canonicalSamples(_ samples: [String: [ChartSample]]) -> [String: [String]] {
    samples.mapValues { values in
        values.map { sample in
            [sample.id, String(sample.x.bitPattern), String(sample.y.bitPattern), sample.series,
             sample.datasetID ?? ""].joined(separator: "|")
        }
    }
}
