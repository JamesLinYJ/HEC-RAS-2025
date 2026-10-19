import RASWorkspaceCore
import SwiftUI
import AppKit

private struct SeriesTableCellAddress: Hashable {
    let scope: String
    let rowID: String
    let columnID: String
}

private struct SeriesPrimaryTimeline {
    let name: String
    let start: Date?
    let end: Date?
}

struct SeriesPlotPoint: Identifiable {
    struct ID: Hashable { let dataset: String; let sample: String }
    struct SegmentID: Hashable { let dataset: String; let index: Int }
    let sample: ChartSample
    let segment: Int
    var isIsolated = false
    var id: ID { .init(dataset: sample.datasetKey, sample: sample.id) }
    var segmentID: SegmentID { .init(dataset: sample.datasetKey, index: segment) }
    static func segments(_ samples: [ChartSample]) -> [Self] {
        var segments: [String: Int] = [:]
        var counts: [SegmentID: Int] = [:]
        let points: [Self] = samples.compactMap { sample in
            guard sample.x.isFinite, sample.y.isFinite else { segments[sample.datasetKey, default: 0] += 1; return nil }
            let point = Self(sample: sample, segment: segments[sample.datasetKey, default: 0])
            counts[point.segmentID, default: 0] += 1
            return point
        }
        return points.map { Self(sample: $0.sample, segment: $0.segment, isIsolated: counts[$0.segmentID] == 1) }
    }
}
struct SeriesSampleDisplayRow: Identifiable {
    let sample: ChartSample
    var id: SeriesPlotPoint.ID { .init(dataset: sample.datasetKey, sample: sample.id) }
}

