import Foundation

enum ClassificationEditorContract {
    nonisolated static let sourceField = "ClassificationLayersEditor/ClassificationLayer_SelectedClassificationInput"
}
struct ClassificationInputInfo: Sendable {
    let filename: String?
    let extent: String?
    let valueFieldID: String?
}
struct BackendClassificationData: Decodable, Sendable {
    struct Polygon: Decodable, Sendable {
        let id: String; let scope: String; let classification: String; let vertexCount: Int
        let vertices: [ClassificationVertex]; let hasZ: Bool; let hasM: Bool
        var presentation: PolygonClassificationItem { .init(id: id, scope: scope, classification: classification, vertexCount: vertexCount, vertices: vertices, hasZ: hasZ, hasM: hasM) }
    }
    struct Input: Decodable, Sendable {
        let id: String; let scope: String; let name: String; let type: String; let canRemove: Bool
        let filename: String?; let tableId: String?; let rows: [BackendModelRow]; let polygons: [Polygon]; let extent: String?
        var presentation: SourceItemPresentation {
            .init(scope: scope, schemaIDs: type == "Raster" ? ["RasterClassificationInputProperties"] : [],
                polygons: type == "PolyClassifier" ? .init(items: polygons.map(\.presentation), selectedIDs: [], canSelect: true) : nil,
                nameFieldID: scope + "/Name", classificationInfo: .init(filename: filename, extent: extent, valueFieldID: type == "Constant" ? scope + "/ConstantClassification/Value" : nil))
        }
    }
    let inputs: [Input]; let selectedId: String?; let classes: [String]
    let canUndoGeometry: Bool; let canRedoGeometry: Bool
    func apply(to snapshot: inout EditorSnapshot) {
        let field = ClassificationEditorContract.sourceField
        snapshot.sourceCollections[field] = .init(items: inputs.reversed().map { .init(id: $0.id, title: $0.name, titleIsUserData: true) },
            sourcePriorityReversed: true, canImport: true, canReorder: true, multipleImports: true, canRemove: true,
            removableIDs: Set(inputs.filter(\.canRemove).map(\.id)), itemDetails: Dictionary(uniqueKeysWithValues: inputs.map { ($0.id, $0.presentation) }), classificationTools: .init(classes: classes, canUndo: canUndoGeometry, canRedo: canRedoGeometry))
        for input in inputs {
            if let table = input.tableId {
                snapshot.rows[table] = input.rows.map(\.editorRow)
                snapshot.tablePresentations[table] = .init(columns: [
                    .init(id: "Key", title: "ID", sourceType: "int", readOnly: true, width: 90),
                    .init(id: "Value", title: "Name", sourceType: "string", width: 240)])
            }
            for polygon in input.polygons { snapshot.textSuggestions[polygon.presentation.fieldID] = classes }
        }
    }
}
