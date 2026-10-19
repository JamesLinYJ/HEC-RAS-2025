import CryptoKit
import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

struct BackendSavedGeometryMapWorkflowTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HECRAS_GEOMETRY_MAP_ACCEPTANCE_DIRECTORY"] != nil
        && ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"] != nil)) @MainActor
    func savedGeometryAndBuildableMapsKeepExactTypesFocusOrderVisibilityAndSourceFiles() async throws {
        let fixture = try SavedGeometryMapFixture()
        defer { fixture.cleanup() }
        let executable = try #require(ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"])
        let store = fixture.makeStore(executable: executable, suffix: "workflow")
        store.requestOpen(fixture.projectURL)
        try await waitForProjectOpen(store)

        // R18's real Project tree includes an implicit Geometry default with
        // an explicit unchecked state but no serialized node path. It must be
        // skipped while the checked Geometry A remains a real source capture.
        let projectRows = try await store.sourceMapLayerRows(MapState.projectMapID)
        let implicitGeometry = try #require(projectRows.first {
            $0.node.sourceLocator?.nodeType == "Geometry"
                && $0.node.name == "Map geometry B"
                && $0.node.sourceLocator?.nodePath == nil
        })
        #expect(implicitGeometry.node.checked == .unchecked)
        let checkedGeometry = try #require(projectRows.first {
            $0.node.sourceLocator?.nodeType == "Geometry"
                && $0.node.name == "Map geometry A"
        })
        #expect(checkedGeometry.node.checked == .checked)
        #expect(checkedGeometry.node.sourceLocator?.nodePath?.isEmpty == false)
        await store.configureMapResultSources(MapState.projectMapID)
        let projectGeometrySession = store.mapState(for: MapState.projectMapID).projectGeometryMap
        #expect(projectGeometrySession.preflightDiagnostics.isEmpty)
        #expect(projectGeometrySession.error == nil)
        #expect(projectGeometrySession.sources.contains { $0.capture.geometryName == "Map geometry A" })
        #expect(!projectGeometrySession.sources.contains { $0.capture.geometryName == "Map geometry B" })
        try await waitForGeometrySnapshot(projectGeometrySession, geometryName: "Map geometry A")

        let originalRas = try Data(contentsOf: fixture.projectURL)
        let originalGeometry = try fixture.geometryHashes()
        let geometryA = try #require(store.assets.first {
            $0.section == .geometries && $0.name == "Map geometry A" && $0.isModelFile
        })
        let geometryB = try #require(store.assets.first {
            $0.section == .geometries && $0.name == "Map geometry B" && $0.isModelFile
        })

        // This is the retained Focus In New View action: create Type=Geometry
        // and persist its first focused HDF in one source transaction.
        #expect(await store.focusGeometryInNewMap(assetID: geometryA.id))
        let geometryMap = try #require(store.mapDocuments.first { $0.kind == .geometry })
        #expect(geometryMap.sourceType == "Geometry")
        #expect(try #require(store.mapIdentityRequest(for: geometryMap.id)).mapType == "Geometry")

        // A subsequent focus appends in source order; the same operation on a
        // Buildable map persists under Layers instead of Focused Geometries.
        #expect(await store.focusGeometryInMap(assetID: geometryB.id, mapID: geometryMap.id))
        #expect(await store.createMapDocument(kind: .buildable))
        let buildableMap = try #require(store.mapDocuments.last { $0.kind == .buildable })
        #expect(buildableMap.sourceType == "Buildable")
        #expect(await store.addGeometryToMap(assetID: geometryB.id, mapID: buildableMap.id))

        let geometryIdentity = try #require(store.mapIdentityRequest(for: geometryMap.id))
        let buildableIdentity = try #require(store.mapIdentityRequest(for: buildableMap.id))
        #expect(geometryIdentity.mapType == "Geometry")
        #expect(buildableIdentity.mapType == "Buildable")
        #expect(geometryIdentity.mapID != buildableIdentity.mapID)
        #expect(geometryIdentity.mapIndex != buildableIdentity.mapIndex)

        let geometryTree = try await loadTree(store, mapID: geometryMap.id)
        let buildableTree = try await loadTree(store, mapID: buildableMap.id)
        #expect(geometryTree.roots.map(\.name) == ["Focused Geometries", "Matching Layers", "Layers"])
        #expect(buildableTree.roots.contains { $0.name == "Layers" })
        #expect(!buildableTree.roots.contains { $0.name == "Focused Geometries" })

        let geometryNodes = try await store.sourceMapLayerNodes(geometryMap.id)
        let focusedRows = geometryNodes.filter { $0.sourceLocator?.nodeType == "Geometry" }
        #expect(focusedRows.map(\.name) == ["Map geometry A", "Map geometry B"])
        #expect(focusedRows.allSatisfy { $0.sourceLocator?.rootName == "Focused Geometries" })
        #expect(focusedRows.allSatisfy { $0.sourceLocator?.nodePath?.count ?? 0 >= 2 })
        #expect(Set(focusedRows.compactMap { $0.sourceLocator?.assetID ?? $0.assetID }.map {
            SourceFilePaths.canonical(URL(fileURLWithPath: $0))
        }).count == 2)

        let buildableNodes = try await store.sourceMapLayerNodes(buildableMap.id)
        let buildableGeometry = try #require(buildableNodes.first {
            $0.sourceLocator?.nodeType == "Geometry" && $0.name == "Map geometry B"
        })
        #expect(buildableGeometry.sourceLocator?.rootName == "Layers")
        #expect((buildableGeometry.sourceLocator?.nodePath?.count ?? 0) >= 2)
        let initialBuildableCulvert = try #require(buildableNodes.first {
            $0.sourceLocator?.nodeType == "CulvertBarrelLayer"
                && $0.sourceLocator?.parentGeometryNodeName == "Map geometry B"
        })
        // Adding a Geometry checks the parent membership only. The retained
        // component defaults to unchecked unless its own IsChecked state was
        // saved, so independence is measured against this source default.
        #expect(initialBuildableCulvert.checked == .unchecked)

        // Read real source pages through the same production provider used by
        // the canvas. These checks bind the response to Geometry and Buildable
        // map index/name/type and to the exact HDF row returned by each tree.
        let client = BackendProcessClient(executableURL: URL(fileURLWithPath: executable))
        let geometryWorkflow = store.mapWorkflowIdentity(geometryMap.id)
        let geometryProvider = BackendProjectGeometryMapProvider(client: client, isCurrent: {
            store.mapWorkflowIdentity(geometryMap.id) == geometryWorkflow
        })
        let geometryASnapshot = try await loadGeometry(store: store, mapID: geometryMap.id,
            node: try #require(focusedRows.first { $0.name == "Map geometry A" }), provider: geometryProvider)
        #expect(geometryASnapshot.mapType == "Geometry")
        #expect(geometryASnapshot.mapIndex == geometryIdentity.mapIndex)
        #expect(geometryASnapshot.mapName == geometryIdentity.mapName)
        #expect(geometryASnapshot.flowAreas?.sourceCellCount ?? 0 > 16_384)

        let buildableWorkflow = store.mapWorkflowIdentity(buildableMap.id)
        let buildableProvider = BackendProjectGeometryMapProvider(client: client, isCurrent: {
            store.mapWorkflowIdentity(buildableMap.id) == buildableWorkflow
        })
        let buildableBSnapshot = try await loadGeometry(store: store, mapID: buildableMap.id,
            node: buildableGeometry, provider: buildableProvider)
        #expect(buildableBSnapshot.mapType == "Buildable")
        #expect(buildableBSnapshot.mapIndex == buildableIdentity.mapIndex)
        #expect(buildableBSnapshot.geometryName == "Map geometry B")
        #expect(buildableBSnapshot.culverts?.sourceBarrelCount == 2)

        // Turning off one child in the Geometry map must not change the same
        // source child's state in the separate Buildable map.
        let flowAreaA = try #require(geometryNodes.first {
            $0.sourceLocator?.nodeType == "FlowAreaLayer"
                && $0.sourceLocator?.parentGeometryNodeName == "Map geometry A"
        })
        #expect(await store.setSourceMapVisibility(flowAreaA, checked: false, mapID: geometryMap.id))
        let updatedGeometryNodes = try await store.sourceMapLayerNodes(geometryMap.id)
        let hiddenFlowAreaA = try #require(updatedGeometryNodes.first {
            $0.sourceLocator?.nodeType == "FlowAreaLayer"
                && $0.sourceLocator?.parentGeometryNodeName == "Map geometry A"
        })
        #expect(hiddenFlowAreaA.checked == .unchecked)
        let updatedBuildableNodes = try await store.sourceMapLayerNodes(buildableMap.id)
        let unaffectedCulvert = try #require(updatedBuildableNodes.first {
            $0.sourceLocator?.nodeType == "CulvertBarrelLayer"
                && $0.sourceLocator?.parentGeometryNodeName == "Map geometry B"
        })
        #expect(unaffectedCulvert.checked == initialBuildableCulvert.checked)

        // Removing Buildable membership does not remove the project Geometry
        // or its independent focused membership from the Geometry map.
        #expect(await store.removeGeometryFromMap(nodeID: buildableGeometry.id, mapID: buildableMap.id))
        let removedBuildableRows = try await store.sourceMapLayerNodes(buildableMap.id)
        #expect(!removedBuildableRows.contains {
            $0.sourceLocator?.nodeType == "Geometry" && $0.name == "Map geometry B"
        })
        let retainedGeometryRows = try await store.sourceMapLayerNodes(geometryMap.id)
        #expect(retainedGeometryRows.filter { $0.sourceLocator?.nodeType == "Geometry" }.map(\.name)
            == ["Map geometry A", "Map geometry B"])

        #expect(try Data(contentsOf: fixture.projectURL) == originalRas)
        #expect(try fixture.geometryHashes() == originalGeometry)
        let visualizationBytes = try Data(contentsOf: fixture.visualizationURL)
        let visualText = String(decoding: visualizationBytes, as: UTF8.self)
        #expect(visualText.contains("VendorRoot"))
        #expect(visualText.contains("preserve-me"))
        #expect(visualText.contains("VendorExtension"))
        #expect(visualText.contains("VendorMapAttribute"))
        let savedVisualization = try VisualizationDocument(projectURL: fixture.projectURL)
        #expect(savedVisualization.maps.contains { $0.type == "Geometry" && $0.index == geometryIdentity.mapIndex })
        #expect(savedVisualization.maps.contains { $0.type == "Buildable" && $0.index == buildableIdentity.mapIndex })

        // Reopen from the saved .vis tree and verify both exact map types,
        // focused order, membership, and child visibility survive reload.
        // Close the first workspace through its normal lifecycle so a second
        // owner can acquire the project-folder lease.
        store.requestClose()
        if store.showDiscardConfirmation { store.discardAndContinue() }
        try #require(store.document == nil)
        let reopened = fixture.makeStore(executable: executable, suffix: "reopen")
        reopened.requestOpen(fixture.projectURL)
        try await waitForProjectOpen(reopened)
        let reopenedGeometry = try #require(reopened.mapDocuments.first { $0.kind == .geometry })
        let reopenedBuildable = try #require(reopened.mapDocuments.first { $0.kind == .buildable })
        #expect(reopened.mapIdentityRequest(for: reopenedGeometry.id)?.mapType == "Geometry")
        #expect(reopened.mapIdentityRequest(for: reopenedBuildable.id)?.mapType == "Buildable")
        let reopenedGeometryNodes = try await reopened.sourceMapLayerNodes(reopenedGeometry.id)
        #expect(reopenedGeometryNodes.filter { $0.sourceLocator?.nodeType == "Geometry" }.map(\.name)
            == ["Map geometry A", "Map geometry B"])
        let reopenedFlowAreaA = try #require(reopenedGeometryNodes.first {
            $0.sourceLocator?.nodeType == "FlowAreaLayer"
                && $0.sourceLocator?.parentGeometryNodeName == "Map geometry A"
        })
        #expect(reopenedFlowAreaA.checked == .unchecked)
        let reopenedBuildableNodes = try await reopened.sourceMapLayerNodes(reopenedBuildable.id)
        #expect(!reopenedBuildableNodes.contains {
            $0.sourceLocator?.nodeType == "Geometry" && $0.name == "Map geometry B"
        })
        #expect(try Data(contentsOf: fixture.projectURL) == originalRas)
        #expect(try fixture.geometryHashes() == originalGeometry)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HECRAS_GEOMETRY_MAP_ACCEPTANCE_DIRECTORY"] != nil
        && ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"] != nil)) @MainActor
    func symlinkedProjectPathLoadsExactSourceAndRejectsStaleProjectVisAndGeometryPages() async throws {
        let fixture = try SavedGeometryMapFixture()
        defer { fixture.cleanup() }
        let executable = try #require(ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"])
        let alias = fixture.root.appendingPathComponent("project-parent-alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.root)
        let aliasProject = alias.appendingPathComponent(fixture.projectURL.lastPathComponent)

        let store = fixture.makeStore(executable: executable, suffix: "alias")
        store.requestOpen(aliasProject)
        try await waitForProjectOpen(store)
        let identity = try #require(store.mapIdentityRequest(for: MapState.projectMapID))
        #expect(identity.projectPath == aliasProject.path)
        #expect(SourceFilePaths.canonical(URL(fileURLWithPath: identity.projectPath))
            == SourceFilePaths.canonical(fixture.projectURL))

        let nodes = try await store.sourceMapLayerNodes(MapState.projectMapID)
        let geometry = try #require(nodes.first {
            $0.sourceLocator?.nodeType == "Geometry" && $0.name == "Map geometry A"
        })
        let locator = try #require(geometry.sourceLocator)
        let assetPath = try #require(geometry.assetID ?? locator.assetID)
        let sourceURL = try PlatformPaths.resolve(assetPath,
            relativeTo: try #require(store.document?.directory), mappings: [])
        let workflow = store.mapWorkflowIdentity(MapState.projectMapID)
        let capture = try ProjectGeometryMapCapture(projectSessionID: store.projectSessionID,
            mapID: MapState.projectMapID, mapWorkflowIdentity: workflow, map: identity,
            geometryNode: locator, geometryAssetPath: sourceURL.path, geometryName: geometry.name)
        let provider = BackendProjectGeometryMapProvider(client: BackendProcessClient(executableURL: URL(fileURLWithPath: executable)),
            isCurrent: { store.mapWorkflowIdentity(MapState.projectMapID) == workflow })
        let first = try await provider.load(MapGeometryRequest(map: identity, geometryNode: locator,
            viewport: nil, contextToken: nil), capture: capture)
        #expect(first.mapType == "Project")
        #expect(SourceFilePaths.canonical(URL(fileURLWithPath: first.geometryCanonicalPath))
            == SourceFilePaths.canonical(fixture.geometryURL(named: "Map geometry A")))
        let cursor = try #require(first.flowAreas?.nextCursor)
        let continuation = MapGeometryRequest(map: identity, geometryNode: locator,
            viewport: nil, contextToken: first.contextToken, cellCursor: cursor,
            skipTopologyPage: true, skipCulvertsPage: true)

        // Every stale check uses the real continuation token, restoring the
        // copied files after each negative probe. The fixture source itself is
        // immutable and each alias resolves to the same copied project files.
        for url in [fixture.visualizationURL, fixture.projectURL, sourceURL] {
            let saved = try Data(contentsOf: url)
            var changed = saved
            changed.append(Data("\n<!-- external stale-source probe -->\n".utf8))
            try changed.write(to: url, options: .atomic)
            do {
                _ = try await provider.load(continuation, capture: capture)
                Issue.record("Geometry continuation accepted an externally changed source file: \(url.lastPathComponent)")
            } catch let error as BackendServiceError {
                #expect(error.code == "sourceChanged")
            } catch ProjectGeometryMapError.sourceChanged {
                // The native provider can detect changed HDF bytes before the Host call.
            }
            try saved.write(to: url, options: .atomic)
        }

        #expect(try fixture.originalsUnchanged())
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HECRAS_ASSOCIATED_MAP_ACCEPTANCE_DIRECTORY"] != nil
        && ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"] != nil)) @MainActor
    func realAssociatedLayersAreOwnedByExactGeometryMapTreeNodes() async throws {
        // This fixture is exported only from the retained source-backed
        // association regression. It contains real HDF inputs and shared
        // Observable association objects; same display text is never used as
        // a substitute for the Geometry -> Terrain/NValue/Classification link.
        let fixture = try SavedGeometryMapFixture(environmentKey: "HECRAS_ASSOCIATED_MAP_ACCEPTANCE_DIRECTORY",
            projectName: nil)
        defer { fixture.cleanup() }
        let executable = try #require(ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"])
        let store = fixture.makeStore(executable: executable, suffix: "associated")
        store.requestOpen(fixture.projectURL)
        try await waitForProjectOpen(store)
        let rasBefore = try Data(contentsOf: fixture.projectURL)
        let hdfBefore = try fixture.geometryHashes()
        let map = try #require(store.mapDocuments.first {
            $0.kind == .geometry && $0.name == "R19 Associated Geometry Map"
        })
        let mapID = map.id
        let mapIdentity = try #require(store.mapIdentityRequest(for: mapID))
        #expect(mapIdentity.mapType == "Geometry")
        await store.configureMapResultSources(mapID)

        let initialRows = try await store.sourceMapLayerRows(mapID)
        let initialGeometryRows = initialRows.filter { $0.node.sourceLocator?.nodeType == "Geometry" }
        #expect(initialGeometryRows.map { $0.node.name }
            == ["R19 Shared Geometry A", "R19 Shared Geometry B"])
        let initialAssociatedRows = initialRows.filter {
            ["Terrain", "NValue", "Classification"].contains($0.node.sourceLocator?.nodeType ?? "")
        }
        #expect(Set(initialAssociatedRows.compactMap { $0.node.sourceLocator?.nodeType })
            == Set(["Terrain", "NValue", "Classification"]))

        // Make the exact Matching Layers visible using the real .vis tree
        // action. The call is source-backed and must not write .ras or HDF.
        for row in initialAssociatedRows where row.node.checked != .checked || !row.isEffectivelyVisible {
            #expect(await store.setSourceMapVisibility(row.node, checked: true, mapID: mapID))
        }
        await store.configureMapResultSources(mapID)
        let rows = try await store.sourceMapLayerRows(mapID)
        let geometryRows = rows.filter { $0.node.sourceLocator?.nodeType == "Geometry" }
        #expect(geometryRows.map { $0.node.name }
            == ["R19 Shared Geometry A", "R19 Shared Geometry B"])
        let geometryLocators = Set(geometryRows.compactMap { $0.node.sourceLocator })
        #expect(geometryLocators.count == 2)
        let associationRows = rows.filter {
            ["Terrain", "NValue", "Classification"].contains($0.node.sourceLocator?.nodeType ?? "")
        }
        #expect(associationRows.count == 3)
        let state = store.mapState(for: mapID).associatedMapLayers
        // This fixture has no structural Geometry extent. Bootstrap the camera
        // from the real associated Terrain/NValue/Classification source bounds.
        await state.bootstrapSourceExtents()
        let sourceBounds = state.sourceReferencePoints
        #expect(sourceBounds.count >= 2)
        let minX = try #require(sourceBounds.map(\.x).min())
        let maxX = try #require(sourceBounds.map(\.x).max())
        let minY = try #require(sourceBounds.map(\.y).min())
        let maxY = try #require(sourceBounds.map(\.y).max())
        let sourceBoundsAreFinite = [minX, maxX, minY, maxY].allSatisfy { $0.isFinite }
        #expect(sourceBoundsAreFinite)
        #expect(minX < maxX && minY < maxY)
        let viewport = RasterMapViewExtent(minX: minX, minY: minY,
            maxX: maxX, maxY: maxY, pixelWidth: 32, pixelHeight: 32)
        await state.updateViewport(viewport)
        await state.refresh()

        #expect(!state.isLoading)
        #expect(state.errorMessage == nil)
        #expect(state.entries.count == 3)
        #expect(state.entries.allSatisfy { $0.capture.map.mapType == "Geometry" })
        #expect(state.entries.allSatisfy { $0.capture.map.mapID == mapID.uuidString })
        #expect(state.entries.allSatisfy { Set($0.capture.geometryNodes) == geometryLocators })
        #expect(state.entries.allSatisfy { entry in
            guard let payload = entry.payload else { return false }
            return Set(payload.geometryNodes) == geometryLocators
        })
        #expect(state.entries.allSatisfy { $0.capture.associationNode.associationAssetID != nil })
        #expect(Set(state.entries.map(\.capture.associationNode.nodeType))
            == Set(["Terrain", "NValue", "Classification"]))
        for entry in state.entries {
            let sourcePath = try #require(entry.capture.associationNode.associationAssetID)
            let expectedSection: ProjectSection = switch entry.capture.associationNode.nodeType {
            case "Terrain": .terrains
            default: .surfaceLayers
            }
            #expect(store.assets.contains {
                $0.section == expectedSection && $0.isModelFile
                    && SourceFilePaths.canonical($0.url)
                        == SourceFilePaths.canonical(URL(fileURLWithPath: sourcePath))
            })
        }
        let renderedKinds = Set(state.entries.compactMap { $0.payload?.kind })
        #expect(renderedKinds.isSuperset(of: [.terrain, .nValue, .classification]))
        #expect(state.entries.filter { entry in
            guard let kind = entry.payload?.kind else { return false }
            return [.terrain, .nValue, .classification].contains(kind)
        }
            .allSatisfy { entry in
                guard let payload = entry.payload, payload.status == .available else { return false }
                return SourceFilePaths.canonical(URL(fileURLWithPath: payload.assetPath)) == entry.capture.assetPath
                    && payload.width == viewport.pixelWidth && payload.height == viewport.pixelHeight
                    && payload.rgba.count == viewport.pixelWidth * viewport.pixelHeight * 4
                    && payload.dependencies.contains { $0.role == "source-hdf" }
            })
        #expect(try Data(contentsOf: fixture.projectURL) == rasBefore)
        #expect(try fixture.geometryHashes() == hdfBefore)
        #expect(try fixture.originalsUnchanged())
    }

    @MainActor
    private func loadTree(_ store: WorkspaceStore, mapID: UUID) async throws -> LayerTreeSnapshot {
        let provider = try #require(store.layerTreeProvider)
        return try await provider.load(store.sourceMapTreeContext(mapID))
    }

    @MainActor
    private func loadGeometry(store: WorkspaceStore, mapID: UUID, node: LayerTreeNode,
                              provider: BackendProjectGeometryMapProvider) async throws -> MapGeometrySnapshot {
        let identity = try #require(store.mapIdentityRequest(for: mapID))
        let locator = try #require(node.sourceLocator)
        let asset = try #require(node.assetID ?? locator.assetID)
        let directory = try #require(store.document?.directory)
        let sourceURL = try PlatformPaths.resolve(asset, relativeTo: directory, mappings: [])
        let capture = try ProjectGeometryMapCapture(projectSessionID: store.projectSessionID,
            mapID: mapID, mapWorkflowIdentity: store.mapWorkflowIdentity(mapID), map: identity,
            geometryNode: locator, geometryAssetPath: sourceURL.path, geometryName: node.name)
        return try await provider.load(MapGeometryRequest(map: identity, geometryNode: locator,
            viewport: nil, contextToken: nil), capture: capture)
    }

    @MainActor
    private func waitForProjectOpen(_ store: WorkspaceStore) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while (store.document == nil || store.isOpeningProject || store.isMapLoading) && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!store.isOpeningProject)
        #expect(store.document != nil)
    }

    @MainActor
    private func waitForGeometrySnapshot(_ session: ProjectGeometryMapSession,
                                         geometryName: String) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while !session.sources.contains(where: {
            $0.capture.geometryName == geometryName && $0.snapshot != nil
        }) && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let source = try #require(session.sources.first { $0.capture.geometryName == geometryName })
        #expect(source.snapshot?.geometryName == geometryName)
        #expect(source.error == nil)
    }
}