// TimeSeriesPayloadTable, TimeSeriesPayloadChart and the spatially-variable
// station table share one source payload scope, draft and capability record.
struct TimeSeriesPage: View {
    let page: ModelEditorPage
    @ObservedObject var session: ModelEditorSession
    @ObservedObject var store: WorkspaceStore
    var chartOnly = false
    var boundaryInspectorLayout = false
    @Environment(\.openWindow) private var openWindow
    @State private var chartMode = "Chart"
    @State private var dataset = ""
    @State private var showProperties = true
    @State private var confirmClear = false
    @State private var refreshedSignature: String?
    @State private var showsTableFilter = false
    @State private var tableSortColumnID = ""
    @State private var tableSortAscending = true
    @State private var selectedCellAnchor: SeriesTableCellAddress?
    @State private var selectedCellExtent: SeriesTableCellAddress?
    @State private var selectedAdditionalCells: Set<SeriesTableCellAddress> = []
    @StateObject private var tableFilter = TableExpressionFilterSession()
    private var presentation: SeriesEditorPresentation { session.seriesPresentations[page.id] ?? .init() }
    private var displayUnit: DisplayUnitChoice? { presentation.valueUnits.flatMap(session.displayUnit) }
    private var displaySamples: [ChartSample] {
        guard let unit = displayUnit else { return samples }
        return samples.map { sample in var value = sample; if value.y.isFinite { value.y = unit.displayed(value.y) }; return value }
    }
    private var displayPresentation: SeriesEditorPresentation {
        var result = presentation
        if let unit = displayUnit { result.yTitle = L10n.text(result.yTitle) + " (" + unit.id + ")" }
        return result
    }
    private var samples: [ChartSample] { (session.samples[page.id] ?? []).filter { dataset.isEmpty || $0.datasetKey == dataset } }
    private var sourceTableID: String? { chartOnly ? nil : presentation.tableID }
    private var sourceTableColumns: [SourceTableColumn] {
        guard let tableID = sourceTableID else { return [] }
        return (session.tablePresentations[tableID]?.columns ?? []).filter { $0.visible != false }
    }
    private var sortableTableColumns: [SourceTableColumn] { sourceTableColumns.filter { $0.sortable != false } }
    private var hasFilterableTableColumns: Bool { sourceTableColumns.contains { $0.filterable != false } }
    private var selectedPayloadIdentity: String {
        let lineID = session.selectedBoundaryLineID ?? ""
        let payloadID = session.selectedBoundaryPayloadIDs[lineID] ?? ""
        return lineID + "|" + payloadID
    }
    private var tableFilterCapture: TableFilterCapture {
        guard let tableID = sourceTableID else {
            return .init(owner: page.id, columns: [], rows: [])
        }
        return TableFilterCapture(
            owner: [store.projectSessionID.uuidString, session.id.uuidString, session.modelAssetID ?? "",
                    session.sourceFileRevision ?? "", selectedPayloadIdentity, page.id, page.scopePrefix ?? "", tableID].joined(separator: "|"),
            columns: (session.tablePresentations[tableID]?.columns ?? []).map {
                .init(id: $0.id, name: $0.title, sourceType: $0.sourceType, filterable: $0.filterable != false)
            },
            rows: (session.rows[tableID] ?? []).map { .init(id: $0.id, values: $0.values) }
        )
    }
    private var visibleSourceTableRows: [EditorRow] {
        guard let tableID = sourceTableID else { return [] }
        let sourceRows = session.rows[tableID] ?? []
        let matchingIDs = tableFilter.appliedExpression.isEmpty ? nil : tableFilter.matchingRowIDs
        var rows = matchingIDs.map { ids in sourceRows.filter { ids.contains($0.id) } } ?? sourceRows
        guard let column = sortableTableColumns.first(where: { $0.id == tableSortColumnID }) else { return rows }
        rows.sort { lhs, rhs in
            let comparison = compareTableValues(lhs.values[column.id] ?? "", rhs.values[column.id] ?? "", sourceType: column.sourceType)
            if comparison == .orderedSame { return lhs.id.localizedStandardCompare(rhs.id) == .orderedAscending }
            return tableSortAscending ? comparison == .orderedAscending : comparison == .orderedDescending
        }
        return rows
    }
    private var tableSelectionScope: String {
        [store.projectSessionID.uuidString, session.id.uuidString, session.modelAssetID ?? "",
         session.sourceFileRevision ?? "", selectedPayloadIdentity, page.id, page.scopePrefix ?? "", sourceTableID ?? "",
         dataset, visibleSourceTableRows.map(\.id).joined(separator: ","), sourceTableColumns.map(\.id).joined(separator: ",")]
            .joined(separator: "|")
    }
    private var tableSortIdentity: String {
        [store.projectSessionID.uuidString, session.id.uuidString, session.modelAssetID ?? "",
         session.sourceFileRevision ?? "", selectedPayloadIdentity, page.id, page.scopePrefix ?? "", sourceTableID ?? ""].joined(separator: "|")
    }
    private var tableFilterRefreshIdentity: String {
        [store.projectSessionID.uuidString, session.id.uuidString, session.modelAssetID ?? "",
         session.sourceFileRevision ?? "", selectedPayloadIdentity, page.id, page.scopePrefix ?? "", sourceTableID ?? ""].joined(separator: "|")
    }
    private var selectedCellBounds: (rows: ClosedRange<Int>, columns: ClosedRange<Int>)? {
        guard let anchor = selectedCellAnchor, let extent = selectedCellExtent,
              anchor.scope == tableSelectionScope, extent.scope == tableSelectionScope,
              let anchorRow = visibleSourceTableRows.firstIndex(where: { $0.id == anchor.rowID }),
              let extentRow = visibleSourceTableRows.firstIndex(where: { $0.id == extent.rowID }),
              let anchorColumn = sourceTableColumns.firstIndex(where: { $0.id == anchor.columnID }),
              let extentColumn = sourceTableColumns.firstIndex(where: { $0.id == extent.columnID }) else { return nil }
        return (min(anchorRow, extentRow)...max(anchorRow, extentRow), min(anchorColumn, extentColumn)...max(anchorColumn, extentColumn))
    }
    private var selectedCopyBounds: (rows: ClosedRange<Int>, columns: ClosedRange<Int>)? {
        var rowBounds: ClosedRange<Int>?
        var columnBounds: ClosedRange<Int>?
        if let bounds = selectedCellBounds {
            rowBounds = bounds.rows
            columnBounds = bounds.columns
        }
        for address in selectedAdditionalCells where address.scope == tableSelectionScope {
            guard let row = visibleSourceTableRows.firstIndex(where: { $0.id == address.rowID }),
                  let column = sourceTableColumns.firstIndex(where: { $0.id == address.columnID }) else { continue }
            rowBounds = rowBounds.map { min($0.lowerBound, row)...max($0.upperBound, row) } ?? (row...row)
            columnBounds = columnBounds.map { min($0.lowerBound, column)...max($0.upperBound, column) } ?? (column...column)
        }
        guard let rows = rowBounds, let columns = columnBounds else { return nil }
        return (rows, columns)
    }
    private var primaryTimeline: SeriesPrimaryTimeline? {
        let regularHosts: Set<String> = ["RegularTimeSeriesPayloadEditor", "RegularSpatiallyVariableTimeSeriesPayloadEditor"]
        guard let schema = page.schemaIDs.lazy.filter(regularHosts.contains).compactMap(SourceEditorLibrary.shared.schema).first,
              let startField = schema.fields.first(where: { $0.sourceControl == "timeline" && $0.id.hasSuffix("_StartTime") }),
              let endField = schema.fields.first(where: { $0.sourceControl == "timeline" && $0.id.hasSuffix("_EndTime") }) else { return nil }
        let start = session.fields[startField.inScope(page.scopePrefix).storageID].flatMap {
            OriginalDateTimeDraftCodec.parseStoredValue($0)
        }
        let end = session.fields[endField.inScope(page.scopePrefix).storageID].flatMap {
            OriginalDateTimeDraftCodec.parseStoredValue($0)
        }
        let matchingLine = session.boundaryLines?.lines.first { line in
            guard let scope = page.scopePrefix else { return false }
            return line.payloads.contains(where: { $0.scope == scope })
        }
        let lineName = matchingLine.map { session.boundaryLineName($0) } ?? L10n.text("Boundary Condition")
        return SeriesPrimaryTimeline(name: lineName, start: start, end: end)
    }
    private var datasets: [EditorChoice] {
        let chart = SeriesChartPresentation.resolved(presentation, samples: session.samples[page.id] ?? [])
        return chart.datasets.map { .init(id: $0.id, title: $0.displayName, titleIsUserData: true) }
    }
    private var hasProperties: Bool { page.schemaIDs.contains { SourceEditorLibrary.shared.schema($0) != nil } }
    private var editable: Bool { session.canEdit && !session.isBusy && !session.loadingSelection && !store.isSavingAll }
    private var boundaryPropertyFields: [SourceEditorField] {
        page.schemaIDs
            .compactMap { SourceEditorLibrary.shared.schema($0) }
            .flatMap { schema in schema.fields.map { $0.inScope(page.scopePrefix) } }
            .filter { field in
                !field.visibleBy.contains { route in
                    let value = session.fields[field.scoped(route)]?.lowercased()
                    if route.contains("IsDebugMode") { return !store.isDebugMode && value != "visible" && value != "true" }
                    return value == "collapsed" || value == "hidden" || value == "false"
                }
            }
    }
    var body: some View {
        Group {
            if boundaryInspectorLayout, !chartOnly, hasProperties {
                ScrollView(.vertical) {
                    VStack(spacing: 0) {
                        controls
                        sourceTimeline
                        sourceTableControls
                        if let chart = presentation.chart {
                            ResultChartActions(pageID: page.id, presentation: chart, session: session, store: store)
                        }
                        chartContent
                            .frame(height: 240)
                        stationLocations
                        boundarySeriesProperties
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 0) {
                    controls
                    sourceTimeline
                    sourceTableControls
                    if let chart = presentation.chart {
                        ResultChartActions(pageID: page.id, presentation: chart, session: session, store: store)
                    }
                    chartContent
                    if !chartOnly {
                        stationLocations
                    }
                    if !chartOnly, hasProperties {
                        Divider()
                        DisclosureGroup("Series Properties", isExpanded: $showProperties) {
                            SourceForm(page: page, session: session, store: store).frame(minHeight: 100, idealHeight: 160, maxHeight: 230)
                        }.padding(12)
                    }
                }
            }
        }
        .onChange(of: datasets.map(\.id)) { _, values in if !values.contains(dataset) { dataset = "" } }
        .onChange(of: tableSelectionScope) { _, _ in
            selectedCellAnchor = nil
            selectedCellExtent = nil
            selectedAdditionalCells = []
        }
        .onChange(of: chartMode) { _, mode in
            if mode != "Table" { selectedCellAnchor = nil; selectedCellExtent = nil; selectedAdditionalCells = [] }
        }
        .onChange(of: sortableTableColumns.map(\.id)) { _, ids in
            if !ids.contains(tableSortColumnID) { tableSortColumnID = "" }
        }
        .onChange(of: tableSortIdentity) { _, _ in
            tableSortColumnID = ""
            tableSortAscending = true
        }
        .task(id: refreshSignature) {
            let signature = refreshSignature
            guard !chartOnly, presentation.operations.contains(.refresh), signature != refreshedSignature else { return }
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            guard !session.isBusy, !session.loadingSelection else { return }
            refreshedSignature = signature
            if await session.editSeries(pageID: page.id, operation: .refresh) { refreshedSignature = refreshSignature }
        }
        .task(id: tableFilterRefreshIdentity + "|" + refreshSignature) {
            guard sourceTableID != nil, !tableFilter.appliedExpression.isEmpty else { return }
            await tableFilter.refresh(tableFilterCapture)
        }
        .confirmationDialog("Clear all values in this series?", isPresented: $confirmClear) {
            Button("Clear Values", role: .destructive) { Task { await session.editSeries(pageID: page.id, operation: .clear) } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("The values will be cleared in the current draft. Save the model to write the change.") }
    }

    @ViewBuilder private var chartContent: some View {
        if chartMode == "Chart" {
            SeriesChartView(samples: displaySamples, presentation: displayPresentation)
        } else {
            table
        }
    }

    @ViewBuilder private var stationLocations: some View {
        if !chartOnly, let stationTableID = presentation.stationTableID {
            DisclosureGroup("Station Locations") {
                Table(session.rows[stationTableID] ?? []) {
                    TableColumn(L10n.text("Station")) { row in Text(row.id.replacingOccurrences(of: "station/", with: "")) }
                    TableColumn(L10n.text("Location")) { row in
                        TableCell(column: .init(id: "Station", title: "Location", sourceType: "double"), rowID: row.id, tableID: stationTableID, session: session, store: store)
                    }
                }.frame(minHeight: 80, idealHeight: 120, maxHeight: 180)
            }.padding(12)
        }
    }

    private var boundarySeriesProperties: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Series Properties")
                .font(.headline)
            Divider()
            SourceFieldRows(fields: boundaryPropertyFields, session: session, store: store)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { selectionControls; Spacer(minLength: 0) }
            HStack { Spacer(minLength: 0); actionControls }
        }.padding(12)
    }
    @ViewBuilder private var sourceTimeline: some View {
        if !chartOnly, let timeline = primaryTimeline {
            VStack(alignment: .leading, spacing: 4) {
                if let start = timeline.start, let end = timeline.end, end < start {
                    Label("The end time must follow the start time.", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.red)
                } else {
                    SourceTimelineView(primaryLineName: timeline.name, startTime: timeline.start, endTime: timeline.end, entries: [])
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
    }
    @ViewBuilder private var sourceTableControls: some View {
        if chartMode == "Table", sourceTableID != nil {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 12) {
                    if !sortableTableColumns.isEmpty {
                        Menu {
                            ForEach(sortableTableColumns) { column in
                                Menu {
                                    Button("Ascending") {
                                        tableSortColumnID = column.id
                                        tableSortAscending = true
                                    }
                                    Button("Descending") {
                                        tableSortColumnID = column.id
                                        tableSortAscending = false
                                    }
                                } label: {
                                    Text(verbatim: column.localizedTitle)
                                }
                            }
                            if !tableSortColumnID.isEmpty {
                                Divider()
                                Button("Clear Sort") { tableSortColumnID = "" }
                            }
                        } label: {
                            Label("Sort", systemImage: "arrow.up.arrow.down")
                        }
                    }
                    if hasFilterableTableColumns {
                        Toggle("Filter Expression", isOn: $showsTableFilter)
                            .toggleStyle(.checkbox)
                    }
                    if let sorted = sortableTableColumns.first(where: { $0.id == tableSortColumnID }) {
                        Text(verbatim: sorted.localizedTitle + (tableSortAscending ? " ↑" : " ↓"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Button("Copy Selection") { copySelectedTableCells() }
                        .disabled(selectedCopyBounds == nil)
                }
                Text("Click a cell to select it. Shift-click extends a range; Command-click adds cells.")
                    .font(.caption).foregroundStyle(.secondary)
                if showsTableFilter, hasFilterableTableColumns {
                    TableExpressionFilterBar(session: tableFilter, capture: tableFilterCapture)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
    }
    @ViewBuilder private var selectionControls: some View {
            if !chartOnly {
                Picker("View", selection: $chartMode) { Text("Chart").tag("Chart"); Text("Table").tag("Table") }.pickerStyle(.segmented).labelsHidden().frame(width: 170)
            } else {
                Button(chartMode == "Chart" ? "Show Data Table" : "Show Chart") { chartMode = chartMode == "Chart" ? "Table" : "Chart" }
            }
            Picker("Dataset", selection: $dataset) {
                Text("All Series").tag("")
                ForEach(datasets) { Text($0.title).tag($0.id) }
            }.labelsHidden().frame(maxWidth: 230).disabled(!chartOnly && chartMode == "Table" && presentation.tableID != nil)
            if let units = presentation.valueUnits { DisplayUnitPicker(units: units, session: session, isEnabled: editable) }
    }
    @ViewBuilder private var actionControls: some View {
            Button { copyValues() } label: { Label(chartMode == "Table" && sourceTableID != nil ? "Copy Selection" : "Copy Values", systemImage: "doc.on.clipboard") }
                .labelStyle(.iconOnly)
                .help(chartMode == "Table" && sourceTableID != nil ? "Copy Selection" : "Copy Values")
                .keyboardShortcut("c", modifiers: .command)
                .disabled(chartMode == "Table" && presentation.tableID != nil
                    ? (sourceTableID != nil ? selectedCopyBounds == nil : false)
                    : samples.isEmpty)
            if !chartOnly {
                Menu {
                    if presentation.operations.contains(.refresh) {
                        Button("Refresh Preview") { Task { _ = await session.editSeries(pageID: page.id, operation: .refresh) } }.disabled(!editable)
                    }
                    Button("Interpolate Missing Values") { Task { await session.editSeries(pageID: page.id, operation: .interpolate) } }
                        .disabled(!editable || !presentation.operations.contains(.interpolate))
                    Button("Add Station") { Task { await session.editSeries(pageID: page.id, operation: .addStation) } }
                        .disabled(!editable || !presentation.operations.contains(.addStation))
                    if presentation.operations.contains(.appendRow) {
                        Button("Add Row") { Task { await session.editSeries(pageID: page.id, operation: .appendRow) } }.disabled(!editable)
                    }
                    if presentation.operations.contains(.removeLastRow) {
                        Button("Remove Last Row", role: .destructive) { Task { await session.editSeries(pageID: page.id, operation: .removeLastRow) } }
                            .disabled(!editable || (presentation.tableID.map { session.rows[$0]?.isEmpty ?? true } ?? samples.isEmpty))
                    }
                    if sourceTableID != nil {
                        Divider()
                        Button("Copy All Values") { copyAllTableValues() }
                    }
                    Divider()
                    Button("Clear Values", role: .destructive) { confirmClear = true }.disabled(!editable || !presentation.operations.contains(.clear))
                } label: { Label("Series Actions", systemImage: "ellipsis.circle") }
                Button { openChart() } label: { Label("Open Chart", systemImage: "arrow.up.forward.square") }
                    .labelStyle(.iconOnly).help("Open Chart").disabled(!session.loaded || session.modelAssetID == nil || session.samples[page.id] == nil)
            }
    }
    @ViewBuilder private var table: some View {
        if let tableID = presentation.tableID,
           let allColumns = session.tablePresentations[tableID]?.columns {
            let columns = allColumns.filter { $0.visible != false }
            Table(chartOnly ? (session.rows[tableID] ?? []) : visibleSourceTableRows) {
                TableColumnForEach(chartOnly ? columns : sourceTableColumns) { column in
                    TableColumn(column.localizedTitle) { (row: EditorRow) in
                        if chartOnly { Text(displayValue(row.values[column.id] ?? "", column: column)).textSelection(.enabled) }
                        else {
                            TableCell(column: column, rowID: row.id, tableID: tableID, session: session, store: store, units: numericUnits(column))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(cellIsSelected(rowID: row.id, columnID: column.id) ? Color.accentColor.opacity(0.16) : .clear)
                                .overlay {
                                    if cellIsSelected(rowID: row.id, columnID: column.id) {
                                        Rectangle().stroke(Color.accentColor.opacity(0.8), lineWidth: 1)
                                    }
                                }
                                .contentShape(Rectangle())
                                .simultaneousGesture(TapGesture().onEnded {
                                    selectTableCell(rowID: row.id, columnID: column.id,
                                                    extending: NSEvent.modifierFlags.contains(.shift),
                                                    adding: NSEvent.modifierFlags.contains(.command) || NSEvent.modifierFlags.contains(.control))
                                })
                                .contextMenu {
                                    Button("Copy Values") { copyTableCell(rowID: row.id, columnID: column.id) }
                                }
                        }
                    }.width(min: 60, ideal: column.width ?? 130)
                }
            }
        } else {
            Table(samples.map { SeriesSampleDisplayRow(sample: $0) }) {
                TableColumn(L10n.text(presentation.xTitle)) { row in sampleCell(row.sample, xAxis: true) }
                TableColumn(L10n.text(presentation.yTitle)) { row in sampleCell(row.sample, xAxis: false) }
                TableColumn(L10n.text("Series"), value: \.sample.series)
                if presentation.chart != nil {
                    TableColumn(L10n.text("X Axis")) { row in Text(axis(row.sample, xAxis: true).displayTitle) }
                    TableColumn(L10n.text("Y Axis")) { row in Text(axis(row.sample, xAxis: false).displayTitle) }
                }
            }
        }
    }
    @ViewBuilder private func sampleCell(_ sample: ChartSample, xAxis: Bool) -> some View {
        let value = xAxis ? sample.x : sample.y
        if !chartOnly, session.canEditSampleAxis(page.id, xAxis: xAxis), !store.isSavingAll {
            if xAxis, axis(sample, xAxis: true).isDate, value.isFinite {
                DatePicker("Time", selection: Binding(get: {
                    Date(timeIntervalSince1970: session.samples[page.id]?.first { $0.id == sample.id && $0.datasetKey == sample.datasetKey }?.x ?? sample.x)
                }, set: { session.setSample(page: page.id, id: sample.id, x: $0.timeIntervalSince1970, datasetID: sample.datasetKey) }), displayedComponents: [.date, .hourAndMinute]).labelsHidden()
            } else {
                TextField("", value: Binding<Double?>(get: {
                    let current = session.samples[page.id]?.first { $0.id == sample.id && $0.datasetKey == sample.datasetKey } ?? sample
                    let number = xAxis ? current.x : current.y
                    return number.isFinite ? (!xAxis ? displayUnit?.displayed(number) ?? number : number) : nil
                }, set: { value in
                    let source = value.map { !xAxis ? displayUnit?.source($0) ?? $0 : $0 }
                    session.setSample(page: page.id, id: sample.id, x: xAxis ? source : nil, y: xAxis ? nil : (source ?? .nan), datasetID: sample.datasetKey)
                }), format: .number)
                    .textFieldStyle(.plain).accessibilityLabel(LocalizedStringKey(xAxis ? presentation.xTitle : presentation.yTitle))
            }
        } else if !value.isFinite { Text("—") }
        else if xAxis && axis(sample, xAxis: true).isDate { Text(Date(timeIntervalSince1970: value), format: .dateTime.year().month().day().hour().minute().second()) }
        else { Text((!xAxis ? displayUnit?.displayed(value) ?? value : value).formatted()) }
    }
    private func axis(_ sample: ChartSample, xAxis: Bool) -> PlotAxisPresentation {
        if let chart = presentation.chart, let dataset = chart.datasets.first(where: { $0.id == sample.datasetKey }),
           let axis = chart.axes.first(where: { $0.id == (xAxis ? dataset.xAxisID : dataset.yAxisID) }) { return axis }
        return .init(id: xAxis ? "x" : "y", direction: xAxis ? .x : .y, title: xAxis ? presentation.xTitle : presentation.yTitle, isDate: xAxis && presentation.xIsDate)
    }
    private func copyValues() {
        if chartMode == "Table", let tableID = presentation.tableID {
            if sourceTableID != nil { copySelectedTableCells() }
            else { copyAllTableValues(tableID: tableID) }
            return
        }
        func escape(_ value: String) -> String { escapeTableCell(value) }
        let lines = samples.map { sample in
            var values = [!sample.x.isFinite ? "" : axis(sample, xAxis: true).isDate ? ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: sample.x)) : String(sample.x), sample.y.isFinite ? String(displayUnit?.displayed(sample.y) ?? sample.y) : "", sample.series]
            if presentation.chart != nil { values += [axis(sample, xAxis: true).displayTitle, axis(sample, xAxis: false).displayTitle] }
            return values.map(escape).joined(separator: "\t")
        }
        var headers = [L10n.text(presentation.xTitle), L10n.text(displayPresentation.yTitle), L10n.text("Series")]
        if presentation.chart != nil { headers += [L10n.text("X Axis"), L10n.text("Y Axis")] }
        store.system.copy((headers.map(escape).joined(separator: "\t") + "\n") + lines.joined(separator: "\n"))
    }
    private func escapeTableCell(_ value: String) -> String {
        value.contains(where: { $0.isNewline || $0 == "\t" || $0 == "\"" })
            ? "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            : value
    }
    private func copyAllTableValues(tableID: String? = nil) {
        guard let tableID = tableID ?? presentation.tableID,
              let columns = session.tablePresentations[tableID]?.columns.filter({ $0.visible != false }) else { return }
        let header = columns.map {
            escapeTableCell($0.localizedTitle + (numericUnit($0).map { " (" + $0.id + ")" } ?? ""))
        }.joined(separator: "\t")
        let rows = (session.rows[tableID] ?? []).map { row in
            columns.map { escapeTableCell(displayValue(row.values[$0.id] ?? "", column: $0)) }.joined(separator: "\t")
        }
        store.system.copy(([header] + rows).joined(separator: "\n"))
    }
    private func copySelectedTableCells() {
        guard let bounds = selectedCopyBounds else { return }
        let rows = visibleSourceTableRows
        let columns = sourceTableColumns
        guard bounds.rows.upperBound < rows.count, bounds.columns.upperBound < columns.count else { return }
        let text = bounds.rows.map { rowIndex in
            bounds.columns.map { columnIndex in
                let column = columns[columnIndex]
                return escapeTableCell(displayValue(rows[rowIndex].values[column.id] ?? "", column: column))
            }.joined(separator: "\t")
        }.joined(separator: "\n")
        store.system.copy(text)
    }
    private func copyTableCell(rowID: String, columnID: String) {
        guard let row = visibleSourceTableRows.first(where: { $0.id == rowID }),
              let column = sourceTableColumns.first(where: { $0.id == columnID }) else { return }
        store.system.copy(displayValue(row.values[columnID] ?? "", column: column))
    }
    private func cellIsSelected(rowID: String, columnID: String) -> Bool {
        let address = SeriesTableCellAddress(scope: tableSelectionScope, rowID: rowID, columnID: columnID)
        if selectedAdditionalCells.contains(address) { return true }
        guard let bounds = selectedCellBounds,
              let row = visibleSourceTableRows.firstIndex(where: { $0.id == rowID }),
              let column = sourceTableColumns.firstIndex(where: { $0.id == columnID }) else { return false }
        return bounds.rows.contains(row) && bounds.columns.contains(column)
    }
    private func selectTableCell(rowID: String, columnID: String, extending: Bool, adding: Bool) {
        let address = SeriesTableCellAddress(scope: tableSelectionScope, rowID: rowID, columnID: columnID)
        if extending {
            if selectedCellAnchor?.scope != tableSelectionScope {
                selectedCellAnchor = address
                selectedCellExtent = address
            } else {
                selectedCellExtent = address
            }
        } else if adding {
            selectedAdditionalCells.insert(address)
            if selectedCellAnchor == nil {
                selectedCellAnchor = address
                selectedCellExtent = address
            }
        } else {
            selectedCellAnchor = address
            selectedCellExtent = address
            selectedAdditionalCells = []
        }
    }
    private func compareTableValues(_ lhs: String, _ rhs: String, sourceType: String) -> ComparisonResult {
        let type = sourceType.lowercased()
        if type.contains("date") || type.contains("time") {
            if let leftDate = OriginalDateTimeDraftCodec.parseStoredValue(lhs),
               let rightDate = OriginalDateTimeDraftCodec.parseStoredValue(rhs) {
                if leftDate < rightDate { return .orderedAscending }
                if leftDate > rightDate { return .orderedDescending }
                return .orderedSame
            }
        }
        if type.contains("double") || type.contains("float") || type.contains("decimal") || type.contains("int") || type.contains("long") {
            if let leftNumber = Double(lhs), leftNumber.isFinite,
               let rightNumber = Double(rhs), rightNumber.isFinite {
                if leftNumber < rightNumber { return .orderedAscending }
                if leftNumber > rightNumber { return .orderedDescending }
                return .orderedSame
            }
        }
        return lhs.localizedStandardCompare(rhs)
    }
    private func numericUnits(_ column: SourceTableColumn) -> DisplayUnitData? {
        ["double", "float"].contains(column.sourceType) ? presentation.valueUnits : nil
    }
    private func numericUnit(_ column: SourceTableColumn) -> DisplayUnitChoice? { numericUnits(column).flatMap(session.displayUnit) }
    private func displayValue(_ value: String, column: SourceTableColumn) -> String { numericUnit(column)?.string(value) ?? value }
    private var refreshSignature: String {
        let values = session.fields.filter { key, _ in
            key.hasPrefix((page.scopePrefix ?? "") + "/") && (key.contains("TimeSeriesDefinition_") || key.contains("_BoundaryCondition_"))
                || key == "BoundaryConditionsSummary/BoundaryCondition_StartTime" || key == "BoundaryConditionsSummary/BoundaryCondition_EndTime"
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let fieldData = (try? encoder.encode(values))?.base64EncodedString() ?? ""
        let tables = [presentation.tableID, presentation.stationTableID].compactMap { $0 }.map { id in
            (session.rows[id] ?? []).map { row in row.id + ":" + ((try? encoder.encode(row.values))?.base64EncodedString() ?? "") }.joined(separator: ";")
        }.joined(separator: "|")
        return page.id + ":" + fieldData + ":" + tables
    }
    private func openChart() {
        guard let assetID = session.modelAssetID else { return }
        store.registerEditor(session)
        openWindow(value: DetachedDocumentRoute(projectSessionID: store.projectSessionID, editor: nil, mapID: nil,
            series: .init(sessionID: session.id, assetID: assetID, title: page.title, schemas: page.schemaIDs, scope: page.scopePrefix)))
    }
}
