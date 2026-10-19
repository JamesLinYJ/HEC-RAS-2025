import Foundation
import Testing
@testable import HECRAS2025

struct ProjectGeometryMapOwnerTests {
    @Test
    func focusedPlanGeometryAcceptsExactImplicitPlanLocator() throws {
        let mapID = UUID()
        let map = map(mapID: mapID, type: "Plan")
        let plan = CatalogTreeNodeLocator(rootName: "Focused Plans", nodeType: "Plan",
            nodeName: "Plan A", assetID: "/tmp/plan-a.p##")
        let geometry = CatalogTreeNodeLocator(rootName: "Focused Plans", nodeType: "Geometry",
            nodeName: "Geometry A", nodePath: [0, 0], assetID: "/tmp/geometry-a.hdf",
            parentPlanAssetID: "/tmp/plan-a.p##", parentPlanNodeName: "Plan A")

        let capture = try ProjectGeometryMapCapture(projectSessionID: UUID(), mapID: mapID,
            mapWorkflowIdentity: "plan-workflow", map: map, geometryNode: geometry,
            geometryAssetPath: "/tmp/geometry-a.hdf", geometryName: "Geometry A",
            planNodes: [plan])

        #expect(capture.planNodes == [plan])
    }

    @Test
    func matchingGeometryRequiresTheCompleteMultiPlanOwnerSetAndExactAssociation() throws {
        let mapID = UUID()
        let map = map(mapID: mapID, type: "Plan")
        let first = CatalogTreeNodeLocator(rootName: "Focused Plans", nodeType: "Plan",
            nodeName: "Plan A", nodePath: [0], assetID: "/tmp/plan-a.p##")
        let second = CatalogTreeNodeLocator(rootName: "Focused Plans", nodeType: "Plan",
            nodeName: "Plan B", assetID: "/tmp/plan-b.p##")
        let geometry = CatalogTreeNodeLocator(rootName: "Matching Layers", nodeType: "Geometry",
            nodeName: "Shared Geometry", nodePath: [1, 0], assetID: "/tmp/shared.hdf",
            associationAssetID: "/tmp/shared.hdf", associationKind: "Geometry")

        let capture = try ProjectGeometryMapCapture(projectSessionID: UUID(), mapID: mapID,
            mapWorkflowIdentity: "matching-plan-workflow", map: map, geometryNode: geometry,
            geometryAssetPath: "/tmp/shared.hdf", geometryName: "Shared Geometry",
            planNodes: [first, second])
        #expect(capture.planNodes == [first, second])

        #expect(throws: ProjectGeometryMapCaptureError.self) {
            try ProjectGeometryMapCapture(projectSessionID: UUID(), mapID: mapID,
                mapWorkflowIdentity: "single-plan-matching", map: map, geometryNode: geometry,
                geometryAssetPath: "/tmp/shared.hdf", geometryName: "Shared Geometry",
                planNodes: [first])
        }
    }

    @Test
    func resultGeometryRequiresExactResultOwnerAndImmediateTreeChild() throws {
        let mapID = UUID()
        let map = map(mapID: mapID, type: "Geometry")
        let resultPath = "/tmp/result.hdf"
        let revision = String(repeating: "A", count: 64)
        let result = CatalogTreeNodeLocator(rootName: "Results", nodeType: "Result",
            nodeName: "Plan 01", nodePath: [0, 1], assetID: resultPath)
        let owner = try MapResultGeometryOwner(resultNode: result, contextToken: "chart-context",
            selectionOverrides: nil, selectionIndex: 0,
            selectedResultPath: resultPath, selectedResultRevision: revision)
        let child = CatalogTreeNodeLocator(rootName: "Results", nodeType: "Geometry",
            nodeName: "Geometry", nodePath: [0, 1, 0], assetID: resultPath,
            parentResultNodeType: "Result", parentResultAssetID: resultPath,
            parentResultNodePath: [0, 1], parentResultNodeName: "Plan 01",
            parentResultRevision: revision)

        let capture = try ProjectGeometryMapCapture(projectSessionID: UUID(), mapID: mapID,
            mapWorkflowIdentity: "result-workflow", map: map, geometryNode: child,
            geometryAssetPath: resultPath, geometryName: "Geometry", resultOwner: owner)
        #expect(capture.resultOwner == owner)

        let flattened = CatalogTreeNodeLocator(rootName: "Focused Geometries", nodeType: "Geometry",
            nodeName: "Geometry", nodePath: [2, 0], assetID: resultPath,
            parentResultNodeType: "Result", parentResultAssetID: resultPath,
            parentResultNodePath: [0, 1], parentResultNodeName: "Plan 01",
            parentResultRevision: revision)
        #expect(throws: ProjectGeometryMapCaptureError.self) {
            try ProjectGeometryMapCapture(projectSessionID: UUID(), mapID: mapID,
                mapWorkflowIdentity: "flattened-result-workflow", map: map,
                geometryNode: flattened, geometryAssetPath: resultPath,
                geometryName: "Geometry", resultOwner: owner)
        }
    }

    private func map(mapID: UUID, type: String) -> MapTreeMapIdentity {
        MapTreeMapIdentity(projectPath: "/tmp/model.ras", projectXml: "<Project />",
            projectXmlSHA: String(repeating: "B", count: 64), mapID: mapID.uuidString,
            mapIndex: 0, mapName: "Map A", mapType: type,
            expectedVisualizationRevision: String(repeating: "C", count: 64))
    }
}
