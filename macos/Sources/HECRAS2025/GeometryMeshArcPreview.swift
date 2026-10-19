import Foundation

/// Resolves the Quad dimension's source-arc membership against the exact map
/// features returned in the same mesh snapshot. A preview is withheld if its
/// source revision, staged-topology fingerprint, selection, or geometry does
/// not match; partial or inferred boundary paths are never rendered.
enum GeometryMeshArcPreview {
    static func sourcePaths(
        for dimension: GeometryMeshPatchDimension,
        sourceRevision: String?,
        topologyFingerprint: String?,
        selectedRegionIDs: [Int],
        map: GeometryMeshMapData?
    ) -> [[GeometryTopologyCoordinate]]? {
        guard let sourceRevision,
              let topologyFingerprint,
              let selection = dimension.sideArcSelection,
              selection.sourceRevision == sourceRevision,
              selection.topologyFingerprint == topologyFingerprint,
              selection.axis == dimension.id,
              selection.axis == "NorthSouth" || selection.axis == "EastWest",
              selection.selectedRegionIDs == selectedRegionIDs.sorted(),
              Set(selection.selectedRegionIDs).count == selection.selectedRegionIDs.count,
              dimension.sideArcIssues?.isEmpty != false,
              selection.arcFeatureIDs.count == dimension.arcCount,
              Set(selection.arcFeatureIDs).count == selection.arcFeatureIDs.count,
              let map else { return nil }

        let requestedIDs = Set(selection.arcFeatureIDs)
        if requestedIDs.isEmpty { return [] }
        var sourcePathsByFID: [Int: [GeometryTopologyCoordinate]] = [:]
        for feature in map.topology.features where feature.featureKind == "arc" {
            guard let fid = feature.fid,
                  requestedIDs.contains(fid),
                  feature.id == "arc:\(fid)",
                  feature.geometryType == "line",
                  feature.paths.count == 1,
                  let path = feature.paths.first,
                  path.count >= 2,
                  path.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { continue }
            sourcePathsByFID[fid] = path
        }
        guard Set(sourcePathsByFID.keys) == requestedIDs else { return nil }
        return selection.arcFeatureIDs.compactMap { sourcePathsByFID[$0] }
    }
}
