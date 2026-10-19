import Charts
import SwiftUI

private struct DisplayRequest: Hashable, Sendable {
    let payload: ChatDisplayPayload
    let objects: [String: ChatDisplayObject]
    enum Prepared: Sendable { case table(MessageTable), chart([MessageSeries], isTime: Bool), fallback(String), error(String) }
    func prepare() throws -> Prepared {
        switch payload {
        case .table(let message): return .table(try message.table(objects: objects))
        case .chart(let message):
            switch message.chartType.lowercased() {
            case "table": return .table(try message.table())
            case "xy", "datetime": return .chart(try message.series(), isTime: message.chartType.lowercased() == "datetime")
            default: return .fallback(message.jsonData)
            }
        }
    }
}

// Original TableMessageControl/ChartMessageControl presentation. Raw source
// JSON and optional resolved source objects are parsed off the main actor.
struct ChatDisplayView: View {
    let payload: ChatDisplayPayload
    let objects: [String: ChatDisplayObject]
    @ObservedObject var store: WorkspaceStore
    var onDock: (() -> Void)? = nil
    var fillsDocument = false
    @State private var prepared: DisplayRequest.Prepared?
    private var request: DisplayRequest { .init(payload: payload, objects: objects) }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(payload.displayTitle).font(.headline)
                Spacer()
                if let timestamp = payload.timestamp { Text(timestamp.formatted()).font(.caption).foregroundStyle(.secondary) }
                if let onDock { Button(action: onDock) { Label("Dock", systemImage: "rectangle.split.2x1") } }
            }
            switch prepared {
            case .table(let table): MessageTableView(model: table, store: store).frame(minHeight: 160, idealHeight: 260, maxHeight: fillsDocument ? .infinity : 400)
            case .chart(let series, let isTime):
                MessageChartView(series: series, isTime: isTime, xLabel: xLabel, yLabel: yLabel)
                    .frame(minHeight: 300, idealHeight: 360, maxHeight: fillsDocument ? .infinity : 400)
            case .fallback(let text): Text(text).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            case .error(let text): Label(L10n.text(text), systemImage: "exclamationmark.triangle").foregroundStyle(.red).textSelection(.enabled)
            case nil: ProgressView().frame(maxWidth: .infinity)
            }
        }
        .task(id: request) {
            prepared = nil
            let captured = request
            let worker = Task.detached(priority: .userInitiated) { try captured.prepare() }
            defer { worker.cancel() }
            do { let result = try await worker.value; if !Task.isCancelled { prepared = result } }
            catch { if !Task.isCancelled { prepared = .error(error.localizedDescription) } }
        }
    }
    private var xLabel: String {
        if case .chart(let chart) = payload { return chart.xLabel ?? L10n.text(chart.chartType.lowercased() == "datetime" ? "Time" : "X") }
        return "X"
    }
    private var yLabel: String {
        if case .chart(let chart) = payload { return chart.yLabel ?? L10n.text(chart.chartType.lowercased() == "datetime" ? "Value" : "Y") }
        return "Y"
    }
}

