import Foundation
import RASWorkspaceCore

struct PlotAxisPresentation: Identifiable, Sendable {
    enum Direction: String, Hashable, Sendable { case x, y }
    let id: String
    let direction: Direction
    let title: String
    var units = ""
    var isDate = false
    var logarithmic = false
    var titleIsUserData = false
    @MainActor var displayTitle: String {
        let name = titleIsUserData ? title : L10n.text(title)
        return units.isEmpty ? name : name + " (" + units + ")"
    }
}
struct PlotDatasetPresentation: Identifiable, Sendable {
    let id: String
    let name: String
    let xAxisID: String
    let yAxisID: String
    var colorRGBA: String? = nil
    var noDataValue: Double? = nil
    var noDataSubstitute: Double? = nil
    @MainActor var displayName: String {
        let suffix = id.components(separatedBy: "/station/").last ?? ""
        if id.contains("/station/"), let station = Int(suffix), name == "Station " + suffix { return L10n.format("Station %d", station) }
        return name
    }
    func forDisplay(_ sample: ChartSample) -> ChartSample {
        var result = sample
        if let noDataValue, sample.y == noDataValue || noDataValue.isNaN && sample.y.isNaN { result.y = noDataSubstitute ?? .nan }
        return result
    }
}
struct SeriesChartPresentation: Sendable {
    var title = ""
    var axes: [PlotAxisPresentation] = []
    var datasets: [PlotDatasetPresentation] = []
    var showLegend = true
    var showXAxis = true
    var showYAxis = true
    var showTitles = true
    var mapTypeFieldID: String? = nil
    var canRefresh = false
    var mapID: UUID? = nil
    var zoomExtent: ViewportRequest? = nil
    func validate(samples: [ChartSample]) throws {
        guard Set(axes.map(\.id)).count == axes.count, Set(datasets.map(\.id)).count == datasets.count,
              axes.allSatisfy({ !$0.id.isEmpty && !($0.isDate && ($0.logarithmic || $0.direction != .x)) }),
              datasets.allSatisfy({ dataset in
                  !dataset.id.isEmpty && (dataset.colorRGBA.map { color in
                      let value = color.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
                      return value.count == 8 && UInt32(value, radix: 16) != nil
                  } ?? true) && axes.contains { $0.id == dataset.xAxisID && $0.direction == .x }
                    && axes.contains { $0.id == dataset.yAxisID && $0.direction == .y }
              }), samples.allSatisfy({ sample in datasets.contains { $0.id == sample.datasetKey } }) else {
            throw ProjectFileError.invalid("The source chart contains invalid dataset or axis identities.")
        }
        for dataset in datasets where axes.first(where: { $0.id == dataset.xAxisID })?.isDate == true {
            guard samples.filter({ $0.datasetKey == dataset.id && $0.x.isFinite }).allSatisfy({ (-62_135_596_800.0...253_402_300_799.0).contains($0.x) }) else {
                throw ProjectFileError.invalid("The source chart contains a date outside the supported source calendar.")
            }
        }
    }
    static func resolved(_ presentation: SeriesEditorPresentation, samples: [ChartSample]) -> Self {
        if let chart = presentation.chart { return chart }
        let names = Dictionary(samples.map { ($0.datasetKey, $0.series) }, uniquingKeysWith: { first, _ in first })
        return Self(axes: [.init(id: "x", direction: .x, title: presentation.xTitle, isDate: presentation.xIsDate),
                          .init(id: "y", direction: .y, title: presentation.yTitle)],
            datasets: names.keys.sorted().map { .init(id: $0, name: names[$0] ?? $0, xAxisID: "x", yAxisID: "y") })
    }
}
struct SeriesChartGroup: Identifiable {
    struct ID: Hashable { let x: String; let y: String }
    let xAxis: PlotAxisPresentation
    let yAxis: PlotAxisPresentation
    let datasets: [PlotDatasetPresentation]
    var id: ID { .init(x: xAxis.id, y: yAxis.id) }
    static func groups(_ presentation: SeriesChartPresentation) -> [Self] {
        var result: [Self] = []
        for x in presentation.axes where x.direction == .x {
            for y in presentation.axes where y.direction == .y {
                let datasets = presentation.datasets.filter { $0.xAxisID == x.id && $0.yAxisID == y.id }
                if !datasets.isEmpty { result.append(.init(xAxis: x, yAxis: y, datasets: datasets)) }
            }
        }
        return result
    }
}

