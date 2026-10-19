import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

struct BackendDynamicProfileWindowWorkflowTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HECRAS_DYNAMIC_PROFILE_ACCEPTANCE_DIRECTORY"] != nil
        && ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"] != nil))
    @MainActor
    func savedMapProfileWindowRebindsAcrossInactiveMapVisibilityAndProjectDraftChanges() async throws {
        let environment = ProcessInfo.processInfo.environment
        let fixtureURL = URL(fileURLWithPath: try #require(environment["HECRAS_DYNAMIC_PROFILE_ACCEPTANCE_DIRECTORY"]))
        let backendURL = URL(fileURLWithPath: try #require(environment["HECRAS_BACKEND_TEST_EXECUTABLE"]))
        try #require(FileManager.default.isExecutableFile(atPath: backendURL.path))

        let originalBytes = try DynamicProfileWindowFileSnapshot(root: fixtureURL)
        let workingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("dynamic-profile-window-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.copyItem(at: fixtureURL, to: workingRoot)
        defer { try? FileManager.default.removeItem(at: workingRoot) }
        #expect(try DynamicProfileWindowFileSnapshot(root: workingRoot).files == originalBytes.files)

        let manifest = try JSONDecoder().decode(DynamicProfileWindowFixture.self,
            from: Data(contentsOf: workingRoot.appendingPathComponent("DYNAMIC_PROFILE_FIXTURE.json")))
        let projectURL = workingRoot.appendingPathComponent(manifest.project)
        let visualizationURL = workingRoot.appendingPathComponent(manifest.visualization)
        let resultURL = workingRoot.appendingPathComponent(try #require(manifest.results.first))
        let terrainURL = workingRoot.appendingPathComponent(try #require(manifest.terrains.first))
        let vectorSource = try #require(manifest.vectorSources.first { $0.mapType == "PolylinesVector" })
        let vectorURL = workingRoot.appendingPathComponent(vectorSource.path)

        let client = BackendProcessClient(executableURL: backendURL)
        let store = WorkspaceStore(
            system: SourceWorkflowFixtureServices(recoveryFolder: workingRoot.appendingPathComponent("Recovery")),
            modelProvider: BackendModelProvider(client: client))
        store.requestOpen(projectURL)
        try await dynamicProfileWindowWaitUntil("project open") {
            store.document?.url?.standardizedFileURL == projectURL.standardizedFileURL
                && !store.isOpeningProject
        }
        #expect(store.errorMessage == nil)

        await store.reloadMapLayersAndWait()
        let mapDocument = try #require(store.catalogMapDocuments.first {
            $0.sourceIndex == manifest.map.index
        })
        let mapID = try #require(UUID(uuidString: mapDocument.id))
        #expect(mapDocument.name == manifest.map.name)
        #expect(mapDocument.kind == manifest.map.type)
        await store.configureMapResultSources(mapID)

        let mapState = store.mapState(for: mapID)
        func canonicalAssetPath(_ node: LayerTreeNode) -> String? {
            guard let assetID = node.assetID, let directory = store.document?.directory else { return nil }
            return try? SourceFilePaths.canonical(PlatformPaths.resolve(assetID,
                relativeTo: directory, mappings: store.pathMappings))
        }
        var sourceNodes = try await store.sourceMapLayerNodes(mapID)
        let vectorNode = try #require(sourceNodes.first { node in
            node.sourceLocator?.nodeType == "MapLayer"
                && node.sourceLocator?.mapType == "PolylinesVector"
                && store.sourceMapVectorURL(node).map(SourceFilePaths.canonical)
                    == SourceFilePaths.canonical(vectorURL)
        })
        let vectorInstanceID = store.sourceVectorInstanceID(vectorNode, mapID: mapID)
        let vectorLayer = try #require(mapState.visibleVectors(store.mapLayers).first {
            $0.id == vectorInstanceID && SourceFilePaths.canonical($0.url) == SourceFilePaths.canonical(vectorURL)
        })
        let usableLineFeatures = vectorLayer.features.filter { feature in
            feature.kind == .line && feature.hasUniqueStableIdentity
                && feature.paths.count == 1 && feature.paths[0].count >= 2
                && feature.pathStableIdentities.count == 1
                && feature.paths[0].allSatisfy { $0.x.isFinite && $0.y.isFinite }
                && zip(feature.paths[0], feature.paths[0].dropFirst()).contains { $0 != $1 }
        }
        #expect(usableLineFeatures.count == 1)
        let lineFeature = try #require(usableLineFeatures.first)
        let lineIdentity = try #require(lineFeature.pathStableIdentities.first)
        mapState.selectedLayerID = vectorLayer.id
        mapState.selectedLineIdentity = lineIdentity
        let selectedLineContext = try store.mapLineContext(mapID: mapID)
        #expect(selectedLineContext.layerID == vectorLayer.id)
        #expect(selectedLineContext.stableFeatureIdentity == lineIdentity)
        #expect(SourceFilePaths.canonical(URL(fileURLWithPath: selectedLineContext.vectorPath))
            == SourceFilePaths.canonical(vectorURL))

        let terrainPath = SourceFilePaths.canonical(terrainURL)
        var terrainNodes = sourceNodes.filter { node in
            node.sourceLocator?.nodeType == "Terrain"
                && node.sourceLocator?.rootName == "Terrains"
                && canonicalAssetPath(node) == terrainPath
        }
        #expect(terrainNodes.count == 1)
        var terrainNode = try #require(terrainNodes.first)
        if terrainNode.checked != .checked {
            #expect(await store.setSourceMapVisibility(terrainNode, checked: true, mapID: mapID))
            await store.configureMapResultSources(mapID)
            sourceNodes = try await store.sourceMapLayerNodes(mapID)
            terrainNodes = sourceNodes.filter { node in
                node.sourceLocator?.nodeType == "Terrain"
                && node.sourceLocator?.rootName == "Terrains"
                    && canonicalAssetPath(node) == terrainPath
            }
            terrainNode = try #require(terrainNodes.first)
        }
        #expect(terrainNode.checked == .checked)

        let firstRoute = try #require(store.openMapDynamicProfileWindow(mapID: mapID, mode: .results))
        let windowID = try #require(firstRoute.dynamicProfile?.sessionID)
        let windowSession = try #require(store.mapDynamicProfileWindows[windowID])
        #expect(windowSession.mapID == mapID && windowSession.isValid)
        let duplicateRoute = try #require(store.openMapDynamicProfileWindow(mapID: mapID, mode: .results))
        #expect(duplicateRoute.dynamicProfile?.sessionID == windowID)
        #expect(store.mapDynamicProfileWindows.count == 1)

        func currentRequest() throws -> MapDynamicProfileRequest {
            let boundSources = windowSession.sources
            let resultNode = try #require(boundSources.sources.activeNodes.first {
                $0.nodeKind == "Result" && $0.selections.contains { slot in
                    slot.selectedResult.map {
                        SourceFilePaths.canonical(URL(fileURLWithPath: $0.resultPath))
                            == SourceFilePaths.canonical(resultURL)
                    } ?? false
                }
            })
            let selectedResult = try #require(resultNode.selections.first(where: { $0.selectionIndex == 0 })?.selectedResult)
            #expect(SourceFilePaths.canonical(URL(fileURLWithPath: selectedResult.resultPath))
                == SourceFilePaths.canonical(resultURL))
            let runtimeNode = mapState.resultMap.nodes.first { $0.id == resultNode.id }
            let profileIndex = try #require(runtimeNode?.profileIndex ?? resultNode.profileIndex)
            let selectedMapType = runtimeNode?.selectedMapType ?? resultNode.selectedMapType
                ?? windowSession.presentation.initialMapType
            return MapDynamicProfileRequest(map: boundSources.map,
                contextToken: boundSources.sources.contextToken,
                selectionOverrides: boundSources.selectionOverrides,
                lines: [windowSession.line], linesToken: windowSession.linesToken,
                targetSampleCount: windowSession.presentation.targetSampleCount,
                plotTerrains: true, plotResults: true,
                // This is the real Results-profile toggle state that permits a
                // Terrain overlay with non-elevation Result map types.
                terrainRequiresElevationResult: false,
                mapType: selectedMapType,
                profileSelections: [.init(node: resultNode.node, profileIndex: profileIndex)])
        }

        func sampleCurrentWindow() async throws -> (MapDynamicProfileRequest, MapDynamicProfileResult) {
            let request = try currentRequest()
            let boundSources = windowSession.sources
            await windowSession.sampler.load(request,
                expectedProjectRevision: boundSources.sources.projectRevision,
                isCurrent: {
                    windowSession.isValid
                        && !windowSession.isRebindingSources
                        && store.mapDynamicProfileWindows[windowID] === windowSession
                        && windowSession.sources == boundSources
                        && store.isCurrentMapDynamicProfileWindow(windowSession, state: mapState)
                })
            let result = try #require(windowSession.sampler.snapshot)
            #expect(windowSession.sampler.acceptedRequestIdentity == request.identity)
            return (request, result)
        }

        let (_, initialProfile) = try await sampleCurrentWindow()
        let initialLine = try #require(initialProfile.lines.first { $0.id == windowSession.line.id })
        let initialTerrain = try #require(initialLine.series.first { $0.sourceKind == "Terrain" })
        let initialResult = try #require(initialLine.series.first { $0.sourceKind == "Result" })
        #expect(SourceFilePaths.canonical(URL(fileURLWithPath: initialTerrain.sourcePath)) == terrainPath)
        #expect(SourceFilePaths.canonical(URL(fileURLWithPath: initialResult.sourcePath))
            == SourceFilePaths.canonical(resultURL))
        #expect(initialProfile.distanceUnits == manifest.distanceUnits)
        #expect(initialProfile.distanceUnits == "ft")
        #expect(initialLine.distances.count == initialLine.samplePoints.count)
        #expect(initialLine.distances.first == 0)
        #expect((initialLine.distances.last ?? 0) > 0)
        #expect(zip(initialLine.distances, initialLine.distances.dropFirst()).allSatisfy { $0 <= $1 })

        // Create a second persisted map through the real Store route only after
        // the Map 1 window is registered, then leave Map 2 active while editing
        // Map 1. This exercises the detached owner rather than active-map UI state.
        #expect(await store.createMapDocument(kind: .project))
        let otherMap = try #require(store.catalogMapDocuments.first {
            $0.sourceIndex != manifest.map.index && $0.id != mapDocument.id && $0.kind == "Project"
        })
        let otherMapID = try #require(UUID(uuidString: otherMap.id))
        #expect(store.lastActiveMapID == otherMapID)
        #expect(otherMapID != mapID)
        await store.configureMapResultSources(mapID)
        store.rebindMapDynamicProfileSources(mapID: mapID)
        try await dynamicProfileWindowWaitUntil("Map 1 window rebound after Map 2 creation") {
            Self.isCurrentBinding(windowSession, mapID: mapID, store: store, state: mapState)
        }
        #expect(store.lastActiveMapID == otherMapID)

        sourceNodes = try await store.sourceMapLayerNodes(mapID)
        terrainNodes = sourceNodes.filter { node in
            node.sourceLocator?.nodeType == "Terrain"
                && node.sourceLocator?.rootName == "Terrains"
                && canonicalAssetPath(node) == terrainPath
        }
        terrainNode = try #require(terrainNodes.first)
        #expect(terrainNode.checked == .checked)
        let oldWindowID = windowSession.id
        let oldVisualizationRevision = try Data(contentsOf: visualizationURL)
        let oldRevisionText = MapDynamicProfileRequest.digest(oldVisualizationRevision)
        #expect(await store.setSourceMapVisibility(terrainNode, checked: false, mapID: mapID))
        await store.configureMapResultSources(mapID)
        try await dynamicProfileWindowWaitUntil("inactive Map 1 source revision rebound") {
            Self.isCurrentBinding(windowSession, mapID: mapID, store: store, state: mapState)
                && windowSession.sources.map.expectedVisualizationRevision.caseInsensitiveCompare(oldRevisionText) != .orderedSame
        }
        #expect(store.lastActiveMapID == otherMapID)
        #expect(store.mapDynamicProfileWindows[oldWindowID] === windowSession)
        #expect(windowSession.isValid && !windowSession.isRebindingSources)
        #expect(windowSession.sources.map.expectedVisualizationRevision.caseInsensitiveCompare(
            MapDynamicProfileRequest.digest(try Data(contentsOf: visualizationURL))) == .orderedSame)

        let (_, terrainHiddenProfile) = try await sampleCurrentWindow()
        let hiddenLine = try #require(terrainHiddenProfile.lines.first { $0.id == windowSession.line.id })
        let retainedResult = try #require(hiddenLine.series.first { $0.sourceKind == "Result" })
        #expect(hiddenLine.series.allSatisfy { $0.sourceKind != "Terrain" })
        #expect(SourceFilePaths.canonical(URL(fileURLWithPath: retainedResult.sourcePath))
            == SourceFilePaths.canonical(resultURL))
        #expect(retainedResult.sourceRevision == initialResult.sourceRevision)
        #expect(terrainHiddenProfile.distanceUnits == manifest.distanceUnits)

        // Workspace's mounted `.task(id: baseIdentity)` is not part of a
        // headless test, so drive the same existing Store rebind/configuration
        // entry points after changing only the in-memory description draft.
        let oldProjectXMLSHA = windowSession.sources.map.projectXmlSHA
        store.descriptionDraft += " Dynamic profile window integration draft"
        store.rebindMapDynamicProfileSources(mapID: mapID)
        await store.configureMapResultSources(mapID)
        try await dynamicProfileWindowWaitUntil("description-draft Project XML rebound") {
            Self.isCurrentBinding(windowSession, mapID: mapID, store: store, state: mapState)
                && windowSession.sources.map.projectXmlSHA != oldProjectXMLSHA
        }
        #expect(windowSession.sources.map.projectXmlSHA
            == MapDynamicProfileRequest.digest(Data(windowSession.sources.map.projectXml.utf8)))
        #expect(store.lastActiveMapID == otherMapID)
        let (_, draftProfile) = try await sampleCurrentWindow()
        #expect(draftProfile.projectXmlSHA == windowSession.sources.map.projectXmlSHA)
        #expect(draftProfile.lines.first?.series.contains { $0.sourceKind == "Result" } == true)
        #expect(draftProfile.lines.first?.series.contains { $0.sourceKind == "Terrain" } == false)

        let sampledLine = try #require(draftProfile.lines.first { $0.id == windowSession.line.id })
        let overlayLine = MapDynamicProfileLine(id: sampledLine.id, points: sampledLine.samplePoints)
        mapState.dynamicProfileOverlay.install(owner: windowSession.overlayOwner,
            lines: [overlayLine], distancesByID: [sampledLine.id: sampledLine.distances])
        mapState.dynamicProfileOverlay.move(owner: windowSession.overlayOwner,
            distance: (sampledLine.distances.last ?? 0) / 2)
        #expect(mapState.dynamicProfileOverlay.markers.first?.id == sampledLine.id)
        store.unregisterMapDynamicProfileWindow(windowID)
        #expect(store.mapDynamicProfileWindows[windowID] == nil)
        #expect(!windowSession.isValid)
        #expect(mapState.dynamicProfileOverlay.markers.isEmpty)

        let projectLockURL = projectURL.deletingLastPathComponent().appendingPathComponent(".lock")
        #expect(FileManager.default.fileExists(atPath: projectLockURL.path))
        store.requestClose()
        if store.showDiscardConfirmation { store.discardAndContinue() }
        try #require(store.document == nil)
        #expect(!FileManager.default.fileExists(atPath: projectLockURL.path))

        let finalCopyBytes = try DynamicProfileWindowFileSnapshot(root: workingRoot)
        let changedCopyFiles = Set(finalCopyBytes.files.compactMap { path, bytes in
            originalBytes.files[path] == bytes ? nil : path
        })
        #expect(Set(finalCopyBytes.files.keys) == Set(originalBytes.files.keys))
        #expect(changedCopyFiles == [manifest.visualization])
        #expect(try DynamicProfileWindowFileSnapshot(root: fixtureURL).files == originalBytes.files)
    }

    @MainActor
    private static func isCurrentBinding(_ session: MapDynamicProfileWindowSession,
                                         mapID: UUID, store: WorkspaceStore,
                                         state: MapState) -> Bool {
        guard session.isValid, !session.isRebindingSources,
              let currentMap = store.mapResultRequest(for: mapID),
              let snapshot = state.resultSources.snapshot else { return false }
        return session.sources.map == currentMap
            && session.sources.identity == store.mapWorkflowIdentity(mapID)
            && snapshot == session.sources
            && store.isCurrentMapDynamicProfileWindow(session, state: state)
    }
}

