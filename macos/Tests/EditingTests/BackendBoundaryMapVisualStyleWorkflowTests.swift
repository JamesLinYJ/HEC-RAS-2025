import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

struct BackendBoundaryMapVisualStyleWorkflowTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HECRAS_PLAN_MAP_ACCEPTANCE_DIRECTORY"] != nil
        && ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"] != nil))
    @MainActor
    func projectAndPlanBoundaryStylesSurviveRepeatedApplyAndReopenWithoutChangingSourceFiles() async throws {
        let fixture = try BoundaryVisualStyleFixtureCopy()
        defer { fixture.remove() }
        let projectURL = fixture.root.appendingPathComponent(fixture.manifest.projectRelativePath)
        let originalHydraulicSources = try BoundaryVisualStyleSourceSnapshot(root: fixture.root)
        let initialStore = WorkspaceStore(system: BoundaryVisualStyleFixtureServices(),
            modelProvider: BackendModelProvider(client: fixture.client))
        try await boundaryVisualStyleOpen(initialStore, projectURL: projectURL)

        #expect(await initialStore.createMapDocument(kind: .project))
        let projectMap = try #require(initialStore.mapDocument(for: MapState.projectMapID))
        let planAsset = try #require(initialStore.assets.first {
            $0.section == .plans && $0.name == fixture.manifest.planName && $0.isModelFile
        })
        #expect(boundaryCanonicalPath(planAsset.url.path)
            == boundaryCanonicalPath(fixture.root.appendingPathComponent(fixture.manifest.planRelativePath).path))
        #expect(await initialStore.focusPlanInNewMap(assetID: planAsset.id))
        let initialPlanMap = try #require(initialStore.mapDocuments.first { $0.kind == .plan })

        try await ensureBoundaryRowVisible(initialStore, mapID: projectMap.id,
            rootName: "Boundary Conditions", planPath: nil, resultType: nil)
        try await ensureBoundaryRowVisible(initialStore, mapID: initialPlanMap.id,
            rootName: "Focused Plans", planPath: planAsset.url.path, resultType: nil)

        let initialProjectIdentity = try #require(initialStore.mapIdentityRequest(for: projectMap.id))
        let initialPlanIdentity = try #require(initialStore.mapIdentityRequest(for: initialPlanMap.id))
        let visualizationURL = boundaryVisualizationURL(projectURL)
        try addUnknownBoundaryStyleXML(to: visualizationURL,
            mapIndices: [initialProjectIdentity.mapIndex, initialPlanIdentity.mapIndex])

        initialStore.requestClose()
        if initialStore.showDiscardConfirmation { initialStore.discardAndContinue() }
        try #require(initialStore.document == nil)

        // Reopen after injecting unknown .vis data so both WorkspaceStore and
        // the backend see the same accepted source revision before editing.
        let store = WorkspaceStore(system: BoundaryVisualStyleFixtureServices(),
            modelProvider: BackendModelProvider(client: fixture.client))
        try await boundaryVisualStyleOpen(store, projectURL: projectURL)
        let reopenedProjectMap = try #require(store.mapDocument(for: MapState.projectMapID))
        let reopenedPlanMap = try #require(store.mapDocuments.first { $0.kind == .plan })
        await store.configureMapResultSources(reopenedProjectMap.id)
        await store.configureMapResultSources(reopenedPlanMap.id)

        var projectNodes = try await store.sourceMapLayerNodes(reopenedProjectMap.id)
        var projectBoundaryNode = try #require(projectNodes.first {
            $0.sourceLocator?.rootName == "Boundary Conditions"
                && $0.sourceLocator?.nodeType == "BoundaryCondition"
        })
        if projectBoundaryNode.checked != .checked {
            #expect(await store.setSourceMapVisibility(projectBoundaryNode, checked: true,
                mapID: reopenedProjectMap.id))
        }
        var planNodes = try await store.sourceMapLayerNodes(reopenedPlanMap.id)
        var planBoundaryNode = try #require(planNodes.first {
            $0.sourceLocator?.rootName == "Focused Plans"
                && $0.sourceLocator?.nodeType == "BoundaryCondition"
                && $0.sourceLocator?.parentPlanAssetID.map(boundaryCanonicalPath)
                    == boundaryCanonicalPath(planAsset.url.path)
                && $0.sourceLocator?.parentResultNodeType == nil
        })
        if planBoundaryNode.checked != .checked {
            #expect(await store.setSourceMapVisibility(planBoundaryNode, checked: true,
                mapID: reopenedPlanMap.id))
        }
        await store.configureMapResultSources(reopenedProjectMap.id)
        await store.configureMapResultSources(reopenedPlanMap.id)
        projectNodes = try await store.sourceMapLayerNodes(reopenedProjectMap.id)
        projectBoundaryNode = try #require(projectNodes.first {
            $0.sourceLocator?.rootName == "Boundary Conditions"
                && $0.sourceLocator?.nodeType == "BoundaryCondition"
        })
        planNodes = try await store.sourceMapLayerNodes(reopenedPlanMap.id)
        planBoundaryNode = try #require(planNodes.first {
            $0.sourceLocator?.rootName == "Focused Plans"
                && $0.sourceLocator?.nodeType == "BoundaryCondition"
                && $0.sourceLocator?.parentPlanAssetID.map(boundaryCanonicalPath)
                    == boundaryCanonicalPath(planAsset.url.path)
                && $0.sourceLocator?.parentResultNodeType == nil
        })

        let projectState = store.mapState(for: reopenedProjectMap.id)
        let projectCapture = try await waitForBoundaryCapture(store, mapID: reopenedProjectMap.id,
            locator: try #require(projectBoundaryNode.sourceLocator))
        #expect(projectState.boundaryMap.entries.first {
            $0.capture.identity == projectCapture.identity
        }?.status == .available)
        let beforeRuntimeToggle = try Data(contentsOf: visualizationURL)
        let wasDirtyBeforeRuntimeToggle = store.hasUnsavedChanges
        #expect(!wasDirtyBeforeRuntimeToggle)
        #expect(!projectState.boundaryMap.showsStrokeVertices(for: projectCapture.sourceIdentity))
        projectState.boundaryMap.setShowsStrokeVertices(true, sourceIdentity: projectCapture.sourceIdentity)
        #expect(projectState.boundaryMap.showsStrokeVertices(for: projectCapture.sourceIdentity))
        #expect(store.hasUnsavedChanges == wasDirtyBeforeRuntimeToggle)
        #expect(try Data(contentsOf: visualizationURL) == beforeRuntimeToggle)

        let projectStyle = try await store.makeBoundaryMapStyleSession(capture: projectCapture,
            mapID: reopenedProjectMap.id)
        await projectStyle.load()
        #expect(projectStyle.errorMessage == nil)
        #expect(projectStyle.snapshot != nil)
        projectStyle.setPenColor("#FF123456", definitionID: BoundaryMapRenderStyle.lineDefinitionID)
        #expect(await projectStyle.apply())
        let projectFirstApply = try #require(projectStyle.snapshot)
        #expect(projectFirstApply.context.capture.boundaryNode == projectCapture.boundaryNode)
        #expect(projectFirstApply.context.capture.resultOwner == nil)
        #expect(projectFirstApply.options[BoundaryMapRenderStyle.lineDefinitionID]?.values.penColor == "#FF123456")
        #expect(projectState.boundaryMap.showsStrokeVertices(
            for: projectFirstApply.context.capture.sourceIdentity))

        projectStyle.setPenColor("#FF654321", definitionID: BoundaryMapRenderStyle.lineDefinitionID)
        projectStyle.setPenWidth(3.5, definitionID: BoundaryMapRenderStyle.lineDefinitionID)
        #expect(await projectStyle.apply())
        let projectSecondApply = try #require(projectStyle.snapshot)
        #expect(projectSecondApply.context.capture.boundaryNode == projectCapture.boundaryNode)
        #expect(projectSecondApply.options[BoundaryMapRenderStyle.lineDefinitionID]?.values.penColor == "#FF654321")
        #expect(projectSecondApply.options[BoundaryMapRenderStyle.lineDefinitionID]?.values.penWidth == 3.5)
        #expect(!store.hasUnsavedChanges)

        // A preceding .vis write changes the saved-map revision globally.
        // The Plan capture is refreshed from its exact Plan-owned source row
        // before its own style session is opened.
        await store.configureMapResultSources(reopenedPlanMap.id)
        let refreshedPlanNodes = try await store.sourceMapLayerNodes(reopenedPlanMap.id)
        let refreshedPlanBoundary = try #require(refreshedPlanNodes.first {
            $0.sourceLocator?.rootName == "Focused Plans"
                && $0.sourceLocator?.nodeType == "BoundaryCondition"
                && $0.sourceLocator?.parentPlanAssetID.map(boundaryCanonicalPath)
                    == boundaryCanonicalPath(planAsset.url.path)
                && $0.sourceLocator?.parentResultNodeType == nil
        })
        let planCapture = try await waitForBoundaryCapture(store, mapID: reopenedPlanMap.id,
            locator: try #require(refreshedPlanBoundary.sourceLocator))
        #expect(store.mapState(for: reopenedPlanMap.id).boundaryMap.entries.first {
            $0.capture.identity == planCapture.identity
        }?.status == .available)
        let planStyle = try await store.makeBoundaryMapStyleSession(capture: planCapture,
            mapID: reopenedPlanMap.id)
        await planStyle.load()
        #expect(planStyle.errorMessage == nil)
        #expect(planStyle.context?.capture.map.mapType == "Plan")
        #expect(planStyle.context?.capture.resultOwner == nil)
        planStyle.setPenColor("#FFAA2233", definitionID: BoundaryMapRenderStyle.lineDefinitionID)
        #expect(await planStyle.apply())
        planStyle.setPenColor("#FF2244AA", definitionID: BoundaryMapRenderStyle.lineDefinitionID)
        planStyle.setPenWidth(4.5, definitionID: BoundaryMapRenderStyle.lineDefinitionID)
        #expect(await planStyle.apply())
        #expect(planStyle.snapshot?.context.capture.boundaryNode == planCapture.boundaryNode)
        #expect(planStyle.snapshot?.options[BoundaryMapRenderStyle.lineDefinitionID]?.values.penColor == "#FF2244AA")
        #expect(planStyle.snapshot?.options[BoundaryMapRenderStyle.lineDefinitionID]?.values.penWidth == 4.5)
        #expect(!store.hasUnsavedChanges)

        store.requestClose()
        if store.showDiscardConfirmation { store.discardAndContinue() }
        try #require(store.document == nil)

        let reopened = WorkspaceStore(system: BoundaryVisualStyleFixtureServices(),
            modelProvider: BackendModelProvider(client: fixture.client))
        try await boundaryVisualStyleOpen(reopened, projectURL: projectURL)
        let reopenedProject = try #require(reopened.mapDocument(for: MapState.projectMapID))
        let reopenedPlan = try #require(reopened.mapDocuments.first { $0.kind == .plan })
        await reopened.configureMapResultSources(reopenedProject.id)
        await reopened.configureMapResultSources(reopenedPlan.id)
        let reopenedProjectRows = try await reopened.sourceMapLayerNodes(reopenedProject.id)
        let reopenedProjectNode = try #require(reopenedProjectRows.first {
            $0.sourceLocator?.rootName == "Boundary Conditions"
                && $0.sourceLocator?.nodeType == "BoundaryCondition"
                && $0.sourceLocator == projectCapture.boundaryNode
        })
        let reopenedProjectCapture = try await waitForBoundaryCapture(reopened,
            mapID: reopenedProject.id, locator: try #require(reopenedProjectNode.sourceLocator))
        let reopenedProjectStyle = try await reopened.makeBoundaryMapStyleSession(
            capture: reopenedProjectCapture, mapID: reopenedProject.id)
        await reopenedProjectStyle.load()
        #expect(reopenedProjectStyle.errorMessage == nil)
        #expect(reopenedProjectStyle.snapshot?.options[BoundaryMapRenderStyle.lineDefinitionID]?.values.penColor
            == "#FF654321")
        #expect(reopenedProjectStyle.snapshot?.options[BoundaryMapRenderStyle.lineDefinitionID]?.values.penWidth == 3.5)

        let reopenedPlanRows = try await reopened.sourceMapLayerNodes(reopenedPlan.id)
        let reopenedPlanNode = try #require(reopenedPlanRows.first {
            $0.sourceLocator?.rootName == "Focused Plans"
                && $0.sourceLocator?.nodeType == "BoundaryCondition"
                && $0.sourceLocator?.parentPlanAssetID.map(boundaryCanonicalPath)
                    == boundaryCanonicalPath(planAsset.url.path)
                && $0.sourceLocator?.parentResultNodeType == nil
        })
        let reopenedPlanCapture = try await waitForBoundaryCapture(reopened,
            mapID: reopenedPlan.id, locator: try #require(reopenedPlanNode.sourceLocator))
        let reopenedPlanStyle = try await reopened.makeBoundaryMapStyleSession(
            capture: reopenedPlanCapture, mapID: reopenedPlan.id)
        await reopenedPlanStyle.load()
        #expect(reopenedPlanStyle.errorMessage == nil)
        #expect(reopenedPlanStyle.context?.capture.boundaryNode == planCapture.boundaryNode)
        #expect(reopenedPlanStyle.snapshot?.options[BoundaryMapRenderStyle.lineDefinitionID]?.values.penColor
            == "#FF2244AA")
        #expect(reopenedPlanStyle.snapshot?.options[BoundaryMapRenderStyle.lineDefinitionID]?.values.penWidth == 4.5)
        #expect(try BoundaryVisualStyleSourceSnapshot(root: fixture.root).matches(originalHydraulicSources))
        try assertUnknownBoundaryStyleXML(in: visualizationURL)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HECRAS_PLAN_MAP_ACCEPTANCE_DIRECTORY"] != nil
        && ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"] != nil))
    @MainActor
    func resultSlotZeroBoundaryStyleReopensAndRejectsStaleVisualizationAndResultOwnerContexts() async throws {
        let fixture = try BoundaryVisualStyleFixtureCopy()
        defer { fixture.remove() }
        let projectURL = fixture.root.appendingPathComponent(fixture.manifest.projectRelativePath)
        let originalHydraulicSources = try BoundaryVisualStyleSourceSnapshot(root: fixture.root)
        let seed = WorkspaceStore(system: BoundaryVisualStyleFixtureServices(),
            modelProvider: BackendModelProvider(client: fixture.client))
        try await boundaryVisualStyleOpen(seed, projectURL: projectURL)
        let planAsset = try #require(seed.assets.first {
            $0.section == .plans && $0.name == fixture.manifest.planName && $0.isModelFile
        })
        #expect(await seed.focusPlanInNewMap(assetID: planAsset.id))
        let seedMap = try #require(seed.mapDocuments.first { $0.kind == .plan })
        var seedRows = try await seed.sourceMapLayerNodes(seedMap.id)
        let seedResultGroup = try #require(seedRows.first {
            $0.sourceLocator?.nodeType == "MultiResult"
                && $0.sourceLocator?.rootName == "Focused Plans"
        })
        #expect(await seed.setSourceMapVisibility(seedResultGroup, checked: true, mapID: seedMap.id))
        await seed.configureMapResultSources(seedMap.id)
        let seedState = seed.mapState(for: seedMap.id)
        try await waitForResultSource(seedState, planName: fixture.manifest.planName)
        seedRows = try await seed.sourceMapLayerNodes(seedMap.id)
        let seedBoundary = try #require(seedRows.first {
            $0.sourceLocator?.nodeType == "BoundaryCondition"
                && $0.sourceLocator?.rootName == "Focused Plans"
                && $0.sourceLocator?.parentResultNodeType == "MultiResult"
        })
        #expect(await seed.setSourceMapVisibility(seedBoundary, checked: true, mapID: seedMap.id))
        await seed.configureMapResultSources(seedMap.id)

        let seededIdentity = try #require(seed.mapIdentityRequest(for: seedMap.id))
        let visualizationURL = boundaryVisualizationURL(projectURL)
        try addUnknownBoundaryStyleXML(to: visualizationURL, mapIndices: [seededIdentity.mapIndex])

        seed.requestClose()
        if seed.showDiscardConfirmation { seed.discardAndContinue() }
        try #require(seed.document == nil)

        let store = WorkspaceStore(system: BoundaryVisualStyleFixtureServices(),
            modelProvider: BackendModelProvider(client: fixture.client))
        try await boundaryVisualStyleOpen(store, projectURL: projectURL)
        let map = try #require(store.mapDocuments.first { $0.kind == .plan })
        await store.configureMapResultSources(map.id)
        let state = store.mapState(for: map.id)
        try await waitForResultSource(state, planName: fixture.manifest.planName)
        let resultSource = try #require(state.resultSources.snapshot?.sources.activeNodes.first {
            $0.nodeKind == "MultiResult" && $0.name == fixture.manifest.planName
        })
        let initialSlot = try #require(resultSource.selections.first { $0.selectionIndex == 0 })
        let initialResult = try #require(initialSlot.selectedResult)
        let alternateResult = try #require(initialSlot.choices.first {
            boundaryCanonicalPath($0.resultPath) != boundaryCanonicalPath(initialResult.resultPath)
        })
        #expect(boundaryCanonicalPath(alternateResult.resultPath)
            != boundaryCanonicalPath(initialResult.resultPath))
        #expect(fixture.manifest.results.count >= 2)
        for result in [initialResult, alternateResult] {
            #expect(fixture.manifest.results.contains {
                boundaryCanonicalPath(fixture.root.appendingPathComponent($0.path).path)
                    == boundaryCanonicalPath(result.resultPath)
                    && $0.revision.caseInsensitiveCompare(result.revision) == .orderedSame
            })
        }

        let nodes = try await store.sourceMapLayerNodes(map.id)
        let resultBoundaryNode = try #require(nodes.first {
            $0.sourceLocator?.nodeType == "BoundaryCondition"
                && $0.sourceLocator?.rootName == "Focused Plans"
                && $0.sourceLocator?.parentResultNodeType == "MultiResult"
                && $0.sourceLocator?.parentResultNodeName == resultSource.name
        })
        let resultBoundaryCapture = try await waitForBoundaryCapture(store, mapID: map.id,
            locator: try #require(resultBoundaryNode.sourceLocator))
        #expect(state.boundaryMap.entries.first {
            $0.capture.identity == resultBoundaryCapture.identity
        }?.status == .available)
        let owner = try #require(resultBoundaryCapture.resultOwner)
        #expect(owner.selectionIndex == 0)
        #expect(boundaryCanonicalPath(owner.selectedResultPath) == boundaryCanonicalPath(initialResult.resultPath))
        #expect(owner.selectedResultRevision.caseInsensitiveCompare(initialResult.revision) == .orderedSame)

        let beforeRuntimeToggle = try Data(contentsOf: visualizationURL)
        #expect(!state.boundaryMap.showsStrokeVertices(for: resultBoundaryCapture.sourceIdentity))
        state.boundaryMap.setShowsStrokeVertices(true, sourceIdentity: resultBoundaryCapture.sourceIdentity)
        #expect(state.boundaryMap.showsStrokeVertices(for: resultBoundaryCapture.sourceIdentity))
        #expect(try Data(contentsOf: visualizationURL) == beforeRuntimeToggle)
        #expect(!store.hasUnsavedChanges)

        let resultStyle = try await store.makeBoundaryMapStyleSession(capture: resultBoundaryCapture,
            mapID: map.id)
        await resultStyle.load()
        #expect(resultStyle.errorMessage == nil)
        resultStyle.setPenColor("#FF13579B", definitionID: BoundaryMapRenderStyle.lineDefinitionID)
        #expect(await resultStyle.apply())
        let firstApply = try #require(resultStyle.snapshot)
        #expect(firstApply.context.capture.resultOwner?.selectionIndex == 0)
        #expect(firstApply.context.capture.resultOwner?.resultNode == owner.resultNode)
        #expect(boundaryCanonicalPath(firstApply.context.capture.resultOwner?.selectedResultPath ?? "")
            == boundaryCanonicalPath(owner.selectedResultPath))
        #expect(firstApply.options[BoundaryMapRenderStyle.lineDefinitionID]?.values.penColor == "#FF13579B")
        #expect(state.boundaryMap.showsStrokeVertices(for: firstApply.context.capture.sourceIdentity))

        resultStyle.setPenColor("#FF97531B", definitionID: BoundaryMapRenderStyle.lineDefinitionID)
        resultStyle.setPenWidth(5.5, definitionID: BoundaryMapRenderStyle.lineDefinitionID)
        #expect(await resultStyle.apply())
        let secondApply = try #require(resultStyle.snapshot)
        #expect(secondApply.context.capture.resultOwner?.selectionIndex == 0)
        #expect(secondApply.context.capture.resultOwner?.resultNode == owner.resultNode)
        #expect(boundaryCanonicalPath(secondApply.context.capture.resultOwner?.selectedResultPath ?? "")
            == boundaryCanonicalPath(owner.selectedResultPath))
        #expect(secondApply.options[BoundaryMapRenderStyle.lineDefinitionID]?.values.penColor == "#FF97531B")
        #expect(secondApply.options[BoundaryMapRenderStyle.lineDefinitionID]?.values.penWidth == 5.5)
        #expect(!store.hasUnsavedChanges)

        store.requestClose()
        if store.showDiscardConfirmation { store.discardAndContinue() }
        try #require(store.document == nil)

        let reopened = WorkspaceStore(system: BoundaryVisualStyleFixtureServices(),
            modelProvider: BackendModelProvider(client: fixture.client))
        try await boundaryVisualStyleOpen(reopened, projectURL: projectURL)
        let reopenedMap = try #require(reopened.mapDocuments.first { $0.kind == .plan })
        await reopened.configureMapResultSources(reopenedMap.id)
        let reopenedState = reopened.mapState(for: reopenedMap.id)
        try await waitForResultSource(reopenedState, planName: fixture.manifest.planName)
        let reopenedNodes = try await reopened.sourceMapLayerNodes(reopenedMap.id)
        let reopenedBoundaryNode = try #require(reopenedNodes.first {
            $0.sourceLocator?.nodeType == "BoundaryCondition"
                && $0.sourceLocator?.rootName == "Focused Plans"
                && $0.sourceLocator?.parentResultNodeType == "MultiResult"
        })
        let reopenedCapture = try await waitForBoundaryCapture(reopened, mapID: reopenedMap.id,
            locator: try #require(reopenedBoundaryNode.sourceLocator))
        let reopenedOwner = try #require(reopenedCapture.resultOwner)
        #expect(reopenedOwner.selectionIndex == 0)
        #expect(reopenedOwner.resultNode.nodeType == owner.resultNode.nodeType)
        #expect(reopenedOwner.resultNode.nodePath == owner.resultNode.nodePath)
        #expect(boundaryCanonicalPath(reopenedOwner.selectedResultPath)
            == boundaryCanonicalPath(owner.selectedResultPath))
        #expect(reopenedOwner.selectedResultRevision.caseInsensitiveCompare(owner.selectedResultRevision) == .orderedSame)
        let reopenedStyle = try await reopened.makeBoundaryMapStyleSession(capture: reopenedCapture,
            mapID: reopenedMap.id)
        await reopenedStyle.load()
        #expect(reopenedStyle.errorMessage == nil)
        #expect(reopenedStyle.snapshot?.context.capture.resultOwner?.selectionIndex == 0)
        #expect(reopenedStyle.snapshot?.options[BoundaryMapRenderStyle.lineDefinitionID]?.values.penColor
            == "#FF97531B")
        #expect(reopenedStyle.snapshot?.options[BoundaryMapRenderStyle.lineDefinitionID]?.values.penWidth == 5.5)

        // A competing valid write advances only the .vis revision. The old
        // loaded editor must reject its stale draft and must not overwrite it.
        let currentCapture = try #require(reopenedStyle.context?.capture)
        let staleVisualizationStyle = try await reopened.makeBoundaryMapStyleSession(
            capture: currentCapture, mapID: reopenedMap.id)
        let winnerStyle = try await reopened.makeBoundaryMapStyleSession(
            capture: currentCapture, mapID: reopenedMap.id)
        await staleVisualizationStyle.load()
        await winnerStyle.load()
        staleVisualizationStyle.setPenColor("#FF010203", definitionID: BoundaryMapRenderStyle.lineDefinitionID)
        winnerStyle.setPenColor("#FFABCDEF", definitionID: BoundaryMapRenderStyle.lineDefinitionID)
        #expect(await winnerStyle.apply())
        let afterWinnerBytes = try Data(contentsOf: visualizationURL)
        #expect(await staleVisualizationStyle.apply() == false)
        #expect(staleVisualizationStyle.errorMessage != nil)
        #expect(try Data(contentsOf: visualizationURL) == afterWinnerBytes)

        // A slot-zero source change is also an owner change even when the
        // Result node and display name remain the same.
        await reopened.configureMapResultSources(reopenedMap.id)
        try await waitForResultSource(reopenedState, planName: fixture.manifest.planName)
        let postVisualNodes = try await reopened.sourceMapLayerNodes(reopenedMap.id)
        let postVisualBoundaryNode = try #require(postVisualNodes.first {
            $0.sourceLocator?.nodeType == "BoundaryCondition"
                && $0.sourceLocator?.parentResultNodeType == "MultiResult"
        })
        let sourceChangeCapture = try await waitForBoundaryCapture(reopened, mapID: reopenedMap.id,
            locator: try #require(postVisualBoundaryNode.sourceLocator))
        let staleResultOwnerStyle = try await reopened.makeBoundaryMapStyleSession(
            capture: sourceChangeCapture, mapID: reopenedMap.id)
        await staleResultOwnerStyle.load()
        staleResultOwnerStyle.setPenColor("#FF102030", definitionID: BoundaryMapRenderStyle.lineDefinitionID)
        let beforeSelectionBytes = try Data(contentsOf: visualizationURL)
        let activeResultNode = try #require(reopenedState.resultSources.snapshot?.sources.activeNodes.first {
            $0.nodeKind == "MultiResult" && $0.name == fixture.manifest.planName
        })
        await reopenedState.resultSources.setSelection(nodeID: activeResultNode.id,
            selectionIndex: 0, mode: .previous)
        try await boundaryVisualStyleWaitUntil("slot-zero Result source change", timeout: .seconds(30)) {
            guard let current = reopenedState.resultSources.snapshot?.sources.activeNodes.first(where: {
                $0.id == activeResultNode.id
            })?.selections.first(where: { $0.selectionIndex == 0 })?.selectedResult else { return false }
            return boundaryCanonicalPath(current.resultPath) == boundaryCanonicalPath(alternateResult.resultPath)
                && !reopenedState.resultSources.isSelecting
        }
        await reopened.configureMapResultSources(reopenedMap.id)
        #expect(await staleResultOwnerStyle.apply() == false)
        #expect(staleResultOwnerStyle.errorMessage != nil)
        #expect(try Data(contentsOf: visualizationURL) == beforeSelectionBytes)

        #expect(try BoundaryVisualStyleSourceSnapshot(root: fixture.root).matches(originalHydraulicSources))
        try assertUnknownBoundaryStyleXML(in: visualizationURL)
    }
}

