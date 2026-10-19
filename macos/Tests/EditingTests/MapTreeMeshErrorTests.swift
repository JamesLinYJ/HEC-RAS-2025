import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

@MainActor
private final class DelayedMapTreeMeshErrorProvider: MapTreeMeshErrorProviding {
    private(set) var started = 0
    private(set) var cancelled = 0
    let response: MapTreeMeshErrorSnapshot

    init(response: MapTreeMeshErrorSnapshot) { self.response = response }

    func load(_ context: MapTreeMeshErrorContext) async throws -> MapTreeMeshErrorSnapshot {
        started += 1
        do { try await Task.sleep(for: .seconds(30)) }
        catch { cancelled += 1; throw error }
        return response
    }

    func set(_ context: MapTreeMeshErrorContext, checkMeshErrors: Bool?,
             maxFacesPerNodeEntry: Double?) async throws
        -> (MapTreeMeshErrorContext, MapTreeMeshErrorSnapshot) {
        (context, response)
    }
}

@Suite(.serialized)
struct MapTreeMeshErrorTests {
    @Test
    func mutationReceiptCanRebaseOnlyAnImplicitFlowAreaPath() throws {
        let fixture = try makeFixture()
        let original = fixture.context.flowAreaNode
        var implicit = original
        implicit.nodePath = nil
        let geometry = CatalogTreeNodeLocator(rootName: original.rootName,
            nodeType: "Geometry", nodeName: original.parentGeometryNodeName!,
            nodePath: original.parentGeometryNodePath, assetID: original.parentGeometryAssetID)
        let capture = try ProjectGeometryMapCapture(
            projectSessionID: fixture.context.projectSessionID,
            mapID: fixture.context.mapID,
            mapWorkflowIdentity: fixture.context.mapWorkflowIdentity,
            map: fixture.context.map,
            geometryNode: geometry,
            geometryAssetPath: fixture.context.sourcePath,
            geometryName: geometry.nodeName)
        let context = try MapTreeMeshErrorContext(capture: capture, flowAreaNode: implicit,
            sourceRevision: fixture.context.sourceRevision,
            contextToken: fixture.context.contextToken)

        var materialized = implicit
        materialized.nodePath = [0, 0]
        let rebased = try context.acceptingMutationReceipt(flowAreaNode: materialized,
            contextToken: context.contextToken)
        #expect(rebased.flowAreaNode == materialized)
        #expect(rebased.sourcePath == context.sourcePath)
        #expect(rebased.sourceRevision == context.sourceRevision)

        var changedOwner = materialized
        changedOwner.parentGeometryNodeName = "Different geometry"
        #expect(throws: MapTreeMeshErrorError.self) {
            try context.acceptingMutationReceipt(flowAreaNode: changedOwner,
                contextToken: context.contextToken)
        }

