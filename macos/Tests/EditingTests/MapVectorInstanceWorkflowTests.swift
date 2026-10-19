import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

struct MapVectorInstanceWorkflowTests {
    @Test @MainActor
    func visualNodeIdentityEditsCanonicalFileAndOverlaysEveryMatchingInstance() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("map-vector-instance-workflow-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let sourceURL = folder.appendingPathComponent("mixed.geojson")
        let sourceBytes = Data(#"{"type":"FeatureCollection","features":[{"type":"Feature","id":"point","properties":{"kind":"point"},"geometry":{"type":"Point","coordinates":[0,0]}},{"type":"Feature","id":"line-a","properties":{"kind":"first line","keep":7},"geometry":{"type":"LineString","coordinates":[[1,1],[2,2],[3,1]]}},{"type":"Feature","id":"area","properties":{"kind":"polygon"},"geometry":{"type":"Polygon","coordinates":[[[10,10],[12,10],[12,12],[10,10]]]}},{"type":"Feature","id":"line-b","properties":{"kind":"second line"},"geometry":{"type":"LineString","coordinates":[[20,20],[21,21],[22,20]]}}]}"#.utf8)
        try sourceBytes.write(to: sourceURL)

        let sourceLayer = try MapVectorLayer(contentsOf: sourceURL)
        let state = MapState(id: UUID())
        let sourcePath = SourceFilePaths.canonical(sourceURL)
        let firstLineNodeID = "source-vector/\(state.id.uuidString)/vis-map-0-tree-0.1"
        let secondLineNodeID = "source-vector/\(state.id.uuidString)/vis-map-0-tree-0.2"
        state.sourceVectorBindings = [
            .init(id: firstLineNodeID, sourcePath: sourcePath, name: "First line node", kind: .line, isVisible: true),
            .init(id: secondLineNodeID, sourcePath: sourcePath, name: "Second line node", kind: .line, isVisible: true),
            .init(id: "source-vector/\(state.id.uuidString)/vis-map-0-tree-0.0", sourcePath: sourcePath,
                name: "Point node", kind: .point, isVisible: true),
            .init(id: "source-vector/\(state.id.uuidString)/vis-map-0-tree-0.3", sourcePath: sourcePath,
                name: "Polygon node", kind: .polygon, isVisible: true)
        ]

        // The selected map node is a display identity, not a path. The editor
        // must open and stage the canonical backing file recorded separately.
        let scope = PolylineMapEditingScope(projectSessionID: UUID(), mapID: state.id,
            layerID: firstLineNodeID, canonicalPath: sourcePath)
        #expect(!scope.layerID.hasPrefix("/"))
        #expect(scope.canonicalPath == sourcePath)
        let originalInstances = state.vectors([sourceLayer])
        let originalFirstLineInstance = try #require(originalInstances.first { $0.id == firstLineNodeID })
        let originalSecondLineInstance = try #require(originalInstances.first { $0.id == secondLineNodeID })
        #expect(await state.polylineEditor.ensureLoaded(scope: scope))
        let editedLine = try #require(state.polylineEditor.lines.first { $0.sourceFeatureOrdinal == 1 })
        let changedPoint = MapPoint(x: 5, y: 6)
        #expect(await state.polylineEditor.moveVertex(lineID: editedLine.id, vertexIndex: 1, to: changedPoint))
        let rawComponentIdentity = try #require(sourceLayer.features.first { $0.sourceFeatureIndex == 1 }
            .flatMap { $0.pathStableIdentities.first })
        #expect(state.polylineEditor.selectMapComponent(rawComponentIdentity, in: originalFirstLineInstance))
        #expect(state.polylineEditor.selectedLineID == editedLine.id)
        #expect(!state.polylineEditor.selectMapComponent(rawComponentIdentity, in: originalSecondLineInstance))
        #expect(state.polylineEditor.selectMapComponent(editedLine.id, in: originalFirstLineInstance))

        let draft = try #require(state.draftVector)
        #expect(SourceFilePaths.canonical(draft.url) == sourcePath)
        #expect(draft.sourceRevision == sourceLayer.sourceRevision)
        #expect(try Data(contentsOf: sourceURL) == sourceBytes)

        let instances = state.vectors([sourceLayer])
        let firstLineInstance = try #require(instances.first { $0.id == firstLineNodeID })
        let secondLineInstance = try #require(instances.first { $0.id == secondLineNodeID })
        let pointInstance = try #require(instances.first { $0.id.hasSuffix("vis-map-0-tree-0.0") })
        let polygonInstance = try #require(instances.first { $0.id.hasSuffix("vis-map-0-tree-0.3") })

        #expect(firstLineInstance.features.map(\.kind) == [.line, .line])
        #expect(secondLineInstance.features.map(\.kind) == [.line, .line])
        #expect(firstLineInstance.features.compactMap(\.sourceFeatureIndex) == [1, 3])
        #expect(secondLineInstance.features.compactMap(\.sourceFeatureIndex) == [1, 3])
        #expect(pointInstance.features.map(\.kind) == [.point])
        #expect(pointInstance.features.compactMap(\.sourceFeatureIndex) == [0])
        #expect(polygonInstance.features.map(\.kind) == [.polygon])
        #expect(polygonInstance.features.compactMap(\.sourceFeatureIndex) == [2])

        for instance in [firstLineInstance, secondLineInstance] {
            let staged = try #require(instance.features.first { $0.sourceFeatureIndex == 1 })
            let unchanged = try #require(instance.features.first { $0.sourceFeatureIndex == 3 })
            let original = try #require(sourceLayer.features.first { $0.sourceFeatureIndex == 1 })
            let unchangedOriginal = try #require(sourceLayer.features.first { $0.sourceFeatureIndex == 3 })
            let unchangedEditorLine = try #require(state.polylineEditor.lines.first { $0.sourceFeatureOrdinal == 3 })
            #expect(staged.paths.first?[1] == changedPoint)
            #expect(staged.stableIdentity == original.stableIdentity)
            #expect(staged.pathStableIdentities == [editedLine.id])
            #expect(staged.geometryPath == original.geometryPath)
            #expect(staged.sourceFeatureIndex == original.sourceFeatureIndex)
            #expect(staged.attributes == original.attributes)
            #expect(unchanged.pathStableIdentities == [unchangedEditorLine.id])
            #expect(unchanged.stableIdentity == unchangedOriginal.stableIdentity)
            #expect(unchanged.paths == unchangedOriginal.paths)
            #expect(unchanged.sourceFeatureIndex == unchangedOriginal.sourceFeatureIndex)
        }
        #expect(firstLineInstance.features.map(\.pathStableIdentities) == secondLineInstance.features.map(\.pathStableIdentities))
        #expect(firstLineInstance.features.map(\.stableIdentity) == secondLineInstance.features.map(\.stableIdentity))
        #expect(firstLineInstance.features.first { $0.sourceFeatureIndex == 1 }?.pathStableIdentities == [editedLine.id])
    }

