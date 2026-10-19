import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

struct CatalogModelActionRoutingTests {
    @Test
    func treeActionsResolveOnlyExactSourceModelAssets() {
        let geometry = ProjectAsset(
            url: URL(fileURLWithPath: "/project/Geometries/Reach.h5"), section: .geometries)
        let result = ProjectAsset(
            url: URL(fileURLWithPath: "/project/Results/Reach.h5"), section: .results)

        let geometryNode = LayerTreeNode(id: "geometry-row", sourceClass: "GeometryNode",
            name: "same display name", assetID: geometry.id)
        #expect(CatalogModelActionTarget.resolve(node: geometryNode, assets: [result, geometry])
            == CatalogModelActionTarget(asset: geometry, kind: .geometry))

        let resultAtGeometryNode = LayerTreeNode(id: "stale-row", sourceClass: "GeometryNode",
            name: "same display name", assetID: result.id)
        #expect(CatalogModelActionTarget.resolve(node: resultAtGeometryNode, assets: [result, geometry]) == nil)

        let resultNode = LayerTreeNode(id: "result-row", sourceClass: "ResultNode",
            name: "same display name", assetID: geometry.id)
        let embeddedFlowArea = LayerTreeNode(id: "flow-area", sourceClass: "FlowAreaNode",
            name: "same display name", assetID: geometry.id)
        #expect(CatalogModelActionTarget.resolve(node: resultNode, assets: [geometry]) == nil)
        #expect(CatalogModelActionTarget.resolve(node: embeddedFlowArea, assets: [geometry]) == nil)
    }

    @Test
    func treeActionMayResolveCanonicalPathAliasButNeverDisplayName() {
        let asset = ProjectAsset(
            url: URL(fileURLWithPath: "/project/Geometries/Reach.h5"), section: .geometries)
        let pathAlias = LayerTreeNode(id: "geometry-row", sourceClass: "ObservableGeometry",
            name: asset.name, assetID: "/project/Geometries/../Geometries/Reach.h5")
        #expect(CatalogModelActionTarget.resolve(node: pathAlias, assets: [asset])
            == CatalogModelActionTarget(asset: asset, kind: .geometry))

        let nameOnly = LayerTreeNode(id: "geometry-row", sourceClass: "ObservableGeometry",
            name: asset.name, assetID: asset.name)
        #expect(CatalogModelActionTarget.resolve(node: nameOnly, assets: [asset]) == nil)
    }

    @Test
    func menuAndInspectorKeepDistinctCloneAndDuplicateRoutes() {
        for kind in CatalogManagedModelKind.allCases {
            #expect(CatalogModelActionExecutionRoute.action(for: .duplicate, caller: .projectTree,
                kind: kind, availableActions: ["duplicate"]) == "duplicate")
            #expect(CatalogModelActionExecutionRoute.action(for: .duplicate, caller: .catalog,
                kind: kind, availableActions: ["duplicate"]) == "duplicate")
            #expect(CatalogModelActionExecutionRoute.action(for: .duplicate, caller: .projectTree,
                kind: kind, availableActions: ["clone"]) == nil)
        }
        #expect(CatalogModelActionExecutionRoute.action(for: .duplicate, caller: .inspector,
            kind: .geometry, availableActions: ["clone"]) == "clone")
        #expect(CatalogModelActionExecutionRoute.action(for: .clone, caller: .inspector,
            kind: .geometry, availableActions: ["clone"]) == "clone")

        // A tree/catalog Duplicate must not degrade to the inspector's
        // separate Clone route if the source doesn't report duplicate.
        #expect(CatalogModelActionExecutionRoute.action(for: .duplicate, caller: .projectTree,
            kind: .plan, availableActions: nil) == nil)
        #expect(CatalogModelActionExecutionRoute.action(for: .rename, caller: .catalog,
            kind: .terrain, availableActions: nil) == nil)
    }

    @Test @MainActor
    func oldPresentationCannotSurviveAssetRevisionOrProjectReplacement() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("catalog-action-context-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let firstProject = try makeProject(folder.appendingPathComponent("first"), name: "First")
        let secondProject = try makeProject(folder.appendingPathComponent("second"), name: "Second")
        let store = WorkspaceStore(system: SourceWorkflowFixtureServices(
            recoveryFolder: folder.appendingPathComponent("Trash")))
        store.requestOpen(firstProject)
        try await waitForProject(store)

        let asset = try #require(store.assets.first { $0.section == .geometries })
        let oldPresentation = try #require(CatalogModelActionPresentation.make(asset: asset,
            kind: .geometry, intent: .duplicate, caller: .projectTree, store: store))
        store.catalogModelActionPresentation = oldPresentation
        #expect(CatalogModelActionContextStamp.capture(oldPresentation, store: store) != nil)

        store.refreshAssets()
        #expect(CatalogModelActionContextStamp.capture(oldPresentation, store: store) == nil)

        let currentAsset = try #require(store.assets.first { $0.section == .geometries })
        let presentationBeforeReplacement = try #require(CatalogModelActionPresentation.make(
            asset: currentAsset, kind: .geometry, intent: .delete, caller: .catalog, store: store))
        store.catalogModelActionPresentation = presentationBeforeReplacement
        let previousSession = store.projectSessionID
        store.requestOpen(secondProject)
        try await waitForProject(store)

        #expect(store.projectSessionID != previousSession)
        #expect(store.catalogModelActionPresentation == nil)
        #expect(CatalogModelActionContextStamp.capture(presentationBeforeReplacement, store: store) == nil)
    }
}

@MainActor
private func makeProject(_ folder: URL, name: String) throws -> URL {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let project = folder.appendingPathComponent(name + ".ras")
    try Data("<Project><Description>Context test</Description></Project>".utf8).write(to: project)
    let geometryFolder = folder.appendingPathComponent("Geometries", isDirectory: true)
    try FileManager.default.createDirectory(at: geometryFolder, withIntermediateDirectories: true)
    try Data("identity only".utf8).write(to: geometryFolder.appendingPathComponent("Reach.h5"))
    return project
}

@MainActor
private func waitForProject(_ store: WorkspaceStore) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while store.isOpeningProject && ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(!store.isOpeningProject)
}
