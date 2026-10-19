import AppKit
import RASWorkspaceCore
import SwiftUI

/// Draws only network-backed map surfaces. Project raster/vector layers are
/// composed above this canvas by ProjectMapView, matching the source map's
/// background-layer ordering.
struct BackgroundMapCanvas: View {
    @ObservedObject var session: BackgroundMapSession
    let points: [MapPoint]
    let scale: CGFloat
    let offset: CGSize

    private var render: BackgroundMapRenderResult? { session.snapshot?.render }
    private var attributions: [String] {
        var seen: Set<String> = []
        return (render?.sources ?? []).compactMap { source in
            guard source.state != "disabled", let attribution = source.attribution,
                  seen.insert(attribution).inserted else { return nil }
            return attribution
        }
    }
    private var failure: BackgroundMapSourceStatus? {
        render?.sources.first(where: { $0.state == "failed" })
    }

    var body: some View {
        GeometryReader { proxy in
            let transform = MapTransform(points: points, size: proxy.size, scale: scale, offset: offset)
            Canvas { context, size in
                guard let render else { return }
                let wholeCanvas = Path(CGRect(origin: .zero, size: size))
                if let backgroundColor = render.osmBackgroundColor.flatMap(SourceARGBColor.color) {
                    context.fill(wholeCanvas, with: .color(backgroundColor))
                }

                for raster in render.rasters {
                    draw(raster, in: &context, transform: transform)
                }
                let orderedFeatures = render.features.enumerated().sorted {
                    $0.element.zIndex == $1.element.zIndex
                        ? $0.offset < $1.offset
                        : $0.element.zIndex < $1.element.zIndex
                }
                for (_, feature) in orderedFeatures {
                    draw(feature, in: &context, transform: transform)
                }
                drawLabels(render.labels, in: &context, transform: transform, size: size)
            }
            .overlay(alignment: .bottomLeading) {
                if !attributions.isEmpty {
                    Text(attributions.map(L10n.text).joined(separator: " · ")).font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
                        .padding(8)
                }
            }
            .overlay(alignment: .topTrailing) {
                if let failure, let message = failure.message {
                    Label(L10n.text(message), systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.primary)
                        .padding(7).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 5))
                        .padding(8).accessibilityLabel(L10n.text(message))
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func draw(_ raster: BackgroundMapRaster, in context: inout GraphicsContext,
                      transform: MapTransform) {
        guard raster.width > 0, raster.height > 0,
              raster.rgba.count == raster.width * raster.height * 4,
              let provider = CGDataProvider(data: raster.rgba as CFData),
              let image = CGImage(width: raster.width, height: raster.height,
                  bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: raster.width * 4,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return }
        let upperLeft = transform.screen(MapPoint(x: raster.minX, y: raster.maxY))
        let lowerRight = transform.screen(MapPoint(x: raster.maxX, y: raster.minY))
        let rect = CGRect(x: min(upperLeft.x, lowerRight.x), y: min(upperLeft.y, lowerRight.y),
            width: abs(lowerRight.x - upperLeft.x), height: abs(lowerRight.y - upperLeft.y))
        guard rect.width.isFinite, rect.height.isFinite, rect.width > 0, rect.height > 0 else { return }
        var rasterContext = context
        rasterContext.opacity = raster.opacity
        rasterContext.draw(Image(decorative: image, scale: 1), in: rect)
    }

    private func draw(_ feature: BackgroundMapFeature, in context: inout GraphicsContext,
                      transform: MapTransform) {
        var path = Path()
        let translation = feature.isTranslated
            ? CGPoint(x: feature.translationX, y: -feature.translationY) : .zero
        for part in feature.parts {
            guard let first = part.points.first else { continue }
            path.move(to: screen(first, transform: transform, translation: translation))
            for coordinate in part.points.dropFirst() {
                path.addLine(to: screen(coordinate, transform: transform, translation: translation))
            }
            if part.isClosed || feature.geometryType == "Polygon" { path.closeSubpath() }
        }
        guard !path.isEmpty else { return }

        var clippedContext = context
        let clipping = polygonPath(feature.clipPolygon, transform: transform)
        if !clipping.isEmpty { clippedContext.clip(to: clipping) }

        if feature.geometryType == "Polygon",
           let fill = feature.fillColor.flatMap(SourceARGBColor.color),
           feature.fillOpacity > 0 {
            clippedContext.fill(path, with: .color(fill.opacity(feature.fillOpacity)),
                style: FillStyle(eoFill: true, antialiased: true))
        }
        if let stroke = feature.strokeColor.flatMap(SourceARGBColor.color),
           feature.strokeOpacity > 0, feature.strokeWidth.isFinite, feature.strokeWidth > 0 {
            let dash = feature.isDashed ? feature.dash.map { CGFloat($0) } : []
            clippedContext.stroke(path, with: .color(stroke.opacity(feature.strokeOpacity)),
                style: StrokeStyle(lineWidth: feature.strokeWidth, lineCap: .round,
                    lineJoin: .round, miterLimit: 2, dash: dash, dashPhase: 0))
        }
    }

    private func drawLabels(_ labels: [BackgroundMapLabel], in context: inout GraphicsContext,
                            transform: MapTransform, size: CGSize) {
        var occupied: [CGRect] = []
        var duplicateAnchors: Set<String> = []
        let orderedLabels = labels.enumerated().sorted {
            $0.element.zIndex == $1.element.zIndex
                ? $0.offset < $1.offset
                : $0.element.zIndex < $1.element.zIndex
        }
        for (_, label) in orderedLabels {
            guard let location = label.point.map({ transform.screen(MapPoint(x: $0.x, y: $0.y)) })
                    ?? polylineMiddle(label.line, transform: transform),
                  location.x.isFinite, location.y.isFinite,
                  location.x >= -100, location.y >= -100,
                  location.x <= size.width + 100, location.y <= size.height + 100 else { continue }
            let anchorKey = "\(label.text)|\(Int(location.x.rounded()))|\(Int(location.y.rounded()))"
            guard duplicateAnchors.insert(anchorKey).inserted else { continue }

            let fontSize = CGFloat(label.fontSize.isFinite ? min(max(label.fontSize, 5), 40) : 10)
            let estimatedWidth = min(max(CGFloat(label.text.count) * fontSize * 0.58, fontSize),
                label.maximumWidth > 0 ? CGFloat(label.maximumWidth) * fontSize : 250)
            let bounds = CGRect(x: location.x - estimatedWidth / 2 - 2,
                y: location.y - fontSize / 2 - 2, width: estimatedWidth + 4, height: fontSize + 4)
            guard !occupied.contains(where: { $0.intersects(bounds) }) else { continue }
            occupied.append(bounds)

            let fontFamily = label.fontFamily.flatMap { $0.isEmpty ? nil : $0 } ?? "Helvetica"
            var text = Text(label.text)
                .font(.custom(fontFamily, size: fontSize))
                .foregroundColor(label.textColor.flatMap(SourceARGBColor.color) ?? .primary)
            if label.bold { text = text.bold() }
            if label.italic { text = text.italic() }
            let angle = label.point == nil ? polylineAngle(label.line, transform: transform) : 0
            var labelContext = context
            labelContext.translateBy(x: location.x, y: location.y)
            if angle.isFinite { labelContext.rotate(by: .radians(angle)) }
            let anchor = CGPoint.zero
            if let halo = label.haloColor.flatMap(SourceARGBColor.color), label.haloWidth > 0 {
                let radius = min(CGFloat(label.haloWidth), 8)
                for x in [-radius, 0, radius] {
                    for y in [-radius, 0, radius] where x != 0 || y != 0 {
                        labelContext.draw(text.foregroundColor(halo), at: CGPoint(x: x, y: y), anchor: .center)
                    }
                }
            }
            labelContext.draw(text, at: anchor, anchor: .center)
        }
    }

    private func polygonPath(_ points: [BackgroundMapCoordinate], transform: MapTransform) -> Path {
        guard let first = points.first else { return Path() }
        var path = Path()
        path.move(to: transform.screen(MapPoint(x: first.x, y: first.y)))
        for point in points.dropFirst() { path.addLine(to: transform.screen(MapPoint(x: point.x, y: point.y))) }
        path.closeSubpath()
        return path
    }

    private func polylineMiddle(_ points: [BackgroundMapCoordinate], transform: MapTransform) -> CGPoint? {
        let screenPoints = points.map { transform.screen(MapPoint(x: $0.x, y: $0.y)) }
        guard screenPoints.count >= 2 else { return screenPoints.first }
        let lengths = zip(screenPoints, screenPoints.dropFirst()).map { hypot($1.x - $0.x, $1.y - $0.y) }
        let total = lengths.reduce(0, +)
        guard total.isFinite, total > 0 else { return screenPoints.first }
        var remaining = total / 2
        for (index, length) in lengths.enumerated() {
            if remaining <= length {
                let fraction = length > 0 ? remaining / length : 0
                let start = screenPoints[index]
                let end = screenPoints[index + 1]
                return CGPoint(x: start.x + (end.x - start.x) * fraction,
                    y: start.y + (end.y - start.y) * fraction)
            }
            remaining -= length
        }
        return screenPoints.last
    }

    private func polylineAngle(_ points: [BackgroundMapCoordinate], transform: MapTransform) -> Double {
        let screenPoints = points.map { transform.screen(MapPoint(x: $0.x, y: $0.y)) }
        guard screenPoints.count >= 2 else { return 0 }
        let middle = screenPoints.count / 2
        let before = screenPoints[max(middle - 1, 0)]
        let after = screenPoints[min(middle + 1, screenPoints.count - 1)]
        return Double(atan2(after.y - before.y, after.x - before.x))
    }

    private func screen(_ coordinate: BackgroundMapCoordinate, transform: MapTransform,
                        translation: CGPoint = .zero) -> CGPoint {
        let point = transform.screen(MapPoint(x: coordinate.x, y: coordinate.y))
        return CGPoint(x: point.x + translation.x, y: point.y + translation.y)
    }
}