    @Test @MainActor
    func sharedFileAliasDraftBlocksEditsAcrossMapNodesUntilDiscarded() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("map-vector-alias-guard-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let sourceURL = folder.appendingPathComponent("shared.geojson")
        let aliasURL = folder.appendingPathComponent("shared-alias.geojson")
        let sourceBytes = Data(#"{"type":"FeatureCollection","features":[{"type":"Feature","id":"line","properties":{"name":"shared"},"geometry":{"type":"LineString","coordinates":[[0,0],[1,1],[2,0]]}}]}"#.utf8)
        try sourceBytes.write(to: sourceURL)
        try FileManager.default.createSymbolicLink(at: aliasURL, withDestinationURL: sourceURL)

        let sourcePath = SourceFilePaths.canonical(sourceURL)
        let aliasPath = SourceFilePaths.canonical(aliasURL)
        #expect(sourcePath == aliasPath)

        let store = WorkspaceStore()
        let firstMapID = UUID(), secondMapID = UUID()
        let first = store.mapState(for: firstMapID)
        let second = store.mapState(for: secondMapID)
        let firstScope = PolylineMapEditingScope(projectSessionID: store.projectSessionID, mapID: firstMapID,
            layerID: "source-vector/\(firstMapID.uuidString)/line-node", canonicalPath: sourcePath)
        let secondScope = PolylineMapEditingScope(projectSessionID: store.projectSessionID, mapID: secondMapID,
            layerID: "source-vector/\(secondMapID.uuidString)/line-node", canonicalPath: aliasURL.path)

        #expect(await first.polylineEditor.ensureLoaded(scope: firstScope))
        #expect(await second.polylineEditor.ensureLoaded(scope: secondScope))
        #expect(first.polylineEditor.currentScope?.canonicalPath == second.polylineEditor.currentScope?.canonicalPath)
        #expect(!store.hasConflictingMapDraft(path: aliasURL.path, excluding: firstMapID))

        let firstLine = try #require(first.polylineEditor.lines.first)
        #expect(await first.polylineEditor.moveVertex(lineID: firstLine.id, vertexIndex: 1,
            to: MapPoint(x: 4, y: 5)))
        #expect(first.polylineEditor.hasUnsavedChanges)
        #expect(store.hasConflictingMapDraft(path: aliasURL.path, excluding: secondMapID))
        #expect(!store.hasConflictingMapDraft(path: aliasURL.path, excluding: firstMapID))

