import RASWorkspaceCore

/// Builds the shared map paint sequence from the exact saved-map rows and
/// each row's already-validated renderer payload. Source captures remain in
/// owner-session order; this value is only a view of their render order.
enum MapRenderComposition {
    /// Promote the focused context before the active payload so a row that
    /// owns both cannot accidentally demote the active layer to second place.
    /// Unfocused records retain the caller's renderer traversal order.
    static func hoverPriorityRecords(_ records: [MapSourceRenderRecord],
                                     selectedLayerID: String?,
                                     selectedContextIdentity: String?) -> [MapSourceRenderRecord] {
        var rows = records
        if let selectedContextIdentity,
           let index = rows.firstIndex(where: { $0.contextIdentity == selectedContextIdentity }) {
            let row = rows.remove(at: index)
            rows.insert(row, at: 0)
        }
        if let selectedLayerID,
           let index = rows.firstIndex(where: { $0.payloadLayerIDs.contains(selectedLayerID) }) {
            let row = rows.remove(at: index)
            rows.insert(row, at: 0)
        }
        return rows
    }

    /// The tooltip merges local vector hits with asynchronous backend values.
    /// Carry focus across that boundary rather than prioritizing only one half.
    static func hoverPreferredNodeIdentities(_ records: [MapSourceRenderRecord],
                                            selectedLayerID: String?,
                                            selectedContextIdentity: String?) -> [String] {
        var identities: [String] = []
        if let selectedLayerID,
           let row = records.first(where: { $0.payloadLayerIDs.contains(selectedLayerID) }) {
            identities.append(row.locator.sourceIdentity)
        }
        if let selectedContextIdentity,
           let row = records.first(where: { $0.contextIdentity == selectedContextIdentity }),
           !identities.contains(row.locator.sourceIdentity) {
            identities.append(row.locator.sourceIdentity)
        }
        return identities
    }

    static func orderedRecords(_ records: [MapSourceRenderRecord]) -> [MapSourceRenderRecord] {
        records.enumerated()
            .filter { $0.element.isActiveAndVisible }
            .sorted { lhs, rhs in
                let left = lhs.element
                let right = rhs.element
                if left.familyOrder != right.familyOrder {
                    return left.familyOrder < right.familyOrder
                }
                // RasMap first reverses the enabled source-tree list and then
                // performs a stable category sort. Thus equal-family contexts
                // paint in reverse tree order. activeLayerOrdinal preserves
                // the source order returned inside each context.
                if left.treeOrdinal != right.treeOrdinal {
                    return left.treeOrdinal > right.treeOrdinal
                }
                switch (left.activeLayerOrdinal, right.activeLayerOrdinal) {
                case let (left?, right?) where left != right:
                    return left < right
                case (.some, .none): return true
                case (.none, .some): return false
                default: return lhs.offset < rhs.offset
                }
            }
            .map(\.element)
    }

    /// Raster rows are interleaved by exact source identity. A missing row
    /// payload is not guessed from a filename or display label. The legacy
    /// fallback applies only before the saved map tree has been installed.
    static func rasterLayers(records: [MapSourceRenderRecord],
                             candidates: [MapRasterLayer],
                             hiddenLayerIDs: Set<String>) -> [MapRasterLayer] {
        let available = Dictionary(candidates.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        let ordered = orderedRecords(records)
        guard !ordered.isEmpty else {
            return candidates.filter { !hiddenLayerIDs.contains($0.id) }
        }

        var result: [MapRasterLayer] = []
        var seen = Set<String>()
        for row in ordered {
            for layerID in row.payloadLayerIDs {
                guard !hiddenLayerIDs.contains(layerID), seen.insert(layerID).inserted,
                      let layer = available[layerID], layer.sourceMapID == nil || layer.sourceMapID == row.mapID else {
                    continue
                }
                result.append(layer)
            }
        }
        return result
    }

    static func vectorLayers(records: [MapSourceRenderRecord],
                             candidates: [MapVectorLayer]) -> [MapVectorLayer] {
        let available = Dictionary(candidates.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        let ordered = orderedRecords(records)
        guard !ordered.isEmpty else { return candidates }

        var result: [MapVectorLayer] = []
        var seen = Set<String>()
        for row in ordered {
            for layerID in row.payloadLayerIDs {
                guard seen.insert(layerID).inserted, let layer = available[layerID],
                      layer.sourceMapID == nil || layer.sourceMapID == row.mapID else {
                    continue
                }
                result.append(layer)
            }
        }
        return result
    }
}
