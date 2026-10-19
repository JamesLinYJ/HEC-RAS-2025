import CryptoKit
import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

struct BackendPlanMapResultWorkflowTests {
    @Test @MainActor
    func bundledPlanMapPersistsExactResultViewAndRendersItsEmbeddedGeometryBoundaryAndCulvertOutput() async throws {
        let environment = ProcessInfo.processInfo.environment
        let executable = URL(fileURLWithPath: try #require(environment["HECRAS_BACKEND_TEST_EXECUTABLE"]))
        let fixtureDirectory = URL(fileURLWithPath: try #require(environment["HECRAS_PLAN_MAP_ACCEPTANCE_DIRECTORY"]))
        let workingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("plan-map-result-workflow-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.copyItem(at: fixtureDirectory, to: workingRoot)
        defer { try? FileManager.default.removeItem(at: workingRoot) }

        let manifest = try JSONDecoder().decode(PlanMapAcceptanceManifest.self,
            from: Data(contentsOf: workingRoot.appendingPathComponent("acceptance.json")))
        let projectURL = workingRoot.appendingPathComponent(manifest.projectRelativePath)
        let planURL = workingRoot.appendingPathComponent(manifest.planRelativePath)
        let sharedPlanURL = workingRoot.appendingPathComponent(manifest.sharedPlanRelativePath)
        let alternatePlanURL = workingRoot.appendingPathComponent(manifest.alternatePlanRelativePath)
        let geometryURL = workingRoot.appendingPathComponent(manifest.geometryRelativePath)
        let alternateGeometryURL = workingRoot.appendingPathComponent(manifest.alternateGeometryRelativePath)
        let boundaryURL = workingRoot.appendingPathComponent(manifest.boundaryConditionRelativePath)
        let visualizationURL = projectURL.deletingPathExtension().appendingPathExtension("vis")
        let sourceBytes = try PlanMapSourceByteSnapshot(root: workingRoot)
        #expect(!FileManager.default.fileExists(atPath: visualizationURL.path))
        #expect(sourceBytes.files.keys.contains { $0.hasSuffix(".ras") })
        #expect(sourceBytes.files.keys.contains { $0.hasSuffix(".h5") })

        let client = BackendProcessClient(executableURL: executable)
        let store = WorkspaceStore(system: PlanMapFixtureServices(),
            modelProvider: BackendModelProvider(client: client))
        try await open(store, projectURL: projectURL)
        let plan = try #require(store.assets.first {
            $0.section == .plans && $0.name == manifest.planName && $0.isModelFile
        })

        #expect(await store.focusPlanInNewMap(assetID: plan.id))
        let map = try #require(store.mapDocuments.first { $0.kind == .plan })
        let mapID = map.id
        #expect(await store.createPlanMap())
        let secondMap = try #require(store.mapDocuments.first { $0.kind == .plan && $0.id != mapID })
        #expect(await store.focusPlanInMap(assetID: plan.id, mapID: secondMap.id))
        let secondMapNodes = try await store.sourceMapLayerNodes(secondMap.id)
        let secondFocusedPlan = try #require(findNode(secondMapNodes, type: "Plan", root: "Focused Plans"))
        #expect(canonical(secondFocusedPlan.assetID ?? secondFocusedPlan.sourceLocator?.assetID ?? "")
            == canonical(planURL.path))
        let secondMapState = store.mapState(for: secondMap.id)
        #expect(await store.removePlanFromMap(nodeID: secondFocusedPlan.id, mapID: secondMap.id))
        let secondMapAfterRemoval = try await store.sourceMapLayerNodes(secondMap.id)
        #expect(findNode(secondMapAfterRemoval, type: "Plan", root: "Focused Plans")?.id == nil)
        let firstMapAfterRemoval = try await store.sourceMapLayerNodes(mapID)
        #expect(findNode(firstMapAfterRemoval, type: "Plan", root: "Focused Plans")?.id != nil)
        #expect(await store.focusPlanInMap(assetID: plan.id, mapID: secondMap.id))
        let secondMapAfterRefocus = try await store.sourceMapLayerNodes(secondMap.id)
        #expect(findNode(secondMapAfterRefocus, type: "Plan", root: "Focused Plans")?.id != nil)

        let secondSharedPlan = try #require(store.assets.first {
            $0.section == .plans && $0.name == manifest.sharedPlanName && $0.isModelFile
        })
        #expect(canonical(secondSharedPlan.url.path) == canonical(sharedPlanURL.path))
        #expect(await store.focusPlanInMap(assetID: secondSharedPlan.id, mapID: secondMap.id))
        var twoPlanNodes = try await store.sourceMapLayerNodes(secondMap.id)
        let twoFocusedPlans = findNodes(twoPlanNodes, type: "Plan", root: "Focused Plans")
            .filter { $0.sourceLocator?.isFocusedPlanOwner == true }
        #expect(twoFocusedPlans.count == 2)
        #expect(Set(twoFocusedPlans.compactMap { $0.sourceLocator?.assetID ?? $0.assetID }.map(canonical))
            == Set([canonical(planURL.path), canonical(sharedPlanURL.path)]))
        twoPlanNodes = try await store.sourceMapLayerNodes(secondMap.id)
        let commonGeometry = try #require(findNode(twoPlanNodes, type: "Geometry", root: "Matching Layers") {
            $0.associationKind == "Geometry"
        })
        #expect(findNodes(twoPlanNodes, type: "Geometry", root: "Matching Layers").count == 1)
        let commonBoundary = try #require(findNode(twoPlanNodes, type: "BoundaryCondition", root: "Matching Layers") {
            $0.associationKind == "BoundaryCondition"
        })
        #expect(findNodes(twoPlanNodes, type: "BoundaryCondition", root: "Matching Layers").count == 1)
        #expect(commonBoundary.sourceLocator?.parentPlanAssetID == nil)
        #expect(canonical(commonBoundary.assetID ?? commonBoundary.sourceLocator?.assetID ?? "")
            == canonical(boundaryURL.path))
        let commonGeometryLocator = try #require(commonGeometry.sourceLocator)
        #expect(commonGeometryLocator.parentPlanAssetID == nil)
        #expect(commonGeometryLocator.parentPlanNodeName == nil)
        #expect(commonGeometryLocator.parentPlanNodePath == nil)
        #expect(canonical(commonGeometry.assetID ?? commonGeometryLocator.assetID ?? "") == canonical(geometryURL.path))
        #expect(await store.setSourceMapVisibility(commonGeometry, checked: true, mapID: secondMap.id))
        await store.configureProjectGeometryMap(secondMap.id)
        try await waitUntil("shared Geometry in Matching Layers", timeout: .seconds(30)) {
            secondMapState.projectGeometryMap.sources.contains {
                $0.capture.geometryNode == commonGeometryLocator
                    && $0.snapshot != nil && !$0.isLoading
            }
        }
        let commonGeometrySource = try #require(secondMapState.projectGeometryMap.sources.first {
            $0.capture.geometryNode == commonGeometryLocator
        })
        #expect(commonGeometrySource.capture.planNodes.count == 2)
        #expect(canonical(commonGeometrySource.capture.geometryCanonicalPath) == canonical(geometryURL.path))

        let alternatePlan = try #require(store.assets.first {
            $0.section == .plans && $0.name == manifest.alternatePlanName && $0.isModelFile
        })
        #expect(canonical(alternatePlan.url.path) == canonical(alternatePlanURL.path))
        #expect(await store.focusPlanInMap(assetID: alternatePlan.id, mapID: secondMap.id))
        var threePlanNodes = try await store.sourceMapLayerNodes(secondMap.id)
        let threeFocusedPlans = findNodes(threePlanNodes, type: "Plan", root: "Focused Plans")
            .filter { $0.sourceLocator?.isFocusedPlanOwner == true }
        #expect(threeFocusedPlans.count == 3)
        #expect(Set(threeFocusedPlans.compactMap { $0.sourceLocator?.assetID ?? $0.assetID }.map(canonical))
            == Set([canonical(planURL.path), canonical(sharedPlanURL.path), canonical(alternatePlanURL.path)]))
        threePlanNodes = try await store.sourceMapLayerNodes(secondMap.id)
        #expect(findNode(threePlanNodes, type: "Geometry", root: "Matching Layers") {
            $0.associationKind == "Geometry"
        }?.id == nil)
        let stillSharedBoundary = try #require(findNode(threePlanNodes, type: "BoundaryCondition", root: "Matching Layers") {
            $0.associationKind == "BoundaryCondition"
        })
        #expect(stillSharedBoundary.sourceLocator?.parentPlanAssetID == nil)
        #expect(canonical(stillSharedBoundary.assetID ?? stillSharedBoundary.sourceLocator?.assetID ?? "")
            == canonical(boundaryURL.path))
        let alternateGeometryNode = try #require(findNode(threePlanNodes, type: "Geometry", root: "Focused Plans") {
            $0.parentPlanAssetID.map(canonical) == canonical(alternatePlan.url.path)
                && $0.parentResultNodeType == nil
        })
        let alternateGeometryLocator = try #require(alternateGeometryNode.sourceLocator)
        #expect(alternateGeometryLocator.parentPlanNodeName == manifest.alternatePlanName)
        #expect(canonical(alternateGeometryLocator.parentPlanAssetID ?? "") == canonical(alternatePlan.url.path))
        #expect(canonical(alternateGeometryNode.assetID ?? alternateGeometryLocator.assetID ?? "")
            == canonical(alternateGeometryURL.path))
        #expect(await store.setSourceMapVisibility(alternateGeometryNode, checked: true, mapID: secondMap.id))
        await store.configureProjectGeometryMap(secondMap.id)
        try await waitUntil("distinct Plan-owned Geometry", timeout: .seconds(30)) {
            secondMapState.projectGeometryMap.sources.contains {
                $0.capture.geometryNode == alternateGeometryLocator
                    && $0.snapshot != nil && !$0.isLoading
            }
        }
        let alternateGeometrySource = try #require(secondMapState.projectGeometryMap.sources.first {
            $0.capture.geometryNode == alternateGeometryLocator
        })
        #expect(alternateGeometrySource.capture.planNodes.count == 1)
        #expect(canonical(alternateGeometrySource.capture.geometryCanonicalPath) == canonical(alternateGeometryURL.path))
        #expect(alternateGeometrySource.snapshot?.geometryName == manifest.alternateGeometryName)

        let mapIdentity = try #require(store.mapIdentityRequest(for: mapID))
        #expect(mapIdentity.mapType == "Plan")
        await store.configureMapResultSources(mapID)

        var nodes = try await store.sourceMapLayerNodes(mapID)
        let treeProvider = try #require(store.layerTreeProvider)
        let sourceTree = try await treeProvider.load(store.sourceMapTreeContext(mapID))
        #expect(sourceTree.roots.map(\.name) == ["Focused Plans", "Matching Layers", "Layers"])
        let focusedPlan = try #require(findNode(nodes, type: "Plan", root: "Focused Plans"))
        let planLocator = try #require(focusedPlan.sourceLocator)
        #expect(planLocator.nodePath?.count == 2)
        #expect(canonical(focusedPlan.assetID ?? planLocator.assetID ?? "") == canonical(planURL.path))
        #expect(planLocator.parentPlanAssetID == nil)
        #expect(findNode(nodes, type: "Geometry", root: "Matching Layers") {
            $0.associationKind == "Geometry"
        }?.id == nil)
        let mapState = store.mapState(for: mapID)

        // With one focused Plan the source keeps Geometry beneath that exact
        // Plan row; it is not a common Matching Layers association.
        let planGeometry = try #require(findNode(nodes, type: "Geometry", root: "Focused Plans") {
            $0.parentPlanAssetID.map(canonical) == canonical(planURL.path)
                && $0.parentResultNodeType == nil
        })
        let planGeometryLocator = try #require(planGeometry.sourceLocator)
        #expect(planGeometryLocator.parentPlanNodeName == manifest.planName)
        #expect(planGeometryLocator.parentPlanNodePath == planLocator.nodePath)
        #expect(canonical(planGeometry.assetID ?? planGeometryLocator.assetID ?? "") == canonical(geometryURL.path))
        #expect(await store.setSourceMapVisibility(planGeometry, checked: true, mapID: mapID))
        await store.configureProjectGeometryMap(mapID)
        try await waitUntil("single Plan Geometry child", timeout: .seconds(30)) {
            mapState.projectGeometryMap.sources.contains {
                $0.capture.geometryNode == planGeometryLocator
                    && $0.snapshot != nil && !$0.isLoading
            }
        }
        let planGeometrySource = try #require(mapState.projectGeometryMap.sources.first {
            $0.capture.geometryNode == planGeometryLocator
        })
        #expect(planGeometrySource.capture.planNodes.count == 1)
        #expect(canonical(planGeometrySource.capture.geometryCanonicalPath) == canonical(geometryURL.path))
        #expect(planGeometrySource.snapshot?.geometryName == manifest.geometryName)

        // The source tree starts with Result groups unchecked. Activate the
        // exact MultiResult row through the same Store route used by the UI.
        let initialGroup = try #require(findNode(nodes, type: "MultiResult", root: "Focused Plans"))
        #expect(initialGroup.checked == .unchecked)
        #expect(await store.setSourceMapVisibility(initialGroup, checked: true, mapID: mapID))
        await store.configureMapResultSources(mapID)
        try await waitUntil("Plan Result sources", timeout: .seconds(30)) {
            mapState.resultSources.sources?.activeNodes.contains { $0.nodeKind == "MultiResult" } == true
                && !mapState.resultSources.isLoading
        }

        let initialSources = try #require(mapState.resultSources.snapshot)
        let sourceNode = try #require(initialSources.sources.activeNodes.first {
            $0.nodeKind == "MultiResult" && $0.name == manifest.planName
        })
        #expect(sourceNode.node.rootName == "Focused Plans")
        #expect(sourceNode.node.parentPlanNodeName == manifest.planName)
        #expect(canonical(sourceNode.node.parentPlanAssetID ?? "") == canonical(planURL.path))
        #expect(sourceNode.selections.map(\.selectionIndex) == [0])
        #expect(sourceNode.selections[0].selectionMode == .latest)

        let signedFixture = try #require(manifest.results.first { $0.role == "signed-flow" })
        let latestFixture = try #require(manifest.results.first { $0.role == "zero-flow" })
        let signedChoice = try #require(sourceNode.selections[0].choices.first {
            canonical($0.resultPath) == canonical(workingRoot.appendingPathComponent(signedFixture.path).path)
        })
        let latestChoice = try #require(sourceNode.selections[0].choices.first {
            canonical($0.resultPath) == canonical(workingRoot.appendingPathComponent(latestFixture.path).path)
        })
        #expect(sourceNode.selections[0].choices.count == 2)
        #expect(sourceNode.selections[0].selectedResult?.revision == latestFixture.revision)
        #expect(sourceNode.selections[0].selectedResult?.id == latestChoice.id)

        let visualizationBeforeSelection = try Data(contentsOf: visualizationURL)
        await mapState.resultSources.setSelection(nodeID: sourceNode.id,
            selectionIndex: 0, mode: .previous)
        try await waitUntil("Previous Result selection", timeout: .seconds(20)) {
            guard let slot = mapState.resultSources.snapshot?.sources.activeNodes
                .first(where: { $0.id == sourceNode.id })?.selections.first else { return false }
            return slot.selectionMode == .previous
                && slot.selectedResult?.revision == signedFixture.revision
                && !mapState.resultSources.isSelecting
        }
        await store.configureMapResultSources(mapID)
        await mapState.resultSources.addSelection(nodeID: sourceNode.id)
        try await waitUntil("second Result selection slot", timeout: .seconds(20)) {
            mapState.resultSources.snapshot?.sources.activeNodes.first(where: { $0.id == sourceNode.id })?
                .selections.count == 2 && !mapState.resultSources.isSelecting
        }
        await store.configureMapResultSources(mapID)
        await mapState.resultSources.setSelection(nodeID: sourceNode.id,
            selectionIndex: 1, mode: .explicit, choice: signedChoice)
        try await waitUntil("explicit request resolves to Previous Result", timeout: .seconds(20)) {
            let slots = mapState.resultSources.snapshot?.sources.activeNodes.first(where: { $0.id == sourceNode.id })?.selections ?? []
            return slots.count == 2 && slots[1].selectionMode == .previous
                && canonical(slots[1].selectedResult?.resultPath ?? "") == canonical(signedChoice.resultPath)
                && slots[1].selectedResult?.revision == signedFixture.revision
                && !mapState.resultSources.isSelecting
        }
        #expect(try Data(contentsOf: visualizationURL) == visualizationBeforeSelection)
        #expect(secondMapState.resultSelectionOverrides.isEmpty)

        // Slot zero alone is the retained MultiResult keyframe. The source
        // tree must bind its Geometry and Boundary children to that exact HDF.
        await store.configureMapResultSources(mapID)
        nodes = try await store.sourceMapLayerNodes(mapID)
        let resultGeometry = try #require(findNode(nodes, type: "Geometry", root: "Focused Plans") {
            $0.parentResultNodeType == "MultiResult"
        })
        let resultGeometryLocator = try #require(resultGeometry.sourceLocator)
        #expect(resultGeometryLocator.parentResultNodeName == sourceNode.name)
        #expect(resultGeometryLocator.parentResultNodePath == sourceNode.node.nodePath)
        #expect(canonical(resultGeometryLocator.parentResultAssetID ?? "") == canonical(signedChoice.resultPath))
        #expect(resultGeometryLocator.parentResultRevision?.caseInsensitiveCompare(signedChoice.revision) == .orderedSame)
        #expect(canonical(resultGeometry.assetID ?? "") == canonical(signedChoice.resultPath))
        #expect(resultGeometryLocator.parentPlanNodeName == manifest.planName)
        #expect(canonical(resultGeometryLocator.parentPlanAssetID ?? "") == canonical(planURL.path))
        #expect(resultGeometryLocator.parentPlanNodePath == planLocator.nodePath)
        #expect(await store.setSourceMapVisibility(resultGeometry, checked: true, mapID: mapID))

        let resultBoundary = try #require(findNode(nodes, type: "BoundaryCondition", root: "Focused Plans") {
            $0.parentResultNodeType == "MultiResult"
        })
        let resultBoundaryLocator = try #require(resultBoundary.sourceLocator)
        #expect(resultBoundary.name == manifest.boundaryConditionName)
        #expect(resultBoundaryLocator.parentResultNodePath == sourceNode.node.nodePath)
        #expect(canonical(resultBoundaryLocator.parentResultAssetID ?? "") == canonical(signedChoice.resultPath))
        #expect(resultBoundaryLocator.parentResultRevision?.caseInsensitiveCompare(signedChoice.revision) == .orderedSame)
        #expect(await store.setSourceMapVisibility(resultBoundary, checked: true, mapID: mapID))

        let terrainNode = try #require(findNode(nodes, type: "Terrain", root: "Focused Plans") {
            $0.associationKind == "Terrain"
                && $0.parentPlanAssetID.map(canonical) == canonical(planURL.path)
        })
        let terrainModelPath = try #require(terrainNode.sourceLocator?.associationAssetID ?? terrainNode.assetID)
        #expect(URL(fileURLWithPath: terrainModelPath).pathExtension.lowercased() == "h5")
        #expect(store.assets.contains { asset in
            asset.section == .terrains && asset.isModelFile
                && SourceFilePaths.canonical(asset.url) == canonical(terrainModelPath)
        })
        #expect(terrainNode.sourceLocator?.parentPlanNodeName == manifest.planName)
        #expect(await store.setSourceMapVisibility(terrainNode, checked: true, mapID: mapID))

        // Persist the selected source map type and one real solver profile on
        // the exact MultiResult .vis node. Runtime Result choices stay native
        // session state and have not written .vis above.
        let signedProfile = try #require(signedFixture.profiles.first(where: { profile in
            profile.flow.count == manifest.barrelNames.count
                && profile.flow[0] * profile.flow[1] < 0
        }))
        nodes = try await store.sourceMapLayerNodes(mapID)
        let multiResultRow = try #require(findNode(nodes, type: "MultiResult", root: "Focused Plans"))
        #expect(await store.setSourceResultViewState(node: multiResultRow, mapID: mapID,
            selectedMapType: "Depth", profileIndex: signedProfile.index))
        let visualizationAfterSettings = try Data(contentsOf: visualizationURL)
        #expect(visualizationAfterSettings != visualizationBeforeSelection)

        await store.configureMapResultSources(mapID)
        try await waitUntil("Result raster and timeline", timeout: .seconds(40)) {
            !mapState.resultMap.isLoading && !mapState.resultMap.nodes.isEmpty
                && mapState.resultMap.nodes.allSatisfy { !$0.isLoading }
                && mapState.resultMap.nodes.contains { $0.profileCount > signedProfile.index }
        }
        let renderedNode = try #require(mapState.resultMap.nodes.first { $0.id == sourceNode.id })
        #expect(renderedNode.kind == "MultiResult")
        #expect(renderedNode.selectedMapType == "Depth")
        #expect(renderedNode.profileIndex == signedProfile.index)
        #expect(mapState.resultMap.resultLayers.contains { !$0.rgba.isEmpty })
        #expect(mapState.resultMap.resultLegends.contains { !$0.stops.isEmpty })
        let timeline = try #require(mapState.resultMap.selectedTimeline)
        #expect(timeline.currentID == signedProfile.index)
        #expect(timeline.steps.count == signedFixture.profileCount)

        try await waitUntil("embedded Result Geometry", timeout: .seconds(30)) {
            mapState.projectGeometryMap.sources.contains { $0.capture.geometryNode == resultGeometryLocator
                && $0.snapshot != nil && !$0.isLoading }
        }
        let embeddedGeometry = try #require(mapState.projectGeometryMap.sources.first {
            $0.capture.geometryNode == resultGeometryLocator
        })
        let geometrySnapshot = try #require(embeddedGeometry.snapshot)
        #expect(embeddedGeometry.capture.resultOwner?.selectionIndex == 0)
        #expect(canonical(embeddedGeometry.capture.resultOwner?.selectedResultPath ?? "") == canonical(signedChoice.resultPath))
        #expect(embeddedGeometry.capture.resultOwner?.selectedResultRevision.caseInsensitiveCompare(signedChoice.revision) == .orderedSame)
        #expect(canonical(geometrySnapshot.geometryCanonicalPath) == canonical(signedChoice.resultPath))
        #expect(geometrySnapshot.geometryRevision.caseInsensitiveCompare(signedChoice.revision) == .orderedSame)
        #expect(geometrySnapshot.geometryName == manifest.geometryName)
        #expect(geometrySnapshot.geometryEffectiveVisible)

        try await waitUntil("embedded Result Boundary Condition", timeout: .seconds(30)) {
            mapState.boundaryMap.entries.contains { $0.capture.boundaryNode == resultBoundaryLocator
                && $0.status != .loading }
        }
        let embeddedBoundary = try #require(mapState.boundaryMap.entries.first {
            $0.capture.boundaryNode == resultBoundaryLocator
        })
        #expect(embeddedBoundary.capture.resultOwner?.selectionIndex == 0)
        #expect(canonical(embeddedBoundary.capture.resultOwner?.selectedResultPath ?? "") == canonical(signedChoice.resultPath))
        #expect(embeddedBoundary.capture.resultOwner?.selectedResultRevision.caseInsensitiveCompare(signedChoice.revision) == .orderedSame)
        #expect(embeddedBoundary.capture.effectiveVisible)
        #expect(embeddedBoundary.status == .available)
        #expect(embeddedBoundary.visibleLines.count == 2)
        let boundaryCaptureIdentity = embeddedBoundary.capture.identity
        let boundaryResultOwner = embeddedBoundary.capture.resultOwner
        mapState.boundaryMap.invalidate()
        await store.refreshBoundaryMap(mapID)
        try await waitUntil("retried exact Result Boundary Condition", timeout: .seconds(30)) {
            mapState.boundaryMap.entries.contains {
                $0.capture.identity == boundaryCaptureIdentity && $0.status == .available
            } && !mapState.boundaryMap.isLoading
        }
        let retriedBoundary = try #require(mapState.boundaryMap.entries.first {
            $0.capture.identity == boundaryCaptureIdentity
        })
        #expect(retriedBoundary.capture.resultOwner == boundaryResultOwner)
        #expect(retriedBoundary.visibleLines.count == 2)

        // The associated Terrain style service is scoped to the exact Plan
        // Matching Layers row and its source revision, and persists only .vis.
        let style = try await store.makeAssociatedRasterStyleSession(node: terrainNode, mapID: mapID)
        await style.load()
        var styleDraft = try #require(style.draft)
        let changedAlpha = styleDraft.alpha == 211 ? 212 : 211
        styleDraft.alpha = changedAlpha
        style.draft = styleDraft
        #expect(await style.apply())
        #expect(style.snapshot?.draft.alpha == changedAlpha)
        #expect(try Data(contentsOf: visualizationURL) != visualizationAfterSettings)
        await store.configureMapResultSources(mapID)
        try await waitUntil("refreshed Result context after Terrain style", timeout: .seconds(30)) {
            guard let snapshot = mapState.resultSources.snapshot,
                  let identity = store.mapIdentityRequest(for: mapID) else { return false }
            return snapshot.sources.visualizationRevision == identity.expectedVisualizationRevision
                && !mapState.resultSources.isLoading
        }

        // Exercise the saved culvert profile endpoint against the exact same
        // slot-zero Result. Its arrays are read from Result.OutputBlock, in the
        // retained Geometry barrel order; no terrain elevation profile is used.
        let currentSources = try #require(mapState.resultSources.snapshot)
        let currentResultNode = try #require(currentSources.sources.activeNodes.first { $0.id == sourceNode.id })
        let mapTreeContext = store.sourceMapTreeContext(mapID)
        let currentMapIdentity = try #require(store.mapIdentityRequest(for: mapID))
        let request = PlanCulvertProfileRequest(
            map: .init(currentMapIdentity,
                resultSelectionOverrides: mapTreeContext.resultSelectionOverrides,
                coreLayerContext: currentSources.map.coreLayerContext),
            contextToken: currentSources.sources.contextToken,
            selectionOverrides: currentSources.selectionOverrides,
            resultNode: currentResultNode.node,
            selectionIndex: 0,
            profileIndex: signedProfile.index)
        let culvert: PlanCulvertProfileSnapshot = try await client.request(
            "map.result.culvertProfile", parameters: request, as: PlanCulvertProfileSnapshot.self)
        #expect(culvert.contextToken == currentSources.sources.contextToken)
        #expect(culvert.resultNode == currentResultNode.node)
        #expect(culvert.selectionIndex == 0 && culvert.profileIndex == signedProfile.index)
        #expect(culvert.selectedMapType == "Depth")
        #expect(canonical(culvert.selectedResultPath) == canonical(signedChoice.resultPath))
        #expect(culvert.selectedResultRevision.caseInsensitiveCompare(signedChoice.revision) == .orderedSame)
        #expect(culvert.geometryAvailable && culvert.outputAvailable)
        #expect(canonical(culvert.geometryPath) == canonical(signedChoice.resultPath))
        #expect(culvert.geometryRevision.caseInsensitiveCompare(signedChoice.revision) == .orderedSame)
        #expect(culvert.barrels.map(\.name) == manifest.barrelNames)
        #expect(culvert.barrels.map(\.sourceOrdinal) == Array(manifest.barrelNames.indices))
        #expect(culvert.flow.count == manifest.barrelNames.count)
        #expect(culvert.outletVelocity.count == manifest.barrelNames.count)
        #expect(culvert.outsideDepth.count == manifest.barrelNames.count * 2)
        #expect(culvert.flow[0] * culvert.flow[1] < 0)
        #expect(zip(culvert.flow, signedProfile.flow).allSatisfy { pair in
            abs(pair.0 - Double(pair.1)) < 1e-5
        })
        #expect(zip(culvert.outsideDepth, signedProfile.outsideDepth).allSatisfy { pair in
            abs(pair.0 - Double(pair.1)) < 1e-5
        })
        #expect(zip(culvert.outletVelocity, signedProfile.outletVelocity).allSatisfy { pair in
            abs(pair.0 - Double(pair.1)) < 1e-5
        })

        let profileWorkflowIdentity = store.mapSourceWorkflowIdentity(mapID)
        let profileCapture = try StoredCulvertProfileCapture(
            projectSessionID: store.projectSessionID,
            workflowIdentity: profileWorkflowIdentity,
            map: currentMapIdentity,
            snapshot: currentSources,
            resultNodeID: currentResultNode.id,
            profileIndex: signedProfile.index)
        let storedProfileSession = StoredCulvertProfileSession()
        storedProfileSession.configure(capture: profileCapture,
            provider: BackendMapResultCulvertProfileProvider(client: client),
            timeline: timeline,
            isCurrent: { store.mapSourceWorkflowIdentity(mapID) == profileWorkflowIdentity })
        try await waitUntil("native stored culvert profile", timeout: .seconds(30)) {
            storedProfileSession.snapshot != nil && !storedProfileSession.isLoading
        }
        let storedProfile = try #require(storedProfileSession.snapshot)
        #expect(storedProfileSession.canAnimate)
        #expect(storedProfile.profileIndex == signedProfile.index)
        #expect(storedProfile.barrels.map(\.name) == manifest.barrelNames)
        #expect(zip(storedProfile.flow, signedProfile.flow).allSatisfy { pair in
            abs(pair.0 - Double(pair.1)) < 1e-5
        })
        storedProfileSession.invalidate()

        // Return slot zero to the retained Latest choice, then read the real
        // zero-flow Result through the same exact owner route. Slot one remains
        // an independent selection request for the earlier signed Result. The
        // source canonicalizes that exact second candidate to Previous.
        await mapState.resultSources.setSelection(nodeID: sourceNode.id,
            selectionIndex: 0, mode: .latest)
        try await waitUntil("Latest Result selection", timeout: .seconds(20)) {
            guard let slot = mapState.resultSources.snapshot?.sources.activeNodes
                .first(where: { $0.id == sourceNode.id })?.selections.first(where: { $0.selectionIndex == 0 }) else {
                return false
            }
            return slot.selectionMode == .latest
                && slot.selectedResult?.id == latestChoice.id
                && !mapState.resultSources.isSelecting
        }
        await store.configureMapResultSources(mapID)
        let zeroSources = try #require(mapState.resultSources.snapshot)
        let zeroResultNode = try #require(zeroSources.sources.activeNodes.first { $0.id == sourceNode.id })
        #expect(zeroResultNode.selections.first(where: { $0.selectionIndex == 1 })?.selectedResult?.id == signedChoice.id)
        let zeroProfile = try #require(latestFixture.profiles.first {
            $0.flow.count == manifest.barrelNames.count
                && $0.flow.allSatisfy { abs($0) <= 0.001 }
        })
        let zeroMapIdentity = try #require(store.mapIdentityRequest(for: mapID))
        let zeroMapContext = store.sourceMapTreeContext(mapID)
        let zeroRequest = PlanCulvertProfileRequest(
            map: .init(zeroMapIdentity,
                resultSelectionOverrides: zeroMapContext.resultSelectionOverrides,
                coreLayerContext: zeroSources.map.coreLayerContext),
            contextToken: zeroSources.sources.contextToken,
            selectionOverrides: zeroSources.selectionOverrides,
            resultNode: zeroResultNode.node,
            selectionIndex: 0,
            profileIndex: zeroProfile.index)
        let zeroCulvert: PlanCulvertProfileSnapshot = try await client.request(
            "map.result.culvertProfile", parameters: zeroRequest, as: PlanCulvertProfileSnapshot.self)
        #expect(canonical(zeroCulvert.selectedResultPath)
            == canonical(workingRoot.appendingPathComponent(latestFixture.path).path))
        #expect(zeroCulvert.selectedResultRevision.caseInsensitiveCompare(latestFixture.revision) == .orderedSame)
        #expect(zeroCulvert.barrels.map(\.name) == manifest.barrelNames)
        #expect(zeroCulvert.flow.allSatisfy { abs($0) <= 0.001 })
        #expect(zip(zeroCulvert.flow, zeroProfile.flow).allSatisfy { pair in
            abs(pair.0 - Double(pair.1)) < 1e-5
        })
        #expect(zip(zeroCulvert.outsideDepth, zeroProfile.outsideDepth).allSatisfy { pair in
            abs(pair.0 - Double(pair.1)) < 1e-5
        })
        #expect(zip(zeroCulvert.outletVelocity, zeroProfile.outletVelocity).allSatisfy { pair in
            abs(pair.0 - Double(pair.1)) < 1e-5
        })

        // Selecting another real source timeline step must persist the exact
        // profile index on this MultiResult row, without writing solver inputs.
        try await waitUntil("latest Result timeline", timeout: .seconds(30)) {
            guard let currentTimeline = mapState.resultMap.selectedTimeline else { return false }
            return currentTimeline.steps.count == latestFixture.profileCount
                && currentTimeline.canSelect
                && !currentTimeline.busy
                && mapState.resultMap.selectedNode?.id == sourceNode.id
        }
        let latestTimeline = try #require(mapState.resultMap.selectedTimeline)
        let initialTimelineProfile = try #require(latestTimeline.currentID)
        let alternatePosition = try #require(latestTimeline.steps.firstIndex { $0.id != initialTimelineProfile })
        let alternateProfileIndex = latestTimeline.steps[alternatePosition].id
        #expect(latestFixture.profiles.contains { $0.index == alternateProfileIndex })
        let revisionBeforeTimelineSelection = try #require(
            store.mapIdentityRequest(for: mapID)?.expectedVisualizationRevision)
        latestTimeline.select(position: alternatePosition)
        try await waitUntil("native timeline frame", timeout: .seconds(40)) {
            guard let currentTimeline = mapState.resultMap.selectedTimeline else { return false }
            return currentTimeline.currentID == alternateProfileIndex && !currentTimeline.busy
        }
        try await waitUntil("persisted exact timeline frame", timeout: .seconds(40)) {
            guard let identity = store.mapIdentityRequest(for: mapID),
                  let snapshot = mapState.resultSources.snapshot,
                  let active = snapshot.sources.activeNodes.first(where: { $0.id == sourceNode.id }),
                  let rendered = mapState.resultMap.nodes.first(where: { $0.id == sourceNode.id }) else { return false }
            return identity.expectedVisualizationRevision != revisionBeforeTimelineSelection
                && snapshot.sources.visualizationRevision == identity.expectedVisualizationRevision
                && active.profileIndex == alternateProfileIndex
                && rendered.profileIndex == alternateProfileIndex
                && !mapState.resultSources.isLoading && !mapState.resultMap.isLoading
        }
        await store.configureMapResultSources(mapID)

        #expect(try sourceBytes.matches(root: workingRoot))
        let originalProjectBytes = try #require(sourceBytes.bytes(relativePath: manifest.projectRelativePath))
        let originalPlanBytes = try #require(sourceBytes.bytes(relativePath: manifest.planRelativePath))
        let originalGeometryBytes = try #require(sourceBytes.bytes(relativePath: manifest.geometryRelativePath))
        let originalBoundaryBytes = try #require(sourceBytes.bytes(relativePath: manifest.boundaryConditionRelativePath))
        #expect(try Data(contentsOf: projectURL) == originalProjectBytes)
        #expect(try Data(contentsOf: planURL) == originalPlanBytes)
        #expect(try Data(contentsOf: geometryURL) == originalGeometryBytes)
        #expect(try Data(contentsOf: boundaryURL) == originalBoundaryBytes)
        #expect(FileManager.default.fileExists(atPath: visualizationURL.path))

        // A new Store session proves the .vis presentation survives reopening,
        // while the nonserialized latest/previous/explicit chooser resets to
        // the retained source default Latest.
        store.requestClose()
        if store.showDiscardConfirmation { store.discardAndContinue() }
        try #require(store.document == nil)

        let reopened = WorkspaceStore(system: PlanMapFixtureServices(),
            modelProvider: BackendModelProvider(client: client))
        try await open(reopened, projectURL: projectURL)
        let reopenedMap = try #require(reopened.mapDocuments.first { $0.name == map.name && $0.kind == .plan })
        let reopenedState = reopened.mapState(for: reopenedMap.id)
        await reopened.configureMapResultSources(reopenedMap.id)
        try await waitUntil("reopened Plan Result map", timeout: .seconds(30)) {
            !reopenedState.resultSources.isLoading && reopenedState.resultSources.sources?.activeNodes.isEmpty == false
        }
        let reopenedActive = try #require(reopenedState.resultSources.snapshot?.sources.activeNodes.first {
            $0.nodeKind == "MultiResult" && $0.name == manifest.planName
        })
        #expect(reopenedActive.selectedMapType == "Depth")
        #expect(reopenedActive.profileIndex == alternateProfileIndex)
        #expect(reopenedActive.selections.first?.selectionMode == .latest)
        #expect(reopenedState.resultSelectionOverrides.isEmpty)
        let reopenedNodes = try await reopened.sourceMapLayerNodes(reopenedMap.id)
        // A single focused Plan keeps its associations under that Plan; Matching Layers is for shared associations.
        let reopenedTerrain = try #require(findNode(reopenedNodes, type: "Terrain", root: "Focused Plans") {
            $0.associationKind == "Terrain"
                && $0.parentPlanAssetID.map(canonical) == canonical(planURL.path)
                && $0.parentPlanNodeName == manifest.planName
        })
        let reopenedStyle = try await reopened.makeAssociatedRasterStyleSession(node: reopenedTerrain,
            mapID: reopenedMap.id)
        await reopenedStyle.load()
        #expect(reopenedStyle.snapshot?.draft.alpha == changedAlpha)
        #expect(try sourceBytes.matches(root: workingRoot))
    }

    @Test @MainActor
    func deletingMiddleDuplicateNamedPlanMapPreservesExactRuntimeOwnersByIndexReceipt() async throws {
        let environment = ProcessInfo.processInfo.environment
        let executable = URL(fileURLWithPath: try #require(environment["HECRAS_BACKEND_TEST_EXECUTABLE"]))
        let fixtureDirectory = URL(fileURLWithPath: try #require(environment["HECRAS_PLAN_MAP_ACCEPTANCE_DIRECTORY"]))
        let workingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("plan-map-delete-workflow-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.copyItem(at: fixtureDirectory, to: workingRoot)
        defer { try? FileManager.default.removeItem(at: workingRoot) }

        let manifest = try JSONDecoder().decode(PlanMapAcceptanceManifest.self,
            from: Data(contentsOf: workingRoot.appendingPathComponent("acceptance.json")))
        let projectURL = workingRoot.appendingPathComponent(manifest.projectRelativePath)
        let visualizationURL = projectURL.deletingPathExtension().appendingPathExtension("vis")
        let sourceBytes = try PlanMapSourceByteSnapshot(root: workingRoot)
        let seedStore = WorkspaceStore(system: PlanMapFixtureServices(),
            modelProvider: BackendModelProvider(client: BackendProcessClient(executableURL: executable)))
        try await open(seedStore, projectURL: projectURL)
        let plan = try #require(seedStore.assets.first {
            $0.section == .plans && $0.name == manifest.planName && $0.isModelFile
        })
        #expect(await seedStore.createPlanMap(focusedPlanAssetID: plan.id))
        #expect(await seedStore.createPlanMap())
        #expect(await seedStore.createPlanMap(focusedPlanAssetID: plan.id))

        let seededMaps = seedStore.mapDocuments.compactMap { map -> (MapDocument, MapTreeMapIdentity)? in
            seedStore.mapIdentityRequest(for: map.id).map { (map, $0) }
        }.sorted { $0.1.mapIndex < $1.1.mapIndex }
        #expect(seededMaps.count == 3)
        let originalFirstName = try #require(seededMaps.first?.1.mapName)
        let xml = try XMLDocument(data: Data(contentsOf: visualizationURL), options: [.nodePreserveAll])
        let root = try #require(xml.rootElement())
        let mapsElement = try #require(root.elements(forName: "Maps").first)
        let mapElements = mapsElement.elements(forName: "Map")
        #expect(mapElements.count == 3)
        mapElements[2].attribute(forName: "Name")?.stringValue = originalFirstName
        mapElements[0].addAttribute(XMLNode.attribute(withName: "UnknownR20Map", stringValue: "first") as! XMLNode)
        mapElements[2].addAttribute(XMLNode.attribute(withName: "UnknownR20Map", stringValue: "last") as! XMLNode)
        root.addChild(XMLElement(name: "UnknownR20Section", stringValue: "preserve"))
        try xml.xmlData.write(to: visualizationURL)

        seedStore.requestClose()
        if seedStore.showDiscardConfirmation { seedStore.discardAndContinue() }
        try #require(seedStore.document == nil)

        // Reopen after the test-only source .vis duplicate-name setup. Saved
        // map UUIDs are then owned by exact source indices, never a title key.
        let store = WorkspaceStore(system: PlanMapFixtureServices(),
            modelProvider: BackendModelProvider(client: BackendProcessClient(executableURL: executable)))
        try await open(store, projectURL: projectURL)
        let indexedMaps = store.mapDocuments.compactMap { map -> (MapDocument, MapTreeMapIdentity)? in
            store.mapIdentityRequest(for: map.id).map { (map, $0) }
        }.sorted { $0.1.mapIndex < $1.1.mapIndex }
        #expect(indexedMaps.count == 3)
        let first = try #require(indexedMaps.first)
        let middle = try #require(indexedMaps.dropFirst().first)
        let last = try #require(indexedMaps.last)
        #expect(first.1.mapIndex == 0 && middle.1.mapIndex == 1 && last.1.mapIndex == 2)
        #expect(first.1.mapType == "Plan" && middle.1.mapType == "Plan" && last.1.mapType == "Plan")
        #expect(first.1.mapName == last.1.mapName)
        #expect(first.0.id != middle.0.id && middle.0.id != last.0.id && first.0.id != last.0.id)

        for map in [first.0, last.0] {
            #expect(await store.focusPlanInMap(assetID: plan.id, mapID: map.id))
            let tree = try await store.sourceMapLayerNodes(map.id)
            let resultGroup = try #require(findNode(tree, type: "MultiResult", root: "Focused Plans"))
            #expect(await store.setSourceMapVisibility(resultGroup, checked: true, mapID: map.id))
            await store.configureMapResultSources(map.id)
        }

        // Each visibility mutation advances the project-wide .vis revision,
        // which intentionally invalidates every map's captured source session.
        // Rebind both maps after the final write, as switching back to a map in
        // the UI does, before issuing map-local result selection requests.
        await store.configureMapResultSources(first.0.id)
        await store.configureMapResultSources(last.0.id)

        let firstState = store.mapState(for: first.0.id)
        let lastState = store.mapState(for: last.0.id)
        try await waitUntil("duplicate-name first Plan result sources", timeout: .seconds(30)) {
            firstState.resultSources.snapshot?.sources.activeNodes.contains { $0.nodeKind == "MultiResult" } == true
                && !firstState.resultSources.isLoading
        }
        try await waitUntil("duplicate-name last Plan result sources", timeout: .seconds(30)) {
            lastState.resultSources.snapshot?.sources.activeNodes.contains { $0.nodeKind == "MultiResult" } == true
                && !lastState.resultSources.isLoading
        }
        let firstNode = try #require(firstState.resultSources.snapshot?.sources.activeNodes.first {
            $0.nodeKind == "MultiResult" && $0.name == manifest.planName
        })
        let lastNode = try #require(lastState.resultSources.snapshot?.sources.activeNodes.first {
            $0.nodeKind == "MultiResult" && $0.name == manifest.planName
        })
        let signedResult = try #require(manifest.results.first { $0.role == "signed-flow" })
        let latestResult = try #require(manifest.results.first { $0.role == "zero-flow" })
        let signedResultPath = workingRoot.appendingPathComponent(signedResult.path).path
        let latestResultPath = workingRoot.appendingPathComponent(latestResult.path).path
        let latestChoice = try #require(firstNode.selections.first?.choices.first {
            canonical($0.resultPath) == canonical(latestResultPath)
                && $0.revision.caseInsensitiveCompare(latestResult.revision) == .orderedSame
        })
        let lastChoice = try #require(lastNode.selections.first?.choices.first {
            canonical($0.resultPath) == canonical(signedResultPath)
                && $0.revision.caseInsensitiveCompare(signedResult.revision) == .orderedSame
        })
        await firstState.resultSources.setSelection(nodeID: firstNode.id, selectionIndex: 0, mode: .latest)
        await lastState.resultSources.setSelection(nodeID: lastNode.id, selectionIndex: 0,
            mode: .explicit, choice: lastChoice)
        try await waitUntil("map-local duplicate-name result selections", timeout: .seconds(30)) {
            let firstSlot = firstState.resultSources.snapshot?.sources.activeNodes
                .first(where: { $0.id == firstNode.id })?.selections.first
            let lastSlot = lastState.resultSources.snapshot?.sources.activeNodes
                .first(where: { $0.id == lastNode.id })?.selections.first
            return firstSlot?.selectionMode == .latest
                && firstSlot?.selectedResult?.id == latestChoice.id
                && canonical(firstSlot?.selectedResult?.resultPath ?? "") == canonical(latestResultPath)
                && lastSlot?.selectionMode == .previous
                && lastSlot?.selectedResult?.id == lastChoice.id
                && canonical(lastSlot?.selectedResult?.resultPath ?? "") == canonical(signedResultPath)
                && !firstState.resultSources.isSelecting && !lastState.resultSources.isSelecting
        }
        let firstOverrides = firstState.resultSelectionOverrides
        let lastOverrides = lastState.resultSelectionOverrides
        #expect(firstOverrides != lastOverrides)
        let visualizationBeforeDelete = try Data(contentsOf: visualizationURL)
        #expect(try sourceBytes.matches(root: workingRoot))

        #expect(await store.deleteMapDocument(middle.0.id))
        #expect(store.mapIdentityRequest(for: middle.0.id) == nil)
        let firstAfter = try #require(store.mapIdentityRequest(for: first.0.id))
        let lastAfter = try #require(store.mapIdentityRequest(for: last.0.id))
        #expect(firstAfter.mapIndex == 0 && lastAfter.mapIndex == 1)
        #expect(firstAfter.mapName == lastAfter.mapName)
        #expect(firstAfter.mapID == first.1.mapID && lastAfter.mapID == last.1.mapID)
        #expect(store.mapState(for: first.0.id) === firstState)
        #expect(store.mapState(for: last.0.id) === lastState)
        #expect(firstState.resultSelectionOverrides == firstOverrides)
        #expect(lastState.resultSelectionOverrides == lastOverrides)

        let saved = try XMLDocument(data: Data(contentsOf: visualizationURL), options: [.nodePreserveAll])
        let savedRoot = try #require(saved.rootElement())
        let savedMaps = try #require(savedRoot.elements(forName: "Maps").first).elements(forName: "Map")
        #expect(savedMaps.count == 2)
        #expect(savedMaps.allSatisfy { $0.attribute(forName: "Name")?.stringValue == originalFirstName })
        #expect(savedMaps[0].attribute(forName: "UnknownR20Map")?.stringValue == "first")
        #expect(savedMaps[1].attribute(forName: "UnknownR20Map")?.stringValue == "last")
        #expect(savedRoot.elements(forName: "UnknownR20Section").first?.stringValue == "preserve")
        #expect(try sourceBytes.matches(root: workingRoot))
        #expect(try Data(contentsOf: visualizationURL) != visualizationBeforeDelete)
    }

    @MainActor
    private func open(_ store: WorkspaceStore, projectURL: URL) async throws {
        store.requestOpen(projectURL)
        try await waitUntil("project open", timeout: .seconds(30)) {
            store.document?.url?.standardizedFileURL == projectURL.standardizedFileURL
                && !store.isOpeningProject
        }
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
        throw PlanMapWorkflowTestError.timedOut(label)
    }

    private func findNode(_ nodes: [LayerTreeNode], type: String, root: String,
                          where predicate: (CatalogTreeNodeLocator) -> Bool = { _ in true }) -> LayerTreeNode? {
        nodes.first { node in
            guard let locator = node.sourceLocator else { return false }
            return locator.rootName == root && locator.nodeType == type && predicate(locator)
        }
    }

    private func findNodes(_ nodes: [LayerTreeNode], type: String, root: String) -> [LayerTreeNode] {
        nodes.filter { node in
            node.sourceLocator?.rootName == root && node.sourceLocator?.nodeType == type
        }
    }

    private func canonical(_ path: String) -> String {
        SourceFilePaths.canonical(URL(fileURLWithPath: path))
    }
}

