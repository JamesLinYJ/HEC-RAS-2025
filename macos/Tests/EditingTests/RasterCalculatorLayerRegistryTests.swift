import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

struct RasterCalculatorLayerRegistryTests {
    @Test @MainActor
    func referenceUpdatesUseVisibleFullSourceBoundsInsteadOfCurrentRasterFrame() throws {
        let store = WorkspaceStore(launchConfiguration:
            WorkspaceLaunchConfiguration(arguments: ["HECRAS2025", "--first-launch"]))
        let mapID = UUID()
        let workflow = store.mapWorkflowIdentity(mapID)
        let registry = CalculatorLayerRegistry()
        var updates: [CalculatorReferencePointsUpdate] = []
        registry.onReferencePointsChanged = { changedMapID, points in
            updates.append(CalculatorReferencePointsUpdate(mapID: changedMapID, points: points))
        }

        let initialBounds = MapSourceRasterBounds(minX: 0, minY: 10, maxX: 100, maxY: 210)
        let entry = try makeEntry(store: store, mapID: mapID, workflow: workflow,
            id: "calculator-layer", sourceExtent: initialBounds)
        registry.add(entry)
        #expect(updates.last?.points == [MapPoint(x: 0, y: 10), MapPoint(x: 100, y: 210)])

        let renderedBounds = MapSourceRasterBounds(minX: -5, minY: 5, maxX: 105, maxY: 205)
        let renderedFrame = try MapRasterLayer(id: entry.id, name: entry.name,
            width: 1, height: 1, rgba: Data([0, 0, 0, 255]),
            lowerLeft: MapPoint(x: 20, y: 30), upperRight: MapPoint(x: 40, y: 50),
            sourceMapID: mapID)
        #expect(registry.installRenderedFrame(renderedFrame, sourceExtent: renderedBounds,
            id: entry.id, mapID: mapID, projectSessionID: store.projectSessionID,
            workflowIdentity: workflow, renderer: entry.renderer))
        #expect(updates.last?.points == [MapPoint(x: -5, y: 5), MapPoint(x: 105, y: 205)])

        registry.setVisible(false, id: entry.id, mapID: mapID,
            projectSessionID: store.projectSessionID, workflowIdentity: workflow)
        #expect(updates.last?.points == [])

        registry.setVisible(true, id: entry.id, mapID: mapID,
            projectSessionID: store.projectSessionID, workflowIdentity: workflow)
        #expect(updates.last?.points == [MapPoint(x: -5, y: 5), MapPoint(x: 105, y: 205)])

        let replacementBounds = MapSourceRasterBounds(minX: -20, minY: -30, maxX: 80, maxY: 70)
        let replacement = try makeEntry(store: store, mapID: mapID, workflow: workflow,
            id: entry.id, sourceExtent: replacementBounds)
        #expect(registry.replace(id: entry.id, with: replacement))
        #expect(updates.last?.points == [MapPoint(x: -20, y: -30), MapPoint(x: 80, y: 70)])

        registry.remove(id: entry.id, mapID: mapID,
            projectSessionID: store.projectSessionID, workflowIdentity: workflow)
        #expect(updates.last?.mapID == mapID)
        #expect(updates.last?.points == [])
        #expect(updates.count == 6)
    }

    @Test @MainActor
    func ordinaryVisualizationRevisionPreservesRecipeAndRejectsLateOldFrame() throws {
        let store = WorkspaceStore(launchConfiguration:
            WorkspaceLaunchConfiguration(arguments: ["HECRAS2025", "--first-launch"]))
        let mapID = UUID()
        let oldCapture = makeMapCapture(mapID: mapID, sha: "old-project-sha", visualization: "old-vis")
        let newCapture = makeMapCapture(mapID: mapID, sha: "new-project-sha", visualization: "new-vis")
        let oldWorkflow = "old-capture-epoch"
        let newWorkflow = "ordinary-style-revision"
        let sourceRevision = String(repeating: "A", count: 64)
        let recipe = RasterCalculatorRecipe(expression: "depth * factor",
            noDataBehavior: "WriteNDV", keyFrameVariableName: "depth",
            inputs: [RasterCalculatorInput(variableName: "depth", sourceID: "result-source",
                sourceRevision: sourceRevision, kind: "resultMap", mapType: "Depth", isKeyFrame: true)],
            constants: [RasterCalculatorConstant(name: "factor", value: "2")])
        let profiles = [RasterCalculatorProfile(index: 0, time: "t=0"),
                        RasterCalculatorProfile(index: 1, time: "t=1")]
        let registry = CalculatorLayerRegistry()
        let bounds = MapSourceRasterBounds(minX: 0, minY: 0, maxX: 10, maxY: 10)
        let entry = try makeEntry(store: store, mapID: mapID, workflow: oldWorkflow,
            id: "calculator-dynamic", sourceExtent: bounds, mapCapture: oldCapture,
            recipe: recipe, profiles: profiles, selectedProfileIndex: 1, isDynamic: true)
        registry.add(entry)
        registry.setVisible(false, id: entry.id, mapID: mapID,
            projectSessionID: store.projectSessionID, workflowIdentity: oldWorkflow)

        let staleLayer = try #require(entry.layer)
        registry.refreshMapCapture(mapID: mapID, projectSessionID: store.projectSessionID,
            mapCapture: newCapture, workflowIdentity: newWorkflow, viewport: nil)

        let rebound = try #require(registry.entry(id: entry.id, mapID: mapID,
            projectSessionID: store.projectSessionID, workflowIdentity: newWorkflow))
        #expect(rebound.mapCapture == newCapture)
        #expect(rebound.recipe == recipe)
        #expect(rebound.name == entry.name)
        #expect(!rebound.isVisible)
        #expect(rebound.isDynamic)
        #expect(rebound.profiles == profiles)
        #expect(rebound.selectedProfileIndex == 1)
        #expect(rebound.layer?.id == nil)
        #expect(rebound.sourceExtent == nil)
        #expect(!registry.installRenderedFrame(staleLayer, sourceExtent: bounds,
            id: entry.id, mapID: mapID, projectSessionID: store.projectSessionID,
            workflowIdentity: oldWorkflow, renderer: entry.renderer),
            "A delayed raster from the previous capture epoch must not reappear.")
        #expect(registry.entry(id: entry.id, mapID: mapID,
            projectSessionID: store.projectSessionID, workflowIdentity: newWorkflow)?.layer?.id == nil)
        registry.synchronizeOwners(projectSessionID: store.projectSessionID, mapTypes: [:])
        #expect(registry.entry(id: entry.id, mapID: mapID,
            projectSessionID: store.projectSessionID, workflowIdentity: newWorkflow)?.id == nil,
            "A map removed from the project catalog must release its transient calculator recipe.")
    }

    @MainActor
    private func makeEntry(store: WorkspaceStore, mapID: UUID, workflow: String,
                           id: String, sourceExtent: MapSourceRasterBounds,
                           mapCapture: MapTreeMapIdentity? = nil,
                           recipe: RasterCalculatorRecipe = RasterCalculatorRecipe(expression: "a", noDataBehavior: "WriteNDV"),
                           profiles: [RasterCalculatorProfile] = [], selectedProfileIndex: Int = 0,
                           isDynamic: Bool = false) throws
        -> CalculatorMapLayerEntry {
        let map = mapCapture ?? makeMapCapture(mapID: mapID, sha: "", visualization: "")
        let renderer = CalculatorLayerRenderCoordinator(store: store,
            provider: BackendRasterCalculatorProvider(), map: map, mapID: mapID,
            projectSessionID: store.projectSessionID, mapWorkflowIdentity: workflow,
            layerID: id, layerName: "Calculator result",
            recipe: recipe, contextToken: "context", sources: [], profiles: profiles,
            isDynamic: isDynamic)
        let frame = try MapRasterLayer(id: id, name: "Calculator result", width: 1,
            height: 1, rgba: Data([0, 0, 0, 255]),
            lowerLeft: MapPoint(x: 20, y: 30), upperRight: MapPoint(x: 40, y: 50),
            sourceMapID: mapID)
        return CalculatorMapLayerEntry(id: id, mapID: mapID,
            projectSessionID: store.projectSessionID, mapWorkflowIdentity: workflow, mapCapture: map,
            name: "Calculator result", recipe: recipe,
            layer: frame, sourceExtent: sourceExtent, profiles: profiles, selectedProfileIndex: selectedProfileIndex,
            isDynamic: isDynamic, isVisible: true, contextToken: "context", sources: [],
            renderer: renderer)
    }

    private func makeMapCapture(mapID: UUID, sha: String, visualization: String) -> MapTreeMapIdentity {
        MapTreeMapIdentity(projectPath: "/tmp/raster-calculator-test.ras", projectXml: "",
            projectXmlSHA: sha, mapID: mapID.uuidString, mapIndex: 0, mapName: "Map",
            mapType: "Project", expectedVisualizationRevision: visualization)
    }
}

private struct CalculatorReferencePointsUpdate: Equatable {
    let mapID: UUID
    let points: [MapPoint]
}
