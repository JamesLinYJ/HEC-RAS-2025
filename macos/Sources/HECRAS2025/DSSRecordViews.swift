import Charts
import SwiftUI

struct DSSRecordPresentation: Identifiable {
    enum Mode: String, Equatable, Identifiable {
        case graph
        case table
        var id: String { rawValue }
    }

    let id = UUID()
    let mode: Mode
    let records: [DSSRecordReadResult]
}

struct DSSRecordResultView: View {
    let presentation: DSSRecordPresentation
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if presentation.mode == .graph {
                        graphContent
                    } else {
                        tableContent
                    }
                }
                .padding(18)
            }
            .navigationTitle(presentation.mode == .graph ? L10n.text("DSS Graph") : L10n.text("DSS Table"))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .frame(minWidth: 760, idealWidth: 980, minHeight: 520, idealHeight: 720)
    }

    @ViewBuilder
    private var graphContent: some View {
        let groups = timeSeriesGroups
        ForEach(groups) { group in
            VStack(alignment: .leading, spacing: 12) {
                Text(group.units.isEmpty ? L10n.text("Units not specified") : group.units)
                    .font(.headline)
                DSSTimeSeriesUnitGraphCard(group: group)
            }
        }
        ForEach(pairedDataRecords) { record in
            if let data = record.pairedData {
                DSSPairedDataGraphCard(record: record, data: data)
            }
        }
        ForEach(recordsWithoutGraphData) { record in
            DSSRecordStatusCard(record: record)
        }
    }

    private var tableContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(presentation.records) { record in
                DSSRecordTableCard(record: record)
            }
        }
    }

    private var timeSeriesGroups: [DSSRecordUnitGroup] {
        var grouped: [String: [DSSRecordReadResult]] = [:]
        for record in presentation.records where record.kind == "timeSeries" {
            guard let series = record.timeSeries else { continue }
            grouped[series.units, default: []].append(record)
        }
        return grouped.keys.sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }.map { DSSRecordUnitGroup(units: $0, records: grouped[$0] ?? []) }
    }

    private var pairedDataRecords: [DSSRecordReadResult] {
        presentation.records.filter { $0.kind == "pairedData" && $0.pairedData != nil }
    }

    private var recordsWithoutGraphData: [DSSRecordReadResult] {
        presentation.records.filter { record in
            !((record.kind == "timeSeries" && record.timeSeries != nil)
                || (record.kind == "pairedData" && record.pairedData != nil))
        }
    }
}

private struct DSSRecordUnitGroup: Identifiable {
    let units: String
    let records: [DSSRecordReadResult]
    var id: String { units }
}

