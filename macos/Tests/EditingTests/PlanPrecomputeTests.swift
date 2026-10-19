import Foundation
import Testing
@testable import HECRAS2025
@testable import RASWorkspaceCore

private enum PlanPrecomputeTestData {
    static let asset = ProjectAsset(url: URL(fileURLWithPath: "/task-fixture/plan-precompute/Plan A.h5"), section: .plans)
    static let description = "PlanSettingsPage/ViewModel_SelectedPlan_Description"
    static let descriptionAlias = "PlanCatalogSummary/Context_Description"
    static let timestep = "PlanSettingsPage/ViewModel_SelectedPlan_ComputeTimestep"
    static let mode = "PlanSettingsPage/ViewModel_SelectedPlan_TimeWindowMode"
    static let start = "PlanSettingsPage/ViewModel_SelectedPlan_ComputeStartTime"
    static let end = "PlanSettingsPage/ViewModel_SelectedPlan_ComputeEndTime"
    static let images = "PlanSettingsPage/ViewModel_SelectedPlan_EmbeddedImages"
    static let revision = "precompute-plan-revision"
    static let windowFields = PlanTimeWindowFieldIDs(mode: mode, start: start, end: end)

    static func snapshot() -> EditorSnapshot {
        EditorSnapshot(
            fields: [
                description: "saved description",
                descriptionAlias: "saved description",
                timestep: "12.5",
                mode: "BoundaryCondition",
                start: "2026-10-01T00:00:00Z",
                end: "2026-10-02T00:00:00Z"
            ],
            rows: [:], samples: [:], canEdit: true,
            images: [images: [.init(id: "source-image", name: "plan.png", data: Data([1, 2, 3]))]],
            sourceRevision: revision,
            fieldGroups: ["PlanDescriptionAliases": [description, descriptionAlias]],
            sourceState: "loaded-plan-source-state",
            planTimeWindowFieldIDs: windowFields)
    }

    static func result(_ code: String) -> PlanPrecomputeResult {
        .init(revision: revision, result: false, messages: [
            .init(code: code, defaultSeverity: "Error", evaluatedMessage: "Late result: \(code)", logData: [], extraCount: 0)
        ])
    }
}

@MainActor
private final class DelayedPlanPrecomputeProvider: ModelEditorProvider, PlanPrecomputeProvider {
    private(set) var precomputeRequests: [EditorEdits] = []
    private var completions: [Int: CheckedContinuation<PlanPrecomputeResult, any Error>] = [:]
    private(set) var refreshedProjectXML: String?
    private var project: ProjectDocument?

    var supportsProjectContextRefresh: Bool { true }
    var projectXML: String? { project?.editorXML }

    func setProject(_ document: ProjectDocument?) { project = document }

    func load(_ asset: ProjectAsset, kind: ModelEditorKind) async throws -> EditorSnapshot {
        PlanPrecomputeTestData.snapshot()
    }

    func refreshProjectContext(_ asset: ProjectAsset, edits: EditorEdits) async throws -> EditorContextRefresh {
        refreshedProjectXML = project?.editorXML
        let snapshot = PlanPrecomputeTestData.snapshot()
        return .init(baseline: snapshot, draft: snapshot)
    }

    func inspect(_ asset: ProjectAsset, edits: EditorEdits) async throws -> PlanPrecomputeResult {
        let request = precomputeRequests.count + 1
        precomputeRequests.append(edits)
        return try await withCheckedThrowingContinuation { continuation in
            completions[request] = continuation
        }
    }

    func save(_ asset: ProjectAsset, changes: EditorEdits) async throws {}

    func perform(_ asset: ProjectAsset, action: EditorAction) async throws -> EditorSnapshot {
        PlanPrecomputeTestData.snapshot()
    }

    func finish(_ request: Int, with result: PlanPrecomputeResult) {
        completions.removeValue(forKey: request)?.resume(returning: result)
    }

