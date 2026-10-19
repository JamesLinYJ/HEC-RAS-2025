import CryptoKit
import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

@MainActor
private final class PlanResultsFixtureProvider: PlanResultCatalogProvider {
    var results: [PlanResultChoice] = [planResultFixture("/fixture/history.h5")]
    func load(_ context: PlanResultContext) async throws -> PlanResultCatalog {
        .init(projectPath: context.projectPath, planPath: context.planPath,
            revision: context.revision, planName: "Plan", results: results)
    }
}

@MainActor
private final class DelayedPlanResultsProvider: PlanResultCatalogProvider {
    var requests: [(PlanResultContext, CheckedContinuation<PlanResultCatalog, any Error>)] = []
    func load(_ context: PlanResultContext) async throws -> PlanResultCatalog {
        try await withCheckedThrowingContinuation { requests.append((context, $0)) }
    }
}

@Suite(.serialized)
struct PlanResultSelectionTests {
    @Test @MainActor
    func activeResultIsVisualStateAndOnlyUnchangedSourceSelectionsSurviveRefresh() async {
        let provider = PlanResultsFixtureProvider()
        let session = PlanResultSelectionSession(provider: provider)
        let context = planResultContextFixture()
        await session.load(context)
        #expect(session.catalog?.results.count == 1 && session.selection == nil)
        session.select("/fixture/not-a-result.h5")
        #expect(session.selection == nil)
        session.select("/fixture/history.h5")
        #expect(session.selectedResult?.name == "History")
        await session.load(context, force: true)
        #expect(session.selection == "/fixture/history.h5")
        provider.results = [planResultFixture("/fixture/history.h5", revision: "new-source")]
        await session.load(context, force: true)
        #expect(session.selection == nil && session.catalog?.results.first?.revision == "new-source")
        session.select("/fixture/history.h5")
        session.removeResult(at: "/fixture/history.h5")
        #expect(session.catalog == nil && session.selection == nil && session.context == nil)
    }

    @Test @MainActor
    func oldPlanReplyCannotReplaceANewerPlanSelection() async throws {
        let provider = DelayedPlanResultsProvider()
        let session = PlanResultSelectionSession(provider: provider)
        let first = planResultContextFixture()
        var second = first
        second = .init(projectSessionID: first.projectSessionID, projectPath: first.projectPath,
            projectXML: first.projectXML, planPath: "/fixture/second.h5", revision: "second", assetsRevision: 1)
        let firstTask = Task { await session.load(first) }
        try await waitForPlanRequests(provider, count: 1)
        let secondTask = Task { await session.load(second) }
        try await waitForPlanRequests(provider, count: 2)
        provider.requests[1].1.resume(returning: .init(projectPath: second.projectPath,
            planPath: second.planPath, revision: second.revision, planName: "Plan", results: []))
        await secondTask.value
        provider.requests[0].1.resume(throwing: BackendServiceError(code: "sourceChanged", message: "Old failure"))
        await firstTask.value
        #expect(session.catalog?.planPath == second.planPath && session.error == nil && !session.isLoading)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HECRAS_PLAN_RESULT_ACCEPTANCE_DIRECTORY"] != nil)) @MainActor
    func actualNameMatchedResultCatalogSelectionNeverBecomesAModelDraft() async throws {
        let fixture = try #require(ProcessInfo.processInfo.environment["HECRAS_PLAN_RESULT_ACCEPTANCE_DIRECTORY"])
        let executable = try #require(ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"])
        let source = URL(fileURLWithPath: fixture)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("plan-results-" + UUID().uuidString)
        try FileManager.default.copyItem(at: source, to: folder)
        defer { try? FileManager.default.removeItem(at: folder) }
        let projectURL = folder.appendingPathComponent("相关结果.ras")
        let project = try ProjectDocument(contentsOf: projectURL)
        let before = try planResultFileHashes(folder)
        let client = BackendProcessClient(executableURL: URL(fileURLWithPath: executable))
        let provider = BackendModelProvider(client: client)
        provider.setProject(project)
        let model = ModelEditorSession(provider: provider)
        let asset = try #require(project.assets.first { $0.section == .plans && $0.name == "计划一" })
        await model.load(asset, kind: .plan)
        #expect(model.error == nil && model.loaded && !model.modified)
        let context = try #require(model.planResultContext(projectSessionID: UUID(), assetsRevision: 0))
        let results = try #require(model.planResults)
        await results.load(context)
        #expect(results.error == nil && results.catalog?.results.count == 2)
        let selected = try #require(results.catalog?.results.first)
        #expect(selected.embeddedPlanName == "计划一" && selected.name != "计划一")
        results.select(selected.id)
        #expect(results.selectedResult?.resultPath == selected.resultPath)
        #expect(!model.modified && model.fields["PlanNodeDetails/Plan_ActiveResult_Result"] == nil)
        #expect(try planResultFileHashes(folder) == before)
        model.invalidateForProjectReplacement()
        #expect(results.selection == nil && results.catalog == nil)
    }
}

private func planResultFixture(_ path: String, revision: String = "result-source") -> PlanResultChoice {
    .init(resultPath: path, revision: revision, name: "History", embeddedPlanName: "Plan", hasComputed: false, profileCount: 0)
}
private func planResultContextFixture() -> PlanResultContext {
    .init(projectSessionID: UUID(), projectPath: "/fixture/Project.ras", projectXML: "<Project/>",
        planPath: "/fixture/Plan.h5", revision: "plan-source", assetsRevision: 0)
}
@MainActor
private func waitForPlanRequests(_ provider: DelayedPlanResultsProvider, count: Int) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while provider.requests.count < count && ContinuousClock.now < deadline { await Task.yield() }
    #expect(provider.requests.count == count)
    try #require(provider.requests.count == count)
}
private func planResultFileHashes(_ folder: URL) throws -> [String: String] {
    let files = try #require(FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey]))
    var hashes: [String: String] = [:]
    for case let file as URL in files where (try file.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true {
        hashes[file.path] = SHA256.hash(data: try Data(contentsOf: file)).map { String(format: "%02x", $0) }.joined()
    }
    return hashes
}
