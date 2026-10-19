import Foundation
import Testing
@testable import HECRAS2025

struct GeometryMeshTopologyPatchContextTests {
    @Test func parentHandoffBindsAssetRevisionDraftAndUniqueRegionIdentity() throws {
        let context = try #require(GeometryMeshTopologyPatchContext(assetID: "geometry-a",
            sourceRevision: "revision-a", topologyDraftState: "topology-draft-a",
            selectedRegionIDs: [9, 4]))

        #expect(context.selectedRegionIDs == [4, 9])
        #expect(context.matchesParent(assetID: "geometry-a", sourceRevision: "revision-a",
            topologyDraftState: "topology-draft-a", selectedRegionIDs: [4, 9]))
        #expect(!context.matchesParent(assetID: "geometry-b", sourceRevision: "revision-a",
            topologyDraftState: "topology-draft-a", selectedRegionIDs: [4, 9]))
        #expect(!context.matchesParent(assetID: "geometry-a", sourceRevision: "revision-b",
            topologyDraftState: "topology-draft-a", selectedRegionIDs: [4, 9]))
        #expect(!context.matchesParent(assetID: "geometry-a", sourceRevision: "revision-a",
            topologyDraftState: "topology-draft-b", selectedRegionIDs: [4, 9]))
        #expect(!context.matchesParent(assetID: "geometry-a", sourceRevision: "revision-a",
            topologyDraftState: "topology-draft-a", selectedRegionIDs: [4, 4]))
    }

    @Test func meshChildMustBeEditableForTheSameSelectionAndCurrentSideFingerprints() throws {
        let context = try #require(GeometryMeshTopologyPatchContext(assetID: "geometry-a",
            sourceRevision: "revision-a", topologyDraftState: "topology-draft-a",
            selectedRegionIDs: [9, 4]))
        let matching = snapshot()

        #expect(context.matchesMeshSnapshot(matching, meshAssetID: "geometry-a",
            liveSelection: [4, 9], canEdit: true))
        #expect(!context.matchesMeshSnapshot(matching, meshAssetID: "geometry-b",
            liveSelection: [4, 9], canEdit: true))
        #expect(!context.matchesMeshSnapshot(matching, meshAssetID: "geometry-a",
            liveSelection: [4], canEdit: true))
        #expect(!context.matchesMeshSnapshot(matching, meshAssetID: "geometry-a",
            liveSelection: [4, 9], canEdit: false))
        #expect(!context.matchesMeshSnapshot(snapshot(revision: "revision-b"),
            meshAssetID: "geometry-a", liveSelection: [4, 9], canEdit: true))
        #expect(!context.matchesMeshSnapshot(snapshot(axisOnEastWest: "NorthSouth"),
            meshAssetID: "geometry-a", liveSelection: [4, 9], canEdit: true))
        #expect(context.matchesMeshSnapshot(snapshot(sizingState: "unavailable"),
            meshAssetID: "geometry-a", liveSelection: [4, 9], canEdit: true))
    }

    private func snapshot(revision: String = "revision-a",
                          axisOnEastWest: String = "EastWest",
                          sizingState: String = "ready") -> GeometryMeshSnapshot {
        let selectedIDs = [4, 9]
        let topologyFingerprint = "staged-topology-fingerprint"
        let dimensions = sizingState == "ready" ? ["NorthSouth", axisOnEastWest].map { dimensionAxis in
            GeometryMeshPatchDimension(id: dimensionAxis, title: dimensionAxis, arcCount: 1,
                sizeFunction: "Constant", sizeFunctionHasMismatch: false, liveValue: 4,
                liveValueHasMismatch: false, canResize: true, canApply: true, canChangeMode: true,
                sideArcSelection: GeometryMeshPatchArcSelection(sourceRevision: revision,
                    topologyFingerprint: topologyFingerprint, selectedRegionIDs: selectedIDs,
                    axis: dimensionAxis, arcFeatureIDs: [dimensionAxis == "NorthSouth" ? 10 : 11]))
        } : []
        return GeometryMeshSnapshot(revision: revision, draftState: "mesh-child-ledger",
            topologyFingerprint: topologyFingerprint, canEdit: true, isDirty: false,
            flowAreas: [], regions: GeometryTopologyFeatureTable(featureKind: "region",
                columns: [], editableFields: [], rows: []), selectedRegionIDs: selectedIDs,
            patchSizing: GeometryMeshPatchSizing(state: sizingState,
                kind: sizingState == "ready" ? "Quad" : nil, message: "source side data unavailable",
                selectedRegionIDs: selectedIDs, dimensions: dimensions),
            generationReport: nil, prepareSummary: nil)
    }
}
