import RASWorkspaceCore
import SwiftUI

struct MapViewportFit {
    let scale: CGFloat
    let offset: CGSize
    init?(request: ViewportRequest, points: [MapPoint], size: CGSize) {
        guard request.isFiniteAndOrdered, request.padding.isFinite, request.padding >= 0, size.width > 0, size.height > 0 else { return nil }
        let base = MapTransform(points: points, size: size, scale: 1, offset: .zero)
        guard base.factor.isFinite, base.factor > 0 else { return nil }
        let width = request.upperRight.x - request.lowerLeft.x, height = request.upperRight.y - request.lowerLeft.y
        let desired = min(max(Double(size.width) - request.padding * 2, 1) / width, max(Double(size.height) - request.padding * 2, 1) / height)
        scale = min(max(CGFloat(desired) / base.factor, 0.000001), 1_000_000)
        let fitted = MapTransform(points: points, size: size, scale: scale, offset: .zero)
        let center = fitted.screen(.init(x: request.lowerLeft.x / 2 + request.upperRight.x / 2, y: request.lowerLeft.y / 2 + request.upperRight.y / 2))
        offset = CGSize(width: size.width / 2 - center.x, height: size.height / 2 - center.y)
        guard offset.width.isFinite, offset.height.isFinite else { return nil }
    }
}

struct MapTransform {
    let center: MapPoint
    let factor: CGFloat
    let size: CGSize
    let offset: CGSize
    init(points: [MapPoint], size: CGSize, scale: CGFloat, offset: CGSize) {
        let minX = points.map(\.x).min() ?? 0; let maxX = points.map(\.x).max() ?? 1
        let minY = points.map(\.y).min() ?? 0; let maxY = points.map(\.y).max() ?? 1
        center = MapPoint(x: minX / 2 + maxX / 2, y: minY / 2 + maxY / 2)
        let span = max(maxX - minX, maxY - minY)
        let fallback = span > 0 && span.isFinite ? span : 1
        let width = maxX > minX ? maxX - minX : fallback
        let height = maxY > minY ? maxY - minY : fallback
        factor = min(max(size.width - 64, 1) / CGFloat(width), max(size.height - 64, 1) / CGFloat(height)) * scale
        self.size = size; self.offset = offset
    }
    func screen(_ point: MapPoint) -> CGPoint {
        CGPoint(x: size.width / 2 + CGFloat(point.x - center.x) * factor + offset.width,
                y: size.height / 2 - CGFloat(point.y - center.y) * factor + offset.height)
    }
    func world(_ point: CGPoint) -> MapPoint {
        MapPoint(x: center.x + Double((point.x - size.width / 2 - offset.width) / factor),
                 y: center.y - Double((point.y - size.height / 2 - offset.height) / factor))
    }
    func path(_ feature: MapFeature, pointDiameter: CGFloat = 8) -> Path {
        var path = Path()
        for points in feature.paths {
            guard let first = points.first else { continue }
            if feature.kind == .point { path.addPath(pointPath(first, diameter: pointDiameter)); continue }
            path.move(to: screen(first))
            for point in points.dropFirst() { path.addLine(to: screen(point)) }
            if feature.kind == .polygon { path.closeSubpath() }
        }
        return path
    }
    func pointPath(_ point: MapPoint, diameter: CGFloat) -> Path {
        let size = max(diameter.isFinite ? diameter : 0, 0)
        let center = screen(point)
        return Path(ellipseIn: CGRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size))
    }
    func verticesPath(_ paths: [[MapPoint]], diameter: CGFloat) -> Path {
        var result = Path()
        for points in paths {
            for point in points { result.addPath(pointPath(point, diameter: diameter)) }
        }
        return result
    }
}

struct SourceARGBComponents: Equatable {
    let alpha: UInt8
    let red: UInt8
    let green: UInt8
    let blue: UInt8
}

enum SourceARGBColor {
    /// Source vector colors use `#AARRGGBB`; this is deliberately distinct from
    /// EditorColor's `RRGGBBAA` editor wire format.
    static func components(_ source: String) -> SourceARGBComponents? {
        guard source.first == "#", source.count == 9,
              let value = UInt32(source.dropFirst(), radix: 16) else { return nil }
        return SourceARGBComponents(
            alpha: UInt8((value >> 24) & 0xFF), red: UInt8((value >> 16) & 0xFF),
            green: UInt8((value >> 8) & 0xFF), blue: UInt8(value & 0xFF))
    }

