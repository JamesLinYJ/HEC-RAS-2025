import Foundation
import Testing
@testable import HECRAS2025

struct MapDynamicProfileWindowTests {
    @Test func savedLineEntriesMatchTheOriginalTerrainAndResultsDefaults() {
        let terrain = MapDynamicProfileWindowPresentation(title: "Project Profile Plot", mode: .terrain)
        #expect(terrain.plotTerrains && !terrain.plotResults)
        #expect(!terrain.terrainRequiresElevationResult && !terrain.showsResultMapTypeSelector)
        #expect(terrain.initialMapType == "WaterSurfaceElevation" && terrain.targetSampleCount == 256)
        #expect(terrain.axisUnits == nil && terrain.legendWidthThreshold == 0
            && terrain.legendHeightThreshold == 0)

        let results = MapDynamicProfileWindowPresentation(title: "Project Profile Plot", mode: .results)
        #expect(results.plotTerrains && results.plotResults)
        #expect(results.terrainRequiresElevationResult && results.showsResultMapTypeSelector)
        #expect(results.initialMapType == "WaterSurfaceElevation" && results.targetSampleCount == 256)
        #expect(results.legendWidthThreshold == 0 && results.legendHeightThreshold == 0)

        let draft = MapDynamicProfileWindowPresentation.geometryDraft
        #expect(draft.initialMapType == "WaterSurfaceElevation" && draft.showsResultMapTypeSelector)
        #expect(draft.plotTerrains && draft.plotResults && draft.terrainRequiresElevationResult)
        #expect(draft.legendWidthThreshold == 400 && draft.legendHeightThreshold == 300)