private struct DynamicProfileWindowFixture: Decodable {
    let project: String
    let visualization: String
    let results: [String]
    let terrains: [String]
    let vectorSources: [VectorSource]
    let distanceUnits: String
    let map: SourceMap
    let selectedResult: SelectedResult

    struct VectorSource: Decodable {
        let path: String
        let mapType: String
    }

    struct SourceMap: Decodable {
        let index: Int
        let name: String
        let type: String
    }

    struct SelectedResult: Decodable {
        let locator: CatalogTreeNodeLocator
    }
}

private struct DynamicProfileWindowFileSnapshot {
    let files: [String: Data]

    init(root: URL) throws {
        let prefix = SourceFilePaths.canonical(root) + "/"
        let enumerator = try #require(FileManager.default.enumerator(at: root,
            includingPropertiesForKeys: [.isRegularFileKey]))
        var captured: [String: Data] = [:]
        for case let url as URL in enumerator {
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            let path = SourceFilePaths.canonical(url)
            guard path.hasPrefix(prefix) else { throw CocoaError(.fileReadInvalidFileName) }
            captured[String(path.dropFirst(prefix.count))] = try Data(contentsOf: url)
        }
        files = captured
    }
}

@MainActor
private func dynamicProfileWindowWaitUntil(_ label: String, timeout: Duration = .seconds(45),
                                           condition: @MainActor () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(50))
    }
    #expect(condition(), "Timed out waiting for \(label).")
}
