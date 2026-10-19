import Charts
import SwiftUI

struct ProfilePresentation: Sendable {
    var chart: CalculationChart? = nil
    var objectName: String? = nil
}

// CrossSectionEditorControl contains a station/elevation plot with a second
// bank series. Keep its legend and axes visible even when the source has no
// points; only source chart samples are drawn.
struct CrossSectionContent: View {
    @ObservedObject var state: DataToolSession
    var showsObjectName = true
    private var chart: CalculationChart? { state.presentation.profile?.chart }
    private var samples: [ChartSample] {
        chart?.samples.filter {
            $0.x.isFinite && $0.y.isFinite && ["Cross Section", "Bank"].contains($0.series)
        } ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsObjectName, let name = state.presentation.profile?.objectName {
                Text(name).font(.headline).textSelection(.enabled).padding(16)
            }
            HStack(spacing: 18) {
                CrossSectionLegendItem(title: "Cross Section", color: Color(red: 0, green: 1, blue: 0))
                CrossSectionLegendItem(title: "Bank", color: Color(red: 1, green: 0, blue: 0))
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)

            Chart(samples) { sample in
                LineMark(
                    x: .value(L10n.text(chart?.xLabel ?? "Stations"), sample.x),
                    y: .value(L10n.text(chart?.yLabel ?? "Elevations"), sample.y),
                    series: .value("Series", L10n.text(sample.series)))
                    .foregroundStyle(by: .value("Series", L10n.text(sample.series)))
                    .lineStyle(StrokeStyle(lineWidth: 2))
            }
            .chartXAxis(.visible)
            .chartYAxis(.visible)
            .chartForegroundStyleScale(
                domain: [L10n.text("Cross Section"), L10n.text("Bank")],
                range: [Color(red: 0, green: 1, blue: 0), Color(red: 1, green: 0, blue: 0)])
            .chartXAxisLabel(L10n.text(chart?.xLabel ?? "Stations"))
            .chartYAxisLabel(L10n.text(chart?.yLabel ?? "Elevations"))
            .chartLegend(.hidden)
            .overlay {
                if samples.isEmpty {
                    Label("No profile samples are available from the source calculation.", systemImage: "chart.xyaxis.line")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding()
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                }
            }
            .frame(minHeight: 260)
            .padding(20)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct CrossSectionLegendItem: View {
    let title: String
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            Capsule().fill(color).frame(width: 18, height: 3)
            Text(L10n.text(title)).font(.caption)
        }
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }
}

struct ArcPointsContent: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var state: DataToolSession
    @ObservedObject var editor: ModelEditorSession
    let tableID = "ArcPointsEditorDialog/PointsDataGrid"
    private var rows: [EditorRow] { editor.rows[tableID] ?? [] }
    private var columns: [SourceTableColumn] {
        [
            .init(id: "Type", title: "Type", sourceType: "string", readOnly: true, width: 80),
            .init(id: "X", title: "X", sourceType: "double", width: 256),
            .init(id: "Y", title: "Y", sourceType: "double", width: 256)]
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let name = state.presentation.profile?.objectName { Text(name).font(.headline).textSelection(.enabled).padding(16) }
            Table(rows) {
                TableColumnForEach(columns) { column in
                    TableColumn(L10n.text(column.title)) { (row: EditorRow) in
                        TableCell(column: column, rowID: row.id, tableID: tableID, session: editor, store: store)
                    }.width(min: 60, ideal: column.width ?? 140)
                }
            }
            .overlay {
                if rows.isEmpty {
                    Text("No arc points are available from the selected topology object.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}