struct ChartAxisTickLayout: Equatable, Sendable {
    let zoomLevel: Int
    let interval: Double
    let values: [Double]
}

enum ChartAxisTickMath {
    /// Mirrors the retained chart's view-relative zoom level and 1-2-5 / time
    /// tick interval selection. `domain` is the unpadded source extent;
    /// `visibleRange` may include the source chart's 15% navigation margin.
    static func layout(
        domain: ClosedRange<Double>,
        visibleRange: ClosedRange<Double>,
        pixelLength: Double,
        pixelsPerTick: Double,
        isDate: Bool = false,
        logarithmic: Bool = false
    ) -> ChartAxisTickLayout? {
        guard domain.lowerBound.isFinite, domain.upperBound.isFinite,
              visibleRange.lowerBound.isFinite, visibleRange.upperBound.isFinite,
              domain.lowerBound < domain.upperBound, visibleRange.lowerBound < visibleRange.upperBound,
              pixelLength.isFinite, pixelLength > 0,
              pixelsPerTick.isFinite, pixelsPerTick > 0,
              !isDate || !logarithmic,
              !logarithmic || (domain.lowerBound > 0 && visibleRange.lowerBound > 0) else { return nil }

        let domainMinimum = logarithmic ? log10(domain.lowerBound) : domain.lowerBound
        let domainMaximum = logarithmic ? log10(domain.upperBound) : domain.upperBound
        let visibleMinimum = logarithmic ? log10(visibleRange.lowerBound) : visibleRange.lowerBound
        let visibleMaximum = logarithmic ? log10(visibleRange.upperBound) : visibleRange.upperBound
        let domainSpan = domainMaximum - domainMinimum
        let visibleSpan = visibleMaximum - visibleMinimum
        guard domainSpan.isFinite, domainSpan > 0, visibleSpan.isFinite, visibleSpan > 0 else { return nil }

        let sourceExtentWidth = visibleSpan / domainSpan
        guard sourceExtentWidth.isFinite, sourceExtentWidth > 0 else { return nil }
        let rawZoomLevel = -log2(sourceExtentWidth).rounded(.towardZero)
        let zoomLevel = Int(min(max(rawZoomLevel, -30), 30))
        let zoomScale = pow(2, Double(zoomLevel))
        let targetInterval = domainSpan * pixelsPerTick / (pixelLength * zoomScale)
        let interval = isDate ? timeInterval(targetInterval) : nearest125(targetInterval)
        guard interval.isFinite, interval > 0 else { return nil }

        let firstIndex = floor(visibleMinimum / interval)
        let lastIndex = ceil(visibleMaximum / interval)
        let count = lastIndex - firstIndex + 1
        guard firstIndex.isFinite, lastIndex.isFinite, count.isFinite, count > 0, count <= 2_000 else { return nil }

        var values: [Double] = []
        values.reserveCapacity(Int(count))
        for offset in 0..<Int(count) {
            let coordinate = (firstIndex + Double(offset)) * interval
            let value = logarithmic ? pow(10, coordinate) : coordinate
            guard value.isFinite else { continue }
            values.append(value)
        }
        guard !values.isEmpty else { return nil }
        return ChartAxisTickLayout(zoomLevel: zoomLevel, interval: interval, values: values)
    }