private struct PlanMapAcceptanceManifest: Decodable {
    let projectRelativePath: String
    let planRelativePath: String
    let sharedPlanRelativePath: String
    let alternatePlanRelativePath: String
    let geometryRelativePath: String
    let alternateGeometryRelativePath: String
    let boundaryConditionRelativePath: String
    let terrainRasterRelativePath: String
    let planName: String
    let sharedPlanName: String
    let alternatePlanName: String
    let geometryName: String
    let alternateGeometryName: String
    let boundaryConditionName: String
    let barrelNames: [String]
    let results: [PlanMapAcceptanceResult]
}

private struct PlanMapAcceptanceResult: Decodable {
    let role: String
    let path: String
    let revision: String
    let profileCount: Int
    let profileNames: [String]
    let profiles: [PlanMapAcceptanceProfile]
}

private struct PlanMapAcceptanceProfile: Decodable {
    let index: Int
    let name: String
    let time: String
    let flow: [Float]
    let outsideDepth: [Float]
    let outletVelocity: [Float]
}

private struct PlanTreeWireRequest: Encodable {
    let projectPath: String
    let projectXml: String
    let projectXmlSHA: String
    let mapID: String
    let mapIndex: Int
    let mapName: String
    let mapType: String
    let expectedVisualizationRevision: String
    let resultSelectionOverrides: [MapTreeResultSelectionOverride]
    let coreLayerContext: CoreLayerRequestContext?

