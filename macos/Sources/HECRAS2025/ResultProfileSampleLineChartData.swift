import Foundation
import RASWorkspaceCore

enum ResultProfileSampleLineChartData {
    private static let palette = ["FF3478C8", "FF27A36A", "FFE28B22", "FF9A63C7", "FFE1558D", "FF4F9FA3"]

    static func samples(for series: [ResultProfileSampleLineSeries]) -> [ChartSample] {
        series.enumerated().flatMap { pair -> [ChartSample] in
            let (index, result) = pair
            guard result.available else { return [] }
            let datasetID = "result-sample-line/\(index)"
            return result.points.compactMap { point in
                guard let date = ResultProfileChartData.sourceDate(point.time) else { return nil }
                return ChartSample(id: "\(datasetID)/\(point.profileIndex)",
                    x: date.timeIntervalSince1970, y: point.value ?? .nan,
                    series: result.resultName, datasetID: datasetID)
            }
        }
    }

    @MainActor
    static func presentation(for series: [ResultProfileSampleLineSeries]) -> SeriesEditorPresentation {
        let yTitle = series.first.map { L10n.text($0.quantity) } ?? L10n.text("Flow")
        let units = series.first?.units ?? ""
        let datasets = series.enumerated().compactMap { index, result -> PlotDatasetPresentation? in
            guard result.available else { return nil }
            return PlotDatasetPresentation(id: "result-sample-line/\(index)", name: result.resultName,
                xAxisID: "time", yAxisID: "value", colorRGBA: palette[index % palette.count])
        }
        let axisTitle = units.isEmpty ? yTitle : yTitle + " (" + units + ")"
        let chart = SeriesChartPresentation(title: L10n.text("Sample Line Time Series"), axes: [
            .init(id: "time", direction: .x, title: L10n.text("Time"), isDate: true),
            .init(id: "value", direction: .y, title: yTitle, units: units)
        ], datasets: datasets)
        return SeriesEditorPresentation(xTitle: L10n.text("Time"), yTitle: axisTitle,
            xIsDate: true, chart: chart)
    }
}
