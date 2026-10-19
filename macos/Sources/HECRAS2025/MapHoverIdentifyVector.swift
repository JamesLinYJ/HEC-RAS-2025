import Foundation
import RASWorkspaceCore

struct MapHoverIdentifyVectorSource: Codable, Hashable, Sendable {
    let node: CatalogTreeNodeLocator
    let contextIdentity: String
    let layerID: String
    let sourcePath: String
    let sourceRevision: String
    let mapType: String?
}

private struct ResolvedMapHoverVector {
    let row: MapSourceRenderRecord
    let layer: MapVectorLayer
    let source: MapHoverIdentifyVectorSource
}

/// Keeps vector identify joined to the visible source-tree row and the exact
/// layer instance used by the renderer. It reuses the same geometry hit tester
/// as vector selection but does not mutate selection or open the inspector.
@MainActor
enum MapHoverIdentifyVector {
    static func sources(mapID: UUID,
                        records: [MapSourceRenderRecord],
                        candidates: [MapVectorLayer],
                        selectedLayerID: String?,
                        selectedContextIdentity: String?) -> [MapHoverIdentifyVectorSource] {
        resolvedSources(mapID: mapID, records: records, candidates: candidates,
            selectedLayerID: selectedLayerID,
            selectedContextIdentity: selectedContextIdentity).map(\.source)
    }

    static func entries(at location: CGPoint,
                        transform: MapTransform,
                        mapID: UUID,
                        records: [MapSourceRenderRecord],
                        candidates: [MapVectorLayer],
                        selectedLayerID: String?,
                        selectedContextIdentity: String?,
                        vectorStyles: [String: MapVectorStylePresentation]) -> [MapHoverIdentifyEntry] {
        let resolved = resolvedSources(mapID: mapID, records: records, candidates: candidates,
            selectedLayerID: selectedLayerID,
            selectedContextIdentity: selectedContextIdentity)
        let renderFactor = WorkspaceRenderScaling.shared.factor
        return resolved.compactMap { item in
            let hit = MapVectorFeatureHitTester.closestFeature(at: location, transform: transform,
                layers: [item.layer], tolerance: 8,
                lineWidth: { layer, feature in
                    let style = MapVectorStyleResolver.values(layerID: layer.id, feature: feature,
                        definitionID: MapVectorStyleDefinitionIDs.primaryDefinition(for: feature.kind),
                        presentations: vectorStyles)
                    return WorkspaceRenderScaling.metric(
                        Double(VectorMapCanvas.safeLineWidth(style.penWidth)), factor: renderFactor)
                },
                pointDiameter: { layer, feature in
                    let style = MapVectorStyleResolver.values(layerID: layer.id, feature: feature,
                        definitionID: MapVectorStyleDefinitionIDs.primaryDefinition(for: feature.kind),
                        presentations: vectorStyles)
                    return WorkspaceRenderScaling.metric(
                        Double(VectorMapCanvas.safePointDiameter(style.pointSize)), factor: renderFactor)
                })
            guard let hit, hit.layerID == item.layer.id else { return nil }
            let matches = item.layer.features.filter {
                $0.stableIdentity == hit.featureIdentity && $0.hasUniqueStableIdentity
                    && $0.sourceFeatureIndex != nil
            }
            guard matches.count == 1, let featureID = matches[0].sourceFeatureIndex else { return nil }
            let value = String(featureID)
            let detail = "\(L10n.text("FID")): \(value)"
            let label = "\(item.row.locator.nodeName) · \(detail)"
            return MapHoverIdentifyEntry(node: item.row.locator, kind: "vector", label: label,
                value: value, valueType: "feature-id", sourcePath: item.source.sourcePath,
                sourceRevision: item.source.sourceRevision, mapType: item.source.mapType,
                profileIndex: nil, meshIndex: nil, elementIndex: nil)
        }
    }

    private static func resolvedSources(mapID: UUID,
                                       records: [MapSourceRenderRecord],
                                       candidates: [MapVectorLayer],
                                       selectedLayerID: String?,
                                       selectedContextIdentity: String?) -> [ResolvedMapHoverVector] {
        var rows = MapRenderComposition.orderedRecords(records).filter { $0.mapID == mapID }
        if let selectedLayerID,
           let index = rows.firstIndex(where: { $0.payloadLayerIDs.contains(selectedLayerID) }) {
            let row = rows.remove(at: index)
            rows.insert(row, at: 0)
        }
        if let selectedContextIdentity,
           let index = rows.firstIndex(where: { $0.contextIdentity == selectedContextIdentity }) {
            let row = rows.remove(at: index)
            rows.insert(row, at: min(1, rows.count))
        }

        return rows.compactMap { row in
            guard row.payloadKind == "MapLayer" || row.payloadKind == "GdbVectorLayer",
                  row.payloadLayerIDs.count == 1,
                  let layerID = row.payloadLayerIDs.first else { return nil }
            let matchingLayers = candidates.filter {
                $0.id == layerID && ($0.sourceMapID == nil || $0.sourceMapID == mapID)
                    && $0.isSourceVisible
            }
            guard matchingLayers.count == 1, let layer = matchingLayers.first,
                  let revision = layer.sourceRevision, !revision.isEmpty else { return nil }
            let sourcePath = SourceFilePaths.canonical(layer.url)
            guard !sourcePath.isEmpty else { return nil }
            let source = MapHoverIdentifyVectorSource(node: row.locator,
                contextIdentity: row.contextIdentity, layerID: layer.id,
                sourcePath: sourcePath, sourceRevision: revision, mapType: row.locator.mapType)
            return ResolvedMapHoverVector(row: row, layer: layer, source: source)
        }
    }
}
