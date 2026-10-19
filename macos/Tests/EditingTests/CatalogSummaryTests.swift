import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

@MainActor
private final class DeferredCatalogSummaryProvider: ModelEditorProvider {
    private var pending: [Int: CheckedContinuation<EditorSnapshot, any Error>] = [:]
    private var startWaiters: [Int: CheckedContinuation<Void, Never>] = [:]
    private(set) var requestedAssetIDs: [String] = []
    private(set) var saved: [EditorEdits] = []

    func load(_ asset: ProjectAsset, kind: ModelEditorKind) async throws -> EditorSnapshot {
        let request = requestedAssetIDs.count
        requestedAssetIDs.append(asset.id)
        startWaiters.removeValue(forKey: requestedAssetIDs.count)?.resume()
        return try await withCheckedThrowingContinuation { pending[request] = $0 }
    }

    func save(_ asset: ProjectAsset, changes: EditorEdits) async throws { saved.append(changes) }
    func perform(_ asset: ProjectAsset, action: EditorAction) async throws -> EditorSnapshot { throw CancellationError() }

    func waitForLoadCount(_ count: Int) async {
        guard requestedAssetIDs.count < count else { return }
        await withCheckedContinuation { startWaiters[count] = $0 }
    }

    func finish(_ request: Int, fields: [String: String]) {
        pending.removeValue(forKey: request)?.resume(returning: .init(
            fields: fields, rows: [:], samples: [:], canEdit: true, images: [:]
        ))
    }
}