    static func color(_ source: String) -> Color? {
        guard let value = components(source) else { return nil }
        return Color(.sRGB, red: Double(value.red) / 255, green: Double(value.green) / 255,
                     blue: Double(value.blue) / 255, opacity: Double(value.alpha) / 255)
    }
}

enum MapVectorStyleResolver {
    private static let sourceDefaults = MapVectorStylePresentation.sourceMapLayerDefaults

    static func values(layerID: String, feature: MapFeature, definitionID: String,
                       presentations: [String: MapVectorStylePresentation]) -> VectorStyleValues {
        presentations[layerID]?.values(for: definitionID, sourceFeatureIndex: feature.sourceFeatureIndex)
            ?? sourceDefaults.values(for: definitionID, sourceFeatureIndex: feature.sourceFeatureIndex)
            ?? VectorStyleValues()
    }

    static func penColor(_ style: VectorStyleValues, definitionID: String) -> Color {
        let sourceDefault = SourceVectorStyleCatalog.definition(for: definitionID).flatMap { SourceARGBColor.color($0.defaultStyle.penColor) }
        return SourceARGBColor.color(style.penColor) ?? sourceDefault ?? .primary
    }

    static func fillColor(_ style: VectorStyleValues, definitionID: String) -> Color {
        let sourceDefault = SourceVectorStyleCatalog.definition(for: definitionID).flatMap { SourceARGBColor.color($0.defaultStyle.fillColor) }
        return SourceARGBColor.color(style.fillColor) ?? sourceDefault ?? .clear
    }
}

