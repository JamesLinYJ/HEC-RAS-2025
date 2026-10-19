import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

struct ResultGroupPlanOwnerTests {
    @Test @MainActor
    func aTopLevelResultGroupUsesItsOwnExactProjectPlanAsset() throws {
        let path = "/private/tmp/result-owner/Plans/方案 A.h5"
        let node = CatalogTreeNodeLocator(rootName: "Layers", nodeType: "MultiResult",
            nodeName: "方案 A", nodePath: [2, 0], assetID: path)
        let owner = try #require(WorkspaceStore.exactPlanOwnerForResultGroup(node))
        #expect(owner.assetID == SourceFilePaths.canonical(URL(fileURLWithPath: path)))
        #expect(owner.name == "方案 A")
    }

    @Test @MainActor
    func aParentedResultGroupKeepsItsCapturedPlanAndRejectsIncompleteOrEmbeddedOwners() throws {
        let parentPath = "/private/tmp/result-owner/Plans/Parent.h5"
        var node = CatalogTreeNodeLocator(rootName: "Focused Plans", nodeType: "MultiResult",
            nodeName: "Parent", nodePath: [0, 0, 4], assetID: parentPath,
            parentPlanAssetID: parentPath, parentPlanNodePath: [0, 0], parentPlanNodeName: "Parent")
        let owner = try #require(WorkspaceStore.exactPlanOwnerForResultGroup(node))
        #expect(owner.assetID == SourceFilePaths.canonical(URL(fileURLWithPath: parentPath)))
        #expect(owner.name == "Parent")
        node.parentPlanAssetID = nil
        #expect(WorkspaceStore.exactPlanOwnerForResultGroup(node) == nil,
            "An incomplete parent cannot fall back to the group's own asset.")
        node.parentPlanAssetID = parentPath
        node.parentResultNodeType = "Result"
        node.parentResultAssetID = "/private/tmp/result-owner/Results/Parent.h5"
        #expect(WorkspaceStore.exactPlanOwnerForResultGroup(node) == nil,
            "A Result's embedded Plan must not become a current project Plan owner.")
    }
}
