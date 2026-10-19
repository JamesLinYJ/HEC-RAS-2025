import CryptoKit
import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

@MainActor
private final class CatalogHeaderSnapshotProvider: LayerTreeProvider {
    let snapshot: LayerTreeSnapshot

    init(_ snapshot: LayerTreeSnapshot) { self.snapshot = snapshot }

    func load(_ context: LayerTreeContext) async throws -> LayerTreeSnapshot { snapshot }
    func perform(_ action: LayerTreeAction, context: LayerTreeContext) async throws -> LayerTreeSnapshot {
        throw CocoaError(.featureUnsupported)
    }
}

struct CatalogHeaderActionsTests {
    @Test @MainActor
    func incompleteRemovalCaptureUsesExactCurrentResultRowsAndSafeDeletionLease() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("catalog-result-header-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Results", isDirectory: true),
                                               withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let projectURL = folder.appendingPathComponent("Header Actions.ras")
        try Data("<Project><Description>Original project</Description></Project>".utf8).write(to: projectURL)
        let failedURL = try resultFile(folder, name: "Failed Run", bytes: "failed source")
        let noSummaryURL = try resultFile(folder, name: "No Summary", bytes: "uncomputed source")
        let completedURL = try resultFile(folder, name: "Completed Run", bytes: "completed source")
        let mismatchedURL = try resultFile(folder, name: "Mismatched Row", bytes: "mismatched source")
        let duplicateAURL = try resultFile(folder, name: "Duplicate A", bytes: "duplicate a")
        let duplicateBURL = try resultFile(folder, name: "Duplicate B", bytes: "duplicate b")

        let services = SourceWorkflowFixtureServices(recoveryFolder: folder.appendingPathComponent("Trash"))
        let store = WorkspaceStore(system: services)
        store.requestOpen(projectURL)
        try await waitForProject(store)

        func node(_ url: URL, name: String, state: String?) throws -> LayerTreeNode {
            LayerTreeNode(id: "result:" + url.lastPathComponent, sourceClass: "ObservableResult", name: name,
                assetID: url.path, resultComputeState: state,
                resultComputeSourcePath: url.path,
                resultComputeSourceRevision: try revision(url))
        }

        let failed = try node(failedURL, name: "Failed Run", state: "failed")
        let noSummary = try node(noSummaryURL, name: "No Summary", state: nil)
        let completed = try node(completedURL, name: "Completed Run", state: "completed")
        let mismatched = LayerTreeNode(id: "result:mismatched", sourceClass: "ObservableResult",
            name: "Mismatched Row", assetID: mismatchedURL.path,
            resultComputeState: "failed", resultComputeSourcePath: failedURL.path,
            resultComputeSourceRevision: try revision(failedURL))
        let duplicateA = try node(duplicateAURL, name: "Same name", state: "failed")
        let duplicateB = try node(duplicateBURL, name: "Same name", state: "failed")
        let resultRoot = LayerTreeNode(id: "results", sourceClass: "ResultRootContext", name: "Results",
            children: [failed, noSummary, completed, mismatched, duplicateA, duplicateB])
        let projectRoot = LayerTreeNode(id: "project", sourceClass: "ModelSectionContext", name: "Project",
            children: [resultRoot])
        await store.catalogTreeSession.load(
            provider: CatalogHeaderSnapshotProvider(.init(roots: [projectRoot])),
            context: store.catalogTreeContext)

        let capturedRoot = try #require(store.catalogTreeSession.node(withID: resultRoot.id))
        let plan = try #require(IncompleteResultRemovalPlan.capture(root: capturedRoot, store: store))
        #expect(plan.candidates.map(\.sourceName) == ["Failed Run", "No Summary"])
        // Preserve the source-row order while comparing file identity through
        // the same symlink-aware canonicalization used by capture and deletion.
        let candidatePaths = plan.candidates.map { SourceFilePaths.canonical($0.asset.url) }
        let expectedPaths = [failedURL, noSummaryURL].map { SourceFilePaths.canonical($0) }
        #expect(candidatePaths == expectedPaths)
        #expect(plan.withheldCount == 3)
        #expect(plan.stillOwnsProject(store))

        let deleteAssetID = try #require(plan.candidates.first?.asset.id)
        #expect(!store.beginResultDeletion(assetID: deleteAssetID, projectSessionID: UUID()))
        #expect(store.beginResultDeletion(assetID: deleteAssetID, projectSessionID: plan.projectSessionID))
        #expect(store.isRunningProjectTool)
        #expect(!store.beginResultDeletion(assetID: deleteAssetID, projectSessionID: plan.projectSessionID))
        store.endResultDeletion(projectSessionID: plan.projectSessionID)
        #expect(!store.isRunningProjectTool)

        store.descriptionDraft = "Changed after confirmation capture"
        #expect(!plan.stillOwnsProject(store))
        #expect(FileManager.default.fileExists(atPath: failedURL.path))
        #expect(FileManager.default.fileExists(atPath: noSummaryURL.path))
        #expect(services.trashCalls == 0)
    }
}

@MainActor
private func resultFile(_ folder: URL, name: String, bytes: String) throws -> URL {
    let url = folder.appendingPathComponent("Results", isDirectory: true)
        .appendingPathComponent(name + ".h5")
    try Data(bytes.utf8).write(to: url)
    return url
}

private func revision(_ url: URL) throws -> String {
    let data = try Data(contentsOf: url)
    return SHA256.hash(data: data).map { String(format: "%02X", $0) }.joined()
}

@MainActor
private func waitForProject(_ store: WorkspaceStore) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while store.isOpeningProject && ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(!store.isOpeningProject)
}
