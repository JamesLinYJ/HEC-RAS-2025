import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

@MainActor
private final class SnapshotLayerTreeProvider: LayerTreeProvider {
    var snapshots: [LayerTreeSnapshot]

    init(_ snapshots: [LayerTreeSnapshot]) { self.snapshots = snapshots }

    func load(_ context: LayerTreeContext) async throws -> LayerTreeSnapshot {
        guard !snapshots.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        return snapshots.removeFirst()
    }

    func perform(_ action: LayerTreeAction, context: LayerTreeContext) async throws -> LayerTreeSnapshot {
        throw CocoaError(.featureUnsupported)
    }
}

struct LayerTreeContextRefreshTests {
    private let projectURL = URL(fileURLWithPath: "/fixture/project.ras")
    private let boundaryID = "boundary:River"

    private func context(projectSessionID: UUID, mapID: UUID, mode: String,
                         projectRevision: String, assetsRevision: Int) -> LayerTreeContext {
        LayerTreeContext(projectSessionID: projectSessionID, projectURL: projectURL,
            mapID: mapID, mode: mode, focusedGeometryIDs: [], focusedPlanIDs: [],
            projectRevision: projectRevision, assetsRevision: assetsRevision)
    }

    private func boundaryNode(_ id: String = "boundary:River") -> LayerTreeNode {
        LayerTreeNode(id: id, sourceClass: "ObservableBoundaryCondition", name: "River",
            properties: [
                .init(id: "BoundaryCondition/StartTime", label: "Start Time", value: "2026-10-16 09:00:00"),
                .init(id: "BoundaryCondition/EndTime", label: "End Time", value: "2026-10-16 10:00:00")
            ])
    }

    @Test @MainActor
    func visualRevisionRefreshRetainsSelectedBoundarySummaryProperties() async throws {
        let projectSessionID = UUID(), mapID = UUID()
        let first = LayerTreeSnapshot(roots: [boundaryNode()], selection: .node(boundaryID),
                                      expandedNodeIDs: [boundaryID])
        let refreshed = LayerTreeSnapshot(roots: [boundaryNode()])
        let provider = SnapshotLayerTreeProvider([first, refreshed])
        let session = LayerTreeSession()

        await session.load(provider: provider, context: context(projectSessionID: projectSessionID,
            mapID: mapID, mode: "Catalog", projectRevision: "vis-before", assetsRevision: 4))
        #expect(session.selectedID == boundaryID)

        await session.load(provider: provider, context: context(projectSessionID: projectSessionID,
            mapID: mapID, mode: "Catalog", projectRevision: "vis-after", assetsRevision: 4))

        let selected = try #require(session.selectedNode)
        #expect(selected.sourceClass == "ObservableBoundaryCondition")
        #expect(selected.properties.filter { $0.id.hasPrefix("BoundaryCondition/") }.count == 2)
        #expect(selected.properties.first { $0.id == "BoundaryCondition/StartTime" }?.value == "2026-10-16 09:00:00")
        #expect(session.expandedNodeIDs.contains(boundaryID))
    }

    @Test @MainActor
    func refreshClearsSelectionWhenSelectedNodeWasDeleted() async {
        let projectSessionID = UUID(), mapID = UUID()
        let provider = SnapshotLayerTreeProvider([
            LayerTreeSnapshot(roots: [boundaryNode()], selection: .node(boundaryID)),
            LayerTreeSnapshot(roots: [LayerTreeNode(id: "boundary:Other", sourceClass: "ObservableBoundaryCondition", name: "Other")])
        ])
        let session = LayerTreeSession()
        await session.load(provider: provider, context: context(projectSessionID: projectSessionID,
            mapID: mapID, mode: "Catalog", projectRevision: "before", assetsRevision: 1))

        await session.load(provider: provider, context: context(projectSessionID: projectSessionID,
            mapID: mapID, mode: "Catalog", projectRevision: "after", assetsRevision: 2))

        #expect(session.selectedID == nil)
        #expect(session.selectedNode == nil)
    }

    @Test @MainActor
    func projectMapAndModeChangesResetSelectionAndExpansion() async {
        let baseProjectID = UUID(), baseMapID = UUID()
        let scenarios = [
            context(projectSessionID: UUID(), mapID: baseMapID, mode: "Catalog", projectRevision: "same", assetsRevision: 1),
            context(projectSessionID: baseProjectID, mapID: UUID(), mode: "Catalog", projectRevision: "same", assetsRevision: 1),
            context(projectSessionID: baseProjectID, mapID: baseMapID, mode: "Project", projectRevision: "same", assetsRevision: 1)
        ]

        for changedContext in scenarios {
            let provider = SnapshotLayerTreeProvider([
                LayerTreeSnapshot(roots: [boundaryNode()], selection: .node(boundaryID), expandedNodeIDs: [boundaryID]),
                LayerTreeSnapshot(roots: [boundaryNode()])
            ])
            let session = LayerTreeSession()
            await session.load(provider: provider, context: context(projectSessionID: baseProjectID,
                mapID: baseMapID, mode: "Catalog", projectRevision: "before", assetsRevision: 0))

            await session.load(provider: provider, context: changedContext)

            #expect(session.selectedID == nil)
            #expect(!session.expandedNodeIDs.contains(boundaryID))
        }
    }
}
