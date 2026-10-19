import Foundation
import RASWorkspaceCore

/// Render values for the exact boundary-line source. Conditional groups are
/// intentionally retained by the style contract but are not evaluated here:
/// this map projection has no verified attribute-table row binding.
struct BoundaryMapRenderStyle: Equatable, Sendable {
    let line: VectorStyleValues
    let vertex: VectorStyleValues
    let lineConditionGroups: [VectorVisualConditionGroup]
    let vertexConditionGroups: [VectorVisualConditionGroup]

    static var sourceDefault: BoundaryMapRenderStyle {
        BoundaryMapRenderStyle(
            line: SourceVectorStyleCatalog.definition(for: Self.lineDefinitionID)?.defaultStyle
                ?? SourceVectorStyleCatalog.fallbackStyle,
            vertex: SourceVectorStyleCatalog.definition(for: Self.vertexDefinitionID)?.defaultStyle
                ?? SourceVectorStyleCatalog.fallbackStyle,
            lineConditionGroups: [], vertexConditionGroups: [])
    }

    static let lineDefinitionID = "BC_Line_Symbology"
    static let vertexDefinitionID = "BC_Line_Vertex_Symbology"

    static func resolve(options: [String: VectorVisualSettingsOptions]) -> BoundaryMapRenderStyle? {
        guard let lineOptions = options[lineDefinitionID],
              let vertexOptions = options[vertexDefinitionID],
              let line = lineOptions.values.validatedForPersistence(),
              let vertex = vertexOptions.values.validatedForPersistence() else { return nil }
        return BoundaryMapRenderStyle(line: line, vertex: vertex,
            lineConditionGroups: lineOptions.conditionGroups,
            vertexConditionGroups: vertexOptions.conditionGroups)
    }
}

enum BoundaryMapRenderOwnerIdentity {
    /// Runtime PlotOption state follows the actual boundary source owner. A
    /// `.vis` revision or Result chart context token is deliberately excluded,
    /// so changing only a style does not reset ShowStrokeVertices.
    static func key(for capture: BoundaryMapCapture) -> String {
        let node = capture.boundaryNode
        let resultOwner = capture.resultOwner
        let fields = [
            capture.projectSessionID.uuidString,
            capture.map.mapID,
            node.rootName,
            node.nodeType,
            node.nodeName,
            (node.nodePath ?? []).map(String.init).joined(separator: "."),
            node.assetID ?? "",
            node.associationKind ?? "",
            node.associationAssetID ?? "",
            node.parentPlanAssetID ?? "",
            (node.parentPlanNodePath ?? []).map(String.init).joined(separator: "."),
            node.parentPlanNodeName ?? "",
            node.parentResultNodeType ?? "",
            node.parentResultAssetID ?? "",
            (node.parentResultNodePath ?? []).map(String.init).joined(separator: "."),
            node.parentResultNodeName ?? "",
            node.parentResultRevision ?? "",
            capture.sourcePath,
            capture.sourceRevision,
            resultOwner?.resultNode.sourceIdentity ?? "direct",
            String(resultOwner?.selectionIndex ?? -1),
            resultOwner?.selectedResultPath ?? "",
            resultOwner?.selectedResultRevision ?? ""
        ]
        return fields.map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
    }
}
