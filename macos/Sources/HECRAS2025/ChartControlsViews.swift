import AppKit
import SwiftUI

struct ChartDisplayOptions: Equatable {
    var showLegend: Bool
    var showXAxis: Bool
    var showYAxis: Bool
    var showXAxisTitle: Bool
    var showYAxisTitle: Bool
    var showDataTable = false
    var showScrollBars = true
    var showDates = true
    var showTimes = true
    var dateFormat = "yyyy-MM-dd"
    var timeFormat = "HH:mm:ss"
    var xPixelsPerTick = 175.0
    var yPixelsPerTick = 100.0
    var xAxisFontSize = 12.0
    var yAxisFontSize = 12.0
    var xLogarithmic: Bool
    var yLogarithmic: Bool

    init(source: SeriesChartPresentation, group: SeriesChartGroup, samples: [ChartSample]) {
        showLegend = source.showLegend
        showXAxis = source.showXAxis
        showYAxis = source.showYAxis
        showXAxisTitle = source.showTitles
        showYAxisTitle = source.showTitles
        let validSamples = samples.compactMap { sample -> (Double, Double)? in
            guard let dataset = group.datasets.first(where: { $0.id == sample.datasetKey }) else { return nil }
            let displayed = dataset.forDisplay(sample)
            guard displayed.x.isFinite, displayed.y.isFinite else { return nil }
            return (displayed.x, displayed.y)
        }
        let xValues = validSamples.map { $0.0 }
        let yValues = validSamples.map { $0.1 }
        xLogarithmic = group.xAxis.logarithmic && !xValues.isEmpty && xValues.allSatisfy { $0 > 0 }
        yLogarithmic = group.yAxis.logarithmic && !yValues.isEmpty && yValues.allSatisfy { $0 > 0 }
    }
}

struct ChartDisplayOptionsView: View {
    @Binding var options: ChartDisplayOptions
    @Binding var showChartTitle: Bool
    @Binding var legendOverlay: Bool
    let xAxis: PlotAxisPresentation
    let yAxis: PlotAxisPresentation
    let xRange: ClosedRange<Double>?
    let yRange: ClosedRange<Double>?
    let xCurrentRange: ClosedRange<Double>?
    let yCurrentRange: ClosedRange<Double>?
    let xZoomLevel: Int
    let yZoomLevel: Int
    let canUseXLogarithmic: Bool
    let canUseYLogarithmic: Bool
    let applyXRange: (ClosedRange<Double>) -> Bool
    let applyYRange: (ClosedRange<Double>) -> Bool
    let resetXRange: () -> Void
    let resetYRange: () -> Void

