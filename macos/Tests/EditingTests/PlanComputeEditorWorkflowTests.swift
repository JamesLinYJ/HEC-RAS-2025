import Foundation
import Combine
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

struct PlanComputeEditorWorkflowTests {
    @Test @MainActor
    func editorComputeUsesTheBundledSolverAndReloadsWrittenModelsWithoutSavingDrafts() async throws {
        let executable = try #require(ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"])
        let fixture = try #require(ProcessInfo.processInfo.environment["HECRAS_PLAN_COMPUTE_ACCEPTANCE_DIRECTORY"])
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("compute-editor-" + UUID().uuidString)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: fixture), to: folder)
        defer { try? FileManager.default.removeItem(at: folder) }
        let projectURL = folder.appendingPathComponent("Plan Compute Acceptance.ras")
        let projectBytes = try Data(contentsOf: projectURL)
        let provider = BackendModelProvider(client: .init(executableURL: URL(fileURLWithPath: executable)))
        let store = WorkspaceStore(system: SourceWorkflowFixtureServices(recoveryFolder: folder.appendingPathComponent("Recovery")), modelProvider: provider)
        store.requestOpen(projectURL)
        try await waitForEditorCompute { !store.isOpeningProject }
        let plan = try #require(store.assets.first { $0.section == .plans && $0.name == "Plan CPU" })
        let geometry = try #require(store.assets.first { $0.section == .geometries })
        let boundary = try #require(store.assets.first { $0.section == .boundaryConditions })
        let planBytes = try Data(contentsOf: plan.url)
        let owner = store.primaryEditorSession(.plan)
        let geometryEditor = store.primaryEditorSession(.geometry)
        let boundaryEditor = store.primaryEditorSession(.boundaryCondition)
        await owner.load(plan, kind: .plan)
        await geometryEditor.load(geometry, kind: .geometry)
        await boundaryEditor.load(boundary, kind: .boundaryCondition)
        #expect(owner.availableOperations.contains(.compute))
        let coreCount = "PlanComputeSettingsPage/ViewModel_SelectedPlan_CoreCount"
        owner.set(coreCount, "2")
        #expect(owner.modified)
        store.descriptionDraft = "Preserve unsaved computation description 中文"
        await store.catalogTreeSession.load(provider: store.catalogTreeProvider, context: store.catalogTreeContext)
        let resultRowObservation = TransientResultComputeRowObservation(store: store)
        #expect(await owner.perform(.compute))
        try await waitForEditorCompute { !store.isRunningPlanCompute }
        let response = try #require(owner.planCompute?.executionResult)
        #expect(response.state == "completed" && response.summary?.success == true)
        #expect(owner.fields[coreCount] == "2" && owner.modified)
        #expect(store.descriptionDraft == "Preserve unsaved computation description 中文")
        #expect(try Data(contentsOf: plan.url) == planBytes)
        #expect(try Data(contentsOf: projectURL) == projectBytes)
        #expect(geometryEditor.loaded && !geometryEditor.modified)
        #expect(boundaryEditor.loaded && !boundaryEditor.modified)
        #expect(geometryEditor.sourceFileRevision == CatalogModelActionPublisher.digest(try Data(contentsOf: geometry.url)))
        #expect(boundaryEditor.sourceFileRevision == CatalogModelActionPublisher.digest(try Data(contentsOf: boundary.url)))
        let resultPath = try #require(response.resultPath)
        let observedRunningRow = try #require(resultRowObservation.runningRow)
        let observedRun = try #require(UUID(uuidString: observedRunningRow.runID))
        let terminalEnvelope = try #require(response.resultCompute)
        let completedRun = try #require(UUID(uuidString: terminalEnvelope.runId))
        #expect(observedRun == completedRun)
        #expect(observedRunningRow.path == SourceFilePaths.canonical(URL(fileURLWithPath: resultPath)))
        #expect(!observedRunningRow.name.isEmpty)
        #expect(observedRunningRow.computeLeaseActive)
        #expect(["TransientResultComputeNode", "ObservableResult", "ResultNode", "ResultNodeVM"].contains(observedRunningRow.sourceClass))
        #expect(!observedRunningRow.liveProfiles.isEmpty,
            "The real solver workflow must surface source-reported BaseOutputBlock profile metadata.")
        #expect(Set(observedRunningRow.liveProfiles.map(\.index)).count == observedRunningRow.liveProfiles.count)
        #expect(observedRunningRow.liveProfiles.allSatisfy { !$0.name.isEmpty && !$0.time.isEmpty })
        let resultAsset = try #require(store.assets.first { $0.section == .results && $0.url.resolvingSymlinksInPath().path == URL(fileURLWithPath: resultPath).resolvingSymlinksInPath().path })
        let result = try await provider.load(resultAsset, kind: .result)
        #expect(!result.canEdit)
        #expect(!store.isRunningProjectTool)
    }
}

