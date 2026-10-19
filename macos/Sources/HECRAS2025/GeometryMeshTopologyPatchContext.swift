import CryptoKit
import Foundation

/// Binds a topology quick-edit handoff to the exact parent source, staged
/// topology state, and selected control-point identities that opened it.
struct GeometryMeshTopologyPatchContext: Hashable, Sendable {
    let assetID: String
    let sourceRevision: String
    let topologyDraftFingerprint: String
    let selectedRegionIDs: [Int]

    init?(assetID: String?, sourceRevision: String?, topologyDraftState: String?, selectedRegionIDs: [Int]) {
        guard let assetID, !assetID.isEmpty,
              let sourceRevision, !sourceRevision.isEmpty,
              !selectedRegionIDs.isEmpty,
              Set(selectedRegionIDs).count == selectedRegionIDs.count else { return nil }
        self.assetID = assetID
        self.sourceRevision = sourceRevision
        let topologyStateIdentity = topologyDraftState.map { "value:\($0)" } ?? "nil"
        self.topologyDraftFingerprint = Self.sha256(topologyStateIdentity)
        self.selectedRegionIDs = selectedRegionIDs.sorted()
    }

    var stableKey: String {
        [assetID, sourceRevision, topologyDraftFingerprint,
         selectedRegionIDs.map { String($0) }.joined(separator: ",")].joined(separator: "|")
    }

    func matchesParent(assetID: String?, sourceRevision: String?, topologyDraftState: String?,
                       selectedRegionIDs: [Int]) -> Bool {
        guard let live = Self(assetID: assetID, sourceRevision: sourceRevision,
                              topologyDraftState: topologyDraftState, selectedRegionIDs: selectedRegionIDs) else {
            return false
        }
        return self == live
    }

    func matchesMeshSnapshot(_ snapshot: GeometryMeshSnapshot?, meshAssetID: String?,
                             liveSelection: Set<Int>, canEdit: Bool) -> Bool {
        guard canEdit,
              meshAssetID == assetID,
              let snapshot,
              snapshot.revision == sourceRevision,
              snapshot.selectedRegionIDs.sorted() == selectedRegionIDs,
              liveSelection == Set(selectedRegionIDs),
              let sizing = snapshot.patchSizing,
              sizing.selectedRegionIDs.sorted() == selectedRegionIDs else { return false }

        // A current but unavailable sizing result is still useful: the inspector
        // can present the source diagnostic and let the user retry. Ready data
        // must additionally contain both exact Quad-side identities below.
        guard sizing.state == "ready" else { return true }
        guard sizing.kind == "Quad", sizing.dimensions.count == 2 else { return false }

        return ["NorthSouth", "EastWest"].allSatisfy { axis in
            guard let dimension = sizing.dimensions.first(where: { $0.id == axis }),
                  let selection = dimension.sideArcSelection else { return false }
            return selection.sourceRevision == snapshot.revision
                && selection.topologyFingerprint == snapshot.topologyFingerprint
                && selection.selectedRegionIDs.sorted() == selectedRegionIDs
                && selection.axis == axis
        }
    }

    private static func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