@MainActor
private struct SavedGeometryMapFixture {
    let original: URL
    let root: URL
    let projectURL: URL
    var visualizationURL: URL { projectURL.deletingPathExtension().appendingPathExtension("vis") }
    private let originalHashes: [String: String]

    init(environmentKey: String = "HECRAS_GEOMETRY_MAP_ACCEPTANCE_DIRECTORY",
         projectName: String? = "Geometry project map.ras") throws {
        original = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment[environmentKey]), isDirectory: true)
        originalHashes = try Self.hashes(in: original)
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "saved-geometry-map-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.copyItem(at: original, to: root)
        if let projectName {
            projectURL = root.appendingPathComponent(projectName)
        } else {
            let rasFiles = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension.lowercased() == "ras" }
            guard rasFiles.count == 1 else { throw ProjectFileError.invalid("The associated-map fixture must contain one project file.") }
            projectURL = rasFiles[0]
        }
    }

    func makeStore(executable: String, suffix: String) -> WorkspaceStore {
        WorkspaceStore(system: SourceWorkflowFixtureServices(recoveryFolder:
            root.appendingPathComponent("Recovery-\(suffix)", isDirectory: true)),
            modelProvider: BackendModelProvider(client: BackendProcessClient(executableURL: URL(fileURLWithPath: executable))))
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
    func originalsUnchanged() throws -> Bool { try Self.hashes(in: original) == originalHashes }

    func geometryURL(named name: String) -> URL {
        root.appendingPathComponent("Geometries", isDirectory: true).appendingPathComponent(name + ".h5")
    }

    func geometryHashes() throws -> [String: String] {
        try Self.hashes(in: root).filter { path, _ in
            path.lowercased().hasSuffix(".h5") || path.lowercased().hasSuffix(".hdf")
        }
    }

    private static func hashes(in directory: URL) throws -> [String: String] {
        let enumerator = try #require(FileManager.default.enumerator(at: directory,
            includingPropertiesForKeys: [.isRegularFileKey]))
        let canonicalRoot = SourceFilePaths.canonical(directory) + "/"
        var result: [String: String] = [:]
        for case let url as URL in enumerator {
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            let canonical = SourceFilePaths.canonical(url)
            guard canonical.hasPrefix(canonicalRoot) else { throw CocoaError(.fileReadInvalidFileName) }
            result[String(canonical.dropFirst(canonicalRoot.count))] = sha(try Data(contentsOf: url))
        }
        return result
    }

    private static func sha(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02X", $0) }.joined()
    }
}
