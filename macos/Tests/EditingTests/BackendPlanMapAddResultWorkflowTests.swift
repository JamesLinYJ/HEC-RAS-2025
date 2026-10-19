import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

struct BackendPlanMapAddResultWorkflowTests {
    @Test @MainActor
    func storeAddResultActivatesPlanAndGeometryMapsIdempotentlyAndPersistsExactOwners() async throws {
        let environment = ProcessInfo.processInfo.environment
        let executable = URL(fileURLWithPath: try #require(environment["HECRAS_BACKEND_TEST_EXECUTABLE"]))
        let fixtureDirectory = URL(fileURLWithPath: try #require(environment["HECRAS_PLAN_MAP_ACCEPTANCE_DIRECTORY"]))
        let workingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("plan-map-add-result-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.copyItem(at: fixtureDirectory, to: workingRoot)
        defer { try? FileManager.default.removeItem(at: workingRoot) }

        let manifest = try JSONDecoder().decode(PlanAddResultManifest.self,
            from: Data(contentsOf: workingRoot.appendingPathComponent("acceptance.json")))
        let projectURL = workingRoot.appendingPathComponent(manifest.projectRelativePath)
        let planURL = workingRoot.appendingPathComponent(manifest.planRelativePath)
        let geometryURL = workingRoot.appendingPathComponent(manifest.geometryRelativePath)
        let boundaryURL = workingRoot.appendingPathComponent(manifest.boundaryConditionRelativePath)
        #expect(FileManager.default.fileExists(atPath: boundaryURL.path))
        let signedResult = try #require(manifest.results.first { $0.role == "signed-flow" })
        let latestResult = try #require(manifest.results.first { $0.role == "zero-flow" })
        let signedResultURL = workingRoot.appendingPathComponent(signedResult.path)
        let latestResultURL = workingRoot.appendingPathComponent(latestResult.path)
        let visualizationURL = projectURL.deletingPathExtension().appendingPathExtension("vis")
        #expect(!FileManager.default.fileExists(atPath: visualizationURL.path))

        let originalSourceBytes = try planAddSourceSnapshot(root: workingRoot)

        let client = BackendProcessClient(executableURL: executable)
        let store = WorkspaceStore(system: PlanAddResultFixtureServices(),
            modelProvider: BackendModelProvider(client: client))
        try await planAddOpen(store, projectURL: projectURL)
        let planAsset = try #require(store.assets.first {
            $0.section == .plans && $0.isModelFile && planAddCanonical($0.url.path) == planAddCanonical(planURL.path)
        })
        let geometryAsset = try #require(store.assets.first {
            $0.section == .geometries && $0.isModelFile && planAddCanonical($0.url.path) == planAddCanonical(geometryURL.path)
        })
        let signedResultAsset = try #require(store.assets.first {
            $0.section == .results && planAddCanonical($0.url.path) == planAddCanonical(signedResultURL.path)
        })
        let latestResultAsset = try #require(store.assets.first {
            $0.section == .results && planAddCanonical($0.url.path) == planAddCanonical(latestResultURL.path)
        })

        #expect(await store.focusPlanInNewMap(assetID: planAsset.id))
        let planMap = try #require(store.mapDocuments.first { $0.kind == .plan })
        let planMapID = planMap.id
        let planState = store.mapState(for: planMapID)
        #expect(await store.focusGeometryInNewMap(assetID: geometryAsset.id))
        let geometryMap = try #require(store.mapDocuments.first { $0.kind == .geometry })
        let geometryMapID = geometryMap.id
        let geometryState = store.mapState(for: geometryMapID)
        #expect(planMapID != geometryMapID)
        #expect(store.mapIdentityRequest(for: planMapID)?.mapType == "Plan")
        #expect(store.mapIdentityRequest(for: geometryMapID)?.mapType == "Geometry")

        // Both maps start without an active Result group. The Plan source tree
        // may project its default, unchecked MultiResult row before Add Result.
        await store.configureMapResultSources(planMapID)
        await store.configureMapResultSources(geometryMapID)
        try await planAddWait("initial Plan result sources") {
            !planState.resultSources.isLoading && planState.resultSources.snapshot != nil
        }
        try await planAddWait("initial Geometry result sources") {
            !geometryState.resultSources.isLoading && geometryState.resultSources.snapshot != nil
        }
        let initialPlanRows = try await store.sourceMapLayerNodes(planMapID)
        let initialPlanGroup = try #require(planAddFindNodes(initialPlanRows, type: "MultiResult", root: "Focused Plans").first)
        #expect(initialPlanGroup.checked == .unchecked)
        #expect(planState.resultSources.snapshot?.sources.activeNodes.contains { $0.nodeKind == "MultiResult" } == false)
        #expect(geometryState.resultSources.snapshot?.sources.activeNodes.contains { $0.nodeKind == "MultiResult" } == false)

        let initialPlanRevision = try #require(store.mapIdentityRequest(for: planMapID)?.expectedVisualizationRevision)
        await store.addAssetsToMap([signedResultAsset], mapID: planMapID)
        try await planAddWait("Plan Add Result route") {
            guard let identity = store.mapIdentityRequest(for: planMapID),
                  let sources = planState.resultSources.snapshot?.sources else { return false }
            return identity.expectedVisualizationRevision != initialPlanRevision
                && sources.activeNodes.contains { $0.nodeKind == "MultiResult" && $0.name == manifest.planName }
                && !planState.resultSources.isLoading
        }

        var planRows = try await store.sourceMapLayerNodes(planMapID)
        var planGroup = try #require(planAddFindNodes(planRows, type: "MultiResult", root: "Focused Plans")
            .first { $0.name == manifest.planName })
        #expect(planAddFindNodes(planRows, type: "MultiResult", root: "Focused Plans").count == 1)
        #expect(planGroup.checked == .checked)
        let planGroupLocator = try #require(planGroup.sourceLocator)
        #expect(planGroupLocator.nodeType == "MultiResult")
        #expect(planGroupLocator.rootName == "Focused Plans")
        #expect(planGroupLocator.parentPlanNodeName == manifest.planName)
        #expect(planAddCanonical(planGroupLocator.parentPlanAssetID ?? "") == planAddCanonical(planURL.path))
        #expect(planGroupLocator.parentPlanNodePath?.count == 2)
        let firstPlanSources = try #require(planState.resultSources.snapshot)
        var planResultNode = try #require(firstPlanSources.sources.activeNodes.first {
            $0.nodeKind == "MultiResult" && $0.name == manifest.planName
        })
        #expect(planResultNode.node == planGroupLocator)
        #expect(planResultNode.selections.map(\.selectionIndex) == [0])
        #expect(planResultNode.selections[0].selectionMode == .latest)
        #expect(planAddCanonical(planResultNode.selections[0].selectedResult?.resultPath ?? "")
            == planAddCanonical(latestResultURL.path))
        #expect(planResultNode.selections[0].selectedResult?.revision.caseInsensitiveCompare(latestResult.revision)
            == .orderedSame)

        // Request the earlier, real Result explicitly. Since it is the second
        // ordered candidate, the source reports the canonical Previous mode;
        // the selected .vis row remains the exact MultiResult group.
        let signedChoice = try #require(planResultNode.selections[0].choices.first {
            planAddCanonical($0.resultPath) == planAddCanonical(signedResultURL.path)
                && $0.revision.caseInsensitiveCompare(signedResult.revision) == .orderedSame
        })
        await planState.resultSources.setSelection(nodeID: planResultNode.id,
            selectionIndex: 0, mode: .explicit, choice: signedChoice)
        try await planAddWait("explicit Plan map Result resolves to Previous") {
            guard let slot = planState.resultSources.snapshot?.sources.activeNodes
                .first(where: { $0.id == planResultNode.id })?.selections.first else { return false }
            return slot.selectionMode == .previous
                && planAddCanonical(slot.selectedResult?.resultPath ?? "") == planAddCanonical(signedResultURL.path)
                && slot.selectedResult?.revision == signedResult.revision
                && !planState.resultSources.isSelecting
        }
        await store.configureMapResultSources(planMapID)
        planRows = try await store.sourceMapLayerNodes(planMapID)
        planGroup = try #require(planAddFindNodes(planRows, type: "MultiResult", root: "Focused Plans")
            .first { $0.name == manifest.planName })
        planResultNode = try #require(planState.resultSources.snapshot?.sources.activeNodes.first {
            $0.nodeKind == "MultiResult" && $0.name == manifest.planName
        })

        let persistedProfileIndex = try #require(signedResult.profiles.first { profile in
            profile.index > 0 && latestResult.profiles.contains { $0.index == profile.index }
        }?.index)
        let revisionBeforePlanView = try #require(store.mapIdentityRequest(for: planMapID)?.expectedVisualizationRevision)
        #expect(await store.setSourceResultViewState(node: planGroup, mapID: planMapID,
            selectedMapType: "Depth", profileIndex: persistedProfileIndex))
        try await planAddWait("Plan map .vis view state") {
            guard let active = planState.resultSources.snapshot?.sources.activeNodes.first(where: {
                $0.nodeKind == "MultiResult" && $0.name == manifest.planName
            }) else { return false }
            return active.selectedMapType == "Depth" && active.profileIndex == persistedProfileIndex
                && store.mapIdentityRequest(for: planMapID)?.expectedVisualizationRevision != revisionBeforePlanView
        }

        let planViewBytes = try Data(contentsOf: visualizationURL)
        let planViewRevision = try #require(store.mapIdentityRequest(for: planMapID)?.expectedVisualizationRevision)
        await store.addAssetsToMap([signedResultAsset], mapID: planMapID)
        #expect(store.mapIdentityRequest(for: planMapID)?.expectedVisualizationRevision == planViewRevision)
        #expect(try Data(contentsOf: visualizationURL) == planViewBytes)
        planRows = try await store.sourceMapLayerNodes(planMapID)
        #expect(planAddFindNodes(planRows, type: "MultiResult", root: "Focused Plans").count == 1)
        #expect(try planAddSourceSnapshot(root: workingRoot) == originalSourceBytes)

        // The Plan insertion must not activate the other saved map. Add the
        // current latest Result through the same production Store workflow to
        // Geometry and verify an independent exact row/slot-zero owner.
        await store.configureMapResultSources(geometryMapID)
        try await planAddWait("Geometry remains isolated before Add Result") {
            !geometryState.resultSources.isLoading
                && geometryState.resultSources.snapshot?.sources.activeNodes.contains { $0.nodeKind == "MultiResult" } == false
        }
        let initialGeometryRevision = try #require(store.mapIdentityRequest(for: geometryMapID)?.expectedVisualizationRevision)
        await store.addAssetsToMap([latestResultAsset], mapID: geometryMapID)
        try await planAddWait("Geometry Add Result route") {
            guard let identity = store.mapIdentityRequest(for: geometryMapID),
                  let sources = geometryState.resultSources.snapshot?.sources else { return false }
            return identity.expectedVisualizationRevision != initialGeometryRevision
                && sources.activeNodes.contains { $0.nodeKind == "MultiResult" && $0.name == manifest.planName }
                && !geometryState.resultSources.isLoading
        }

        var geometryRows = try await store.sourceMapLayerNodes(geometryMapID)
        let geometryGroup = try #require(planAddFindNodes(geometryRows, type: "MultiResult", root: "Layers")
            .first { $0.name == manifest.planName })
        #expect(planAddFindNodes(geometryRows, type: "MultiResult", root: "Layers").count == 1)
        #expect(geometryGroup.checked == .checked)
        let geometryGroupLocator = try #require(geometryGroup.sourceLocator)
        #expect(geometryGroupLocator.nodeType == "MultiResult")
        #expect(geometryGroupLocator.rootName == "Layers")
        #expect((geometryGroupLocator.nodePath?.count ?? 0) >= 2)
        let firstGeometrySources = try #require(geometryState.resultSources.snapshot)
        let geometryResultNode = try #require(firstGeometrySources.sources.activeNodes.first {
            $0.nodeKind == "MultiResult" && $0.name == manifest.planName
        })
        #expect(geometryResultNode.node == geometryGroupLocator)
        #expect(geometryResultNode.selections.map(\.selectionIndex) == [0])
        #expect(geometryResultNode.selections[0].selectionMode == .latest)
        #expect(planAddCanonical(geometryResultNode.selections[0].selectedResult?.resultPath ?? "")
            == planAddCanonical(latestResultURL.path))
        #expect(geometryResultNode.selections[0].selectedResult?.revision.caseInsensitiveCompare(latestResult.revision)
            == .orderedSame)

        let revisionBeforeGeometryView = try #require(store.mapIdentityRequest(for: geometryMapID)?.expectedVisualizationRevision)
        #expect(await store.setSourceResultViewState(node: geometryGroup, mapID: geometryMapID,
            selectedMapType: "Velocity", profileIndex: persistedProfileIndex))
        try await planAddWait("Geometry map .vis view state") {
            guard let active = geometryState.resultSources.snapshot?.sources.activeNodes.first(where: {
                $0.nodeKind == "MultiResult" && $0.name == manifest.planName
            }) else { return false }
            return active.selectedMapType == "Velocity" && active.profileIndex == persistedProfileIndex
                && store.mapIdentityRequest(for: geometryMapID)?.expectedVisualizationRevision != revisionBeforeGeometryView
        }

        let geometryViewBytes = try Data(contentsOf: visualizationURL)
        let geometryViewRevision = try #require(store.mapIdentityRequest(for: geometryMapID)?.expectedVisualizationRevision)
        await store.addAssetsToMap([latestResultAsset], mapID: geometryMapID)
        #expect(store.mapIdentityRequest(for: geometryMapID)?.expectedVisualizationRevision == geometryViewRevision)
        #expect(try Data(contentsOf: visualizationURL) == geometryViewBytes)
        geometryRows = try await store.sourceMapLayerNodes(geometryMapID)
        #expect(planAddFindNodes(geometryRows, type: "MultiResult", root: "Layers").count == 1)

        // Embedded HDF children belong to the exact active Result slot, not
        // merely to a same-named project Geometry or Boundary model.
        await store.configureMapResultSources(planMapID)
        await store.configureMapResultSources(geometryMapID)
        try await planAddWait("independent Plan and Geometry result selections") {
            guard let planSlot = planState.resultSources.snapshot?.sources.activeNodes
                .first(where: { $0.nodeKind == "MultiResult" })?.selections.first,
                  let geometrySlot = geometryState.resultSources.snapshot?.sources.activeNodes
                .first(where: { $0.nodeKind == "MultiResult" })?.selections.first else { return false }
            return planSlot.selectionMode == .previous
                && planAddCanonical(planSlot.selectedResult?.resultPath ?? "") == planAddCanonical(signedResultURL.path)
                && planSlot.selectedResult?.revision == signedResult.revision
                && geometrySlot.selectionMode == .latest
                && planAddCanonical(geometrySlot.selectedResult?.resultPath ?? "") == planAddCanonical(latestResultURL.path)
                && !planState.resultSources.isLoading && !geometryState.resultSources.isLoading
        }
        let selectedPlanSource = try #require(planState.resultSources.snapshot?.sources.activeNodes.first {
            $0.nodeKind == "MultiResult" && $0.name == manifest.planName
        })
        let selectedGeometrySource = try #require(geometryState.resultSources.snapshot?.sources.activeNodes.first {
            $0.nodeKind == "MultiResult" && $0.name == manifest.planName
        })
        #expect(selectedPlanSource.selectedMapType == "Depth" && selectedPlanSource.profileIndex == persistedProfileIndex)
        #expect(selectedGeometrySource.selectedMapType == "Velocity" && selectedGeometrySource.profileIndex == persistedProfileIndex)

        planRows = try await store.sourceMapLayerNodes(planMapID)
        geometryRows = try await store.sourceMapLayerNodes(geometryMapID)
        let planEmbeddedGeometry = try #require(planAddFindNode(planRows, type: "Geometry", root: "Focused Plans") {
            $0.parentResultNodeType == "MultiResult" && $0.parentResultNodePath == planGroupLocator.nodePath
        })
        let planEmbeddedBoundary = try #require(planAddFindNode(planRows, type: "BoundaryCondition", root: "Focused Plans") {
            $0.parentResultNodeType == "MultiResult" && $0.parentResultNodePath == planGroupLocator.nodePath
        })
        let geometryEmbeddedGeometry = try #require(planAddFindNode(geometryRows, type: "Geometry", root: "Layers") {
            $0.parentResultNodeType == "MultiResult" && $0.parentResultNodePath == geometryGroupLocator.nodePath
        })
        let geometryEmbeddedBoundary = try #require(planAddFindNode(geometryRows, type: "BoundaryCondition", root: "Layers") {
            $0.parentResultNodeType == "MultiResult" && $0.parentResultNodePath == geometryGroupLocator.nodePath
        })
        for (child, resultPath, resultRevision) in [
            (planEmbeddedGeometry, signedResultURL.path, signedResult.revision),
            (planEmbeddedBoundary, signedResultURL.path, signedResult.revision),
            (geometryEmbeddedGeometry, latestResultURL.path, latestResult.revision),
            (geometryEmbeddedBoundary, latestResultURL.path, latestResult.revision)
        ] {
            let owner = try #require(child.sourceLocator)
            #expect(planAddCanonical(owner.parentResultAssetID ?? "") == planAddCanonical(resultPath))
            #expect(owner.parentResultRevision?.caseInsensitiveCompare(resultRevision) == .orderedSame)
            #expect(owner.parentResultNodeName == manifest.planName)
        }
        #expect(planEmbeddedGeometry.name == manifest.geometryName)
        #expect(planEmbeddedBoundary.name == manifest.boundaryConditionName)
        #expect(geometryEmbeddedGeometry.name == manifest.geometryName)
        #expect(geometryEmbeddedBoundary.name == manifest.boundaryConditionName)
        #expect(planAddCanonical(planEmbeddedGeometry.assetID ?? "") == planAddCanonical(signedResultURL.path))
        #expect(planAddCanonical(geometryEmbeddedGeometry.assetID ?? "") == planAddCanonical(latestResultURL.path))

        #expect(try planAddSourceSnapshot(root: workingRoot) == originalSourceBytes)
        #expect(FileManager.default.fileExists(atPath: visualizationURL.path))

        // Open a new Store against the exact same private copy. Checked
        // MultiResult membership and per-node .vis presentation persist, while
        // the nonserialized Plan Result chooser starts again at source Latest.
        store.requestClose()
        if store.showDiscardConfirmation { store.discardAndContinue() }
        try #require(store.document == nil)

        let reopened = WorkspaceStore(system: PlanAddResultFixtureServices(),
            modelProvider: BackendModelProvider(client: client))
        try await planAddOpen(reopened, projectURL: projectURL)
        let reopenedPlanMap = try #require(reopened.mapDocuments.first {
            $0.kind == .plan && $0.name == planMap.name
        })
        let reopenedGeometryMap = try #require(reopened.mapDocuments.first {
            $0.kind == .geometry && $0.name == geometryMap.name
        })
        let reopenedPlanState = reopened.mapState(for: reopenedPlanMap.id)
        let reopenedGeometryState = reopened.mapState(for: reopenedGeometryMap.id)
        await reopened.configureMapResultSources(reopenedPlanMap.id)
        await reopened.configureMapResultSources(reopenedGeometryMap.id)
        try await planAddWait("reopened Plan Add Result group") {
            !reopenedPlanState.resultSources.isLoading
                && reopenedPlanState.resultSources.snapshot?.sources.activeNodes.contains {
                    $0.nodeKind == "MultiResult" && $0.name == manifest.planName
                } == true
        }
        try await planAddWait("reopened Geometry Add Result group") {
            !reopenedGeometryState.resultSources.isLoading
                && reopenedGeometryState.resultSources.snapshot?.sources.activeNodes.contains {
                    $0.nodeKind == "MultiResult" && $0.name == manifest.planName
                } == true
        }
        let reopenedPlanSource = try #require(reopenedPlanState.resultSources.snapshot?.sources.activeNodes.first {
            $0.nodeKind == "MultiResult" && $0.name == manifest.planName
        })
        let reopenedGeometrySource = try #require(reopenedGeometryState.resultSources.snapshot?.sources.activeNodes.first {
            $0.nodeKind == "MultiResult" && $0.name == manifest.planName
        })
        #expect(reopenedPlanSource.node.rootName == "Focused Plans")
        #expect(reopenedGeometrySource.node.rootName == "Layers")
        #expect(reopenedPlanSource.selections.first?.selectionMode == .latest)
        #expect(reopenedGeometrySource.selections.first?.selectionMode == .latest)
        #expect(reopenedPlanSource.selections.map(\.selectionIndex) == [0])
        #expect(reopenedGeometrySource.selections.map(\.selectionIndex) == [0])
        #expect(planAddCanonical(reopenedPlanSource.selections.first?.selectedResult?.resultPath ?? "")
            == planAddCanonical(latestResultURL.path))
        #expect(planAddCanonical(reopenedGeometrySource.selections.first?.selectedResult?.resultPath ?? "")
            == planAddCanonical(latestResultURL.path))
        #expect(reopenedPlanSource.selectedMapType == "Depth" && reopenedPlanSource.profileIndex == persistedProfileIndex)
        #expect(reopenedGeometrySource.selectedMapType == "Velocity" && reopenedGeometrySource.profileIndex == persistedProfileIndex)
        #expect(reopenedPlanState.resultSelectionOverrides.isEmpty)
        #expect(reopenedGeometryState.resultSelectionOverrides.isEmpty)

        let reopenedPlanRows = try await reopened.sourceMapLayerNodes(reopenedPlanMap.id)
        let reopenedGeometryRows = try await reopened.sourceMapLayerNodes(reopenedGeometryMap.id)
        #expect(planAddFindNodes(reopenedPlanRows, type: "MultiResult", root: "Focused Plans").count == 1)
        #expect(planAddFindNodes(reopenedGeometryRows, type: "MultiResult", root: "Layers").count == 1)
        #expect(planAddFindNode(reopenedPlanRows, type: "MultiResult", root: "Focused Plans")?.checked == .checked)
        #expect(planAddFindNode(reopenedGeometryRows, type: "MultiResult", root: "Layers")?.checked == .checked)
        let reopenedPlanGeometry = try #require(planAddFindNode(reopenedPlanRows, type: "Geometry", root: "Focused Plans") {
            $0.parentResultNodeType == "MultiResult"
        })
        let reopenedPlanBoundary = try #require(planAddFindNode(reopenedPlanRows, type: "BoundaryCondition", root: "Focused Plans") {
            $0.parentResultNodeType == "MultiResult"
        })
        let reopenedGeometryChild = try #require(planAddFindNode(reopenedGeometryRows, type: "Geometry", root: "Layers") {
            $0.parentResultNodeType == "MultiResult"
        })
        let reopenedBoundaryChild = try #require(planAddFindNode(reopenedGeometryRows, type: "BoundaryCondition", root: "Layers") {
            $0.parentResultNodeType == "MultiResult"
        })
        for child in [reopenedPlanGeometry, reopenedPlanBoundary, reopenedGeometryChild, reopenedBoundaryChild] {
            #expect(planAddCanonical(child.sourceLocator?.parentResultAssetID ?? "")
                == planAddCanonical(latestResultURL.path))
            #expect(child.sourceLocator?.parentResultRevision?.caseInsensitiveCompare(latestResult.revision) == .orderedSame)
        }
        #expect(try planAddSourceSnapshot(root: workingRoot) == originalSourceBytes)
    }
}