    var body: some View {
        Form {
            Section(L10n.text("Display")) {
                Toggle(L10n.text("Legend"), isOn: $options.showLegend)
                Toggle(L10n.text("Legend Overlay"), isOn: $legendOverlay)
                    .disabled(!options.showLegend)
                Toggle(L10n.text("Chart Title"), isOn: $showChartTitle)
                Toggle(L10n.text("X Axis"), isOn: $options.showXAxis)
                Toggle(L10n.text("Y Axis"), isOn: $options.showYAxis)
                Toggle(L10n.text("Scroll Bars"), isOn: $options.showScrollBars)
                Toggle(L10n.text("Data Table"), isOn: $options.showDataTable)
            }

            Section(L10n.text("Axis Titles")) {
                Toggle(L10n.text("X Axis Title"), isOn: $options.showXAxisTitle)
                    .disabled(!options.showXAxis)
                Toggle(L10n.text("Y Axis Title"), isOn: $options.showYAxisTitle)
                    .disabled(!options.showYAxis)
            }

            Section(L10n.text("Tick Marks")) {
                LabeledContent(L10n.text("X Zoom Level"), value: String(xZoomLevel))
                Stepper(value: $options.xPixelsPerTick, in: 50...500, step: 25) {
                    LabeledContent(L10n.text("X Pixels Per Tick"), value: String(Int(options.xPixelsPerTick)))
                }
                LabeledContent(L10n.text("Y Zoom Level"), value: String(yZoomLevel))
                Stepper(value: $options.yPixelsPerTick, in: 50...500, step: 25) {
                    LabeledContent(L10n.text("Y Pixels Per Tick"), value: String(Int(options.yPixelsPerTick)))
                }
            }

            Section(L10n.text("Axis Font Size")) {
                Stepper(value: $options.xAxisFontSize, in: 8...24, step: 1) {
                    LabeledContent(L10n.text("X Axis Font Size"), value: String(Int(options.xAxisFontSize)))
                }
                Stepper(value: $options.yAxisFontSize, in: 8...24, step: 1) {
                    LabeledContent(L10n.text("Y Axis Font Size"), value: String(Int(options.yAxisFontSize)))
                }
            }

            Section(L10n.text("X Axis")) {
                Toggle(L10n.text("Logarithmic"), isOn: $options.xLogarithmic)
                    .disabled(xAxis.isDate || !canUseXLogarithmic)
                if !xAxis.isDate && !canUseXLogarithmic {
                    Text(L10n.text("Logarithmic scale requires positive source values."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                ChartAxisRangeEditor(
                    axis: xAxis, sourceRange: xRange, currentRange: xCurrentRange,
                    apply: applyXRange, reset: resetXRange
                )
                if xAxis.isDate {
                    Toggle(L10n.text("Show Dates"), isOn: $options.showDates)
                    Toggle(L10n.text("Show Times"), isOn: $options.showTimes)
                    TextField(L10n.text("Date Format"), text: $options.dateFormat)
                    TextField(L10n.text("Time Format"), text: $options.timeFormat)
                }
            }

            Section(L10n.text("Y Axis")) {
                Toggle(L10n.text("Logarithmic"), isOn: $options.yLogarithmic)
                    .disabled(!canUseYLogarithmic)
                if !canUseYLogarithmic {
                    Text(L10n.text("Logarithmic scale requires positive source values."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                ChartAxisRangeEditor(
                    axis: yAxis, sourceRange: yRange, currentRange: yCurrentRange,
                    apply: applyYRange, reset: resetYRange
                )
            }

        }
        .formStyle(.grouped)
        .frame(width: 360, height: 780)
        .padding(8)
    }
}

private struct ChartAxisRangeEditor: View {
    let axis: PlotAxisPresentation
    let sourceRange: ClosedRange<Double>?
    let currentRange: ClosedRange<Double>?
    let apply: (ClosedRange<Double>) -> Bool
    let reset: () -> Void

    @State private var lowerText: String
    @State private var upperText: String
    @State private var invalidRange = false

    init(
        axis: PlotAxisPresentation,
        sourceRange: ClosedRange<Double>?,
        currentRange: ClosedRange<Double>?,
        apply: @escaping (ClosedRange<Double>) -> Bool,
        reset: @escaping () -> Void
    ) {
        self.axis = axis
        self.sourceRange = sourceRange
        self.currentRange = currentRange
        self.apply = apply
        self.reset = reset
        let initial = currentRange ?? sourceRange
        _lowerText = State(initialValue: initial.map { ChartValueFormatter.axisBound($0.lowerBound, axis: axis) } ?? "")
        _upperText = State(initialValue: initial.map { ChartValueFormatter.axisBound($0.upperBound, axis: axis) } ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(axis.displayTitle).font(.subheadline.weight(.medium))
            if let sourceRange {
                Text(L10n.text("Source Range"))
                    .font(.caption).foregroundStyle(.secondary)
                Text(ChartValueFormatter.axisBound(sourceRange.lowerBound, axis: axis)
                     + " … " + ChartValueFormatter.axisBound(sourceRange.upperBound, axis: axis))
                    .font(.caption.monospacedDigit()).textSelection(.enabled)
                if axis.isDate {
                    Text(L10n.text("Enter local date bounds as YYYY-MM-DD HH:MM:SS."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    TextField(L10n.text("Minimum"), text: $lowerText)
                    TextField(L10n.text("Maximum"), text: $upperText)
                }
                .textFieldStyle(.roundedBorder)
                HStack {
                    Button(L10n.text("Apply View Range"), action: applyRange)
                    Button(L10n.text("Reset View Range")) {
                        invalidRange = false
                        reset()
                        updateFields(sourceRange)
                    }
                }
                if invalidRange {
                    Text(L10n.text("Enter finite increasing bounds inside the source data range."))
                        .font(.caption).foregroundStyle(.red)
                }
            } else {
                Text(L10n.text("No finite source range is available."))
                    .font(.caption).foregroundStyle(.secondary)
                TextField(L10n.text("Minimum"), text: $lowerText).disabled(true)
                TextField(L10n.text("Maximum"), text: $upperText).disabled(true)
            }
        }
        .onChange(of: currentRange) { _, newValue in
            if let newValue { updateFields(newValue) }
        }
    }

    private func parse(_ value: String) -> Double? {
        if axis.isDate {
            let formatter = ChartValueFormatter.rangeDateFormatter()
            guard let date = formatter.date(from: value) else { return nil }
            return date.timeIntervalSince1970
        }
        guard let number = Double(value.trimmingCharacters(in: .whitespacesAndNewlines)), number.isFinite else { return nil }
        return number
    }

    private func applyRange() {
        guard let lower = parse(lowerText), let upper = parse(upperText), lower < upper else {
            invalidRange = true
            return
        }
        invalidRange = !apply(lower...upper)
    }

    private func updateFields(_ range: ClosedRange<Double>) {
        lowerText = ChartValueFormatter.axisBound(range.lowerBound, axis: axis)
        upperText = ChartValueFormatter.axisBound(range.upperBound, axis: axis)
        invalidRange = false
    }
}

enum ChartValueFormatter {
    static func axisBound(_ value: Double, axis: PlotAxisPresentation) -> String {
        guard value.isFinite else { return "" }
        if axis.isDate {
            let formatter = rangeDateFormatter()
            return formatter.string(from: Date(timeIntervalSince1970: value))
        }
        return String(value)
    }

    static func dateLabel(_ date: Date, showDates: Bool, showTimes: Bool, dateFormat: String, timeFormat: String) -> String {
        guard date.timeIntervalSince1970.isFinite else { return "—" }
        var components: [String] = []
        if showDates, !dateFormat.isEmpty { components.append(dateFormat) }
        if showTimes, !timeFormat.isEmpty { components.append(timeFormat) }
        guard !components.isEmpty else { return "" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = components.joined(separator: " ")
        return formatter.string(from: date)
    }

    static func rangeDateFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.isLenient = false
        return formatter
    }

    static func number(_ value: Double) -> String {
        guard value.isFinite else { return "—" }
        return value.formatted(.number.precision(.significantDigits(1...7)))
    }
}

struct ChartDatasetLegend: View {
    let datasets: [PlotDatasetPresentation]
    let colors: [Color]
    @Binding var selectedDatasetID: String?

    private var fallbackColors: [Color] { [.blue, .green, .orange, .purple, .pink, .teal] }

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), alignment: .leading)], alignment: .leading) {
            ForEach(Array(datasets.enumerated()), id: \.element.id) { index, dataset in
                legendItem(dataset, color: color(at: index))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(L10n.text("Legend")))
    }

    @ViewBuilder
    private func legendItem(_ dataset: PlotDatasetPresentation, color: Color) -> some View {
        let isSelected = selectedDatasetID == dataset.id
        Button {
            selectedDatasetID = isSelected ? nil : dataset.id
        } label: {
            Label {
                Text(dataset.displayName).lineLimit(1)
            } icon: {
                Circle().fill(color).frame(width: 8, height: 8)
            }
            .font(.caption)
            .opacity(selectedDatasetID == nil || isSelected ? 1 : 0.28)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint(Text(L10n.text("Select or clear this chart series.")))
    }

    private func color(at index: Int) -> Color {
        if colors.indices.contains(index) { return colors[index] }
        return fallbackColors[index % fallbackColors.count]
    }
}

struct ChartZoomControls: View {
    @Binding var xFraction: Double
    @Binding var yFraction: Double
    var isDisabled = false

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                axisControl("X Zoom", value: $xFraction)
                axisControl("Y Zoom", value: $yFraction)
            }
            VStack(alignment: .leading, spacing: 4) {
                axisControl("X Zoom", value: $xFraction)
                axisControl("Y Zoom", value: $yFraction)
            }
        }
    }

    private func axisControl(_ title: String, value: Binding<Double>) -> some View {
        HStack(spacing: 6) {
            Text(L10n.text(title)).font(.caption)
            Slider(value: value, in: 0.00001...1)
                .frame(minWidth: 80, maxWidth: 200)
                .disabled(isDisabled)
                .accessibilityLabel(Text(L10n.text(title)))
        }
    }
}

enum ChartInteractionMode: String, CaseIterable, Identifiable, Hashable {
    case panAndAxisZoom
    case zoomRectangle

    var id: String { rawValue }

    @MainActor var title: String {
        switch self {
        case .panAndAxisZoom: L10n.text("Pan / Axis Zoom")
        case .zoomRectangle: L10n.text("Zoom Rectangle")
        }
    }
}

struct ChartScrollbarView: NSViewRepresentable {
    @Binding var progress: Double
    let viewportFraction: Double
    let isVertical: Bool
    var isDisabled = false

    func makeCoordinator() -> Coordinator {
        Coordinator(progress: $progress, pageProgressStep: PlotDisplayMath.scrollPageStepProgress(fraction: viewportFraction))
    }

    func makeNSView(context: Context) -> NSScroller {
        let frame = isVertical
            ? NSRect(x: 0, y: 0, width: 16, height: 100)
            : NSRect(x: 0, y: 0, width: 100, height: 16)
        let scroller = NSScroller(frame: frame)
        scroller.controlSize = .small
        scroller.scrollerStyle = NSScroller.preferredScrollerStyle
        scroller.target = context.coordinator
        scroller.action = #selector(Coordinator.scrolled(_:))
        scroller.isContinuous = true
        update(scroller)
        return scroller
    }

    func updateNSView(_ scroller: NSScroller, context: Context) {
        context.coordinator.progress = $progress
        context.coordinator.pageProgressStep = PlotDisplayMath.scrollPageStepProgress(fraction: viewportFraction)
        update(scroller)
    }

    static func dismantleNSView(_ scroller: NSScroller, coordinator: Coordinator) {
        scroller.target = nil
    }

    private func update(_ scroller: NSScroller) {
        scroller.isEnabled = !isDisabled && viewportFraction < 1
        scroller.knobProportion = CGFloat(min(max(viewportFraction, 0), 1))
        scroller.doubleValue = min(max(progress, 0), 1)
    }

    @MainActor
    final class Coordinator: NSObject {
        var progress: Binding<Double>
        var pageProgressStep: Double

        init(progress: Binding<Double>, pageProgressStep: Double) {
            self.progress = progress
            self.pageProgressStep = pageProgressStep
        }

        @objc func scrolled(_ sender: NSScroller) {
            switch sender.hitPart {
            case .decrementPage:
                progress.wrappedValue = max(0, progress.wrappedValue - pageProgressStep)
            case .incrementPage:
                progress.wrappedValue = min(1, progress.wrappedValue + pageProgressStep)
            default:
                progress.wrappedValue = min(max(sender.doubleValue, 0), 1)
            }
        }
    }
}

struct ChartDataTableView: View {
    let datasets: [PlotDatasetPresentation]
    let xAxis: PlotAxisPresentation
    let yAxis: PlotAxisPresentation
    let samples: [ChartSample]
    let dateFormat: String
    let timeFormat: String
    let showDates: Bool
    let showTimes: Bool

    private var rows: [ChartDataTableRow] {
        datasets.flatMap { dataset in
            samples.filter { $0.datasetKey == dataset.id }.map { sample in
                let displayed = dataset.forDisplay(sample)
                return ChartDataTableRow(
                    id: dataset.id + "/" + sample.id,
                    series: dataset.displayName,
                    x: xAxis.isDate
                        ? ChartValueFormatter.dateLabel(Date(timeIntervalSince1970: sample.x), showDates: showDates, showTimes: showTimes,
                                                        dateFormat: dateFormat, timeFormat: timeFormat)
                        : ChartValueFormatter.number(sample.x),
                    y: ChartValueFormatter.number(displayed.y)
                )
            }
        }
    }

    var body: some View {
        Table(rows) {
            TableColumn(L10n.text("Series"), value: \.series)
            TableColumn(xAxis.displayTitle, value: \.x)
            TableColumn(yAxis.displayTitle, value: \.y)
        }
        .accessibilityLabel(Text(L10n.text("Data Table")))
    }
}

private struct ChartDataTableRow: Identifiable {
    let id: String
    let series: String
    let x: String
    let y: String
}

struct ChartScrubbedDataDisplay: View {
    let x: Double
    let xAxis: PlotAxisPresentation
    let yAxis: PlotAxisPresentation
    let datasets: [PlotDatasetPresentation]
    let samples: [ChartSample]
    var showDates = true
    var showTimes = true
    var dateFormat = "yyyy-MM-dd"
    var timeFormat = "HH:mm:ss"

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(L10n.text("Cursor Value")).font(.caption).foregroundStyle(.secondary)
                if xAxis.isDate {
                    Text(ChartValueFormatter.dateLabel(Date(timeIntervalSince1970: x), showDates: showDates, showTimes: showTimes,
                                                       dateFormat: dateFormat, timeFormat: timeFormat))
                        .font(.caption.monospacedDigit())
                } else {
                    Text(ChartValueFormatter.number(x)).font(.caption.monospacedDigit())
                }
            }
            ForEach(datasets) { dataset in
                let values = PlotDisplayMath.scrub(
                    samples.filter { $0.datasetKey == dataset.id }.map(dataset.forDisplay),
                    x: x,
                    logX: xAxis.logarithmic,
                    logY: yAxis.logarithmic
                )
                LabeledContent(dataset.displayName, value: formatted(values))
                    .font(.caption)
                    .textSelection(.enabled)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(L10n.text("Cursor Value")))
    }

    private func formatted(_ values: [Double]) -> String {
        guard !values.isEmpty else { return "—" }
        let valuesText = values.map(ChartValueFormatter.number).joined(separator: ", ")
        return yAxis.units.isEmpty ? valuesText : valuesText + " " + yAxis.units
    }
}
