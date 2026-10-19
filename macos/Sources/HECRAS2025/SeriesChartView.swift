import Charts
import AppKit
import SwiftUI

struct SeriesChartView: View {
    let samples: [ChartSample]
    let presentation: SeriesEditorPresentation
    var emptyMessage = "The model source has no series values to plot."
    @State private var selectedDatasetID: String? = nil
    @State private var showChartTitle = true
    @AppStorage("HECRAS2025.ChartSettings.IsLegendOverlay") private var legendOverlay = true

    private var source: SeriesChartPresentation { .resolved(presentation, samples: samples) }
    private var plotGroups: [SeriesChartGroup] {
        let groups = SeriesChartGroup.groups(source)
        guard groups.isEmpty else { return groups }
        return [SeriesChartGroup(
            xAxis: .init(id: "x", direction: .x, title: presentation.xTitle, isDate: presentation.xIsDate),
            yAxis: .init(id: "y", direction: .y, title: presentation.yTitle),
            datasets: [])]
    }
    private var chartIdentity: [SeriesChartDataIdentity] {
        plotGroups.map { group in
            let plotSamples = samples.filter { sample in group.datasets.contains { $0.id == sample.datasetKey } }
            return SeriesChartDataIdentity(group: group, samples: plotSamples, source: source,
                                           sourceIdentity: presentation.tableID)
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.width < 400 || geometry.size.height < 300
            if plotGroups.count == 1, let group = plotGroups.first {
                if geometry.size.height < 520 {
                    ScrollView { singleChartContent(group, compact: compact) }
                } else {
                    singleChartContent(group, compact: compact)
                }
            } else {
                ScrollView {
                    VStack(spacing: 16) {
                        if showChartTitle, !compact, !source.title.isEmpty {
                            Text(source.title).font(.headline).textSelection(.enabled)
                        }
                        ForEach(plotGroups) { group in
                            axisPlot(group, compact: compact, showChartTitle: $showChartTitle,
                                     legendOverlay: $legendOverlay)
                        }
                    }
                    .padding(14)
                }
            }
        }
        .onChange(of: chartIdentity) { _, _ in
            selectedDatasetID = nil
        }
    }

    private func axisPlot(_ group: SeriesChartGroup, compact: Bool,
                          showChartTitle: Binding<Bool>, legendOverlay: Binding<Bool>) -> some View {
        let plotSamples = samples.filter { sample in group.datasets.contains { $0.id == sample.datasetKey } }
        return SeriesAxisPlot(
            group: group,
            samples: plotSamples,
            source: source,
            emptyMessage: emptyMessage,
            compact: compact,
            showChartTitle: showChartTitle,
            legendOverlay: legendOverlay,
            selectedDatasetID: $selectedDatasetID
        )
        .id(SeriesChartDataIdentity(group: group, samples: plotSamples, source: source,
                                    sourceIdentity: presentation.tableID))
    }

    private func singleChartContent(_ group: SeriesChartGroup, compact: Bool) -> some View {
        VStack(spacing: 10) {
            if showChartTitle, !compact, !source.title.isEmpty {
                Text(source.title).font(.headline).textSelection(.enabled)
            }
            axisPlot(group, compact: compact, showChartTitle: $showChartTitle,
                     legendOverlay: $legendOverlay)
        }
        .padding(14)
    }
}

private struct SeriesAxisPlot: View {
    let group: SeriesChartGroup
    let samples: [ChartSample]
    let source: SeriesChartPresentation
    let emptyMessage: String
    let compact: Bool
    @Binding var showChartTitle: Bool
    @Binding var legendOverlay: Bool
    @Binding var selectedDatasetID: String?

    @State private var options: ChartDisplayOptions
    @State private var xFraction = 1.0
    @State private var yFraction = 1.0
    @State private var xPosition = 0.0
    @State private var yPosition = 0.0
    @State private var cursor: Double?
    @State private var interactionMode: ChartInteractionMode = .panAndAxisZoom
    @State private var dragTarget: ChartDragTarget?
    @State private var dragStart: CGPoint?
    @State private var dragCurrent: CGPoint?
    @State private var panStartXPosition = 0.0
    @State private var panStartYPosition = 0.0
    @State private var panStartXFraction = 1.0
    @State private var panStartYFraction = 1.0
    @State private var settings = false
    @State private var didInitializeViewport = false

    init(group: SeriesChartGroup, samples: [ChartSample], source: SeriesChartPresentation,
         emptyMessage: String, compact: Bool, showChartTitle: Binding<Bool>,
         legendOverlay: Binding<Bool>, selectedDatasetID: Binding<String?>) {
        self.group = group
        self.samples = samples
        self.source = source
        self.emptyMessage = emptyMessage
        self.compact = compact
        self._showChartTitle = showChartTitle
        self._legendOverlay = legendOverlay
        self._selectedDatasetID = selectedDatasetID
        self._options = State(initialValue: ChartDisplayOptions(source: source, group: group, samples: samples))
    }

    private var points: [SeriesPlotPoint] {
        let displaySamples = samples.map { sample -> ChartSample in
            var result = group.datasets.first { $0.id == sample.datasetKey }?.forDisplay(sample) ?? sample
            if (options.xLogarithmic && result.x <= 0) || (options.yLogarithmic && result.y <= 0) {
                result.y = .nan
            }
            return result
        }
        return SeriesPlotPoint.segments(displaySamples)
    }