private struct PlanAddResultManifest: Decodable {
    let projectRelativePath: String
    let planRelativePath: String
    let geometryRelativePath: String
    let boundaryConditionRelativePath: String
    let planName: String
    let geometryName: String
    let boundaryConditionName: String
    let results: [PlanAddResultManifestResult]
}

private struct PlanAddResultManifestResult: Decodable {
    let role: String
    let path: String
    let revision: String
    let profiles: [PlanAddResultManifestProfile]
}

private struct PlanAddResultManifestProfile: Decodable {
    let index: Int
}

@MainActor
private func planAddOpen(_ store: WorkspaceStore, projectURL: URL) async throws {
    store.requestOpen(projectURL)
    try await planAddWait("project open") {
        store.document?.url?.standardizedFileURL == projectURL.standardizedFileURL && !store.isOpeningProject
    }
}

@MainActor
private func planAddWait(_ label: String, timeout: Duration = .seconds(30),
                         condition: @MainActor () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(20))
    }
    if condition() { return }
    throw PlanAddResultWorkflowError.timedOut(label)
}

private func planAddFindNode(_ nodes: [LayerTreeNode], type: String, root: String,
                             where predicate: (CatalogTreeNodeLocator) -> Bool = { _ in true }) -> LayerTreeNode? {
    nodes.first { node in
        guard let locator = node.sourceLocator else { return false }
        return locator.rootName == root && locator.nodeType == type && predicate(locator)
    }
}

