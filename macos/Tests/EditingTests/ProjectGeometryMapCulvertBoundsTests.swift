import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

@MainActor
private final class ProjectGeometryCulvertBoundsProvider: ProjectGeometryMapProvider {
    func load(_ request: MapGeometryRequest,
              capture: ProjectGeometryMapCapture) async throws -> MapGeometrySnapshot {
        let savedExtent = GeometryTopologyExtent(minX: 1, minY: 2, maxX: 3, maxY: 4)
        let culvertLocator = CatalogTreeNodeLocator(rootName: capture.geometryNode.rootName,
            nodeType: "CulvertBarrelLayer", nodeName: "CulvertBarrelLayer",
            nodePath: (capture.geometryNode.nodePath ?? []) + [0],
            assetID: capture.geometryNode.assetID,
            parentGeometryAssetID: capture.geometryNode.assetID,
            parentGeometryNodePath: capture.geometryNode.nodePath,
            parentGeometryNodeName: capture.geometryNode.nodeName)
        let culvert = GeometryCulvertFeatureRow(id: "barrel:source:1", fid: 1,
            values: ["Name": "Saved Culvert"], polyline: [
                .init(x: 2, y: 2), .init(x: 3, y: 3)
            ])
        return MapGeometrySnapshot(mapID: request.map.mapID, mapIndex: request.map.mapIndex,
            mapName: request.map.mapName, mapType: request.map.mapType,
            projectCanonicalPath: request.map.projectPath, projectRevision: "project-revision",
            projectXmlSHA: request.map.projectXmlSHA,
            visualizationRevision: request.map.expectedVisualizationRevision,
            contextToken: "culvert-bounds-fixture", geometryNode: capture.geometryNode,
            geometryName: capture.geometryName, geometryCanonicalPath: capture.geometryCanonicalPath,
            geometryRevision: String(repeating: "A", count: 64), geometryChecked: true,
            geometryEffectiveVisible: true, extent: savedExtent, planNodes: request.planNodes,
            topologyState: .init(nodeID: nil, locator: nil, isChecked: false,
                effectiveVisible: false, status: .empty, diagnostic: nil),
            flowAreasState: .init(nodeID: nil, locator: nil, isChecked: false,
                effectiveVisible: false, status: .empty, diagnostic: nil),
            culvertsState: .init(nodeID: "culverts", locator: culvertLocator, isChecked: true,
                effectiveVisible: true, status: .available, diagnostic: nil),
            topology: nil, flowAreas: nil,
            culverts: .init(sourceExtent: savedExtent, sourceBarrelCount: 1,
                scannedSourceBarrelCount: 1, returnedBarrelCount: 1, invalidFeatureCount: 0,
                features: [culvert], complete: true, nextCursor: nil))
    }
}