private final class TransientResultComputeRowObservation: @unchecked Sendable {
    struct Value: Sendable {
        let runID: String
        let path: String
        let name: String
        let sourceClass: String
        let computeLeaseActive: Bool
        let liveProfiles: [LiveMapResultProfile]
    }

    private let lock = NSLock()
    private var captured: Value?
    private var subscription: AnyCancellable?

    @MainActor init(store: WorkspaceStore) {
        subscription = Publishers.CombineLatest3(store.catalogTreeSession.$roots,
            store.$liveResultComputeByPath, store.$isRunningPlanCompute)
            .sink { [weak self] roots, liveEntries, computeLeaseActive in
                self?.captureRunningRow(in: roots, liveEntries: liveEntries,
                    computeLeaseActive: computeLeaseActive)
        }
    }

    var runningRow: Value? {
        lock.lock(); defer { lock.unlock() }
        return captured
    }

    private func captureRunningRow(in roots: [LayerTreeNode]?,
                                   liveEntries: [String: WorkspaceResultComputeEntry],
                                   computeLeaseActive: Bool) {
        guard computeLeaseActive else { return }
        func find(_ node: LayerTreeNode, entry: WorkspaceResultComputeEntry) -> Value? {
            let path = node.resultComputeSourcePath ?? node.assetID
            guard let path,
                  SourceFilePaths.canonical(URL(fileURLWithPath: path)) == entry.resultPath else {
                return node.children?.lazy.compactMap { find($0, entry: entry) }.first
            }
            if node.sourceClass == "TransientResultComputeNode",
               node.transientResultComputeStatus == "running",
               node.transientResultComputeRunID == entry.runID {
                return Value(runID: entry.runID, path: entry.resultPath,
                    name: node.name, sourceClass: node.sourceClass, computeLeaseActive: true,
                    liveProfiles: entry.profileTimeline?.blocks.flatMap(\.profiles) ?? [])
            }
            if ["ObservableResult", "ResultNode", "ResultNodeVM"].contains(node.sourceClass),
               entry.status == .running {
                return Value(runID: entry.runID, path: entry.resultPath,
                    name: node.name, sourceClass: node.sourceClass, computeLeaseActive: true,
                    liveProfiles: entry.profileTimeline?.blocks.flatMap(\.profiles) ?? [])
            }
            return node.children?.lazy.compactMap { find($0, entry: entry) }.first
        }
        guard let value = liveEntries.values.lazy
            .filter({ $0.status == .running })
            .sorted(by: { $0.runID < $1.runID })
            .compactMap({ entry in roots?.lazy.compactMap { find($0, entry: entry) }.first })
            .first else { return }
        lock.lock(); defer { lock.unlock() }
        if captured == nil || captured?.runID == value.runID { captured = value }
    }
}

@MainActor
private func waitForEditorCompute(_ condition: @MainActor () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(15)
    while !condition() {
        if ContinuousClock.now >= deadline { throw EditorComputeTestError.timedOut }
        try await Task.sleep(for: .milliseconds(10))
    }
}
private enum EditorComputeTestError: Error { case timedOut }
