import Foundation
import RASWorkspaceCore

// TimeSeriesPayloadTable / SpatiallyVariableTimesSeriesPayloadTable capabilities
// are per payload, not global editor permissions. A regular date column can be
// read-only while its value columns remain editable.
enum SeriesEditOperation: String, Hashable, Sendable { case clear, interpolate, addStation, refresh, appendRow, removeLastRow }
struct SeriesEditorPresentation: Sendable {
    var tableID: String? = nil
    var xTitle = "Time / Station"
    var yTitle = "Value"
    var xIsDate = false
    var canEditX = false
    var canEditY = true
    var operations: Set<SeriesEditOperation> = []
    var chart: SeriesChartPresentation? = nil
    var stationTableID: String? = nil
    var valueUnits: DisplayUnitData? = nil
}
struct SeriesEditRequest: Sendable {
    let pageID: String
    let operation: SeriesEditOperation
    let edits: EditorEdits
}
struct SeriesEditResult: Sendable {
    let changed: Bool
    var samples: [ChartSample]? = nil
    var rows: [EditorRow]? = nil
    var presentation: SeriesEditorPresentation? = nil
    var table: EditorTablePresentation? = nil
    var sourceState: String? = nil
    var additionalRows: [String: [EditorRow]] = [:]
    var additionalTables: [String: EditorTablePresentation] = [:]
    var fields: [String: String]? = nil
}

// Spatial controls switch scalar/point/grid surfaces. Dataset identity, column
// definitions, timesteps and map preview come from the source adapter.
struct SpatialDatasetPresentation: Sendable {
    var gridData: SpatialGridData? = nil
    var pointData: SpatialPointPresentation? = nil
    var sourceFieldID: String? = nil
    var tableID: String? = nil
    var preview = DataToolPreview()
    var timeSteps: [DataToolTimeStep] = []
    var selectedTimeStepID: String? = nil
    var canSelectTime = false
    var canImport = false
    var importTool: ToolKind = .spatialImport
    var seriesPage: ModelEditorPage? = nil
    func validate() throws {
        try gridData?.preview?.validate()
        let ids = timeSteps.map(\.id)
        if let data = pointData {
            try data.valueUnits?.validate(); try data.heightUnits?.validate(); try data.intervalUnits?.validate()
            let stationIDs = data.stations.map(\.id), inputIDs = data.inputs.map(\.id)
            guard Set(stationIDs).count == stationIDs.count, Set(inputIDs).count == inputIDs.count,
                  stationIDs.allSatisfy({ !$0.isEmpty }), inputIDs.allSatisfy({ !$0.isEmpty }),
                  data.stations.allSatisfy({ $0.x.isFinite && $0.y.isFinite }),
                  data.inputs.allSatisfy({ $0.stationId.map(stationIDs.contains) ?? true }) else {
                throw ProjectFileError.invalid("Spatial point inputs contain invalid identities or coordinates.")
            }
        }
        guard Set(ids).count == ids.count, ids.allSatisfy({ !$0.isEmpty }),
              selectedTimeStepID.map(ids.contains) ?? true,
              timeSteps.allSatisfy({ $0.date.timeIntervalSince1970.isFinite }) else {
            throw ProjectFileError.invalid("Spatial timesteps contain invalid identities or dates.")
        }
    }
}

extension EditorSnapshot {
    func validatePresentation() throws {
        guard readOnlyFieldIDs.isSubset(of: Set(fields.keys)) else {
            throw ProjectFileError.invalid("The source marked unknown fields as read-only.")
        }
        try boundaryLines?.validate()
        for values in samples.values {
            guard values.allSatisfy({ !$0.id.isEmpty }),
                  Set(values.map { SeriesPlotPoint.ID(dataset: $0.datasetKey, sample: $0.id) }).count == values.count else {
                throw ProjectFileError.invalid("The source chart contains duplicate sample identities within a dataset.")
            }
        }
        for presentation in spatialPresentations.values { try presentation.validate() }
        for (page, presentation) in seriesPresentations { try presentation.chart?.validate(samples: samples[page] ?? []); try presentation.valueUnits?.validate() }
        for presentation in tablePresentations.values {
            try presentation.selection?.detail?.validate()
            let ids = presentation.columns.map(\.id)
            guard Set(ids).count == ids.count else { throw ProjectFileError.invalid("The source table contains duplicate column identities.") }
        }
        for collection in sourceCollections.values {
            for detail in collection.itemDetails.values { try detail.validate() }
        }
    }
}