private struct DSSRecordHeader: View {
    let record: DSSRecordReadResult

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(record.path).font(.headline).textSelection(.enabled)
            HStack(spacing: 12) {
                LabeledContent("Record Type", value: record.recordType.isEmpty ? L10n.text("(blank)") : L10n.text(record.recordType))
                if let data = record.timeSeries {
                    LabeledContent("Data Type", value: data.dataType.isEmpty ? L10n.text("(not specified)") : data.dataType)
                    LabeledContent("Units", value: data.units.isEmpty ? L10n.text("(not specified)") : data.units)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

private struct DSSTimeSeriesUnitGraphCard: View {
    let group: DSSRecordUnitGroup
    private var segments: [DSSTimeSeriesSegment] {
        group.records.flatMap { record -> [DSSTimeSeriesSegment] in
            guard let data = record.timeSeries else { return [] }
            return Self.makeSegments(record: record, data: data)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if segments.isEmpty {
                ContentUnavailableView("No time-series values are available.", systemImage: "chart.xyaxis.line")
                    .frame(height: 180)
            } else {
                Chart {
                    ForEach(segments) { segment in
                        ForEach(segment.points) { point in
                            if segment.points.count == 1 {
                                PointMark(x: .value("Time", point.x), y: .value("Value", point.value))
                                    .foregroundStyle(by: .value(L10n.text("Record"), segment.recordPath))
                            } else {
                                LineMark(x: .value("Time", point.x), y: .value("Value", point.value),
                                         series: .value("Segment", segment.id))
                                    .foregroundStyle(by: .value(L10n.text("Record"), segment.recordPath))
                            }
                        }
                    }
                }
                .chartLegend(.visible)
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 5)) { axisValue in
                        AxisGridLine()
                        AxisTick()
                        AxisValueLabel {
                            if let x = axisValue.as(Double.self), let label = nearestTimeLabel(to: x) {
                                Text(label).lineLimit(1).fixedSize()
                            }
                        }
                    }
                }
                .chartYAxisLabel(group.units.isEmpty ? L10n.text("Value") : L10n.format("Value (%@)", group.units))
                .frame(height: 250)
            }
            ForEach(group.records) { record in
                if let data = record.timeSeries {
                    VStack(alignment: .leading, spacing: 8) {
                        DSSRecordHeader(record: record)
                        DSSRecordMetadataLocation(location: record.location)
                        DisclosureGroup("Values and quality") {
                            DSSTimeSeriesTable(data: data)
                        }
                    }
                    .padding(.top, 6)
                }
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }

    private func nearestTimeLabel(to x: Double) -> String? {
        segments.flatMap(\.points).min { abs($0.x - x) < abs($1.x - x) }?.time
    }

    private static func makeSegments(record: DSSRecordReadResult,
                                     data: DSSRecordReadResult.TimeSeries) -> [DSSTimeSeriesSegment] {
        var runs: [[DSSTimeSeriesPoint]] = []
        var current: [DSSTimeSeriesPoint] = []
        for index in data.values.indices {
            guard data.times.indices.contains(index), let value = data.values[index],
                  let x = DSSWallClockPosition.scalar(data.times[index]) else {
                if !current.isEmpty { runs.append(current); current = [] }
                continue
            }
            let rawTime = data.times[index]
            current.append(DSSTimeSeriesPoint(id: "\(record.path)-\(index)", x: x, value: value,
                                              time: rawTime))
        }
        if !current.isEmpty { runs.append(current) }
        return runs.enumerated().map {
            DSSTimeSeriesSegment(id: "\(record.path)-segment-\($0.offset)", recordPath: record.path, points: $0.element)
        }
    }
}

private struct DSSTimeSeriesPoint: Identifiable {
    let id: String
    let x: Double
    let value: Double
    let time: String
}

private struct DSSTimeSeriesSegment: Identifiable {
    let id: String
    let recordPath: String
    let points: [DSSTimeSeriesPoint]
}

private struct DSSPairedDataGraphCard: View {
    let record: DSSRecordReadResult
    let data: DSSRecordReadResult.PairedData
    private var segments: [DSSPairedDataSegment] { Self.makeSegments(data) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            DSSRecordHeader(record: record)
            LabeledContent("Independent", value: unitsAndType(data.independentUnits, data.independentType))
                .font(.caption).foregroundStyle(.secondary)
            LabeledContent("Dependent", value: unitsAndType(data.dependentUnits, data.dependentType))
                .font(.caption).foregroundStyle(.secondary)
            if segments.isEmpty {
                ContentUnavailableView("No paired-data values are available.", systemImage: "chart.xyaxis.line")
                    .frame(height: 180)
            } else {
                Chart {
                    ForEach(segments) { segment in
                        ForEach(segment.points) { point in
                            if segment.points.count == 1 {
                                PointMark(x: .value(data.independentUnits, point.x), y: .value(data.dependentUnits, point.y))
                                    .foregroundStyle(by: .value(L10n.text("Curve"), segment.curveTitle))
                            } else {
                                LineMark(x: .value(data.independentUnits, point.x), y: .value(data.dependentUnits, point.y),
                                         series: .value("Curve segment", segment.id))
                                    .foregroundStyle(by: .value(L10n.text("Curve"), segment.curveTitle))
                            }
                        }
                    }
                }
                .chartXAxisLabel(data.independentUnits.isEmpty ? L10n.text("Independent") : L10n.format("Independent (%@)", data.independentUnits))
                .chartYAxisLabel(data.dependentUnits.isEmpty ? L10n.text("Dependent") : L10n.format("Dependent (%@)", data.dependentUnits))
                .frame(height: 260)
            }
            DSSRecordMetadataLocation(location: record.location)
            DisclosureGroup("Values") { DSSPairedDataTable(data: data) }
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }

    private func unitsAndType(_ units: String, _ type: String) -> String {
        [units, type].filter { !$0.isEmpty }.joined(separator: " · ").ifEmpty(L10n.text("(not specified)"))
    }

    private static func makeSegments(_ data: DSSRecordReadResult.PairedData) -> [DSSPairedDataSegment] {
        var result: [DSSPairedDataSegment] = []
        for (curveIndex, curve) in data.curves.enumerated() {
            var runs: [[DSSPairedPoint]] = []
            var current: [DSSPairedPoint] = []
            for index in curve.values.indices {
                guard data.ordinates.indices.contains(index),
                      let x = data.ordinates[index], let y = curve.values[index] else {
                    if !current.isEmpty { runs.append(current); current = [] }
                    continue
                }
                current.append(DSSPairedPoint(id: "\(curveIndex)-\(index)", x: x, y: y))
            }
            if !current.isEmpty { runs.append(current) }
            let curveTitle = "\(curve.label) #\(curveIndex + 1)"
            for (segmentIndex, points) in runs.enumerated() {
                result.append(DSSPairedDataSegment(id: "curve-\(curveIndex)-segment-\(segmentIndex)",
                                                   curveTitle: curveTitle, points: points))
            }
        }
        return result
    }
}

private struct DSSPairedPoint: Identifiable {
    let id: String
    let x: Double
    let y: Double
}

private struct DSSPairedDataSegment: Identifiable {
    let id: String
    let curveTitle: String
    let points: [DSSPairedPoint]
}

private struct DSSRecordTableCard: View {
    let record: DSSRecordReadResult

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            DSSRecordHeader(record: record)
            if record.kind == "timeSeries", let data = record.timeSeries {
                DSSTimeSeriesTable(data: data)
            } else if record.kind == "pairedData", let data = record.pairedData {
                DSSPairedDataTable(data: data)
            } else if record.kind == "location", let location = record.location {
                DSSLocationTable(location: location)
            } else {
                DSSRecordStatus(record: record)
            }
            DSSRecordMetadataLocation(location: record.location)
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct DSSSampleTableRow: Identifiable {
    let id: Int
}

private struct DSSTimeSeriesTable: View {
    let data: DSSRecordReadResult.TimeSeries
    private var rowCount: Int {
        DSSTimeSeriesTableProjection.rowCount(timesCount: data.times.count, valuesCount: data.values.count)
    }

    var body: some View {
        Table((0..<rowCount).map { DSSSampleTableRow(id: $0) }) {
            TableColumn(L10n.text("Time")) { row in
                Text(data.times.indices.contains(row.id) ? data.times[row.id] : "—").textSelection(.enabled)
            }
            TableColumn(L10n.text("Value")) { row in
                Text(data.values.indices.contains(row.id) ? number(data.values[row.id]) : "—")
            }
            TableColumn(L10n.text("Quality")) { row in
                Text(DSSTimeSeriesTableProjection.qualityText(qualities: data.qualities,
                                                              sampleCount: data.values.count,
                                                              sampleIndex: row.id))
            }
        }
        .frame(minHeight: min(CGFloat(max(rowCount, 1) * 28), 80), maxHeight: 240)
    }
}

private struct DSSPairedDataTable: View {
    let data: DSSRecordReadResult.PairedData
    private struct CurveColumn: Identifiable {
        let id: Int
        let label: String
    }
    private var rowCount: Int {
        max(data.ordinates.count, data.curves.map(\.values.count).max() ?? 0)
    }
    private var curveColumns: [CurveColumn] {
        data.curves.enumerated().map { CurveColumn(id: $0.offset, label: $0.element.label) }
    }

    var body: some View {
        Table((0..<rowCount).map { DSSSampleTableRow(id: $0) }) {
            TableColumn(data.independentUnits.isEmpty ? L10n.text("Ordinate") : data.independentUnits) { row in
                Text(data.ordinates.indices.contains(row.id) ? number(data.ordinates[row.id]) : "—")
                    .textSelection(.enabled)
            }
            .width(min: 112, ideal: 140)
            TableColumnForEach(curveColumns) { column in
                TableColumn("\(column.label) #\(column.id + 1)") { (row: DSSSampleTableRow) in
                    Text(data.curves[column.id].values.indices.contains(row.id)
                         ? number(data.curves[column.id].values[row.id]) : "—")
                        .textSelection(.enabled)
                }
                .width(min: 112, ideal: 140)
            }
        }
        .frame(minHeight: min(CGFloat(max(rowCount, 1) * 28), 80), maxHeight: 240)
    }
}

private struct DSSLocationTable: View {
    let location: DSSRecordReadResult.Location

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
            row("X", number(location.x))
            row("Y", number(location.y))
            row("Z", number(location.z))
            row("Coordinate System", L10n.text(location.coordinateSystem))
            row("Coordinate ID", String(location.coordinateID))
            row("Horizontal Units", String(location.horizontalUnits))
            row("Horizontal Datum", String(location.horizontalDatum))
            row("Vertical Units", String(location.verticalUnits))
            row("Vertical Datum", String(location.verticalDatum))
            row("Time Zone", location.timeZoneName)
            row("Supplemental", location.supplemental)
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(L10n.text(label)).foregroundStyle(.secondary)
            Text(value.isEmpty ? "—" : value).textSelection(.enabled)
        }
    }
}

private struct DSSRecordMetadataLocation: View {
    let location: DSSRecordReadResult.Location?

