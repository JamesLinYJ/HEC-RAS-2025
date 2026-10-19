import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

struct StoreAssociatedLayerRoutingTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HECRAS_MESH_PREPARE_ACCEPTANCE_DIRECTORY"] != nil
        && ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"] != nil)) @MainActor
    func independentProjectTerrainDoesNotBecomeAnAssociatedGeometryLayer() async throws {
        let fixturePath = try #require(ProcessInfo.processInfo.environment["HECRAS_MESH_PREPARE_ACCEPTANCE_DIRECTORY"])
        let executable = try #require(ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"])
        let fixture = URL(fileURLWithPath: fixturePath, isDirectory: true).standardizedFileURL
        let projectName = "Prepared geometry.ras"

        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("independent-project-terrain-\(UUID().uuidString)", isDirectory: true)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        try FileManager.default.copyItem(at: fixture, to: folder)
        defer { try? FileManager.default.removeItem(at: folder) }

        let copiedProjectURL = folder.appendingPathComponent(projectName)
        let terrain = try #require(ProjectDocument(contentsOf: copiedProjectURL).assets.first {
            $0.section == .terrains && $0.isModelFile && $0.url.pathExtension.lowercased() == "h5"
        }, "The source-backed project fixture must contain a real independent Terrain asset.")
        let projectBytes = try Data(contentsOf: copiedProjectURL)
        let terrainBytes = try Data(contentsOf: terrain.url)
        let visualizationURL = copiedProjectURL.deletingPathExtension().appendingPathExtension("vis")

        let store = WorkspaceStore(
            system: SourceWorkflowFixtureServices(recoveryFolder: folder.appendingPathComponent("Recovery")),
            modelProvider: BackendModelProvider(client: BackendProcessClient(executableURL: URL(fileURLWithPath: executable))))
        store.requestOpen(copiedProjectURL)
        try await waitForProjectOpen(store)

        // The fixture intentionally has no .vis. Create a real saved Project
        // map so this regression exercises map.tree.load and its exact source
        // locators, rather than the unpersisted catalog-tree fallback.
        #expect(await store.createMapDocument(kind: .project))
        let savedMap = try #require(store.mapIdentityRequest(for: MapState.projectMapID))
        #expect(savedMap.mapType == "Project")
        let visualizationBytes = try Data(contentsOf: visualizationURL)
        let rows = try await store.sourceMapLayerRows(MapState.projectMapID)
        let independentTerrain = try #require(rows.first {
            $0.node.sourceLocator?.nodeType == "Terrain"
                && $0.node.sourceLocator?.rootName == "Terrains"
                && SourceFilePaths.canonical(URL(fileURLWithPath: $0.node.sourceLocator?.assetID ?? ""))
                    == SourceFilePaths.canonical(terrain.url)
        })
        #expect(independentTerrain.node.sourceLocator?.associationKind == nil)
        #expect(independentTerrain.node.sourceLocator?.associationAssetID == nil)
        #expect(!independentTerrain.isGeometryAssociationContext)

        await store.configureMapResultSources(MapState.projectMapID)
        let associatedSession = store.mapState(for: MapState.projectMapID).associatedMapLayers
        #expect(associatedSession.preflightDiagnostics.isEmpty)
        #expect(associatedSession.errorMessage == nil)
        #expect(!associatedSession.entries.contains {
            SourceFilePaths.canonical(URL(fileURLWithPath: $0.capture.associationNode.associationAssetID ?? ""))
                == SourceFilePaths.canonical(terrain.url)
        })

        #expect(try Data(contentsOf: copiedProjectURL) == projectBytes)
        #expect(try Data(contentsOf: terrain.url) == terrainBytes)
        #expect(try Data(contentsOf: visualizationURL) == visualizationBytes)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HECRAS_ASSOCIATED_MAP_ACCEPTANCE_DIRECTORY"] != nil
        && ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"] != nil)) @MainActor
    func emptyGeometryMapBootstrapsRealAssociatedSourceBoundsAndKeepsThemStableWhilePanning() async throws {
        let fixturePath = try #require(ProcessInfo.processInfo.environment["HECRAS_ASSOCIATED_MAP_ACCEPTANCE_DIRECTORY"])
        let executable = try #require(ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"])
        let fixture = URL(fileURLWithPath: fixturePath, isDirectory: true).standardizedFileURL
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("geometry-map-camera-bootstrap-\(UUID().uuidString)", isDirectory: true)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        try FileManager.default.copyItem(at: fixture, to: folder)
        defer { try? FileManager.default.removeItem(at: folder) }

        let projectURL = folder.appendingPathComponent("Associated Map Layers.ras")
        let store = WorkspaceStore(
            system: SourceWorkflowFixtureServices(recoveryFolder: folder.appendingPathComponent("Recovery")),
            modelProvider: BackendModelProvider(client: BackendProcessClient(executableURL: URL(fileURLWithPath: executable))))
        store.requestOpen(projectURL)
        try await waitForProjectOpen(store)
        let geometry = try #require(store.assets.first { $0.section == .geometries })
        let geometryBytes = try Data(contentsOf: geometry.url)
        let projectBytes = try Data(contentsOf: projectURL)
        let previousMapIDs = Set(store.catalogMapDocuments.map(\.id))

        #expect(await store.focusGeometryInNewMap(assetID: geometry.id))
        let map = try #require(store.catalogMapDocuments.first {
            $0.kind == "Geometry" && !previousMapIDs.contains($0.id)
        })
        let mapID = try #require(UUID(uuidString: map.id))
        let state = store.mapState(for: mapID)
        #expect(state.kind == .geometry)
        // Source Focus defaults are unchecked. Enable actual tree contexts
        // through the same production actions as the native layer popover.
        let structuralRows = try await store.sourceMapLayerRows(mapID)
        let topologyRow = try #require(structuralRows.first {
            $0.node.sourceLocator?.nodeType == "ConceptualMesh"
        })
        #expect(await store.setSourceMapVisibility(topologyRow.node, checked: true, mapID: mapID))
        let associationRows = try await store.sourceMapLayerRows(mapID)
        let terrainRow = try #require(associationRows.first {
            $0.isGeometryAssociationContext && $0.node.sourceLocator?.associationKind == "Terrain"
        })
        #expect(await store.setSourceMapVisibility(terrainRow.node, checked: true, mapID: mapID))
        #expect(!state.associatedMapLayers.entries.isEmpty)
        try await waitForAssociatedSourceBounds(state.associatedMapLayers)
        #expect(state.associatedMapLayers.sourceReferencePoints.count >= 2,
            "The real associated-source response must provide finite bounds before any camera viewport exists.")
        #expect(state.associatedMapLayers.sourceReferencePoints.allSatisfy { $0.x.isFinite && $0.y.isFinite })
        #expect(state.referencePoints == nil,
            "The test has not injected or established a camera reference yet.")
        #expect(state.resultViewport == nil)

        let canvasSize = CGSize(width: 800, height: 600)
        state.canvasPixelSize = canvasSize
        state.establishReference(vectors: store.mapLayers, rasters: store.rasterLayers)
        #expect(state.referencePoints != nil)
        let initialExtent = try #require(Self.updateCameraExtent(state, store: store, size: canvasSize))
        #expect(state.currentExtent?.id == initialExtent.id)
        let initialViewport = try #require(state.resultViewport)
        #expect(initialViewport.minX < initialViewport.maxX && initialViewport.minY < initialViewport.maxY)

        // Exercise the real empty structural Geometry source at the same fitted
        // viewport that ProjectMapView would send after reference establishment.
        await state.projectGeometryMap.updateViewport(initialExtent)
        try await waitForGeometrySourcePages(state.projectGeometryMap)
        #expect(!state.projectGeometryMap.sources.isEmpty)
        #expect(state.projectGeometryMap.visibleGeometryFeatureCount == 0,
            "This acceptance fixture has no topology features, mesh cells, or culvert barrels.")

        // Geometry pages may add a source extent even when they contain no
        // renderable features. Re-establish once after that stable source
        // response before measuring the user pan behavior.
        let fittedExtent = try #require(Self.updateCameraExtent(state, store: store, size: canvasSize))
        let fittedViewport = try #require(state.resultViewport)
        await state.associatedMapLayers.updateViewport(fittedViewport)
        try await waitForAssociatedRasterFrame(state.associatedMapLayers)

        let stableReferencePoints = try #require(state.referencePoints)
        let stableMapReferenceRevision = state.referenceRevision
        let stableSourceExtentRevision = state.associatedMapLayers.sourceExtentRevision
        state.offset = CGSize(width: 53, height: -29)
        let pannedExtent = try #require(Self.updateCameraExtent(state, store: store, size: canvasSize))
        let pannedViewport = try #require(state.resultViewport)
        #expect(pannedExtent.id != fittedExtent.id)
        await state.associatedMapLayers.updateViewport(pannedViewport)
        try await waitForAssociatedRasterFrame(state.associatedMapLayers)

        #expect(state.referencePoints == stableReferencePoints)
        #expect(state.referenceRevision == stableMapReferenceRevision)
        #expect(state.associatedMapLayers.sourceExtentRevision == stableSourceExtentRevision)
        #expect(state.associatedMapLayers.visibleLayers.allSatisfy { $0.width > 1 && $0.height > 1 },
            "Only the fitted camera viewport raster should be installed; the 1×1 metadata seed is never rendered.")
        #expect(try Data(contentsOf: geometry.url) == geometryBytes)
        #expect(try Data(contentsOf: projectURL) == projectBytes)
    }

    @MainActor
    private static func updateCameraExtent(_ state: MapState, store: WorkspaceStore,
                                          size: CGSize) -> ViewportRequest? {
        state.establishReference(vectors: store.mapLayers, rasters: store.rasterLayers)
        let transform = MapTransform(points: state.transformPoints(vectors: store.mapLayers, rasters: store.rasterLayers),
            size: size, scale: state.scale, offset: state.offset)
        let extent = ViewportRequest(
            lowerLeft: transform.world(CGPoint(x: 0, y: size.height)),
            upperRight: transform.world(CGPoint(x: size.width, y: 0)))
        state.currentExtent = extent
        return extent
    }

    @MainActor
    private func waitForProjectOpen(_ store: WorkspaceStore) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while (store.document == nil || store.isOpeningProject || store.isMapLoading)
            && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!store.isOpeningProject)
        #expect(store.document != nil)
    }

    @MainActor
    private func waitForGeometrySourcePages(_ session: ProjectGeometryMapSession) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while (session.isLoading || session.sources.contains { $0.snapshot == nil || $0.hasNextPage })
            && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!session.isLoading)
        #expect(session.sources.allSatisfy { $0.snapshot != nil && !$0.hasNextPage })
    }

    @MainActor
    private func waitForAssociatedSourceBounds(_ session: AssociatedMapLayerSession) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while session.sourceReferencePoints.isEmpty && session.errorMessage == nil
            && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(session.errorMessage == nil)
        #expect(!session.sourceReferencePoints.isEmpty)
    }

    @MainActor
    private func waitForAssociatedRasterFrame(_ session: AssociatedMapLayerSession) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while session.visibleLayers.isEmpty && session.errorMessage == nil
            && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!session.visibleLayers.isEmpty)
        #expect(session.errorMessage == nil)
    }
}