struct CatalogSummaryTests {
    @Test
    func planSummaryUsesExactSourceFieldIDs() {
        let fields = [
            "PlanCatalogSummary/Context_Name": "Plan A",
            "PlanCatalogSummary/Context_Filename": "/project/Plans/Plan A.h5",
            "PlanCatalogSummary/Context_Layer_DateCreated": "2026-10-16 06:45:57",
            "PlanCatalogSummary/Context_Layer_DateLastModified": "2026-10-16 07:00:00",
            "PlanCatalogSummary/Context_Description": "Original description",
            "Unrelated/Name": "Not the selected plan"
        ]

        #expect(CatalogSummarySnapshotMapper.kind(for: .plan, sourceFields: fields) == .plan)
        let sections = CatalogSummarySnapshotMapper.sections(for: .plan, sourceFields: fields)
        #expect(sections.map(\.schemaID) == ["PlanCatalogSummary"])
        #expect(sections[0].fields.map(\.id) == [
            "PlanCatalogSummary/Context_Name",
            "PlanCatalogSummary/Context_Filename",
            "PlanCatalogSummary/Context_Layer_DateCreated",
            "PlanCatalogSummary/Context_Layer_DateLastModified",
            "PlanCatalogSummary/Context_Description"
        ])
        #expect(sections[0].fields.first(where: { $0.id.hasSuffix("/Context_Description") })?.value == "Original description")
        let blankDescription = CatalogSummarySnapshotMapper.sections(for: .plan, sourceFields: [
            "PlanCatalogSummary/Context_Name": "Plan A",
            "PlanCatalogSummary/Context_Description": ""
        ])
        #expect(blankDescription.first?.fields.first(where: { $0.id.hasSuffix("/Context_Description") })?.value == "")
        #expect(blankDescription.first?.unavailableFields.contains("Description") == false)
    }

    @Test
    func surfaceSummaryKindComesFromSourceSchemaScope() {
        let classificationFields = [
            "ClassificationCatalogSummary/Context_Name": "Land Cover",
            "ClassificationLayerSummary/ClassificationLayer_ClassificationLayer_LoadedFileVersion": "2"
        ]
        #expect(CatalogSummarySnapshotMapper.kind(for: .surface, sourceFields: classificationFields) == .classification)
        #expect(CatalogSummarySnapshotMapper.sections(for: .classification, sourceFields: classificationFields).map(\.schemaID) == [
            "ClassificationCatalogSummary", "ClassificationLayerSummary"
        ])
        #expect(CatalogSummarySnapshotMapper.kind(for: .surface, sourceFields: ["NValueCatalogSummary/Context_Name": "Manning"] ) == .nValue)
        #expect(CatalogSummarySnapshotMapper.kind(for: .surface, sourceFields: [
            "NValueCatalogSummary/Context_Name": "Manning",
            "ClassificationCatalogSummary/Context_Name": "Land Cover"
        ]) == nil)
    }

    @Test
    func embeddedImagesUseSourceAliasesOnceAndRetainTheirSourceName() {
        let image = ImageAttachment(id: "source-image-id", name: "Plan image.png", data: Data([1, 2, 3]))
        let duplicateAlias = ImageAttachment(id: image.id, name: "Plan image.png", data: Data([1, 2, 3]))
        let images = CatalogSummarySnapshotMapper.embeddedImages(from: [
            "PlanSettingsPage/ViewModel_SelectedPlan_EmbeddedImages": [image],
            "RasCatalogSummary/EmbeddedImages": [duplicateAlias]
        ])

        #expect(images.count == 1)
        #expect(images.first?.name == "Plan image.png")
    }

    @Test @MainActor
    func lateAssetSummaryResponseCannotReplaceNewSelection() async {
        let provider = DeferredCatalogSummaryProvider()
        let session = CatalogAssetSummarySession()
        let first = ProjectAsset(url: URL(fileURLWithPath: "/fixture/first.h5"), section: .plans)
        let second = ProjectAsset(url: URL(fileURLWithPath: "/fixture/second.h5"), section: .plans)
        let projectID = UUID()
        let oldRequest = Task {
            await session.load(asset: first, projectSessionID: projectID, assetsRevision: 1,
                               editorKind: .plan, provider: provider)
        }
        await provider.waitForLoadCount(1)
        let newRequest = Task {
            await session.load(asset: second, projectSessionID: projectID, assetsRevision: 2,
                               editorKind: .plan, provider: provider)
        }
        await provider.waitForLoadCount(2)

        provider.finish(1, fields: ["PlanCatalogSummary/Context_Name": "Second plan"])
        await newRequest.value
        #expect(session.sections.first?.fields.first?.value == "Second plan")
        provider.finish(0, fields: ["PlanCatalogSummary/Context_Name": "Stale first plan"])
        await oldRequest.value
        #expect(session.sections.first?.fields.first?.value == "Second plan")
        #expect(provider.saved.isEmpty)
    }

    @Test @MainActor
    func lateProjectSummaryResponseCannotReplaceCurrentProject() async {
        let provider = DeferredCatalogSummaryProvider()
        let session = CatalogAssetSummarySession()
        let asset = ProjectAsset(url: URL(fileURLWithPath: "/fixture/shared-plan.h5"), section: .plans)
        let oldProjectID = UUID()
        let currentProjectID = UUID()
        let oldRequest = Task {
            await session.load(asset: asset, projectSessionID: oldProjectID, assetsRevision: 5,
                               editorKind: .plan, provider: provider)
        }
        await provider.waitForLoadCount(1)
        let currentRequest = Task {
            await session.load(asset: asset, projectSessionID: currentProjectID, assetsRevision: 5,
                               editorKind: .plan, provider: provider)
        }
        await provider.waitForLoadCount(2)

        provider.finish(1, fields: ["PlanCatalogSummary/Context_Name": "Current project plan"])
        await currentRequest.value
        provider.finish(0, fields: ["PlanCatalogSummary/Context_Name": "Old project plan"])
        await oldRequest.value
        #expect(session.sections.first?.fields.first?.value == "Current project plan")
        #expect(provider.saved.isEmpty)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"] != nil
                   && ProcessInfo.processInfo.environment["HECRAS_PLAN_CONTEXT_ACCEPTANCE_DIRECTORY"] != nil)) @MainActor
    func actualBackendPlanSummaryIncludesEmbeddedSourceImageAndLeavesEditorDraftUntouched() async throws {
        let executable = try #require(ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"])
        let fixture = try #require(ProcessInfo.processInfo.environment["HECRAS_PLAN_CONTEXT_ACCEPTANCE_DIRECTORY"])
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-plan-summary-" + UUID().uuidString)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: fixture), to: folder)
        defer { try? FileManager.default.removeItem(at: folder) }

        let project = try ProjectDocument(contentsOf: folder.appendingPathComponent("Plan Context Refresh.ras"))
        let plan = try #require(project.assets.first { $0.section == .plans && $0.name == "Plan A" })
        let provider = BackendModelProvider(client: .init(executableURL: URL(fileURLWithPath: executable)))
        provider.setProject(project)
        let draft = ModelEditorSession(provider: provider)
        draft.set("PlanSettingsPage/ViewModel_SelectedPlan_Description", "unsaved editor draft")
        let summary = CatalogAssetSummarySession()

        await summary.load(asset: plan, projectSessionID: UUID(), assetsRevision: 1,
                           editorKind: .plan, provider: provider)

        #expect(summary.kind == .plan)
        #expect(summary.sections.first?.fields.first(where: { $0.id == "PlanCatalogSummary/Context_Name" })?.value == "Plan A")
        #expect(summary.images.map(\.name) == ["plan.png"])
        #expect(draft.fields["PlanSettingsPage/ViewModel_SelectedPlan_Description"] == "unsaved editor draft")
        #expect(draft.modified)
    }
}