struct VectorMapCanvas: View {
    @ObservedObject private var renderScaling = WorkspaceRenderScaling.shared
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var mapState: MapState
    let mapID: UUID
    let scale: CGFloat
    let offset: CGSize
    @Binding var pointer: MapPoint?
    var orderedLayers: [MapVectorLayer]? = nil
    private var visibleLayers: [MapVectorLayer] { orderedLayers ?? mapState.visibleVectors(store.mapLayers) }
    var body: some View {
        GeometryReader { proxy in
            let transform = MapTransform(points: mapState.transformPoints(vectors: store.mapLayers, rasters: store.rasterLayers), size: proxy.size, scale: scale, offset: offset)
            let renderFactor = renderScaling.factor
            Canvas { context, _ in
                for layer in visibleLayers {
                    for feature in layer.features {
                        let definitionID = MapVectorStyleDefinitionIDs.primaryDefinition(for: feature.kind)
                        let style = MapVectorStyleResolver.values(layerID: layer.id, feature: feature,
                            definitionID: definitionID, presentations: mapState.vectorStyles)
                        let pointDiameter = WorkspaceRenderScaling.metric(Double(Self.safePointDiameter(style.pointSize)), factor: renderFactor)
                        let path = transform.path(feature, pointDiameter: pointDiameter)
                        let penColor = MapVectorStyleResolver.penColor(style, definitionID: definitionID)
                        let fillColor = MapVectorStyleResolver.fillColor(style, definitionID: definitionID)
                        let lineWidth = WorkspaceRenderScaling.metric(Double(Self.safeLineWidth(style.penWidth)), factor: renderFactor)
                        let selected = layer.id == mapState.selectedLayerID && mapState.selectedFeatureIdentities.contains(feature.stableIdentity)
                        if feature.kind == .polygon { context.fill(path, with: .color(fillColor), style: FillStyle(eoFill: true)) }
                        if feature.kind == .point { context.fill(path, with: .color(fillColor)) }
                        context.stroke(path, with: .color(penColor), lineWidth: lineWidth)

                        if let vertexDefinitionID = MapVectorStyleDefinitionIDs.vertexDefinition(for: feature.kind) {
                            let vertexStyle = MapVectorStyleResolver.values(layerID: layer.id, feature: feature,
                                definitionID: vertexDefinitionID, presentations: mapState.vectorStyles)
                            let vertexPaths = feature.kind == .polygon
                                ? feature.paths.map { points in points.first == points.last ? Array(points.dropLast()) : points }
                                : feature.paths
                            let vertices = transform.verticesPath(vertexPaths, diameter: WorkspaceRenderScaling.metric(Double(Self.safePointDiameter(vertexStyle.pointSize)), factor: renderFactor))
                            context.fill(vertices, with: .color(MapVectorStyleResolver.fillColor(vertexStyle, definitionID: vertexDefinitionID)))
                            context.stroke(vertices, with: .color(MapVectorStyleResolver.penColor(vertexStyle, definitionID: vertexDefinitionID)),
                                lineWidth: WorkspaceRenderScaling.metric(Double(Self.safeLineWidth(vertexStyle.penWidth)), factor: renderFactor))
                        }

                        // Interaction highlighting remains a separate overlay;
                        // it never replaces the source base/conditional style.
                        if selected {
                            switch feature.kind {
                            case .point:
                                for points in feature.paths {
                                    guard let point = points.first else { continue }
                                    let overlay = transform.pointPath(point, diameter: pointDiameter + 6)
                                    context.stroke(overlay, with: .color(.orange), lineWidth: 2.5)
                                }
                            case .line, .polygon:
                                context.stroke(path, with: .color(.orange), lineWidth: max(lineWidth + 2, 3))
                            }
                        }
                    }
                }
                for feature in mapState.allPreview {
                    context.stroke(transform.path(feature), with: .color(.orange), style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                }
            }
            .allowsHitTesting(false)
        }
    }

    /// Selection is invoked by ProjectMapView's single map-surface input
    /// router. The canvas only answers against its own visible vector rows;
    /// it never installs a second tap/hover route over geometry or raster.
    @discardableResult
    func selectFeature(at location: CGPoint, transform: MapTransform,
                       modifiers: Set<MapInput.Modifier> = []) -> Bool {
        for layer in visibleLayers.reversed() {
            for feature in layer.features.reversed() {
                let definitionID = MapVectorStyleDefinitionIDs.primaryDefinition(for: feature.kind)
                let style = MapVectorStyleResolver.values(layerID: layer.id, feature: feature,
                    definitionID: definitionID, presentations: mapState.vectorStyles)
                let path = transform.path(feature, pointDiameter: scaledMetric(Self.safePointDiameter(style.pointSize)))
                let hitWidth = max(scaledMetric(Self.safeLineWidth(style.penWidth)), 10)
                if path.contains(location, eoFill: true) || path.strokedPath(StrokeStyle(lineWidth: hitWidth)).contains(location) {
                    let sourcePath = SourceFilePaths.canonical(layer.url)
                    if let asset = store.assets.first(where: { SourceFilePaths.canonical($0.url) == sourcePath }) {
                        store.select(asset)
                    }
                    guard mapState.selectVectorFeature(feature, in: layer,
                        mode: .pointer(modifiers: modifiers)) else { continue }
                    if feature.kind == .line, mapState.selectedFeatureIdentities.contains(feature.stableIdentity) {
                        for (index, points) in feature.paths.enumerated().reversed() {
                            let component = MapFeature(id: feature.id, kind: .line, paths: [points], attributes: feature.attributes)
                            if transform.path(component).strokedPath(StrokeStyle(lineWidth: hitWidth)).contains(location), feature.pathStableIdentities.indices.contains(index) {
                                mapState.selectedLineIdentity = feature.pathStableIdentities[index]; break
                            }
                        }
                    }
                    store.activateMap(mapID)
                    store.selectedFeatureID = mapState.selectedFeatureID; store.inspectorMode = .components; store.showInspector = true
                    return true
                }
            }
        }
        return false
    }

    private func scaledMetric(_ value: CGFloat) -> CGFloat {
        WorkspaceRenderScaling.metric(Double(value), factor: renderScaling.factor)
    }

    static func safeLineWidth(_ value: Double) -> CGFloat {
        guard value.isFinite else { return 1 }
        return CGFloat(max(value, 0))
    }

    static func safePointDiameter(_ value: Int) -> CGFloat {
        CGFloat(max(value, 0))
    }
}
