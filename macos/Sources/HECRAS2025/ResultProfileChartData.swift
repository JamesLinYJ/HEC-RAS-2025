import Foundation

enum ResultProfileChartData {
    static let datasetID = "result-profile"

    static func samples(for series: ResultProfileSeries) -> [ChartSample] {
        guard series.available else { return [] }
        return series.points.compactMap { point in
            guard let date = sourceDate(point.time) else { return nil }
            return ChartSample(id: "profile/\(point.profileIndex)", x: date.timeIntervalSince1970,
                y: point.value ?? .nan, series: series.resultName, datasetID: datasetID)
        }
    }

    static func sourceDate(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.isLenient = false
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSSS"
        return formatter.date(from: value)
    }
}
