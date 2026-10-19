import CryptoKit
import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

struct BackendLinkedResultProfilesTests {
    private struct Fixture: Decodable { let project: String; let anchor: String; let candidate: String }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HECRAS_LINKED_PROFILE_ACCEPTANCE_DIRECTORY"] != nil)) @MainActor
    func acceptedPlanGroupsScrubDifferentStoredResultIndicesThroughTheProductionHost() async throws {
        let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["HECRAS_LINKED_PROFILE_ACCEPTANCE_DIRECTORY"]))
        let executable = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"]))
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: directory.appendingPathComponent("LINKED_PROFILE_FIXTURE.json")))
        let project = directory.appendingPathComponent(fixture.project), anchor = directory.appendingPathComponent(fixture.anchor)
        let projectBefore = try Data(contentsOf: project), anchorBefore = try Data(contentsOf: anchor)
        let candidate = directory.appendingPathComponent(fixture.candidate), candidateBefore = try Data(contentsOf: directory.appendingPathComponent(fixture.candidate))
        let revision = SHA256.hash(data: anchorBefore).map { String(format: "%02X", $0) }.joined()
        let client = BackendProcessClient(executableURL: executable)
        let xml = try #require(String(data: projectBefore, encoding: .utf8))
        let context = try await client.request("result.planContext", parameters:
            ResultPlanContextRequest(projectPath: project.path, projectXml: xml, resultPath: anchor.path, revision: revision),
            as: ResultPlanContextSnapshot.self)
        let group = try #require(context.candidateGroups.first { $0.planName == "Shifted plan" })
        let selection = LinkedResultSelection(projectPath: context.projectPath, projectRevision: context.projectRevision,
            anchor: context.anchor, selectedGroups: [group])
        let session = LinkedResultProfilesSession(client: client)
        await session.load(selection, projectXML: xml, profileIndex: 0)
        let first = try #require(session.snapshot)
        #expect(session.error == nil && !session.isLoading && first.steps.count == 3)
        #expect(first.frames[0].profileIndex == 0 && first.frames[1].profileIndex == nil)
        #expect(first.frames[1].unavailableReason != nil && first.frames[1].nearestProfileIndex == 0)
        await session.load(selection, projectXML: xml, profileIndex: 1)
        let second = try #require(session.snapshot)
        #expect(second.frames[0].profileIndex == 1 && second.frames[1].profileIndex == 0)
        #expect(second.frames[0].time == second.frames[1].time)
        #expect(try Data(contentsOf: project) == projectBefore)
        #expect(try Data(contentsOf: anchor) == anchorBefore)
        #expect(try Data(contentsOf: candidate) == candidateBefore)
        session.cancel()
        #expect(session.snapshot == nil && !session.isLoading)
    }
}