    func fail(_ request: Int, with error: any Error) {
        completions.removeValue(forKey: request)?.resume(throwing: error)
    }
}

private enum StaleContextChange: CaseIterable, Equatable {
    case draft
    case projectXML
    case discard
    case reload
}

@Suite(.serialized)
struct PlanPrecomputeTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HECRAS_PLAN_CONTEXT_ACCEPTANCE_DIRECTORY"] != nil)) @MainActor
    func bundledBackendChecksUnsavedPlanAndProjectDraftsWithoutWritingSourceFiles() async throws {
        let executable = try #require(ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"])
        let fixture = try #require(ProcessInfo.processInfo.environment["HECRAS_PLAN_CONTEXT_ACCEPTANCE_DIRECTORY"])
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("plan-precompute-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: fixture), to: folder)
        defer { try? FileManager.default.removeItem(at: folder) }

        let projectURL = folder.appendingPathComponent("Plan Context Refresh.ras")
        let project = try ProjectDocument(contentsOf: projectURL)
        let provider = BackendModelProvider(client: .init(executableURL: URL(fileURLWithPath: executable)))
        provider.setProject(project)
        let plan = try #require(project.assets.first { $0.section == .plans && $0.name == "Plan A" })
        let boundaryA = try #require(project.assets.first { $0.section == .boundaryConditions && $0.name == "Boundary A" })
        let boundaryB = try #require(project.assets.first { $0.section == .boundaryConditions && $0.name == "Boundary B" })
        let session = ModelEditorSession(provider: provider)
        await session.load(plan, kind: .plan)
        #expect(session.loaded && session.error == nil)
        let originalContextID = try #require(session.currentPlanPrecomputeContext()?.id)

        let originalFiles = [projectURL, plan.url, boundaryA.url, boundaryB.url]
        let originalBytes = try Dictionary(uniqueKeysWithValues: originalFiles.map { ($0, try Data(contentsOf: $0)) })
        let originalProjectBytes = try #require(originalBytes[projectURL])
        let originalPlanBytes = try #require(originalBytes[plan.url])
        let originalBoundaryABytes = try #require(originalBytes[boundaryA.url])
        let originalBoundaryBBytes = try #require(originalBytes[boundaryB.url])
        let association = try #require(project.associationRows(group: "PlanAssociations").first { $0.name == plan.name })
        try project.setAssociation(association, field: "BoundaryCondition", value: boundaryB.name)
        provider.setProject(project)
        #expect(session.currentPlanPrecomputeContext()?.id != originalContextID,
            "An unsaved owning-project XML change must invalidate the plan precompute context.")

        let untouchedWindow = try await provider.refreshProjectContext(plan, edits: .init(
            fields: [:], rows: [:], images: [:],
            sourceRevision: session.sourceFileRevision, sourceState: session.sourceState))
        let start = try #require(untouchedWindow.baseline.fields[PlanPrecomputeTestData.start])
        let end = try #require(untouchedWindow.baseline.fields[PlanPrecomputeTestData.end])
        #expect(start.contains("2026-10-03") && start.contains("06:00:00"))
        #expect(end.contains("2026-10-04") && end.contains("12:00:00"))

        let edits = EditorEdits(
            fields: [
                PlanPrecomputeTestData.description: "Unsaved precompute description",
                PlanPrecomputeTestData.timestep: "70"
            ],
            rows: [:], images: [:], sourceRevision: session.sourceFileRevision,
            sourceState: session.sourceState,
            planTimeWindowEdits: [
                .init(fieldID: PlanPrecomputeTestData.mode, value: "Plan"),
                .init(fieldID: PlanPrecomputeTestData.start, value: start),
                .init(fieldID: PlanPrecomputeTestData.end, value: end)
            ])
        let boundaryBDraft = try await provider.inspect(plan, edits: edits)
        let boundaryBCodes = Set(boundaryBDraft.messages.map(\.code))
        #expect(boundaryBDraft.revision == session.sourceFileRevision)
        #expect(!boundaryBDraft.result)
        #expect(boundaryBCodes.contains("Plan_NoGeomAssociation"))
        #expect(boundaryBCodes.contains("Plan_MappingIntervalMismatchingComputeInterval"))
        #expect(!boundaryBCodes.contains("BC_DoesntCoverTimeWindow"))
        let geometryMessage = try #require(boundaryBDraft.messages.first { $0.code == "Plan_NoGeomAssociation" })
        #expect(geometryMessage.defaultSeverity == "Error")
        #expect(geometryMessage.evaluatedMessage.contains("Plan A"))
        #expect(geometryMessage.logData.contains { $0.key == "PlanName" && $0.value == "Plan A" })

        try project.setAssociation(association, field: "BoundaryCondition", value: boundaryA.name)
        provider.setProject(project)
        let boundaryADraft = try await provider.inspect(plan, edits: edits)
        #expect(boundaryADraft.messages.contains { $0.code == "BC_DoesntCoverTimeWindow" })

        for file in originalFiles {
            let expected = try #require(originalBytes[file])
            #expect(try Data(contentsOf: file) == expected, "Precompute must leave project XML and all plan/boundary HDF files byte-identical.")
        }

        var externallyChangedPlan = originalPlanBytes
        externallyChangedPlan.append(0)
        try externallyChangedPlan.write(to: plan.url, options: .atomic)
        do {
            _ = try await provider.inspect(plan, edits: edits)
            Issue.record("Precompute must reject a plan whose source SHA changed after load.")
        } catch let error as BackendServiceError {
            #expect(error.code == "sourceChanged")
        }
        #expect(try Data(contentsOf: plan.url) == externallyChangedPlan)
        #expect(try Data(contentsOf: projectURL) == originalProjectBytes)
        #expect(try Data(contentsOf: boundaryA.url) == originalBoundaryABytes)
        #expect(try Data(contentsOf: boundaryB.url) == originalBoundaryBBytes)
    }

    @Test @MainActor
    func precomputeResultDoesNotAlterDraftFieldsImagesSourceStateOrDirtyState() async throws {
        let provider = DelayedPlanPrecomputeProvider()
        let session = ModelEditorSession(provider: provider)
        await session.load(PlanPrecomputeTestData.asset, kind: .plan)
        session.set(PlanPrecomputeTestData.description, "  exact unsaved draft 🌊  ")
        session.addImage(PlanPrecomputeTestData.images, image: .init(id: "local-image", name: "local.png", data: Data([4, 5, 6])))

        let fieldsBefore = session.fields
        let imagesBefore = session.images
        let sourceStateBefore = session.sourceState
        let modifiedBefore = session.modified
        let state = PlanPrecomputeState()
        state.refresh(session: session)
        #expect(await waitUntil { provider.precomputeRequests.count == 1 })
        let request = try #require(provider.precomputeRequests.first)
        #expect(request.fields[PlanPrecomputeTestData.description] == "  exact unsaved draft 🌊  ")
        // CanCompute needs no attachment data; the complete UI draft is
        // checked below to ensure the read-only request leaves it intact.
        #expect(request.images.isEmpty)

        let result = PlanPrecomputeTestData.result("Plan_NoGeomAssociation")
        provider.finish(1, with: result)
        #expect(await waitUntil { state.result == result })
        #expect(state.resultContextID == session.currentPlanPrecomputeContext()?.id)
        #expect(session.fields == fieldsBefore)
        #expect(Set(session.images.keys) == Set(imagesBefore.keys))
        #expect(session.images.mapValues { $0.map(\.id) } == imagesBefore.mapValues { $0.map(\.id) })
        #expect(session.images.mapValues { $0.map(\.name) } == imagesBefore.mapValues { $0.map(\.name) })
        #expect(session.images.mapValues { $0.map(\.data) } == imagesBefore.mapValues { $0.map(\.data) })
        #expect(session.sourceState == sourceStateBefore)
        #expect(session.modified == modifiedBefore)
    }

    @Test @MainActor
    func lateResultsAreDiscardedAfterDraftProjectAssociationDiscardAndReloadChanges() async throws {
        for change in StaleContextChange.allCases {
            let provider = DelayedPlanPrecomputeProvider()
            let session = ModelEditorSession(provider: provider)
            await session.load(PlanPrecomputeTestData.asset, kind: .plan)

            var project: ProjectDocument?
            var association: ProjectAssociation?
            if change == .projectXML {
                let document = try ProjectDocument(name: "Precompute State", units: "SI")
                let row = ProjectAssociation(group: "PlanAssociations", element: "PlanAssociation",
                    primaryKey: "Plan", name: "Plan A", fields: ["Plan": "Plan A"])
                try document.setAssociation(row, field: "BoundaryCondition", value: "Boundary A")
                provider.setProject(document)
                project = document
                association = row
            }
            if change == .discard {
                session.set(PlanPrecomputeTestData.description, "draft before discard")
            }

            let state = PlanPrecomputeState()
            state.refresh(session: session)
            #expect(await waitUntil { provider.precomputeRequests.count == 1 }, "The \(change) precompute request did not start.")
            let originalContextID = try #require(session.currentPlanPrecomputeContext()?.id)

            switch change {
            case .draft:
                session.set(PlanPrecomputeTestData.description, "newer draft")
            case .projectXML:
                let document = try #require(project)
                let row = try #require(association)
                let originalXML = try #require(provider.projectXML)
                try document.setAssociation(row, field: "BoundaryCondition", value: "Boundary B")
                provider.setProject(document)
                #expect(provider.projectXML != originalXML)
                // This is the invalidation route used after an unsaved association edit.
                session.requestProjectContextRefresh()
                #expect(await session.refreshProjectContext())
                #expect(provider.refreshedProjectXML == provider.projectXML)
            case .discard:
                session.discardEdits()
            case .reload:
                await session.load(PlanPrecomputeTestData.asset, kind: .plan)
            }

            #expect(session.currentPlanPrecomputeContext()?.id != originalContextID)
            provider.finish(1, with: PlanPrecomputeTestData.result("late-\(String(describing: change))"))
            #expect(await waitUntil { !state.isRefreshing })
            #expect(state.result == nil)
            #expect(state.resultContextID == nil)
            #expect(state.errorMessage == nil)
        }
    }

    @Test @MainActor
    func olderFailureCannotReplaceAResultFromANewerPrecomputeRequest() async throws {
        let provider = DelayedPlanPrecomputeProvider()
        let session = ModelEditorSession(provider: provider)
        await session.load(PlanPrecomputeTestData.asset, kind: .plan)
        let state = PlanPrecomputeState()

        state.refresh(session: session)
        #expect(await waitUntil { provider.precomputeRequests.count == 1 })
        state.refresh(session: session)
        #expect(await waitUntil { provider.precomputeRequests.count == 2 })

        let newerResult = PlanPrecomputeTestData.result("newer-result")
        provider.finish(2, with: newerResult)
        #expect(await waitUntil { state.result == newerResult })
        provider.fail(1, with: DelayedPrecomputeFailure())
        try await Task.sleep(for: .milliseconds(30))

        #expect(state.result == newerResult)
        #expect(state.resultContextID == session.currentPlanPrecomputeContext()?.id)
        #expect(state.errorMessage == nil)
        #expect(!state.isRefreshing)
    }
}

private struct DelayedPrecomputeFailure: LocalizedError {
    var errorDescription: String? { "An older precompute request failed." }
}

@MainActor
private func waitUntil(
    timeout: Duration = .seconds(3),
    _ condition: @MainActor () -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !condition(), clock.now < deadline {
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}
