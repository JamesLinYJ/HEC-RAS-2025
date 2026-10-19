import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

struct ResultPlanSettingsEditorSessionTests {
    @Test @MainActor
    func parentSaveReceiptRebasesOwnerAndPreservesDescriptionTypedWhileSaving() async throws {
        let capture = makeCapture(revision: String(repeating: "A", count: 64))
        let provider = ResultPlanEditorTestProvider()
        let session = ResultPlanSettingsEditorSession(provider: provider)
        await session.load(capture)

        #expect(session.currentOwnerCapture?.identity == capture.identity)
        session.draftDescription = "Description captured by parent save"
        let draft = try #require(session.captureDraft(for: capture))
        session.draftDescription = "Description typed while the parent save is running"

        let newRevision = String(repeating: "C", count: 64)
        let savedSnapshot = makeSnapshot(capture: capture, revision: newRevision,
            description: draft.planDescription)
        let receipt = ResultPlanSettingsSaveReceipt(resultPath: capture.owner.resultPath,
            previousRevision: capture.owner.resultRevision, revision: newRevision,
            planName: draft.planName, planDescription: draft.planDescription, snapshot: savedSnapshot)
        session.accept(draft, receipt: receipt)

        #expect(session.currentOwnerCapture?.owner.resultRevision == newRevision)
        #expect(session.snapshot?.settings.planDescription == draft.planDescription)
        #expect(session.draftDescription == "Description typed while the parent save is running")
        #expect(session.hasUnsavedChanges)
        #expect(session.captureDraft(for: try #require(session.currentOwnerCapture))?.planDescription
            == "Description typed while the parent save is running")
    }

    @Test @MainActor
    func pendingDraftCannotBeReusedAfterResultRevisionChangesAndExplicitDiscardReloadsExactOwner() async {
        let original = makeCapture(revision: String(repeating: "A", count: 64))
        let changed = makeCapture(revision: String(repeating: "D", count: 64))
        let session = ResultPlanSettingsEditorSession(provider: ResultPlanEditorTestProvider())
        await session.load(original)
        session.draftDescription = "Pending old Result draft"

        await session.load(changed)
        #expect(session.hasUnsavedChanges)
        #expect(!session.isCurrent(changed))
        #expect(session.captureDraft(for: changed) == nil)
        #expect(session.currentOwnerCapture?.identity == original.identity)

        session.discard()
        await session.load(changed)
        #expect(session.isCurrent(changed))
        #expect(session.currentOwnerCapture?.identity == changed.identity)
        #expect(!session.hasUnsavedChanges)
    }

    private func makeCapture(revision: String) -> PlanSettingsResultCapture {
        PlanSettingsResultCapture(owner: PlanSettingsResultOwner(
            projectSessionID: UUID(uuidString: "9A6312BD-5BA6-414E-8D45-E73840B7F3D7")!,
            resultAssetID: "/fixture/Results/Run.h5",
            resultPath: SourceFilePaths.canonical(URL(fileURLWithPath: "/fixture/Results/Run.h5")),
            resultRevision: revision,
            sourceContextID: "result-editor-session"),
            resultName: "Run", assetsRevision: 3,
            projectPath: SourceFilePaths.canonical(URL(fileURLWithPath: "/fixture/Project.ras")),
            projectRevision: String(repeating: "B", count: 64), projectXML: "<Project />")
    }

    private func makeSnapshot(capture: PlanSettingsResultCapture, revision: String,
                              description: String) -> ResultPlanSettingsSnapshot {
        ResultPlanSettingsSnapshot(projectPath: capture.projectPath,
            projectRevision: capture.projectRevision, resultPath: capture.owner.resultPath,
            revision: revision, resultName: capture.resultName, hasPlan: true,
            planName: "Embedded Plan", planDescription: description,
            geometryName: "Embedded Geometry", boundaryConditionName: "Embedded Boundary",
            embeddedPlanGroups: [
                .init(title: "Time Window", items: [.init(label: "Start", value: "2026-10-19", isLocalizedValue: false)]),
                .init(title: "Computation Options", items: [])
            ], images: [])
    }
}

@MainActor
private struct ResultPlanEditorTestProvider: ResultPlanSettingsEditing {
    func inspect(_ capture: PlanSettingsResultCapture) async throws -> PlanSettingsEmbeddedResultSnapshot {
        PlanSettingsEmbeddedResultSnapshot(settings: makeSnapshot(capture: capture,
            revision: capture.owner.resultRevision, description: "Source description"))
    }

    func save(_ capture: ResultPlanSettingsDraftCapture) async throws -> ResultPlanSettingsSaveReceipt {
        let revision = String(repeating: "C", count: 64)
        let settings = makeSnapshot(capture: capture.result, revision: revision,
            description: capture.planDescription)
        return ResultPlanSettingsSaveReceipt(resultPath: capture.result.owner.resultPath,
            previousRevision: capture.result.owner.resultRevision, revision: revision,
            planName: capture.planName, planDescription: capture.planDescription, snapshot: settings)
    }

    private func makeSnapshot(capture: PlanSettingsResultCapture, revision: String,
                              description: String) -> ResultPlanSettingsSnapshot {
        ResultPlanSettingsSnapshot(projectPath: capture.projectPath,
            projectRevision: capture.projectRevision, resultPath: capture.owner.resultPath,
            revision: revision, resultName: capture.resultName, hasPlan: true,
            planName: "Embedded Plan", planDescription: description,
            geometryName: "Embedded Geometry", boundaryConditionName: "Embedded Boundary",
            embeddedPlanGroups: [
                .init(title: "Time Window", items: [.init(label: "Start", value: "2026-10-19", isLocalizedValue: false)]),
                .init(title: "Computation Options", items: [])
            ], images: [])
    }
}