private struct BoundaryVisualStyleFixtureManifest: Decodable {
    let projectRelativePath: String
    let planRelativePath: String
    let planName: String
    let results: [Result]

    struct Result: Decodable {
        let path: String
        let revision: String
    }
}

private struct BoundaryVisualStyleFixtureCopy {
    let root: URL
    let manifest: BoundaryVisualStyleFixtureManifest
    let client: BackendProcessClient

    init() throws {
        let environment = ProcessInfo.processInfo.environment
        let fixtureDirectory = URL(fileURLWithPath:
            try #require(environment["HECRAS_PLAN_MAP_ACCEPTANCE_DIRECTORY"]))
        let executable = URL(fileURLWithPath:
            try #require(environment["HECRAS_BACKEND_TEST_EXECUTABLE"]))
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "boundary-style-workflow-" + UUID().uuidString, isDirectory: true)
        client = BackendProcessClient(executableURL: executable)
        try FileManager.default.copyItem(at: fixtureDirectory, to: root)
        do {
            manifest = try JSONDecoder().decode(BoundaryVisualStyleFixtureManifest.self,
                from: Data(contentsOf: root.appendingPathComponent("acceptance.json")))
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

private struct BoundaryVisualStyleSourceSnapshot {
    let files: [String: Data]

    init(root: URL) throws {
        guard let enumerator = FileManager.default.enumerator(at: root,
            includingPropertiesForKeys: [.isRegularFileKey]) else {
            throw BoundaryVisualStyleFixtureError.unreadableFixture
        }
        var captured: [String: Data] = [:]
        for case let file as URL in enumerator {
            guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true,
                  ["ras", "h5", "hdf", "tif", "tiff"].contains(file.pathExtension.lowercased()) else {
                continue
            }
            let canonicalRoot = boundaryCanonicalPath(root.path)
            let canonicalFile = boundaryCanonicalPath(file.path)
            let prefix = canonicalRoot.hasSuffix("/") ? canonicalRoot : canonicalRoot + "/"
            guard canonicalFile.hasPrefix(prefix) else {
                throw BoundaryVisualStyleFixtureError.unreadableFixture
            }
            captured[String(canonicalFile.dropFirst(prefix.count))] = try Data(contentsOf: file)
        }
        files = captured
    }

    func matches(_ original: BoundaryVisualStyleSourceSnapshot) -> Bool {
        files == original.files
    }
}

@MainActor
private final class BoundaryVisualStyleFixtureServices: WorkspaceSystemServices {
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

@MainActor
private func boundaryVisualStyleOpen(_ store: WorkspaceStore, projectURL: URL) async throws {
    store.requestOpen(projectURL)
    try await boundaryVisualStyleWaitUntil("project open", timeout: .seconds(30)) {
        store.document?.url?.standardizedFileURL == projectURL.standardizedFileURL
            && !store.isOpeningProject
    }
}

@MainActor
private func ensureBoundaryRowVisible(_ store: WorkspaceStore, mapID: UUID,
    rootName: String, planPath: String?, resultType: String?) async throws {
    let nodes = try await store.sourceMapLayerNodes(mapID)
    let row = try #require(nodes.first { node in
        guard let locator = node.sourceLocator,
              locator.rootName == rootName, locator.nodeType == "BoundaryCondition",
              locator.parentResultNodeType == resultType else { return false }
        if let planPath {
            return locator.parentPlanAssetID.map(boundaryCanonicalPath) == boundaryCanonicalPath(planPath)
        }
        return true
    })
    if row.checked != .checked {
        #expect(await store.setSourceMapVisibility(row, checked: true, mapID: mapID))
    }
    await store.configureMapResultSources(mapID)
}

@MainActor
private func waitForBoundaryCapture(_ store: WorkspaceStore, mapID: UUID,
                                   locator: CatalogTreeNodeLocator) async throws -> BoundaryMapCapture {
    let state = store.mapState(for: mapID)
    try await boundaryVisualStyleWaitUntil("Boundary map capture", timeout: .seconds(30)) {
        state.boundaryMap.entries.contains {
            $0.capture.boundaryNode == locator && $0.status != .loading
        } && !state.boundaryMap.isLoading
    }
    return try #require(state.boundaryMap.entries.first { $0.capture.boundaryNode == locator }?.capture)
}

@MainActor
private func waitForResultSource(_ state: MapState, planName: String) async throws {
    try await boundaryVisualStyleWaitUntil("slot-zero Result source", timeout: .seconds(30)) {
        state.resultSources.snapshot?.sources.activeNodes.contains {
            $0.nodeKind == "MultiResult" && $0.name == planName
                && $0.selections.contains { $0.selectionIndex == 0 && $0.selectedResult != nil }
        } == true && !state.resultSources.isLoading
    }
}

@MainActor
private func boundaryVisualStyleWaitUntil(_ label: String, timeout: Duration,
                                          condition: @MainActor () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(20))
    }
    if condition() { return }
    throw BoundaryVisualStyleFixtureError.timedOut(label)
}

private func addUnknownBoundaryStyleXML(to visualizationURL: URL, mapIndices: [Int]) throws {
    let document = try XMLDocument(contentsOf: visualizationURL, options: [.nodePreserveAll])
    guard let root = document.rootElement(),
          let maps = root.elements(forName: "Maps").first else {
        throw BoundaryVisualStyleFixtureError.invalidVisualization
    }
    for index in mapIndices {
        let mapElements = maps.elements(forName: "Map")
        guard mapElements.indices.contains(index) else {
            throw BoundaryVisualStyleFixtureError.invalidVisualization
        }
        let map = mapElements[index]
        map.addAttribute(XMLNode.attribute(withName: "UnknownR22StyleMap", stringValue: "map-\(index)") as! XMLNode)
    }
    root.addChild(XMLElement(name: "UnknownR22StyleSection", stringValue: "preserve-me"))
    try document.xmlData(options: [.nodePreserveAll]).write(to: visualizationURL)
}

private func assertUnknownBoundaryStyleXML(in visualizationURL: URL) throws {
    let document = try XMLDocument(contentsOf: visualizationURL, options: [.nodePreserveAll])
    let root = try #require(document.rootElement())
    #expect(root.elements(forName: "UnknownR22StyleSection").first?.stringValue == "preserve-me")
    let maps = try #require(root.elements(forName: "Maps").first).elements(forName: "Map")
    #expect(maps.contains {
        $0.attribute(forName: "UnknownR22StyleMap")?.stringValue != nil
    })
}

private func boundaryVisualizationURL(_ projectURL: URL) -> URL {
    projectURL.deletingPathExtension().appendingPathExtension("vis")
}

private func boundaryCanonicalPath(_ path: String) -> String {
    SourceFilePaths.canonical(URL(fileURLWithPath: path))
}

private enum BoundaryVisualStyleFixtureError: Error {
    case unreadableFixture
    case invalidVisualization
    case timedOut(String)
}
