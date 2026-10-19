import Foundation

struct BackendModelRow: Codable, Sendable {
    let id: String
    let values: [String: String]
    init(_ row: EditorRow) { id = row.id; values = row.values }
    var editorRow: EditorRow { .init(id: id, values: values) }
}
struct BackendModelSample: Codable, Sendable {
    let id: String
    let x: Double
    let y: Double?
    let series: String
    let datasetId: String?
    init(_ sample: ChartSample) {
        id = sample.id; x = sample.x; y = sample.y.isNaN ? nil : sample.y
        series = sample.series; datasetId = sample.datasetID
    }
    var sample: ChartSample { .init(id: id, x: x, y: y ?? .nan, series: series, datasetID: datasetId) }
}
struct BackendBoundaryData: Decodable, Sendable {
    struct Payload: Decodable, Sendable {
        let id: String; let scope: String; let name: String; let friendlyName: String; let editorSchemaId: String
        let isHydraulic: Bool; let isEnabled: Bool
        let variable: String; let description: String
        let valueUnits: DisplayUnitData?
        var presentation: BoundaryPayloadPresentation {
            .init(id: id, scope: scope, name: name, friendlyName: friendlyName, editorSchemaID: editorSchemaId,
                  isHydraulic: isHydraulic, isEnabled: isEnabled, valueUnits: valueUnits, canDelete: true)
        }
    }
    struct Choice: Decodable, Sendable {
        let id: String; let title: String
        var presentation: EditorChoice { .init(id: id, title: title, titleIsUserData: true) }
    }
    struct NewPayload: Decodable, Sendable {
        let fields: [String: String]; let choices: [String: [Choice]]; let constantUnits: [String: String]
        let valueUnits: [String: DisplayUnitData]?
        var presentation: NewPayloadPresentation {
            .init(fields: fields, choices: choices.mapValues { $0.map { .init(id: $0.id, title: $0.title, titleIsUserData: false) } },
                  constantUnits: constantUnits, constantValueUnits: valueUnits ?? [:])
        }
    }
    struct Line: Decodable, Sendable {
        let id: String; let scope: String; let name: String; let payloads: [Payload]; let activeHydraulicPayloadId: String?
        let newPayload: NewPayload
        let geometry: [BoundaryLineCoordinate]?
        var presentation: BoundaryLinePresentation {
            .init(id: id, scope: scope, name: name, payloads: payloads.map(\.presentation), selectedPayloadID: activeHydraulicPayloadId,
                activeHydraulicPayloadID: activeHydraulicPayloadId, newPayload: newPayload.presentation, geometry: geometry)
        }
    }
    struct Column: Decodable, Sendable {
        let id: String; let title: String; let sourceType: String; let readOnly: Bool; let width: Double
        // TimeSeriesPayloadDateTimeColumn and BindableDoubleArrayColumn inherit
        // ColumnBase's enabled sort/filter defaults in the original DataGrid.
        var column: SourceTableColumn {
            .init(id: id, title: title, sourceType: sourceType, readOnly: readOnly,
                  sortable: true, filterable: true, width: width)
        }
    }
    struct Series: Decodable, Sendable {
        let pageId: String; let scope: String; let schemaId: String; let tableId: String?
        let samples: [BackendModelSample]; let rows: [BackendModelRow]; let columns: [Column]
        let canEditX: Bool; let xIsDate: Bool; let operations: [String]; let stations: [BackendModelRow]
        let xTitle: String; let yTitle: String
        let valueUnits: DisplayUnitData?
        var stationTableID: String? { schemaId == "RegularSpatiallyVariableTimeSeriesPayloadEditor" && tableId != nil ? pageId + "/Stations" : nil }
        var presentation: SeriesEditorPresentation {
            .init(tableID: tableId, xTitle: xTitle, yTitle: yTitle, xIsDate: xIsDate, canEditX: canEditX, canEditY: tableId == nil,
                operations: Set(operations.compactMap(SeriesEditOperation.init(rawValue:))), stationTableID: stationTableID, valueUnits: valueUnits)
        }
        var table: EditorTablePresentation { .init(columns: columns.map(\.column)) }
        var stationTable: EditorTablePresentation { .init(columns: [.init(id: "Station", title: "Station", sourceType: "double", width: 130)]) }
        func editResult(state: String?, fields: [String: String], operation: SeriesEditOperation) -> SeriesEditResult {
            .init(changed: operation != .refresh, samples: samples.map(\.sample), rows: tableId == nil ? nil : rows.map(\.editorRow),
                presentation: presentation, table: tableId == nil ? nil : table, sourceState: state,
                additionalRows: stationTableID.map { [$0: stations.map(\.editorRow)] } ?? [:],
                additionalTables: stationTableID.map { [$0: stationTable] } ?? [:], fields: fields)
        }
    }
    let lines: [Line]
    let series: [String: Series]
    let selectedLineId: String?
    let selectedPayloadId: String?
    let spatial: [String: SpatialPointPresentation]?
    func apply(to snapshot: inout EditorSnapshot) {
        let presentations = lines.map { line in
            var result = line.presentation
            if line.id == selectedLineId { result.selectedPayloadID = selectedPayloadId }
            return result
        }
        snapshot.boundaryLines = .init(lines: presentations, selectedLineID: selectedLineId ?? presentations.first?.id)
        for (id, data) in spatial ?? [:] { snapshot.spatialPresentations[id] = .init(pointData: data) }
        for (key, data) in series {
            snapshot.samples[key] = data.samples.map(\.sample)
            snapshot.seriesPresentations[key] = data.presentation
            if data.tableId == nil { snapshot.editableSamplePages.insert(key) }
            if let tableID = data.tableId { snapshot.rows[tableID] = data.rows.map(\.editorRow); snapshot.tablePresentations[tableID] = data.table }
            if let tableID = data.stationTableID { snapshot.rows[tableID] = data.stations.map(\.editorRow); snapshot.tablePresentations[tableID] = data.stationTable }
        }
    }
}
