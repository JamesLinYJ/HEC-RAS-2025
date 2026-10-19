import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

struct ModelEditorResultPlanSettingsLifecycleTests {
    @Test @MainActor
    func embeddedPlanDraftBelongsToResultParentAcrossNavigationAndSelectionChange() async throws {
        let revision = String(repeating: "A", count: 64)
        let modelProvider = ResultPlanParentModelProvider(revision: revision)
        let childProvider = ResultPlanChildProvider()
        let editor = ModelEditorSession(provider: modelProvider,
            resultPlanSettingsProvider: childProvider)
        let first = ProjectAsset(url: URL(fileURLWithPath: "/fixture/Results/First.h5"), section: .results)
        let second = ProjectAsset(url: URL(fileURLWithPath: "/fixture/Results/Second.h5"), section: .results)
        await editor.load(first, kind: .result)

        let child = try #require(editor.resultPlanSettings)
        let capture = childProvider.capture(for: first, revision: revision)
        await child.load(capture)
        #expect(child.currentOwnerCapture?.identity == capture.identity)
        #expect(!editor.modified && !editor.hasUnsavedEditorChanges)

        child.draftDescription = "Pending embedded Plan description"
        #expect(editor.modified && editor.hasUnsavedEditorChanges)
        #expect(!editor.canSave) // This isolated parent has no live Store identity provider.

        // Re-entering the same editor page keeps the single child and its draft.
        await editor.ensureLoaded(first, kind: .result)
        #expect(modelProvider.loadCount == 1)
        #expect(editor.resultPlanSettings === child)
        #expect(child.draftDescription == "Pending embedded Plan description")

        // A new Result cannot silently adopt the old Result's embedded Plan draft.
        await editor.load(second, kind: .result)
        #expect(editor.modelAssetID == first.id)
        #expect(child.currentOwnerCapture?.identity == capture.identity)
        #expect(child.draftDescription == "Pending embedded Plan description")

        editor.discardEdits()
        #expect(!editor.modified && !editor.hasUnsavedEditorChanges)
        #expect(!child.hasUnsavedChanges)
        await editor.load(second, kind: .result)
        #expect(editor.modelAssetID == second.id)
        #expect(child.currentOwnerCapture == nil)
        #expect(modelProvider.loadCount == 2)
    }
}

@MainActor
private final class ResultPlanParentModelProvider: ModelEditorProvider {
    let revision: String
    private(set) var loadCount = 0

    init(revision: String) { self.revision = revision }

    func load(_ asset: ProjectAsset, kind: ModelEditorKind) async throws -> EditorSnapshot {
        loadCount += 1
        return EditorSnapshot(fields: [:], rows: [:], samples: [:], canEdit: false,
            images: [:], sourceRevision: revision)
    }

    func save(_ asset: ProjectAsset, changes: EditorEdits) async throws {}

    func perform(_ asset: ProjectAsset, action: EditorAction) async throws -> EditorSnapshot {
        throw CocoaError(.featureUnsupported)
    }
}

@MainActor
fileprivate struct ResultPlanChildProvider: ResultPlanSettingsEditing {
    func capture(for asset: ProjectAsset, revision: String) -> PlanSettingsResultCapture {
        let projectPath = SourceFilePaths.canonical(URL(fileURLWithPath: "/fixture/Project.ras"))
        let projectRevision = String(repeating: "B", count: 64)
        let projectSessionID = UUID(uuidString: "9A6312BD-5BA6-414E-8D45-E73840B7F3D7")!
        return PlanSettingsResultCapture(owner: PlanSettingsResultOwner(
            projectSessionID: projectSessionID,
            resultAssetID: asset.id,
            resultPath: SourceFilePaths.canonical(asset.url),
            resultRevision: revision,
            sourceContextID: "\(projectSessionID.uuidString)|\(asset.id)|\(projectSessionID):1"),
            resultName: asset.name, assetsRevision: 1,
            projectPath: projectPath, projectRevision: projectRevision,
            projectXML: "<Project />")
    }

    func inspect(_ capture: PlanSettingsResultCapture) async throws -> PlanSettingsEmbeddedResultSnapshot {
        PlanSettingsEmbeddedResultSnapshot(settings: snapshot(capture, description: "Source description"))
    }

    func save(_ capture: ResultPlanSettingsDraftCapture) async throws -> ResultPlanSettingsSaveReceipt {
        throw CocoaError(.featureUnsupported)
    }

    private func snapshot(_ capture: PlanSettingsResultCapture,
                          description: String) -> ResultPlanSettingsSnapshot {
        ResultPlanSettingsSnapshot(projectPath: capture.projectPath,
            projectRevision: capture.projectRevision,
            resultPath: capture.owner.resultPath,
            revision: capture.owner.resultRevision,
            resultName: capture.resultName,
            hasPlan: true,
            planName: "Embedded Plan",
            planDescription: description,
            geometryName: "Geometry",
            boundaryConditionName: "Boundary Conditions",
            embeddedPlanGroups: [
                ResultPlanPropertyGroup(title: "Time Window", items: []),
                ResultPlanPropertyGroup(title: "Computation Options", items: [])
            ],
            images: [])
    }
}