    private var xRange: ClosedRange<Double>? {
        PlotDisplayMath.range(points.map { $0.sample.x }, logarithmic: options.xLogarithmic,
                              addNavigationMargin: true)
    }

    private var xDataRange: ClosedRange<Double>? {
        PlotDisplayMath.range(points.map { $0.sample.x }, logarithmic: options.xLogarithmic)
    }

    private var yRange: ClosedRange<Double>? {
        PlotDisplayMath.range(points.map { $0.sample.y }, logarithmic: options.yLogarithmic,
                              addNavigationMargin: true)
    }

    private var yDataRange: ClosedRange<Double>? {
        PlotDisplayMath.range(points.map { $0.sample.y }, logarithmic: options.yLogarithmic)
    }

    private var xZoomLevel: Int {
        guard let domain = xDataRange, let visibleRange = xVisibleRange else { return 0 }
        return ChartAxisTickMath.zoomLevel(domain: domain, visibleRange: visibleRange,
                                           logarithmic: options.xLogarithmic)
    }

    private var yZoomLevel: Int {
        guard let domain = yDataRange, let visibleRange = yVisibleRange else { return 0 }
        return ChartAxisTickMath.zoomLevel(domain: domain, visibleRange: visibleRange,
                                           logarithmic: options.yLogarithmic)
    }

    private func xTickValues(pixelLength: Double, isDate: Bool) -> [Double]? {
        guard let domain = xDataRange, let visibleRange = xVisibleRange else { return nil }
        return ChartAxisTickMath.layout(domain: domain, visibleRange: visibleRange,
                                        pixelLength: pixelLength, pixelsPerTick: options.xPixelsPerTick,
                                        isDate: isDate, logarithmic: options.xLogarithmic)?.values
    }

    private func yTickValues(pixelLength: Double) -> [Double]? {
        guard let domain = yDataRange, let visibleRange = yVisibleRange else { return nil }
        return ChartAxisTickMath.layout(domain: domain, visibleRange: visibleRange,
                                        pixelLength: pixelLength, pixelsPerTick: options.yPixelsPerTick,
                                        logarithmic: options.yLogarithmic)?.values
    }

    private var xVisibleRange: ClosedRange<Double>? {
        xRange.flatMap { PlotDisplayMath.visibleRange($0, position: xPosition, fraction: xFraction, logarithmic: options.xLogarithmic) }
    }

    private var yVisibleRange: ClosedRange<Double>? {
        yRange.flatMap { PlotDisplayMath.visibleRange($0, position: yPosition, fraction: yFraction, logarithmic: options.yLogarithmic) }
    }

    private var xLength: Double {
        xRange.map { PlotDisplayMath.visibleLength($0, position: xPosition, fraction: xFraction, logarithmic: options.xLogarithmic) } ?? 1
    }

    private var yLength: Double {
        yRange.map { PlotDisplayMath.visibleLength($0, position: yPosition, fraction: yFraction, logarithmic: options.yLogarithmic) } ?? 1
    }

    private var xLogAvailable: Bool {
        let values = samples.compactMap { sample -> Double? in
            guard let dataset = group.datasets.first(where: { $0.id == sample.datasetKey }) else { return nil }
            let displayed = dataset.forDisplay(sample)
            return displayed.x.isFinite && displayed.y.isFinite ? displayed.x : nil
        }
        return canUseLogarithmic(values)
    }
    private var yLogAvailable: Bool {
        let values = samples.compactMap { sample -> Double? in
            guard let dataset = group.datasets.first(where: { $0.id == sample.datasetKey }) else { return nil }
            let displayed = dataset.forDisplay(sample)
            return displayed.x.isFinite && displayed.y.isFinite ? displayed.y : nil
        }
        return canUseLogarithmic(values)
    }

