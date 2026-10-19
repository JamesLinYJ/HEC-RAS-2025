import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

struct BackendResultPlanComparisonTests {
    private struct Fixture: Decodable { let project: String; let anchor: String; let candidate: String }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HECRAS_LINKED_PROFILE_ACCEPTANCE_DIRECTORY"] != nil))
    @MainActor
    func comparisonAcceptsOnlyCurrentWholeSourceGroupsAndFeedsTheRealKeyedProfiles() async throws {
        let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["HECRAS_LINKED_PROFILE_ACCEPTANCE_DIRECTORY"]))
        let executable = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"]))
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: directory.appendingPathComponent("LINKED_PROFILE_FIXTURE.json")))
        let project = directory.appendingPathComponent(fixture.project)
        let anchor = directory.appendingPathComponent(fixture.anchor)
        let candidate = directory.appendingPathComponent(fixture.candidate)
        let original = try [project, anchor, candidate].map { try Data(contentsOf: $0) }
        let xml = try #require(String(data: original[0], encoding: .utf8))
        let client = BackendProcessClient(executableURL: executable)
        let asset = ProjectAsset(url: anchor, section: .results)
        let inspector = ResultInspectorSession(provider: BackendResultInspectorProvider(client: client))
        await inspector.ensureLoaded(asset: asset, projectPath: project, projectXML: xml,
            sourceContextRevision: "comparison-owner")
        let inspected = try #require(inspector.snapshot)
        let plans = ResultPlanContextSession(provider: BackendResultPlanContextProvider(client: client))
        await plans.ensureLoaded(asset: asset, projectPath: project, projectXml: xml,
            inspectorSnapshot: inspected, sourceContextRevision: "comparison-owner")
        let context = try #require(plans.snapshot)
        let group = try #require(context.candidateGroups.first { $0.planName == "Shifted plan" })
        let accepted = LinkedResultSelection(projectPath: context.projectPath,
            projectRevision: context.projectRevision, anchor: context.anchor, selectedGroups: [group])
        func accepts(_ selection: LinkedResultSelection, sourceContext: String = "comparison-owner",
                     projectXML: String? = nil, selectedAsset: ProjectAsset? = nil) -> Bool {
            plans.accepts(selection, asset: selectedAsset ?? asset, projectPath: project,
                projectXml: projectXML ?? xml, inspectorSnapshot: inspected,
                sourceContextRevision: sourceContext)
        }
        #expect(accepts(accepted))
        #expect(!accepts(accepted, sourceContext: "another-project-session"))
        #expect(!accepts(accepted, projectXML: xml + "\n"))
        #expect(!accepts(accepted, selectedAsset: ProjectAsset(url: candidate, section: .results)))
        #expect(!accepts(LinkedResultSelection(projectPath: context.projectPath,
            projectRevision: context.projectRevision, anchor: context.anchor, selectedGroups: [])))
        #expect(!accepts(LinkedResultSelection(projectPath: context.projectPath,
            projectRevision: context.projectRevision, anchor: context.anchor, selectedGroups: [group, group])))
        let first = try #require(group.results.first)
        let changed = ResultPlanCandidate(resultPath: first.resultPath, revision: "STALE",
            name: first.name, planName: first.planName, hasPlan: first.hasPlan)
        let forged = ResultPlanCandidateGroup(planName: group.planName, hasPlan: group.hasPlan,
            results: [changed] + group.results.dropFirst())
        #expect(!accepts(LinkedResultSelection(projectPath: context.projectPath,
            projectRevision: context.projectRevision, anchor: context.anchor, selectedGroups: [forged])))

        let linked = LinkedResultProfilesSession(client: client)
        await linked.load(accepted, projectXML: xml, profileIndex: 1)
        let frame = try #require(linked.snapshot)
        #expect(linked.error == nil && frame.frames.count == accepted.results.count)
        #expect(frame.frames[0].profileIndex == 1 && frame.frames[1].profileIndex == 0)
        #expect(frame.frames[0].time == frame.frames[1].time)
        plans.invalidate()
        #expect(!accepts(accepted))
        #expect(try [project, anchor, candidate].map { try Data(contentsOf: $0) } == original)
    }
}
