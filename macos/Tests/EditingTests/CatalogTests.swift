import Foundation
import Testing
import RASWorkspaceCore
@testable import HECRAS2025

@MainActor
private final class CatalogFixtureProvider: LayerTreeProvider {
    var snapshot: LayerTreeSnapshot
    var response: LayerTreeSnapshot?
    var failure: (any Error)?
    var restoredNodeIDs: [String] = []
    var loadedModes: [String] = []
    init(_ snapshot: LayerTreeSnapshot) { self.snapshot = snapshot }
    func load(_ context: LayerTreeContext) async throws -> LayerTreeSnapshot {
        loadedModes.append(context.mode); return snapshot
    }
    func perform(_ action: LayerTreeAction, context: LayerTreeContext) async throws -> LayerTreeSnapshot {
        guard case .saveBackupAsNewGeometry(let id) = action else { throw CocoaError(.featureUnsupported) }
        restoredNodeIDs.append(id)
        if let failure { throw failure }
        return response ?? snapshot
    }
}

struct CatalogTests {
    @Test @MainActor
    func catalogBackupSelectionDoesNotReplaceProjectTreeSelection() async throws {
        let workspace = WorkspaceStore()
        let backup = LayerTreeNode(id: "backup-1", sourceClass: "BackupNodeVM", name: "原始备份名",
            backupSummary: .init(filename: "/task-fixture/geometry/backup.h5", dateCreated: "parent creation date", dateLastModified: "parent modification date"))
        let geometry = LayerTreeNode(id: "geometry-1", sourceClass: "ObservableGeometry", name: "原始几何名",
            children: [.init(id: "backup-root", sourceClass: "BackupRootNodeVM", name: "Backups", localizeName: true, children: [backup])])
        let catalog = CatalogFixtureProvider(.init(roots: [geometry], selection: .node(backup.id)))
        let tree = CatalogFixtureProvider(.init(roots: [.init(id: "project-tree-node", sourceClass: "FolderNode", name: "Project Tree")], selection: .node("project-tree-node")))
        let projectURL = URL(fileURLWithPath: "/task-fixture/project.ras")
        let context = LayerTreeContext(projectSessionID: workspace.projectSessionID, projectURL: projectURL, mapID: MapState.projectMapID, mode: "Catalog", focusedGeometryIDs: [], focusedPlanIDs: [])
        await workspace.catalogTreeSession.load(provider: catalog, context: context)
        await workspace.layerTreeSession.load(provider: tree, context: .init(projectSessionID: context.projectSessionID, projectURL: projectURL, mapID: context.mapID, mode: "Project", focusedGeometryIDs: [], focusedPlanIDs: []))
        #expect(workspace.inspectorTreeSession.selectedNode?.name == "原始备份名")
        #expect(workspace.inspectorTreeSession.selectedNode?.backupSummary?.dateCreated == "parent creation date")
        #expect(workspace.catalogTreeSession.expandedNodeIDs == [geometry.id, "backup-root"])
        workspace.catalogTreeSession.setExpanded(geometry.id, expanded: false)
        #expect(!workspace.catalogTreeSession.expandedNodeIDs.contains(geometry.id))
        workspace.sidebarSection = .projectTree
        #expect(workspace.inspectorTreeSession.selectedNode?.id == "project-tree-node")
        workspace.sidebarSection = .catalog
        #expect(workspace.inspectorTreeSession.selectedNode?.id == backup.id)
        #expect(!workspace.catalogTreeSession.expandedNodeIDs.contains(geometry.id))
        #expect(catalog.loadedModes == ["Catalog"])
        #expect(tree.loadedModes == ["Project"])
    }

    @Test @MainActor
    func backupActionKeepsSourceSummaryOnFailureAndUsesReturnedSelectionOnSuccess() async throws {
        var backup = LayerTreeNode(id: "backup-1", sourceClass: "BackupNodeVM", name: "backup.h5",
            backupSummary: .init(filename: "/task-fixture/backup.h5", dateCreated: "source date", dateLastModified: "source modified date"))
        let provider = CatalogFixtureProvider(.init(roots: [backup], selection: .node(backup.id)))
        let workspace = WorkspaceStore(), session = workspace.catalogTreeSession
        let context = LayerTreeContext(projectSessionID: workspace.projectSessionID, projectURL: URL(fileURLWithPath: "/task-fixture/project.ras"), mapID: MapState.projectMapID, mode: "Catalog", focusedGeometryIDs: [], focusedPlanIDs: [])
        await session.load(provider: provider, context: context)
        #expect(await session.saveBackupAsNewGeometry(backup.id) == nil)
        await session.perform(.saveBackupAsNewGeometry(nodeID: backup.id))
        #expect(provider.restoredNodeIDs.isEmpty)
        backup.backupSummary?.canSaveAsNewGeometry = true
        provider.snapshot = .init(roots: [backup], selection: .node(backup.id))
        await session.load(provider: provider, context: context)
        #expect(await session.saveBackupAsNewGeometry(backup.id) == nil)
        #expect(provider.restoredNodeIDs.isEmpty)
        backup.backupSummary?.revision = String(repeating: "a", count: 64)
        backup.backupSummary?.parentGeometryPath = "/task-fixture/Geometry.h5"
        backup.backupSummary?.parentGeometryRevision = String(repeating: "b", count: 64)
        backup.backupSummary?.projectRevision = String(repeating: "c", count: 64)
        provider.snapshot = .init(roots: [backup], selection: .node(backup.id))
        await session.load(provider: provider, context: context)
        provider.failure = CocoaError(.fileWriteNoPermission)
        #expect(await session.saveBackupAsNewGeometry(backup.id) == nil)
        #expect(session.error != nil)
        #expect(session.selectedNode?.backupSummary?.filename == "/task-fixture/backup.h5")
        #expect(session.selectedID == backup.id)
        provider.failure = nil
        let created = ProjectAsset(url: URL(fileURLWithPath: "/task-fixture/Source unique geometry name.h5"), section: .geometries)
        provider.response = .init(roots: [.init(id: "source-created-geometry", sourceClass: "ObservableGeometry", name: created.name, assetID: created.id)], selection: .node("source-created-geometry"), projectAssets: [created])
        #expect(await session.saveBackupAsNewGeometry(backup.id) == created.id)
        #expect(provider.restoredNodeIDs == [backup.id, backup.id])
        #expect(session.selectedID == "source-created-geometry")
        #expect(session.error == nil)
        #expect(!session.busy)
        #expect(workspace.assets == [created])
    }
}