    var body: some View {
        if let location {
            DisclosureGroup("Location Information") {
                DSSLocationTable(location: location)
                    .padding(.top, 6)
            }
        }
    }
}

private struct DSSRecordStatusCard: View {
    let record: DSSRecordReadResult

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            DSSRecordHeader(record: record)
            DSSRecordStatus(record: record)
            DSSRecordMetadataLocation(location: record.location)
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct DSSRecordStatus: View {
    let record: DSSRecordReadResult

    var body: some View {
        let message: String
        let symbol: String
        let isError: Bool
        switch record.kind {
        case "error":
            message = record.error.flatMap { $0.isEmpty ? nil : $0 } ?? L10n.text("The source reported an error for this record.")
            symbol = "exclamationmark.triangle.fill"
            isError = true
        case "unsupported":
            message = record.error.flatMap { $0.isEmpty ? nil : $0 } ?? L10n.text("This DSS record type is not supported for graph or table data.")
            symbol = "nosign"
            isError = false
        case "location" where record.location == nil:
            message = L10n.text("The source did not return location information for this record.")
            symbol = "exclamationmark.triangle"
            isError = true
        case "timeSeries" where record.timeSeries == nil:
            message = L10n.text("The source did not return time-series data for this record.")
            symbol = "exclamationmark.triangle"
            isError = true
        case "pairedData" where record.pairedData == nil:
            message = L10n.text("The source did not return paired-data values for this record.")
            symbol = "exclamationmark.triangle"
            isError = true
        default:
            message = L10n.format("Unsupported DSS record result kind: %@", record.kind)
            symbol = "questionmark.circle"
            isError = false
        }
        return Label(message, systemImage: symbol)
            .foregroundStyle(isError ? Color.red : Color.secondary)
            .textSelection(.enabled)
    }
}

private func number(_ value: Double?) -> String {
    guard let value else { return "—" }
    return value.formatted(.number.precision(.fractionLength(0...8)))
}

private extension String {
    func ifEmpty(_ alternative: String) -> String { isEmpty ? alternative : self }
}
