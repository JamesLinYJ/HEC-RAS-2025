import Charts
import RASWorkspaceCore
import SwiftUI

enum MapDynamicProfileQuantity: Hashable, Sendable {
    case elevation, depth, velocity, depthTimesVelocity
    case unknown(String)

    init(series: MapDynamicProfileSeries) {
        if series.sourceKind == "Terrain" { self = .elevation; return }
        switch series.mapType {
        case "WaterSurfaceElevation", "Water Surface": self = .elevation
        case "Depth": self = .depth
        case "Velocity": self = .velocity
        case "DepthTimesVelocity", "D*V": self = .depthTimesVelocity
        // An unclassified series cannot share an axis merely because another
        // unclassified series happens to use the same unit label.
        default: self = .unknown(series.id)
        }
    }

    var titleKey: String {
        switch self {
        case .elevation: "Elevation"
        case .depth: "Depth"
        case .velocity: "Velocity"
        case .depthTimesVelocity: "Depth × Velocity"
        case .unknown: "Profile Value"
        }
    }

    var order: Int {
        switch self {
        case .elevation: 0
        case .depth: 1
        case .velocity: 2
        case .depthTimesVelocity: 3
        case .unknown: 4
        }
    }
}

struct MapDynamicProfileChartFacet: Identifiable, Sendable {
    struct ID: Hashable, Sendable {
        let quantity: MapDynamicProfileQuantity
        let units: String
    }
    let id: ID
    var seriesIDs: [String] = []
    var samples: [ChartSample] = []
}

struct MapDynamicProfileChartProjection: Sendable {
    let facets: [MapDynamicProfileChartFacet]
    let distanceDomain: ClosedRange<Double>

    init(lines: [MapDynamicProfileLineResult]) {
        var ordered: [MapDynamicProfileChartFacet] = []
        var indexes: [MapDynamicProfileChartFacet.ID: Int] = [:]
        var maximumDistance = 0.0
        for line in lines {
            for distance in line.distances where distance.isFinite && distance >= 0 {
                maximumDistance = max(maximumDistance, distance)
            }
            for series in line.series {
                let key = MapDynamicProfileChartFacet.ID(quantity: .init(series: series), units: series.units)
                let index: Int
                if let existing = indexes[key] { index = existing }
                else {
                    index = ordered.count
                    indexes[key] = index
                    ordered.append(.init(id: key))
                }
                if !ordered[index].seriesIDs.contains(series.id) {
                    ordered[index].seriesIDs.append(series.id)
                }
                ordered[index].samples += line.distances.enumerated().map { offset, distance in
                    let value = series.samples.indices.contains(offset) ? series.samples[offset] : nil
                    return ChartSample(id: line.id + ":" + String(offset), x: distance,
                        y: value ?? .nan, series: series.name, datasetID: series.id)
                }
            }
        }
        facets = ordered.enumerated().sorted { left, right in
            left.element.id.quantity.order == right.element.id.quantity.order
                ? left.offset < right.offset
                : left.element.id.quantity.order < right.element.id.quantity.order
        }.map { $0.element }
        distanceDomain = 0...(maximumDistance > 0 ? maximumDistance : 1)
    }
}

/// Native chart facets preserve the original independent physical axes while
/// keeping station distance and the owning map's hover marker synchronized.
struct MapDynamicProfileFacetedChart: View {
    let lines: [MapDynamicProfileLineResult]
    let orderedSeries: [MapDynamicProfileSeries]
    let colors: [Color]
    let stationDistanceTitle: String
    let cursor: Double?
    let onHover: (Double?) -> Void

    private var projection: MapDynamicProfileChartProjection { .init(lines: lines) }
    private func color(for id: String) -> Color {
        guard let index = orderedSeries.firstIndex(where: { $0.id == id }), colors.indices.contains(index)
        else { return .blue }
        return colors[index]
    }
    private func title(for facet: MapDynamicProfileChartFacet) -> String {
        let quantity = L10n.text(facet.id.quantity.titleKey)
        return facet.id.units.isEmpty ? quantity : quantity + " (" + facet.id.units + ")"
    }

    var body: some View {
        let data = projection
        let facets = data.facets.filter { $0.samples.contains { $0.y.isFinite } }
        GeometryReader { container in
            ScrollView(.vertical) {
                VStack(spacing: 12) {
                    ForEach(facets) { facet in
                        plot(facet, distanceDomain: data.distanceDomain)
                            .frame(height: max(180,
                                (container.size.height - CGFloat(max(0, facets.count - 1)) * 12)
                                    / CGFloat(max(1, facets.count))))
                    }
                }
            }
        }
    }

    private func plot(_ facet: MapDynamicProfileChartFacet,
                      distanceDomain: ClosedRange<Double>) -> some View {
        let yTitle = title(for: facet)
        return Chart {
            ForEach(SeriesPlotPoint.segments(facet.samples)) { point in
                if point.isIsolated {
                    PointMark(x: .value(L10n.text("Station Distance"), point.sample.x),
                        y: .value(yTitle, point.sample.y))
                        .foregroundStyle(by: .value(L10n.text("Source"), point.sample.datasetKey))
                } else {
                    LineMark(x: .value(L10n.text("Station Distance"), point.sample.x), y: .value(yTitle, point.sample.y),
                        series: .value("Source segment", point.sample.datasetKey + "/" + String(point.segment)))
                        .foregroundStyle(by: .value(L10n.text("Source"), point.sample.datasetKey))
                }
            }
            if let cursor, cursor.isFinite {
                RuleMark(x: .value(L10n.text("Station Distance"), cursor)).foregroundStyle(.secondary)
            }
        }
        .chartXScale(domain: distanceDomain)
        .chartXAxisLabel(stationDistanceTitle)
        .chartYAxisLabel(yTitle)
        .chartForegroundStyleScale(domain: facet.seriesIDs, range: facet.seriesIDs.map { color(for: $0) })
        .chartLegend(.hidden)
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Color.clear.contentShape(Rectangle()).onContinuousHover { phase in
                    switch phase {
                    case .active(let position):
                        guard let frame = proxy.plotFrame,
                              geometry[frame].contains(position),
                              let distance: Double = proxy.value(atX: position.x - geometry[frame].minX),
                              distance.isFinite else { onHover(nil); return }
                        onHover(distance)
                    case .ended: onHover(nil)
                    }
                }
            }
        }
    }
}