private func planAddFindNodes(_ nodes: [LayerTreeNode], type: String, root: String) -> [LayerTreeNode] {
    nodes.filter { node in
        node.sourceLocator?.rootName == root && node.sourceLocator?.nodeType == type
    }
}

private func planAddCanonical(_ path: String) -> String {
    SourceFilePaths.canonical(URL(fileURLWithPath: path))
}

private func planAddSourceSnapshot(root: URL) throws -> [String: Data] {
    guard let enumerator = FileManager.default.enumerator(at: root,
        includingPropertiesForKeys: [.isRegularFileKey]) else {
        throw PlanAddResultWorkflowError.unreadableFixture
    }
    var sourceBytes: [String: Data] = [:]
    for case let file as URL in enumerator {
        guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
        let ext = file.pathExtension.lowercased()
        let sourceSequence = ext.count == 3
            && ["p", "g", "u"].contains(String(ext.prefix(1)))
            && ext.dropFirst().allSatisfy(\.isNumber)
        guard ["ras", "h5", "hdf", "tif", "tiff"].contains(ext) || sourceSequence else { continue }
        sourceBytes[planAddCanonical(file.path)] = try Data(contentsOf: file)
    }
    return sourceBytes
}

@MainActor
private final class PlanAddResultFixtureServices: WorkspaceSystemServices {
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

private enum PlanAddResultWorkflowError: Error {
    case timedOut(String)
    case unreadableFixture
}