struct MessageTableView: View {
    let model: MessageTable
    @ObservedObject var store: WorkspaceStore
    @State private var table: MessageTable
    @State private var selection: Set<Int> = []
    init(model: MessageTable, store: WorkspaceStore) { self.model = model; self.store = store; _table = State(initialValue: model) }
    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Text(L10n.format("%d rows", table.rows.count)).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { if let value = selectedText { store.system.copy(value) } } label: { Label("Copy Table", systemImage: "doc.on.clipboard") }.disabled(selection.isEmpty)
            }
            Table(table.rows, selection: $selection) {
                TableColumnForEach(table.columns) { column in
                    TableColumn(column.defaultTitleOrdinal.map { L10n.format("Column %d", $0) } ?? column.title) { (row: MessageTable.Row) in
                        if column.editable {
                            TextField(column.title, text: Binding(get: { value(row.id, column.id) }, set: { edit(row.id, column.id, $0) })).textFieldStyle(.plain)
                        } else { Text(value(row.id, column.id)).textSelection(.enabled) }
                    }.width(min: 24, ideal: column.width, max: 2000)
                }
            }
            .onCopyCommand { selectedText.map { [NSItemProvider(object: $0 as NSString)] } ?? [] }
            .overlay { if table.rows.isEmpty { ContentUnavailableView("No data to display", systemImage: "tablecells") } }
        }.onChange(of: model) { _, value in table = value; selection = selection.intersection(value.rows.map(\.id)) }
    }
    private func value(_ rowID: Int, _ column: Int) -> String {
        guard let index = table.columns.firstIndex(where: { $0.id == column }) else { return "" }
        return table.rows.first(where: { $0.id == rowID }).flatMap { $0.values.indices.contains(index) ? $0.values[index] : nil } ?? ""
    }
    private func edit(_ rowID: Int, _ column: Int, _ value: String) {
        guard let row = table.rows.firstIndex(where: { $0.id == rowID }), let index = table.columns.firstIndex(where: { $0.id == column }), table.rows[row].values.indices.contains(index) else { return }
        // JSON-backed ArrayColumn cells are a local display copy in the source.
        // Source object snapshots are read-only until an object adapter exists.
        table.rows[row].values[index] = value
    }
    private var selectedText: String? {
        let rows = table.rows.filter { selection.contains($0.id) }
        guard !rows.isEmpty else { return nil }
        func escaped(_ value: String) -> String {
            value.contains(where: { $0.isNewline || $0 == "\t" || $0 == "\"" }) ? "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : value
        }
        return ([table.columns.map { escaped($0.defaultTitleOrdinal.map { L10n.format("Column %d", $0) } ?? $0.title) }.joined(separator: "\t")] + rows.map { $0.values.map(escaped).joined(separator: "\t") }).joined(separator: "\n")
    }
}

struct MessageChartView: View {
    let series: [MessageSeries]
    let isTime: Bool
    let xLabel: String
    let yLabel: String
    @State private var hidden: Set<Int> = []
    private let colors: [Color] = [.blue, .red, .green, .orange, .purple, .brown]
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if series.allSatisfy({ $0.points.isEmpty }) { ContentUnavailableView("No data to display", systemImage: "chart.xyaxis.line") }
            else {
                Chart {
                    ForEach(series.filter { !hidden.contains($0.id) }) { dataset in
                        ForEach(dataset.points) { point in
                            if isTime, let date = point.time {
                                LineMark(x: .value(xLabel, date), y: .value(yLabel, point.y), series: .value("Series", dataset.id))
                                    .foregroundStyle(colors[dataset.id % colors.count]).lineStyle(StrokeStyle(lineWidth: 2))
                            } else {
                                LineMark(x: .value(xLabel, point.x), y: .value(yLabel, point.y), series: .value("Series", dataset.id))
                                    .foregroundStyle(colors[dataset.id % colors.count]).lineStyle(StrokeStyle(lineWidth: 2))
                            }
                        }
                    }
                }.chartXAxisLabel(xLabel).chartYAxisLabel(yLabel).chartLegend(.hidden)
                ScrollView(.horizontal) {
                    HStack(spacing: 14) {
                        ForEach(series) { dataset in
                            Toggle(isOn: Binding(get: { !hidden.contains(dataset.id) }, set: { if $0 { hidden.remove(dataset.id) } else { hidden.insert(dataset.id) } })) {
                                HStack { Circle().fill(colors[dataset.id % colors.count]).frame(width: 8, height: 8); Text(dataset.defaultName ? L10n.text(dataset.name) : dataset.name) }
                            }.toggleStyle(.checkbox)
                        }
                    }
                }.scrollIndicators(.hidden).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct ChatDisplayDocument: Identifiable {
    let id: UUID
    let entryID: String
    let payload: ChatDisplayPayload
    let objects: [String: ChatDisplayObject]
}
