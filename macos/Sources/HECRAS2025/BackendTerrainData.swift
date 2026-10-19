import Foundation

enum TerrainEditorContract {
    nonisolated static let sourceField = "TerrainLayersEditor/SelectedInputWithMap"
}
struct TerrainInputMetadata: Sendable {
    let type: String
    let filename: String?
    let error: String?
    let validExtent: TerrainInputValidExtent?
    let overviewCount: Int?
    let overviews: [String]?

    init(type: String, filename: String?, error: String?, validExtent: TerrainInputValidExtent?,
         overviewCount: Int? = nil, overviews: [String]? = nil) {
        self.type = type; self.filename = filename; self.error = error; self.validExtent = validExtent
        self.overviewCount = overviewCount; self.overviews = overviews
    }
}
struct TerrainMapData: Decodable, Sendable {
    let raster: SpatialGridPreview?
    let selectedRaster: SpatialGridPreview?
    let inputId: String?
    let sourceRevision: String?
    let features: [TerrainMapFeature]?
}
struct TerrainMapCoordinate: Codable, Sendable {
    let x: Double
    let y: Double
}
struct TerrainMapFeature: Decodable, Identifiable, Sendable {
    let id: String
    let tableId: String
    let points: [TerrainMapCoordinate]
    let kind: String?
}
struct BackendTerrainData: Decodable, Sendable {
    struct Input: Decodable, Sendable {
        let id: String; let scope: String; let name: String; let type: String
        let filename: String?; let schema: String?; let error: String?
        let validExtent: TerrainInputValidExtent?
        let overviewCount: Int?
        let overviews: [String]?
        init(id: String, scope: String, name: String, type: String, filename: String?,
             schema: String?, error: String?, validExtent: TerrainInputValidExtent? = nil,
             overviewCount: Int? = nil, overviews: [String]? = nil) {
            self.id = id; self.scope = scope; self.name = name; self.type = type
            self.filename = filename; self.schema = schema; self.error = error; self.validExtent = validExtent
            self.overviewCount = overviewCount; self.overviews = overviews
        }
        var presentation: SourceItemPresentation {
            .init(scope: scope, schemaIDs: schema.map { [$0] } ?? [], nameFieldID: scope + "/Name",
                terrainInfo: .init(type: type, filename: filename, error: error, validExtent: validExtent,
                                   overviewCount: overviewCount, overviews: overviews))
        }
    }
    struct Column: Decodable, Sendable {
        let id: String
        let title: String
        let sourceType: String
        let readOnly: Bool
        let width: Double?
        let autoSuggestions: [String]?
        var presentation: SourceTableColumn {
            .init(id: id, title: title, sourceType: sourceType, readOnly: readOnly,
                  width: width, autoSuggestions: autoSuggestions)
        }
    }
    struct Table: Decodable, Sendable {
        let columns: [Column]
        let canAddRows: Bool
        let canCopyRows: Bool
        let canDeleteRows: Bool
        let selectedRowIDs: [String]?
        let requestedSelectionRowIDs: [String]?
        var presentation: EditorTablePresentation {
            var result = EditorTablePresentation(columns: columns.map(\.presentation))
            result.canAddRows = canAddRows
            result.canCopyRows = canCopyRows
            result.canDeleteRows = canDeleteRows
            if let selectedRowIDs { result.selection = .init(rowIDs: Set(selectedRowIDs)) }
            result.requestedSelectionRowIDs = requestedSelectionRowIDs.map(Set.init)
            return result
        }
    }
    let inputs: [Input]; let selectedId: String?
    let importDraftToken: String?
    let importCleanupWarning: String?
    let importCleanupToken: String?
    let rows: [String: [BackendModelRow]]?
    let tables: [String: Table]?
    let fieldChoices: [String: [EditorChoice]]?
    let textSuggestions: [String: [String]]?
    init(inputs: [Input], selectedId: String?, importDraftToken: String?, importCleanupWarning: String?,
         importCleanupToken: String?, rows: [String: [BackendModelRow]]? = nil,
         tables: [String: Table]? = nil, fieldChoices: [String: [EditorChoice]]? = nil,
         textSuggestions: [String: [String]]? = nil) {
        self.inputs = inputs; self.selectedId = selectedId; self.importDraftToken = importDraftToken
        self.importCleanupWarning = importCleanupWarning; self.importCleanupToken = importCleanupToken
        self.rows = rows; self.tables = tables; self.fieldChoices = fieldChoices; self.textSuggestions = textSuggestions
    }
    func apply(to snapshot: inout EditorSnapshot) {
        snapshot.sourceCollections[TerrainEditorContract.sourceField] = .init(
            items: inputs.reversed().map { .init(id: $0.id, title: $0.name, titleIsUserData: true) },
            sourcePriorityReversed: true, canImport: snapshot.canEdit, canReorder: true, multipleImports: true,
            canRemove: true, itemDetails: Dictionary(uniqueKeysWithValues: inputs.map { ($0.id, $0.presentation) }), terrainConnected: true)
        snapshot.terrainInputImportDraftToken = importDraftToken
        snapshot.terrainInputImportCleanupWarning = importCleanupWarning
        snapshot.terrainInputImportCleanupToken = importCleanupToken
        for (tableID, sourceRows) in rows ?? [:] { snapshot.rows[tableID] = sourceRows.map(\.editorRow) }
        for (tableID, table) in tables ?? [:] { snapshot.tablePresentations[tableID] = table.presentation }
        for (fieldID, choices) in fieldChoices ?? [:] { snapshot.choiceOptions[fieldID] = choices }
        for (fieldID, suggestions) in textSuggestions ?? [:] { snapshot.textSuggestions[fieldID] = suggestions }
    }
}