    private var colors: [Color] {
        let defaults: [Color] = [.blue, .green, .orange, .purple, .pink, .teal]
        return group.datasets.enumerated().map { index, dataset in
            let base = dataset.colorRGBA.map(EditorColor.decode) ?? defaults[index % defaults.count]
            return selectedDatasetID == nil || selectedDatasetID == dataset.id ? base : base.opacity(0.2)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Menu {
                    Picker(L10n.text("Interaction"), selection: $interactionMode) {
                        ForEach(ChartInteractionMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label(interactionMode.title, systemImage: "hand.draw")
                        .lineLimit(1)
                }
                .help(L10n.text("Chart Interaction Mode"))
                Spacer(minLength: 8)
                if selectedDatasetID != nil {
                    Button(L10n.text("Clear Selection"), systemImage: "xmark.circle") { selectedDatasetID = nil }
                        .labelStyle(.iconOnly)
                        .help(L10n.text("Clear Selection"))
                }
                Button(L10n.text("Fit All"), systemImage: "arrow.up.left.and.arrow.down.right", action: resetAll)
                    .help(L10n.text("Reset View Range"))
                    .disabled(xRange == nil && yRange == nil)
                Button(L10n.text("Chart Options"), systemImage: "slider.horizontal.3") { settings.toggle() }
                    .popover(isPresented: $settings) {
                        ChartDisplayOptionsView(
                            options: $options,
                            showChartTitle: $showChartTitle,
                            legendOverlay: $legendOverlay,
                            xAxis: group.xAxis,
                            yAxis: group.yAxis,
                            xRange: xRange,
                            yRange: yRange,
                            xCurrentRange: xVisibleRange,
                            yCurrentRange: yVisibleRange,
                            xZoomLevel: xZoomLevel,
                            yZoomLevel: yZoomLevel,
                            canUseXLogarithmic: xLogAvailable,
                            canUseYLogarithmic: yLogAvailable,
                            applyXRange: { applyRange($0, axis: .x) },
                            applyYRange: { applyRange($0, axis: .y) },
                            resetXRange: resetX,
                            resetYRange: resetY
                        )
                    }
            }
            .buttonStyle(.borderless)

            if options.showDataTable, !group.datasets.isEmpty {
                VSplitView {
                    chartSection
                        .frame(minHeight: compact ? 140 : 240, idealHeight: compact ? 220 : 420)
                    dataTable
                        .frame(minHeight: compact ? 100 : 120, idealHeight: compact ? 150 : 220)
                }
                .frame(minHeight: compact ? 260 : 380, idealHeight: compact ? 400 : 620)
            } else {
                chartSection
            }
        }
        .onAppear {
            guard !didInitializeViewport else { return }
            didInitializeViewport = true
            resetAll()
        }
        .onChange(of: xRange) { _, _ in clampPositions() }
        .onChange(of: yRange) { _, _ in clampPositions() }
        .onChange(of: xFraction) { _, _ in clampPositions() }
        .onChange(of: yFraction) { _, _ in clampPositions() }
        .onChange(of: options.xLogarithmic) { _, _ in resetX() }
        .onChange(of: options.yLogarithmic) { _, _ in resetY() }
    }

    @ViewBuilder
    private var chartSection: some View {
        if let xRange, let yRange {
            chartWithViewport(xRange: xRange, yRange: yRange)
        } else {
            ZStack(alignment: .topTrailing) {
                chart(pixelSize: nil)
                    .frame(minHeight: 240, idealHeight: 300)
                    .overlay {
                        Label(L10n.text(emptyMessage), systemImage: "chart.xyaxis.line")
                            .font(.callout).foregroundStyle(.secondary)
                            .padding(12).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    }
                if showsLegend && legendOverlay && !group.datasets.isEmpty { legendPanel }
            }
        }
    }

    private var dataTable: some View {
        ChartDataTableView(datasets: group.datasets, xAxis: group.xAxis, yAxis: group.yAxis,
                           samples: samples, dateFormat: options.dateFormat, timeFormat: options.timeFormat,
                           showDates: options.showDates, showTimes: options.showTimes)
    }

    private var showsLegend: Bool { options.showLegend && !compact }

    private func chart(pixelSize: CGSize?) -> some View {
        Chart {
            ForEach(points) { point in
                mark(point)
                    .foregroundStyle(by: .value("Dataset", point.sample.datasetKey))
                    .accessibilityLabel(Text(group.datasets.first { $0.id == point.sample.datasetKey }?.displayName ?? point.sample.series))
                    .accessibilityValue(Text(accessibleValue(point.sample)))
            }
            if let cursor {
                if group.xAxis.isDate {
                    RuleMark(x: .value("Cursor", Date(timeIntervalSince1970: cursor)))
                        .foregroundStyle(.secondary).lineStyle(.init(lineWidth: 1, dash: [4, 4]))
                } else {
                    RuleMark(x: .value("Cursor", cursor))
                        .foregroundStyle(.secondary).lineStyle(.init(lineWidth: 1, dash: [4, 4]))
                }
            }
        }
        .chartForegroundStyleScale(domain: group.datasets.map(\.id), range: colors)
        .chartLegend(.hidden)
        .chartXAxis {
            if options.showXAxis {
                if group.xAxis.isDate {
                    if let pixelSize, let ticks = xTickValues(pixelLength: pixelSize.width, isDate: true) {
                        AxisMarks(values: ticks.map { Date(timeIntervalSince1970: $0) }) { value in
                            AxisGridLine()
                            AxisTick()
                            AxisValueLabel {
                                if let date = value.as(Date.self) {
                                    Text(ChartValueFormatter.dateLabel(date, showDates: options.showDates,
                                                                       showTimes: options.showTimes,
                                                                       dateFormat: options.dateFormat,
                                                                       timeFormat: options.timeFormat))
                                        .font(.system(size: options.xAxisFontSize))
                                }
                            }
                        }
                    } else {
                        AxisMarks(values: .automatic) { value in
                            AxisGridLine()
                            AxisTick()
                            AxisValueLabel {
                                if let date = value.as(Date.self) {
                                    Text(ChartValueFormatter.dateLabel(date, showDates: options.showDates,
                                                                       showTimes: options.showTimes,
                                                                       dateFormat: options.dateFormat,
                                                                       timeFormat: options.timeFormat))
                                        .font(.system(size: options.xAxisFontSize))
                                }
                            }
                        }
                    }
                } else if let pixelSize, let ticks = xTickValues(pixelLength: pixelSize.width, isDate: false) {
                    AxisMarks(values: ticks) { value in
                        AxisGridLine()
                        AxisTick()
                        AxisValueLabel {
                            if let number = value.as(Double.self) {
                                Text(ChartValueFormatter.number(number)).font(.system(size: options.xAxisFontSize))
                            }
                        }
                    }
                } else {
                    AxisMarks(values: .automatic) { value in
                        AxisGridLine()
                        AxisTick()
                        AxisValueLabel {
                            if let number = value.as(Double.self) {
                                Text(ChartValueFormatter.number(number)).font(.system(size: options.xAxisFontSize))
                            }
                        }
                    }
                }
            }
        }
        .chartYAxis {
            if options.showYAxis {
                if let pixelSize, let ticks = yTickValues(pixelLength: pixelSize.height) {
                    AxisMarks(values: ticks) { value in
                        AxisGridLine()
                        AxisTick()
                        AxisValueLabel {
                            if let number = value.as(Double.self) {
                                Text(ChartValueFormatter.number(number)).font(.system(size: options.yAxisFontSize))
                            }
                        }
                    }
                } else {
                    AxisMarks(values: .automatic) { value in
                        AxisGridLine()
                        AxisTick()
                        AxisValueLabel {
                            if let number = value.as(Double.self) {
                                Text(ChartValueFormatter.number(number)).font(.system(size: options.yAxisFontSize))
                            }
                        }
                    }
                }
            }
        }
        .chartXAxisLabel {
            if options.showXAxis && options.showXAxisTitle && !compact {
                Text(group.xAxis.displayTitle).font(.system(size: options.xAxisFontSize))
            }
        }
        .chartYAxisLabel {
            if options.showYAxis && options.showYAxisTitle && !compact {
                Text(group.yAxis.displayTitle).font(.system(size: options.yAxisFontSize))
            }
        }
    }

    private var legend: some View {
        ChartDatasetLegend(datasets: group.datasets, colors: colors, selectedDatasetID: $selectedDatasetID)
            .padding(8)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
    }

    private var legendPanel: some View {
        legend.padding(8)
    }

    @ViewBuilder
    private func chartWithViewport(xRange: ClosedRange<Double>, yRange: ClosedRange<Double>) -> some View {
        VStack(spacing: 5) {
            HStack(alignment: .center, spacing: 3) {
                GeometryReader { geometry in
                    let horizontalAxisSpace = options.showXAxis
                        ? (options.showDates ? 38.0 : 19.0) + (options.showXAxisTitle ? options.xAxisFontSize : 0) + 16
                        : 16
                    let verticalAxisSpace = options.showYAxis
                        ? 48.0 + (options.showYAxisTitle ? options.yAxisFontSize : 0) + 16
                        : 16
                    let plotSize = CGSize(width: max(1, geometry.size.width - verticalAxisSpace),
                                          height: max(1, geometry.size.height - horizontalAxisSpace))
                    ZStack(alignment: .topTrailing) {
                        Group {
                            if group.xAxis.isDate {
                                chart(pixelSize: plotSize)
                                    .chartXScale(domain: Date(timeIntervalSince1970: xRange.lowerBound)...Date(timeIntervalSince1970: xRange.upperBound))
                                    .chartScrollPosition(x: Binding(
                                        get: { Date(timeIntervalSince1970: xPosition) },
                                        set: { xPosition = $0.timeIntervalSince1970 }
                                    ))
                            } else {
                                chart(pixelSize: plotSize)
                                    .chartXScale(domain: xRange, type: options.xLogarithmic ? .log : .linear)
                                    .chartScrollPosition(x: $xPosition)
                            }
                        }
                        .chartYScale(domain: yRange, type: options.yLogarithmic ? .log : .linear)
                        .chartYVisibleDomain(length: yLength)
                        .chartXVisibleDomain(length: xLength)
                        .chartScrollableAxes([.horizontal, .vertical])
                        .chartScrollPosition(y: $yPosition)
                        .chartOverlay { proxy in
                            ChartInteractionOverlay(
                                proxy: proxy,
                                xIsDate: group.xAxis.isDate,
                                xAxisEnabled: options.showXAxis,
                                yAxisEnabled: options.showYAxis,
                                interactionMode: interactionMode,
                                selectionTarget: dragTarget,
                                onHover: { cursor = $0 },
                                onWheelZoom: { x, y, xFactor, yFactor in
                                    if let x { zoomX(at: x, factor: xFactor) }
                                    if let y { zoomY(at: y, factor: yFactor) }
                                },
                                selectionRect: selectionRect,
                                dragBegan: beginDrag,
                                dragChanged: changeDrag,
                                dragEnded: { target, start, end, plotBounds in
                                    finishDrag(target: target, start: start, end: end, plotBounds: plotBounds, proxy: proxy)
                                }
                            )
                        }

                        if showsLegend && legendOverlay {
                            legendPanel
                        }
                    }
                }
                .frame(minHeight: 240, idealHeight: 300)

                if options.showScrollBars && yFraction <= 1.299 / 1.3 {
                    ChartScrollbarView(progress: yScrollProgress, viewportFraction: yFraction,
                                       isVertical: true)
                        .frame(width: 16)
                        .frame(maxHeight: .infinity)
                        .accessibilityLabel(Text(L10n.format("%@ Scroll Position", L10n.text("Y"))))
                }
            }

            if options.showScrollBars && xFraction <= 1.299 / 1.3 {
                ChartScrollbarView(progress: xScrollProgress, viewportFraction: xFraction,
                                   isVertical: false)
                    .frame(height: 16)
                    .accessibilityLabel(Text(L10n.format("%@ Scroll Position", L10n.text("X"))))
            }

            ChartZoomControls(xFraction: $xFraction, yFraction: $yFraction,
                              isDisabled: false)
            if showsLegend, !legendOverlay, !group.datasets.isEmpty {
                legend
            }
            if let cursor {
                ChartScrubbedDataDisplay(
                    x: cursor, xAxis: effectiveAxis(group.xAxis, logarithmic: options.xLogarithmic),
                    yAxis: effectiveAxis(group.yAxis, logarithmic: options.yLogarithmic),
                    datasets: group.datasets, samples: samples,
                    showDates: options.showDates, showTimes: options.showTimes,
                    dateFormat: options.dateFormat, timeFormat: options.timeFormat
                )
            }
            if points.count > 1 {
                Text(interactionMode == .panAndAxisZoom
                     ? L10n.text("Drag in the plot to pan; drag an axis to zoom it.")
                     : L10n.text("Drag in the plot to zoom to a range."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var xScrollProgress: Binding<Double> {
        Binding(
            get: { xRange.map { PlotDisplayMath.scrollProgress($0, position: xPosition, fraction: xFraction, logarithmic: options.xLogarithmic) } ?? 0 },
            set: { progress in
                if let range = xRange {
                    xPosition = PlotDisplayMath.position(atScrollProgress: progress, in: range, fraction: xFraction, logarithmic: options.xLogarithmic)
                }
            }
        )
    }

    private var yScrollProgress: Binding<Double> {
        Binding(
            get: { yRange.map { PlotDisplayMath.scrollProgress($0, position: yPosition, fraction: yFraction, logarithmic: options.yLogarithmic) } ?? 0 },
            set: { progress in
                if let range = yRange {
                    yPosition = PlotDisplayMath.position(atScrollProgress: progress, in: range, fraction: yFraction, logarithmic: options.yLogarithmic)
                }
            }
        )
    }

    private var selectionRect: CGRect? {
        guard let dragStart, let dragCurrent else { return nil }
        if dragTarget == .plot && interactionMode == .panAndAxisZoom { return nil }
        return CGRect(x: min(dragStart.x, dragCurrent.x), y: min(dragStart.y, dragCurrent.y),
                      width: abs(dragCurrent.x - dragStart.x), height: abs(dragCurrent.y - dragStart.y))
    }

    @ChartContentBuilder
    private func mark(_ point: SeriesPlotPoint) -> some ChartContent {
        if group.xAxis.isDate {
            if point.isIsolated {
                PointMark(x: .value(group.xAxis.displayTitle, Date(timeIntervalSince1970: point.sample.x)),
                          y: .value(group.yAxis.displayTitle, point.sample.y))
            } else {
                LineMark(x: .value(group.xAxis.displayTitle, Date(timeIntervalSince1970: point.sample.x)),
                         y: .value(group.yAxis.displayTitle, point.sample.y),
                         series: .value("Segment", point.sample.datasetKey + "/" + String(point.segment)))
            }
        } else if point.isIsolated {
            PointMark(x: .value(group.xAxis.displayTitle, point.sample.x), y: .value(group.yAxis.displayTitle, point.sample.y))
        } else {
            LineMark(x: .value(group.xAxis.displayTitle, point.sample.x), y: .value(group.yAxis.displayTitle, point.sample.y),
                     series: .value("Segment", point.sample.datasetKey + "/" + String(point.segment)))
        }
    }

    private func accessibleValue(_ sample: ChartSample) -> String {
        let x = group.xAxis.isDate
            ? ChartValueFormatter.dateLabel(Date(timeIntervalSince1970: sample.x), showDates: options.showDates, showTimes: options.showTimes,
                                            dateFormat: options.dateFormat, timeFormat: options.timeFormat)
            : ChartValueFormatter.number(sample.x)
        return group.xAxis.displayTitle + ": " + x + ", " + group.yAxis.displayTitle + ": " + ChartValueFormatter.number(sample.y)
    }

    private func applyRange(_ range: ClosedRange<Double>, axis: PlotAxisPresentation.Direction) -> Bool {
        switch axis {
        case .x:
            guard let sourceRange = xRange,
                  let viewport = PlotDisplayMath.viewport(for: range, within: sourceRange, logarithmic: options.xLogarithmic) else { return false }
            xPosition = viewport.position
            xFraction = viewport.fraction
        case .y:
            guard let sourceRange = yRange,
                  let viewport = PlotDisplayMath.viewport(for: range, within: sourceRange, logarithmic: options.yLogarithmic) else { return false }
            yPosition = viewport.position
            yFraction = viewport.fraction
        }
        cursor = nil
        return true
    }

    private func zoomX(at anchor: Double, factor: Double) {
        guard let range = xRange,
              let viewport = PlotDisplayMath.zoomedViewport(range, position: xPosition, fraction: xFraction,
                                                             anchor: anchor, factor: factor,
                                                             logarithmic: options.xLogarithmic) else { return }
        xPosition = viewport.position
        xFraction = viewport.fraction
        cursor = nil
    }

    private func zoomY(at anchor: Double, factor: Double) {
        guard let range = yRange,
              let viewport = PlotDisplayMath.zoomedViewport(range, position: yPosition, fraction: yFraction,
                                                             anchor: anchor, factor: factor,
                                                             logarithmic: options.yLogarithmic) else { return }
        yPosition = viewport.position
        yFraction = viewport.fraction
        cursor = nil
    }

    private func resetX() {
        xFraction = 1
        xPosition = xRange?.lowerBound ?? 0
    }

    private func resetY() {
        yFraction = 1
        yPosition = yRange?.lowerBound ?? 0
    }

    private func resetAll() {
        resetX()
        resetY()
        cursor = nil
        dragStart = nil
        dragCurrent = nil
    }

    private func clampPositions() {
        if let range = xRange {
            let maximum = PlotDisplayMath.maximumPosition(range, fraction: xFraction, logarithmic: options.xLogarithmic)
            xPosition = min(max(xPosition, range.lowerBound), max(range.lowerBound, maximum))
        }
        if let range = yRange {
            let maximum = PlotDisplayMath.maximumPosition(range, fraction: yFraction, logarithmic: options.yLogarithmic)
            yPosition = min(max(yPosition, range.lowerBound), max(range.lowerBound, maximum))
        }
    }

    private func canUseLogarithmic(_ values: [Double]) -> Bool {
        let finite = values.filter(\.isFinite)
        return !finite.isEmpty && finite.allSatisfy { $0 > 0 }
    }

    private func beginDrag(_ target: ChartDragTarget, _ start: CGPoint) {
        dragTarget = target
        dragStart = start
        dragCurrent = start
        if target == .plot && interactionMode == .panAndAxisZoom {
            panStartXPosition = xPosition
            panStartYPosition = yPosition
            panStartXFraction = xFraction
            panStartYFraction = yFraction
        }
    }

    private func changeDrag(_ target: ChartDragTarget, _ start: CGPoint, _ current: CGPoint, _ plotBounds: CGRect) {
        dragTarget = target
        dragStart = start
        dragCurrent = current
        guard target == .plot, interactionMode == .panAndAxisZoom,
              plotBounds.width > 0, plotBounds.height > 0 else { return }
        let horizontalTranslation = -Double(current.x - start.x) / Double(plotBounds.width)
        let verticalTranslation = Double(current.y - start.y) / Double(plotBounds.height)
        if let xRange,
           let viewport = PlotDisplayMath.pannedViewport(
                xRange, position: panStartXPosition, fraction: panStartXFraction,
                translationFraction: horizontalTranslation, logarithmic: options.xLogarithmic
           ) {
            xPosition = viewport.position
        }
        if let yRange,
           let viewport = PlotDisplayMath.pannedViewport(
                yRange, position: panStartYPosition, fraction: panStartYFraction,
                translationFraction: verticalTranslation, logarithmic: options.yLogarithmic
           ) {
            yPosition = viewport.position
        }
        cursor = nil
    }

    private func finishDrag(target: ChartDragTarget, start: CGPoint, end: CGPoint,
                            plotBounds: CGRect, proxy: ChartProxy) {
        defer { dragTarget = nil; dragStart = nil; dragCurrent = nil }
        guard abs(end.x - start.x) > 6 || abs(end.y - start.y) > 6 else { return }
        switch target {
        case .plot:
            if interactionMode == .zoomRectangle {
                applyRectangleZoom(start: start, end: end, proxy: proxy)
            }
        case .horizontalAxis:
            applyAxisZoom(startFraction: Double(start.x / max(plotBounds.width, 1)),
                          endFraction: Double(end.x / max(plotBounds.width, 1)), axis: .x)
        case .verticalAxis:
            applyAxisZoom(startFraction: Double(1 - start.y / max(plotBounds.height, 1)),
                          endFraction: Double(1 - end.y / max(plotBounds.height, 1)), axis: .y)
        }
    }

    private func applyAxisZoom(startFraction: Double, endFraction: Double,
                               axis: PlotAxisPresentation.Direction) {
        guard abs(endFraction - startFraction) > 0.002 else { return }
        switch axis {
        case .x:
            guard let visibleRange = xVisibleRange,
                  let first = PlotDisplayMath.value(in: visibleRange, at: startFraction, logarithmic: options.xLogarithmic),
                  let second = PlotDisplayMath.value(in: visibleRange, at: endFraction, logarithmic: options.xLogarithmic) else { return }
            _ = applyRange(min(first, second)...max(first, second), axis: .x)
        case .y:
            guard let visibleRange = yVisibleRange,
                  let first = PlotDisplayMath.value(in: visibleRange, at: startFraction, logarithmic: options.yLogarithmic),
                  let second = PlotDisplayMath.value(in: visibleRange, at: endFraction, logarithmic: options.yLogarithmic) else { return }
            _ = applyRange(min(first, second)...max(first, second), axis: .y)
        }
    }

    private func applyRectangleZoom(start: CGPoint, end: CGPoint, proxy: ChartProxy) {
        guard abs(end.x - start.x) > 6, abs(end.y - start.y) > 6,
              let xRange, let yRange,
              let x0 = chartXValue(start.x, proxy: proxy), let x1 = chartXValue(end.x, proxy: proxy),
              let y0 = proxy.value(atY: start.y, as: Double.self), let y1 = proxy.value(atY: end.y, as: Double.self) else { return }
        let xSelection = min(x0, x1)...max(x0, x1)
        let ySelection = min(y0, y1)...max(y0, y1)
        guard let xViewport = PlotDisplayMath.viewport(for: xSelection, within: xRange, logarithmic: options.xLogarithmic),
              let yViewport = PlotDisplayMath.viewport(for: ySelection, within: yRange, logarithmic: options.yLogarithmic) else { return }
        xPosition = xViewport.position
        xFraction = xViewport.fraction
        yPosition = yViewport.position
        yFraction = yViewport.fraction
        cursor = nil
    }

    private func chartXValue(_ position: CGFloat, proxy: ChartProxy) -> Double? {
        if group.xAxis.isDate { return proxy.value(atX: position, as: Date.self)?.timeIntervalSince1970 }
        return proxy.value(atX: position, as: Double.self)
    }

    private func effectiveAxis(_ axis: PlotAxisPresentation, logarithmic: Bool) -> PlotAxisPresentation {
        var result = axis
        result.logarithmic = logarithmic
        return result
    }
}

private enum ChartDragTarget: Equatable {
    case plot
    case horizontalAxis
    case verticalAxis
}

private struct ChartInteractionOverlay: View {
    let proxy: ChartProxy
    let xIsDate: Bool
    let xAxisEnabled: Bool
    let yAxisEnabled: Bool
    let interactionMode: ChartInteractionMode
    let selectionTarget: ChartDragTarget?
    let onHover: (Double?) -> Void
    let onWheelZoom: (Double?, Double?, Double, Double) -> Void
    let selectionRect: CGRect?
    let dragBegan: (ChartDragTarget, CGPoint) -> Void
    let dragChanged: (ChartDragTarget, CGPoint, CGPoint, CGRect) -> Void
    let dragEnded: (ChartDragTarget, CGPoint, CGPoint, CGRect) -> Void

    @State private var dragOrigin: CGPoint? = nil
    @State private var activeTarget: ChartDragTarget? = nil

    var body: some View {
        GeometryReader { geometry in
            if let plotFrame = proxy.plotFrame {
                let plotBounds = geometry[plotFrame]
                ZStack(alignment: .topLeading) {
                    ChartScrollWheelCapture { location, wheelMovedUp in
                        if plotBounds.contains(location),
                           let x = chartXValue(location.x - plotBounds.minX),
                           let y = proxy.value(atY: location.y - plotBounds.minY, as: Double.self) {
                            let factor = wheelMovedUp ? 0.9 : 1.1
                            onWheelZoom(x, y, factor, factor)
                            return true
                        }

                        if location.x >= plotBounds.minX, location.x <= plotBounds.maxX,
                           location.y >= plotBounds.maxY, location.y <= geometry.size.height,
                           let x = chartXValue(location.x - plotBounds.minX) {
                            onWheelZoom(x, nil, wheelMovedUp ? 0.95 : 1.05, 1)
                            return true
                        }

                        if location.x >= 0, location.x <= plotBounds.minX,
                           location.y >= plotBounds.minY, location.y <= plotBounds.maxY,
                           let y = proxy.value(atY: location.y - plotBounds.minY, as: Double.self) {
                            onWheelZoom(nil, y, 1, wheelMovedUp ? 0.95 : 1.05)
                            return true
                        }
                        return false
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)

                    Color.clear
                        .contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let location):
                                guard plotBounds.contains(location) else { onHover(nil); return }
                                onHover(chartXValue(location.x - plotBounds.minX))
                            case .ended:
                                onHover(nil)
                            }
                        }
                        .highPriorityGesture(
                            DragGesture(minimumDistance: 8)
                                .onChanged { value in
                                    let start = CGPoint(x: value.startLocation.x - plotBounds.minX, y: value.startLocation.y - plotBounds.minY)
                                    let current = CGPoint(x: value.location.x - plotBounds.minX, y: value.location.y - plotBounds.minY)
                                    if dragOrigin == nil {
                                        guard let target = dragTarget(at: value.startLocation, plotBounds: plotBounds, viewSize: geometry.size) else { return }
                                        dragOrigin = start
                                        activeTarget = target
                                        dragBegan(target, start)
                                    }
                                    guard let dragOrigin, let activeTarget else { return }
                                    dragChanged(activeTarget, dragOrigin, current, CGRect(origin: .zero, size: plotBounds.size))
                                }
                                .onEnded { value in
                                    defer { dragOrigin = nil; activeTarget = nil }
                                    guard let dragOrigin, let activeTarget else { return }
                                    let end = CGPoint(x: value.location.x - plotBounds.minX, y: value.location.y - plotBounds.minY)
                                    dragEnded(activeTarget, dragOrigin, end, CGRect(origin: .zero, size: plotBounds.size))
                                }
                        )

                    if let selectionRect, let selectionTarget {
                        selectionMark(selectionTarget, rect: selectionRect, plotBounds: plotBounds)
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
            }
        }
    }

    @ViewBuilder
    private func selectionMark(_ target: ChartDragTarget, rect: CGRect, plotBounds: CGRect) -> some View {
        switch target {
        case .plot:
            Rectangle()
                .fill(Color.accentColor.opacity(0.12))
                .overlay(Rectangle().stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                .frame(width: rect.width, height: rect.height)
                .offset(x: plotBounds.minX + rect.minX, y: plotBounds.minY + rect.minY)
                .allowsHitTesting(false)
        case .horizontalAxis:
            Rectangle()
                .fill(Color.accentColor.opacity(0.12))
                .frame(width: max(rect.width, 1), height: plotBounds.height)
                .offset(x: plotBounds.minX + rect.minX, y: plotBounds.minY)
                .allowsHitTesting(false)
        case .verticalAxis:
            Rectangle()
                .fill(Color.accentColor.opacity(0.12))
                .frame(width: plotBounds.width, height: max(rect.height, 1))
                .offset(x: plotBounds.minX, y: plotBounds.minY + rect.minY)
                .allowsHitTesting(false)
        }
    }

    private func dragTarget(at point: CGPoint, plotBounds: CGRect, viewSize: CGSize) -> ChartDragTarget? {
        if plotBounds.contains(point) { return .plot }
        if xAxisEnabled, point.x >= plotBounds.minX, point.x <= plotBounds.maxX,
           point.y >= plotBounds.maxY, point.y <= viewSize.height { return .horizontalAxis }
        if yAxisEnabled, point.x >= 0, point.x <= plotBounds.minX,
           point.y >= plotBounds.minY, point.y <= plotBounds.maxY { return .verticalAxis }
        return nil
    }

    private func chartXValue(_ position: CGFloat) -> Double? {
        if xIsDate { return proxy.value(atX: position, as: Date.self)?.timeIntervalSince1970 }
        return proxy.value(atX: position, as: Double.self)
    }
}

/// Routes only coarse wheel events over this chart. Precise trackpad scrolling
/// remains available to Swift Charts as the native pan gesture. The local
/// monitor is removed with the chart view and does not consume events outside
/// this view's current window bounds.
private struct ChartScrollWheelCapture: NSViewRepresentable {
    let onWheel: (CGPoint, Bool) -> Bool

    func makeNSView(context: Context) -> ChartScrollWheelRoutingView {
        let view = ChartScrollWheelRoutingView()
        view.onWheel = onWheel
        return view
    }

    func updateNSView(_ view: ChartScrollWheelRoutingView, context: Context) {
        view.onWheel = onWheel
    }

    static func dismantleNSView(_ view: ChartScrollWheelRoutingView, coordinator: ()) {
        view.removeWheelMonitor()
    }
}

@MainActor
private final class ChartScrollWheelRoutingView: NSView {
    var onWheel: ((CGPoint, Bool) -> Bool)?
    private var wheelMonitor: Any?

    override var isOpaque: Bool { false }
    // ChartProxy and the SwiftUI overlay use a top-left origin.
    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { removeWheelMonitor() }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        installWheelMonitorIfNeeded()
    }

    func removeWheelMonitor() {
        if let wheelMonitor {
            NSEvent.removeMonitor(wheelMonitor)
            self.wheelMonitor = nil
        }
    }

    private func installWheelMonitorIfNeeded() {
        guard wheelMonitor == nil, window != nil else { return }
        wheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, let targetWindow = self.window,
                  event.window === targetWindow,
                  !event.hasPreciseScrollingDeltas,
                  event.scrollingDeltaY != 0 else { return event }
            let location = self.convert(event.locationInWindow, from: nil)
            guard self.bounds.contains(location),
                  self.onWheel?(location, event.scrollingDeltaY > 0) == true else { return event }
            return nil
        }
    }
}

struct ResultChartActions: View {
    let pageID: String
    let presentation: SeriesChartPresentation
    @ObservedObject var session: ModelEditorSession
    @ObservedObject var store: WorkspaceStore

    var body: some View {
        if presentation.mapTypeFieldID != nil || presentation.canRefresh || presentation.zoomExtent != nil {
            HStack {
                if let field = presentation.mapTypeFieldID {
                    let choices = session.choiceOptions[field] ?? []
                    let value = session.fields[field] ?? ""
                    Picker(L10n.text("Result Map Type"), selection: Binding(get: { value }, set: { id in
                        Task { await session.perform(.selectSource(field: field, id: id)) }
                    })) {
                        if !choices.contains(where: { $0.id == value }) {
                            Text(value.isEmpty ? L10n.text("Select a map type") : value).tag(value)
                        }
                        ForEach(choices) { choice in Text(choice.titleIsUserData == true ? choice.title : L10n.text(choice.title)).tag(choice.id) }
                    }.frame(maxWidth: 300).disabled(choices.isEmpty)
                }
                Spacer()
                if presentation.canRefresh {
                    Button(L10n.text("Refresh Chart"), systemImage: "arrow.clockwise") {
                        Task { await session.perform(.refreshSeries(pageID: pageID)) }
                    }
                }
                if let extent = presentation.zoomExtent {
                    Button(L10n.text("Zoom to Sample Line"), systemImage: "viewfinder") {
                        if let id = presentation.mapID { store.mapState(for: id).viewport = extent }
                    }.disabled(presentation.mapID == nil || !extent.isFiniteAndOrdered)
                }
            }
            .padding(.horizontal, 12).padding(.bottom, 8)
            .disabled(session.isBusy || session.loadingSelection)
        }
    }
}