    init(_ identity: MapTreeMapIdentity,
         resultSelectionOverrides: [MapTreeResultSelectionOverride],
         coreLayerContext: CoreLayerRequestContext?) {
        projectPath = identity.projectPath
        projectXml = identity.projectXml
        projectXmlSHA = identity.projectXmlSHA
        mapID = identity.mapID
        mapIndex = identity.mapIndex
        mapName = identity.mapName
        mapType = identity.mapType
        expectedVisualizationRevision = identity.expectedVisualizationRevision
        self.resultSelectionOverrides = resultSelectionOverrides
        self.coreLayerContext = coreLayerContext
    }
}

private struct PlanCulvertProfileRequest: Encodable {
    let map: PlanTreeWireRequest
    let contextToken: String
    let selectionOverrides: [MapResultSelectionOverride]
    let resultNode: CatalogTreeNodeLocator
    let selectionIndex: Int
    let profileIndex: Int
}

private struct PlanCulvertProfileSnapshot: Decodable {
    struct Barrel: Decodable {
        let sourceOrdinal: Int
        let name: String
    }

    let contextToken: String
    let resultNode: CatalogTreeNodeLocator
    let selectionIndex: Int
    let selectedResultPath: String
    let selectedResultRevision: String
    let profileIndex: Int
    let selectedMapType: String?
    let geometryPath: String
    let geometryRevision: String
    let geometryAvailable: Bool
    let outputAvailable: Bool
    let barrels: [Barrel]
    let flow: [Double]
    let outsideDepth: [Double]
    let outletVelocity: [Double]
}

