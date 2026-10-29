import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

@Suite(.serialized)
struct BackendStoreMapHoverIdentifyCaptureTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HECRAS_GEOMETRY_MAP_ACCEPTANCE_DIRECTORY"] != nil
        && ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"] != nil))
    @MainActor
    func configuredFlowAreaAndCulvertCapturesReachHoverFlights() async throws {
        let fixture = try StoreHoverFixture(
            environmentKey: "HECRAS_GEOMETRY_MAP_ACCEPTANCE_DIRECTORY",
            projectName: "Geometry project map.ras")
        defer { fixture.remove() }
        let store = fixture.makeStore()
        defer { closeStore(store) }
        try await fixture.open(store)

        let geometryA = try #require(store.assets.first {
            $0.section == .geometries && $0.name == "Map geometry A" && $0.isModelFile
        })
        let geometryB = try #require(store.assets.first {
            $0.section == .geometries && $0.name == "Map geometry B" && $0.isModelFile
        })
        #expect(await store.focusGeometryInNewMap(assetID: geometryA.id))
        let map = try #require(store.mapDocuments.first { $0.kind == .geometry })
        #expect(await store.focusGeometryInMap(assetID: geometryB.id, mapID: map.id))

        let flowArea = try await storeHoverVisibleRow(store, mapID: map.id) {
            $0.sourceLocator?.nodeType == "FlowAreaLayer"
                && $0.sourceLocator?.parentGeometryNodeName == "Map geometry A"
        }
        let culvert = try await storeHoverVisibleRow(store, mapID: map.id) {
            $0.sourceLocator?.nodeType == "CulvertBarrelLayer"
                && $0.sourceLocator?.parentGeometryNodeName == "Map geometry B"
        }
        await store.configureMapResultSources(map.id)

        let state = store.mapState(for: map.id)
        try await storeHoverWaitUntil("map Result-source snapshot") {
            state.resultSources.snapshot?.sources.contextToken.isEmpty == false
                && !state.resultSources.isLoading
        } diagnostics: {
            storeHoverDiagnostic(store, mapID: map.id)
        }
        try await installStoreHoverGeometryViewport(store, mapID: map.id,
            geometryName: "Map geometry B", client: fixture.client)
        try await storeHoverWaitUntil("FlowArea and Culvert source pages") {
            state.projectGeometryMap.sources.contains { source in
                source.capture.geometryName == "Map geometry A"
                    && source.snapshot?.flowAreasState.effectiveVisible == true
                    && source.presentsFlowAreaData
                    && source.contextToken?.isEmpty == false
                    && source.geometryRevision?.isEmpty == false
            } && state.projectGeometryMap.sources.contains { source in
                source.capture.geometryName == "Map geometry B"
                    && source.snapshot?.culvertsState.effectiveVisible == true
                    && source.culvertFeatures.isEmpty == false
                    && source.geometryRevision?.isEmpty == false
            }
        } diagnostics: {
            storeHoverDiagnostic(store, mapID: map.id)
        }

        let flowCapture = try #require(state.projectGeometryMap.sources.first {
            $0.capture.geometryName == "Map geometry A"
        })
        let culvertCapture = try #require(state.projectGeometryMap.sources.first {
            $0.capture.geometryName == "Map geometry B"
        })
        try assertStoreHoverRoute(store, mapID: map.id,
            captureWorkflowIdentity: flowCapture.capture.mapWorkflowIdentity,
            locator: flowArea, kind: "mesh")
        try assertStoreHoverRoute(store, mapID: map.id,
            captureWorkflowIdentity: culvertCapture.capture.mapWorkflowIdentity,
            locator: culvert, kind: "modelVector")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HECRAS_ASSOCIATED_STYLE_ACCEPTANCE_DIRECTORY"] != nil
        && ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"] != nil))
    @MainActor
    func configuredAssociatedLayerCaptureReachesHoverFlight() async throws {
        let fixture = try StoreHoverFixture(
            environmentKey: "HECRAS_ASSOCIATED_STYLE_ACCEPTANCE_DIRECTORY",
            manifestName: "manifest.json")
        defer { fixture.remove() }
        let manifest = try JSONDecoder().decode(StoreHoverAssociatedManifest.self,
            from: Data(contentsOf: fixture.root.appendingPathComponent("manifest.json")))
        let store = fixture.makeStore()
        defer { closeStore(store) }
        try await fixture.open(store, relativeProjectPath: manifest.associatedProjectRelativePath)

        let map = try #require(store.mapDocuments.first {
            $0.kind == .geometry && $0.name == manifest.associatedMapName
        })
        await store.configureMapResultSources(map.id)
        let locator = try await storeHoverVisibleRow(store, mapID: map.id) {
            $0.sourceLocator?.rootName == "Matching Layers"
                && $0.sourceLocator?.associationKind == "NValue"
        }
        await store.configureMapResultSources(map.id)

        let state = store.mapState(for: map.id)
        try await installStoreHoverAssociatedViewport(state)
        try await storeHoverWaitUntil("associated NValue render capture") {
            state.resultSources.snapshot?.sources.contextToken.isEmpty == false
                && state.associatedMapLayers.entries.contains { entry in
                    entry.capture.associationNode == locator
                        && entry.payload?.status == .available
                        && entry.payload?.isChecked == true
                        && entry.payload?.effectiveVisible == true
                        && entry.payload?.revision.isEmpty == false
                        && entry.rasterLayer != nil
                }
        } diagnostics: {
            storeHoverDiagnostic(store, mapID: map.id)
        }
        let capture = try #require(state.associatedMapLayers.entries.first {
            $0.capture.associationNode == locator && $0.payload?.status == .available
                && $0.payload?.isChecked == true && $0.payload?.effectiveVisible == true
                && $0.payload?.revision.isEmpty == false && $0.rasterLayer != nil
        })
        try assertStoreHoverRoute(store, mapID: map.id,
            captureWorkflowIdentity: capture.capture.mapWorkflowIdentity,
            locator: locator, kind: "nvalue")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HECRAS_PLAN_MAP_ACCEPTANCE_DIRECTORY"] != nil
        && ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"] != nil))
    @MainActor
    func configuredBoundaryCaptureReachesHoverFlight() async throws {
        let fixture = try StoreHoverFixture(
            environmentKey: "HECRAS_PLAN_MAP_ACCEPTANCE_DIRECTORY",
            manifestName: "acceptance.json")
        defer { fixture.remove() }
        let manifest = try JSONDecoder().decode(StoreHoverBoundaryManifest.self,
            from: Data(contentsOf: fixture.root.appendingPathComponent("acceptance.json")))
        let store = fixture.makeStore()
        defer { closeStore(store) }
        try await fixture.open(store, relativeProjectPath: manifest.projectRelativePath)

        if store.mapDocument(for: MapState.projectMapID) == nil {
            #expect(await store.createMapDocument(kind: .project))
        }
        let map = try #require(store.mapDocument(for: MapState.projectMapID))
        await store.configureMapResultSources(map.id)
        let locator = try await storeHoverVisibleRow(store, mapID: map.id) {
            $0.sourceLocator?.rootName == "Boundary Conditions"
                && $0.sourceLocator?.nodeType == "BoundaryCondition"
                && $0.sourceLocator?.parentResultNodeType == nil
        }
        await store.configureMapResultSources(map.id)

        let state = store.mapState(for: map.id)
        try await storeHoverWaitUntil("Boundary Condition render capture") {
            state.resultSources.snapshot?.sources.contextToken.isEmpty == false
                && state.boundaryMap.entries.contains { source in
                    source.capture.boundaryNode == locator
                        && source.status == .available
                        && !source.visibleLines.isEmpty
                }
        } diagnostics: {
            storeHoverDiagnostic(store, mapID: map.id)
        }
        let capture = try #require(state.boundaryMap.entries.first {
            $0.capture.boundaryNode == locator && $0.status == .available
                && !$0.visibleLines.isEmpty
        })
        try assertStoreHoverRoute(store, mapID: map.id,
            captureWorkflowIdentity: capture.capture.mapWorkflowIdentity,
            locator: locator, kind: "modelVector")
    }
}