@Suite(.serialized)
struct ProjectGeometryMapCulvertBoundsTests {
    @Test @MainActor
    func culvertDraftExtentFeedsSharedMapTransformWithoutMovingEstablishedReference() async throws {
        let fixture = try makeFixture()
        let mapState = MapState(kind: .project, id: fixture.capture.mapID)
        let session = mapState.projectGeometryMap
        await session.configure(map: fixture.map, workflowIdentity: fixture.capture.mapWorkflowIdentity,
            captures: [fixture.capture], provider: ProjectGeometryCulvertBoundsProvider(), isCurrent: { true })
        try await waitUntil { !session.isLoading && session.sources.first?.culvertsProgress.complete == true }

        let savedBounds = [MapPoint(x: 1, y: 2), MapPoint(x: 3, y: 4)]
        #expect(session.visiblePoints == savedBounds)
        mapState.establishReference(vectors: [], rasters: [])
        let establishedReference = try #require(mapState.referencePoints)
        #expect(establishedReference == savedBounds)

        let draftExtent = GeometryTopologyExtent(minX: 100, minY: 200, maxX: 300, maxY: 400)
        let draft = ProjectGeometryMapCulvertDraftPresentation(
            identity: fixture.capture.identity + "|parent-draft|editor-a|draft-a",
            captureIdentity: fixture.capture.identity,
            projectSessionID: fixture.capture.projectSessionID,
            mapID: fixture.capture.mapID,
            mapWorkflowIdentity: fixture.capture.mapWorkflowIdentity,
            geometryCanonicalPath: fixture.capture.geometryCanonicalPath,
            geometryRevision: String(repeating: "A", count: 64),
            extent: draftExtent, featureCount: 1)
        let cameraRevision = session.cameraExtentRevision
        session.setCulvertDraftPresentation(draft, captureIdentity: fixture.capture.identity)

        #expect(session.cameraExtentRevision == cameraRevision,
            "A culvert draft must not invalidate an established camera reference.")
        #expect(mapState.referencePoints == establishedReference)
        #expect(session.visiblePoints == [MapPoint(x: 100, y: 200), MapPoint(x: 300, y: 400)])
        #expect(mapState.transformPoints(vectors: [], rasters: []) == establishedReference,
            "The current camera retains its reference until the user requests a new fit.")

        mapState.resetViewport()
        let sharedVisiblePoints = mapState.transformPoints(vectors: [], rasters: [])
        #expect(sharedVisiblePoints == [MapPoint(x: 100, y: 200), MapPoint(x: 300, y: 400)])
        let canvasTransform = MapTransform(points: sharedVisiblePoints,
            size: CGSize(width: 800, height: 600), scale: 1, offset: .zero)
        let pointerTransform = MapTransform(points: mapState.transformPoints(vectors: [], rasters: []),
            size: CGSize(width: 800, height: 600), scale: 1, offset: .zero)
        #expect(pointerTransform.world(CGPoint(x: 415, y: 275))
            == canvasTransform.world(CGPoint(x: 415, y: 275)),
            "Canvas drawing and pointer conversion must use the same MapState points.")

        let wrongSource = ProjectGeometryMapCulvertDraftPresentation(
            identity: "stale-source", captureIdentity: fixture.capture.identity,
            projectSessionID: fixture.capture.projectSessionID, mapID: fixture.capture.mapID,
            mapWorkflowIdentity: fixture.capture.mapWorkflowIdentity,
            geometryCanonicalPath: fixture.capture.geometryCanonicalPath,
            geometryRevision: String(repeating: "B", count: 64),
            extent: .init(minX: -900, minY: -900, maxX: -800, maxY: -800), featureCount: 1)
        session.setCulvertDraftPresentation(wrongSource, captureIdentity: fixture.capture.identity)
        #expect(session.visiblePoints == [MapPoint(x: 100, y: 200), MapPoint(x: 300, y: 400)])

        session.setCulvertDraftPresentation(nil, captureIdentity: fixture.capture.identity)
        #expect(session.visiblePoints == savedBounds,
            "Closing the exact draft owner clears its extent override.")
        #expect(mapState.transformPoints(vectors: [], rasters: []) == savedBounds)
    }

    private func makeFixture() throws -> (map: MapTreeMapIdentity, capture: ProjectGeometryMapCapture) {
        let mapID = UUID()
        let map = MapTreeMapIdentity(projectPath: "/tmp/culvert-map-bounds/Model.ras",
            projectXml: "<Project />", projectXmlSHA: String(repeating: "B", count: 64),
            mapID: mapID.uuidString, mapIndex: 0, mapName: "Map A", mapType: "Project",
            expectedVisualizationRevision: String(repeating: "C", count: 64))
        let geometry = CatalogTreeNodeLocator(rootName: "Geometries", nodeType: "Geometry",
            nodeName: "Geometry A", nodePath: [0, 0], assetID: "/tmp/culvert-map-bounds/geometry.hdf")
        let capture = try ProjectGeometryMapCapture(projectSessionID: UUID(), mapID: mapID,
            mapWorkflowIdentity: "culvert-map-bounds", map: map, geometryNode: geometry,
            geometryAssetPath: "/tmp/culvert-map-bounds/geometry.hdf", geometryName: "Geometry A")
        return (map, capture)
    }

    @MainActor
    private func waitUntil(timeout: Duration = .seconds(5),
                           _ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw ProjectGeometryMapCulvertBoundsTestError.timedOut
    }
}

private enum ProjectGeometryMapCulvertBoundsTestError: Error {
    case timedOut
}
