import Foundation
import Testing
@testable import HECRAS2025
@testable import RASWorkspaceCore

struct BackendPlanContextTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HECRAS_PLAN_CONTEXT_ACCEPTANCE_DIRECTORY"] != nil)) @MainActor
    func actualPlanContextRefreshRebasesDraftsWithoutWritingProjectOrModels() async throws {
        let executable = try #require(ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"])
        let fixture = try #require(ProcessInfo.processInfo.environment["HECRAS_PLAN_CONTEXT_ACCEPTANCE_DIRECTORY"])
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("plan-context-refresh-" + UUID().uuidString)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: fixture), to: folder)
        defer { try? FileManager.default.removeItem(at: folder) }

        let projectPath = folder.appendingPathComponent("Plan Context Refresh.ras")
        let project = try ProjectDocument(contentsOf: projectPath)
        let provider = BackendModelProvider(client: .init(executableURL: URL(fileURLWithPath: executable)))
        provider.setProject(project)
        let plan = try #require(project.assets.first { $0.section == .plans && $0.name == "Plan A" })
        let boundaryA = try #require(project.assets.first { $0.section == .boundaryConditions && $0.name == "Boundary A" })
        let boundaryB = try #require(project.assets.first { $0.section == .boundaryConditions && $0.name == "Boundary B" })
        let session = ModelEditorSession(provider: provider)
        await session.load(plan, kind: .plan)
        #expect(session.loaded && session.canEdit && session.error == nil)

        let description = "PlanSettingsPage/ViewModel_SelectedPlan_Description"
        let mode = "PlanSettingsPage/ViewModel_SelectedPlan_TimeWindowMode"
        let start = "PlanSettingsPage/ViewModel_SelectedPlan_ComputeStartTime"
        let end = "PlanSettingsPage/ViewModel_SelectedPlan_ComputeEndTime"
        let embeddedImages = "PlanSettingsPage/ViewModel_SelectedPlan_EmbeddedImages"
        let descriptionBefore = try #require(session.fields[description])
        let loadedStart = try #require(session.fields[start])
        #expect(loadedStart.contains("2026-10-01") && session.fields[mode] == "BoundaryCondition")
        let sourceImages = try #require(session.images[embeddedImages])
        #expect(sourceImages.count == 1)

        let originalProjectBytes = try Data(contentsOf: projectPath)
        let originalPlanBytes = try Data(contentsOf: plan.url)
        let originalBoundaryABytes = try Data(contentsOf: boundaryA.url)
        let originalBoundaryBBytes = try Data(contentsOf: boundaryB.url)
        let association = try #require(project.associationRows(group: "PlanAssociations").first { $0.name == plan.name })
        try project.setAssociation(association, field: "BoundaryCondition", value: boundaryB.name)
        #expect(project.editorXML.contains("BoundaryCondition=\"Boundary B\""))

        let descriptionDraft = "Unsaved refreshed plan description 🌊"
        session.set(description, descriptionDraft)
        let localImage = ImageAttachment(id: "swift-local-image", name: "draft.png", data: sourceImages[0].data)
        session.addImage(embeddedImages, image: localImage)
        #expect(session.modified)
        #expect(await session.refreshProjectContext())
        #expect(session.error == nil)
        #expect(session.fields[description] == descriptionDraft)
        #expect(session.fields[mode] == "BoundaryCondition")
        #expect(session.fields[start]?.contains("2026-10-03") == true)
        #expect(session.fields[start]?.contains("06:00:00") == true)
        #expect(session.fields[end]?.contains("2026-10-04") == true)
        #expect(session.fields[end]?.contains("12:00:00") == true)
        let inheritedBoundaryStart = try #require(session.fields[start])
        #expect(session.images[embeddedImages]?.map(\.id) == sourceImages.map(\.id) + [localImage.id])
        #expect(session.modified)
        #expect(sourceBytesRemainUnchanged())

        session.discardEdits()
        #expect(!session.modified && session.error == nil)
        #expect(session.fields[description] == descriptionBefore)
        #expect(session.fields[mode] == "BoundaryCondition")
        #expect(session.fields[start]?.contains("2026-10-03") == true)
        #expect(session.fields[start]?.contains("06:00:00") == true)
        #expect(session.fields[end]?.contains("2026-10-04") == true)
        #expect(session.fields[end]?.contains("12:00:00") == true)
        #expect(session.images[embeddedImages]?.map(\.id) == sourceImages.map(\.id))

        // The source returns local-offset ISO strings. Compare their exact
        // instants rather than requiring the input's particular UTC spelling.
        func instant(_ value: String?) throws -> Date {
            let raw = try #require(value)
            return try #require(ISO8601DateFormatter().date(from: raw))
        }
        let expectedStart = try instant("2026-10-06T07:00:00+00:00")
        let expectedEnd = try instant("2026-10-07T19:30:00+00:00")
        session.set(mode, "Plan")
        session.set(start, "2026-10-06T07:00:00+00:00")
        session.set(end, "2026-10-07T19:30:00+00:00")
        #expect(await session.refreshProjectContext())
        #expect(session.fields[mode] == "Plan")
        #expect(try instant(session.fields[start]) == expectedStart)
        #expect(try instant(session.fields[end]) == expectedEnd)
        #expect(session.fields[start] != inheritedBoundaryStart)
        #expect(session.modified)
        #expect(sourceBytesRemainUnchanged())

        session.set(mode, "BoundaryCondition")
        #expect(await session.refreshProjectContext())
        #expect(session.error == nil)
        #expect(session.fields[mode] == "BoundaryCondition")
        #expect(session.fields[start]?.contains("2026-10-03") == true)
        #expect(session.fields[start]?.contains("06:00:00") == true)
        #expect(session.fields[end]?.contains("2026-10-04") == true)
        #expect(session.fields[end]?.contains("12:00:00") == true)

        session.set(mode, "Plan")
        #expect(await session.refreshProjectContext())
        #expect(session.fields[mode] == "Plan")
        #expect(try instant(session.fields[start]) == expectedStart)
        #expect(try instant(session.fields[end]) == expectedEnd)
        #expect(session.modified)
        #expect(sourceBytesRemainUnchanged())

        #expect(await session.saveLoadedModel())
        #expect(session.error == nil && !session.modified)
        let savedPlanBytes = try Data(contentsOf: plan.url)
        #expect(savedPlanBytes != originalPlanBytes)
        #expect(try Data(contentsOf: projectPath) == originalProjectBytes)
        #expect(try Data(contentsOf: boundaryA.url) == originalBoundaryABytes)
        #expect(try Data(contentsOf: boundaryB.url) == originalBoundaryBBytes)

        await session.load(plan, kind: .plan)
        #expect(session.loaded && session.error == nil)
        #expect(session.fields[mode] == "Plan")
        #expect(try instant(session.fields[start]) == expectedStart)
        #expect(try instant(session.fields[end]) == expectedEnd)

        session.set(mode, "BoundaryCondition")
        #expect(await session.refreshProjectContext())
        #expect(session.fields[start]?.contains("2026-10-03") == true)
        try project.setAssociation(association, field: "BoundaryCondition", value: "")
        #expect(await session.refreshProjectContext())
        #expect(session.error == nil)
        #expect(session.fields[mode] == "BoundaryCondition")
        #expect(try instant(session.fields[start]) == expectedStart)
        #expect(try instant(session.fields[end]) == expectedEnd)
        #expect(session.modified)
        session.discardEdits()
        #expect(!session.modified)
        #expect(session.fields[mode] == "Plan")
        #expect(try instant(session.fields[start]) == expectedStart)
        #expect(try instant(session.fields[end]) == expectedEnd)
        #expect(try Data(contentsOf: projectPath) == originalProjectBytes)
        #expect(try Data(contentsOf: boundaryA.url) == originalBoundaryABytes)
        #expect(try Data(contentsOf: boundaryB.url) == originalBoundaryBBytes)

        var externallyChangedPlan = savedPlanBytes
        externallyChangedPlan.append(0)
        try externallyChangedPlan.write(to: plan.url, options: .atomic)
        let staleEdits = EditorEdits(fields: [:], rows: [:], images: [:], sourceRevision: session.sourceFileRevision)
        do {
            _ = try await provider.refreshProjectContext(plan, edits: staleEdits)
            Issue.record("A stale plan SHA must be rejected by the bundled backend")
        } catch let error as BackendServiceError {
            #expect(error.code == "sourceChanged")
        }
        #expect(!(await session.refreshProjectContext()))
        #expect(session.error != nil)
        #expect(try Data(contentsOf: projectPath) == originalProjectBytes)
        #expect(try Data(contentsOf: boundaryA.url) == originalBoundaryABytes)
        #expect(try Data(contentsOf: boundaryB.url) == originalBoundaryBBytes)
        #expect(try Data(contentsOf: plan.url) == externallyChangedPlan)

        func sourceBytesRemainUnchanged() -> Bool {
            (try? Data(contentsOf: projectPath)) == originalProjectBytes &&
                (try? Data(contentsOf: plan.url)) == originalPlanBytes &&
                (try? Data(contentsOf: boundaryA.url)) == originalBoundaryABytes &&
                (try? Data(contentsOf: boundaryB.url)) == originalBoundaryBBytes
        }
    }
}
