import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

struct BoundaryPlanOwnerCaptureTests {
    @Test
    func focusedPlanBoundaryAcceptsItsExactTypedAssociationAndDirectLocator() throws {
        let associated = try capture(node())
        #expect(associated.sourcePath == sourcePath)
        #expect(associated.boundaryNode.parentPlanNodePath == [0, 0])
        var direct = node()
        direct.associationKind = nil
        direct.associationAssetID = nil
        #expect(try capture(direct).sourcePath == associated.sourcePath)
    }

    @Test
    func focusedPlanBoundaryRejectsPartialWrongFileWrongKindAndWrongParentLocators() {
        var partial = node()
        partial.associationAssetID = nil
        var wrongKind = node()
        wrongKind.associationKind = "Terrain"
        var wrongFile = node()
        wrongFile.associationAssetID = "/private/tmp/boundary-plan-owner/Other.h5"
        var wrongModel = node()
        wrongModel.assetID = "/private/tmp/boundary-plan-owner/Other.h5"
        var wrongParent = node()
        wrongParent.parentPlanNodePath = [0, 1]
        var partialResult = node()
        partialResult.parentResultNodeType = "MultiResult"
        for invalid in [partial, wrongKind, wrongFile, wrongModel, wrongParent, partialResult] {
            #expect(throws: (any Error).self) { try capture(invalid) }
        }
    }

    private var sourcePath: String { "/private/tmp/boundary-plan-owner/Boundary.h5" }

    private func node() -> CatalogTreeNodeLocator {
        .init(rootName: "Focused Plans", nodeType: "BoundaryCondition",
            nodeName: "Boundary", nodePath: [0, 0, 3], assetID: sourcePath,
            parentPlanAssetID: "/private/tmp/boundary-plan-owner/Plan.h5",
            parentPlanNodePath: [0, 0], parentPlanNodeName: "Plan",
            associationAssetID: sourcePath, associationKind: "BoundaryCondition")
    }

    private func capture(_ node: CatalogTreeNodeLocator) throws -> BoundaryMapCapture {
        let map = MapTreeMapIdentity(projectPath: "/private/tmp/boundary-plan-owner/Project.ras",
            projectXml: "<Project />", projectXmlSHA: String(repeating: "A", count: 64),
            mapID: "7AE105D6-E68C-4C31-891B-DAF2B3A635E6", mapIndex: 0,
            mapName: "Plan Map", mapType: "Plan",
            expectedVisualizationRevision: String(repeating: "B", count: 64))
        return try BoundaryMapCapture(projectSessionID: UUID(), mapWorkflowIdentity: "same-plan-map",
            map: map, boundaryNode: node, sourcePath: sourcePath,
            sourceRevision: String(repeating: "C", count: 64),
            isChecked: true, effectiveVisible: true)
    }
}