        let secondLine = try #require(second.polylineEditor.lines.first)
        second.polylineEditor.selectLine(secondLine.id)
        #expect(!second.polylineEditor.canEditSelectedLine)
        #expect(!second.polylineEditor.isSaveAllowed)
        let blockedMove = await second.polylineEditor.moveVertex(lineID: secondLine.id, vertexIndex: 1,
            to: MapPoint(x: 8, y: 9))
        #expect(!blockedMove)
        #expect(!second.polylineEditor.hasUnsavedChanges)
        #expect(try Data(contentsOf: sourceURL) == sourceBytes)

        #expect(await first.polylineEditor.discard())
        #expect(!store.hasConflictingMapDraft(path: aliasURL.path, excluding: secondMapID))
        #expect(second.polylineEditor.isSaveAllowed)
        #expect(await second.polylineEditor.moveVertex(lineID: secondLine.id, vertexIndex: 1,
            to: MapPoint(x: 8, y: 9)))
        #expect(second.polylineEditor.hasUnsavedChanges)
        #expect(try Data(contentsOf: sourceURL) == sourceBytes)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"] != nil
        && ProcessInfo.processInfo.environment["HECRAS_MAP_LAYER_ACTION_ACCEPTANCE_DIRECTORY"] != nil))
    @MainActor
    func removedPrivateMapSourceHidesBindingDropsCachedLayerAndRetainsOtherSourceAndDraft() async throws {
        let executable = try #require(ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"])
        let fixturePath = try #require(ProcessInfo.processInfo.environment["HECRAS_MAP_LAYER_ACTION_ACCEPTANCE_DIRECTORY"])
        let fixtureURL = URL(fileURLWithPath: fixturePath, isDirectory: true).standardizedFileURL
        let manifestURL = fixtureURL.appendingPathComponent("manifest.json")
        let manifest = try JSONDecoder().decode(MapLayerRefreshAcceptanceManifest.self,
            from: Data(contentsOf: manifestURL))

        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("map-layer-refresh-\(UUID().uuidString)", isDirectory: true)
        #expect(!FileManager.default.fileExists(atPath: temporaryRoot.path))
        try FileManager.default.copyItem(at: fixtureURL, to: temporaryRoot)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let projectURL = temporaryRoot.appendingPathComponent(manifest.project)
        let sourceURL = temporaryRoot.appendingPathComponent(manifest.vector)
        let keepURL = sourceURL.deletingLastPathComponent().appendingPathComponent("Keep copy.geojson")
        let fixtureSourceBytes = try Data(contentsOf: fixtureURL.appendingPathComponent(manifest.vector))
        let sourceBytes = try Data(contentsOf: sourceURL)
        try sourceBytes.write(to: keepURL)
        let keepBytes = try Data(contentsOf: keepURL)
        let sourcePath = SourceFilePaths.canonical(sourceURL)
        let keepPath = SourceFilePaths.canonical(keepURL)

        let store = WorkspaceStore(
            system: SourceWorkflowFixtureServices(recoveryFolder: temporaryRoot.appendingPathComponent("Recovery")),
            modelProvider: BackendModelProvider(client: BackendProcessClient(executableURL: URL(fileURLWithPath: executable))))
        store.requestOpen(projectURL)
        try await waitForProjectOpen(store)
        let mapID = try #require(store.catalogMapDocuments.first { $0.kind == "Buildable" }
            .flatMap { UUID(uuidString: $0.id) })

        // Register two independent real GeoJSON nodes through the production
        // Store/backend path. One will disappear; the other must remain live.
        await store.addAssetsToMap([
            ProjectAsset(url: sourceURL, section: .mapLayers),
            ProjectAsset(url: keepURL, section: .mapLayers)
        ], mapID: mapID)
        var nodes = try await store.sourceMapLayerNodes(mapID)
        await store.refreshSourceMapVectors(nodes, mapID: mapID)
        let targetNode = try #require(nodes.first {
            $0.sourceLocator?.nodeType == "MapLayer" && $0.sourceLocator?.mapType == "PolylinesVector"
                && $0.assetID.map { SourceFilePaths.canonical(URL(fileURLWithPath: $0)) } == sourcePath
        })
        let keepNode = try #require(nodes.first {
            $0.sourceLocator?.nodeType == "MapLayer" && $0.sourceLocator?.mapType == "PolylinesVector"
                && $0.assetID.map { SourceFilePaths.canonical(URL(fileURLWithPath: $0)) } == keepPath
        })
        let state = store.mapState(for: mapID)
        let targetLayerID = store.sourceVectorInstanceID(targetNode, mapID: mapID)
        let keepLayerID = store.sourceVectorInstanceID(keepNode, mapID: mapID)
        #expect(store.mapLayers.contains { SourceFilePaths.canonical($0.url) == sourcePath })
        #expect(store.mapLayers.contains { SourceFilePaths.canonical($0.url) == keepPath })
        #expect(state.vectors(store.mapLayers).contains { $0.id == targetLayerID })
        #expect(state.vectors(store.mapLayers).contains { $0.id == keepLayerID })

        let editor = state.polylineEditor
        let scope = PolylineMapEditingScope(projectSessionID: store.projectSessionID, mapID: mapID,
            layerID: targetLayerID, canonicalPath: sourcePath)
        #expect(await editor.ensureLoaded(scope: scope))
        let line = try #require(editor.lines.first)
        let draftPoint = MapPoint(x: 41, y: 42)
        #expect(await editor.moveVertex(lineID: line.id, vertexIndex: 1, to: draftPoint))
        #expect(editor.hasUnsavedChanges)
        #expect(store.hasUnsavedMapEdits)
        #expect(try Data(contentsOf: sourceURL) == sourceBytes)

        // The file vanishes only in the private fixture copy. A fresh source
        // read must hide its binding and remove the cached raw layer without
        // discarding the in-memory line ledger or the independent valid node.
        try FileManager.default.removeItem(at: sourceURL)
        nodes = try await store.sourceMapLayerNodes(mapID)
        let unavailableTarget = try #require(nodes.first { $0.id == targetNode.id })
        #expect({ if case nil = unavailableTarget.checked { true } else { false } }())
        await store.refreshSourceMapVectors(nodes, mapID: mapID)

        let targetBinding = try #require(state.sourceVectorBindings?.first { $0.id == targetLayerID })
        #expect(!targetBinding.isVisible)
        #expect(!store.mapLayers.contains { SourceFilePaths.canonical($0.url) == sourcePath })
        #expect(store.mapLayers.contains { SourceFilePaths.canonical($0.url) == keepPath })
        let rendered = state.vectors(store.mapLayers)
        #expect(!rendered.contains { $0.id == targetLayerID })
        #expect(rendered.contains { $0.id == keepLayerID && $0.isSourceVisible })

        #expect(editor.currentScope?.layerID == targetLayerID)
        #expect(editor.currentScope?.canonicalPath == sourcePath)
        #expect(editor.hasUnsavedChanges)
        #expect(store.hasUnsavedMapEdits)
        #expect(editor.lines.first?.points[1] == draftPoint)
        let retainedDraftLayer = try #require(editor.currentMapLayer)
        #expect(SourceFilePaths.canonical(retainedDraftLayer.url) == sourcePath)
        #expect(try Data(contentsOf: keepURL) == keepBytes)
        #expect(try Data(contentsOf: fixtureURL.appendingPathComponent(manifest.vector)) == fixtureSourceBytes)
    }

    @MainActor
    private func waitForProjectOpen(_ store: WorkspaceStore) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while (store.document == nil || store.isOpeningProject || store.isMapLoading) && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!store.isOpeningProject)
        #expect(store.document != nil)
    }
}

private struct MapLayerRefreshAcceptanceManifest: Decodable {
    let project: String
    let vector: String
}