private struct StoreHoverAssociatedManifest: Decodable {
    let associatedProjectRelativePath: String
    let associatedMapName: String
}

private struct StoreHoverBoundaryManifest: Decodable {
    let projectRelativePath: String
}

@MainActor
private struct StoreHoverFixture {
    let root: URL
    let projectName: String?
    let client: BackendProcessClient

    init(environmentKey: String, projectName: String? = nil,
         manifestName: String? = nil) throws {
        let environment = ProcessInfo.processInfo.environment
        let source = URL(fileURLWithPath: try #require(environment[environmentKey]), isDirectory: true)
        let executable = URL(fileURLWithPath:
            try #require(environment["HECRAS_BACKEND_TEST_EXECUTABLE"]))
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "store-map-hover-\(UUID().uuidString)", isDirectory: true)
        self.projectName = projectName
        client = BackendProcessClient(executableURL: executable)
        try FileManager.default.copyItem(at: source, to: root)
        if let manifestName,
           !FileManager.default.fileExists(atPath: root.appendingPathComponent(manifestName).path) {
            throw StoreHoverFixtureError.missingManifest(manifestName)
        }
    }

    func makeStore() -> WorkspaceStore {
        WorkspaceStore(system: SourceWorkflowFixtureServices(
            recoveryFolder: root.appendingPathComponent("Recovery", isDirectory: true)),
            modelProvider: BackendModelProvider(client: client))
    }

    func open(_ store: WorkspaceStore, relativeProjectPath: String? = nil) async throws {
        let relative = relativeProjectPath ?? projectName
            ?? ""
        guard !relative.isEmpty else { throw StoreHoverFixtureError.missingProjectPath }
        let projectURL = root.appendingPathComponent(relative)
        store.requestOpen(projectURL)
        try await storeHoverWaitUntil("project open") {
            store.document?.url?.standardizedFileURL == projectURL.standardizedFileURL
                && !store.isOpeningProject && !store.isMapLoading
        }
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

@MainActor
private func storeHoverVisibleRow(_ store: WorkspaceStore, mapID: UUID,
                                  matching predicate: (LayerTreeNode) -> Bool) async throws
    -> CatalogTreeNodeLocator {
    var rows = try await store.sourceMapLayerRows(mapID)
    guard let initial = rows.first(where: { predicate($0.node) }),
          let initialLocator = initial.node.sourceLocator else {
        throw StoreHoverFixtureError.missingVisibleRow("predicate did not match a map source row")
    }

    // The visible state is the conjunction of every checkable ancestor and
    // the source row itself. Enable ancestors from the outside in, refetching
    // after each .vis mutation because every mutation produces a fresh locator.
    if let targetPath = initialLocator.nodePath {
        let ancestorDepths = Set(rows.compactMap { row -> Int? in
            guard let locator = row.node.sourceLocator,
                  locator.rootName == initialLocator.rootName,
                  let path = locator.nodePath,
                  path.count < targetPath.count,
                  Array(targetPath.prefix(path.count)) == path,
                  row.node.checked != nil else { return nil }
            return path.count
        }).sorted()
        for depth in ancestorDepths {
            rows = try await store.sourceMapLayerRows(mapID)
            guard let ancestor = rows.first(where: { row in
                guard let locator = row.node.sourceLocator,
                      locator.rootName == initialLocator.rootName,
                      locator.nodePath?.count == depth,
                      let path = locator.nodePath else { return false }
                return Array(targetPath.prefix(depth)) == path
            }) else { continue }
            if ancestor.node.checked != .checked {
                let changed = await store.setSourceMapVisibility(ancestor.node,
                    checked: true, mapID: mapID)
                #expect(changed, "Failed to enable map-source ancestor \(ancestor.node.name).")
                guard changed else {
                    throw StoreHoverFixtureError.missingVisibleRow(
                        "could not enable ancestor \(ancestor.node.name)")
                }
            }
        }
    }

    rows = try await store.sourceMapLayerRows(mapID)
    guard let row = rows.first(where: { predicate($0.node) }) else {
        throw StoreHoverFixtureError.missingVisibleRow("source row disappeared after visibility refresh")
    }
    if row.node.checked != .checked {
        let changed = await store.setSourceMapVisibility(row.node, checked: true, mapID: mapID)
        #expect(changed, "Failed to enable map source \(row.node.name).")
        guard changed else {
            throw StoreHoverFixtureError.missingVisibleRow("could not enable \(row.node.name)")
        }
    }
    rows = try await store.sourceMapLayerRows(mapID)
    guard let current = rows.first(where: { predicate($0.node) }),
          current.isChecked, current.isEffectivelyVisible,
          let locator = current.node.sourceLocator else {
        let visibility = rows.first(where: { predicate($0.node) }).map {
            "checked=\(storeHoverCheckedState($0.node.checked)), effective=\($0.isEffectivelyVisible), path=\($0.node.sourceLocator?.nodePath?.description ?? "nil")"
        } ?? "row missing"
        throw StoreHoverFixtureError.missingVisibleRow("row not effectively visible after refresh: \(visibility)")
    }
    return locator
}

@MainActor
private func installStoreHoverAssociatedViewport(_ state: MapState) async throws {
    // Match the production no-canvas bootstrap: source bounds come from the
    // real associated raster provider, then the real viewport loads pixels.
    await state.associatedMapLayers.bootstrapSourceExtents()
    let points = state.associatedMapLayers.sourceReferencePoints
    guard let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
          let minY = points.map(\.y).min(), let maxY = points.map(\.y).max(),
          minX.isFinite, maxX.isFinite, minY.isFinite, maxY.isFinite,
          minX < maxX, minY < maxY else {
        throw StoreHoverFixtureError.missingVisibleRow(
            "associated source bootstrap produced no finite camera bounds")
    }
    let viewport = RasterMapViewExtent(minX: minX, minY: minY, maxX: maxX, maxY: maxY,
        pixelWidth: 48, pixelHeight: 36)
    state.canvasPixelSize = CGSize(width: 48, height: 36)
    state.currentExtent = ViewportRequest(lowerLeft: MapPoint(x: minX, y: minY),
        upperRight: MapPoint(x: maxX, y: maxY), animated: false, padding: 0)
    await state.associatedMapLayers.updateViewport(viewport)
    await state.associatedMapLayers.refresh()
}

@MainActor
private func installStoreHoverGeometryViewport(_ store: WorkspaceStore, mapID: UUID,
                                               geometryName: String,
                                               client: BackendProcessClient) async throws {
    let state = store.mapState(for: mapID)
    try await storeHoverWaitUntil("initial Geometry source metadata") {
        state.projectGeometryMap.sources.contains { $0.snapshot != nil }
    } diagnostics: {
        storeHoverDiagnostic(store, mapID: mapID)
    }
    state.projectGeometryMap.pausePaging()

    guard let source = state.projectGeometryMap.sources.first(where: {
        $0.capture.geometryName == geometryName
    }) else {
        throw StoreHoverFixtureError.missingVisibleRow("Geometry capture for \(geometryName) is missing")
    }
    let sampleProvider = BackendProjectGeometryMapProvider(client: client, isCurrent: {
        store.projectSessionID == source.capture.projectSessionID
            && store.mapIdentityRequest(for: mapID) == source.capture.map
    })
    let sampleRequest = MapGeometryRequest(map: source.capture.map,
        geometryNode: source.capture.geometryNode, viewport: nil, contextToken: nil,
        planNodes: source.capture.planNodes, skipTopologyPage: true,
        skipFlowAreasPage: true)
    let sample = try await sampleProvider.load(sampleRequest, capture: source.capture)
    guard let line = sample.culverts?.features.first?.polyline, !line.isEmpty else {
        throw StoreHoverFixtureError.missingVisibleRow(
            "real Geometry provider returned no culvert line for \(geometryName)")
    }
    // Fit the actual culvert without pulling most of the independent 40k-cell
    // source into this hover-route test's first visible frame.
    let padding = 0.25
    let minX = line.map(\.x).min()! - padding
    let maxX = line.map(\.x).max()! + padding
    let minY = line.map(\.y).min()! - padding
    let maxY = line.map(\.y).max()! + padding
    let extent = ViewportRequest(lowerLeft: MapPoint(x: minX, y: minY),
        upperRight: MapPoint(x: maxX, y: maxY), animated: false, padding: 0)
    state.canvasPixelSize = CGSize(width: 320, height: 240)
    state.currentExtent = extent
    await state.projectGeometryMap.updateViewport(extent)
    try await Task.sleep(for: .milliseconds(200))
    state.projectGeometryMap.resumePaging()
}

@MainActor
private func storeHoverDiagnostic(_ store: WorkspaceStore, mapID: UUID) -> String {
    let state = store.mapState(for: mapID)
    let rows = state.sourceMapLayerRows.map { row in
        let locator = row.node.sourceLocator
        return "\(row.node.name){type=\(locator?.nodeType ?? "nil"),checked=\(storeHoverCheckedState(row.node.checked)),effective=\(row.isEffectivelyVisible),path=\(locator?.nodePath?.description ?? "nil")}"
    }.joined(separator: ";")
    let geometry = state.projectGeometryMap.sources.map { source in
        let snapshot = source.snapshot
        let flowState = snapshot.map {
            "\($0.flowAreasState.status.rawValue)/\($0.flowAreasState.effectiveVisible)"
        } ?? "nil"
        let culvertState = snapshot.map {
            "\($0.culvertsState.status.rawValue)/\($0.culvertsState.effectiveVisible)"
        } ?? "nil"
        return "\(source.capture.geometryName){loading=\(source.isLoading),error=\(source.error ?? "nil"),revision=\(source.geometryRevision ?? "nil"),token=\(source.contextToken?.isEmpty == false),flow=\(flowState),culvert=\(culvertState),cells=\(source.cells.count),barrels=\(source.culvertFeatures.count)}"
    }.joined(separator: ";")
    let associated = "error=\(state.associatedMapLayers.errorMessage ?? "nil"),preflight=\(state.associatedMapLayers.preflightDiagnostics),loading=\(state.associatedMapLayers.isLoading),entries=" + state.associatedMapLayers.entries.map {
        let entry = $0
        let status = entry.payload.map { $0.status.rawValue } ?? "nil"
        let revisionPresent = entry.payload.map { !$0.revision.isEmpty } ?? false
        return "\(entry.capture.associationNode.nodeName){status=\(status),checked=\(entry.payload?.isChecked ?? false),visible=\(entry.payload?.effectiveVisible ?? false),revision=\(revisionPresent),raster=\(entry.rasterLayer != nil),diag=\(entry.payload?.diagnostic ?? "nil")}"
    }.joined(separator: ";")
    let boundary = "error=\(state.boundaryMap.errorMessage ?? "nil"),loading=\(state.boundaryMap.isLoading),entries=" + state.boundaryMap.entries.map {
        let entry = $0
        return "\(entry.capture.boundaryNode.nodeName){status=\(entry.status.rawValue),lines=\(entry.visibleLines.count),diag=\(entry.diagnostic ?? "nil")}"
    }.joined(separator: ";")
    let extent = state.currentExtent.map { request in
        "\(request.lowerLeft.x),\(request.lowerLeft.y)..\(request.upperRight.x),\(request.upperRight.y)"
    } ?? "nil"
    return [
        "resultContext=\(state.resultSources.snapshot?.sources.contextToken.isEmpty == false)",
        "resultLoading=\(state.resultSources.isLoading)",
        "resultError=\(state.resultSources.errorMessage ?? "nil")",
        "sourceIdentity=\(state.resultSourceIdentity ?? "nil")",
        "canvas=\(state.canvasPixelSize)", "extent=\(extent)",
        "tree=[\(rows)]", "geometry=[\(geometry)]",
        "associated=[\(associated)]", "boundary=[\(boundary)]",
        "storeError=\(store.errorMessage ?? "nil")"
    ].joined(separator: ",")
}

private func storeHoverCheckedState(_ state: LayerTreeNode.CheckState?) -> String {
    switch state {
    case .some(.checked): return "checked"
    case .some(.unchecked): return "unchecked"
    case .some(.mixed): return "mixed"
    case .none: return "nil"
    }
}

@MainActor
private func assertStoreHoverRoute(_ store: WorkspaceStore, mapID: UUID,
                                   captureWorkflowIdentity: String,
                                   locator: CatalogTreeNodeLocator,
                                   kind: String) throws {
    let currentIdentity = store.mapSourceWorkflowIdentity(mapID)
    #expect(currentIdentity.contains("|result-context:"))
    #expect(captureWorkflowIdentity == currentIdentity)
    #expect(captureWorkflowIdentity != store.mapWorkflowIdentity(mapID))
    let extent = store.mapState(for: mapID).currentExtent
    let point = extent.map {
        MapPoint(x: ($0.lowerLeft.x + $0.upperRight.x) / 2,
                 y: ($0.lowerLeft.y + $0.upperRight.y) / 2)
    } ?? MapPoint(x: 0, y: 0)
    let flight = try #require(store.captureMapHoverIdentify(mapID: mapID,
        point: point, worldUnitsPerScreenPoint: 1,
        screenPoint: CGPoint(x: 1, y: 1), localEntries: []))
    #expect(flight.request.layers.contains { $0.node == locator && $0.kind == kind })
}

@MainActor
private func storeHoverWaitUntil(_ label: String, timeout: Duration = .seconds(30),
                                 condition: @MainActor () -> Bool,
                                 diagnostics: @MainActor () -> String = { "no diagnostics" }) async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(20))
    }
    if condition() { return }
    throw StoreHoverFixtureError.timedOut(label, diagnostics())
}

@MainActor
private func closeStore(_ store: WorkspaceStore) {
    store.requestClose()
    if store.showDiscardConfirmation { store.discardAndContinue() }
}

private enum StoreHoverFixtureError: Error, LocalizedError {
    case timedOut(String, String)
    case missingManifest(String)
    case missingProjectPath
    case missingVisibleRow(String)

    var errorDescription: String? {
        switch self {
        case .timedOut(let label, let diagnostics): return "Timed out waiting for \(label). State: \(diagnostics)"
        case .missingManifest(let name): return "Fixture is missing manifest \(name)."
        case .missingProjectPath: return "Fixture project path is missing."
        case .missingVisibleRow(let detail): return "Could not prepare a visible source row: \(detail)"
        }
    }
}
