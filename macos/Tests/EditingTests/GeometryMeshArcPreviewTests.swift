import Foundation
import Testing
@testable import HECRAS2025

struct GeometryMeshArcPreviewTests {
    @Test func resolvesOnlyExactSourceArcPathsForTheCurrentIdentity() throws {
        let pathsByFID = [
            41: [GeometryTopologyCoordinate(x: 0, y: 0), GeometryTopologyCoordinate(x: 5, y: 0)],
            42: [GeometryTopologyCoordinate(x: 5, y: 0), GeometryTopologyCoordinate(x: 5, y: 8)]
        ]
        let selection = GeometryMeshPatchArcSelection(sourceRevision: "revision-a",
            topologyFingerprint: "topology-a", selectedRegionIDs: [5, 8], axis: "NorthSouth",
            arcFeatureIDs: [41, 42])
        let dimension = dimension(selection: selection, arcCount: 2)

        let paths = try #require(GeometryMeshArcPreview.sourcePaths(for: dimension,
            sourceRevision: "revision-a", topologyFingerprint: "topology-a",
            selectedRegionIDs: [8, 5], map: map(pathsByFID: pathsByFID)))

        #expect(paths == [pathsByFID[41]!, pathsByFID[42]!])
    }

    @Test func withholdsStaleOrPartialArcGeometry() {
        let selection = GeometryMeshPatchArcSelection(sourceRevision: "revision-a",
            topologyFingerprint: "topology-a", selectedRegionIDs: [5], axis: "EastWest",
            arcFeatureIDs: [41, 42])
        let dimension = dimension(selection: selection, arcCount: 2)
        let completeMap = map(pathsByFID: [
            41: [GeometryTopologyCoordinate(x: 0, y: 0), GeometryTopologyCoordinate(x: 5, y: 0)],
            42: [GeometryTopologyCoordinate(x: 5, y: 0), GeometryTopologyCoordinate(x: 5, y: 8)]
        ])

        #expect(GeometryMeshArcPreview.sourcePaths(for: dimension,
            sourceRevision: "revision-b", topologyFingerprint: "topology-a",
            selectedRegionIDs: [5], map: completeMap) == nil)
        #expect(GeometryMeshArcPreview.sourcePaths(for: dimension,
            sourceRevision: "revision-a", topologyFingerprint: "topology-b",
            selectedRegionIDs: [5], map: completeMap) == nil)
        #expect(GeometryMeshArcPreview.sourcePaths(for: dimension,
            sourceRevision: "revision-a", topologyFingerprint: "topology-a",
            selectedRegionIDs: [6], map: completeMap) == nil)
        #expect(GeometryMeshArcPreview.sourcePaths(for: dimension,
            sourceRevision: "revision-a", topologyFingerprint: "topology-a",
            selectedRegionIDs: [5], map: map(pathsByFID: [
                41: [GeometryTopologyCoordinate(x: 0, y: 0), GeometryTopologyCoordinate(x: 5, y: 0)]
            ])) == nil)
    }

    private func dimension(selection: GeometryMeshPatchArcSelection,
                           arcCount: Int) -> GeometryMeshPatchDimension {
        GeometryMeshPatchDimension(id: selection.axis, title: selection.axis, arcCount: arcCount,
            sizeFunction: "Constant", sizeFunctionHasMismatch: false, liveValue: 4,
            liveValueHasMismatch: false, canResize: true, canApply: true, canChangeMode: true,
            sideArcSelection: selection)
    }

    private func map(pathsByFID: [Int: [GeometryTopologyCoordinate]]) -> GeometryMeshMapData {
        let features = pathsByFID.keys.sorted().map { fid in
            GeometryTopologyMapFeature(id: "arc:\(fid)", featureKind: "arc", fid: fid,
                geometryType: "line", selectionIDs: ["arc:\(fid)"],
                paths: [pathsByFID[fid]!])
        }
        return GeometryMeshMapData(extent: nil,
            topology: GeometryTopologyMapData(extent: nil, features: features), cells: [],
            totalCellCount: 0, renderedCellCount: 0, omittedCellCount: 0,
            invalidCandidateCount: 0, cellLimit: 0, vertexLimit: 0)
    }
}
