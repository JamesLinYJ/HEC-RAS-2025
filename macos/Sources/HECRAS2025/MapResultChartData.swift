import Foundation

struct MapResultChartPresentationData: Sendable {
    let samples: [ChartSample]
    let presentation: SeriesEditorPresentation
}

enum MapResultChartData {
    private struct QuantityUnit: Hashable {
        let quantity: String
        let units: String
    }

    private static let palette = ["FF3478C8", "FF27A36A", "FFE28B22", "FF9A63C7", "FFE1558D", "FF4F9FA3"]

    @MainActor
    static func samples(for result: MapResultChartSeries) -> [ChartSample] {
        result.series.enumerated().flatMap { index, entry -> [ChartSample] in
            guard entry.series.available else { return [] }
            let datasetID = "map-result-line/\(index)"
            let sourceLabel = [entry.series.resultName] + entry.selections.map { selection in
                "\(selection.node.nodeName) (\(L10n.format("Selection %d", selection.selectionIndex + 1)))"
            }
            let displayName = sourceLabel.joined(separator: " — ")
            return entry.series.points.compactMap { point in
                guard let date = ResultProfileChartData.sourceDate(point.time) else { return nil }
                return ChartSample(id: "\(datasetID)/\(point.profileIndex)",
                    x: date.timeIntervalSince1970, y: point.value ?? .nan,
                    series: displayName, datasetID: datasetID)
            }
        }
    }

    @MainActor
    static func presentation(for result: MapResultChartSeries, mode: MapResultChartMode) -> SeriesEditorPresentation {
        let availableEntries: [MapResultChartSeriesEntry] = result.series.filter { entry in
            entry.series.available
        }
        var uniqueQuantities: Set<QuantityUnit> = []
        for entry in availableEntries {
            let quantityUnit = QuantityUnit(quantity: entry.series.quantity, units: entry.series.units)
            uniqueQuantities.insert(quantityUnit)
        }
        let quantities: [QuantityUnit] = uniqueQuantities.sorted(by: quantityUnitPrecedes)
        var axes: [PlotAxisPresentation] = [
            .init(id: "time", direction: .x, title: L10n.text("Time"), isDate: true)
        ]
        var datasets: [PlotDatasetPresentation] = []
        for (axisIndex, quantity) in quantities.enumerated() {
            let axisID = "value-\(axisIndex)"
            axes.append(.init(id: axisID, direction: .y,
                title: L10n.text(quantity.quantity), units: quantity.units))
            for (seriesIndex, entry) in result.series.enumerated()
            where entry.series.available && entry.series.quantity == quantity.quantity
                && entry.series.units == quantity.units {
                datasets.append(PlotDatasetPresentation(id: "map-result-line/\(seriesIndex)",
                    name: displayName(for: entry), xAxisID: "time", yAxisID: axisID,
                    colorRGBA: palette[seriesIndex % palette.count]))
            }
        }
        let first = quantities.first
        let yTitle = first.map { L10n.text($0.quantity) } ?? L10n.text("Flow")
        let yAxisTitle = first.map { $0.units.isEmpty ? yTitle : yTitle + " (" + $0.units + ")" } ?? yTitle
        let chart = SeriesChartPresentation(title: L10n.text(mode.titleKey), axes: axes,
            datasets: datasets)
        return SeriesEditorPresentation(xTitle: L10n.text("Time"), yTitle: yAxisTitle,
            xIsDate: true, chart: chart)
    }

    static func unavailableEntries(in result: MapResultChartSeries) -> [MapResultChartSeriesEntry] {
        result.series.filter { !$0.series.available }
    }

    @MainActor
    private static func displayName(for entry: MapResultChartSeriesEntry) -> String {
        let sources = entry.selections.map { selection in
            "\(selection.node.nodeName) (\(L10n.format("Selection %d", selection.selectionIndex + 1)))"
        }
        return ([entry.series.resultName] + sources).joined(separator: " — ")
    }

    private static func quantityUnitPrecedes(_ lhs: QuantityUnit, _ rhs: QuantityUnit) -> Bool {
        if lhs.quantity == rhs.quantity {
            return lhs.units < rhs.units
        }
        return lhs.quantity < rhs.quantity
    }
}