        let callerConfigured = MapDynamicProfileWindowPresentation(title: "Map Profile Plot",
            mode: .results, axisUnits: "ft", showResultMapTypeSelector: false,
            legendWidthThreshold: 620, legendHeightThreshold: 410)
        #expect(callerConfigured.title == "Map Profile Plot" && callerConfigured.axisUnits == "ft")
        #expect(!callerConfigured.showsResultMapTypeSelector)
        #expect(callerConfigured.legendWidthThreshold == 620 && callerConfigured.legendHeightThreshold == 410)
    }

    @Test func topologyArcCallersKeepTheirDistinctTerrainAndResultFlags() {
        let terrain = MapDynamicProfileWindowPresentation.topologyArcs(title: "Arc Profile", mode: .terrain)
        #expect(terrain.plotTerrains && !terrain.plotResults)
        #expect(!terrain.terrainRequiresElevationResult && terrain.showsResultMapTypeSelector)
        let results = MapDynamicProfileWindowPresentation.topologyArcs(title: "Arc Profile", mode: .results)
        #expect(!results.plotTerrains && results.plotResults)
        #expect(!results.terrainRequiresElevationResult && results.showsResultMapTypeSelector)
        #expect(terrain.targetSampleCount == 256 && results.targetSampleCount == 256)
    }

    @Test @MainActor func mapInvalidationRetiresOnlyItsWindowAndCancelsItsPendingSample() async throws {
        let store = WorkspaceStore()
        let firstMapID = UUID(), secondMapID = UUID()
        let firstState = store.mapState(for: firstMapID)
        let secondState = store.mapState(for: secondMapID)
        let firstCapture = try Self.context(mapID: firstMapID, lineID: "feature:1")
        let secondCapture = try Self.context(mapID: secondMapID, lineID: "feature:2")
        let firstProvider = WindowControlledDynamicProfileProvider()
        let firstSampler = MapDynamicProfileSession(provider: firstProvider)
        let firstWindow = Self.window(mapState: firstState, context: firstCapture,
            sampler: firstSampler)
        let secondWindow = Self.window(mapState: secondState, context: secondCapture,
            sampler: MapDynamicProfileSession(provider: WindowControlledDynamicProfileProvider()))
        let firstID = store.registerMapDynamicProfileWindow(firstWindow)
        let secondID = store.registerMapDynamicProfileWindow(secondWindow)

        let request = Self.request(context: firstCapture, line: firstWindow.line)
        let loading = Task { await firstSampler.load(request, isCurrent: { firstWindow.isValid }) }
        for _ in 0..<200 where firstProvider.pendingCount == 0 { await Task.yield() }
        #expect(firstProvider.pendingCount == 1)

        firstState.dynamicProfileOverlay.install(owner: firstWindow.overlayOwner,
            lines: [firstWindow.line])
        firstState.dynamicProfileOverlay.move(owner: firstWindow.overlayOwner, distance: 2)
        #expect(firstState.dynamicProfileOverlay.markers.count == 1)

        store.invalidateMapDynamicProfiles(mapID: firstMapID, reason: "The source changed.")
        #expect(!firstWindow.isValid)
        #expect(secondWindow.isValid)
        #expect(firstState.dynamicProfileOverlay.markers.isEmpty)

        firstProvider.complete(try Self.response(request))
        await loading.value
        #expect(firstSampler.snapshot == nil && firstSampler.acceptedRequestIdentity == nil)
        store.unregisterMapDynamicProfileWindow(firstID)
        #expect(store.mapDynamicProfileWindows[secondID] === secondWindow)
        store.unregisterMapDynamicProfileWindow(secondID)
        #expect(store.mapDynamicProfileWindows.isEmpty)
    }

    @Test @MainActor func windowReuseKeepsTheSameLiveMapLineAcrossSourceRefreshes() throws {
        let store = WorkspaceStore()
        let mapID = UUID()
        let state = store.mapState(for: mapID)
        let context = try Self.context(mapID: mapID, lineID: "feature:1")
        let window = Self.window(mapState: state, context: context,
            sampler: MapDynamicProfileSession(provider: WindowControlledDynamicProfileProvider()))
        #expect(window.matches(projectSessionID: context.projectSessionID, mapID: mapID,
            context: context, mode: .terrain, editingSelection: false))
        #expect(!window.matches(projectSessionID: context.projectSessionID, mapID: mapID,
            context: context, mode: .results, editingSelection: false))
        #expect(!window.matches(projectSessionID: context.projectSessionID, mapID: mapID,
            context: context, mode: .terrain, editingSelection: true))

        let changedSources = Self.replacementSnapshot(window.sources,
            contextToken: "refreshed-context-token")
        #expect(window.matches(projectSessionID: context.projectSessionID, mapID: mapID,
            context: context, mode: .terrain, editingSelection: false))
        #expect(changedSources != window.sources)

        window.invalidate()
        #expect(!window.matches(projectSessionID: context.projectSessionID, mapID: mapID,
            context: context, mode: .terrain, editingSelection: false))
    }

    @Test @MainActor func sameMapSourceRebindKeepsWindowAndRejectsCancelledOldSamples() async throws {
        let mapID = UUID()
        let state = WorkspaceStore().mapState(for: mapID)
        let context = try Self.context(mapID: mapID, lineID: "feature:1")
        let provider = WindowControlledDynamicProfileProvider()
        let sampler = MapDynamicProfileSession(provider: provider)
        let window = Self.window(mapState: state, context: context, sampler: sampler)
        let oldRequest = Self.request(context: context, line: window.line)
        let loading = Task { await sampler.load(oldRequest, isCurrent: { window.isValid }) }
        for _ in 0..<200 where provider.pendingCount == 0 { await Task.yield() }
        #expect(provider.pendingCount == 1)

        let generation = window.beginSourceRebind()
        #expect(window.isRebindingSources)
        #expect(sampler.snapshot == nil && sampler.acceptedRequestIdentity == nil)
        provider.complete(try Self.response(oldRequest))
        await loading.value
        #expect(sampler.snapshot == nil && sampler.acceptedRequestIdentity == nil)

        let updatedSources = Self.replacementSnapshot(window.sources, contextToken: "new-context-token")
        #expect(window.rebindSourceContext(projectSessionID: context.projectSessionID,
            mapID: mapID, context: context, sources: updatedSources,
            sourceWorkflowIdentity: "new-source-workflow", mapWorkflowIdentity: updatedSources.identity))
        #expect(window.isValid && !window.isRebindingSources)
        #expect(window.context == context && window.line.id == context.stableFeatureIdentity)
        #expect(window.sources.sources.contextToken == "new-context-token")
        #expect(window.sourceWorkflowIdentity == "new-source-workflow")
        #expect(window.isCurrentSourceRebind(generation) == false)

        let reboundRequest = Self.request(context: context, line: window.line,
            contextToken: updatedSources.sources.contextToken)
        let reboundLoading = Task {
            await sampler.load(reboundRequest, expectedProjectRevision: updatedSources.sources.projectRevision,
                isCurrent: { window.isValid && !window.isRebindingSources })
        }
        for _ in 0..<200 where provider.pendingCount == 0 { await Task.yield() }
        #expect(provider.pendingCount == 1)
        provider.complete(try Self.response(reboundRequest))
        await reboundLoading.value
        #expect(sampler.snapshot != nil && sampler.acceptedRequestIdentity == reboundRequest.identity)
    }

    @Test @MainActor func unrelatedProjectMapOrLineChangeRetiresARebindingWindow() throws {
        let mapID = UUID()
        let state = WorkspaceStore().mapState(for: mapID)
        let original = try Self.context(mapID: mapID, lineID: "feature:1")
        let otherMap = UUID()

        let projectChanged = Self.window(mapState: state, context: original,
            sampler: MapDynamicProfileSession(provider: WindowControlledDynamicProfileProvider()))
        _ = projectChanged.beginSourceRebind()
        #expect(!projectChanged.rebindSourceContext(projectSessionID: UUID(), mapID: mapID,
            context: original, sources: projectChanged.sources,
            sourceWorkflowIdentity: "source", mapWorkflowIdentity: projectChanged.sources.identity))
        #expect(!projectChanged.isValid)

        let mapChanged = Self.window(mapState: state, context: original,
            sampler: MapDynamicProfileSession(provider: WindowControlledDynamicProfileProvider()))
        _ = mapChanged.beginSourceRebind()
        #expect(!mapChanged.rebindSourceContext(projectSessionID: original.projectSessionID,
            mapID: otherMap, context: original, sources: mapChanged.sources,
            sourceWorkflowIdentity: "source", mapWorkflowIdentity: mapChanged.sources.identity))
        #expect(!mapChanged.isValid)

        let lineChanged = Self.window(mapState: state, context: original,
            sampler: MapDynamicProfileSession(provider: WindowControlledDynamicProfileProvider()))
        _ = lineChanged.beginSourceRebind()
        let changedContext = try Self.context(mapID: mapID, lineID: "feature:2")
        #expect(!lineChanged.rebindSourceContext(projectSessionID: original.projectSessionID,
            mapID: mapID, context: changedContext, sources: lineChanged.sources,
            sourceWorkflowIdentity: "source", mapWorkflowIdentity: lineChanged.sources.identity))
        #expect(!lineChanged.isValid)

        let projectPathChanged = Self.window(mapState: state, context: original,
            sampler: MapDynamicProfileSession(provider: WindowControlledDynamicProfileProvider()))
        _ = projectPathChanged.beginSourceRebind()
        let changedProjectPath = try Self.updatedContext(original,
            projectPath: "/tmp/another-project-\(mapID.uuidString).ras")
        let changedProjectSources = Self.replacementSnapshot(projectPathChanged.sources,
            contextToken: "different-project-context", context: changedProjectPath,
            mapWorkflowIdentity: "different-project-workflow")
        #expect(!projectPathChanged.rebindSourceContext(projectSessionID: original.projectSessionID,
            mapID: mapID, context: changedProjectPath, sources: changedProjectSources,
            sourceWorkflowIdentity: "source", mapWorkflowIdentity: changedProjectSources.identity))
        #expect(!projectPathChanged.isValid)
    }

    @Test @MainActor func visualizationAndProjectXMLUpdatesRebindWhenTheExactMapLineIsStable() throws {
        let mapID = UUID()
        let state = WorkspaceStore().mapState(for: mapID)
        let original = try Self.context(mapID: mapID, lineID: "feature:1")
        let window = Self.window(mapState: state, context: original,
            sampler: MapDynamicProfileSession(provider: WindowControlledDynamicProfileProvider()))

        _ = window.beginSourceRebind()
        let visualizationChanged = try Self.updatedContext(original,
            mapIndex: 3, mapName: "Renamed Map", mapType: "Plan",
            visualizationRevision: "vis-revision-2")
        let visualizationSources = Self.replacementSnapshot(window.sources,
            contextToken: "vis-context", context: visualizationChanged,
            mapWorkflowIdentity: "map-workflow-vis-2")
        #expect(window.rebindSourceContext(projectSessionID: original.projectSessionID,
            mapID: mapID, context: visualizationChanged, sources: visualizationSources,
            sourceWorkflowIdentity: "source-workflow-vis-2",
            mapWorkflowIdentity: visualizationSources.identity))
        #expect(window.isValid && window.context.visualizationRevision == "vis-revision-2")
        #expect(window.context.mapIndex == 3 && window.context.mapName == "Renamed Map")

        _ = window.beginSourceRebind()
        let projectXMLChanged = try Self.updatedContext(visualizationChanged,
            projectXML: "<Ras><Updated /></Ras>")
        let projectXMLSources = Self.replacementSnapshot(window.sources,
            contextToken: "project-xml-context", context: projectXMLChanged,
            mapWorkflowIdentity: "map-workflow-project-xml-3")
        #expect(window.rebindSourceContext(projectSessionID: original.projectSessionID,
            mapID: mapID, context: projectXMLChanged, sources: projectXMLSources,
            sourceWorkflowIdentity: "source-workflow-project-xml-3",
            mapWorkflowIdentity: projectXMLSources.identity))
        #expect(window.isValid && window.context.projectXML == "<Ras><Updated /></Ras>")
        #expect(window.matchesStableMapLine(projectSessionID: original.projectSessionID,
            mapID: mapID, context: original, editingSelection: false))
    }

    @Test @MainActor func sourceVectorCoordinateOrDraftChangesRetireTheWindow() throws {
        let mapID = UUID()
        let state = WorkspaceStore().mapState(for: mapID)
        let original = try Self.context(mapID: mapID, lineID: "feature:1")
        let changedCoordinates = try Self.updatedContext(original,
            coordinates: [.init(x: 0, y: 0), .init(x: 11, y: 0)])
        let changedVectorRevision = try Self.updatedContext(original, vectorRevision: "vector-sha-2")
        let changedVectorPath = try Self.updatedContext(original,
            vectorPath: "/tmp/another-vector-\(mapID.uuidString).geojson")
        let changedDraft = try Self.updatedContext(original, draftGeneration: "draft:2")

        for changed in [changedCoordinates, changedVectorRevision, changedVectorPath, changedDraft] {
            let window = Self.window(mapState: state, context: original,
                sampler: MapDynamicProfileSession(provider: WindowControlledDynamicProfileProvider()))
            _ = window.beginSourceRebind()
            #expect(!window.rebindSourceContext(projectSessionID: original.projectSessionID,
                mapID: mapID, context: changed,
                sources: Self.replacementSnapshot(window.sources, contextToken: "changed-source",
                    context: changed, mapWorkflowIdentity: "changed-map-workflow"),
                sourceWorkflowIdentity: "changed-source-workflow",
                mapWorkflowIdentity: "changed-map-workflow"))
            #expect(!window.isValid)
        }
    }

    private static func context(mapID: UUID, lineID: String) throws -> MapResultChartContext {
        let projectPath = "/tmp/dynamic-profile-window-\(mapID.uuidString).ras"
        let projectXML = "<Ras />"
        let capture = try MapResultChartLineCapture(projectSessionID: UUID(), mapID: mapID,
            projectPath: URL(fileURLWithPath: projectPath), projectXML: projectXML,
            mapIndex: 0, mapName: "Window Test", mapType: "Project", visualizationRevision: "vis-sha",
            layerID: "/tmp/window-line.geojson", vectorPath: URL(fileURLWithPath: "/tmp/window-line.geojson"),
            vectorRevision: "vector-sha", stableFeatureIdentity: lineID,
            coordinates: [.init(x: 0, y: 0), .init(x: 10, y: 0)], draftGeneration: "disk:vector-sha")
        return MapResultChartContext(capture: capture)
    }

    @MainActor private static func window(mapState: MapState, context: MapResultChartContext,
                                          sampler: MapDynamicProfileSession) -> MapDynamicProfileWindowSession {
        let sources = MapResultChartSources(projectPath: context.projectPath,
            projectRevision: "project-sha", mapID: context.mapRequest.mapID,
            mapIndex: context.mapIndex, mapName: context.mapName, mapType: context.mapType,
            projectXmlSHA: context.projectXMLSHA, visualizationRevision: context.visualizationRevision,
            contextToken: "source-context", activeNodes: [])
        let snapshot = MapResultSourcesSnapshot(map: context.mapRequest,
            identity: "map-workflow", sources: sources, selectionOverrides: [])
        return MapDynamicProfileWindowSession(mapState: mapState,
            projectSessionID: context.projectSessionID, context: context, sources: snapshot,
            sourceWorkflowIdentity: "source-workflow", mapWorkflowIdentity: snapshot.identity,
            editingSelection: false,
            presentation: .init(title: "Window Test Profile Plot", mode: .terrain), sampler: sampler)
    }

    private static func replacementSnapshot(_ old: MapResultSourcesSnapshot,
                                            contextToken: String,
                                            context: MapResultChartContext? = nil,
                                            mapWorkflowIdentity: String? = nil) -> MapResultSourcesSnapshot {
        let previous = old.sources
        let map = context?.mapRequest ?? old.map
        let identity = mapWorkflowIdentity ?? old.identity
        let sources = MapResultChartSources(projectPath: map.projectPath,
            projectRevision: previous.projectRevision, mapID: previous.mapID,
            mapIndex: map.mapIndex, mapName: map.mapName,
            mapType: map.mapType, projectXmlSHA: map.projectXmlSHA,
            visualizationRevision: map.expectedVisualizationRevision,
            contextToken: contextToken, activeNodes: previous.activeNodes)
        return MapResultSourcesSnapshot(map: map, identity: identity,
            sources: sources, selectionOverrides: old.selectionOverrides)
    }

    private static func updatedContext(_ old: MapResultChartContext,
                                       projectPath: String? = nil,
                                       projectXML: String? = nil,
                                       mapIndex: Int? = nil,
                                       mapName: String? = nil,
                                       mapType: String? = nil,
                                       visualizationRevision: String? = nil,
                                       vectorPath: String? = nil,
                                       vectorRevision: String? = nil,
                                       coordinates: [GeometryTopologyCoordinate]? = nil,
                                       draftGeneration: String? = nil) throws -> MapResultChartContext {
        let capture = old.capture
        return MapResultChartContext(capture: try MapResultChartLineCapture(
            projectSessionID: capture.projectSessionID, mapID: capture.mapID,
            projectPath: URL(fileURLWithPath: projectPath ?? capture.projectPath),
            projectXML: projectXML ?? capture.projectXML,
            mapIndex: mapIndex ?? capture.mapIndex, mapName: mapName ?? capture.mapName,
            mapType: mapType ?? capture.mapType,
            visualizationRevision: visualizationRevision ?? capture.visualizationRevision,
            layerID: vectorPath ?? capture.layerID,
            vectorPath: URL(fileURLWithPath: vectorPath ?? capture.vectorPath),
            vectorRevision: vectorRevision ?? capture.vectorRevision,
            stableFeatureIdentity: capture.stableFeatureIdentity,
            coordinates: coordinates ?? capture.coordinates,
            draftGeneration: draftGeneration ?? capture.draftGeneration))
    }

    private static func request(context: MapResultChartContext,
                                line: MapDynamicProfileLine,
                                contextToken: String = "source-context") -> MapDynamicProfileRequest {
        MapDynamicProfileRequest(map: context.mapRequest, contextToken: contextToken,
            selectionOverrides: [], lines: [line],
            linesToken: GeometryDynamicProfileLines.token(lines: [line], sourceIdentity: context.identity),
            targetSampleCount: 256, plotTerrains: true, plotResults: true,
            terrainRequiresElevationResult: true, mapType: "WaterSurfaceElevation", profileSelections: [])
    }

    private static func response(_ request: MapDynamicProfileRequest) throws -> MapDynamicProfileResult {
        let points = request.lines[0].points.map { ["x": $0.x, "y": $0.y] }
        let json: [String: Any] = ["projectPath": request.map.projectPath, "projectRevision": "project-sha",
            "projectXmlSHA": request.map.projectXmlSHA, "visualizationRevision": request.map.expectedVisualizationRevision,
            "mapID": request.map.mapID, "mapIndex": request.map.mapIndex, "mapName": request.map.mapName,
            "mapType": request.map.mapType, "contextToken": request.contextToken,
            "linesToken": request.linesToken, "targetSampleCount": request.targetSampleCount,
            "distanceUnits": "ft", "lines": [["id": request.lines[0].id,
                "points": points, "samplePoints": points, "distances": [0.0, 10.0], "series": []]]]
        return try JSONDecoder().decode(MapDynamicProfileResult.self, from: JSONSerialization.data(withJSONObject: json))
    }
}

@MainActor private final class WindowControlledDynamicProfileProvider: MapDynamicProfileProviding {
    private var pending: [CheckedContinuation<MapDynamicProfileResult, any Error>] = []
    var pendingCount: Int { pending.count }

    func sample(_ request: MapDynamicProfileRequest) async throws -> MapDynamicProfileResult {
        try await withCheckedThrowingContinuation { pending.append($0) }
    }

    func complete(_ result: MapDynamicProfileResult) {
        pending.removeFirst().resume(returning: result)
    }
}