    static func zoomLevel(
        domain: ClosedRange<Double>,
        visibleRange: ClosedRange<Double>,
        logarithmic: Bool = false
    ) -> Int {
        guard domain.lowerBound.isFinite, domain.upperBound.isFinite,
              visibleRange.lowerBound.isFinite, visibleRange.upperBound.isFinite,
              domain.lowerBound < domain.upperBound, visibleRange.lowerBound < visibleRange.upperBound,
              !logarithmic || (domain.lowerBound > 0 && visibleRange.lowerBound > 0) else { return 0 }
        let lower = logarithmic ? log10(domain.lowerBound) : domain.lowerBound
        let upper = logarithmic ? log10(domain.upperBound) : domain.upperBound
        let visibleLower = logarithmic ? log10(visibleRange.lowerBound) : visibleRange.lowerBound
        let visibleUpper = logarithmic ? log10(visibleRange.upperBound) : visibleRange.upperBound
        let extentWidth = (visibleUpper - visibleLower) / (upper - lower)
        guard extentWidth.isFinite, extentWidth > 0 else { return 0 }
        return Int(min(max(-log2(extentWidth).rounded(.towardZero), -30), 30))
    }

    private static func nearest125(_ target: Double) -> Double {
        guard target.isFinite, target > 0 else { return 1 }
        let power = pow(10, floor(log10(target)))
        let mantissa = target / power
        let nice = mantissa < 1.5 ? 1.0 : mantissa < 3.5 ? 2.0 : mantissa < 7.5 ? 5.0 : 10.0
        return nice * power
    }

    private static func timeInterval(_ target: Double) -> Double {
        guard target.isFinite, target > 0 else { return 1 }
        let power = pow(60, floor(log(target) / log(60)))
        let mantissa = target / power
        let nice: Double
        if mantissa < 1.5 { nice = 1 }
        else if mantissa < 3.5 { nice = 2 }
        else if mantissa < 7.5 { nice = 5 }
        else if mantissa < 12.5 { nice = 10 }
        else if mantissa < 17.5 { nice = 15 }
        else if mantissa < 25 { nice = 20 }
        else if mantissa < 45 { nice = 30 }
        else { nice = 60 }
        return nice * power
    }
}

struct PlotAxisViewport: Equatable, Sendable {
    let position: Double
    let fraction: Double
}

/// A view-state key that changes when source axes, datasets, or sample values
/// change. SwiftUI uses it to discard old zoom and cursor state after a draft
/// or data-source switch.
struct SeriesChartDataIdentity: Hashable, Sendable {
    private struct AxisIdentity: Hashable, Sendable {
        let id: String
        let direction: PlotAxisPresentation.Direction
        let title: String
        let units: String
        let isDate: Bool
        let logarithmic: Bool
        let titleIsUserData: Bool

        init(_ axis: PlotAxisPresentation) {
            id = axis.id
            direction = axis.direction
            title = axis.title
            units = axis.units
            isDate = axis.isDate
            logarithmic = axis.logarithmic
            titleIsUserData = axis.titleIsUserData
        }
    }

    private struct DatasetIdentity: Hashable, Sendable {
        let id: String
        let name: String
        let xAxisID: String
        let yAxisID: String
        let colorRGBA: String?
        let noDataValue: UInt64?
        let noDataSubstitute: UInt64?

        init(_ dataset: PlotDatasetPresentation) {
            id = dataset.id
            name = dataset.name
            xAxisID = dataset.xAxisID
            yAxisID = dataset.yAxisID
            colorRGBA = dataset.colorRGBA
            noDataValue = dataset.noDataValue?.bitPattern
            noDataSubstitute = dataset.noDataSubstitute?.bitPattern
        }
    }

    private struct SampleIdentity: Hashable, Sendable {
        let id: String
        let datasetKey: String
        let x: UInt64
        let y: UInt64

        init(_ sample: ChartSample) {
            id = sample.id
            datasetKey = sample.datasetKey
            x = sample.x.bitPattern
            y = sample.y.bitPattern
        }
    }

    private let xAxis: AxisIdentity
    private let yAxis: AxisIdentity
    private let datasets: [DatasetIdentity]
    private let samples: [SampleIdentity]
    private let sourceTitle: String
    private let sourceDisplay: [Bool]
    private let sourceIdentity: String?
    private let mapID: UUID?
    private let mapTypeFieldID: String?

