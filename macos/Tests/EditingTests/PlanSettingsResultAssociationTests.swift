import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

@MainActor
struct PlanSettingsResultAssociationTests {
    @Test
    func resultPlanSettingsRequireOneExactNestedResultAndMatchingSourceRevisions() {
        let capture = capture()
        let exact = snapshot(capture: capture)

        #expect(PlanSettingsResultSession.accepts(exact, capture: capture))
        #expect(!PlanSettingsResultSession.accepts(snapshot(capture: capture,
            resultPath: "/project/Results/Other.h5"), capture: capture))
        #expect(!PlanSettingsResultSession.accepts(snapshot(capture: capture,
            resultRevision: String(repeating: "C", count: 64)), capture: capture))
        #expect(!PlanSettingsResultSession.accepts(snapshot(capture: capture,
            projectRevision: String(repeating: "D", count: 64)), capture: capture))
    }

    @Test
    func aResultWithoutAnEmbeddedPlanHasNoPlanNamesOrSettingsToReuse() {
        let capture = capture()
        #expect(PlanSettingsResultSession.accepts(snapshot(capture: capture, hasPlan: false),
            capture: capture))
    }

    @Test
    func embeddedDescriptionAndImageMustBelongToTheExactPlanDataset() {
        let capture = capture()
        let image = ResultPlanSettingsImage(id: "/Plan Data/Images/plan.png",
            name: "plan.png", description: "Embedded image", dateLastModified: nil,
            x: 12.5, y: -4.25, byteCount: 4, data: Data([1, 2, 3, 4]))
        let exact = snapshot(capture: capture, description: "Embedded Plan description", images: [image])
        #expect(PlanSettingsResultSession.accepts(exact, capture: capture))
        #expect(exact.settings.planDescription == "Embedded Plan description")
        #expect(exact.settings.images == [image])

        let wrongDataset = ResultPlanSettingsImage(id: "/Plan Data/Images/other.png",
            name: "plan.png", description: "Embedded image", dateLastModified: nil,
            x: 12.5, y: -4.25, byteCount: 4, data: Data([1, 2, 3, 4]))
        #expect(!PlanSettingsResultSession.accepts(
            snapshot(capture: capture, description: "Embedded Plan description", images: [wrongDataset]),
            capture: capture))

        let wrongSize = ResultPlanSettingsImage(id: image.id, name: image.name,
            description: image.description, dateLastModified: image.dateLastModified,
            x: image.x, y: image.y, byteCount: image.byteCount + 1, data: image.data)
        #expect(!PlanSettingsResultSession.accepts(
            snapshot(capture: capture, description: "Embedded Plan description", images: [wrongSize]),
            capture: capture))
    }

    private func capture() -> PlanSettingsResultCapture {
        PlanSettingsResultCapture(owner: PlanSettingsResultOwner(
            projectSessionID: UUID(), resultAssetID: "/project/Results/Run.h5",
            resultPath: "/project/Results/Run.h5", resultRevision: String(repeating: "A", count: 64),
            sourceContextID: "result-editor-context"),
            resultName: "Run", assetsRevision: 4,
            projectPath: "/project/Project.ras", projectRevision: String(repeating: "B", count: 64),
            projectXML: "<Project />")
    }

    private func snapshot(capture: PlanSettingsResultCapture,
                          resultPath: String? = nil,
                          resultRevision: String? = nil,
                          projectRevision: String? = nil,
                          hasPlan: Bool = true,
                          description: String? = nil,
                          images: [ResultPlanSettingsImage] = []) -> PlanSettingsEmbeddedResultSnapshot {
        let groups: [ResultPlanPropertyGroup] = hasPlan ? [
            .init(title: "Time Window", items: [.init(label: "Start", value: "2026-10-19", isLocalizedValue: false)]),
            .init(title: "Computation Options", items: [])
        ] : []
        return PlanSettingsEmbeddedResultSnapshot(settings: ResultPlanSettingsSnapshot(
            projectPath: capture.projectPath,
            projectRevision: projectRevision ?? capture.projectRevision,
            resultPath: resultPath ?? capture.owner.resultPath,
            revision: resultRevision ?? capture.owner.resultRevision,
            resultName: capture.resultName, hasPlan: hasPlan,
            planName: hasPlan ? "Embedded Plan" : nil,
            planDescription: hasPlan ? description : nil,
            geometryName: hasPlan ? "Embedded Geometry" : nil,
            boundaryConditionName: hasPlan ? "Embedded Boundary" : nil,
            embeddedPlanGroups: groups, images: images))
    }
}