        var changedExistingPath = original
        changedExistingPath.nodePath = [9, 9]
        #expect(throws: MapTreeMeshErrorError.self) {
            try fixture.context.acceptingMutationReceipt(flowAreaNode: changedExistingPath,
                contextToken: fixture.context.contextToken)
        }
        #expect(throws: MapTreeMeshErrorError.self) {
            try context.acceptingMutationReceipt(flowAreaNode: materialized,
                contextToken: String(repeating: "f", count: 64))
        }
    }

    @Test
    func resultOwnedMutationReceiptRebasesTheResultContextToken() throws {
        let fixture = try makeFixture()
        let path = fixture.context.sourcePath
        let revision = String(repeating: "e", count: 64)
        let resultNode = CatalogTreeNodeLocator(rootName: "Results", nodeType: "Result",
            nodeName: "Run", nodePath: [0], assetID: path)
        let owner = try MapResultGeometryOwner(resultNode: resultNode,
            contextToken: String(repeating: "1", count: 64), selectionOverrides: nil,
            selectionIndex: 0, selectedResultPath: path, selectedResultRevision: revision)
        let geometryNode = CatalogTreeNodeLocator(rootName: "Results", nodeType: "Geometry",
            nodeName: "Geometry", nodePath: [0, 0], assetID: path,
            parentResultNodeType: "Result", parentResultAssetID: path,
            parentResultNodePath: [0], parentResultNodeName: "Run",
            parentResultRevision: revision)
        let capture = try ProjectGeometryMapCapture(
            projectSessionID: fixture.context.projectSessionID,
            mapID: fixture.context.mapID,
            mapWorkflowIdentity: fixture.context.mapWorkflowIdentity,
            map: fixture.context.map,
            geometryNode: geometryNode,
            geometryAssetPath: path,
            geometryName: "Geometry",
            resultOwner: owner)
        let implicitFlowArea = CatalogTreeNodeLocator(rootName: "Results",
            nodeType: "FlowAreaLayer", nodeName: "FlowAreaLayer", assetID: path,
            parentGeometryAssetID: path, parentGeometryNodePath: [0, 0],
            parentGeometryNodeName: "Geometry", parentResultNodeType: "Result",
            parentResultAssetID: path, parentResultNodePath: [0],
            parentResultNodeName: "Run", parentResultRevision: revision)
        let context = try MapTreeMeshErrorContext(capture: capture,
            flowAreaNode: implicitFlowArea, sourceRevision: revision,
            contextToken: owner.contextToken)
        var materialized = implicitFlowArea
        materialized.nodePath = [0, 0, 0]
        let refreshedToken = String(repeating: "f", count: 64)

        let accepted = try context.acceptingMutationReceipt(flowAreaNode: materialized,
            contextToken: refreshedToken)
        #expect(accepted.flowAreaNode == materialized)
        #expect(accepted.contextToken == refreshedToken)
        #expect(accepted.resultOwner?.contextToken == refreshedToken,
            "Subsequent Result reads must use the token for the newly committed .vis revision.")
        #expect(accepted.resultOwner?.selectedResultPath == path)
        #expect(accepted.resultOwner?.selectedResultRevision == revision.uppercased())
    }

    @Test @MainActor
    func computeSuspensionCancelsPendingReadersAndPreservesOnlyCompletedOverlayData() async throws {
        let fixture = try makeFixture()
        let provider = DelayedMapTreeMeshErrorProvider(response: fixture.snapshot)
        let session = MapTreeMeshErrorSession()
        session.configureOverlayContexts([fixture.context], provider: provider)
        try await waitUntil { provider.started == 1 && session.isLoadingOverlays }

        session.suspendSourceReads()
        try await waitUntil { provider.cancelled == 1 }
        #expect(session.sourceReadsSuspended)
        #expect(!session.isLoadingOverlays)
        #expect(session.overlaySnapshots.isEmpty,
            "A reply cancelled before completion cannot be installed as completed diagnostics.")

        session.configureOverlayContexts([fixture.context], provider: provider)
        #expect(provider.started == 1,
            "Source changes during the writer lease may update desired contexts but cannot start HDF reads.")
        session.resumeSourceReads()
        try await waitUntil { provider.started == 2 && session.isLoadingOverlays }
        session.clear()
        try await waitUntil { provider.cancelled == 2 }
        #expect(session.overlaySnapshots.isEmpty)
    }

    @Test
    func overlayRequiresExactMapAndPersistedVisibilityAndZoomUsesRealCellExtent() throws {
        let fixture = try makeFixture()
        #expect(MapTreeMeshErrorOverlayProjection.isVisible(fixture.snapshot, mapID: fixture.mapID))
        #expect(!MapTreeMeshErrorOverlayProjection.isVisible(fixture.snapshot, mapID: UUID()))

        let hidden = makeSnapshot(mapID: fixture.mapID, isChecked: false,
            isEffectivelyVisible: true, status: "available")
        let protected = makeSnapshot(mapID: fixture.mapID, isChecked: nil,
            isEffectivelyVisible: nil, status: "writerProtected")
        #expect(!MapTreeMeshErrorOverlayProjection.isVisible(hidden, mapID: fixture.mapID))
        #expect(!MapTreeMeshErrorOverlayProjection.isVisible(protected, mapID: fixture.mapID))

        let viewport = try #require(MapTreeMeshErrorNavigation.viewport(for: fixture.issue,
            current: ViewportRequest(lowerLeft: MapPoint(x: -10, y: -10),
                upperRight: MapPoint(x: 10, y: 10))))
        #expect(viewport.lowerLeft == MapPoint(x: -1, y: -1))
        #expect(viewport.upperRight == MapPoint(x: 3, y: 3),
            "The source CellsExtent is doubled around its center, preserving actual world coordinates.")
    }

    @Test @MainActor
    func generatedDraftDiagnosticsCarryTheirExactPresentationAndIncidentCells() throws {
        let meshMap = GeometryMeshMapData(extent: .init(minX: 0, minY: 0, maxX: 2, maxY: 2),
            topology: .empty,
            cells: [.init(id: "flow-area-row:0:cell:7", flowAreaID: "flow-area-row:0",
                flowAreaName: "Current mesh", meshIndex: 0, cellIndex: 7,
                coordinates: [.init(x: 0, y: 0), .init(x: 2, y: 0), .init(x: 2, y: 2)])],
            totalCellCount: 1, renderedCellCount: 1, omittedCellCount: 0,
            invalidCandidateCount: 0, cellLimit: 12_000, vertexLimit: 1_000_000)
        let meshSnapshot = GeometryMeshSnapshot(revision: String(repeating: "c", count: 64),
            draftState: "opaque generated mesh child draft", topologyFingerprint: "mesh-topology",
            canEdit: true, isDirty: true,
            flowAreas: [.init(id: "flow-area-row:0", rowIndex: 0, name: "Current mesh",
                targetedCellSpacing: 1, hasMesh: true, cellCount: 1, faceCount: 3,
                nodeCount: 3, extent: .init(minX: 0, minY: 0, maxX: 2, maxY: 2),
                hasMeshErrors: false, hasPropertyTables: false,
                propertyTablesQueuedForParentSave: false, propertyTablesPinned: false, metadata: [])],
            regions: .init(featureKind: "region", columns: [], editableFields: [], rows: []),
            selectedRegionIDs: [], patchSizing: nil,
            generationReport: .init(succeeded: true, partial: false, meshWasReplaced: true,
                cellCount: 1, messages: []), prepareSummary: nil, map: meshMap)
        let presentationIdentity = try #require(MapTreeMeshErrorDraftIdentity.presentationIdentity(
            captureIdentity: "exact-geometry-capture", sourceRevision: meshSnapshot.revision,
            resultIdentity: "mesh-generation-42", snapshot: meshSnapshot))

        let fixture = try makeFixture()
        let sourceCell = GeometryMeshDegreeCell(cellIndex: 7,
            coordinates: [.init(x: 0, y: 0), .init(x: 2, y: 0), .init(x: 2, y: 2)])
        let scan = GeometryMeshDegreeScan(maxFacesPerNode: fixture.snapshot.maxFacesPerNode,
            issues: [.init(id: "flow-area-row:0:node:1", flowAreaID: "flow-area-row:0",
                flowAreaName: "Current mesh", meshIndex: 0, nodeIndex: 1, faceCount: 6,
                x: 1, y: 1, cellsExtent: .init(minX: 0, minY: 0, maxX: 2, maxY: 2),
                cells: [sourceCell])])
        let draft = MapTreeMeshErrorDraftProjection.install(scan, on: fixture.snapshot,
            draftIdentity: presentationIdentity)

        #expect(draft.geometryMeshDraftIdentity == presentationIdentity)
        #expect(draft.status == "available")
        #expect(draft.issues.count == 1)
        #expect(draft.issues[0].id == "flow-area-row:0:node:1")
        #expect(draft.issues[0].cells.map(\.cellIndex) == [7])
        #expect(draft.issues[0].cells[0].coordinates == sourceCell.coordinates.map {
            MapTreeMeshErrorCoordinate(x: $0.x, y: $0.y)
        })

        var savedHDFOverlay = fixture.snapshot
        savedHDFOverlay.geometryMeshDraftIdentity = nil
        #expect(savedHDFOverlay.geometryMeshDraftIdentity != draft.geometryMeshDraftIdentity,
            "Persisted-HDF diagnostics cannot masquerade as the active generated child draft.")
    }

    @Test
    func meshErrorContextUsesVisibleGeneratedDraftAndNeverFallsBackWhenItsMapIsMissing() throws {
        let fixture = try makeFixture()
        let meshMap = GeometryMeshMapData(extent: .init(minX: 0, minY: 0, maxX: 1, maxY: 1),
            topology: .empty,
            cells: [.init(id: "flow-area-row:0:cell:0", flowAreaID: "flow-area-row:0",
                flowAreaName: "Generated", meshIndex: 0, cellIndex: 0,
                coordinates: [.init(x: 0, y: 0), .init(x: 1, y: 0), .init(x: 1, y: 1)])],
            totalCellCount: 1, renderedCellCount: 1, omittedCellCount: 0,
            invalidCandidateCount: 0, cellLimit: 12_000, vertexLimit: 1_000_000)
        let geometryNode = CatalogTreeNodeLocator(rootName: fixture.context.flowAreaNode.rootName,
            nodeType: "Geometry", nodeName: fixture.context.flowAreaNode.parentGeometryNodeName!,
            nodePath: fixture.context.flowAreaNode.parentGeometryNodePath,
            assetID: fixture.context.sourcePath)
        let capture = try ProjectGeometryMapCapture(projectSessionID: fixture.context.projectSessionID,
            mapID: fixture.context.mapID, mapWorkflowIdentity: fixture.context.mapWorkflowIdentity,
            map: fixture.context.map, geometryNode: geometryNode,
            geometryAssetPath: fixture.context.sourcePath, geometryName: geometryNode.nodeName)
        let savedFlowAreas = MapGeometryLayerState(nodeID: fixture.context.flowAreaNode.sourceIdentity,
            locator: fixture.context.flowAreaNode, isChecked: false, effectiveVisible: false,
            status: .empty, diagnostic: nil)
        let geometry = MapGeometrySnapshot(mapID: fixture.context.mapID.uuidString,
            mapIndex: fixture.context.map.mapIndex, mapName: fixture.context.map.mapName,
            mapType: fixture.context.map.mapType,
            projectCanonicalPath: fixture.context.map.projectPath,
            projectRevision: String(repeating: "d", count: 64),
            projectXmlSHA: fixture.context.map.projectXmlSHA,
            visualizationRevision: fixture.context.map.expectedVisualizationRevision,
            contextToken: fixture.context.contextToken, geometryNode: geometryNode,
            geometryName: "Geometry", geometryCanonicalPath: fixture.context.sourcePath,
            geometryRevision: fixture.context.sourceRevision,
            geometryChecked: true, geometryEffectiveVisible: true, extent: nil, planNodes: nil,
            topologyState: .init(nodeID: nil, locator: nil, isChecked: false,
                effectiveVisible: false, status: .empty, diagnostic: nil),
            flowAreasState: savedFlowAreas,
            culvertsState: .init(nodeID: nil, locator: nil, isChecked: false,
                effectiveVisible: false, status: .empty, diagnostic: nil),
            topology: nil, flowAreas: nil, culverts: nil)
        var source = ProjectGeometryMapSourceState(capture: capture, snapshot: geometry)
        let draftIdentity = "exact-generated-preview-17"
        source.flowAreaGenerationPresentation = .init(identity: draftIdentity,
            phase: .childDraft, map: meshMap)

        let contexts = MapTreeMeshErrorContext.checkedVisibleContexts(in: [source])
        #expect(contexts.count == 1,
            "The actually displayed generated child draft is eligible even when the saved FlowArea row is unchecked/empty.")
        #expect(contexts.first?.geometryMeshDraftIdentity == draftIdentity)

        source.flowAreaGenerationPresentation = .init(identity: "draft-without-map",
            phase: .childDraft, map: nil)
        #expect(MapTreeMeshErrorContext.checkedVisibleContexts(in: [source]).isEmpty,
            "A generated draft without its current map cannot fall back to persisted HDF diagnostics.")
        #expect(!MapTreeMeshErrorOverlayProjection.isVisible(fixture.snapshot,
            mapID: fixture.mapID, sources: [source]),
            "Previously accepted saved-HDF rows are hidden as soon as a generated draft replaces them.")
    }

    private func makeFixture() throws -> (context: MapTreeMeshErrorContext, mapID: UUID,
                                          snapshot: MapTreeMeshErrorSnapshot, issue: MapTreeMeshErrorIssue) {
        let projectSessionID = UUID()
        let mapID = UUID()
        let path = "/tmp/map-tree-mesh-errors/Geometry.hdf"
        let geometry = CatalogTreeNodeLocator(rootName: "Geometries", nodeType: "Geometry",
            nodeName: "Geometry", nodePath: [0], assetID: path)
        let map = MapTreeMapIdentity(projectPath: "/tmp/map-tree-mesh-errors/Project.ras",
            projectXml: "<Project />", projectXmlSHA: String(repeating: "a", count: 64),
            mapID: mapID.uuidString, mapIndex: 0, mapName: "Map", mapType: "Project",
            expectedVisualizationRevision: String(repeating: "b", count: 64))
        let capture = try ProjectGeometryMapCapture(projectSessionID: projectSessionID,
            mapID: mapID, mapWorkflowIdentity: "mesh-errors-workflow", map: map,
            geometryNode: geometry, geometryAssetPath: path, geometryName: "Geometry")
        let flowArea = CatalogTreeNodeLocator(rootName: "Geometries", nodeType: "FlowAreaLayer",
            nodeName: "FlowAreaLayer", nodePath: [0, 0], assetID: path,
            parentGeometryAssetID: path, parentGeometryNodePath: [0], parentGeometryNodeName: "Geometry")
        let issue = MapTreeMeshErrorIssue(id: "0:1", meshIndex: 0, nodeIndex: 1, faceCount: 6,
            node: .init(x: 1, y: 1), cellsMinX: 0, cellsMinY: 0, cellsMaxX: 2, cellsMaxY: 2,
            cells: [.init(cellIndex: 1, coordinates: [.init(x: 0, y: 0), .init(x: 2, y: 0),
                .init(x: 2, y: 2), .init(x: 0, y: 2)])])
        let context = try MapTreeMeshErrorContext(capture: capture, flowAreaNode: flowArea,
            sourceRevision: String(repeating: "c", count: 64), contextToken: "mesh-context")
        let snapshot = makeSnapshot(mapID: mapID, isChecked: true,
            isEffectivelyVisible: true, status: "available", context: context, issues: [issue])
        return (context, mapID, snapshot, issue)
    }

    private func makeSnapshot(mapID: UUID, isChecked: Bool?, isEffectivelyVisible: Bool?,
                              status: String, context: MapTreeMeshErrorContext? = nil,
                              issues: [MapTreeMeshErrorIssue] = []) -> MapTreeMeshErrorSnapshot {
        let locator = context?.flowAreaNode ?? CatalogTreeNodeLocator(rootName: "Geometries",
            nodeType: "FlowAreaLayer", nodeName: "FlowAreaLayer", nodePath: [0, 0],
            assetID: "/tmp/map-tree-mesh-errors/Geometry.hdf",
            parentGeometryAssetID: "/tmp/map-tree-mesh-errors/Geometry.hdf",
            parentGeometryNodePath: [0], parentGeometryNodeName: "Geometry")
        return MapTreeMeshErrorSnapshot(projectSessionID: context?.projectSessionID.uuidString ?? UUID().uuidString,
            mapWorkflowIdentity: context?.mapWorkflowIdentity ?? "mesh-errors-workflow",
            contextToken: context?.contextToken ?? "mesh-context",
            projectCanonicalPath: "/tmp/map-tree-mesh-errors/Project.ras",
            projectRevision: String(repeating: "d", count: 64),
            projectXmlSHA: String(repeating: "a", count: 64),
            visualizationRevision: String(repeating: "b", count: 64),
            mapID: mapID.uuidString, mapIndex: 0, mapName: "Map", mapType: "Project",
            flowAreaNode: locator, sourcePath: context?.sourcePath ?? "/tmp/map-tree-mesh-errors/Geometry.hdf",
            sourceRevision: context?.sourceRevision ?? String(repeating: "c", count: 64),
            checkMeshErrors: true, maxFacesPerNode: 5, isChecked: isChecked,
            isEffectivelyVisible: isEffectivelyVisible, status: status, diagnostic: nil,
            issues: issues, totalIssueCount: issues.count, omittedIssueCount: 0,
            previousVisualizationRevision: nil)
    }

    @MainActor
    private func waitUntil(timeout: Duration = .seconds(5),
                           _ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw MapTreeMeshErrorTestError.timedOut
    }
}

private enum MapTreeMeshErrorTestError: Error { case timedOut }