    init(group: SeriesChartGroup, samples: [ChartSample], source: SeriesChartPresentation? = nil,
         sourceIdentity: String? = nil) {
        xAxis = AxisIdentity(group.xAxis)
        yAxis = AxisIdentity(group.yAxis)
        datasets = group.datasets.map(DatasetIdentity.init)
        self.samples = samples.map(SampleIdentity.init)
        sourceTitle = source?.title ?? ""
        sourceDisplay = source.map { [$0.showLegend, $0.showXAxis, $0.showYAxis, $0.showTitles] } ?? []
        self.sourceIdentity = sourceIdentity
        mapID = source?.mapID
        mapTypeFieldID = source?.mapTypeFieldID
    }
}

enum PlotDisplayMath {
    static func maximumPosition(_ range: ClosedRange<Double>, fraction: Double, logarithmic: Bool) -> Double {
        logarithmic ? pow(10, log10(range.upperBound) - (log10(range.upperBound) - log10(range.lowerBound)) * fraction)
            : range.upperBound - (range.upperBound - range.lowerBound) * fraction
    }
    static func visibleLength(_ range: ClosedRange<Double>, position: Double, fraction: Double, logarithmic: Bool) -> Double {
        guard logarithmic else { return (range.upperBound - range.lowerBound) * fraction }
        let start = min(max(position, range.lowerBound), maximumPosition(range, fraction: fraction, logarithmic: true))
        return pow(10, min(log10(range.upperBound), log10(start) + (log10(range.upperBound) - log10(range.lowerBound)) * fraction)) - start
    }
    static func visibleRange(_ range: ClosedRange<Double>, position: Double, fraction: Double,
                             logarithmic: Bool) -> ClosedRange<Double>? {
        guard range.lowerBound.isFinite, range.upperBound.isFinite,
              position.isFinite, fraction.isFinite, fraction > 0, fraction <= 1,
              !logarithmic || range.lowerBound > 0 else { return nil }
        let minimumPosition = range.lowerBound
        let maximumPosition = self.maximumPosition(range, fraction: fraction, logarithmic: logarithmic)
        let start = min(max(position, minimumPosition), maximumPosition)
        let length = visibleLength(range, position: start, fraction: fraction, logarithmic: logarithmic)
        let end = start + length
        guard start.isFinite, end.isFinite, start < end else { return nil }
        return start...end
    }
    static func zoomedViewport(_ range: ClosedRange<Double>, position: Double, fraction: Double,
                               anchor: Double, factor: Double, logarithmic: Bool) -> PlotAxisViewport? {
        guard range.lowerBound.isFinite, range.upperBound.isFinite, range.lowerBound < range.upperBound,
              position.isFinite, fraction.isFinite, fraction > 0, fraction <= 1,
              anchor.isFinite, factor.isFinite, factor > 0,
              !logarithmic || range.lowerBound > 0 else { return nil }

        func transform(_ value: Double) -> Double { logarithmic ? log10(value) : value }
        func inverse(_ value: Double) -> Double { logarithmic ? pow(10, value) : value }
        let sourceLower = transform(range.lowerBound)
        let sourceUpper = transform(range.upperBound)
        let sourceWidth = sourceUpper - sourceLower
        guard sourceWidth.isFinite, sourceWidth > 0 else { return nil }
        let currentWidth = sourceWidth * fraction
        let currentLower = min(max(transform(position), sourceLower), sourceUpper - currentWidth)
        let currentUpper = currentLower + currentWidth
        let anchorPosition = min(max(transform(anchor), currentLower), currentUpper)
        let relativeAnchor = (anchorPosition - currentLower) / currentWidth
        let newFraction = min(max(fraction * factor, 0.00001), 1)
        let newWidth = sourceWidth * newFraction
        let newLower = min(max(anchorPosition - relativeAnchor * newWidth, sourceLower), sourceUpper - newWidth)
        let positionValue = inverse(newLower)
        guard positionValue.isFinite, newFraction.isFinite, newWidth.isFinite, newWidth > 0 else { return nil }
        return PlotAxisViewport(position: positionValue, fraction: newFraction)
    }
    static func pannedViewport(_ range: ClosedRange<Double>, position: Double, fraction: Double,
                              translationFraction: Double, logarithmic: Bool) -> PlotAxisViewport? {
        guard range.lowerBound.isFinite, range.upperBound.isFinite, range.lowerBound < range.upperBound,
              position.isFinite, fraction.isFinite, fraction > 0, fraction <= 1,
              translationFraction.isFinite, !logarithmic || (range.lowerBound > 0 && position > 0) else { return nil }
        let sourceLower = logarithmic ? log10(range.lowerBound) : range.lowerBound
        let sourceUpper = logarithmic ? log10(range.upperBound) : range.upperBound
        let sourceWidth = sourceUpper - sourceLower
        let visibleWidth = sourceWidth * fraction
        guard sourceWidth.isFinite, sourceWidth > 0, visibleWidth.isFinite, visibleWidth > 0 else { return nil }
        let initial = logarithmic ? log10(position) : position
        let clampedInitial = min(max(initial, sourceLower), sourceUpper - visibleWidth)
        let translated = clampedInitial + translationFraction * visibleWidth
        let newLower = min(max(translated, sourceLower), sourceUpper - visibleWidth)
        let result = logarithmic ? pow(10, newLower) : newLower
        guard result.isFinite else { return nil }
        return PlotAxisViewport(position: result, fraction: fraction)
    }
    static func viewport(for visibleRange: ClosedRange<Double>, within sourceRange: ClosedRange<Double>,
                         logarithmic: Bool) -> PlotAxisViewport? {
        let lower = visibleRange.lowerBound
        let upper = visibleRange.upperBound
        let sourceLower = sourceRange.lowerBound
        let sourceUpper = sourceRange.upperBound
        guard lower.isFinite, upper.isFinite, sourceLower.isFinite, sourceUpper.isFinite,
              lower < upper, sourceLower < sourceUpper,
              lower >= sourceLower, upper <= sourceUpper,
              !logarithmic || (lower > 0 && sourceLower > 0) else { return nil }
        let fraction: Double
        if logarithmic {
            let fullLogWidth = log10(sourceUpper) - log10(sourceLower)
            fraction = (log10(upper) - log10(lower)) / fullLogWidth
        } else {
            fraction = (upper - lower) / (sourceUpper - sourceLower)
        }
        guard fraction.isFinite, fraction > 0, fraction <= 1 else { return nil }
        return PlotAxisViewport(position: lower, fraction: fraction)
    }
    static func scrollProgress(_ range: ClosedRange<Double>, position: Double, fraction: Double,
                               logarithmic: Bool) -> Double {
        guard fraction.isFinite, fraction > 0, fraction < 1,
              range.lowerBound.isFinite, range.upperBound.isFinite,
              !logarithmic || range.lowerBound > 0 else { return 0 }
        let minimum = range.lowerBound
        let maximum = maximumPosition(range, fraction: fraction, logarithmic: logarithmic)
        guard maximum > minimum else { return 0 }
        let clamped = min(max(position, minimum), maximum)
        let progress: Double
        if logarithmic {
            progress = (log10(clamped) - log10(minimum)) / (log10(maximum) - log10(minimum))
        } else {
            progress = (clamped - minimum) / (maximum - minimum)
        }
        return progress.isFinite ? min(max(progress, 0), 1) : 0
    }
    static func position(atScrollProgress progress: Double, in range: ClosedRange<Double>,
                         fraction: Double, logarithmic: Bool) -> Double {
        guard progress.isFinite, range.lowerBound.isFinite, range.upperBound.isFinite,
              fraction.isFinite, fraction > 0, fraction < 1,
              !logarithmic || range.lowerBound > 0 else { return range.lowerBound }
        let minimum = range.lowerBound
        let maximum = maximumPosition(range, fraction: fraction, logarithmic: logarithmic)
        let clampedProgress = min(max(progress, 0), 1)
        if logarithmic {
            return pow(10, log10(minimum) + (log10(maximum) - log10(minimum)) * clampedProgress)
        }
        return minimum + (maximum - minimum) * clampedProgress
    }
    static func scrollPageStepProgress(fraction: Double) -> Double {
        guard fraction.isFinite, fraction > 0, fraction < 1 else { return 1 }
        let page = fraction / (1 - fraction)
        return page.isFinite ? min(max(page, 0), 1) : 1
    }
    static func value(in range: ClosedRange<Double>, at fraction: Double, logarithmic: Bool) -> Double? {
        guard fraction.isFinite, range.lowerBound.isFinite, range.upperBound.isFinite,
              range.lowerBound < range.upperBound, !logarithmic || range.lowerBound > 0 else { return nil }
        let clamped = min(max(fraction, 0), 1)
        let lower = logarithmic ? log10(range.lowerBound) : range.lowerBound
        let upper = logarithmic ? log10(range.upperBound) : range.upperBound
        let value = lower + (upper - lower) * clamped
        let result = logarithmic ? pow(10, value) : value
        return result.isFinite ? result : nil
    }
    static func range(_ values: [Double], logarithmic: Bool = false,
                      addNavigationMargin: Bool = false) -> ClosedRange<Double>? {
        let valid = values.filter { $0.isFinite && (!logarithmic || $0 > 0) }
        guard let min = valid.min(), let max = valid.max() else { return nil }
        let baseRange: ClosedRange<Double>
        if min < max {
            guard (max - min).isFinite else { return nil }
            baseRange = min...max
        } else {
            let pad = min == 0 ? 1 : abs(min) * 0.05
            let low = logarithmic ? min / 1.1 : min - pad
            let high = logarithmic ? min * 1.1 : min + pad
            if low.isFinite, high.isFinite, low < high {
                baseRange = low...high
            } else if low.isFinite, low < min {
                baseRange = low...min
            } else if high.isFinite, min < high {
                baseRange = min...high
            } else {
                return nil
            }
        }

        guard addNavigationMargin else { return baseRange }

        let baseLower = logarithmic ? log10(baseRange.lowerBound) : baseRange.lowerBound
        let baseUpper = logarithmic ? log10(baseRange.upperBound) : baseRange.upperBound
        let margin = (baseUpper - baseLower) * 0.15
        guard margin.isFinite, margin > 0 else { return baseRange }
        let lowerValue = logarithmic ? pow(10, baseLower - margin) : baseRange.lowerBound - margin
        let upperValue = logarithmic ? pow(10, baseUpper + margin) : baseRange.upperBound + margin
        guard lowerValue.isFinite, upperValue.isFinite, lowerValue < upperValue else { return baseRange }
        return lowerValue...upperValue
    }
    // Display interpolation follows ChartDataset.GetValuesY: preserve multiple
    // intersections and missing-data gaps. Log coordinates transform the query
    // as well as segment endpoints; no model or stored sample is modified.
    static func scrub(_ samples: [ChartSample], x: Double, logX: Bool, logY: Bool) -> [Double] {
        guard x.isFinite, !logX || x > 0 else { return [] }
        func valid(_ s: ChartSample) -> Bool { s.x.isFinite && s.y.isFinite && (!logX || s.x > 0) && (!logY || s.y > 0) }
        var values = samples.filter { $0.x == x && valid($0) }.map(\.y)
        for (a, b) in zip(samples, samples.dropFirst()) where valid(a) && valid(b) && x > min(a.x, b.x) && x < max(a.x, b.x) {
            let ax = logX ? log10(a.x) : a.x, bx = logX ? log10(b.x) : b.x, q = logX ? log10(x) : x
            let ay = logY ? log10(a.y) : a.y, by = logY ? log10(b.y) : b.y
            let ratio = (q - ax) / (bx - ax)
            let result = ay * (1 - ratio) + by * ratio
            let value = logY ? pow(10, result) : result
            if value.isFinite { values.append(value) }
        }
        return values
    }
}
