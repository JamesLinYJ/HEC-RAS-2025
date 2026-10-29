import Foundation

@MainActor
enum MapResultCulvertTimeSeriesChartData {
    static func make(from snapshot: MapResultCulvertTimeSeriesSnapshot,
                     variable: String) -> (samples: [ChartSample], presentation: SeriesEditorPresentation)? {
        guard variable == "Flow" || variable == "Velocity",
              snapshot.variable == variable,
              snapshot.times.count > 0,
              snapshot.noDataValue.isFinite,
              !snapshot.datasets.isEmpty else { return nil }

        var samples: [ChartSample] = []
        var datasets: [PlotDatasetPresentation] = []
        var datasetIDs = Set<String>()
        for dataset in snapshot.datasets {
            guard datasetIDs.insert(dataset.id).inserted,
                  dataset.id == "barrel:source:\(dataset.sourceOrdinal)",
                  dataset.sourceOrdinal >= 0,
                  dataset.colorRGBA.count == 8,
                  UInt32(dataset.colorRGBA, radix: 16) != nil,
                  dataset.strokeWidth.isFinite, dataset.strokeWidth > 0,
                  dataset.values.count == snapshot.times.count,
                  dataset.values.allSatisfy(\.isFinite) else { return nil }
            let displayName = dataset.name.isEmpty
                ? L10n.format("Culvert Barrel %d", dataset.sourceOrdinal + 1)
                : dataset.name
            datasets.append(.init(id: dataset.id, name: displayName,
                xAxisID: "time", yAxisID: "value", colorRGBA: dataset.colorRGBA,
                noDataValue: snapshot.noDataValue))
            for (index, value) in dataset.values.enumerated() {
                guard let date = sourceDate(snapshot.times[index]) else { return nil }
                samples.append(ChartSample(id: "\(dataset.id)/\(index)",
                    x: date.timeIntervalSince1970, y: value,
                    series: displayName, datasetID: dataset.id))
            }
        }

        let title = L10n.text(variable == "Flow"
            ? "Culvert Flow Time Series" : "Culvert Velocity Time Series")
        let axisTitle = L10n.text(variable)
        let chart = SeriesChartPresentation(title: title, axes: [
            .init(id: "time", direction: .x, title: L10n.text("Time"), isDate: true),
            .init(id: "value", direction: .y, title: axisTitle, units: snapshot.units)
        ], datasets: datasets)
        return (samples, SeriesEditorPresentation(xTitle: L10n.text("Time"),
            yTitle: axisTitle, xIsDate: true, chart: chart))
    }

    /// OutputBlock.ToString("O") includes seven fractional digits and may
    /// carry a UTC/local offset. Unspecified source times retain local wall
    /// time, as the existing chart route does.
    static func sourceDate(_ value: String) -> Date? {
        let zoned = DateFormatter()
        zoned.locale = Locale(identifier: "en_US_POSIX")
        zoned.calendar = Calendar(identifier: .gregorian)
        zoned.isLenient = false
        zoned.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSSSXXXXX"
        if let date = zoned.date(from: value) { return date }

        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US_POSIX")
        local.calendar = Calendar(identifier: .gregorian)
        local.timeZone = .current
        local.isLenient = false
        local.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSSS"
        return local.date(from: value)
    }

    static func isValidSourceDate(_ value: String) -> Bool {
        sourceDate(value) != nil
    }
}
