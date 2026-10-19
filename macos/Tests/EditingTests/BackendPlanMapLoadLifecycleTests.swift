import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

struct BackendPlanMapLoadLifecycleTests {
    @Test @MainActor
    func concurrentConfigurationOfDefaultUncheckedPlanMapStaysQuiet() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let store = try await makeStore(executable: fixture.executable, projectURL: fixture.projectURL)
        let plan = try #require(store.assets.first {
            $0.section == .plans && $0.name == fixture.manifest.planName && $0.isModelFile
        })
        #expect(await store.focusPlanInNewMap(assetID: plan.id))
        #expect(store.errorMessage == nil)
        let map = try #require(store.mapDocuments.first { $0.kind == .plan })
        let state = store.mapState(for: map.id)
        let rows = try await store.sourceMapLayerNodes(map.id)
        let resultRows = rows.filter { ["Result", "MultiResult"].contains($0.sourceLocator?.nodeType ?? "") }
        #expect(!resultRows.isEmpty)
        #expect(resultRows.allSatisfy { $0.checked == .unchecked })
        #expect(fixture.sourceBytes.files.keys.contains { URL(fileURLWithPath: $0).pathExtension.lowercased() == "ras" })
        #expect(fixture.sourceBytes.files.keys.contains { URL(fileURLWithPath: $0).pathExtension.lowercased() == "h5" })

        // This overlaps the map view's .task with an explicit refresh call.
        async let viewTask = store.configureMapResultSources(map.id)
        async let explicitRefresh = store.configureMapResultSources(map.id)
        _ = await (viewTask, explicitRefresh)
        try await waitUntil("unchecked Plan result source snapshot", timeout: .seconds(30)) {
            !state.resultSources.isLoading && state.resultSources.snapshot != nil
        }

        #expect(state.resultSources.snapshot?.sources.activeNodes.isEmpty == true)
        #expect(state.resultSources.errorMessage == nil)
        #expect(store.errorMessage == nil)
        #expect(try fixture.sourceBytes.matches())
    }

    @Test @MainActor
    func repeatedPlanConfigurationPreservesPreviousAndPersistedProfileTwo() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let store = try await makeStore(executable: fixture.executable, projectURL: fixture.projectURL)
        let plan = try #require(store.assets.first {
            $0.section == .plans && $0.name == fixture.manifest.planName && $0.isModelFile
        })
        #expect(await store.focusPlanInNewMap(assetID: plan.id))
        let map = try #require(store.mapDocuments.first { $0.kind == .plan })
        let state = store.mapState(for: map.id)

        let treeBeforeActivation = try await store.sourceMapLayerNodes(map.id)
        let group = try #require(findNode(treeBeforeActivation, type: "MultiResult", root: "Focused Plans"))
        #expect(group.checked == .unchecked)
        #expect(await store.setSourceMapVisibility(group, checked: true, mapID: map.id))

        async let viewTask = store.configureMapResultSources(map.id)
        async let explicitRefresh = store.configureMapResultSources(map.id)
        _ = await (viewTask, explicitRefresh)
        try await waitUntil("active Plan result choices", timeout: .seconds(30)) {
            !state.resultSources.isLoading
                && state.resultSources.snapshot?.sources.activeNodes.contains {
                    $0.nodeKind == "MultiResult" && $0.name == fixture.manifest.planName
                } == true
        }

        let previousFixture = try #require(fixture.manifest.results.first { $0.role == "signed-flow" })
        #expect(previousFixture.profileCount > 2)
        let previousPath = fixture.root.appendingPathComponent(previousFixture.path).path
        let sourceNode = try #require(state.resultSources.snapshot?.sources.activeNodes.first {
            $0.nodeKind == "MultiResult" && $0.name == fixture.manifest.planName
        })
        let selectionVis = try Data(contentsOf: fixture.visualizationURL)
        await state.resultSources.setSelection(nodeID: sourceNode.id, selectionIndex: 0, mode: .previous)
        try await waitUntil("exact Previous source selection", timeout: .seconds(30)) {
            guard let active = state.resultSources.snapshot?.sources.activeNodes.first(where: { $0.id == sourceNode.id }),
                  let slot = active.selections.first(where: { $0.selectionIndex == 0 }) else { return false }
            return !state.resultSources.isLoading && !state.resultSources.isSelecting
                && active.node == sourceNode.node
                && slot.selectionMode == .previous
                && slot.selectedResult?.revision == previousFixture.revision
                && canonical(slot.selectedResult?.resultPath ?? "") == canonical(previousPath)
        }

        async let selectionViewTask = store.configureMapResultSources(map.id)
        async let selectionExplicitRefresh = store.configureMapResultSources(map.id)
        _ = await (selectionViewTask, selectionExplicitRefresh)
        try await waitUntil("Previous selection after duplicate configuration", timeout: .seconds(30)) {
            guard let active = state.resultSources.snapshot?.sources.activeNodes.first(where: {
                $0.id == sourceNode.id && $0.node == sourceNode.node
            }),
                  let slot = active.selections.first(where: { $0.selectionIndex == 0 }) else { return false }
            return !state.resultSources.isLoading && !state.resultSources.isSelecting
                && slot.selectionMode == .previous
                && slot.selectedResult?.revision == previousFixture.revision
                && canonical(slot.selectedResult?.resultPath ?? "") == canonical(previousPath)
        }
        #expect(try Data(contentsOf: fixture.visualizationURL) == selectionVis)
        #expect(store.errorMessage == nil)

        let treeWithActiveResult = try await store.sourceMapLayerNodes(map.id)
        let activeGroup = try #require(findNode(treeWithActiveResult, type: "MultiResult", root: "Focused Plans"))
        #expect(await store.setSourceResultViewState(node: activeGroup, mapID: map.id,
            selectedMapType: "Depth", profileIndex: 2))

        async let profileViewTask = store.configureMapResultSources(map.id)
        async let profileExplicitRefresh = store.configureMapResultSources(map.id)
        _ = await (profileViewTask, profileExplicitRefresh)
        try await waitUntil("persisted profile two and Previous selection", timeout: .seconds(40)) {
            guard let snapshot = state.resultSources.snapshot,
                  let active = snapshot.sources.activeNodes.first(where: {
                      $0.id == sourceNode.id && $0.node == sourceNode.node
                  }),
                  let slot = active.selections.first(where: { $0.selectionIndex == 0 }) else { return false }
            return !state.resultSources.isLoading && !state.resultSources.isSelecting
                && active.selectedMapType == "Depth" && active.profileIndex == 2
                && slot.selectionMode == .previous
                && slot.selectedResult?.revision == previousFixture.revision
                && canonical(slot.selectedResult?.resultPath ?? "") == canonical(previousPath)
        }

        #expect(state.resultSources.errorMessage == nil)
        #expect(store.errorMessage == nil)
        #expect(try fixture.sourceBytes.matches())
    }

    @Test @MainActor
    func projectResetDoesNotLetAnOldSetupWaiterRecreateItsMapState() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = try await makeStore(executable: fixture.executable, projectURL: fixture.projectURL)
        let plan = try #require(store.assets.first { $0.section == .plans && $0.name == fixture.manifest.planName })
        #expect(await store.focusPlanInNewMap(assetID: plan.id))
        let map = try #require(store.mapDocuments.first { $0.kind == .plan })
        let held = try await holdSetup(store: store, mapID: map.id)
        defer { held.gate.release() }
        let previousProject = store.projectSessionID
        store.requestClose()
        #expect(store.document == nil)
        #expect(store.projectSessionID != previousProject)
        #expect(store.existingMapState(for: map.id) == nil)
        held.gate.release()
        await held.waiter.value
        #expect(store.existingMapState(for: map.id) == nil)
        #expect(store.mapResultSourceSetupRequestIdentity(for: map.id) == nil)
        #expect(store.mapResultSourceSetupCoordinator.flight(for: map.id) == nil)
        #expect(try fixture.sourceBytes.matches())
    }

    @Test @MainActor
    func deletingAMapDoesNotLetAnOldSetupWaiterRecreateItsState() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = try await makeStore(executable: fixture.executable, projectURL: fixture.projectURL)
        let plan = try #require(store.assets.first { $0.section == .plans && $0.name == fixture.manifest.planName })
        #expect(await store.focusPlanInNewMap(assetID: plan.id))
        let map = try #require(store.mapDocuments.first { $0.kind == .plan })
        let held = try await holdSetup(store: store, mapID: map.id)
        defer { held.gate.release() }
        #expect(await store.deleteMapDocument(map.id))
        #expect(store.existingMapState(for: map.id) == nil)
        held.gate.release()
        await held.waiter.value
        #expect(store.document != nil)
        #expect(!store.mapDocuments.contains { $0.id == map.id })
        #expect(store.existingMapState(for: map.id) == nil)
        #expect(store.mapResultSourceSetupRequestIdentity(for: map.id) == nil)
        #expect(store.mapResultSourceSetupCoordinator.flight(for: map.id) == nil)
        #expect(store.errorMessage == nil)
        #expect(try fixture.sourceBytes.matches())
    }

    @MainActor
    private func holdSetup(store: WorkspaceStore, mapID: UUID) async throws
        -> (gate: PlanMapHeldSetupGate, waiter: Task<Void, Never>) {
        let identity = try #require(store.mapResultSourceSetupRequestIdentity(for: mapID))
        let gate = PlanMapHeldSetupGate()
        let shared = Task { @MainActor in await gate.wait() }
        try await waitUntil("controlled shared setup started", timeout: .seconds(10)) { gate.isWaiting }
        store.mapResultSourceSetupCoordinator.replace(.init(requestIdentity: identity,
            token: UUID(), task: shared), for: mapID)
        var waiterStarted = false
        let waiter = Task { @MainActor in
            waiterStarted = true
            await store.configureMapResultSources(mapID)
        }
        try await waitUntil("configure joined the controlled setup", timeout: .seconds(10)) { waiterStarted }
        return (gate, waiter)
    }

    @MainActor
    private func makeFixture() throws -> PlanMapLifecycleFixture {
        let environment = ProcessInfo.processInfo.environment
        let executable = URL(fileURLWithPath: try #require(environment["HECRAS_BACKEND_TEST_EXECUTABLE"]))
        let fixtureDirectory = URL(fileURLWithPath: try #require(environment["HECRAS_PLAN_MAP_ACCEPTANCE_DIRECTORY"]))
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("plan-map-load-lifecycle-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.copyItem(at: fixtureDirectory, to: root)
        let manifest = try JSONDecoder().decode(PlanMapLifecycleManifest.self,
            from: Data(contentsOf: root.appendingPathComponent("acceptance.json")))
        let projectURL = root.appendingPathComponent(manifest.projectRelativePath)
        let visualizationURL = projectURL.deletingPathExtension().appendingPathExtension("vis")
        let sourceBytes = try PlanMapLifecycleSourceBytes(root: root, manifest: manifest)
        return PlanMapLifecycleFixture(executable: executable, root: root, projectURL: projectURL,
            visualizationURL: visualizationURL, manifest: manifest, sourceBytes: sourceBytes)
    }

    @MainActor
    private func makeStore(executable: URL, projectURL: URL) async throws -> WorkspaceStore {
        let store = WorkspaceStore(system: PlanMapLifecycleServices(),
            modelProvider: BackendModelProvider(client: BackendProcessClient(executableURL: executable)))
        store.requestOpen(projectURL)
        try await waitUntil("project open", timeout: .seconds(30)) {
            store.document?.url?.standardizedFileURL == projectURL.standardizedFileURL
                && !store.isOpeningProject
        }
        return store
    }

    @MainActor
    private func waitUntil(_ label: String, timeout: Duration,
                           condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        if condition() { return }
        throw PlanMapLifecycleTestError.timedOut(label)
    }

    private func findNode(_ nodes: [LayerTreeNode], type: String, root: String) -> LayerTreeNode? {
        nodes.first { $0.sourceLocator?.rootName == root && $0.sourceLocator?.nodeType == type }
    }

    private func canonical(_ path: String) -> String {
        SourceFilePaths.canonical(URL(fileURLWithPath: path))
    }
}

/// Ignores cancellation until released, like a late reply from an old source.
/// This makes the post-await deletion/reset window deterministic.
@MainActor
private final class PlanMapHeldSetupGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var isWaiting = false

    func wait() async {
        await withCheckedContinuation {
            continuation = $0
            isWaiting = true
        }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private struct PlanMapLifecycleFixture {
    let executable: URL
    let root: URL
    let projectURL: URL
    let visualizationURL: URL
    let manifest: PlanMapLifecycleManifest
    let sourceBytes: PlanMapLifecycleSourceBytes
}

private struct PlanMapLifecycleManifest: Decodable {
    let projectRelativePath: String
    let planRelativePath: String
    let sharedPlanRelativePath: String
    let alternatePlanRelativePath: String
    let geometryRelativePath: String
    let alternateGeometryRelativePath: String
    let boundaryConditionRelativePath: String
    let planName: String
    let results: [PlanMapLifecycleResult]
}

private struct PlanMapLifecycleResult: Decodable {
    let role: String
    let path: String
    let revision: String
    let profileCount: Int
}

private struct PlanMapLifecycleSourceBytes {
    let files: [String: Data]

    init(root: URL, manifest: PlanMapLifecycleManifest) throws {
        var captured: [String: Data] = [:]
        guard let enumerator = FileManager.default.enumerator(at: root,
            includingPropertiesForKeys: [.isRegularFileKey]) else {
            throw PlanMapLifecycleTestError.unreadableFixture
        }
        for case let file as URL in enumerator {
            guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true,
                  ["ras", "h5", "hdf"].contains(file.pathExtension.lowercased()) else { continue }
            captured[SourceFilePaths.canonical(file)] = try Data(contentsOf: file)
        }
        for result in manifest.results {
            let file = root.appendingPathComponent(result.path).standardizedFileURL
            captured[SourceFilePaths.canonical(file)] = try Data(contentsOf: file)
        }
        files = captured
    }

    func matches() throws -> Bool {
        for (canonicalPath, expected) in files {
            let file = URL(fileURLWithPath: canonicalPath)
            guard try Data(contentsOf: file) == expected else { return false }
        }
        return true
    }
}

@MainActor
private final class PlanMapLifecycleServices: WorkspaceSystemServices {
    func chooseProject() -> URL? { nil }
    func chooseProjectDestination(name: String) -> URL? { nil }
    func chooseFolder(title: String) -> URL? { nil }
    func chooseVectorLayer() -> URL? { nil }
    func chooseConnectionFile() -> URL? { nil }
    func chooseInputFiles() -> [URL] { [] }
    func chooseImageFiles() -> [URL] { [] }
    func chooseProjectionFile() -> URL? { nil }
    func reveal(_ url: URL) {}
    func copy(_ text: String) {}
    func openWebsite(_ url: URL) {}
}

private enum PlanMapLifecycleTestError: Error {
    case unreadableFixture
    case timedOut(String)
}