private struct PlanMapSourceByteSnapshot {
    let files: [String: Data]

    init(root: URL) throws {
        let canonicalRoot = SourceFilePaths.canonical(root)
        let rootPrefix = canonicalRoot.hasSuffix("/") ? canonicalRoot : canonicalRoot + "/"
        guard let enumerator = FileManager.default.enumerator(at: root,
            includingPropertiesForKeys: [.isRegularFileKey]) else {
            throw PlanMapWorkflowTestError.unreadableFixture
        }
        var captured: [String: Data] = [:]
        for case let file as URL in enumerator {
            guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            let extensionName = file.pathExtension.lowercased()
            guard ["ras", "h5", "hdf", "tif", "tiff"].contains(extensionName) else { continue }
            let canonicalFile = SourceFilePaths.canonical(file)
            guard canonicalFile.hasPrefix(rootPrefix) else {
                throw PlanMapWorkflowTestError.unreadableFixture
            }
            let relative = String(canonicalFile.dropFirst(rootPrefix.count))
            captured[relative] = try Data(contentsOf: file)
        }
        files = captured
    }

    func bytes(relativePath: String) -> Data? { files[relativePath] }

    func matches(root: URL) throws -> Bool {
        let current = try PlanMapSourceByteSnapshot(root: root)
        guard Set(current.files.keys) == Set(files.keys) else { return false }
        return files.allSatisfy { current.files[$0.key] == $0.value }
    }
}

@MainActor
private final class PlanMapFixtureServices: WorkspaceSystemServices {
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

private enum PlanMapWorkflowTestError: Error {
    case unreadableFixture
    case timedOut(String)
}
